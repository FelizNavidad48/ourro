
(in-package #:ourro.kernel)

(defparameter +all-capabilities+
  '(:filesystem-read :filesystem-write :subprocess :network :llm :observe :ui
    :automate)
  "The closed set of declarable capabilities. :observe lets a gene read the
event log and register turn hooks — i.e. be a smarter miner (PR-7). :ui lets a
gene add panes, status widgets, and keybindings — i.e. redecorate its own TUI
(PR-7's UI half, M3). :automate lets a gene register trigger-driven automations
that subscribe to the live event stream and act proactively — the reflexes arc
(M13). An :automate gene reacts; it still needs :subprocess/:llm/etc. to *do*
anything effectful inside the reaction.")

(defun capability-p (thing)
  (member thing +all-capabilities+))

(defvar *active-capabilities* +all-capabilities+
  "Capabilities of the currently executing context. Trusted (kernel/base)
code runs with all capabilities; RUN-TOOL binds this to the gene's
declared set before entering evolved code.")

(defvar *capability-ceiling* +all-capabilities+
  "Upper bound on the capabilities any context may hold. Normally the full
set, so it does nothing. BOOT lowers it to a read-only subset under
--visiting (M4-6): a time-travel session literally cannot write, spawn, or
reach the network, because every grant is intersected with this ceiling
before it takes effect. Enforced at the one choke point every grant flows
through — WITH-CAPABILITIES — so it covers both the per-tool grant in
CALL-INSTRUMENTED and the turn's blanket grant. The agent's own persistence
(handoff, checkpoint, event log) never touches the CAP/* wrappers, so a
lowered ceiling constrains only evolved/tool code, never the harness.")

(defvar *capability-filesystem-root* nil
  "When non-NIL, CAP/* file access is confined below this existing directory.

The verifier binds this to its disposable root. NIL preserves the ordinary
live workspace behavior, where higher-level toolkit functions perform their
own workspace checks. This Lisp boundary is defense in depth; a reviewed OS
sandbox remains required for effectful release.")

(defun capabilities-under-ceiling (capabilities)
  "CAPABILITIES intersected with the process ceiling. Trusted harness code uses
this to establish a fresh execution boundary."
  (remove-if-not (lambda (capability)
                   (member capability *capability-ceiling*))
                 capabilities))

(defun capabilities-under-active-grant (capabilities)
  "CAPABILITIES attenuated by both the process ceiling and the caller's current
grant. Evolved nested calls use this path and therefore cannot elevate."
  (remove-if-not (lambda (capability)
                   (and (member capability *capability-ceiling*)
                        (member capability *active-capabilities*)))
                 capabilities))

(defmacro with-capabilities (capabilities &body body)
  `(let ((*active-capabilities* (capabilities-under-ceiling ,capabilities)))
     ,@body))

(defmacro with-attenuated-capabilities (capabilities &body body)
  `(let ((*active-capabilities*
           (capabilities-under-active-grant ,capabilities)))
     ,@body))

(defun require-capability (capability operation)
  (unless (member capability *active-capabilities*)
    (error 'capability-violation :capability capability :operation operation))
  t)

(defun pathname-has-up-component-p (pathname)
  (member :up (pathname-directory (pathname pathname))))

(defun nearest-existing-pathname (pathname)
  (labels ((walk (current)
             (let ((present (probe-file current)))
               (if present
                   (truename present)
                   (let ((parent
                           (uiop:pathname-parent-directory-pathname current)))
                     (unless (equal parent current) (walk parent)))))))
    ;; PATHNAME-PARENT-DIRECTORY-PATHNAME treats its input as a directory.
    ;; Strip a file name/type first or `/root/new.txt` would jump to `/` and a
    ;; perfectly confined new fixture would be rejected as outside `/root/`.
    (walk (if (or (pathname-name pathname) (pathname-type pathname))
              (uiop:pathname-directory-pathname pathname)
              pathname))))

(defun capability-path (pathname capability operation)
  "Resolve PATHNAME under *CAPABILITY-FILESYSTEM-ROOT* or fail closed.

Existing symlinks are resolved before the prefix check. Nonexistent targets
are accepted only when their nearest existing ancestor resolves within the
root. :UP components are rejected instead of relying on namestring cleanup."
  (let ((root *capability-filesystem-root*))
    (if (null root)
        pathname
        (let* ((canonical-root
                 (uiop:ensure-directory-pathname (truename root)))
               (candidate
                 (if (uiop:absolute-pathname-p pathname)
                     (pathname pathname)
                     (merge-pathnames pathname canonical-root))))
          (when (pathname-has-up-component-p candidate)
            (error 'capability-violation :capability capability
                   :operation (list operation pathname :outside-root root)))
          (let* ((existing (nearest-existing-pathname candidate))
                 (root-name (namestring canonical-root))
                 (existing-name (and existing (namestring existing))))
            (unless (and existing-name
                         (or (string= root-name existing-name)
                             (string-prefix-p root-name existing-name)))
              (error 'capability-violation :capability capability
                     :operation (list operation pathname :outside-root root)))
            ;; For existing paths return the resolved target, closing ordinary
            ;; symlink escapes. A new target retains its checked pathname.
            (or (probe-file candidate) candidate))))))


(defun cap/read-file (pathname &key (max-bytes (* 4 1024 1024)))
  "Read a file as a string, capped at MAX-BYTES."
  (require-capability :filesystem-read `(cap/read-file ,pathname))
  (setf pathname (capability-path pathname :filesystem-read 'cap/read-file))
  (with-open-file (in pathname :direction :input
                               :external-format :utf-8
                               :element-type 'character)
    (let* ((length (min (or (ignore-errors (file-length in)) max-bytes)
                        max-bytes))
           (buffer (make-string length))
           (read (read-sequence buffer in)))
      (subseq buffer 0 read))))

(defun cap/write-file (pathname content &key (if-exists :supersede))
  (require-capability :filesystem-write `(cap/write-file ,pathname))
  (setf pathname (capability-path pathname :filesystem-write 'cap/write-file))
  (ensure-directories-exist pathname)
  (with-open-file (out pathname :direction :output
                                :external-format :utf-8
                                :if-exists if-exists
                                :if-does-not-exist :create)
    (write-string content out))
  (namestring pathname))

(defun cap/delete-file (pathname)
  (require-capability :filesystem-write `(cap/delete-file ,pathname))
  (setf pathname (capability-path pathname :filesystem-write 'cap/delete-file))
  (delete-file pathname))

(defun cap/ensure-directories (pathname)
  (require-capability :filesystem-write `(cap/ensure-directories ,pathname))
  (setf pathname
        (capability-path pathname :filesystem-write 'cap/ensure-directories))
  (ensure-directories-exist pathname))

(defparameter *max-program-output-bytes* (* 4 1024 1024)
  "Maximum combined stdout/stderr retained by CAP/RUN-PROGRAM.")

(defun cap/run-program (command &key directory input (timeout 120)
                                     (max-output-bytes *max-program-output-bytes*))
  "Run COMMAND (list of strings) synchronously. Returns (values output exit-code).
Combined stdout+stderr, never signals on nonzero exit. Reading must never block
on pipe EOF: a backgrounded grandchild (`server &`) can hold the write end open
forever after the direct child exits, so once the child is dead we only wait a
short quiet grace for straggling output, and the TIMEOUT deadline is enforced
on every path — including the final reap."
  (require-capability :subprocess `(cap/run-program ,command))
  (let* ((process (uiop:launch-program
                   command
                   :directory directory
                   :input (and input (make-string-input-stream input))
                   :output :stream
                   :error-output :output))
         (output-stream (uiop:process-info-output process))
         (buffer (make-string-output-stream))
         (deadline (+ (get-universal-time) (or timeout 120)))
         (quiet-since nil))
    (unwind-protect
         (progn
           (loop for char = (read-char-no-hang output-stream nil :eof)
                 do (cond ((eq char :eof) (return))
                          (char
                           ;; Keep draining after the bound so a noisy child
                           ;; cannot block on a full pipe, but retain only a
                           ;; bounded prefix in the Lisp heap.
                           (when (< (file-position buffer) max-output-bytes)
                             (write-char char buffer))
                           (setf quiet-since nil))
                          ((> (get-universal-time) deadline)
                           (uiop:terminate-process process :urgent t)
                           (return))
                          ((not (uiop:process-alive-p process))
                           ;; Child is dead but the pipe hasn't hit EOF — a
                           ;; live grandchild may hold it open indefinitely.
                           ;; Allow ~1s of quiet for late output, then stop.
                           (let ((now (get-universal-time)))
                             (if quiet-since
                                 (when (> (- now quiet-since) 1) (return))
                                 (setf quiet-since now)))
                           (sleep 0.02))
                          (t (sleep 0.02))))
           ;; Reap without blocking past the deadline: a child that closed its
           ;; stdout (EOF above) may still be running.
           (loop while (and (uiop:process-alive-p process)
                            (<= (get-universal-time) deadline))
                 do (sleep 0.05))
           (when (uiop:process-alive-p process)
             (uiop:terminate-process process :urgent t))
           (let ((code (uiop:wait-process process)))
             (values (get-output-stream-string buffer) code)))
      (ignore-errors (close output-stream)))))

(defun cap/launch-program (command &key directory output-file)
  "Launch COMMAND detached; returns the UIOP process-info. When OUTPUT-FILE is
given, stdout AND stderr append to it (a job's startup errors are the whole
point of a dev server, so they must be captured, not discarded). Input is
ALWAYS nil — a detached job must never read the tty. Without OUTPUT-FILE the
output is discarded, as before."
  (require-capability :subprocess `(cap/launch-program ,command))
  (if output-file
      (progn
        ;; Ensure the log exists so :append has a file to append to (a fresh
        ;; job's log does not exist yet) and so its directory is present.
        (ensure-directories-exist output-file)
        (with-open-file (s output-file :direction :output
                                       :if-exists :append
                                       :if-does-not-exist :create)
          (finish-output s))
        (uiop:launch-program command
                             :directory directory
                             :input nil
                             :output output-file
                             :if-output-exists :append
                             :error-output output-file
                             :if-error-output-exists :append))
      (uiop:launch-program command :directory directory
                                   :input nil
                                   :output nil :error-output nil)))

(defun cap/http-request (url &key (method :get) headers content (timeout 60)
                                  want-stream)
  "Perform an HTTP request via dexador. Returns what DEX:REQUEST returns."
  (require-capability :network `(cap/http-request ,url))
  (dexador:request url :method method :headers headers :content content
                       :read-timeout timeout :connect-timeout timeout
                       :want-stream want-stream))
