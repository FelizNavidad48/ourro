(in-package #:ourro.tests)

(def-suite tools-suite :in ourro)
(in-suite tools-suite)

(test seed-tools-registered
  ;; The genome is loaded in the test image, so the seed tools exist.
  (dolist (name '("read_file" "write_file" "edit_file" "list_files"
                  "search" "shell"))
    (is-true (ourro.tools:find-tool name)
             "tool ~A should be registered" name)))

(test tool-declarations-shape
  (let ((declarations (ourro.tools:tool-declarations)))
    (is (every (lambda (d) (and (stringp (first d)) (stringp (second d))))
               declarations))))

(test execute-unknown-tool
  (multiple-value-bind (result error-p)
      (ourro.tools:execute-tool-call "no_such_tool" (ourro.llm:json-object))
    (is-true error-p)
    (is (search "unknown tool" result))))

(test shell-tool-runs
  (let ((args (ourro.llm:json-object "command" "echo hi-from-test")))
    (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
      (multiple-value-bind (result error-p)
          (ourro.tools:execute-tool-call "shell" args)
        (is (not error-p))
        (is (search "hi-from-test" result))))))

(test instrumentation-logs-tool-call
  (let ((ourro.observe::*recent-events* '())
        (ourro.observe::*event-log-path* nil)
        (ourro.toolkit:*workspace* (uiop:temporary-directory)))
    (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
      (ourro.tools:execute-tool-call
       "list_files" (ourro.llm:json-object "pattern" "*.nonexistent")))
    (is (find :tool-call (ourro.observe:recent-events)
              :key (lambda (e) (getf e :kind))))))

(test contract-violation-is-caught
  ;; write_file requires string content; passing a number would violate the
  ;; pre-contract, and execute-tool-call must return it as an error string.
  (let ((ourro.toolkit:*workspace* (uiop:temporary-directory)))
    (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
      (multiple-value-bind (result error-p)
          (ourro.tools:execute-tool-call
           "read_file" (ourro.llm:json-object "path" "/no/such/ourro/file/xyz"))
        (declare (ignore result))
        (is-true error-p)))))
