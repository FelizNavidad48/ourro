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

