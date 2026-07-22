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

(test mixed-batch-parallels-reads-then-runs-the-rest-serially
  (with-fixture-tools ("r1" "r2" "w1")
    (register-fixture-tool "r1" 250)
    (register-fixture-tool "r2" 250)
    (register-fixture-tool "w1" 250 :caps '(:filesystem-write))
    (let* ((agent (fresh-agent))
           ;; [r1 r2] run together; w1 is serial after them.
           (calls (list (tc "c1" "r1") (tc "c2" "r2") (tc "c3" "w1")))
           (start (get-internal-real-time))
           (results (ourro.agent::run-tool-calls agent calls))
           (elapsed (ourro.agent::elapsed-ms start (get-internal-real-time))))
      ;; ~250 (parallel reads) + ~250 (serial w1) ≈ 500, not 750.
      (is (< elapsed 700))
      (is (equal '("c1" "c2" "c3") (result-ids results))))))

(test single-eligible-call-takes-the-serial-path
  ;; A batch of one is never parallelized — today's exact path.
  (with-fixture-tools ("solo")
    (register-fixture-tool "solo" 1)
    (let* ((agent (fresh-agent))
           (results (ourro.agent::run-tool-calls agent (list (tc "c1" "solo")))))
      (is (equal '("c1") (result-ids results)))
      (is (string= "solo" (pget (first results) :content))))))

(test cancel-before-batch-synthesizes-cancelled-for-all
  (with-fixture-tools ("s1")
    (register-fixture-tool "s1" 1)
    (let ((agent (fresh-agent)))
      (setf (ourro.agent::agent-cancel-requested agent) t)
      (let ((results (ourro.agent::run-tool-calls
                      agent (list (tc "c1" "s1") (tc "c2" "s1") (tc "c3" "s1")))))
        (is (= 3 (length results)))
        (is (equal '("c1" "c2" "c3") (result-ids results)))
        (is (every (lambda (m) (pget m :error-p)) results))
        (is (every (lambda (m) (search "cancelled" (pget m :content))) results))))))

(test parallel-batch-cancel-mid-join-synthesizes-unfinished
  ;; A cancel active while a parallel batch is joining: the join bails out and
  ;; every still-running call gets a synthesized cancelled result (read-only
  ;; orphans are harmless). Deterministic because cancel is set up front.
  (with-fixture-tools ("slow_c")
    (register-fixture-tool "slow_c" 500)
    (let ((agent (fresh-agent)))
      (setf (ourro.agent::agent-cancel-requested agent) t)
      (let ((results (ourro.agent::run-parallel-tool-batch
                      agent (list (tc "c1" "slow_c") (tc "c2" "slow_c")))))
        (is (equal '("c1" "c2") (result-ids results)))
        (is (every (lambda (m) (search "cancelled" (pget m :content))) results))))))
