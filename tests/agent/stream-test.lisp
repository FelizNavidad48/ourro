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

(test first-delta-clears-thinking-activity
  ;; "reasoning…" must not linger once visible text starts streaming (review #5).
  (let ((agent (ourro.agent::make-agent
                :provider (ourro.llm:make-scripted-provider '()))))
    (ourro.agent::stream-event agent (list :kind :thinking))
    (ourro.agent::stream-event agent (list :kind :delta :text "answer"))
    (is (null (ourro.tui:statusbar-activity
               (ourro.tui:view-statusbar (ourro.agent::agent-view agent)))))))


(defun span-with-style-p (agent style needle)
  (some (lambda (line)
          (some (lambda (span)
                  (and (consp span) (eq (car span) style)
                       (search needle (cdr span))))
                line))
        (ourro.tui:transcript-lines
         (ourro.tui:view-transcript (ourro.agent::agent-view agent)))))

(test streaming-tail-renders-markdown-heading
  (let ((agent (ourro.agent::make-agent
                :provider (ourro.llm:make-scripted-provider '()))))
    (ourro.agent::stream-event agent (list :kind :delta :text "# Title"))
    (is-true (span-with-style-p agent :accent "Title"))))

(test streaming-tail-unclosed-fence-is-code
  ;; An unclosed ``` fence mid-stream renders its body as :code (it will be).
  (let ((agent (ourro.agent::make-agent
                :provider (ourro.llm:make-scripted-provider '()))))
    (ourro.agent::stream-event agent
                              (list :kind :delta
                                    :text (format nil "```~%(defun f ())")))
    (is-true (span-with-style-p agent :code "defun"))))

(test streaming-cursor-on-last-line-only
  (let ((agent (ourro.agent::make-agent
                :provider (ourro.llm:make-scripted-provider '()))))
    (ourro.agent::stream-event agent
                              (list :kind :delta
                                    :text (format nil "line one~%line two")))
    (let* ((lines (ourro.tui:transcript-lines
                   (ourro.tui:view-transcript (ourro.agent::agent-view agent))))
           (last-line (car (last lines))))
      (flet ((has-cursor (line)
               (some (lambda (s) (and (consp s) (search "▌" (cdr s)))) line)))
        (is-true (has-cursor last-line))
        (is (notany (lambda (line) (and (not (eq line last-line))
                                        (has-cursor line)))
                    lines))))))

(test streaming-final-equals-tail-minus-cursor
  ;; The proof that there is no pop-in: the last streamed frame is identical to
  ;; the finalized render once the ▌ cursor is stripped.
  (let ((agent (ourro.agent::make-agent
                :provider (ourro.llm:make-scripted-provider '())))
        (msg (format nil "# Heading~%~%some **bold** text and `code`")))
    (ourro.agent::stream-event agent (list :kind :delta :text msg))
    (let ((tail-text (remove #\▌ (agent-transcript-text agent))))
      (ourro.agent::finish-stream agent msg)
      (is (string= tail-text (agent-transcript-text agent))))))

;; A provider that streams a couple of tokens and THEN signals a provider-error,
;; to exercise the mid-stream failure path in PROCESS-TURN (review #1).
(defclass stream-then-error-provider (ourro.llm:provider) ())

(defmethod ourro.llm:complete ((p stream-then-error-provider) system messages tools
                              &key on-event)
  (declare (ignore system messages tools))
  (when on-event
    (funcall on-event (list :kind :delta :text "partial "))
    (funcall on-event (list :kind :delta :text "answer")))
  (error 'ourro.llm:provider-error :message "connection reset"))

(test provider-error-mid-stream-keeps-error-line
  ;; The unwind-protect cleanup rebuilds from the stream head; the error line
  ;; must survive it, and the partial text must be finalized (cursor gone).
  (let ((agent (ourro.agent::make-agent
                :provider (make-instance 'stream-then-error-provider))))
    (ourro.agent::process-turn agent)
    (let ((text (agent-transcript-text agent)))
      (is (search "partial answer" text))          ; partial stream finalized
      (is (search "provider error: connection reset" text))
      (is (null (search "▌" text))))               ; no dangling cursor
    (is-false (ourro.agent::agent-stream-start agent))))
