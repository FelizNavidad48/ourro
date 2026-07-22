
(in-package #:ourro.agent)

(defparameter *scratch-granted-capabilities* '(:filesystem-read :observe)
  "Capabilities lisp_eval grants the evaluated code: read files and observe
events. The walker rejects anything needing more (write, subprocess, network,
:llm) exactly as it would for a gene, and with-capabilities enforces it at
runtime too.")

(defparameter *scratch-timeout-seconds* 10
  "Watchdog budget for one lisp_eval — a runaway loop is cut here.")

(defvar *scratch-package* nil "The persistent OURRO-SCRATCH package.")
(defvar *scratch-eval-agent* nil "The agent whose ring (tool-output n) reads.")

(defun scratch-tool-output (n)
  "The (tool-output n) accessor installed in OURRO-SCRATCH: the full text of
tool-result ring entry N (see the ↳ [N] labels / the /out pager)."
  (let ((agent *scratch-eval-agent*))
    (if (null agent)
        "(tool-output is only available inside lisp_eval)"
        (let ((entry (find n (agent-tool-results agent)
                           :key (lambda (e) (pget e :n)) :test #'eql)))
          (if entry
              (or (pget entry :result) "")
              (format nil "no tool output #~A (the ring holds the last ~A results)"
                      n *tool-result-ring-size*))))))

(defun ensure-scratch-package ()
  "The OURRO-SCRATCH package (:use OURRO.API), created once and reused so
definitions persist across lisp_eval calls. Installs (tool-output n)."
  (or *scratch-package*
      (let ((pkg (or (find-package "OURRO-SCRATCH")
                     (make-package "OURRO-SCRATCH" :use '(:ourro.api)))))
        (let ((sym (intern "TOOL-OUTPUT" pkg)))
          (setf (symbol-function sym) #'scratch-tool-output)
          (export sym pkg))
        (setf *scratch-package* pkg))))

(defun scratch-eval (agent code)
  "Evaluate CODE (Common Lisp source) in the scratch package: safe-read → walker
lint (granting the read-only scratch capabilities) → eval under those caps + a
10 s watchdog + stdout capture. Always returns a string — a walker rejection, a
capability violation, a timeout, or an error becomes readable text, never a
crash. Definitions persist across calls."
  (let ((pkg (ensure-scratch-package))
        (*scratch-eval-agent* agent))
    (handler-case
        (let ((forms (ourro.kernel:safe-read-forms code :package pkg)))
          (if (null forms)
              "(nothing to evaluate)"
              (let ((violations (ourro.kernel:lint-gene-body
                                 forms :capabilities *scratch-granted-capabilities*)))
                (if violations
                    (format nil "rejected by the walker (lisp_eval grants only ~
~{~A~^, ~}):~%~A"
                            *scratch-granted-capabilities*
                            (ourro.kernel:lint-violations violations))
                    (scratch-run forms)))))
      (error (c)
        (format nil "read error: ~A" c)))))

(defun scratch-run (forms)
  "Run already-linted FORMS under the scratch capabilities + watchdog, capturing
output. Returns the captured stdout plus the last form's value."
  (let ((out (make-string-output-stream))
        (value nil))
    (handler-case
        (sb-ext:with-timeout *scratch-timeout-seconds*
          (ourro.kernel:with-capabilities *scratch-granted-capabilities*
            (let ((*standard-output* out)
                  (*trace-output* out)
                  (*package* (ensure-scratch-package)))
              (dolist (form forms) (setf value (eval form))))))
      (sb-ext:timeout ()
        (return-from scratch-run
          (format nil "timed out after ~As (a runaway loop?)"
                  *scratch-timeout-seconds*)))
      (ourro.kernel:capability-violation (c)
        (return-from scratch-run
          (format nil "capability violation: ~A" c)))
      (error (c)
        (return-from scratch-run (format nil "error: ~A" c))))
    (let ((printed (get-output-stream-string out)))
      (ourro.toolkit:clamp-output
       (format nil "~@[~A~%~]=> ~A"
               (and (plusp (length printed)) printed)
               (prin1-to-string value))
       :label "lisp_eval"))))

(ourro.tools:deftool lisp-eval
    ((code :string "Common Lisp source to evaluate in the persistent OURRO-SCRATCH package"
           :required t))
  (:doc "Evaluate Common Lisp in a persistent scratchpad — your in-image
compiler. Definitions (defun/defparameter) persist across calls, so you can
build helpers. You get the OURRO.API surface plus read-only capabilities
(:filesystem-read, :observe); the walker rejects writes, subprocesses, network,
and eval/random exactly as it does for a gene, and a 10 s watchdog stops runaway
loops. Use (tool-output N) to fetch the full text of tool-result ring entry N
(the ↳ [N] labels) — e.g. filter a huge log in-image instead of re-reading it:
  (let ((log (tool-output 3)))
    (length (remove-if-not (lambda (l) (search \"FIXME\" l)) (split-lines log))))")
  (:contract (:pre ((stringp code)) :post ((stringp result))))
  (scratch-eval *agent* code))
