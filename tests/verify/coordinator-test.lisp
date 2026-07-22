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

