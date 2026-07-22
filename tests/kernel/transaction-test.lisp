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

