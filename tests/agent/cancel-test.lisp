(in-package #:ourro.tests)

(def-suite cancel-suite :in ourro)
(in-suite cancel-suite)

(defun cancel-transcript-text (agent)
  (with-output-to-string (out)
    (dolist (line (ourro.tui:transcript-lines
                   (ourro.tui:view-transcript (ourro.agent::agent-view agent))))
      (dolist (span (if (listp line) line (list line)))
        (write-string (if (consp span) (cdr span) (princ-to-string span)) out))
      (write-char #\Newline out))))

(defun make-cancel-agent ()
  (ourro.agent::make-agent :provider (ourro.llm:make-scripted-provider '())))

(test turn-cancelled-is-not-an-error
  (is-false (typep (make-condition 'ourro.kernel:turn-cancelled) 'error))
  (is-true (typep (make-condition 'ourro.kernel:turn-cancelled) 'serious-condition))
  ;; An inner (error () …) must NOT catch it; only the outer turn-cancelled clause.
  (is (eq :cancel
          (handler-case
              (handler-case
                  (error 'ourro.kernel:turn-cancelled :reason "x")
                (error () :swallowed-as-error))
            (ourro.kernel:turn-cancelled () :cancel)))))

(test interrupt-action-state-machine
  ;; idle → quit regardless of timing
  (is (eq :quit (ourro.agent::interrupt-action nil 0 100)))
  ;; busy, first press (last press long ago) → cancel
  (is (eq :cancel (ourro.agent::interrupt-action t 0 100)))
  ;; busy, second press within the window → quit
  (is (eq :quit (ourro.agent::interrupt-action t 100 101)))
  ;; busy, press well outside the window → cancel again
  (is (eq :cancel (ourro.agent::interrupt-action t 100 200))))

(test cancel-between-tool-calls-keeps-conversation-well-formed
  ;; With a cancel pending, RUN-TOOL-CALLS must still return a functionResponse
  ;; for EVERY functionCall (Gemini 400s on a dangling call), each an error
  ;; carrying "cancelled". If the synthesis were removed the tools would run and
  ;; the content would be their real output — so this pins the M7-1 wiring.
  (let ((agent (make-cancel-agent))
        (calls (list (list :type :tool-call :id "a" :name "read_file")
                     (list :type :tool-call :id "b" :name "list_files"))))
    (setf (ourro.agent::agent-cancel-requested agent) t)
    (let ((results (ourro.agent::run-tool-calls agent calls)))
      (is (= 2 (length results)))
      (is (equal '("a" "b")
                 (mapcar (lambda (m) (getf m :tool-call-id)) results)))
      (is (every (lambda (m) (getf m :error-p)) results))
      (is (every (lambda (m) (search "cancelled"
                                     (princ-to-string (getf m :content))))
                 results)))))

(defclass stream-then-cancel-provider (ourro.llm:provider)
  ((agent :initarg :agent :accessor stcp-agent)))

(defmethod ourro.llm:complete ((p stream-then-cancel-provider) system messages tools
                              &key on-event)
  (declare (ignore system messages tools))
  (when on-event
    (funcall on-event (list :kind :delta :text "partial "))
    (setf (ourro.agent::agent-cancel-requested (stcp-agent p)) t)
    (funcall on-event (list :kind :delta :text "more")))
  (ourro.llm:assistant-message '()))

(test cancel-mid-stream-finalizes-partial-text
  (let* ((agent (make-cancel-agent))
         (provider (make-instance 'stream-then-cancel-provider :agent agent)))
    (setf (ourro.agent::agent-provider agent) provider
          (ourro.agent::agent-conversation agent)
          (list (ourro.llm:user-message "hi")))
    (ourro.agent::process-turn agent)
    (let ((text (cancel-transcript-text agent)))
      (is (search "partial" text))                 ; what streamed is kept
      (is (search "cancelled" text))               ; the ⏹ marker
      (is (null (search "▌" text))))               ; no dangling cursor
    ;; No partial assistant message was committed to the conversation.
    (is (notany (lambda (m) (eq (getf m :role) :assistant))
                (ourro.agent::agent-conversation agent)))
    (is-false (ourro.agent::agent-stream-start agent))
    ;; The flag is cleared by the turn cleanup.
    (is-false (ourro.agent::agent-cancel-requested agent))))

