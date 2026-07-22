(in-package #:ourro.tests)

(def-suite coordinator-suite :in ourro)
(in-suite coordinator-suite)

(test coordinator-produces-and-persists-one-proof
  (with-transaction-home
    (multiple-value-bind (gene report)
        (ourro.verify.coordinator:verify-source +good-gene+)
      (declare (ignore gene))
      (let* ((proof (ourro.verify.coordinator:proof-for-report report))
             (path (ourro.txn:verification-artifact-path
                    (getf report :proof-hash))))
        (is-true (ourro.verify.coordinator:authoritative-pass-report-p
                  report +good-gene+))
        (is-true (ourro.txn:verification-artifact-valid-p proof))
        (is (probe-file path)))
      (multiple-value-bind (records health)
          (ourro.txn:read-wal
           (ourro.verify.coordinator:verification-wal-path))
        (is (eq :ok health))
        (is (= 2 (length records)))
        (is (equal '(:prepared :verified)
                   (mapcar (lambda (record) (getf record :status)) records)))
        (is (string= (getf (first records) :transaction-id)
                     (getf (second records) :transaction-id)))))))

(test coordinator-records-failed-verification-without-proof
  (with-transaction-home
    (signals ourro.kernel:verification-failure
      (ourro.verify.coordinator:verify-source "(not-a-gene)"))
    (multiple-value-bind (records health)
        (ourro.txn:read-wal
         (ourro.verify.coordinator:verification-wal-path))
      (is (eq :ok health))
      (is (equal '(:prepared :verification-failed)
                 (mapcar (lambda (record) (getf record :status)) records)))
      (is (eq :read (getf (second records) :stage))))))

(test coordinator-can-run-without-persistence-for-hermetic-staging
  (with-transaction-home
    (multiple-value-bind (gene report)
        (ourro.verify.coordinator:verify-source +good-gene+ :persist nil)
      (declare (ignore gene))
      (is-true (ourro.verify.coordinator:authoritative-pass-report-p
                report +good-gene+))
      (is-false (probe-file
                 (ourro.verify.coordinator:verification-wal-path))))))

(test coordinator-adopts-child-proof-once
  (with-transaction-home
    (multiple-value-bind (gene report)
        (ourro.verify.coordinator:verify-source +good-gene+ :persist nil)
      (declare (ignore gene))
      (let ((path (ourro.txn:verification-artifact-path
                   (getf report :proof-hash))))
        (is-false (probe-file path))
        (ourro.verify.coordinator:adopt-authoritative-report
         report +good-gene+)
        (ourro.verify.coordinator:adopt-authoritative-report
         report +good-gene+)
        (is (probe-file path))
        (multiple-value-bind (records health)
            (ourro.txn:read-wal
             (ourro.verify.coordinator:verification-wal-path))
          (is (eq :ok health))
          (is (= 1 (length records)))
          (is (eq :verified-external (getf (first records) :status))))))))

(test coordinator-rejects-report-transaction-mismatch
  (with-transaction-home
    (multiple-value-bind (gene report)
        (ourro.verify.coordinator:verify-source +good-gene+ :persist nil)
      (declare (ignore gene))
      (is-false
       (ourro.verify.coordinator:authoritative-pass-report-p
        (ourro.util:plist-put report :transaction-id "different")
        +good-gene+)))))

(test coordinator-reports-read-only-containment
  (with-transaction-home
    (let ((ourro.verify.coordinator:*containment-mode-override* :read-only))
      (multiple-value-bind (gene report)
          (ourro.verify.coordinator:verify-source +good-gene+ :persist nil)
        (declare (ignore gene))
        (is (eq :read-only
                (getf (getf report :containment) :mode)))
        (is-true (assoc :containment (getf report :stages)))))))

(test coordinator-canonicalizes-disposable-package-automation-names
  (with-transaction-home
    (let ((source
            "(defgene auto/coordinator-receipt
                (:generation 1 :capabilities (:automate :observe))
               (:doc \"Read-only declarative automation proof fixture.\")
               (:code
                (define-automation coordinator-receipt
                    (:on (:kind :probe) :cooldown 1)
                  (post-note \"probe observed\" :style :info)))
               (:tests
                (test coordinator-receipt/t (is-true t))))"))
      (multiple-value-bind (gene report)
          (ourro.verify.coordinator:verify-source source :persist nil)
        (declare (ignore gene))
        (is-true (ourro.verify.coordinator:authoritative-pass-report-p
                  report source))
        (is (= 1 (length (pget report :reflex-proofs))))
        (is-true (ourro.reflex.proof:reflex-proof-valid-p
                  (first (pget report :reflex-proofs))))
        (is-true (ourro.txn:verification-artifact-valid-p
                  (pget report :verification-artifact)))))))

(test coordinator-transports-deep-onboarding-proof-without-duplicating-report
  (with-transaction-home
    (let* ((root (asdf:system-source-directory "ourro"))
           (source (uiop:read-file-string
                    (merge-pathnames
                     "seed-genome/genes/auto/onboard-new-repo.gene" root))))
      (multiple-value-bind (gene report)
          (ourro.verify.coordinator:verify-source source :persist nil)
        (declare (ignore gene))
        (let* ((encoded
                 (ourro.verify.coordinator:encode-report-for-transport report))
               (restored
                 (ourro.verify.coordinator:decode-report-from-transport encoded)))
          (is-true (ourro.verify.coordinator:authoritative-pass-report-p
                    restored source))
          (is (equal (pget report :stages) (pget restored :stages)))
          (is (equal (pget report :test-report)
                     (pget restored :test-report)))
          (is (= (length (pget report :reflex-proofs))
                 (length (pget restored :reflex-proofs)))))))))

(test coordinator-report-envelope-fails-closed-on-identity-or-artifact-tampering
  (with-transaction-home
    (multiple-value-bind (gene report)
        (ourro.verify.coordinator:verify-source +good-gene+ :persist nil)
      (declare (ignore gene))
      (let* ((encoded
               (ourro.verify.coordinator:encode-report-for-transport report))
             (envelope (ourro.txn:canonical-decode encoded)))
        (signals error
          (ourro.verify.coordinator:decode-report-from-transport
           (ourro.txn:canonical-encode
            (ourro.util:plist-put envelope :transaction-id "substituted"))))
        (signals error
          (ourro.verify.coordinator:decode-report-from-transport
           (ourro.txn:canonical-encode
            (ourro.util:plist-put envelope :proof-hash "substituted"))))
        (signals error
          (ourro.verify.coordinator:decode-report-from-transport
           (ourro.txn:canonical-encode
            (ourro.util:plist-put envelope :artifact "not-canonical"))))
        (signals error
          (ourro.verify.coordinator:decode-report-from-transport nil))))))

(test coordinator-refuses-effectful-source-before-execution
  (with-transaction-home
    (let ((ourro.verify.coordinator:*containment-mode-override* :read-only))
      (handler-case
          (progn
            (ourro.verify.coordinator:verify-source
             "(defgene tool/effectful
                (:generation 1 :capabilities (:filesystem-write))
               (:doc \"Must be rejected before staged execution.\")
               (:code (defun effectful-helper () nil))
               (:tests (test effectful/t (is-true t))))")
            (fail "effectful source unexpectedly passed"))
        (ourro.kernel:verification-failure (failure)
          (is (eq :containment
                  (ourro.kernel:verification-failure-stage failure)))))
      (multiple-value-bind (records health)
          (ourro.txn:read-wal
           (ourro.verify.coordinator:verification-wal-path))
        (is (eq :ok health))
        (is (equal '(:prepared :verification-failed)
                   (mapcar (lambda (record) (getf record :status)) records)))
        (is (eq :containment (getf (second records) :stage)))))))

(test coordinator-treats-model-calls-as-network-authority
  (is-true (ourro.verify.coordinator:effectful-authority-p '(:llm)))
  (is-false
   (ourro.verify.coordinator:effectful-authority-p
    '(:filesystem-read :observe :automate))))
