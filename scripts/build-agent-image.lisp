
(let ((genome (uiop:getenv "OURRO_BUILD_GENOME"))
      (output (uiop:getenv "OURRO_BUILD_OUTPUT")))
  (unless (and genome output)
    (format *error-output* "~&[image] OURRO_BUILD_GENOME/OUTPUT unset~%")
    (sb-ext:exit :code 1))
  (handler-case
      (let ((n (funcall (read-from-string "ourro.genome:load-genome") genome)))
        (format t "~&[image] loaded ~A genes from ~A~%" n genome))
    (error (c)
      (format *error-output* "~&[image] genome load failed: ~A~%" c)
      (sb-ext:exit :code 1)))
  (ensure-directories-exist output)
  ;; Harden the kernel in built images only (M4-5): lock OURRO.KERNEL so no
  ;; runtime code path — not even a bug — can redefine a safety primitive or
  ;; intern a new symbol into the package. Dev (`make dev`) and the test suite
  ;; stay unlocked so they can still poke internals. A built image without the
  ;; lock is not hardened and must never be published.
  (handler-case
      (progn
        (dolist (package '("OURRO.KERNEL" "OURRO.TXN" "OURRO.VERIFY"
                           "OURRO.VERIFY.COORDINATOR" "OURRO.AUTOMATION"
                           "OURRO.REFLEX.MODEL" "OURRO.REFLEX.JOURNAL"
                           "OURRO.REFLEX.COMPILER" "OURRO.REFLEX.PROOF"
                           "OURRO.REFLEX.EFFECTS" "OURRO.REFLEX.RUNTIME"
                           "OURRO.REFLEX.INVESTIGATION"
                           "OURRO.REFLEX.BRIEFING" "OURRO.REFLEX.LEARN"
                           "OURRO.REFLEX.INSPECTOR" "OURRO.REFLEX.PILOT"))
          (sb-ext:lock-package package))
        (format t "~&[image] locked kernel/transaction/verifier/effect packages~%"))
    (error (c)
      (format *error-output* "~&[image] could not lock hardened packages: ~A~%" c)
      (sb-ext:exit :code 1)))
  (format t "~&[image] saving ~A~%" output)
  (sb-ext:save-lisp-and-die
   output
   :executable t
   :compression t
   :save-runtime-options t
   :toplevel (read-from-string "ourro.main:main")))
