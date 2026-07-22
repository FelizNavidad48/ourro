(in-package #:ourro.tests)

(def-suite reflex-compiler-suite :in ourro)
(in-suite reflex-compiler-suite)

(test reflex-compiler-retains-ir-generated-lisp-and-proof
  (let* ((definition (ourro.reflex.model:definition-from-form
                      (fixture-reflex-form)))
         (version (ourro.reflex.compiler:compile-reflex
                   definition :base-proof-hash "base"))
         (transition (ourro.reflex.model:version-transition-function version))
         (result (funcall transition '(:step :notify) '(:kind :job-exit) '())))
    (is (stringp (ourro.reflex.model:version-hash version)))
    (is-true (ourro.reflex.compiler:generated-lisp-safe-p
              (ourro.reflex.model:version-generated-lisp version)))
    (is-true (ourro.reflex.proof:reflex-proof-valid-p
              (ourro.reflex.model:version-proof version)))
    (is (eq :done (getf (getf result :state) :step)))
    (is (= 1 (length (getf result :effects))))))

(test source-valid-generated-lisp-invalid-output-is-rejected
  (let ((ourro.reflex.compiler::*transition-generator*
          (lambda (definition)
            (declare (ignore definition))
            '(lambda (state event activity-results)
               (declare (ignore state event activity-results))
               (ourro.kernel::cap/read-file "outside-the-activity-boundary")))))
    (signals error
      (ourro.reflex.compiler:compile-reflex
       (ourro.reflex.model:definition-from-form (fixture-reflex-form))))))

(test trusted-dependency-change-invalidates-all-routes-before-rebuild
  (let ((ourro.reflex.compiler:*version-registry* (make-hash-table :test #'equal))
        (ourro.reflex.compiler:*active-version-pointers*
          (make-hash-table :test #'equal))
        (ourro.reflex.compiler:*canary-routes* (make-hash-table :test #'equal))
        (ourro.reflex.model:*reflex-definitions* (make-hash-table :test #'equal))
        (ourro.reflex.model:*definition-registered-hook* nil)
        (ourro.reflex.compiler::*dependency-fingerprint-override* "dependency-a"))
    (let* ((definition (ourro.reflex.model:definition-from-form
                        (fixture-reflex-form)))
           (old (ourro.reflex.compiler:compile-reflex definition)))
      (setf (gethash (ourro.reflex.model:reflex-name definition)
                     ourro.reflex.model:*reflex-definitions*) definition)
      (ourro.reflex.compiler:install-reflex-version old)
      (ourro.reflex.compiler:activate-reflex-version
       'failed-job-briefing (ourro.reflex.model:version-hash old)
       :approved-authority '(:observe))
      (let ((ourro.reflex.compiler::*dependency-fingerprint-override*
              "dependency-b"))
        (is-false (ourro.reflex.compiler:version-current-p old))
        (signals error
          (ourro.reflex.compiler:select-routed-reflex-versions
           '(:kind :job-exit :event-id "stale-route")))
        (let ((rebuilt
                (ourro.reflex.compiler:rebuild-reflex-dependency-closure)))
          (is (= 1 (length rebuilt)))
          (is (eq :stale (ourro.reflex.model:version-status old)))
          (is-false (ourro.reflex.compiler:active-reflex-version
                     'failed-job-briefing))
          (is (not (string= (ourro.reflex.model:version-hash old)
                            (ourro.reflex.model:version-hash
                             (first rebuilt)))))
          (is-true (ourro.reflex.compiler:version-current-p
                    (first rebuilt))))))))

