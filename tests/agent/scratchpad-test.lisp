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

