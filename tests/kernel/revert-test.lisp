(in-package #:ourro.tests)

(def-suite revert-suite :in ourro)
(in-suite revert-suite)

;; A gene that redefines an existing function; hot-load then revert.
(defun ourro-revert-target () :original)
(defparameter *qc-revert-value* :old)
(defclass qc-revert-class () ((x :initform 1 :accessor qc-revert-x)))

(test hot-load-then-revert-function
  (let ((gene-source
          "(defgene test/redefiner
             (:generation 3 :capabilities ())
           (:doc \"Redefines a target function for revert testing.\")
           (:code
            (defun ourro.tests::ourro-revert-target () :evolved))
           (:tests (test redefiner/t (is-true t))))"))
    (declare (ignore gene-source))
    ;; Do it directly through kernel revert machinery (hot-load compiles in
    ;; OURRO.GENES; instead test the revert table primitive directly).
    (is (eq :original (ourro-revert-target)))
    (ourro.kernel:record-function-definition "test/redef" 'ourro-revert-target)
    (setf (fdefinition 'ourro-revert-target) (lambda () :evolved))
    (is (eq :evolved (ourro-revert-target)))
    (is (= 1 (ourro.kernel:revert-gene-definitions "test/redef")))
    (is (eq :original (ourro-revert-target)))))

(test probation-reverts-on-failure
  (let ((reverted nil))
    (ourro.kernel:record-function-definition "test/prob" 'ourro-revert-target)
    (setf (fdefinition 'ourro-revert-target) (lambda () (error "boom")))
    (ourro.kernel:start-probation "test/prob" 3)
    (let ((ourro.kernel:*probation-failure-hook*
            (lambda (name c) (declare (ignore name c)) (setf reverted t))))
      (signals ourro.kernel:evolved-code-failure
        (ourro.kernel:with-probation ("test/prob")
          (ourro-revert-target))))
    (is-true reverted)
    ;; After revert, the original definition is restored.
    (is (eq :original (ourro-revert-target)))))

(test probation-graduates-on-success
  (ourro.kernel:start-probation "test/grad" 2)
  (is (= 2 (ourro.kernel::probation-remaining "test/grad")))
  (ourro.kernel:with-probation ("test/grad") 1)
  (is (= 1 (ourro.kernel::probation-remaining "test/grad")))
  (ourro.kernel:with-probation ("test/grad") 1)
  (is (= 0 (ourro.kernel::probation-remaining "test/grad"))))

(test gene-snapshot-restores-variable-and-class-shape
  (let* ((source
           "(defgene test/class-transaction
                (:generation 1 :capabilities ())
              (:doc \"transaction fixture\")
              (:code
               (defparameter ourro.tests::*qc-revert-value* :new)
               (defclass ourro.tests::qc-revert-class ()
                 ((y :initform 2 :accessor ourro.tests::qc-revert-y))))
              (:tests (test class-transaction/t (is-true t))))")
         (gene (ourro.genome:parse-gene-source source))
         (instance (make-instance 'qc-revert-class)))
    (setf *qc-revert-value* :old)
    (ourro.genome::snapshot-gene-targets gene)
    (setf *qc-revert-value* :new)
    (sb-mop:ensure-class
     'qc-revert-class :direct-superclasses (list (find-class t))
     :direct-slots (list (list :name 'y :initform 2
                               :initfunction (constantly 2)
                               :readers '(qc-revert-y))))
    (is (eq :new *qc-revert-value*))
    (ourro.kernel:revert-gene-definitions "test/class-transaction")
    (is (eq :old *qc-revert-value*))
    (is (= 1 (qc-revert-x instance)))
    (is (find 'x (sb-mop:class-direct-slots (find-class 'qc-revert-class))
              :key #'sb-mop:slot-definition-name))))
