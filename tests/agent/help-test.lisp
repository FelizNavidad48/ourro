(in-package #:ourro.tests)

(def-suite help-suite :in ourro)
(in-suite help-suite)

(defun help-agent ()
  (ourro.agent::make-agent :provider (ourro.llm:make-scripted-provider '())))

(defun help-transcript-text (agent)
  (with-output-to-string (out)
    (dolist (line (ourro.tui:transcript-lines
                   (ourro.tui:view-transcript (ourro.agent::agent-view agent))))
      (dolist (span (if (listp line) line (list line)))
        (write-string (if (consp span) (cdr span) (princ-to-string span)) out))
      (write-char #\Newline out))))

(test help-lists-cockpit-keys
  (let ((agent (help-agent)))
    (ourro.agent::cmd-help agent)
    (let ((text (help-transcript-text agent)))
      (is (search "/out" text))
      (is (search "ctrl-o" text))
      (is (search "cancels" text))
      (is (search "quits" text)))))

