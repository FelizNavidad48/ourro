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

(test legacy-automation-subset-compiles-and-arbitrary-body-stays-opaque
  (let* ((source
           "(defgene auto/legacy-classification
               (:generation 1 :capabilities (:automate :observe))
              (:doc \"legacy classifier fixture\")
              (:code
               (define-automation simple-note
                   (:on (:kind :probe) :cooldown 5)
                 (post-note \"probe observed\" :style :info))
               (define-automation arbitrary-body
                   (:on (:kind :probe))
                 (let ((message (format nil \"~A\" event)))
                   (post-note message))))
              (:tests (test legacy-classification/t (is-true t))))")
         (gene (ourro.genome:parse-gene-source source))
         (semantics (ourro.reflex.compiler:legacy-automation-semantics gene))
         (compiled (ourro.reflex.compiler:compile-gene-reflexes gene)))
    (is (= 1 (length compiled)))
    (is (eq :compiled-subset (pget (first semantics) :semantics)))
    (is-true (pget (first semantics) :replayable))
    (is (eq :opaque (pget (second semantics) :semantics)))
    (is-false (pget (second semantics) :replayable))
    (is-false (pget (second semantics) :promotable))))

(test selected-seeds-cover-compiled-rewritten-and-opaque-semantics
  (let* ((root (asdf:system-source-directory "ourro"))
         (onboard
           (ourro.genome:parse-gene-source
            (uiop:read-file-string
             (merge-pathnames "seed-genome/genes/auto/onboard-new-repo.gene"
                              root))))
         (sentinel
           (ourro.genome:parse-gene-source
            (uiop:read-file-string
             (merge-pathnames "seed-genome/genes/auto/job-sentinel.gene"
                              root))))
         (legacy (ourro.reflex.compiler:legacy-automation-semantics onboard))
         (sentinel-versions
           (ourro.reflex.compiler:compile-gene-reflexes sentinel)))
    (is-true (find :compiled-subset legacy :key (lambda (entry)
                                                  (pget entry :semantics))))
    (is-true (find :opaque legacy :key (lambda (entry)
                                         (pget entry :semantics))))
    (is (= 1 (length sentinel-versions)))
    (is-true (ourro.reflex.proof:reflex-proof-valid-p
              (ourro.reflex.model:version-proof (first sentinel-versions))))))

(test immutable-versions-activate-exact-authority-and-rollback
  (let ((ourro.reflex.compiler:*version-registry* (make-hash-table :test #'equal))
        (ourro.reflex.compiler:*active-version-pointers* (make-hash-table :test #'equal)))
    (let* ((v1 (ourro.reflex.compiler:compile-reflex
                (ourro.reflex.model:definition-from-form
                 (fixture-reflex-form :version 1))))
           (v2 (ourro.reflex.compiler:compile-reflex
                (ourro.reflex.model:definition-from-form
                 (fixture-reflex-form :version 2)))))
      (ourro.reflex.compiler:install-reflex-version v1)
      (ourro.reflex.compiler:install-reflex-version v2)
      (signals error
        (ourro.reflex.compiler:activate-reflex-version
         'failed-job-briefing (ourro.reflex.model:version-hash v2)
         :approved-authority '(:observe :network)))
      (ourro.reflex.compiler:activate-reflex-version
       'failed-job-briefing (ourro.reflex.model:version-hash v2)
       :approved-authority '(:observe))
      (is (string= (ourro.reflex.model:version-hash v2)
                   (ourro.reflex.model:version-hash
                    (ourro.reflex.compiler:active-reflex-version
                     'failed-job-briefing))))
      (ourro.reflex.compiler:rollback-reflex-version
       'failed-job-briefing (ourro.reflex.model:version-hash v1))
      (is (string= (ourro.reflex.model:version-hash v1)
                   (ourro.reflex.model:version-hash
                    (ourro.reflex.compiler:active-reflex-version
                     'failed-job-briefing)))))))

(test coordinator-extends-reflex-gene-proof
  (let ((ourro.verify.coordinator:*containment-mode-override* :read-only)
        (source
          "(defgene auto/compiled-fixture
             (:generation 1 :parent nil :capabilities (:automate :observe)
              :provenance (:test t))
             (:doc \"compiled reflex fixture\")
             (:code
              (define-reflex failed-job-briefing
                (:identity (:version 1 :workspace :current
                            :capabilities (:observe)))
                (:trigger (:kind :job-exit :outcome :error))
                (:guards ())
                (:state (:version 1 :initial-step :notify))
                (:workflow ((:id :notify :activity :notify
                             :input (:text \"job failed\") :next :done)))
                (:policy (:approval :required))))
             (:tests (test compiled-fixture/shape (is-true t))))"))
    (multiple-value-bind (gene report)
        (ourro.verify.coordinator:verify-source source :persist nil)
      (declare (ignore gene))
      (is (= 1 (length (getf report :reflex-proofs))))
      (is-true (ourro.reflex.proof:reflex-proof-valid-p
                (first (getf report :reflex-proofs))))
      (is-true (assoc :reflex-lowering (getf report :stages))))))
