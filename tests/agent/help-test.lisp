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
      (is (search "/theme" text))
      (is (search "ctrl-o" text))
      (is (search "cancels" text))
      (is (search "quits" text)))))

(test theme-command-switches-and-validates
  (let ((agent (help-agent)))
    (unwind-protect
         (progn
           (ourro.agent::cmd-theme agent '("dark"))
           (is (eq :dark (ourro.tui:current-theme)))
           (ourro.agent::cmd-theme agent '("sepia"))
           (is (search "unknown theme" (help-transcript-text agent))))
      (ourro.tui:set-theme :dark))))

(test cold-boot-shows-primer
  (let ((agent (help-agent)))
    (ourro.agent::greet agent)
    (let ((text (help-transcript-text agent)))
      (is (search "how this works" text))
      (is (search "/onboard" text)))))

(test restored-session-skips-primer
  (let ((agent (help-agent)))
    ;; A restored session has scrollback before greet runs — the transcript is
    ;; non-empty, so the primer is skipped.
    (ourro.agent::add-transcript-line
     agent (list (ourro.tui:styled :assistant "a restored prior line")))
    (ourro.agent::greet agent)
    (is (null (search "how this works" (help-transcript-text agent))))))
