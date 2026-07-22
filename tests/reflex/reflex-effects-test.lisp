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

(test every-built-in-adapter-declares-recovery-authority-and-virtual-boundary
  (loop for (name class) in '((:read :pure) (:notify :idempotent)
                              (:start-job :reconcilable)
                              (:investigate :non-repeatable)
                              (:prepare-change :reconcilable))
        for adapter = (ourro.reflex.effects:find-effect-adapter name) do
          (is (eq class
                  (ourro.reflex.effects:effect-adapter-recovery-class adapter)))
          (is-true (ourro.reflex.effects:effect-adapter-capability adapter))))

(test unavailable-reconcilers-pause-instead-of-crashing-recovery
  (let ((ourro.reflex.effects:*effect-hooks* (make-hash-table :test #'eq)))
    (dolist (spec '((:start-job (:subprocess))
                    (:prepare-change (:filesystem-read :filesystem-write))))
      (let ((intent (ourro.reflex.effects:make-effect-intent
                     :instance-id "i" :version-hash "v" :step-id :step
                     :workspace "/repo/a/" :adapter (first spec) :input '()
                     :authority (second spec))))
        (is (eq :pause
                (pget (ourro.reflex.effects:reconcile-effect-intent intent)
                      :decision)))))))

(test declared-compensation-is-idempotency-keyed-and-journaled
  (with-scratch-journal ()
    (let ((ourro.reflex.effects:*effect-adapters*
            (ourro.reflex.effects:copy-effect-adapters))
          (keys '()))
      (ourro.reflex.effects:register-effect-adapter
       :fixture-compensatable :capability :observe
       :recovery-class :reconcilable
       :execute (lambda (input key) (declare (ignore input key)) '(:ok t))
       :reconcile (lambda (input key) (declare (ignore input key)) '(:known t))
       :compensate (lambda (input key) (declare (ignore input))
                     (push key keys) '(:undone t))
       :virtual-execute (lambda (input key) (declare (ignore input key)) '(:virtual t)))
      (let* ((intent (ourro.reflex.effects:make-effect-intent
                      :instance-id "i" :version-hash "v" :step-id :step
                      :workspace "/repo/a/" :adapter :fixture-compensatable
                      :input '(:x 1) :authority '(:observe)))
             (persisted (ourro.reflex.journal:append-record
                         intent :workspace "/repo/a/"))
             (result (ourro.reflex.effects:compensate-effect-intent persisted)))
        (is (eq :compensated (pget result :status)))
        (is (string= (pget persisted :idempotency-key) (first keys)))))))

(test synchronous-effect-restarts-return-only-durable-transition-tokens
  (with-scratch-journal ()
    (let ((ourro.reflex.effects:*effect-adapters*
            (ourro.reflex.effects:copy-effect-adapters)))
      (ourro.reflex.effects:register-effect-adapter
       :fixture-failure :capability :observe :recovery-class :idempotent
       :execute (lambda (input key)
                  (declare (ignore input key)) (error "fixture failure"))
       :virtual-execute (lambda (input key)
                          (declare (ignore input key)) '(:virtual t)))
      (let* ((intent (ourro.reflex.effects:make-effect-intent
                      :instance-id "i" :version-hash "v" :step-id :step
                      :workspace "/repo/a/" :adapter :fixture-failure
                      :input '(:x 1) :authority '(:observe)))
             (persisted (ourro.reflex.journal:append-record
                         intent :workspace "/repo/a/"))
             (token
               (handler-bind
                   ((ourro.reflex.effects:reflex-effect-condition
                      (lambda (condition)
                        (declare (ignore condition))
                        (invoke-restart 'ourro.reflex.effects:pause-effect))))
                 (ourro.reflex.effects:execute-effect-intent persisted))))
        (is (eq :pause (pget token :transition-token)))
        (is (string= (pget persisted :intent-id) (pget token :intent-id)))
        (is (= 2 (length (ourro.reflex.journal:query-records
                          :workspace "/repo/a/" :kind :effect-attempt))))))))
