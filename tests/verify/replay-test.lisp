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

(test kernel-gene-cannot-be-applied
  ;; Even if a candidate somehow verified, apply-candidate refuses kernel
  ;; references (defense in depth over the walker).
  (let ((candidate (make-instance 'ourro.evolve:evolution-candidate
                                  :pattern '(:id "k")
                                  :status :verified
                                  :source "(defgene x (:generation 2) (:code (defun q () ourro.kernel::foo)))")))
    (setf (ourro.evolve:candidate-status candidate) :verified)
    (ourro.evolve:apply-candidate candidate :force t)
    (is (eq :rejected (ourro.evolve:candidate-status candidate)))))

(test replay-session-skips-effectful-tools
  ;; Only read-ish tools are replayed; a shell event is skipped.
  (let ((events (list (list :kind :tool-call :tool "shell"
                            :args '(:command "rm -rf /"))
                      (list :kind :tool-call :tool "list_files"
                            :args '(:pattern "*.nonexistent")))))
    (let ((ourro.toolkit:*workspace* (uiop:temporary-directory)))
      (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
        (let ((traces (ourro.verify:replay-session events)))
          ;; Only the list_files call replayed.
          (is (= 1 (length traces)))
          (is (string= "list_files" (getf (first traces) :tool))))))))
