(in-package #:ourro.tests)

(def-suite verifier-suite :in ourro)
(in-suite verifier-suite)

(defparameter +good-gene+
  "(defgene tool/double
     (:generation 2 :parent nil :capabilities () :provenance (:test t))
   (:doc \"A tool that doubles a number, for verifier tests.\")
   (:code
    (deftool double-it
        ((n :integer \"Number to double\" :required t))
      (:doc \"Return 2n as a string.\")
      (:contract (:pre ((integerp n)) :post ((stringp result))))
      (format nil \"~A\" (* 2 n))))
   (:tests
    (test double-it/works
      (let ((h (make-hash-table :test (quote equal))))
        (setf (gethash \"n\" h) 21)
        (is (string= \"42\" (run-tool (find-tool \"double_it\") h)))))))")

(test good-gene-passes-gauntlet
  (multiple-value-bind (gene report) (ourro.verify:verify-gene-text +good-gene+)
    (is (string= "tool/double" (ourro.genome:gene-name gene)))
    (is (getf report :test-report))
    ;; The candidate must NOT be visible in the live registry afterward.
    (is (null (ourro.tools:find-tool "double_it")))))

(test staged-verification-does-not-leak-runtime-registries
  (let ((hooks-before (copy-tree ourro.observe:*turn-hooks*))
        (queue-before (copy-tree ourro.observe:*evolution-queue*))
        (reverts-before (ourro.kernel:revert-record-count
                         "observe/staged-hook")))
    (ourro.verify:verify-gene-text
     "(defgene observe/staged-hook
        (:generation 1 :parent nil :capabilities (:observe)
         :provenance (:test t))
       (:doc \"Registers a verification-only observer.\")
       (:code
        (add-turn-hook \"verification-only\" (lambda () nil)))
       (:tests
        (test staged-hook/exists (is (= 1 1)))))")
    (is (equal hooks-before ourro.observe:*turn-hooks*))
    (is (equal queue-before ourro.observe:*evolution-queue*))
    (is (= reverts-before
           (ourro.kernel:revert-record-count "observe/staged-hook")))))

(test staged-verification-confines-fixture-filesystem-authority
  (let* ((path (merge-pathnames
                (format nil "ourro-verifier-escape-~A.txt"
                        (ourro.util:make-id "escape"))
                (uiop:temporary-directory)))
         (source
           (format nil
                   "(defgene test/fs-escape
                      (:generation 1 :capabilities ())
                      (:doc \"Must not escape the staged fixture root.\")
                      (:code (defun fs-escape-marker () nil))
                      (:tests
                       (test fs-escape/t
                         (cap/write-file ~S \"escaped\")
                         (is-true t))))"
                   (namestring path))))
    (unwind-protect
         (progn
           (signals ourro.kernel:verification-failure
             (ourro.verify:verify-gene-text source))
           (is-false (probe-file path)))
      (ignore-errors (delete-file path)))))

(test capability-violation-rejected-at-lint
  (signals ourro.kernel:verification-failure
    (ourro.verify:verify-gene-text
     "(defgene tool/bad
        (:generation 2 :capabilities (:filesystem-read))
      (:doc \"Declares read but writes.\")
      (:code
       (deftool bad-tool ((p :string \"path\" :required t))
         (:doc \"bad\")
         (:contract (:pre () :post ((stringp result))))
         (cap/write-file p \"x\")))
      (:tests (test bad/t (is-true t))))")))

(test compile-error-rejected
  (signals ourro.kernel:verification-failure
    (ourro.verify:verify-gene-text
     "(defgene tool/broken
        (:generation 2 :capabilities ())
      (:doc \"Will not compile.\")
      (:code
       (deftool broken ((x :integer \"n\" :required t))
         (:doc \"broken\")
         (:contract (:pre () :post ((stringp result))))
         (this-function-does-not-exist x)))
      (:tests (test broken/t (is-true t))))")))

(test failing-test-rejected
  (signals ourro.kernel:verification-failure
    (ourro.verify:verify-gene-text
     "(defgene tool/failer
        (:generation 2 :capabilities ())
      (:doc \"Its test fails.\")
      (:code
       (deftool failer ((x :integer \"n\" :required t))
         (:doc \"failer\")
         (:contract (:pre () :post ((stringp result))))
         (format nil \"~A\" x)))
      (:tests (test failer/t (is (string= \"nope\" \"yep\")))))")))

(test withheld-capability-test-adds-repair-hint
  ;; A gene may DECLARE :subprocess, but verification runs observationally and
  ;; withholds it — a test that actually calls cap/run-program raises
  ;; CAPABILITY-VIOLATION ("requires undeclared capability :SUBPROCESS", which
  ;; is misleading since the gene DID declare it). The test-stage diagnostic
  ;; must add a hint steering the repair loop to fake the effect, not re-declare.
  (handler-case
      (progn
        (ourro.verify:verify-gene-text
         "(defgene tool/runner
            (:generation 2 :capabilities (:subprocess))
          (:doc \"Runs a command.\")
          (:code
           (deftool runner ((cmd :string \"c\" :required t))
             (:doc \"runner\")
             (:contract (:pre ((stringp cmd)) :post ((stringp result))))
             (multiple-value-bind (out code)
                 (cap/run-program (list \"/bin/echo\" cmd))
               (declare (ignore code))
               out)))
          (:tests (test runner/t
                    (is (search \"hi\" (run-tool (find-tool \"runner\")
                                        (let ((h (make-hash-table :test 'equal)))
                                          (setf (gethash \"cmd\" h) \"hi\") h)))))))")
        (fail "expected verification-failure"))
    (ourro.kernel:verification-failure (c)
      (let ((diag (ourro.kernel:verification-failure-diagnostics c)))
        (is (eq :test (ourro.kernel:verification-failure-stage c)))
        (is (search "withholds" diag))
        (is (search ":subprocess" diag))
        (is (search "Fake" diag)))))
  ;; The hint is silent when nothing withheld is implicated.
  (is (null (ourro.verify::withheld-capability-hint
             (ourro.genome:parse-gene-source
              "(defgene tool/pure (:generation 2 :capabilities ())
                 (:doc \"pure\")
                 (:code (deftool pure () (:doc \"p\")
                          (:contract (:pre () :post ((stringp result)))) \"x\"))
                 (:tests (test pure/t (is-true t))))")
             "Unexpected Error: CAPABILITY-VIOLATION"))))

(test missing-doc-rejected
  (signals ourro.kernel:verification-failure
    (ourro.verify:verify-gene-text
     "(defgene tool/nodoc
        (:generation 2 :capabilities ())
      (:doc \"gene doc present but tool doc missing\")
      (:code
       (deftool nodoc ((x :integer \"n\" :required t))
         (:contract (:pre () :post ((stringp result))))
         (format nil \"~A\" x)))
      (:tests (test nodoc/t (is-true t))))")))


(test gene-random-primitive-rejected
  ;; RANDOM is not in OURRO.API and is walker-forbidden: a gene that reaches for
  ;; it cannot pass the gauntlet. Determinism is structural.
  (signals ourro.kernel:verification-failure
    (ourro.verify:verify-gene-text
     "(defgene tool/roll
        (:generation 2 :capabilities ())
      (:doc \"Rolls a die — nondeterministic, must be rejected.\")
      (:code
       (deftool roll ((n :integer \"sides\" :required t))
         (:doc \"Return a random number in [0,n).\")
         (:contract (:pre ((integerp n)) :post ((stringp result))))
         (format nil \"~A\" (random n))))
      (:tests (test roll/t (is-true t))))")))

(test determinism-metadata-parses
  ;; The :determinism contract survives parsing and is readable back.
  (let ((gene (ourro.genome:parse-gene-source
               "(defgene tool/id
                  (:generation 2 :capabilities ()
                   :determinism ((\"id_tool\" :n 5)))
                (:doc \"identity\")
                (:code
                 (deftool id-tool ((n :integer \"n\" :required t))
                   (:doc \"echo n\")
                   (:contract (:pre () :post ((stringp result))))
                   (format nil \"~A\" n)))
                (:tests (test id/t (is-true t))))")))
    (is (equal '(("id_tool" :n 5)) (ourro.genome:gene-determinism gene)))))

(test determinism-probe-passes-for-pure-tool
  ;; A declared probe on a genuinely deterministic tool passes and adds a
  ;; :determinism stage to the report.
  (multiple-value-bind (gene report)
      (ourro.verify:verify-gene-text
       "(defgene tool/const
          (:generation 2 :capabilities ()
           :determinism ((\"double_up\" :n 21)))
        (:doc \"Doubles a number — deterministic.\")
        (:code
         (deftool double-up ((n :integer \"n\" :required t))
           (:doc \"Return 2n.\")
           (:contract (:pre ((integerp n)) :post ((stringp result))))
           (format nil \"~A\" (* 2 n))))
        (:tests
         (test double-up/t
           (let ((h (make-hash-table :test (quote equal))))
             (setf (gethash \"n\" h) 21)
             (is (string= \"42\" (run-tool (find-tool \"double_up\") h)))))))")
    (is (string= "tool/const" (ourro.genome:gene-name gene)))
    (is-true (assoc :determinism (getf report :stages)))))

(test determinism-probe-rejects-nondeterministic-tool
  ;; A tool whose output varies across calls (GENSYM) fails its declared
  ;; determinism probe — the gene cannot go live even though its test passes.
  (signals ourro.kernel:verification-failure
    (ourro.verify:verify-gene-text
     "(defgene tool/noisy
        (:generation 2 :capabilities ()
         :determinism ((\"noisy\")))
      (:doc \"Emits a fresh symbol each call — not reproducible.\")
      (:code
       (deftool noisy ()
         (:doc \"A different string every call.\")
         (:contract (:pre () :post ((stringp result))))
         (format nil \"~A\" (gensym))))
      (:tests
       (test noisy/t
         (is-true (stringp (run-tool (find-tool \"noisy\")
                                     (make-hash-table :test (quote equal))))))))")))

(test determinism-probe-watchdog-reaps-a-looping-tool
  ;; A tool that loops on the probe args must be reaped by the probe's own
  ;; watchdog, not hang the gauntlet (M5 review #2). Its FiveAM test doesn't
  ;; call the tool, so only the probe triggers the loop.
  (let ((ourro.verify:*test-timeout-seconds* 1))
    (signals ourro.kernel:verification-failure
      (ourro.verify:verify-gene-text
       "(defgene tool/looper
          (:generation 2 :capabilities ()
           :determinism ((\"looper\")))
        (:doc \"Loops forever when called — the probe must time out.\")
        (:code
         (deftool looper ()
           (:doc \"Never returns.\")
           (:contract (:pre () :post ((stringp result))))
           (loop)))
        (:tests (test looper/t (is-true t))))"))))
