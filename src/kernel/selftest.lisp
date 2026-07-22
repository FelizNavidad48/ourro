
(in-package #:ourro.kernel)

(fiveam:def-suite kernel-selftest
  :description "Load-bearing safety-kernel invariants, checked in every image.")

(fiveam:in-suite kernel-selftest)


(fiveam:test selftest-safe-read-rejects-read-eval
  (fiveam:signals unsafe-form-error (safe-read-form "#.(+ 1 2)")))

(fiveam:test selftest-safe-read-rejects-depth-bomb
  (let ((bomb (concatenate 'string
                           (make-string 200 :initial-element #\()
                           (make-string 200 :initial-element #\)))))
    (fiveam:signals unsafe-form-error (safe-read-form bomb))))

(fiveam:test selftest-safe-read-accepts-plain-form
  (fiveam:is (equal '(+ 1 2) (safe-read-form "(+ 1 2)" :package :ourro.util))))


(fiveam:test selftest-walker-rejects-uncapped-effect
  ;; A raw filesystem primitive named anywhere in gene code is a violation.
  (fiveam:is-true (lint-gene-body '((open "x")) :capabilities '())))

(fiveam:test selftest-walker-rejects-uncapped-subprocess
  ;; cap/run-program without :subprocess declared.
  (fiveam:is-true (lint-gene-body '((cap/run-program (list "ls")))
                                  :capabilities '())))

(fiveam:test selftest-walker-rejects-kernel-reference
  ;; A kernel-internal symbol (not on the CAP/* allowlist) is forbidden even
  ;; with every capability declared — the kernel is out of the genome's reach.
  (fiveam:is-true (lint-gene-body '((revert-gene-definitions "x"))
                                  :capabilities +all-capabilities+)))

(fiveam:test selftest-walker-accepts-declared-effect
  (fiveam:is-false (lint-gene-body '((cap/read-file "x"))
                                   :capabilities '(:filesystem-read))))


(fiveam:test selftest-revert-round-trip
  (let ((reverted nil)
        (gene "selftest/revert"))
    (record-revert-action gene (lambda () (setf reverted t)))
    (fiveam:is (= 1 (revert-record-count gene)))
    (fiveam:is (= 1 (revert-gene-definitions gene)))
    (fiveam:is-true reverted)
    (fiveam:is (= 0 (revert-record-count gene)))))


(fiveam:test selftest-probation-reverts-and-signals
  (let ((gene "selftest/probation")
        (fired nil))
    (let ((*probation-failure-hook*
            (lambda (name condition)
              (declare (ignore name condition))
              (setf fired t))))
      (start-probation gene 3)
      (fiveam:signals evolved-code-failure
        (with-probation (gene) (error "boom")))
      (fiveam:is-true fired)
      ;; The failure consumed probation — the counter is cleared.
      (fiveam:is (= 0 (probation-remaining gene))))))

(fiveam:test selftest-probation-success-decrements
  (let ((gene "selftest/probation-ok"))
    (start-probation gene 2)
    (fiveam:is (= 42 (with-probation (gene) 42)))
    (fiveam:is (= 1 (probation-remaining gene)))
    (clear-revert-records gene)))


(fiveam:test selftest-protocol-framing-survives-newlines
  (let* ((buffer (make-string-output-stream))
         (out (make-instance 'protocol-connection
                             :socket nil
                             :stream (make-two-way-stream
                                      (make-string-input-stream "") buffer)))
         (message (list :propose-generation
                        :changes (list (list :path "genes/x.gene"
                                             :content (format nil "(defgene~%  x)"))))))
    (protocol-send out message)
    (let ((in (make-instance 'protocol-connection
                            :socket nil
                            :stream (make-two-way-stream
                                     (make-string-input-stream
                                      (get-output-stream-string buffer))
                                     (make-broadcast-stream)))))
      (fiveam:is (equal message (protocol-receive in))))))


(fiveam:test selftest-capability-ceiling-clamps
  (let ((*capability-ceiling* '(:filesystem-read)))
    (with-capabilities '(:filesystem-read :filesystem-write :subprocess)
      (fiveam:is-true (member :filesystem-read *active-capabilities*))
      (fiveam:is-false (member :filesystem-write *active-capabilities*))
      (fiveam:signals capability-violation
        (require-capability :filesystem-write 'selftest)))))


(defun kernel-locked-p ()
  "T iff the OURRO.KERNEL package is locked. Built images lock it at
save-lisp-and-die time (scripts/build-agent-image.lisp); `make dev` and the test
suite stay unlocked so they can poke internals. Reported at --smoke time so each
built image self-confirms the hardened kernel (M8 kernel-path proof)."
  (let ((package (find-package "OURRO.KERNEL")))
    (and package (sb-ext:package-locked-p package) t)))

(defun run-kernel-selftest ()
  "Run the kernel self-test suite silently. Returns (values passed-p report).
Called at --smoke time so a base-core change that breaks a kernel invariant
fails the generation build instead of shipping."
  (let* ((results (let ((*standard-output* (make-broadcast-stream))
                        (*error-output* (make-broadcast-stream)))
                    (fiveam:run 'kernel-selftest)))
         (passed (fiveam:results-status results))
         (report (with-output-to-string (out)
                   (let ((*standard-output* out))
                     (ignore-errors (fiveam:explain! results))))))
    (values passed report)))
