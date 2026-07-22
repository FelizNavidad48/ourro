(in-package #:ourro.tests)

(def-suite transaction-suite :in ourro)
(in-suite transaction-suite)

(defmacro with-transaction-home (&body body)
  `(let* ((home (merge-pathnames
                 (format nil "ourro-txn-test-~A/" (ourro.util:make-id "h"))
                 (uiop:temporary-directory)))
          (ourro.util::*ourro-home* (uiop:ensure-directory-pathname home)))
     (ensure-directories-exist home)
     (unwind-protect (progn ,@body)
       (ignore-errors
        (uiop:delete-directory-tree (uiop:ensure-directory-pathname home)
                                    :validate (constantly t))))))

(test sha256-known-vectors
  (is (string=
       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
       (ourro.txn:sha256-string "")))
  (is (string=
       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
       (ourro.txn:sha256-string "abc"))))

(test canonical-codec-round-trips-supported-data
  (let* ((table (make-hash-table :test #'equal))
         (value (list :name "reflex/test" :count 42 :ratio 2/3
                      :float -1.25d0 :character #\λ
                      :vector (vector 1 "two")
                      :symbol 'cl:+ :map table)))
    (setf (gethash "b" table) 2
          (gethash "a" table) 1)
    (let ((decoded (ourro.txn:canonical-decode
                    (ourro.txn:canonical-encode value))))
      (is (equalp (subseq value 0 12) (subseq decoded 0 12)))
      (is (equalp (getf value :vector) (getf decoded :vector)))
      (is (= 1 (gethash "a" (getf decoded :map))))
      (is (= 2 (gethash "b" (getf decoded :map)))))))

(test canonical-map-order-is-stable
  (let ((left (make-hash-table :test #'equal))
        (right (make-hash-table :test #'equal)))
    (setf (gethash "a" left) 1 (gethash "b" left) 2
          (gethash "b" right) 2 (gethash "a" right) 1)
    (is (string= (ourro.txn:canonical-hash left)
                 (ourro.txn:canonical-hash right)))))

(test wal-batch-append-preserves-frame-order
  (with-transaction-home
    (let ((path (ourro.util:ourro-path "state" "batch.wal"))
          (records '((:id "one") (:id "two") (:id "three"))))
      (is (equal records (ourro.txn:append-wal-record-batch path records)))
      (multiple-value-bind (read health) (ourro.txn:read-wal path)
        (is (eq :ok health))
        (is (equal records read))))))

(test canonical-codec-rejects-cycles-and-uninterned-symbols
  (let ((cycle (list :x)))
    (setf (cdr cycle) cycle)
    (signals ourro.txn:canonical-encoding-error
      (ourro.txn:canonical-encode cycle)))
  (signals ourro.txn:canonical-encoding-error
    (ourro.txn:canonical-encode (make-symbol "NOT-DURABLE"))))

(test canonical-codec-distinguishes-wide-data-from-deep-data
  (let* ((wide (loop for index below 2000 collect index))
         (decoded (ourro.txn:canonical-decode (ourro.txn:canonical-encode wide))))
    (is (equal wide decoded)))
  (let ((ourro.txn:*max-canonical-depth* 8))
    (signals ourro.txn:canonical-encoding-error
      (ourro.txn:canonical-encode
       (loop with value = :leaf
             repeat 12 do (setf value (list value))
             finally (return value))))))

(test wal-round-trip-and-torn-tail-recovery
  (with-transaction-home
    (let ((path (ourro.util:ourro-path "state" "test.wal")))
      (ourro.txn:append-wal-record path '(:id "one" :status :prepared))
      (ourro.txn:append-wal-record path '(:id "two" :status :verified))
      (multiple-value-bind (records health) (ourro.txn:read-wal path)
        (is (eq :ok health))
        (is (equal '((:id "one" :status :prepared)
                     (:id "two" :status :verified))
                   records)))
      ;; A crash can leave an incomplete final header. Recovery discards only
      ;; those bytes and preserves both committed records.
      (with-open-file (out path :direction :output :if-exists :append
                                :element-type '(unsigned-byte 8))
        (write-sequence (sb-ext:string-to-octets "OURRO-TXN/1 20"
                                                :external-format :utf-8)
                        out))
      (multiple-value-bind (records health) (ourro.txn:recover-wal path)
        (is (eq :torn-tail health))
        (is (= 2 (length records))))
      (multiple-value-bind (records health) (ourro.txn:read-wal path)
        (is (eq :ok health))
        (is (= 2 (length records)))))))

(test wal-interior-corruption-is-visible
  (with-transaction-home
    (let ((path (ourro.util:ourro-path "state" "bad.wal")))
      (ourro.txn:append-wal-record path '(:id "one" :status :prepared))
      (ourro.txn:append-wal-record path '(:id "two" :status :verified))
      (with-open-file (io path :direction :io :if-exists :overwrite
                              :element-type '(unsigned-byte 8))
        ;; Flip a payload byte in the first complete frame.
        (let ((newline (loop for byte = (read-byte io)
                             for i from 0
                             when (= byte (char-code #\Newline)) return i)))
          (file-position io (1+ newline))
          (write-byte (logxor (read-byte io) 1) io)))
      (signals ourro.txn:wal-corruption (ourro.txn:read-wal path))
      (is (eq :degraded (getf (ourro.txn:wal-health path) :status))))))

(test wal-recovers-after-every-byte-of-a-tail-frame-write
  (with-transaction-home
    (let ((complete (ourro.util:ourro-path "state" "complete.wal"))
          (first-only (ourro.util:ourro-path "state" "first.wal"))
          (crashed (ourro.util:ourro-path "state" "crashed.wal")))
      (ourro.txn:append-wal-record first-only '(:id "one" :status :committed))
      (ourro.txn:append-wal-record complete '(:id "one" :status :committed))
      (ourro.txn:append-wal-record complete '(:id "two" :status :committed))
      (let* ((bytes (ourro.txn::read-file-octets complete))
             (first-length
               (with-open-file (in first-only :direction :input
                                              :element-type '(unsigned-byte 8))
                 (file-length in))))
        (loop for cut from first-length below (length bytes) do
          (with-open-file (out crashed :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create
                                  :element-type '(unsigned-byte 8))
            (write-sequence bytes out :end cut))
          (multiple-value-bind (records health) (ourro.txn:recover-wal crashed)
            (is (eq (if (= cut first-length) :ok :torn-tail) health))
            (is (equal '((:id "one" :status :committed)) records))))
        (with-open-file (out crashed :direction :output
                                :if-exists :supersede
                                :element-type '(unsigned-byte 8))
          (write-sequence bytes out))
        (multiple-value-bind (records health) (ourro.txn:recover-wal crashed)
          (is (eq :ok health))
          (is (= 2 (length records))))))))

(test verification-artifact-is-self-authenticating-and-immutable
  (with-transaction-home
    (let* ((artifact (ourro.txn:make-verification-artifact
                      :transaction-id "verify-1"
                      :source "(defgene test)"
                      :authority '(:filesystem-read)
                      :fingerprints '(:sbcl "test")
                      :stages '((:read :ok) (:lint :ok))))
           (path (ourro.txn:persist-verification-artifact artifact)))
      (is-true (ourro.txn:verification-artifact-valid-p artifact))
      (is (probe-file path))
      (is (ourro.txn:canonical-equal artifact
                                    (ourro.txn:read-verification-artifact path)))
      (let ((tampered (ourro.util:plist-put artifact :authority '(:network))))
        (is-false (ourro.txn:verification-artifact-valid-p tampered))))))

(test lifecycle-attestation-is-self-authenticating
  (let ((record (ourro.txn:make-lifecycle-attestation
                 :transaction-id "tx-1" :version-hash "version"
                 :proof-hash "proof" :prior-status :prepared
                 :status :verified :actor "verifier" :time 1)))
    (is-true (ourro.txn:lifecycle-attestation-valid-p record))
    (is-false
     (ourro.txn:lifecycle-attestation-valid-p
      (ourro.util:plist-put record :status :active)))))
