
(defpackage #:ourro.kernel
  (:use #:cl #:ourro.util)
  (:export
   ;; conditions
   #:ourro-error
   #:verification-failure
   #:verification-failure-stage
   #:verification-failure-diagnostics
   #:capability-violation
   #:capability-violation-capability
   #:capability-violation-operation
   #:evolved-code-failure
   #:evolved-code-failure-gene
   #:evolved-code-failure-original
   #:generation-build-failure
   #:generation-build-failure-report
   #:protocol-error
   #:*max-protocol-frame-chars*
   #:unsafe-form-error
   ;; turn cancellation (M7-1)
   #:turn-cancelled
   #:turn-cancelled-reason
   #:*cancel-inhibited*
   ;; restarts
   #:revert-definition
   #:discard-gene
   #:evolution-freeze
   #:with-evolution-freeze-restart
   #:*evolution-frozen*
   #:*automations-armed*
   ;; gene context (D-3: relocated from ourro.tools so the earlier-loading
   ;; ourro.tui can name it for UI-gene registration)
   #:*current-gene-context*
   ;; capabilities (capabilities.lisp)
   #:*active-capabilities*
   #:*capability-ceiling*
   #:*capability-filesystem-root*
   #:+all-capabilities+
   #:capability-p
   #:capabilities-under-ceiling
   #:capabilities-under-active-grant
   #:with-capabilities
   #:with-attenuated-capabilities
   #:*probation-graduation-hook*
   #:require-capability
   #:cap/run-program
   #:cap/launch-program
   #:cap/read-file
   #:cap/write-file
   #:cap/delete-file
   #:cap/ensure-directories
   #:cap/http-request
   ;; safe reader (safe-read.lisp)
   #:safe-read-form
   #:safe-read-forms
   #:*max-form-depth*
   #:*max-form-atoms*
   ;; walker (walker.lisp)
   #:lint-gene-body
   #:lint-violations
   #:effectful-operator-capability
   ;; revert table (revert.lisp)
   #:record-function-definition
   #:record-method-definition
   #:record-revert-action
   #:revert-gene-definitions
   #:revert-record-count
   #:clear-revert-records
   #:snapshot-definition
   ;; probation
   #:with-probation
   #:*probation-uses*
   #:*probation-failure-hook*
   #:start-probation
   #:note-probation-success
   #:probation-remaining
   ;; protocol (protocol.lisp)
   #:protocol-connect
   #:protocol-send
   #:protocol-receive
   #:protocol-request
   #:protocol-close
   #:protocol-connection
   #:protocol-connection-p
   #:make-protocol-server
   #:protocol-serve
   ;; handoff (handoff.lisp)
   #:write-handoff
   #:read-handoff
   #:handoff-plist
   ;; kernel self-test (selftest.lisp, M4-5)
   #:run-kernel-selftest
   #:kernel-locked-p))

(in-package #:ourro.kernel)

(define-condition ourro-error (error)
  ((message :initarg :message :initform nil :reader ourro-error-message))
  (:report (lambda (c stream)
             (format stream "~@[~A~]" (ourro-error-message c)))))

(define-condition verification-failure (ourro-error)
  ((stage :initarg :stage :reader verification-failure-stage
          :documentation "One of :read :lint :compile :contract :test :kernel.")
   (diagnostics :initarg :diagnostics :initform nil
                :reader verification-failure-diagnostics))
  (:report (lambda (c stream)
             (format stream "Verification failed at ~A stage:~%~A"
                     (verification-failure-stage c)
                     (verification-failure-diagnostics c)))))

(define-condition unsafe-form-error (verification-failure) ()
  (:default-initargs :stage :read))

(define-condition capability-violation (ourro-error)
  ((capability :initarg :capability :reader capability-violation-capability)
   (operation :initarg :operation :reader capability-violation-operation))
  (:report (lambda (c stream)
             (format stream "Operation ~A requires undeclared capability ~S"
                     (capability-violation-operation c)
                     (capability-violation-capability c)))))

(define-condition evolved-code-failure (ourro-error)
  ((gene :initarg :gene :reader evolved-code-failure-gene)
   (original :initarg :original :reader evolved-code-failure-original))
  (:report (lambda (c stream)
             (format stream "Evolved gene ~A failed: ~A"
                     (evolved-code-failure-gene c)
                     (evolved-code-failure-original c)))))

(define-condition generation-build-failure (ourro-error)
  ((report :initarg :report :initform nil :reader generation-build-failure-report)))

(define-condition protocol-error (ourro-error) ())

(define-condition turn-cancelled (serious-condition)
  ((reason :initarg :reason :initform nil :reader turn-cancelled-reason))
  (:report (lambda (c stream)
             (format stream "Turn cancelled~@[: ~A~]" (turn-cancelled-reason c)))))

(defvar *cancel-inhibited* nil
  "Thread-local guard read INSIDE an escalation interrupt lambda (M7-1). Bound
true around uninterruptible sections — a genome mutation (HOT-LOAD-GENE) or a
DELIBERATE-EVOLUTION body — so an escalated BT:INTERRUPT-THREAD never fires a
`turn-cancelled` mid-write and tears kernel/genome state. The interrupt lambda
checks it and no-ops when set; the cooperative CHECK-CANCEL boundaries then catch
the cancel once the guarded section returns.")


(defvar *evolution-frozen* nil
  "When true, the evolution engine proposes and hot-loads nothing.")

(defvar *automations-armed* nil
  "When NIL, the automation dispatcher matches and enqueues nothing — installed
reflexes go silent until /arm. Toggled by /disarm and /arm; carried across
restarts in the session payload.")


(defvar *current-gene-context* nil
  "Plist (:name <gene-name> :capabilities <list>) of the gene currently being
loaded, or NIL. Consulted by load-time registration to attribute definitions
to their gene.")

(defun evolution-freeze (&optional condition)
  "Invoke the EVOLUTION-FREEZE restart if available."
  (let ((restart (find-restart 'evolution-freeze condition)))
    (when restart (invoke-restart restart))))

(defmacro with-evolution-freeze-restart (&body body)
  `(restart-case (progn ,@body)
     (evolution-freeze ()
       :report "Freeze all evolution activity."
       (setf *evolution-frozen* t)
       nil)))
