(in-package #:ourro.tests)

(def-suite replay-suite :in ourro)
(in-suite replay-suite)

(test learned-tool-is-deterministic
  ;; PR-13: a learned tool runs byte-identically with zero LLM calls.
  (let ((ourro.toolkit:*workspace* (uiop:temporary-directory)))
    (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
      (let ((path (merge-pathnames "ourro-det-test.txt"
                                   (uiop:temporary-directory))))
        (with-open-file (out path :direction :output :if-exists :supersede)
          (write-string (format nil "a~%b~%c~%") out))
        (multiple-value-bind (deterministic-p results)
            (ourro.verify:verify-determinism
             "read_file"
             (ourro.llm:json-object "path" (namestring path))
             :runs 10)
          (is-true deterministic-p)
          (is (= 10 (length results))))
        (ignore-errors (delete-file path))))))

(test kernel-touching-detected
  (is-true (ourro.verify:kernel-touching-p
            "(defun x () (ourro.kernel::record-function-definition 1 2))"))
  (is-true (ourro.verify:kernel-touching-p "references ourro.supervisor here"))
  (is-false (ourro.verify:kernel-touching-p
             "(defun add (a b) (+ a b))")))

