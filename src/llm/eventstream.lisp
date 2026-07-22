
(in-package #:ourro.llm)

(define-condition eventstream-decode-error (error)
  ((detail :initarg :detail :initform nil :reader eventstream-decode-error-detail))
  (:report (lambda (c s)
             (format s "event-stream decode error~@[: ~A~]"
                     (eventstream-decode-error-detail c))))
  (:documentation "A malformed AWS event-stream frame. The Bedrock streaming
path catches this and falls back to the non-streaming Converse call so a broken
stream never loses a turn (M10-2)."))

(defun es-be-u16 (bytes offset)
  (logior (ash (aref bytes offset) 8) (aref bytes (+ offset 1))))

(defun es-be-u32 (bytes offset)
  (logior (ash (aref bytes offset) 24)
          (ash (aref bytes (+ offset 1)) 16)
          (ash (aref bytes (+ offset 2)) 8)
          (aref bytes (+ offset 3))))

(defun es-octets->string (octets)
  (handler-case (sb-ext:octets-to-string octets :external-format :utf-8)
    (error () (map 'string (lambda (b) (code-char (logand b 255))) octets))))

(defun eventstream-header-value (headers name)
  "Scan HEADERS (an octet vector) for the header NAME and return its string
value, or NIL. Handles every AWS header value type for correct advancement, but
only type 7 (string) carries a value we return."
  (let ((pos 0) (len (length headers)))
    (handler-case
        (loop while (< pos len) do
          (let* ((name-len (aref headers pos))
                 (hname (es-octets->string
                         (subseq headers (1+ pos) (+ 1 pos name-len))))
                 (type (aref headers (+ 1 pos name-len)))
                 (vpos (+ 2 pos name-len)))
            (macrolet ((advance (n) `(setf pos (+ vpos ,n))))
              (case type
                ((0 1) (advance 0))          ; bool true / false: no value bytes
                (2 (advance 1))              ; byte
                (3 (advance 2))              ; short
                (4 (advance 4))              ; int
                ((5 8) (advance 8))          ; long / timestamp
                (9 (advance 16))             ; uuid
                ((6 7)                       ; byte array / string: u16 len + bytes
                 (let ((vlen (es-be-u16 headers vpos)))
                   (when (and (= type 7) (string= hname name))
                     (return-from eventstream-header-value
                       (es-octets->string
                        (subseq headers (+ vpos 2) (+ vpos 2 vlen)))))
                   (advance (+ 2 vlen))))
                (t (return-from eventstream-header-value nil))))))
      (error () nil))
    nil))

(defun make-vector-byte-reader (octets)
  "A READ-BYTES closure over OCTETS: (funcall it n) → the next N bytes (fresh
vector), NIL at a clean end (exactly 0 bytes left), or an EVENTSTREAM-DECODE-ERROR
on a truncated read (1..n-1 bytes left) — so a frame cut short is never mistaken
for a clean frame boundary."
  (let ((pos 0) (len (length octets)))
    (lambda (n)
      (cond ((<= (+ pos n) len)
             (prog1 (subseq octets pos (+ pos n)) (incf pos n)))
            ((= pos len) nil)           ; clean end
            (t (error 'eventstream-decode-error
                      :detail (format nil "truncated read: ~A of ~A bytes"
                                      (- len pos) n)))))))

(defun make-stream-byte-reader (stream)
  "A READ-BYTES closure over a binary STREAM: reads exactly N bytes (blocking,
so a frame split across socket reads is reassembled), NIL at a clean end (0 bytes
before N is reached), or an EVENTSTREAM-DECODE-ERROR on a truncated read — a
stream cut mid-prelude must fall back, not be read as a clean end-of-stream."
  (lambda (n)
    (let ((buf (make-array n :element-type '(unsigned-byte 8))))
      (let ((got (read-sequence buf stream)))
        (cond ((= got n) buf)
              ((= got 0) nil)           ; clean EOF at a frame boundary
              (t (error 'eventstream-decode-error
                        :detail (format nil "truncated read: ~A of ~A bytes"
                                        got n))))))))

(defun decode-eventstream (read-bytes on-message &key deadline deadline-seconds)
  "Decode AWS event-stream frames via the READ-BYTES closure, calling ON-MESSAGE
with (event-type payload-string) per frame. event-type is the :event-type header
value (a string) or NIL. Stops cleanly at EOF; signals EVENTSTREAM-DECODE-ERROR
on a structurally invalid frame, or STREAM-DEADLINE-EXCEEDED if DEADLINE passes
between frames (the per-read socket timeout can't bound a dribbling stream)."
  (loop
    (when (and deadline (> (get-internal-real-time) deadline))
      (error 'stream-deadline-exceeded :seconds deadline-seconds))
    (let ((prelude (funcall read-bytes 12)))
      (unless prelude (return))            ; clean EOF between frames
      (let ((total (es-be-u32 prelude 0))
            (headers-len (es-be-u32 prelude 4)))
        (when (or (< total 16) (> headers-len (- total 16)))
          (error 'eventstream-decode-error
                 :detail (format nil "bad frame lengths total=~A headers=~A"
                                 total headers-len)))
        (let ((remaining (funcall read-bytes (- total 12))))
          (unless remaining
            (error 'eventstream-decode-error :detail "truncated frame body"))
          (let* ((headers (subseq remaining 0 headers-len))
                 (payload-len (- total headers-len 16))
                 (payload (subseq remaining headers-len (+ headers-len payload-len)))
                 (event-type (eventstream-header-value headers ":event-type")))
            (funcall on-message event-type (es-octets->string payload))))))))
