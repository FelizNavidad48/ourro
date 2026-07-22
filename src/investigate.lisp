
(in-package #:ourro.agent)

(defparameter *investigation-max-steps* 8)
(defparameter *investigation-watchdog-seconds* 300)
(defparameter *investigation-ceiling* '(:filesystem-read :observe :llm))

(defun read-only-tool-p (tool)
  (let ((ourro.reflex.investigation:*capability-ceiling*
          *investigation-ceiling*))
    (ourro.reflex.investigation:read-only-tool-p tool)))

(defun read-only-tool-registry ()
  (let ((ourro.reflex.investigation:*capability-ceiling*
          *investigation-ceiling*))
    (ourro.reflex.investigation:read-only-tool-registry)))

(defun investigation-system-prompt ()
  (ourro.reflex.investigation:investigation-system-prompt))

(defun run-investigation (provider prompt &key events
                                               (max-steps *investigation-max-steps*))
  "Compatibility text surface; the durable adapter uses the complete transcript."
  (let ((ourro.reflex.investigation:*maximum-steps* max-steps)
        (ourro.reflex.investigation:*watchdog-seconds*
          *investigation-watchdog-seconds*)
        (ourro.reflex.investigation:*capability-ceiling*
          *investigation-ceiling*))
    (ourro.reflex.investigation:run-investigation-text
     provider prompt :events events :max-steps max-steps)))
