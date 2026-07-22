(in-package #:ourro.tests)

(def-suite scratchpad-suite :in ourro)
(in-suite scratchpad-suite)


(defun scratch-agent ()
  (ourro.agent::make-agent :provider (ourro.llm:make-scripted-provider '())))

(test scratchpad-evaluates-arithmetic
  (let ((out (ourro.agent::scratch-eval (scratch-agent) "(+ 1 2)")))
    (is (search "=> 3" out))))

(test scratchpad-definitions-persist-across-calls
  (let ((agent (scratch-agent)))
    (ourro.agent::scratch-eval agent "(defun sqr-xyz (x) (* x x))")
    ;; A later call sees the earlier defun — the scratch package persists.
    (is (search "=> 49" (ourro.agent::scratch-eval agent "(sqr-xyz 7)")))))

(test scratchpad-captures-stdout
  (let ((out (ourro.agent::scratch-eval (scratch-agent)
                                       "(progn (format t \"hi~%\") 5)")))
    (is (search "hi" out))
    (is (search "=> 5" out))))

(test scratchpad-walker-rejects-write-capability
  ;; cap/write-file needs :filesystem-write, which lisp_eval does not grant.
  (let ((out (ourro.agent::scratch-eval (scratch-agent)
                                       "(cap/write-file \"/tmp/x\" \"y\")")))
    (is (search "walker" out))
    (is (or (search "capability" out) (search "FILESYSTEM-WRITE" out)))))

(test scratchpad-walker-rejects-eval-and-random
  (is (search "walker" (ourro.agent::scratch-eval (scratch-agent) "(eval (list 1))")))
  (is (search "walker" (ourro.agent::scratch-eval (scratch-agent) "(random 10)"))))

(test scratchpad-watchdog-stops-runaway-loops
  (let ((ourro.agent::*scratch-timeout-seconds* 0.4))
    (let ((out (ourro.agent::scratch-eval (scratch-agent) "(loop for i from 0)")))
      (is (search "timed out" out)))))

(test scratchpad-tool-output-reads-the-ring
  ;; (tool-output n) fetches ring entry n — the "filter a log in-image" accessor.
  (let ((agent (scratch-agent)))
    (setf (ourro.agent::agent-tool-results agent)
          (list (list :n 3 :name "read_file"
                      :result (format nil "line one~%FIXME two~%line three")
                      :error-p nil :ms 1)))
    (let ((out (ourro.agent::scratch-eval
                agent
                "(length (remove-if-not (lambda (l) (search \"FIXME\" l))
                                        (split-lines (tool-output 3))))")))
      (is (search "=> 1" out)))))

(test scratchpad-read-error-is-clean
  (let ((out (ourro.agent::scratch-eval (scratch-agent) "(+ 1 2")))  ; unbalanced
    (is (stringp out))
    (is (or (search "read error" out) (search "error" out)))))

(test scratchpad-lisp-eval-tool-is-registered
  (is-true (ourro.tools:find-tool "lisp_eval")))
