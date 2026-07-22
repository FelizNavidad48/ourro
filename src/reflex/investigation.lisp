
(defpackage #:ourro.reflex.investigation
  (:use #:cl #:ourro.util)
  (:export #:run-investigation
           #:run-investigation-text
           #:read-only-tool-p
           #:read-only-tool-registry
           #:investigation-system-prompt
           #:*maximum-steps*
           #:*watchdog-seconds*
           #:*capability-ceiling*))

(in-package #:ourro.reflex.investigation)

(defparameter *maximum-steps* 8)
(defparameter *watchdog-seconds* 300)
(defparameter *capability-ceiling* '(:filesystem-read :observe :llm))
(defun read-only-tool-p (tool)
  "Admit any current or gene-grown tool whose authority fits the ceiling."
  (subsetp (ourro.tools:tool-capabilities tool) *capability-ceiling*))

(defun read-only-tool-registry ()
  (let ((registry (ourro.tools:make-tool-registry)))
    (dolist (tool (ourro.tools:list-tools) registry)
      (when (read-only-tool-p tool)
        (setf (gethash (ourro.tools:tool-name tool) registry) tool)))))

(defun investigation-system-prompt ()
  "You are ourro's background investigator. Diagnose the supplied local evidence without interrupting the user. You are strictly read-only: read files, search the codebase, and inspect recorded events only. You cannot edit files, run commands, start jobs, use the network directly, or mutate the genome. Cite the supplied evidence identity in every factual claim and finish with a concise diagnosis and next action.")

(defun provider-identity (provider)
  (let ((class (ignore-errors (class-name (class-of provider)))))
    (and class (string-downcase (symbol-name class)))))

(defun completed-result (text prompt events tool-results steps status provider)
  (list :text text :prompt prompt :events (copy-tree events)
        :tool-results (nreverse tool-results) :steps steps :status status
        :provider (provider-identity provider)
        :model (ignore-errors (ourro.llm:provider-model provider))
        :limits (list :steps *maximum-steps* :seconds *watchdog-seconds*)
        :no-changes-made t))

(defun investigation-workspace (workspace events)
  (let ((value (or workspace (pget (first events) :workspace)
                   ourro.toolkit:*workspace*)))
    (and value
         (handler-case
             (uiop:ensure-directory-pathname value)
           (error () nil)))))

(defun run-investigation (provider prompt &key events workspace
                                               (max-steps *maximum-steps*))
  "Run a bounded read-only mini-turn and return its complete durable transcript."
  (let* ((context (when events
                    (format nil "~%~%Recorded evidence (newest first):~%~{  ~S~%~}"
                            (subseq events 0 (min 20 (length events))))))
         (messages (list (ourro.llm:user-message
                          (format nil "~A~@[~A~]" prompt context))))
         (system (investigation-system-prompt))
         (last-text "")
         (tool-results '())
         (steps 0)
         (workspace (investigation-workspace workspace events))
         (ourro.llm:*llm-call-context* :background))
    (handler-case
        (sb-ext:with-timeout *watchdog-seconds*
          (let ((ourro.kernel:*capability-ceiling* *capability-ceiling*)
                (ourro.kernel:*capability-filesystem-root* workspace)
                (ourro.toolkit:*workspace* (or workspace ourro.toolkit:*workspace*))
                (read-only (read-only-tool-registry)))
            (dotimes (step max-steps
                           (completed-result
                            (if (plusp (length last-text))
                                last-text
                                "investigation reached its step cap without a conclusion")
                            prompt events tool-results steps :step-cap provider))
              (setf steps (1+ step))
              (let* ((message (ourro.llm:complete-with-retry
                               provider system messages
                               (ourro.tools:tool-declarations read-only)))
                     (tool-calls (ourro.llm:assistant-tool-calls message)))
                (setf messages (append messages (list message)))
                (let ((text (ourro.llm:assistant-text message)))
                  (when (plusp (length text)) (setf last-text text)))
                (when (null tool-calls)
                  (return (completed-result last-text prompt events tool-results
                                            steps :completed provider)))
                (dolist (call tool-calls)
                  (let* ((name (ourro.llm:tool-call-name call))
                         (args (ourro.llm:tool-call-args call))
                         (tool (ourro.tools:find-tool name read-only)))
                    (multiple-value-bind (result error-p)
                        (if tool
                            (ourro.tools:execute-tool-object tool args)
                            (values
                             (format nil "ERROR: tool ~A is unavailable in a read-only investigation"
                                     name)
                             t))
                      (push (list :call-id (ourro.llm:tool-call-id call)
                                  :tool name :arguments args :result result
                                  :error (and error-p t))
                            tool-results)
                      (setf messages
                            (append messages
                                    (list (ourro.llm:tool-result-message
                                           (ourro.llm:tool-call-id call)
                                           name result :error-p error-p)))))))))))
      (sb-ext:timeout ()
        (completed-result
         (if (plusp (length last-text)) last-text
             "investigation exceeded its watchdog before concluding")
         prompt events tool-results steps :timeout provider))
      (error (condition)
        (completed-result
         (format nil "investigation failed: ~A"
                 (truncate-string (princ-to-string condition) 200))
         prompt events tool-results steps :failed provider)))))

(defun run-investigation-text (provider prompt &key events workspace
                                               (max-steps *maximum-steps*))
  (pget (run-investigation provider prompt :events events :workspace workspace
                           :max-steps max-steps)
        :text))
