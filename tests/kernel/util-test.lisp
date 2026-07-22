(in-package #:ourro.tests)

(def-suite util-suite :in ourro)
(in-suite util-suite)

(test readable-roundtrip
  (let* ((form (list :a 1 "two" (list :nested 3.5d0)))
         (text (ourro.util:print-readable-to-string form))
         (back (ourro.util:read-safe-from-string text)))
    (is (equal form back))))

(test run-command-returns-output
  (is (string= "hi" (ourro.util:run-command (list "printf" "hi")))))

(test run-command-enforces-timeout
  ;; A child that outlives :TIMEOUT is killed and COMMAND-FAILED signaled — the
  ;; timeout is enforced, not advisory. Without this a hung child (e.g. an old
  ;; image that boots its TUI on an --replay flag it predates and SIGTTOU-stops)
  ;; wedges the supervisor forever. Guard the assertion with a wall-clock bound
  ;; so a regression to the blocking path fails loudly instead of hanging CI.
  (let ((start (get-internal-real-time)))
    (signals ourro.util:command-failed
      (ourro.util:run-command (list "sleep" "30") :timeout 1))
    (let ((elapsed (/ (- (get-internal-real-time) start)
                      internal-time-units-per-second)))
      (is-true (< elapsed 10)))))

(test read-safe-no-eval
  ;; #. must not evaluate under read-safe.
  (signals error (ourro.util:read-safe-from-string "#.(+ 1 2)")))

