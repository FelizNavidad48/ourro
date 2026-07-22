
(in-package #:ourro.tests)

(def-suite corrections-suite :in ourro)
(in-suite corrections-suite)


(test verbal-correction-table
  (flet ((classify (text) (ourro.observe:detect-verbal-correction text)))
    ;; substitution → :substitute "new|old"
    (let ((c (classify "use pnpm not npm")))
      (is (eq :substitute (first c)))
      (is (string= "pnpm|npm" (second c))))
    (let ((c (classify "please use ripgrep instead of grep here")))
      (is (eq :substitute (first c)))
      (is (string= "ripgrep|grep" (second c))))
    ;; plain negations → :verbal
    (is (eq :verbal (first (classify "no, that's the wrong file"))))
    (is (eq :verbal (first (classify "don't edit that one"))))
    (is (eq :verbal (first (classify "actually, revert that"))))
    ;; non-corrections → NIL
    (is-false (classify "please add a test for the parser"))
    (is-false (classify "great, thanks"))
    (is-false (classify ""))))

(test verbal-correction-confidence
  (multiple-value-bind (class conf) (ourro.observe:detect-verbal-correction "use a not b")
    (declare (ignore class))
    (is (eq :high conf)))
  (multiple-value-bind (class conf) (ourro.observe:detect-verbal-correction "no, stop")
    (declare (ignore class))
    (is (eq :medium conf))))

(test maybe-log-correction-requires-tool-activity
  (let ((ourro.observe::*recent-events* '())
        (ourro.observe::*event-log-path* nil))
    ;; No tool activity yet → a correction-looking message logs nothing.
    (ourro.observe:maybe-log-correction "no, use pnpm not npm")
    (is (null (ourro.observe:recent-events :kind :correction)))
    ;; After a tool call, the same message is captured.
    (ourro.observe:log-event :tool-call :tool "shell" :outcome :ok)
    (ourro.observe:maybe-log-correction "no, use pnpm not npm")
    (let ((corrections (ourro.observe:recent-events :kind :correction)))
      (is (= 1 (length corrections)))
      (is (equal '(:substitute "pnpm|npm")
                 (getf (first corrections) :class)))
      (is (string= "shell" (getf (first corrections) :ref-tool))))))


(defun user-ev (text) (list :kind :user-message :text text))
(defun call-ev (tool &rest args)
  (list :kind :tool-call :outcome :ok :tool tool :args args))

(test rework-same-file-detection
  ;; turn 1: edit foo.py; turn 2 opens with a negation and re-edits foo.py.
  (let ((events (list (user-ev "edit the config")
                      (call-ev "edit_file" :path "foo.py")
                      (user-ev "no, that broke it, fix foo.py")
                      (call-ev "edit_file" :path "foo.py"))))
    (let ((class (ourro.observe:detect-rework-file events)))
      (is (eq :rework-file (first class)))
      (is (equal "py" (second class)))))
  ;; No negation → no detection.
  (let ((events (list (user-ev "edit the config")
                      (call-ev "edit_file" :path "foo.py")
                      (user-ev "now also tweak foo.py")
                      (call-ev "edit_file" :path "foo.py"))))
    (is-false (ourro.observe:detect-rework-file events))))

(test command-preference-detection
  (let ((events (list (user-ev "run the tests")
                      (call-ev "shell" :command "npm test")
                      (user-ev "no, use pnpm")
                      (call-ev "shell" :command "pnpm test"))))
    (let ((class (ourro.observe:detect-command-preference events)))
      (is (eq :command-preference (first class)))
      (is (equal "pnpm" (second class)))))
  ;; Same command → nothing.
  (let ((events (list (user-ev "run the tests")
                      (call-ev "shell" :command "npm test")
                      (user-ev "no, do it again")
                      (call-ev "shell" :command "npm test"))))
    (is-false (ourro.observe:detect-command-preference events))))

(test events-to-turns
  (let ((turns (ourro.observe:events->turns
                (list (user-ev "a") (call-ev "x") (call-ev "y")
                      (user-ev "b") (call-ev "z")))))
    (is (= 2 (length turns)))
    (is (string= "a" (getf (first (first turns)) :text)))
    (is (= 2 (length (rest (first turns)))))))


(test corrections-mine-into-a-pattern
  (let ((events (list (list :kind :correction :class '(:substitute "pnpm|npm")
                            :text "use pnpm not npm")
                      (list :kind :correction :class '(:substitute "pnpm|npm")
                            :text "no, pnpm again"))))
    (let ((patterns (ourro.miner:mine-patterns :events events)))
      (is (find :correction patterns :key (lambda (p) (getf p :kind)))))))
