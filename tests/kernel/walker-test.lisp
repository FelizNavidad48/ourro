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

(test rejects-sb-packages
  (is (lint '((defun p () (sb-posix:getpid))))))

(test utility-summary-requires-observe
  ;; The evolution HUD gene reads the ledger via UTILITY-SUMMARY (M7-3); the
  ;; walker requires the :observe capability for it, matched by symbol name.
  (is (null (lint '((defun h () (utility-summary))) '(:observe))))
  (is (lint '((defun h () (utility-summary))) '())))

(test rejects-unknown-capability
  (is (lint '((defun ok () 1)) '(:nonexistent-capability))))

(test rejects-random-nondeterminism
  ;; RANDOM is barred anywhere in gene code — learned behavior must be
  ;; reproducible (PR-13, M5-2). Even fully qualified.
  (is (lint '((defun r () (random 100)))))
  (is (lint '((defun r () (cl:random 100)))))
  (is (lint '((defun r () (make-random-state t))))))

(test rejects-dynamic-qualified-capability-bypass
  ;; The concrete exploit from the quality-control review: discover the CL
  ;; symbol at runtime, then invoke it without spelling DELETE-FILE in source.
  (is (lint '((defun escape (path)
               (cl:funcall
                (cl:find "DELETE-FILE" (cl:apropos-list "DELETE-FILE")
                         :key #'cl:symbol-name :test #'cl:string=)
                path)))
            '()))
  ;; Raw tool registry invocation is confined to staged gene tests.
  (is (lint '((defun escape () (run-tool (find-tool "shell") nil))) '()))
  (is (null (ourro.kernel:lint-gene-body
             '((run-tool (find-tool "own_tool") nil))
             :capabilities '() :allow-test-helpers t))))

(test rejects-fully-qualified-trusted-product-internals
  (is (lint '((ourro.txn:append-wal-record "/tmp/forged.wal" nil)) '()))
  (is (lint '((ourro.observe::log-event :forged)) '(:observe)))
  ;; The boundary is positive, not merely a product-package denylist: a
  ;; third-party client cannot be invoked directly to evade CAP/HTTP-REQUEST.
  (is (lint '((dexador:request "https://example.invalid")) '(:network)))
  ;; Public API symbols retain their defining package as their home package;
  ;; the positive boundary must recognize the exact OURRO.API re-export.
  (is (null (lint '((ourro.observe:recent-events :limit 1)) '(:observe)))))
