(in-package #:ourro.tests)

(def-suite walker-suite :in ourro)
(in-suite walker-suite)

(defun lint (forms &optional capabilities)
  (ourro.kernel:lint-gene-body forms :capabilities capabilities))

(test clean-code-passes
  (is (null (lint '((defun add (a b) (+ a b)))))))

(test rejects-eval
  (is (lint '((defun evil (x) (eval x))))))

(test rejects-raw-delete-file
  (is (lint '((defun evil () (delete-file "/etc/passwd"))))))

(test rejects-intern
  (is (lint '((defun sneaky (s) (intern s :cl-user))))))

(test capability-required-for-write
  ;; cap/write-file with :filesystem-write declared → clean.
  (is (null (lint '((defun w (p c) (cap/write-file p c)))
                  '(:filesystem-write))))
  ;; cap/write-file without it → violation.
  (is (lint '((defun w (p c) (cap/write-file p c))) '())))

(test capability-required-for-subprocess
  (is (null (lint '((defun r (cmd) (cap/run-program cmd))) '(:subprocess))))
  (is (lint '((defun r (cmd) (cap/run-program cmd))) '(:filesystem-read))))

