(in-package #:ourro.tests)

(def-suite safe-read-suite :in ourro)
(in-suite safe-read-suite)

(test reads-plain-form
  ;; Symbols intern into the given package, so compare by structure/name.
  (let ((form (ourro.kernel:safe-read-form "(defun foo (x) x)"
                                          :package (find-package :ourro.util))))
    (is (string= "DEFUN" (symbol-name (first form))))
    (is (string= "FOO" (symbol-name (second form))))
    (is (equal '("X") (mapcar #'symbol-name (third form))))))

(test rejects-read-eval
  (signals ourro.kernel:unsafe-form-error
    (ourro.kernel:safe-read-form "#.(delete-file \"x\")")))

(test rejects-second-form
  (signals ourro.kernel:unsafe-form-error
    (ourro.kernel:safe-read-form "(a) (b)")))

(test rejects-too-deep
  (let ((ourro.kernel:*max-form-depth* 5))
    (signals ourro.kernel:unsafe-form-error
      (ourro.kernel:safe-read-form "(((((((((1)))))))))"))))

(test rejects-too-large
  (let ((ourro.kernel:*max-form-atoms* 10))
    (signals ourro.kernel:unsafe-form-error
      (ourro.kernel:safe-read-form
       (format nil "(~{~A ~})" (loop for i below 50 collect i))))))

(test interns-into-given-package
  (let ((form (ourro.kernel:safe-read-form "(brand-new-symbol-xyz 1)"
                                          :package (find-package :ourro.genes))))
    (is (eq (symbol-package (first form)) (find-package :ourro.genes)))))
