(in-package #:ourro.tests)

(def-suite parallel-tools-suite :in ourro)
(in-suite parallel-tools-suite)


(defun register-fixture-tool (name ms &key (caps '(:filesystem-read)) gene)
  "A tool that sleeps MS then returns its own name — a stand-in for a slow read."
  (ourro.tools:register-tool
   (make-instance 'ourro.tools:tool
                  :name name :description "fixture"
                  :function (let ((secs (/ ms 1000.0)) (name name))
                              (lambda (args) (declare (ignore args))
                                (sleep secs) name))
                  :capabilities caps :gene gene)))

(defun tc (id name)
  "A canonical tool-call block."
  (list :type :tool-call :id id :name name :args-json "{}"))

(defun result-ids (results)
  (mapcar (lambda (m) (pget m :tool-call-id)) results))

(defmacro with-fixture-tools ((&rest names) &body body)
  `(unwind-protect (progn ,@body)
     ,@(mapcar (lambda (n) `(ignore-errors (ourro.tools:unregister-tool ,n))) names)))

(defun fresh-agent ()
  (ourro.agent::make-agent :provider (ourro.llm:make-scripted-provider '())))

(test parallel-eligibility-follows-capabilities-and-probation
  (with-fixture-tools ("ok_r" "wr" "prob_r")
    (register-fixture-tool "ok_r" 1)
    (register-fixture-tool "wr" 1 :caps '(:filesystem-write))
    (register-fixture-tool "prob_r" 1 :gene "tool/probs")
    ;; read-only, no gene → eligible
    (is-true (ourro.agent::parallel-eligible-p (tc "c" "ok_r")))
    ;; a write capability → never eligible
    (is-false (ourro.agent::parallel-eligible-p (tc "c" "wr")))
    ;; a read-only tool whose gene is on probation → serial (revert mutates
    ;; global fdefinitions mid-batch; must not race)
    (ourro.kernel::start-probation "tool/probs")
    (is-false (ourro.agent::parallel-eligible-p (tc "c" "prob_r")))
    ;; an unknown tool → not eligible (falls to the serial path, which reports it)
    (is-false (ourro.agent::parallel-eligible-p (tc "c" "nope")))))

(test parallel-batch-runs-concurrently-preserving-order
  (with-fixture-tools ("slow_a" "slow_b")
    (register-fixture-tool "slow_a" 300)
    (register-fixture-tool "slow_b" 300)
    (let* ((agent (fresh-agent))
           (calls (list (tc "c1" "slow_a") (tc "c2" "slow_b")))
           (start (get-internal-real-time))
           (results (ourro.agent::run-tool-calls agent calls))
           (elapsed (ourro.agent::elapsed-ms start (get-internal-real-time))))
      ;; Two 300 ms reads concurrently ⇒ well under the 600 ms serial sum.
      (is (< elapsed 550))
      ;; Results (and their contents) come back in original call order.
      (is (equal '("c1" "c2") (result-ids results)))
      (is (equal '("slow_a" "slow_b")
                 (mapcar (lambda (m) (pget m :content)) results))))))

(test parallel-workers-preserve-the-turn-causal-context
  (with-fixture-tools ("causal_a" "causal_b")
    (let ((seen '()) (lock (bt:make-lock "causal-fixture")))
      (dolist (name '("causal_a" "causal_b"))
        (ourro.tools:register-tool
         (make-instance
          'ourro.tools:tool :name name :description "causal fixture"
          :capabilities '(:filesystem-read)
          :function (lambda (args)
                      (declare (ignore args))
                      (bt:with-lock-held (lock)
                        (push (copy-list ourro.reflex.journal:*causal-context*)
                              seen))
                      "ok"))))
      (let ((ourro.reflex.journal:*causal-context*
              '(:trace-id "turn-trace" :causation-id "user-event")))
        (ourro.agent::run-tool-calls
         (fresh-agent) (list (tc "c1" "causal_a") (tc "c2" "causal_b"))))
      (is (= 2 (length seen)))
      (is-true (every (lambda (context)
                        (string= "turn-trace" (pget context :trace-id)))
                      seen))
      ;; Instrumentation reserves a child tool-event identity before invoking
      ;; the implementation, so immediate causation may be that child; it must
      ;; remain non-NIL and on the inherited turn trace.
      (is-true (every (lambda (context) (pget context :causation-id)) seen)))))

