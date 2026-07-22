
(defpackage #:ourro.util
  (:use #:cl)
  (:export #:ourro-home
           #:ourro-path
           #:ensure-dir
           #:iso-time
           #:unix-time
           #:make-id
           #:pget
           #:plist-put
           #:string-prefix-p
           #:string-suffix-p
           #:string-join
           #:split-lines
           #:trim
           #:truncate-string
           #:percentile
           #:lcg-next
           #:copy-hash-table
           #:print-readable-to-string
           #:read-safe-from-string
           #:read-safe
           #:write-sexp-file
           #:read-sexp-file
           #:read-sexp-lines
           #:append-sexp-line
           #:with-sexp-syntax
           #:run-command
           #:command-failed
           #:command-failed-output
           #:getenv))

(in-package #:ourro.util)

(defun percentile (values fraction)
  "Return FRACTION's bounded empirical percentile without mutating VALUES."
  (unless values (error "cannot take a percentile of an empty sequence"))
  (unless (<= 0 fraction 1) (error "percentile fraction must be in [0,1]"))
  (let ((sorted (sort (copy-seq values) #'<)))
    (elt sorted (min (1- (length sorted))
                     (floor (* fraction (length sorted)))))))

(defun lcg-next (state &optional (salt 0))
  "Shared deterministic 31-bit LCG used by reproducible bootstrap routines."
  (mod (+ (* state 1103515245) 12345 salt) 2147483648))

(defun copy-hash-table (source &key (value-copier #'identity))
  "Copy SOURCE while preserving its test and explicitly choosing value depth."
  (let ((copy (make-hash-table :test (hash-table-test source)
                               :size (max 1 (hash-table-count source)))))
    (maphash (lambda (key value)
               (setf (gethash key copy) (funcall value-copier value)))
             source)
    copy))

(defun getenv (name &optional default)
  "Read environment variable NAME. For the project's own OURRO_* variables,
transparently fall back to the legacy OURO_* spelling (the pre-rename prefix,
one fewer R) when the OURRO_* form is unset — so a shell that still exports
OURO_BEDROCK_API_KEY / OURO_MODEL / OURO_HOME etc. keeps working after the
ouroboros→ourro rename. Only OURRO_-prefixed names get the fallback; every
other variable (AWS_*, PATH, …) is read verbatim."
  (or (uiop:getenv name)
      (and (>= (length name) 6)
           (string= name "OURRO_" :end1 6)
           (uiop:getenv (concatenate 'string "OURO_" (subseq name 6))))
      default))

(defvar *ourro-home* nil
  "Cached ourro state directory.")

(defun ourro-home ()
  "Root state directory: $OURRO_HOME or ~/.ourro/.
Holds the ledger, genome repo, images, sessions, and quarantine."
  (or *ourro-home*
      (setf *ourro-home*
            (uiop:ensure-directory-pathname
             (or (getenv "OURRO_HOME")
                 (merge-pathnames ".ourro/" (user-homedir-pathname)))))))

(defun ourro-path (&rest components)
  "Resolve COMPONENTS under the ourro home. A trailing / in the last
component makes the result a directory pathname."
  (let ((rel (format nil "~{~A~^/~}" components)))
    (merge-pathnames rel (ourro-home))))

(defun ensure-dir (pathname)
  (ensure-directories-exist (uiop:ensure-directory-pathname pathname))
  (uiop:ensure-directory-pathname pathname))

(defun iso-time (&optional (time (get-universal-time)))
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time time 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour min sec)))

(defun unix-time ()
  (- (get-universal-time) (encode-universal-time 0 0 0 1 1 1970 0)))

(defvar *id-random-state* (make-random-state t))

(defun make-id (&optional (prefix "id"))
  (format nil "~A-~8,'0X~4,'0X" prefix
          (random (expt 2 32) *id-random-state*)
          (random (expt 2 16) *id-random-state*)))

(defun pget (plist key &optional default)
  (getf plist key default))

(defun plist-put (plist key value)
  "Return a fresh plist with KEY set to VALUE."
  (let ((copy (copy-list plist)))
    (setf (getf copy key) value)
    copy))

(defun string-prefix-p (prefix string)
  (and (<= (length prefix) (length string))
       (string= prefix string :end2 (length prefix))))

(defun string-suffix-p (suffix string)
  (and (<= (length suffix) (length string))
       (string= suffix string :start2 (- (length string) (length suffix)))))

(defun string-join (separator strings)
  (format nil (concatenate 'string "~{~A~^" separator "~}") strings))

(defun split-lines (string)
  (uiop:split-string string :separator '(#\Newline)))

(defun trim (string)
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))

(defun truncate-string (string max)
  (if (<= (length string) max)
      string
      (concatenate 'string (subseq string 0 (max 0 (- max 1))) "…")))


(defmacro with-sexp-syntax (&body body)
  ;; *print-readably* NIL (not T): our persisted data is only keywords,
  ;; strings, numbers, and lists, all of which the standard printer renders
  ;; readably with *print-escape* T (from with-standard-io-syntax). Forcing
  ;; *print-readably* T additionally makes SBCL print base-strings as
  ;; #A((n) BASE-CHAR . "…") to preserve the exact array type — correct but
  ;; ugly in the ledger and event logs the user reads.
  `(with-standard-io-syntax
     (let ((*package* (find-package :ourro.util))
           (*print-readably* nil)
           (*print-escape* t)
           (*print-pretty* t)
           (*print-circle* nil)
           (*read-eval* nil))
       ,@body)))

(defun print-readable-to-string (form)
  (with-sexp-syntax
    (prin1-to-string form)))

(defun read-safe (stream &optional (eof-value :eof))
  "READ one form with *READ-EVAL* NIL. Never evaluates."
  (with-sexp-syntax
    (read stream nil eof-value)))

(defun read-safe-from-string (string &optional (eof-value :eof))
  (with-input-from-string (in string)
    (read-safe in eof-value)))

(defun write-sexp-file (pathname form)
  (ensure-directories-exist pathname)
  (uiop:with-staging-pathname (staging pathname)
    (with-open-file (out staging :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create)
      (with-sexp-syntax
        (prin1 form out)
        (terpri out))))
  pathname)

(defun read-sexp-file (pathname &optional default)
  (if (probe-file pathname)
      (with-open-file (in pathname :direction :input)
        (let ((form (read-safe in :eof)))
          (if (eq form :eof) default form)))
      default))

(defun read-sexp-lines (pathname)
  "Read every form from an append-only S-expression log (oldest first)."
  (when (probe-file pathname)
    (with-open-file (in pathname :direction :input)
      (loop for form = (read-safe in :eof)
            until (eq form :eof)
            collect form))))

(defun append-sexp-line (pathname form)
  "Append FORM as a single line and flush immediately (durability: at most
the final unflushed line can be lost on a crash)."
  (ensure-directories-exist pathname)
  (with-open-file (out pathname :direction :output
                                :if-exists :append
                                :if-does-not-exist :create)
    (with-sexp-syntax
      (let ((*print-pretty* nil))
        (prin1 form out)
        (terpri out)))
    (finish-output out))
  pathname)


(define-condition command-failed (error)
  ((command :initarg :command :reader command-failed-command)
   (code :initarg :code :reader command-failed-code)
   (output :initarg :output :reader command-failed-output))
  (:report (lambda (c stream)
             (format stream "Command ~S exited ~A:~%~A"
                     (command-failed-command c)
                     (command-failed-code c)
                     (command-failed-output c)))))

(defun run-command (command &key directory (timeout nil) input)
  "Run COMMAND (a list) and return its combined output as a string.
Signals COMMAND-FAILED on nonzero exit. When TIMEOUT (seconds) is given and the
child outlives it, the child is SIGKILLed and COMMAND-FAILED is signaled: the
timeout is ENFORCED, not advisory. A hung child must never wedge its caller —
e.g. an old generation image that ignores an --replay flag it predates and
instead boots its TUI, which then SIGTTOU-stops on the controlling terminal and
would otherwise block the supervisor forever."
  (if (null timeout)
      ;; No deadline: collect output synchronously (git, chmod — fast, local).
      (multiple-value-bind (output error-output code)
          (uiop:run-program command
                            :directory directory
                            :input (and input (make-string-input-stream input))
                            :output '(:string :stripped t)
                            :error-output :output
                            :ignore-error-status t)
        (declare (ignore error-output))
        (unless (zerop code)
          (error 'command-failed :command command :code code :output output))
        output)
      ;; Deadline: launch async to a temp file so the child stays killable.
      ;; A Lisp output stream would need a pump thread we couldn't reliably
      ;; unblock past a SIGKILL; a file sidesteps that entirely.
      (let* ((out-file (merge-pathnames (format nil "ourro-run-~A.out"
                                                (make-id "cmd"))
                                        (uiop:temporary-directory)))
             (process (uiop:launch-program
                       command
                       :directory directory
                       :input (and input (make-string-input-stream input))
                       :output out-file
                       :error-output :output))
             (read-out (lambda ()
                         (string-right-trim
                          '(#\Space #\Tab #\Newline #\Return)
                          (or (ignore-errors (uiop:read-file-string out-file))
                              "")))))
        (unwind-protect
             (let ((deadline (+ (get-universal-time) timeout)))
               (loop
                 (unless (uiop:process-alive-p process)
                   (let ((code (uiop:wait-process process))
                         (output (funcall read-out)))
                     (unless (zerop code)
                       (error 'command-failed :command command
                                              :code code :output output))
                     (return output)))
                 (when (>= (get-universal-time) deadline)
                   ;; SIGKILL (:urgent) — a SIGTTOU-stopped child ignores a
                   ;; queued SIGTERM until resumed, but nothing survives KILL.
                   (ignore-errors (uiop:terminate-process process :urgent t))
                   (ignore-errors (uiop:wait-process process))
                   (error 'command-failed :command command :code :timeout
                          :output (format nil "timed out after ~A s~%~A"
                                          timeout (funcall read-out))))
                 (sleep 0.1)))
          (ignore-errors (delete-file out-file))))))
