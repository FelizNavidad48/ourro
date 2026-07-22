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

