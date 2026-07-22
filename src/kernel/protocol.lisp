
(in-package #:ourro.kernel)

(defparameter *max-protocol-frame-chars* (* 16 1024 1024)
  "Hard allocation bound for one supervisor protocol frame.")

(defclass protocol-connection ()
  ((socket :initarg :socket :reader connection-socket)
   (stream :initarg :stream :reader connection-stream)
   ;; Two locks, deliberately split. SEND-LOCK guards a single frame write
   ;; and is held only for microseconds. REQUEST-LOCK serializes whole
   ;; request/reply exchanges (so there is never more than one outstanding
   ;; reply on the wire, and only one thread ever reads). Crucially, a
   ;; pending request does NOT block PROTOCOL-SEND: the heartbeat thread
   ;; keeps feeding the supervisor's liveness monitor while a generation
   ;; build is in flight — holding one lock across send+receive was how
   ;; the agent used to get itself SIGKILLed as "hung" mid-build.
   (send-lock :initform (bt:make-lock "ourro-protocol-send")
              :reader connection-send-lock)
   (request-lock :initform (bt:make-lock "ourro-protocol-request")
                 :reader connection-request-lock)
   (broken :initform nil :accessor connection-broken-p
           :documentation "Set after a reply timeout: the stream may hold a
stale reply, so later requests fail fast instead of desyncing.")))

(defun protocol-connection-p (thing)
  (typep thing 'protocol-connection))

(defun protocol-connect (socket-path &key (timeout 5))
  "Connect to the supervisor's Unix socket. Returns a PROTOCOL-CONNECTION
or NIL if the socket is absent/refusing (e.g. running without supervisor)."
  (let ((deadline (+ (get-universal-time) timeout)))
    (loop
      (handler-case
          (let ((socket (make-instance 'sb-bsd-sockets:local-socket
                                       :type :stream)))
            (sb-bsd-sockets:socket-connect socket (namestring socket-path))
            (return
              (make-instance 'protocol-connection
                             :socket socket
                             :stream (sb-bsd-sockets:socket-make-stream
                                      socket :input t :output t
                                      :element-type 'character
                                      :buffering :line
                                      :external-format :utf-8))))
        (error ()
          (if (>= (get-universal-time) deadline)
              (return nil)
              (sleep 0.2)))))))

(defun protocol-send (connection message)
  "Send MESSAGE (a plist) as one length-prefixed frame. Thread-safe.
Signals PROTOCOL-ERROR on I/O error.

Framing is <char-count>\\n<payload>\\n — NOT one-line-per-message: payloads
carry gene source text whose strings contain literal newlines (PRIN1 does
not escape them), and line framing chopped such messages mid-string. The
supervisor then dropped the connection as garbage, heartbeats went into a
dead socket, and the monitor killed a healthy agent as \"hung\"."
  (handler-case
      (bt:with-lock-held ((connection-send-lock connection))
        (let ((payload (with-standard-io-syntax
                         (let ((*package* (find-package :keyword))
                               (*print-pretty* nil)
                               (*print-readably* nil)
                               (*print-escape* t))
                           (prin1-to-string message))))
              (stream (connection-stream connection)))
          (format stream "~A~%" (length payload))
          (write-string payload stream)
          (terpri stream)
          (finish-output stream)))
    (error (c)
      (error 'protocol-error :message (format nil "send failed: ~A" c))))
  message)

(defun protocol-receive (connection &key (eof-error-p t))
  "Read one length-prefixed message. Returns the plist, or NIL on EOF when
EOF-ERROR-P NIL."
  (let* ((stream (connection-stream connection))
         (header (handler-case (read-line stream nil nil)
                   (error (c)
                     (if eof-error-p
                         (error 'protocol-error
                                :message (format nil "receive failed: ~A" c))
                         (return-from protocol-receive nil))))))
    (cond ((null header)
           (if eof-error-p
               (error 'protocol-error :message "connection closed")
               nil))
          (t
           (unless (and (plusp (length header))
                        (every #'digit-char-p header))
             (error 'protocol-error
                    :message (format nil "invalid frame length header ~S" header)))
           (let ((length (parse-integer header)))
             (unless (<= 0 length *max-protocol-frame-chars*)
               (error 'protocol-error
                      :message (format nil "frame length ~A exceeds bound ~A"
                                       length *max-protocol-frame-chars*)))
             (let ((payload (make-string length)))
                   (let ((read (handler-case (read-sequence payload stream)
                                 (error (c)
                                   (error 'protocol-error
                                          :message (format nil "receive failed: ~A" c))))))
                     (unless (= read length)
                       (error 'protocol-error
                              :message (format nil "truncated frame: ~A of ~A chars"
                                               read length))))
                   (let ((terminator (read-char stream nil nil)))
                     (unless (eql terminator #\Newline)
                       (error 'protocol-error :message "frame missing trailing newline")))
                   (parse-protocol-message payload)))))))

(defun parse-protocol-message (line)
  (handler-case
      (with-standard-io-syntax
        (let ((*read-eval* nil)
              (*package* (find-package :keyword)))
          (with-input-from-string (in line)
            (let ((message (read in nil :eof)))
              (unless (and (listp message) (oddp (length message))
                           (keywordp (first message)))
                (error "message is not a keyword plist"))
              (unless (eq (read in nil :eof) :eof)
                (error "message contains trailing forms"))
              message))))
    (error (c)
      (error 'protocol-error
             :message (format nil "unparseable message ~S: ~A" line c)))))

(defun protocol-request (connection message &key (timeout 600))
  "Send MESSAGE and wait for its reply. Requests are serialized by the
request lock (one outstanding reply at a time; one reader); sends from
other threads — heartbeats — interleave freely between frames. TIMEOUT
seconds without a reply signals PROTOCOL-ERROR and marks the connection
broken (a late reply would desync the next request)."
  (bt:with-lock-held ((connection-request-lock connection))
    (when (connection-broken-p connection)
      (error 'protocol-error :message "connection broken by an earlier timeout"))
    (protocol-send connection message)
    (handler-case
        (sb-ext:with-timeout timeout
          (protocol-receive connection))
      (sb-ext:timeout ()
        (setf (connection-broken-p connection) t)
        (error 'protocol-error
               :message (format nil "no reply to ~S within ~As"
                                (first message) timeout))))))

(defun protocol-close (connection)
  (when connection
    (ignore-errors (close (connection-stream connection)))
    (ignore-errors (sb-bsd-sockets:socket-close (connection-socket connection))))
  nil)


(defun make-protocol-server (socket-path)
  "Bind and listen on SOCKET-PATH. Returns the listening socket."
  (let ((path (namestring socket-path)))
    (when (probe-file path) (delete-file path))
    (ensure-directories-exist path)
    (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (sb-bsd-sockets:socket-bind socket path)
      (sb-bsd-sockets:socket-listen socket 4)
      socket)))

(defun protocol-serve (server-socket handler &key stop-p on-disconnect)
  "Accept connections on SERVER-SOCKET; for each message call
(HANDLER message connection) and send its non-NIL return value as the
reply. Runs until STOP-P returns true or the socket dies. Handles one
client at a time (the supervisor has exactly one agent). ON-DISCONNECT,
if given, runs whenever a client connection ends — the supervisor uses it
to disarm its heartbeat watchdog instead of killing an agent it simply
can't hear."
  (loop
    (when (and stop-p (funcall stop-p)) (return))
    (let ((client (handler-case (sb-bsd-sockets:socket-accept server-socket)
                    (error () (return)))))
      (let ((connection (make-instance
                         'protocol-connection
                         :socket client
                         :stream (sb-bsd-sockets:socket-make-stream
                                  client :input t :output t
                                  :element-type 'character
                                  :buffering :line
                                  :external-format :utf-8))))
        (unwind-protect
             (loop
               (when (and stop-p (funcall stop-p)) (return))
               (let ((message (handler-case
                                  (protocol-receive connection :eof-error-p nil)
                                (protocol-error () nil))))
                 (unless message (return))
                 (let ((reply (funcall handler message connection)))
                   (when reply
                     (handler-case (protocol-send connection reply)
                       (protocol-error () (return)))))))
          (protocol-close connection)
          (when on-disconnect (ignore-errors (funcall on-disconnect))))))))
