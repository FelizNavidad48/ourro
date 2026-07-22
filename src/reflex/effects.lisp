
(defpackage #:ourro.reflex.effects
  (:use #:cl #:ourro.util)
  (:export #:effect-adapter
           #:register-effect-adapter
           #:find-effect-adapter
           #:copy-effect-adapters
           #:make-effect-intent
           #:execute-effect-intent
           #:reconcile-effect-intent
           #:compensate-effect-intent
           #:cancel-effect-intent
           #:effect-idempotency-key
           #:effect-adapter-name
           #:effect-adapter-capability
           #:effect-adapter-recovery-class
           #:*effect-adapters*
           #:*effect-hooks*
           #:*effect-fault-hook*
           #:reflex-effect-condition
           #:effect-condition-intent
           #:effect-condition-recoveries
           #:effect-intent-recovery-tokens
           #:retry-effect-now
           #:retry-effect-later
           #:pause-effect))

(in-package #:ourro.reflex.effects)

(defstruct effect-adapter
  name capability recovery-class execute reconcile compensate virtual-execute)

(define-condition reflex-effect-condition (error)
  ((intent :initarg :intent :reader effect-condition-intent)
   (recoveries :initarg :recoveries :reader effect-condition-recoveries)
   (cause :initarg :cause :reader effect-condition-cause))
  (:report (lambda (condition stream)
             (format stream "reflex effect ~A failed: ~A"
                     (pget (effect-condition-intent condition) :adapter)
                     (effect-condition-cause condition)))))

(defvar *effect-adapters* (make-hash-table :test #'eq))
(defvar *effect-hooks* (make-hash-table :test #'eq)
  "Product-layer callbacks used by built-in adapters without a runtime→UI dependency.")
(defvar *effect-fault-hook* nil
  "Test-only process-crash seam called at durable effect boundaries.")

(defun copy-effect-adapters (&optional (source *effect-adapters*))
  (copy-hash-table source))

(defun register-effect-adapter (name &key capability recovery-class execute
                                          reconcile compensate virtual-execute)
  (unless (member recovery-class '(:pure :idempotent :reconcilable :non-repeatable))
    (error "invalid recovery class ~S" recovery-class))
  (dolist (required (if (listp capability) capability (list capability)))
    (when (and required (not (ourro.kernel:capability-p required)))
      (error "unknown adapter capability ~S" required)))
  (setf (gethash name *effect-adapters*)
        (make-effect-adapter :name name :capability capability
                             :recovery-class recovery-class :execute execute
                             :reconcile reconcile :compensate compensate
                             :virtual-execute virtual-execute)))

(defun find-effect-adapter (name)
  (or (gethash name *effect-adapters*)
      (error "unknown reflex effect adapter ~S" name)))

(defun effect-idempotency-key (instance-id version-hash step-id attempt input)
  (ourro.txn:canonical-hash
   (list :instance instance-id :version version-hash :step step-id
         :attempt attempt :input input)))

(defun make-effect-intent (&key instance-id version-hash step-id attempt workspace
                                adapter input authority causation-id priority
                                deadline-seconds (max-attempts 3))
  (let* ((adapter-definition (find-effect-adapter adapter))
         (required (effect-adapter-capability adapter-definition)))
    (unless (or (null required)
                (subsetp (if (listp required) required (list required)) authority))
      (error "effect adapter ~S requires ~S outside version authority ~S"
             adapter required authority))
    (let ((key (effect-idempotency-key instance-id version-hash step-id
                                       (or attempt 1) input)))
      (list :record-kind :effect-intent :kind :effect-intent
            :intent-id (format nil "intent-~A" (subseq key 0 24))
            :instance-id instance-id :reflex-version version-hash
            :step-id step-id :attempt (or attempt 1) :workspace workspace
            :adapter adapter :input input
            :priority (or priority 0) :deadline-seconds deadline-seconds
            :max-attempts max-attempts
            :input-hash (ourro.txn:canonical-hash input)
            :capability required
            :recovery-class (effect-adapter-recovery-class adapter-definition)
            :idempotency-key key :status :planned
            :causation-id causation-id :time (iso-time) :unix (unix-time)))))

(defun append-effect-record (intent status &rest fields)
  (ourro.reflex.journal:append-record
   (list* :record-kind :effect-attempt :kind :effect-attempt
          :intent-id (pget intent :intent-id)
          :instance-id (pget intent :instance-id)
          :reflex-version (pget intent :reflex-version)
          :step-id (pget intent :step-id)
          :adapter (pget intent :adapter)
          :idempotency-key (pget intent :idempotency-key)
          :status status :causation-id (pget intent :causation-id)
          :time (iso-time) :unix (unix-time)
          fields)
   :workspace (pget intent :workspace)))

(defun inject-effect-fault (boundary intent &optional result)
  (when *effect-fault-hook*
    (funcall *effect-fault-hook* boundary intent result)))

(defun invoke-effect-executor (adapter function intent)
  (let ((capability (effect-adapter-capability adapter)))
    (if capability
        (ourro.kernel:with-capabilities
            (if (listp capability) capability (list capability))
          (funcall function (copy-tree (pget intent :input))
                   (pget intent :idempotency-key)))
        (funcall function (copy-tree (pget intent :input))
                 (pget intent :idempotency-key)))))

(defun recovery-descriptors (adapter)
  (case (effect-adapter-recovery-class adapter)
    (:pure '((:token :retry-now) (:token :skip) (:token :pause)))
    (:idempotent '((:token :retry-now) (:token :retry-later) (:token :pause)))
    (:reconcilable '((:token :reconcile) (:token :compensate) (:token :pause)))
    (:non-repeatable '((:token :accept-result) (:token :compensate) (:token :pause)))))

(defun effect-intent-recovery-tokens (intent)
  "Return the adapter-declared durable recovery vocabulary for INTENT."
  (mapcar (lambda (descriptor) (pget descriptor :token))
          (recovery-descriptors (find-effect-adapter (pget intent :adapter)))))

(defun execute-effect-intent (intent &key virtual)
  "Execute INTENT after its durable record exists; append one terminal result."
  (let* ((adapter (find-effect-adapter (pget intent :adapter)))
         (function (if virtual
                       (effect-adapter-virtual-execute adapter)
                       (effect-adapter-execute adapter))))
    (unless function
      (error "adapter ~S has no ~:[live~;virtual~] executor"
             (pget intent :adapter) virtual))
    (unless (string= (pget intent :input-hash)
                     (ourro.txn:canonical-hash (pget intent :input)))
      (error "effect intent input hash mismatch"))
    (append-effect-record intent (if virtual :virtual-started :started))
    ;; Fault hooks live outside the adapter error handler. Abrupt process death
    ;; must leave an unresolved boundary, not fabricate a durable :FAILED result.
    (inject-effect-fault :before-effect intent)
    (multiple-value-bind (succeeded result condition)
        (handler-case
            (values t (invoke-effect-executor adapter function intent) nil)
          (error (condition) (values nil nil condition)))
      (if succeeded
          (progn
            (inject-effect-fault :after-effect intent result)
            (let ((terminal
                    (append-effect-record
                     intent (if virtual :virtual-succeeded :succeeded)
                     :result result
                     :result-hash (ourro.txn:canonical-hash result))))
              (inject-effect-fault :after-result-commit intent terminal)
              terminal))
          (let ((failure (append-effect-record
                          intent :failed :error (princ-to-string condition))))
            ;; Restarts have dynamic extent and return only serialized transition
            ;; tokens.  The durable runtime may record and apply one immediately;
            ;; asynchronous UI decisions use the same token vocabulary later and
            ;; never retain a restart object or stack.
            (restart-case
                (error 'reflex-effect-condition :intent failure :cause condition
                       :recoveries (recovery-descriptors adapter))
              (retry-effect-now ()
                :report "Retry this effect now with the same idempotency key."
                (list :transition-token :retry-now
                      :intent-id (pget intent :intent-id)))
              (retry-effect-later ()
                :report "Persist a delayed retry decision."
                (list :transition-token :retry-later
                      :intent-id (pget intent :intent-id)))
              (pause-effect ()
                :report "Pause at the durable effect boundary."
                (list :transition-token :pause
                      :intent-id (pget intent :intent-id)))))))))

(defun reconcile-effect-intent (intent)
  "Recover an unresolved intent according to its declared semantics."
  (let* ((adapter (find-effect-adapter (pget intent :adapter)))
         (class (effect-adapter-recovery-class adapter)))
    (case class
      ((:pure :idempotent) (list :decision :retry :intent intent))
      (:reconcilable
       (if (effect-adapter-reconcile adapter)
           (handler-case
               (list :decision :reconciled
                     :result (funcall (effect-adapter-reconcile adapter)
                                      (pget intent :input)
                                      (pget intent :idempotency-key)))
             (error (condition)
               (list :decision :pause :reason :reconciliation-unavailable
                     :error (princ-to-string condition))))
           (list :decision :pause :reason :missing-reconciler)))
      (:non-repeatable (list :decision :pause :reason :ambiguous-non-repeatable)))))

(defun compensate-effect-intent (intent)
  "Invoke only an adapter's declared compensation and journal its outcome."
  (let* ((adapter (find-effect-adapter (pget intent :adapter)))
         (function (effect-adapter-compensate adapter)))
    (unless function
      (return-from compensate-effect-intent
        (list :status :not-compensatable :intent-id (pget intent :intent-id))))
    (handler-case
        (let ((result (funcall function (copy-tree (pget intent :input))
                               (pget intent :idempotency-key))))
          (append-effect-record intent :compensated :result result))
      (error (condition)
        (append-effect-record intent :compensation-failed
                              :error (princ-to-string condition))))))

(defun cancel-effect-intent (intent reason)
  "Durably prove a planned effect was invalidated before its start boundary."
  (append-effect-record intent :cancelled-before-start :reason reason))

(defun hook-executor (name)
  (lambda (input key)
    (let ((hook (gethash name *effect-hooks*)))
      (unless hook (error "product adapter hook ~S is unavailable" name))
      (funcall hook input key))))

(defun virtual-receipt (input key)
  (list :virtual t :idempotency-key key :input-hash (ourro.txn:canonical-hash input)))

;; Built-in typed boundaries. Product code supplies hooks; replay always stays virtual.
(register-effect-adapter :read :capability :filesystem-read :recovery-class :pure
                         :execute (hook-executor :read)
                         :virtual-execute #'virtual-receipt)
(register-effect-adapter :notify :capability :observe :recovery-class :idempotent
                         :execute (hook-executor :notify)
                         :virtual-execute #'virtual-receipt)
(register-effect-adapter :start-job :capability :subprocess :recovery-class :reconcilable
                         :execute (hook-executor :start-job)
                         :reconcile (hook-executor :reconcile-job)
                         :virtual-execute #'virtual-receipt)
(register-effect-adapter :investigate
                         :capability '(:filesystem-read :llm :observe)
                         :recovery-class :non-repeatable
                         :execute (hook-executor :investigate)
                         :virtual-execute #'virtual-receipt)
(register-effect-adapter :prepare-change
                         :capability '(:filesystem-read :filesystem-write)
                         :recovery-class :reconcilable
                         :execute (hook-executor :prepare-change)
                         :reconcile (hook-executor :reconcile-change)
                         :virtual-execute #'virtual-receipt)
