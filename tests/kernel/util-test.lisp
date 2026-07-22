(in-package #:ourro.tests)

(def-suite util-suite :in ourro)
(in-suite util-suite)

(test readable-roundtrip
  (let* ((form (list :a 1 "two" (list :nested 3.5d0)))
         (text (ourro.util:print-readable-to-string form))
         (back (ourro.util:read-safe-from-string text)))
    (is (equal form back))))

(test getenv-falls-back-to-legacy-ouro-prefix
  ;; After the ouroboros→ourro rename, an OURRO_* lookup transparently falls
  ;; back to the legacy OURO_* spelling (one fewer R), so a shell that still
  ;; exports OURO_BEDROCK_API_KEY etc. keeps working.
  (unwind-protect
       (progn
         (sb-posix:setenv "OURO_ZZ_LEGACY_TEST" "legacy-hit" 1)
         ;; The OURRO_* form is unset → the legacy OURO_* value is used.
         (is (string= "legacy-hit"
                      (ourro.util:getenv "OURRO_ZZ_LEGACY_TEST")))
         ;; A non-OURRO_ name is read verbatim — no fallback games.
         (is (null (ourro.util:getenv "ZZ_LEGACY_TEST")))
         ;; An explicit OURRO_* value wins over the legacy one.
         (sb-posix:setenv "OURRO_ZZ_LEGACY_TEST" "new-hit" 1)
         (is (string= "new-hit"
                      (ourro.util:getenv "OURRO_ZZ_LEGACY_TEST"))))
    (ignore-errors (sb-posix:unsetenv "OURO_ZZ_LEGACY_TEST"))
    (ignore-errors (sb-posix:unsetenv "OURRO_ZZ_LEGACY_TEST"))))

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

(test plist-put-is-fresh
  (let* ((a (list :x 1))
         (b (ourro.util:plist-put a :y 2)))
    (is (equal (list :x 1) a))
    (is (= 2 (getf b :y)))))

(test string-helpers
  (is (ourro.util:string-prefix-p "foo" "foobar"))
  (is (ourro.util:string-suffix-p "bar" "foobar"))
  (is (string= "a,b,c" (ourro.util:string-join "," '("a" "b" "c")))))

(test sexp-file-roundtrip
  (let ((path (merge-pathnames "ourro-util-test.sexp"
                               (uiop:temporary-directory)))
        (form (list :hello "world" :n 42)))
    (ourro.util:write-sexp-file path form)
    (is (equal form (ourro.util:read-sexp-file path)))
    (ignore-errors (delete-file path))))

(test append-sexp-line
  (let ((path (merge-pathnames "ourro-append-test.sexp"
                               (uiop:temporary-directory))))
    (ignore-errors (delete-file path))
    (ourro.util:append-sexp-line path '(:a 1))
    (ourro.util:append-sexp-line path '(:b 2))
    (with-open-file (in path)
      (is (equal '(:a 1) (ourro.util:read-safe in)))
      (is (equal '(:b 2) (ourro.util:read-safe in))))
    (ignore-errors (delete-file path))))
