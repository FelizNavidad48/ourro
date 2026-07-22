(in-package #:ourro.tests)

(def-suite reflex-runtime-suite :in ourro)
(in-suite reflex-runtime-suite)

(defmacro with-scratch-reflex-runtime (() &body body)
  `(with-scratch-journal ()
     (let ((ourro.reflex.compiler:*version-registry*
             (make-hash-table :test #'equal))
           (ourro.reflex.compiler:*active-version-pointers*
             (make-hash-table :test #'equal))
           (ourro.reflex.compiler:*canary-routes*
             (make-hash-table :test #'equal))
           (ourro.reflex.effects:*effect-hooks* (make-hash-table :test #'eq)))
       ;; Runtime worker threads must share the symbol's global control state;
       ;; dynamically bound booleans are copied into a new SBCL thread.
       (when (ourro.reflex.runtime:runtime-worker-running-p)
         (ignore-errors (ourro.reflex.runtime:stop-runtime-worker)))
       (setf ourro.reflex.runtime::*runtime-worker-semaphore*
             (bt:make-semaphore :name "test-reflex-runtime"))
       (ourro.reflex.runtime:reset-runtime)
       (unwind-protect (progn ,@body)
         (when (ourro.reflex.runtime:runtime-worker-running-p)
           (ignore-errors (ourro.reflex.runtime:stop-runtime-worker)))
         (ourro.reflex.runtime:reset-runtime)))))

(defun install-active-fixture-version (&key (version-number 1))
  (let ((version
          (ourro.reflex.compiler:compile-reflex
           (ourro.reflex.model:definition-from-form
            (fixture-reflex-form :version version-number)))))
    (ourro.reflex.compiler:install-reflex-version version)
    (ourro.reflex.compiler:activate-reflex-version
     'failed-job-briefing (ourro.reflex.model:version-hash version)
     :approved-authority '(:observe))
    version))

(defun fixture-runtime-event ()
  (ourro.reflex.journal:append-record
   (list :kind :job-exit :outcome :error) :workspace "/repo/a/"))

(defun adapter-crash-fixture-form (adapter authority)
  `(define-reflex adapter-crash-fixture
     (:identity (:version 1 :workspace :current :capabilities ,authority))
     (:trigger (:kind :adapter-crash-probe))
     (:guards ())
     (:state (:version 1 :initial-step :effect))
     (:workflow ((:id :effect :activity ,adapter :input (:fixture t)
                  :next :done :max-attempts 3)))
     (:policy (:approval :required))))

(defun exercise-adapter-crash-boundary (adapter class authority boundary)
  (with-scratch-reflex-runtime ()
    (let ((live-calls 0) (reconcile-calls 0) (seen-keys '()))
      (setf (gethash adapter ourro.reflex.effects:*effect-hooks*)
            (lambda (input key)
              (declare (ignore input))
              (incf live-calls)
              (push key seen-keys)
              (list :executed adapter)))
      (when (eq adapter :start-job)
        (setf (gethash :reconcile-job ourro.reflex.effects:*effect-hooks*)
              (lambda (input key)
                (declare (ignore input))
                (incf reconcile-calls)
                (push key seen-keys)
                '(:job :known))))
      (when (eq adapter :prepare-change)
        (setf (gethash :reconcile-change ourro.reflex.effects:*effect-hooks*)
              (lambda (input key)
                (declare (ignore input))
                (incf reconcile-calls)
                (push key seen-keys)
                '(:worktree :known))))
      (let* ((version
               (ourro.reflex.compiler:compile-reflex
                (ourro.reflex.model:definition-from-form
                 (adapter-crash-fixture-form adapter authority))))
             (hash (ourro.reflex.model:version-hash version)))
        (ourro.reflex.compiler:install-reflex-version version)
        (ourro.reflex.compiler:activate-reflex-version
         'adapter-crash-fixture hash :approved-authority authority)
        (ourro.reflex.runtime:submit-command
         (list :type :arm :workspace "/repo/a/"))
        (let* ((event (ourro.reflex.journal:append-record
                       (list :kind :adapter-crash-probe)
                       :workspace "/repo/a/"))
               (instance
                 (first (ourro.reflex.runtime:submit-command
                         (list :type :external-event :event event))))
               (instance-id
                 (ourro.reflex.runtime:runtime-instance-id instance))
               (intent (first (ourro.reflex.runtime:runtime-pending-intents)))
               (key (pget intent :idempotency-key)))
          (unless (eq boundary :after-intent)
            (let ((ourro.reflex.effects:*effect-fault-hook*
                    (lambda (at fault-intent result)
                      (declare (ignore fault-intent result))
                      (when (eq at boundary) (error "simulated process death")))))
              (handler-case
                  (ourro.reflex.effects:execute-effect-intent intent)
                (error () nil))))
          (ourro.reflex.runtime:reset-runtime)
          (ourro.reflex.runtime:recover-runtime "/repo/a/")
          (let ((recovered
                  (ourro.reflex.runtime:find-runtime-instance instance-id)))
            (is-true recovered)
            (cond
              ((eq boundary :after-result-commit)
               (is (eq :succeeded
                       (ourro.reflex.runtime:runtime-instance-status recovered)))
               (is (= 1 live-calls))
               (is (= 0 reconcile-calls)))
              ((or (member class '(:pure :idempotent))
                   (and (eq class :non-repeatable)
                        (eq boundary :after-intent)))
               (is (eq :waiting-effect
                       (ourro.reflex.runtime:runtime-instance-status recovered)))
               (let ((retry (first
                             (ourro.reflex.runtime:runtime-pending-intents))))
                 (is-true retry)
                 (is (string= key (pget retry :idempotency-key)))))
              ((eq class :reconcilable)
               (is (eq :succeeded
                       (ourro.reflex.runtime:runtime-instance-status recovered)))
               (is (= 1 reconcile-calls))
               (is (every (lambda (seen) (string= key seen)) seen-keys)))
              (t
               (is (eq :awaiting-decision
                       (ourro.reflex.runtime:runtime-instance-status recovered)))
               (is (eq :ambiguous-non-repeatable
                       (pget (ourro.reflex.runtime:runtime-instance-pending-decision
                              recovered)
                             :reason)))
               (is (null (ourro.reflex.runtime:runtime-pending-intents)))))))))))

(test failed-effects-offer-and-accept-only-the-adapters-recovery-vocabulary
  (with-scratch-reflex-runtime ()
    (let* ((definition (ourro.reflex.model:definition-from-form
                        (adapter-crash-fixture-form
                         :investigate '(:filesystem-read :llm :observe))))
           (version (ourro.reflex.compiler:compile-reflex definition)))
      (ourro.reflex.compiler:install-reflex-version version)
      (ourro.reflex.compiler:activate-reflex-version
       'adapter-crash-fixture (ourro.reflex.model:version-hash version)
       :approved-authority '(:filesystem-read :llm :observe))
      (setf (gethash :investigate ourro.reflex.effects:*effect-hooks*)
            (lambda (input key)
              (declare (ignore input key)) (error "fixture failure")))
      (ourro.reflex.runtime:submit-command
       (list :type :arm :workspace "/repo/a/"))
      (let* ((event (ourro.reflex.journal:append-record
                     (list :kind :adapter-crash-probe) :workspace "/repo/a/"))
             (instance (first (ourro.reflex.runtime:submit-command
                               (list :type :external-event :event event)))))
        (ourro.reflex.runtime:drain-effects)
        (let ((recoveries
                (pget (ourro.reflex.runtime:runtime-instance-pending-decision
                       instance)
                      :recoveries)))
          (is (equal '(:accept-result :compensate :pause) recoveries))
          (is-false (member :retry-now recoveries)))
        (ourro.reflex.runtime:submit-command
         (list :type :recovery-decision
               :instance-id (ourro.reflex.runtime:runtime-instance-id instance)
               :token :accept-result :result '(:accepted t)))
        (is (eq :succeeded
                (ourro.reflex.runtime:runtime-instance-status instance)))))))

(test runtime-pins-version-and-commits-before-effect
  (with-scratch-reflex-runtime ()
    (let* ((v1 (install-active-fixture-version :version-number 1))
           (live-calls 0))
      (setf (gethash :notify ourro.reflex.effects:*effect-hooks*)
            (lambda (input key)
              (declare (ignore input key))
              (incf live-calls)
              '(:delivered t)))
      (ourro.reflex.runtime:submit-command
       (list :type :arm :workspace "/repo/a/"))
      (let* ((instances (ourro.reflex.runtime:submit-command
                         (list :type :external-event
                               :event (fixture-runtime-event))))
             (instance (first instances)))
        (is (= 1 (length instances)))
        (is (string= (ourro.reflex.model:version-hash v1)
                     (ourro.reflex.runtime:runtime-instance-version-hash instance)))
        (is (eq :waiting-effect
                (ourro.reflex.runtime:runtime-instance-status instance)))
        (is (= 1 (length (ourro.reflex.runtime:runtime-pending-intents))))
        (ourro.reflex.runtime:drain-effects)
        (is (= 1 live-calls))
        (is (eq :succeeded
                (ourro.reflex.runtime:runtime-instance-status instance)))))))

(test every-adapter-recovers-at-every-effect-crash-boundary
  (dolist (spec '((:read :pure (:filesystem-read))
                  (:notify :idempotent (:observe))
                  (:start-job :reconcilable (:subprocess))
                  (:investigate :non-repeatable
                   (:filesystem-read :llm :observe))
                  (:prepare-change :reconcilable
                   (:filesystem-read :filesystem-write))))
    (dolist (boundary '(:after-intent :before-effect :after-effect
                        :after-result-commit))
      (exercise-adapter-crash-boundary
       (first spec) (second spec) (third spec) boundary))))

(test thousand-event-foreground-acceptance-meets-frozen-p95-gate
  (with-scratch-reflex-runtime ()
    (install-active-fixture-version)
    (ourro.reflex.runtime:submit-command
     (list :type :arm :workspace "/repo/benchmark/"))
    (let ((report
            (ourro.reflex.runtime:run-foreground-acceptance-benchmark
             :event-count 1000 :workspace "/repo/benchmark/")))
      (is (= 1000 (pget report :event-count)))
      (is-true (pget report :under-50-ms))
      (is-true (pget report :within-five-percent-regression))
      (is (< (pget report :p95-ms) 50.0d0)))))

(test disarm-invalidates-queued-effects-without-deadlock
  (with-scratch-reflex-runtime ()
    (install-active-fixture-version)
    (let ((live-calls 0))
      (setf (gethash :notify ourro.reflex.effects:*effect-hooks*)
            (lambda (input key)
              (declare (ignore input key)) (incf live-calls)))
      (ourro.reflex.runtime:submit-command
       (list :type :arm :workspace "/repo/a/"))
      (let ((instance (first (ourro.reflex.runtime:submit-command
                              (list :type :external-event
                                    :event (fixture-runtime-event))))))
        (ourro.reflex.runtime:submit-command
         (list :type :disarm :workspace "/repo/a/"))
        (is (null (ourro.reflex.runtime:runtime-pending-intents)))
        (is (eq :paused
                (ourro.reflex.runtime:runtime-instance-status instance)))
        (is (null (ourro.reflex.runtime:drain-effects)))
        (is (= 0 live-calls))))))

(test recovery-requeues-only-safe-unresolved-effects
  (with-scratch-reflex-runtime ()
    (install-active-fixture-version)
    (ourro.reflex.runtime:submit-command
     (list :type :arm :workspace "/repo/a/"))
    (ourro.reflex.runtime:submit-command
     (list :type :external-event :event (fixture-runtime-event)))
    (setf ourro.reflex.runtime:*instances* (make-hash-table :test #'equal)
          ourro.reflex.runtime:*pending-intents* '())
    (let ((summary (ourro.reflex.runtime:recover-runtime "/repo/a/")))
      (is (= 1 (getf summary :instances)))
      (is (= 1 (getf summary :pending-effects))))))

(test recovery-commits-a-durable-effect-result-without-repeating-the-effect
  (with-scratch-reflex-runtime ()
    (install-active-fixture-version)
    (let ((calls 0))
      (setf (gethash :notify ourro.reflex.effects:*effect-hooks*)
            (lambda (input key)
              (declare (ignore input key))
              (incf calls)
              '(:delivered t)))
      (ourro.reflex.runtime:submit-command
       (list :type :arm :workspace "/repo/a/"))
      (ourro.reflex.runtime:submit-command
       (list :type :external-event :event (fixture-runtime-event)))
      ;; Simulate death after the adapter's durable terminal record but before
      ;; the runtime receives/commits :EFFECT-RESULT.
      (let ((intent (first (ourro.reflex.runtime:runtime-pending-intents))))
        (ourro.reflex.effects:execute-effect-intent intent)
        (setf ourro.reflex.runtime:*instances* (make-hash-table :test #'equal)
              ourro.reflex.runtime:*pending-intents* '())
        (ourro.reflex.runtime:recover-runtime "/repo/a/")
        (let ((instance (first (ourro.reflex.runtime:list-runtime-instances))))
          (is (= 1 calls))
          (is (eq :succeeded
                  (ourro.reflex.runtime:runtime-instance-status instance))))
        ;; A second cold reconstruction observes the committed transition and
        ;; neither invokes nor plans the completed effect again.
        (ourro.reflex.runtime:recover-runtime "/repo/a/")
        (is (= 1 calls))
        (is (null (ourro.reflex.runtime:runtime-pending-intents)))))))

(test automatic-crash-retries-stop-at-the-declared-budget
  (with-scratch-reflex-runtime ()
    (install-active-fixture-version)
    (ourro.reflex.runtime:submit-command
     (list :type :arm :workspace "/repo/a/"))
    (ourro.reflex.runtime:submit-command
     (list :type :external-event :event (fixture-runtime-event)))
    (let ((intent (first (ourro.reflex.runtime:runtime-pending-intents))))
      (dotimes (i (pget intent :max-attempts))
        (ourro.reflex.journal:append-record
         (list :record-kind :effect-attempt :kind :effect-attempt
               :intent-id (pget intent :intent-id)
               :instance-id (pget intent :instance-id)
               :status :started :attempt-index i)
         :workspace "/repo/a/"))
      (setf ourro.reflex.runtime:*instances* (make-hash-table :test #'equal)
            ourro.reflex.runtime:*pending-intents* '())
      (ourro.reflex.runtime:recover-runtime "/repo/a/")
      (let ((instance (first (ourro.reflex.runtime:list-runtime-instances))))
        (is (null (ourro.reflex.runtime:runtime-pending-intents)))
        (is (eq :awaiting-decision
                (ourro.reflex.runtime:runtime-instance-status instance)))
        (is (eq :automatic-retry-budget-exhausted
                (pget (ourro.reflex.runtime:runtime-instance-pending-decision
                       instance)
                      :reason)))))))

