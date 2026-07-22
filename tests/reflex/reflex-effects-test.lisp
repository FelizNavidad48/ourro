(in-package #:ourro.tests)

(def-suite reflex-effects-suite :in ourro)
(in-suite reflex-effects-suite)

(test effect-intents-have-stable-identity-and-exact-authority
  (let* ((arguments (list :instance-id "instance-1" :version-hash "version-1"
                          :step-id :notify :attempt 1 :workspace "/repo/a/"
                          :adapter :notify :input '(:text "failed")
                          :authority '(:observe) :causation-id "event-1"))
         (first (apply #'ourro.reflex.effects:make-effect-intent arguments))
         (second (apply #'ourro.reflex.effects:make-effect-intent arguments)))
    (is (string= (getf first :idempotency-key)
                 (getf second :idempotency-key)))
    (is (string= (getf first :intent-id) (getf second :intent-id)))
    (signals error
      (ourro.reflex.effects:make-effect-intent
       :instance-id "instance-1" :version-hash "version-1"
       :step-id :notify :workspace "/repo/a/" :adapter :notify
       :input '() :authority '(:filesystem-read)))))

(test virtual-effects-never-invoke-live-product-hooks
  (with-scratch-journal ()
    (let ((ourro.reflex.effects:*effect-hooks* (make-hash-table :test #'eq))
          (live-calls 0))
      (setf (gethash :notify ourro.reflex.effects:*effect-hooks*)
            (lambda (input key)
              (declare (ignore input key))
              (incf live-calls)))
      (let* ((intent (ourro.reflex.effects:make-effect-intent
                      :instance-id "instance-1" :version-hash "version-1"
                      :step-id :notify :workspace "/repo/a/" :adapter :notify
                      :input '(:text "failed") :authority '(:observe)))
             (persisted (ourro.reflex.journal:append-record
                         intent :workspace "/repo/a/"))
             (result (ourro.reflex.effects:execute-effect-intent
                      persisted :virtual t)))
        (is (= 0 live-calls))
        (is (eq :virtual-succeeded (getf result :status)))
        (is-true (getf (getf result :result) :virtual))))))

(test recovery-classes-never-retry-non-repeatable-effects
  (let ((intent (ourro.reflex.effects:make-effect-intent
                 :instance-id "instance-1" :version-hash "version-1"
                 :step-id :investigate :workspace "/repo/a/"
                 :adapter :investigate :input '(:prompt "why")
                 :authority '(:filesystem-read :llm :observe))))
    (is (eq :pause
            (getf (ourro.reflex.effects:reconcile-effect-intent intent)
                  :decision)))))

