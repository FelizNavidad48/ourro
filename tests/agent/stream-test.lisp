(in-package #:ourro.tests)

(def-suite stream-suite :in ourro)
(in-suite stream-suite)

(defun agent-transcript-text (agent)
  (with-output-to-string (out)
    (dolist (line (ourro.tui:transcript-lines
                   (ourro.tui:view-transcript (ourro.agent::agent-view agent))))
      (dolist (span (if (listp line) line (list line)))
        (write-string (if (consp span) (cdr span) (princ-to-string span)) out))
      (write-char #\Newline out))))

(test streaming-shows-cursor-then-finalizes
  (let ((agent (ourro.agent::make-agent
                :provider (ourro.llm:make-scripted-provider '()))))
    (ourro.agent::stream-event agent (list :kind :delta :text "hello "))
    (ourro.agent::stream-event agent (list :kind :delta :text "world"))
    (let ((text (agent-transcript-text agent)))
      (is (search "hello world" text))
      (is (search "▌" text)))                    ; cursor present mid-stream
    (is-true (ourro.agent::agent-stream-start agent))
    ;; Finalizing swaps the streamed tail for final lines; the cursor is gone.
    (ourro.agent::finish-stream agent "hello world")
    (let ((text (agent-transcript-text agent)))
      (is (search "hello world" text))
      (is (null (search "▌" text))))
    (is-false (ourro.agent::agent-stream-start agent))))

(test streaming-preserves-prior-transcript
  ;; Only the in-progress message is rewritten — earlier lines stay put (D-1).
  (let ((agent (ourro.agent::make-agent
                :provider (ourro.llm:make-scripted-provider '()))))
    (ourro.agent::add-wrapped agent "an earlier line" :user)
    (ourro.agent::stream-event agent (list :kind :delta :text "partial"))
    (ourro.agent::finish-stream agent "final reply")
    (let ((text (agent-transcript-text agent)))
      (is (search "an earlier line" text))
      (is (search "final reply" text))
      (is (null (search "partial" text)))        ; the transient text was replaced
      (is (null (search "▌" text))))))

(test wrapped-lines-hang-indents-continuation-lines
  ;; :hang leads every continuation line so wrapped text keeps a hanging indent
  ;; aligned under the first line's content (the /tools alignment fix). Without
  ;; :hang, continuations drift to the margin. First line is unchanged either way.
  (let* ((agent (ourro.agent::make-agent
                 :provider (ourro.llm:make-scripted-provider '())))
         (text (with-output-to-string (s)
                 (dotimes (i 40) (format s "word~A " i)))) ; long enough to wrap
         (plain (mapcar (lambda (l) (cdr (first l)))
                        (ourro.agent::wrapped-lines agent text :dim)))
         (hung (mapcar (lambda (l) (cdr (first l)))
                       (ourro.agent::wrapped-lines agent text :dim :hang "  "))))
    (is (> (length plain) 1))                    ; it actually wrapped
    (is (= (length plain) (length hung)))        ; :hang doesn't add/drop lines
    (is (string= (first plain) (first hung)))    ; first line identical
    ;; Each continuation gains exactly the 2-space hang.
    (is (string= (concatenate 'string "  " (second plain)) (second hung)))))

(test scripted-provider-streams-words
  (let ((deltas '())
        (provider (ourro.llm:make-scripted-provider (list "one two three")
                                                   :stream t)))
    (ourro.llm:complete provider "sys" (list (ourro.llm:user-message "hi")) nil
                       :on-event (lambda (e)
                                   (when (eq (getf e :kind) :delta)
                                     (push (getf e :text) deltas))))
    (is (> (length deltas) 1))                   ; word-by-word, not one shot
    (is (string= "one two three"
                 (apply #'concatenate 'string (reverse deltas))))))

(test thinking-event-sets-activity
  (let ((agent (ourro.agent::make-agent
                :provider (ourro.llm:make-scripted-provider '()))))
    (ourro.agent::stream-event agent (list :kind :thinking))
    (is (search "reasoning"
                (or (ourro.tui:statusbar-activity
                     (ourro.tui:view-statusbar (ourro.agent::agent-view agent)))
                    "")))))

