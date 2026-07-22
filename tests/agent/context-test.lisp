(in-package #:ourro.tests)

(def-suite context-suite :in ourro)
(in-suite context-suite)


(defun bedrock-test-provider ()
  ;; A real, in-table inference-profile id so model-pricing resolves and the
  ;; cost-accounting assertions exercise the priced path deterministically (a
  ;; raw off-menu id prices at 0 → :cost-known NIL).
  (make-instance 'ourro.llm::bedrock-provider
                 :model "global.anthropic.claude-opus-4-5-20251101-v1:0"
                 :api-key "x"))

(defun ctx-agent ()
  (ourro.agent::make-agent :provider (bedrock-test-provider)))

(defun long-conversation (n)
  "user, then N (assistant tool-call + 30 KB tool-result + user) turns."
  (let ((conv (list (ourro.llm:user-message "start")))
        (big (make-string 30000 :initial-element #\x)))
    (dotimes (i n)
      (setf conv
            (append conv
                    (list (ourro.llm:assistant-message
                           (list (list :type :tool-call :id (format nil "c~A" i)
                                       :name "read_file" :args-json "{}")))
                          (ourro.llm:tool-result-message
                           (format nil "c~A" i) "read_file"
                           (format nil "first line~%~A" big))
                          (ourro.llm:user-message (format nil "next ~A" i))))))
    conv))

(defun canonical-pairs-ok-p (conversation)
  "Every assistant tool-call has a :tool reply — the invariant compaction must
never break (a dangling call 400s the next turn)."
  (let ((calls (loop for m in conversation
                     when (eq (pget m :role) :assistant)
                       sum (length (ourro.llm:assistant-tool-calls m))))
        (results (count :tool conversation :key (lambda (m) (pget m :role)))))
    (= calls results)))


(test model-window-shape-fallback
  (is (= 1000000 (ourro.llm:model-context-window "gemini-3.1-pro-preview")))
  (is (= 200000 (ourro.llm:model-context-window "eu.anthropic.claude-opus-4-5-v1")))
  (is (= 200000 (ourro.llm:model-context-window "some-unknown-model"))))

(test turn-cost-bills-cache-reads-at-the-discount
  (let ((pricing '(:in 15.0d0 :out 75.0d0 :cache-read 1.5d0)))
    ;; 1M prompt tokens, all cache hits → the cheap :cache-read rate.
    (is (< (abs (- 1.5d0 (ourro.agent::turn-cost
                          (list :prompt-tokens 1000000 :candidates-tokens 0
                                :cache-read-tokens 1000000)
                          pricing)))
           0.001))
    ;; 1M prompt tokens, none cached → the full :in rate.
    (is (< (abs (- 15.0d0 (ourro.agent::turn-cost
                           (list :prompt-tokens 1000000 :candidates-tokens 0
                                 :cache-read-tokens 0)
                           pricing)))
           0.001))))

(test usage-accounting-tracks-tokens-and-cost
  (let ((agent (ctx-agent)))
    (is (= 200000 (ourro.agent::agent-context-window agent)))
    (ourro.agent::record-turn-usage
     agent (list :prompt-tokens 100000 :candidates-tokens 1000 :cache-read-tokens 0))
    (is (= 100000 (ourro.agent::agent-last-prompt-tokens agent)))
    (is (plusp (ourro.agent::agent-session-cost agent)))
    (let ((hud (ourro.agent::context-hud-data agent)))
      (is (= 50 (pget hud :percent)))       ; 100000 / 200000
      (is-true (pget hud :cost-known)))))


(test stage1-elides-old-tool-results-keeping-pairs
  (let* ((conv (long-conversation 12))
         (compacted (ourro.agent::elide-old-tool-results conv :keep-turns 3)))
    ;; No messages dropped, and every call still has its result.
    (is (= (length conv) (length compacted)))
    (is-true (canonical-pairs-ok-p compacted))
    ;; Every tool message keeps id + name + non-empty content (well-formed pair).
    (dolist (m compacted)
      (when (eq (pget m :role) :tool)
        (is-true (pget m :tool-call-id))
        (is-true (pget m :name))
        (is (plusp (length (pget m :content))))))
    ;; The oldest result is shrunk; the most recent is kept whole.
    (let ((tools (remove-if-not (lambda (m) (eq (pget m :role) :tool)) compacted)))
      (is (< (length (pget (first tools) :content)) 200))
      (is (> (length (pget (car (last tools)) :content)) 20000)))
    ;; Both serializers still emit well-formed output (no orphan calls).
    (is-true (vectorp (ourro.llm::bedrock-serialize-messages compacted)))
    (is-true (ourro.llm::serialize-messages compacted))))

