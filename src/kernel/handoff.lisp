
(in-package #:ourro.kernel)

(defun handoff-plist (&key session-id generation conversation scrollback
                           input-text cwd ticker pending extra checkpoint pid
                           frozen)
  "Build the canonical handoff payload. The same shape serves two callers: a
generation handoff (written to a fresh handoff-*.sexp) and a crash checkpoint
(CHECKPOINT t, PID set, written to the fixed checkpoint.sexp — M4-1). FROZEN
carries the evolution-frozen flag so a user's /freeze survives a restart
(handoff or crash-resume) instead of silently thawing."
  (list :version 1
        :written (iso-time)
        :checkpoint checkpoint
        :pid pid
        :session-id session-id
        :generation generation
        :cwd (and cwd (namestring cwd))
        :conversation conversation
        :scrollback scrollback
        :input-text (or input-text "")
        :ticker ticker
        :pending pending
        :frozen frozen
        :extra extra))

(defun write-handoff (payload &key (directory (ourro-path "state/")))
  "Write PAYLOAD to a fresh handoff file; returns its pathname."
  (ensure-dir directory)
  (let ((path (merge-pathnames (format nil "handoff-~A.sexp" (make-id "ho"))
                               directory)))
    (write-sexp-file path payload)
    path))

(defun read-handoff (pathname)
  "Read a handoff payload; returns NIL if missing or unreadable."
  (handler-case
      (let ((payload (read-sexp-file pathname)))
        (and (listp payload)
             (eql (pget payload :version) 1)
             payload))
    (error () nil)))
