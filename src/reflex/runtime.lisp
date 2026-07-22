
(defpackage #:ourro.reflex.runtime
  (:use #:cl #:ourro.util)
  (:export #:runtime-instance
           #:runtime-instance-id
           #:runtime-instance-version-hash
           #:runtime-instance-reflex-name
           #:runtime-instance-workspace
           #:runtime-instance-state
           #:runtime-instance-status
           #:runtime-instance-trigger-event-ids
           #:runtime-instance-pending-decision
           #:runtime-instance-attempts
           #:submit-command
           #:drain-effects
           #:recover-runtime
           #:reset-runtime
           #:find-runtime-instance
           #:list-runtime-instances
           #:runtime-armed-p
           #:runtime-status
           #:runtime-pending-intents
           #:simulate-event
           #:install-runtime-dispatch
           #:remove-runtime-dispatch
           #:start-runtime-worker
           #:stop-runtime-worker
           #:runtime-worker-running-p
           #:run-foreground-acceptance-benchmark
           #:purge-runtime-workspace
           #:*instances*
           #:*pending-intents*
           #:*virtual-effects*))

(in-package #:ourro.reflex.runtime)

(defstruct runtime-instance
  id version-hash reflex-name workspace trigger-event-ids state
  (status :running) (attempts 0) pending-decision created-at updated-at)

(defstruct runtime-control
  armed frozen shutdown foreground worker-running)

(defvar *instances* (make-hash-table :test #'equal))
(defvar *pending-intents* '())
(defvar *runtime-shutdown* nil)
(defvar *foreground-active* nil)
(defvar *runtime-control* (make-runtime-control))
(defvar *virtual-effects* nil)
(defvar *inflight-intents* (make-hash-table :test #'equal))
(defvar *suspended-intents* (make-hash-table :test #'equal))
(defvar *effect-worker-threads* (make-hash-table :test #'equal))
(defvar *runtime-timers* (make-hash-table :test #'equal))
(defparameter *maximum-effect-workers* 4)
(defparameter *workspace-effect-concurrency* 2)
(defparameter *foreground-priority-threshold* 50)
(defparameter *default-effect-deadline-seconds* 300)
(defparameter +frozen-foreground-p95-ms+ 47.5d0
  "Pre-reflex pinned-hardware p95; the permitted regression ceiling is 49.875ms.")
(defvar *runtime-lock* (bt:make-lock "ourro-reflex-runtime"))
(defvar *effect-execution-lock* (bt:make-lock "ourro-reflex-effect-execution"))
(defvar *runtime-worker-semaphore* (bt:make-semaphore :name "ourro-durable-reflex"))
(defvar *runtime-worker-running* nil)
(defvar *runtime-worker-thread* nil)
(defvar *dispatch-queue* '())
(defvar *dispatch-queue-lock* (bt:make-lock "ourro-reflex-dispatch-queue"))

(defun runtime-armed-p () (runtime-control-armed *runtime-control*))

(defun unlocked-runtime-status ()
  (list :armed (runtime-control-armed *runtime-control*)
        :frozen (runtime-control-frozen *runtime-control*)
        :foreground-active (runtime-control-foreground *runtime-control*)
        :shutdown (runtime-control-shutdown *runtime-control*)
        :instances (hash-table-count *instances*)
        :pending-effects (length *pending-intents*)
        :inflight-effects (hash-table-count *inflight-intents*)
        :timers (hash-table-count *runtime-timers*)
        :worker-running (runtime-control-worker-running *runtime-control*)))

(defun runtime-status ()
  (bt:with-lock-held (*runtime-lock*) (unlocked-runtime-status)))

(defun runtime-pending-intents ()
  (bt:with-lock-held (*runtime-lock*) (copy-list *pending-intents*)))

(defun instance-snapshot (instance)
  (list :id (runtime-instance-id instance)
        :version-hash (runtime-instance-version-hash instance)
        :reflex-name (runtime-instance-reflex-name instance)
        :workspace (runtime-instance-workspace instance)
        :trigger-event-ids (copy-list (runtime-instance-trigger-event-ids instance))
        :state (copy-tree (runtime-instance-state instance))
        :status (runtime-instance-status instance)
        :attempts (runtime-instance-attempts instance)
        :pending-decision (copy-tree (runtime-instance-pending-decision instance))
        :created-at (runtime-instance-created-at instance)
        :updated-at (runtime-instance-updated-at instance)))

(defun snapshot-instance (snapshot)
  (make-runtime-instance
   :id (pget snapshot :id) :version-hash (pget snapshot :version-hash)
   :reflex-name (pget snapshot :reflex-name)
   :workspace (pget snapshot :workspace)
   :trigger-event-ids (copy-list (pget snapshot :trigger-event-ids))
   :state (copy-tree (pget snapshot :state)) :status (pget snapshot :status)
   :attempts (pget snapshot :attempts 0)
   :pending-decision (copy-tree (pget snapshot :pending-decision))
   :created-at (pget snapshot :created-at) :updated-at (pget snapshot :updated-at)))

(defun append-runtime-record (kind workspace &rest fields)
  (ourro.reflex.journal:append-record
   (list* :record-kind :runtime-transition :kind kind
          :time (iso-time) :unix (unix-time) fields)
   :workspace workspace))

(defun reset-runtime ()
  (bt:with-lock-held (*runtime-lock*)
    (setf *instances* (make-hash-table :test #'equal)
          *pending-intents* '()
          *inflight-intents* (make-hash-table :test #'equal)
          *suspended-intents* (make-hash-table :test #'equal)
          *effect-worker-threads* (make-hash-table :test #'equal)
          *runtime-timers* (make-hash-table :test #'equal)
          *foreground-active* nil
          *runtime-shutdown* nil
          *runtime-control* (make-runtime-control)))
  (bt:with-lock-held (*dispatch-queue-lock*)
    (setf *dispatch-queue* '()))
  t)

(defun find-runtime-instance (id)
  (bt:with-lock-held (*runtime-lock*) (gethash id *instances*)))

(defun list-runtime-instances (&key workspace status)
  (let ((instances '()))
    (bt:with-lock-held (*runtime-lock*)
      (maphash (lambda (id instance)
                 (declare (ignore id))
                 (when (and (or (null workspace)
                                (string= (ourro.reflex.journal:normalize-workspace workspace)
                                         (runtime-instance-workspace instance)))
                            (or (null status)
                                (eq status (runtime-instance-status instance))))
                   (push instance instances)))
               *instances*))
    instances))

(defun activity-adapter (activity)
  (case activity
    (:await-job :read)
    ((:branch :finish) nil)
    (t activity)))

(defun intent-higher-priority-p (left right)
  (let ((left-priority (or (pget left :priority) 0))
        (right-priority (or (pget right :priority) 0)))
    (if (= left-priority right-priority)
        (< (or (pget left :unix) 0) (or (pget right :unix) 0))
        (> left-priority right-priority))))

(defun enqueue-intent (intent)
  (push intent *pending-intents*)
  (setf *pending-intents* (stable-sort *pending-intents*
                                       #'intent-higher-priority-p))
  intent)

(defun instance-trigger-event (instance)
  "Resolve INSTANCE's durable trigger without duplicating it in state records."
  (or (let ((id (or (pget (runtime-instance-state instance) :trigger-event-id)
                     (first (runtime-instance-trigger-event-ids instance)))))
        (and id
             (ourro.reflex.journal:find-record
              id (runtime-instance-workspace instance))))
      ;; Compatibility for instances written by the first runtime schema.
      (pget (runtime-instance-state instance) :trigger-event)))

(defun queue-instance-effects (instance version transition effects)
  (dolist (effect effects)
    (let ((adapter (activity-adapter (pget effect :activity))))
      (when adapter
        (incf (runtime-instance-attempts instance))
        (let* ((definition (ourro.reflex.model:version-definition version))
               (policy (ourro.reflex.model:reflex-policy definition))
               (intent
                 (ourro.reflex.effects:make-effect-intent
                  :instance-id (runtime-instance-id instance)
                  :version-hash (runtime-instance-version-hash instance)
                  :step-id (pget effect :id)
                  :attempt (runtime-instance-attempts instance)
                  :workspace (runtime-instance-workspace instance)
                  :adapter adapter
                  ;; The triggering event is durable workflow input.  Static
                  ;; DSL input may refine the activity, but cannot replace its
                  ;; causal evidence identity. Store the journal reference,
                  ;; not a nested event copy; this also keeps WAL frames within
                  ;; canonical structural-depth limits for wide product events.
                  :input (append (copy-list (or (pget effect :input) '()))
                                 (list :event-id
                                       (pget (instance-trigger-event instance)
                                             :event-id)
                                       :event-workspace
                                       (runtime-instance-workspace instance)))
                  :authority (ourro.reflex.model:reflex-capabilities definition)
                  :priority (or (pget effect :priority)
                                (pget policy :priority) 0)
                  :deadline-seconds
                  (or (pget effect :deadline-seconds)
                      (pget policy :deadline-seconds)
                      *default-effect-deadline-seconds*)
                  :max-attempts
                  (or (pget effect :max-attempts)
                      (pget policy :max-attempts) 3)
                  :causation-id (pget transition :event-id)))
               (persisted (ourro.reflex.journal:append-record
                           intent :workspace (runtime-instance-workspace instance))))
          (enqueue-intent persisted))))))

(defun advance-instance (instance &key event activity-results)
  "Run one deterministic transition on the instance's pinned version."
  (let ((version (ourro.reflex.compiler:find-reflex-version
                  (runtime-instance-reflex-name instance)
                  (runtime-instance-version-hash instance))))
    (unless version
      (setf (runtime-instance-status instance) :quarantined)
      (error "pinned reflex version is unavailable"))
    (unless (ourro.reflex.compiler:version-current-p version)
      (setf (runtime-instance-status instance) :quarantined)
      (error "pinned reflex dependency closure is stale"))
    (when (eq :quarantined (ourro.reflex.model:version-status version))
      (setf (runtime-instance-status instance) :quarantined)
      (error "pinned reflex version is quarantined"))
    (let* ((result (funcall (ourro.reflex.model:version-transition-function version)
                            (copy-tree (runtime-instance-state instance))
                            event activity-results))
           (effects (pget result :effects))
           (terminal (pget result :terminal))
           (new-status (cond (effects :waiting-effect)
                             (terminal :succeeded)
                             (t :running)))
           (updated (iso-time))
           (prospective (copy-runtime-instance instance)))
      (setf (runtime-instance-state prospective) (copy-tree (pget result :state))
            (runtime-instance-status prospective) new-status
            (runtime-instance-updated-at prospective) updated)
      ;; Transition first, resulting work second.
      (let ((transition
              (append-runtime-record
               :instance-transition (runtime-instance-workspace instance)
               :instance-id (runtime-instance-id instance)
               :reflex-version (runtime-instance-version-hash instance)
               :old-state (copy-tree (runtime-instance-state instance))
               :new-state (copy-tree (runtime-instance-state prospective))
               :status new-status :instance-snapshot (instance-snapshot prospective))))
        (setf (runtime-instance-state instance) (runtime-instance-state prospective)
              (runtime-instance-status instance) new-status
              (runtime-instance-updated-at instance) updated)
        (queue-instance-effects instance version transition effects)
        instance))))

(defun create-instance (version event workspace)
  (let* ((definition (ourro.reflex.model:version-definition version))
         (id (make-id "instance"))
         (now (iso-time))
         (instance
           (make-runtime-instance
            :id id :version-hash (ourro.reflex.model:version-hash version)
            :reflex-name (ourro.reflex.model:reflex-name definition)
            :workspace workspace
            :trigger-event-ids (remove nil (list (pget event :event-id)))
            :state (ourro.reflex.model:reflex-initial-state definition) :status :running
            :created-at now :updated-at now)))
    (append-runtime-record :instance-created workspace
                           :instance-id id
                           :reflex-version (runtime-instance-version-hash instance)
                           :trigger-event-ids (runtime-instance-trigger-event-ids instance)
                           :causation-id (pget event :event-id)
                           :instance-snapshot (instance-snapshot instance))
    (setf (gethash id *instances*) instance)
    (advance-instance instance :event event)
    instance))

(defun coalescable-instance (version event workspace)
  (let* ((definition (ourro.reflex.model:version-definition version))
         (policy (ourro.reflex.model:reflex-policy definition))
         (key (pget policy :coalesce-key)))
    (when key
      (let ((value (pget event key)) (match nil))
        (maphash
         (lambda (id instance)
           (declare (ignore id))
           (when (and (null match)
                      (string= workspace (runtime-instance-workspace instance))
                      (string= (ourro.reflex.model:version-hash version)
                               (runtime-instance-version-hash instance))
                      (member (runtime-instance-status instance)
                              '(:running :waiting-effect :paused))
                      (equal value
                             (pget (instance-trigger-event instance) key)))
             (setf match instance)))
         *instances*)
        match))))

(defun create-or-coalesce-instance (version event workspace)
  (let ((instance (coalescable-instance version event workspace)))
    (if (null instance)
        (create-instance version event workspace)
        (progn
          (pushnew (pget event :event-id)
                   (runtime-instance-trigger-event-ids instance) :test #'equal)
          (setf (runtime-instance-updated-at instance) (iso-time))
          (append-runtime-record
           :instance-coalesced workspace
           :instance-id (runtime-instance-id instance)
           :reflex-version (runtime-instance-version-hash instance)
           :trigger-event-id (pget event :event-id)
           :instance-snapshot (instance-snapshot instance))
          instance))))

(defun handle-external-event (event)
  (unless (and (runtime-control-armed *runtime-control*)
               (not (runtime-control-frozen *runtime-control*)))
    (return-from handle-external-event '()))
  (let ((workspace (ourro.reflex.journal:normalize-workspace
                    (pget event :workspace))))
    (loop for version in (ourro.reflex.compiler:select-routed-reflex-versions event)
          for definition = (ourro.reflex.model:version-definition version)
          when (and (or (eq :current (ourro.reflex.model:reflex-workspace definition))
                        (equal workspace
                               (ourro.reflex.journal:normalize-workspace
                                (ourro.reflex.model:reflex-workspace definition))))
                    (ourro.reflex.model:reflex-matches-p definition event))
            collect
            (let ((instance (create-or-coalesce-instance version event workspace)))
              (when (eq :canary (ourro.reflex.model:version-status version))
                (ourro.reflex.compiler:record-canary-firing version)
                (append-runtime-record
                 :canary-routed workspace
                 :instance-id (runtime-instance-id instance)
                 :reflex-version (ourro.reflex.model:version-hash version)
                 :trigger-event-id (pget event :event-id)))
              instance))))

(defun handle-effect-result (command)
  (let* ((intent-id (pget command :intent-id))
         (intent (gethash intent-id *inflight-intents*))
         (instance (gethash (pget command :instance-id) *instances*)))
    (unless instance (error "effect result names unknown instance"))
    (remhash intent-id *inflight-intents*)
    (when (member (runtime-instance-status instance)
                  '(:cancelled :quarantined :failed :succeeded))
      (return-from handle-effect-result instance))
    (if (not (runtime-control-armed *runtime-control*))
        (progn
          ;; A result which crosses the kill switch is evidence, never
          ;; permission to plan another activity.
          (setf (runtime-instance-status instance) :paused
                (runtime-instance-updated-at instance) (iso-time))
          (append-runtime-record
           :effect-finished-while-disarmed (runtime-instance-workspace instance)
           :instance-id (runtime-instance-id instance)
           :intent-id (pget command :intent-id)
           :status (pget command :status)
           :instance-snapshot (instance-snapshot instance))
          instance)
        (if (eq :succeeded (pget command :status))
        (advance-instance instance :activity-results (pget command :result))
        (progn
          (let ((recoveries
                  (or (pget command :recoveries)
                      (and intent
                           (ourro.reflex.effects:effect-intent-recovery-tokens
                            intent))
                      '(:pause))))
            (setf (runtime-instance-status instance) :awaiting-decision
                (runtime-instance-pending-decision instance)
                (list :condition :effect-failed
                      :intent-id intent-id
                      :recoveries recoveries)))
          (when intent (setf (gethash intent-id *suspended-intents*) intent))
          (append-runtime-record
           :recovery-required (runtime-instance-workspace instance)
           :instance-id (runtime-instance-id instance)
           :intent-id intent-id
           :condition :effect-failed
           :recoveries (pget (runtime-instance-pending-decision instance)
                             :recoveries)
           :instance-snapshot (instance-snapshot instance))
          instance)))))

(defun handle-recovery-decision (command)
  (let* ((instance (gethash (pget command :instance-id) *instances*))
         (token (pget command :token))
         (offered (and instance
                       (pget (runtime-instance-pending-decision instance)
                             :recoveries))))
    (unless (and instance (eq :awaiting-decision (runtime-instance-status instance)))
      (error "instance is not awaiting a recovery decision"))
    (unless (member token offered) (error "recovery token was not offered"))
    (let* ((intent-id (pget (runtime-instance-pending-decision instance)
                            :intent-id))
           (intent (and intent-id (gethash intent-id *suspended-intents*))))
      (case token
      (:cancel (setf (runtime-instance-status instance) :cancelled))
      (:pause (setf (runtime-instance-status instance) :paused))
      (:skip (advance-instance instance :activity-results nil))
      (:accept-result
       (advance-instance instance :activity-results (pget command :result)))
      (:reconcile
       (let ((decision (and intent
                            (ourro.reflex.effects:reconcile-effect-intent intent))))
         (if (eq :reconciled (pget decision :decision))
             (advance-instance instance :activity-results
                               (pget decision :result))
             (setf (runtime-instance-status instance) :paused))))
      (:compensate
       (let ((result (and intent
                          (ourro.reflex.effects:compensate-effect-intent intent))))
         (setf (runtime-instance-status instance)
               (if (eq :compensated (pget result :status))
                   :cancelled :paused))))
      ((:retry-now :retry-later)
       (when intent (enqueue-intent intent))
       (setf (runtime-instance-status instance) :waiting-effect))))
    (let ((intent-id (pget (runtime-instance-pending-decision instance) :intent-id)))
      (when intent-id (remhash intent-id *suspended-intents*)))
    (setf (runtime-instance-pending-decision instance) nil
          (runtime-instance-updated-at instance) (iso-time))
    (append-runtime-record :recovery-decided (runtime-instance-workspace instance)
                           :instance-id (runtime-instance-id instance)
                           :token token :actor (or (pget command :actor) :user)
                           :instance-snapshot (instance-snapshot instance))
    instance))

(defun command-workspace-matches-p (command instance)
  (let ((workspace (pget command :workspace)))
    (or (null workspace)
        (string= (ourro.reflex.journal:normalize-workspace workspace)
                 (runtime-instance-workspace instance)))))

(defun select-command-instances (command)
  (let ((id (pget command :instance-id)) (selected '()))
    (maphash
     (lambda (key instance)
       (declare (ignore key))
       (when (and (or (null id) (equal id (runtime-instance-id instance)))
                  (command-workspace-matches-p command instance))
         (push instance selected)))
     *instances*)
    selected))

(defun cancel-pending-intents (predicate reason)
  (let ((cancelled (remove-if-not predicate *pending-intents*)))
    (dolist (intent cancelled)
      (ourro.reflex.effects:cancel-effect-intent intent reason)
      (let ((instance (gethash (pget intent :instance-id) *instances*)))
        (when instance
          (setf (gethash (pget intent :intent-id) *suspended-intents*) intent)
          (setf (runtime-instance-status instance) :paused
                (runtime-instance-pending-decision instance)
                (list :condition reason :recoveries '(:retry-now :cancel)
                      :intent-id (pget intent :intent-id))))))
    (setf *pending-intents* (remove-if predicate *pending-intents*))
    cancelled))

(defun submit-command (command)
  "Serialize and durably record one runtime command."
  (bt:with-lock-held (*runtime-lock*)
    (when (and (runtime-control-shutdown *runtime-control*)
               (not (member (pget command :type) '(:recover :effect-result :status))))
      (error "reflex runtime is shut down"))
    (case (pget command :type)
      (:external-event
       (prog1 (handle-external-event (pget command :event))
         (when *pending-intents*
           (bt:signal-semaphore *runtime-worker-semaphore*))))
      (:arm
       (append-runtime-record :runtime-armed
                              (or (pget command :workspace) "workspace:system"))
       (setf (runtime-control-armed *runtime-control*) t))
      (:status (unlocked-runtime-status))
      (:freeze
       (setf (runtime-control-frozen *runtime-control*) t)
       (append-runtime-record :runtime-frozen
                              (or (pget command :workspace) "workspace:system")))
      (:unfreeze
       (setf (runtime-control-frozen *runtime-control*) nil)
       (append-runtime-record :runtime-unfrozen
                              (or (pget command :workspace) "workspace:system")))
      (:foreground-start
       (setf *foreground-active* t
             (runtime-control-foreground *runtime-control*) t)
       (append-runtime-record :foreground-preemption-started
                              (or (pget command :workspace) "workspace:system")))
      (:foreground-end
       (setf *foreground-active* nil
             (runtime-control-foreground *runtime-control*) nil)
       (append-runtime-record :foreground-preemption-ended
                              (or (pget command :workspace) "workspace:system"))
       (bt:signal-semaphore *runtime-worker-semaphore*))
      (:disarm
       ;; SUBMIT-COMMAND owns the serialized start boundary.  Work already in
       ;; an adapter is reported as an explicit safe point; it may finish, but
       ;; its result cannot advance state or start another effect.
       (setf (runtime-control-armed *runtime-control*) nil)
       (cancel-pending-intents (constantly t) :disarmed-before-start)
         ;; SUBMIT-COMMAND already owns *RUNTIME-LOCK*; do not call the public
         ;; list helper here because it acquires that non-recursive lock again.
         (maphash
          (lambda (id instance)
            (declare (ignore id))
            (when (member (runtime-instance-status instance)
                          '(:running :waiting-effect))
              (setf (runtime-instance-status instance) :paused)))
          *instances*)
       (append-runtime-record :runtime-disarmed
                              (or (pget command :workspace) "workspace:system")
                              :inflight-safe-points
                              (hash-table-count *inflight-intents*)))
      (:pause
       (let* ((instances (select-command-instances command))
              (ids (mapcar #'runtime-instance-id instances)))
         (cancel-pending-intents
          (lambda (intent) (member (pget intent :instance-id) ids :test #'equal))
          :paused-before-start)
         (dolist (instance instances)
           (unless (member (runtime-instance-status instance)
                           '(:succeeded :failed :cancelled :quarantined))
             (setf (runtime-instance-status instance) :paused)
             (append-runtime-record
              :instance-paused (runtime-instance-workspace instance)
              :instance-id (runtime-instance-id instance)
              :instance-snapshot (instance-snapshot instance))))
         instances))
      (:resume
       (let ((instances (select-command-instances command)))
         (dolist (instance instances)
           (when (eq :paused (runtime-instance-status instance))
             (setf (runtime-instance-status instance)
                   (if (pget (runtime-instance-pending-decision instance) :intent-id)
                       :awaiting-decision :running))
             (append-runtime-record
              :instance-resumed (runtime-instance-workspace instance)
              :instance-id (runtime-instance-id instance)
              :instance-snapshot (instance-snapshot instance))))
         instances))
      (:schedule
       (let ((timer-id (or (pget command :timer-id) (make-id "timer"))))
         (unless (and (numberp (pget command :due-unix))
                      (listp (pget command :event)))
           (error "timer requires :DUE-UNIX and :EVENT"))
         (let ((timer (list :timer-id timer-id :due-unix (pget command :due-unix)
                            :event (copy-tree (pget command :event))
                            :workspace (ourro.reflex.journal:normalize-workspace
                                        (or (pget command :workspace)
                                            (pget (pget command :event) :workspace))))))
           (setf (gethash timer-id *runtime-timers*) timer)
           (append-runtime-record :timer-scheduled (pget timer :workspace)
                                  :timer-id timer-id :due-unix (pget timer :due-unix)
                                  :event (pget timer :event))
           (bt:signal-semaphore *runtime-worker-semaphore*)
           timer-id)))
      (:cancel-timer
       (let ((timer (gethash (pget command :timer-id) *runtime-timers*)))
         (when timer
           (remhash (pget command :timer-id) *runtime-timers*)
           (append-runtime-record :timer-cancelled (pget timer :workspace)
                                  :timer-id (pget timer :timer-id)))
         (and timer t)))
      (:cancel
       (let ((instance (gethash (pget command :instance-id) *instances*)))
         (when instance
           (setf (runtime-instance-status instance) :cancelled)
           (cancel-pending-intents
            (lambda (intent)
              (equal (runtime-instance-id instance)
                     (pget intent :instance-id)))
            :instance-cancelled)
           ;; Cancellation is terminal even though the helper above describes
           ;; a possible retry for ordinary pauses.
           (setf (runtime-instance-status instance) :cancelled
                 (runtime-instance-pending-decision instance) nil)
           (append-runtime-record :instance-cancelled
                                  (runtime-instance-workspace instance)
                                  :instance-id (runtime-instance-id instance)
                                  :instance-snapshot (instance-snapshot instance)))
         instance))
      (:effect-result (handle-effect-result command))
      (:recovery-decision (handle-recovery-decision command))
      (:shutdown
       (setf *runtime-shutdown* t
             (runtime-control-armed *runtime-control*) nil
             (runtime-control-shutdown *runtime-control*) t)
       (cancel-pending-intents (constantly t) :shutdown-before-start)
       (append-runtime-record :runtime-shutdown
                              (or (pget command :workspace) "workspace:system")
                              :inflight-safe-points
                              (hash-table-count *inflight-intents*)))
      (t (error "unknown reflex runtime command ~S" (pget command :type))))))

(defun benchmark-duration-ms (start)
  (* 1000.0d0
     (/ (- (get-internal-real-time) start)
        internal-time-units-per-second)))

(defun run-foreground-acceptance-benchmark
    (&key (event-count 1000) (workspace "workspace:benchmark"))
  "Measure foreground status acceptance across a scripted event fixture."
  (unless (plusp event-count) (error "EVENT-COUNT must be positive"))
  (loop repeat 32 do (submit-command '(:type :status)))
  (let ((durations '()))
    (dotimes (index event-count)
      (let ((event
              (ourro.reflex.journal:append-record
               (list :kind :runtime-benchmark-probe :ordinal index)
               :workspace workspace)))
        (submit-command (list :type :external-event :event event)))
      (let ((start (get-internal-real-time)))
        (submit-command '(:type :status))
        (push (benchmark-duration-ms start) durations)))
    (let* ((p95 (percentile durations 0.95d0))
           (regression-ceiling (* +frozen-foreground-p95-ms+ 1.05d0))
           (report
             (list :record-kind :runtime-benchmark :kind :runtime-benchmark
                   :event-count event-count :p95-ms p95
                   :frozen-baseline-p95-ms +frozen-foreground-p95-ms+
                   :regression-ceiling-ms regression-ceiling
                   :under-50-ms (< p95 50.0d0)
                   :within-five-percent-regression
                   (<= p95 regression-ceiling))))
      (ourro.reflex.journal:append-record report :workspace workspace))))

(defun terminal-effect-status-p (status)
  (member status '(:succeeded :failed :virtual-succeeded
                   :cancelled-before-start :compensated)
          :test #'eq))

(defun automatic-retry-count (records intent-id)
  (count-if (lambda (record)
              (and (eq :effect-attempt (pget record :record-kind))
                   (equal intent-id (pget record :intent-id))
                   (member (pget record :status) '(:started :virtual-started))))
            records))

(defun pause-recovered-intent (instance intent decision)
  (let ((intent-id (pget intent :intent-id)))
    (when instance
      (setf (runtime-instance-status instance) :awaiting-decision
            (runtime-instance-pending-decision instance)
            (append (list :condition :effect-recovery
                          :intent-id intent-id
                          :recoveries '(:retry-now :pause :cancel))
                    (copy-list decision))
            (gethash intent-id *suspended-intents*) intent)
      (append-runtime-record
       :recovery-required (runtime-instance-workspace instance)
       :instance-id (runtime-instance-id instance)
       :intent-id intent-id :condition :effect-recovery
       :decision decision :instance-snapshot (instance-snapshot instance)))
    decision))

(defun recover-terminal-effect (intent terminal-record)
  "Commit a recorded adapter result into deterministic workflow state once."
  (let ((instance (gethash (pget intent :instance-id) *instances*)))
    (when (and instance
               (member (runtime-instance-status instance)
                       '(:waiting-effect :running)))
      (case (pget terminal-record :status)
        ((:succeeded :virtual-succeeded)
         (append-runtime-record
          :effect-completion-recovered (runtime-instance-workspace instance)
          :instance-id (runtime-instance-id instance)
          :intent-id (pget intent :intent-id)
          :effect-record-id (pget terminal-record :event-id))
         (advance-instance instance :activity-results
                           (pget terminal-record :result)))
        (:failed
         (pause-recovered-intent
          instance intent
          (list :reason :recorded-effect-failure
                :error (pget terminal-record :error))))
        ((:cancelled-before-start :compensated)
         (pause-recovered-intent
          instance intent
          (list :reason (pget terminal-record :status))))))))

(defun run-effect-intent (intent &key virtual)
  "Execute and report INTENT through the single supervised result boundary."
  (let* ((deadline (or (pget intent :deadline-seconds)
                       *default-effect-deadline-seconds*))
         (result
           (handler-case
               (sb-ext:with-timeout deadline
                 (ourro.reflex.effects:execute-effect-intent
                  intent :virtual virtual))
             (ourro.reflex.effects:reflex-effect-condition (condition)
               (append
                (ourro.reflex.effects:effect-condition-intent condition)
                (list :recoveries
                      (mapcar (lambda (descriptor) (pget descriptor :token))
                              (ourro.reflex.effects:effect-condition-recoveries
                               condition)))))
             (sb-ext:timeout ()
               (list :status :failed :error :deadline-exceeded))
             (serious-condition (condition)
               (list :status :failed :error (princ-to-string condition))))))
    (submit-command
     (list :type :effect-result :instance-id (pget intent :instance-id)
           :intent-id (pget intent :intent-id)
           :status (if (member (pget result :status)
                               '(:succeeded :virtual-succeeded))
                       :succeeded :failed)
           :result (pget result :result)
           :recoveries (pget result :recoveries)))
    result))

(defun drain-effects (&key (limit most-positive-fixnum))
  "Run queued effects outside the serialized transition lock."
  (loop repeat limit
        for intent = (bt:with-lock-held (*runtime-lock*)
                       (when (and (runtime-control-armed *runtime-control*)
                                  *pending-intents*)
                         (let ((intent (pop *pending-intents*)))
                           (setf (gethash (pget intent :intent-id)
                                          *inflight-intents*) intent)
                           intent)))
        while intent
        collect
        (run-effect-intent intent :virtual *virtual-effects*)))

(defun recover-runtime (workspace)
  "Reconstruct durable instances and unresolved effects for one workspace."
  (bt:with-lock-held (*runtime-lock*)
    (setf *instances* (make-hash-table :test #'equal)
          *pending-intents* '()
          *inflight-intents* (make-hash-table :test #'equal)
          *suspended-intents* (make-hash-table :test #'equal)
          *runtime-timers* (make-hash-table :test #'equal))
    (let* ((records (reverse (ourro.reflex.journal:query-records
                             :workspace workspace)))
           (intent-by-id (make-hash-table :test #'equal))
           (terminal (make-hash-table :test #'equal)))
      (dolist (record records)
        (let ((snapshot (pget record :instance-snapshot)))
          (when snapshot
            (let ((instance (snapshot-instance snapshot)))
              (setf (gethash (runtime-instance-id instance) *instances*) instance))))
        (when (eq :effect-intent (pget record :record-kind))
          (setf (gethash (pget record :intent-id) intent-by-id) record))
        (when (and (eq :effect-attempt (pget record :record-kind))
                   (terminal-effect-status-p (pget record :status)))
          ;; RECORDS are oldest first, so this retains the newest terminal
          ;; attempt (for example a success after an explicit retry).
          (setf (gethash (pget record :intent-id) terminal) record))
        (case (pget record :kind)
          (:timer-scheduled
           (setf (gethash (pget record :timer-id) *runtime-timers*)
                 (list :timer-id (pget record :timer-id)
                       :due-unix (pget record :due-unix)
                       :event (pget record :event)
                       :workspace (pget record :workspace))))
          ((:timer-cancelled :timer-fired)
           (remhash (pget record :timer-id) *runtime-timers*))
          (:runtime-frozen
           (setf (runtime-control-frozen *runtime-control*) t))
          (:runtime-unfrozen
           (setf (runtime-control-frozen *runtime-control*) nil))))
      (maphash
       (lambda (id intent)
         (let ((terminal-record (gethash id terminal))
               (instance (gethash (pget intent :instance-id) *instances*)))
           (if terminal-record
               (recover-terminal-effect intent terminal-record)
               (let ((decision
                       (if (and (eq :non-repeatable (pget intent :recovery-class))
                                (zerop (automatic-retry-count records id)))
                           ;; The durable start boundary was never crossed, so
                           ;; even a non-repeatable adapter is safe to begin.
                           (list :decision :retry :intent intent
                                 :reason :not-started-before-crash)
                           (handler-case
                               (sb-ext:with-timeout 2
                                 (ourro.reflex.effects:reconcile-effect-intent intent))
                             (error (condition)
                               (list :decision :pause :reason :reconcile-failed
                                     :error (princ-to-string condition)))))))
                 (case (pget decision :decision)
                   (:retry
                    (if (< (automatic-retry-count records id)
                           (or (pget intent :max-attempts) 3))
                        (push intent *pending-intents*)
                        (pause-recovered-intent
                         instance intent
                         (list :decision :pause
                               :reason :automatic-retry-budget-exhausted
                               :attempts (automatic-retry-count records id)))))
                   (:reconciled
                    (when instance
                      (append-runtime-record
                       :effect-reconciled (runtime-instance-workspace instance)
                       :instance-id (runtime-instance-id instance)
                       :intent-id id :decision decision)
                      (advance-instance instance :activity-results
                                        (pget decision :result))))
                   (t (pause-recovered-intent instance intent decision)))))))
       intent-by-id)
      (maphash
       (lambda (id instance)
         (declare (ignore id))
         (let ((intent-id (pget (runtime-instance-pending-decision instance)
                                :intent-id)))
           (when (and intent-id (gethash intent-id intent-by-id))
             (setf (gethash intent-id *suspended-intents*)
                   (gethash intent-id intent-by-id)))))
       *instances*)
      (list :instances (hash-table-count *instances*)
            :pending-effects (length *pending-intents*)))))

(defun simulate-event (event)
  "Run EVENT with virtual adapters only; never invokes a live effect hook."
  (let ((*virtual-effects* t))
    (let ((instances (submit-command (list :type :external-event :event event))))
      (drain-effects)
      instances)))

(defun runtime-worker-running-p ()
  (runtime-control-worker-running *runtime-control*))

(defun quoted-thread-binding (symbol value)
  (cons symbol (list 'quote value)))

(defun runtime-thread-bindings ()
  "Explicitly propagate causal/runtime context; CL thread inheritance is undefined."
  (append
   (ourro.reflex.journal:journal-thread-bindings)
   (list
    (quoted-thread-binding 'ourro.reflex.compiler:*version-registry*
                           ourro.reflex.compiler:*version-registry*)
    (quoted-thread-binding 'ourro.reflex.compiler:*active-version-pointers*
                           ourro.reflex.compiler:*active-version-pointers*)
    (quoted-thread-binding 'ourro.reflex.compiler:*canary-routes*
                           ourro.reflex.compiler:*canary-routes*)
    (quoted-thread-binding 'ourro.reflex.effects:*effect-hooks*
                           ourro.reflex.effects:*effect-hooks*)
    (quoted-thread-binding 'ourro.reflex.effects:*effect-adapters*
                           ourro.reflex.effects:*effect-adapters*))
   bt:*default-special-bindings*))

(defun inflight-count-for-workspace (workspace)
  (let ((count 0))
    (maphash (lambda (id intent)
               (declare (ignore id))
               (when (string= workspace (pget intent :workspace)) (incf count)))
             *inflight-intents*)
    count))

(defun intent-dispatchable-p (intent)
  (and (or (not (runtime-control-foreground *runtime-control*))
           (>= (or (pget intent :priority) 0)
               *foreground-priority-threshold*))
       (< (inflight-count-for-workspace (pget intent :workspace))
          *workspace-effect-concurrency*)))

(defun take-dispatchable-intent ()
  (bt:with-lock-held (*runtime-lock*)
    (when (and (runtime-control-armed *runtime-control*)
               (not (runtime-control-shutdown *runtime-control*))
               (< (hash-table-count *inflight-intents*)
                  *maximum-effect-workers*))
      (let ((intent (find-if #'intent-dispatchable-p *pending-intents*)))
        (when intent
          (setf *pending-intents* (delete intent *pending-intents* :count 1))
          (setf (gethash (pget intent :intent-id) *inflight-intents*) intent)
          intent)))))

(defun effect-start-decision (intent)
  "Close the dequeue/disarm race under the actor lock."
  (bt:with-lock-held (*runtime-lock*)
    (cond
      ((or (not (runtime-control-armed *runtime-control*))
           (runtime-control-shutdown *runtime-control*)
           (null (gethash (pget intent :intent-id) *inflight-intents*)))
       (remhash (pget intent :intent-id) *inflight-intents*)
       (ignore-errors
         (ourro.reflex.effects:cancel-effect-intent
          intent :invalidated-at-start-boundary))
       :cancel)
      ((and (runtime-control-foreground *runtime-control*)
            (< (or (pget intent :priority) 0) *foreground-priority-threshold*))
       (remhash (pget intent :intent-id) *inflight-intents*)
       (enqueue-intent intent)
       :defer)
      (t :start))))

(defun execute-supervised-intent (intent start-gate)
  (bt:wait-on-semaphore start-gate)
  (unwind-protect
       (when (eq :start (effect-start-decision intent))
         (ignore-errors (run-effect-intent intent)))
    (bt:with-lock-held (*runtime-lock*)
      (remhash (pget intent :intent-id) *effect-worker-threads*)
      ;; HANDLE-EFFECT-RESULT normally removes this first.  Unconditionally
      ;; repeat the removal so a reporting error, cancellation, or timeout can
      ;; never strand a phantom in-flight slot.
      (remhash (pget intent :intent-id) *inflight-intents*))
    (bt:signal-semaphore *runtime-worker-semaphore*)))

(defun dispatch-pending-effects ()
  (loop for intent = (take-dispatchable-intent)
        while intent do
          ;; LOOP reuses its iteration binding. Capture this particular intent
          ;; before the worker crosses the gate, otherwise a fast manager can
          ;; advance the shared binding to NIL before the closure runs.
          (let* ((dispatched-intent intent)
                 (gate (bt:make-semaphore :name "ourro-effect-start"))
                 (thread
                   (bt:make-thread
                    (lambda ()
                      (execute-supervised-intent dispatched-intent gate))
                    :name (format nil "ourro-effect-~A"
                                  (pget dispatched-intent :intent-id))
                    :initial-bindings (runtime-thread-bindings))))
            (bt:with-lock-held (*runtime-lock*)
              (setf (gethash (pget dispatched-intent :intent-id)
                             *effect-worker-threads*) thread))
            (bt:signal-semaphore gate))))

(defun fire-due-timers ()
  (let ((due '()))
    (bt:with-lock-held (*runtime-lock*)
      (when (and (runtime-control-armed *runtime-control*)
                 (not (runtime-control-frozen *runtime-control*))
                 (not (runtime-control-shutdown *runtime-control*)))
        (maphash
         (lambda (id timer)
           (when (<= (pget timer :due-unix) (unix-time))
             (push timer due)
             (remhash id *runtime-timers*)
             (append-runtime-record
              :timer-fired (pget timer :workspace)
              :timer-id id :due-unix (pget timer :due-unix))))
         *runtime-timers*)))
    (dolist (timer due)
      (ignore-errors
        (submit-command (list :type :external-event :event (pget timer :event)))))
    (length due)))

(defun drain-runtime-dispatch-queue ()
  (let ((events
          (bt:with-lock-held (*dispatch-queue-lock*)
            (prog1 (nreverse *dispatch-queue*)
              (setf *dispatch-queue* '())))))
    (dolist (event events)
      (handler-case
          (submit-command (list :type :external-event :event event))
        (serious-condition (condition)
          (ignore-errors
            (append-runtime-record
             :runtime-dispatch-error (or (pget event :workspace)
                                         "workspace:unknown")
             :causation-id (pget event :event-id)
             :source-kind (pget event :kind)
             :error (princ-to-string condition))))))
    (length events)))

(defun runtime-worker-loop ()
  ;; This actor only dispatches bounded workers. A slow provider never occupies
  ;; the serialized transition/timer/status lane.
  (loop while (runtime-control-worker-running *runtime-control*) do
    (bt:wait-on-semaphore *runtime-worker-semaphore* :timeout 0.05)
    (handler-case
        (progn (drain-runtime-dispatch-queue)
               (fire-due-timers)
               (dispatch-pending-effects))
      (serious-condition (condition)
        (ignore-errors
          (append-runtime-record :worker-error "workspace:system"
                                 :error (princ-to-string condition)))))))

(defun start-runtime-worker ()
  (unless (runtime-control-worker-running *runtime-control*)
    (setf *runtime-shutdown* nil
          (runtime-control-shutdown *runtime-control*) nil
          *runtime-worker-running* t
          (runtime-control-worker-running *runtime-control*) t
          *runtime-worker-thread*
          (bt:make-thread #'runtime-worker-loop :name "ourro-durable-reflex"
                          :initial-bindings (runtime-thread-bindings))))
  *runtime-worker-thread*)

(defun stop-runtime-worker ()
  (ignore-errors
    (submit-command (list :type :shutdown :workspace "workspace:system")))
  (setf *runtime-worker-running* nil
        (runtime-control-worker-running *runtime-control*) nil)
  (bt:signal-semaphore *runtime-worker-semaphore*)
  (let ((thread *runtime-worker-thread*))
    (when (and thread (not (eq thread (bt:current-thread))))
      (ignore-errors (sb-thread:join-thread thread :timeout 0.5 :default :timeout)))
    (setf *runtime-worker-thread* nil))
  (bt:with-lock-held (*dispatch-queue-lock*)
    (setf *dispatch-queue* '()))
  ;; Adapter threads are supervised work units. Give cooperative timeout
  ;; unwinds a bounded window, then terminate any unsafe stuck thread so image
  ;; shutdown never waits indefinitely.
  (let ((threads '()))
    (bt:with-lock-held (*runtime-lock*)
      (maphash (lambda (id thread) (push (cons id thread) threads))
               *effect-worker-threads*))
    (dolist (pair threads)
      (let ((thread (cdr pair)))
        (when (and thread (bt:thread-alive-p thread))
          (multiple-value-bind (result reason)
              (sb-thread:join-thread thread :timeout 0.1 :default :timeout)
            (declare (ignore result))
            (when (eq reason :timeout)
              (ignore-errors (bt:destroy-thread thread)))))))
    (bt:with-lock-held (*runtime-lock*)
      (setf *effect-worker-threads* (make-hash-table :test #'equal)
            *inflight-intents* (make-hash-table :test #'equal))))
  t)

(defun quarantine-version-instances (name hash)
  "Runtime half of the version invocation barrier used by exact rollback."
  (let ((workers '()) (unresolved '()) (instances '()))
    (bt:with-lock-held (*runtime-lock*)
      (setf instances
            (remove-if-not
             (lambda (instance)
               (and (string= name (runtime-instance-reflex-name instance))
                    (string= hash (runtime-instance-version-hash instance))))
             (loop for instance being the hash-values of *instances*
                   collect instance)))
      (cancel-pending-intents
       (lambda (intent) (string= hash (pget intent :reflex-version)))
       :version-quarantined)
      (maphash
       (lambda (id intent)
         (when (string= hash (pget intent :reflex-version))
           (push intent unresolved)
           (let ((thread (gethash id *effect-worker-threads*)))
             (when thread (push thread workers)))
           (remhash id *inflight-intents*)
           (remhash id *effect-worker-threads*)))
       *inflight-intents*)
      (dolist (instance instances)
        (setf (runtime-instance-status instance) :quarantined
              (runtime-instance-pending-decision instance) nil)
        (append-runtime-record
         :instance-quarantined (runtime-instance-workspace instance)
         :instance-id (runtime-instance-id instance)
         :reflex-version hash :instance-snapshot (instance-snapshot instance))))
    (dolist (worker workers)
      (when (bt:thread-alive-p worker)
        (ignore-errors (bt:destroy-thread worker))))
    ;; Never retry while rolling back. Record the adapter-specific assessment
    ;; so an ambiguous/non-repeatable crossing remains visible.
    (dolist (intent unresolved)
      (let ((decision
              (handler-case
                  (sb-ext:with-timeout 2
                    (ourro.reflex.effects:reconcile-effect-intent intent))
                (error (condition)
                  (list :decision :pause :reason :reconcile-failed
                        :error (princ-to-string condition))))))
        (ignore-errors
          (append-runtime-record
           :rollback-effect-reconciled (pget intent :workspace)
           :instance-id (pget intent :instance-id)
           :intent-id (pget intent :intent-id)
           :reflex-version hash :decision decision))))
    (list :version hash :instances (length instances)
          :unresolved-effects (length unresolved) :acknowledged t)))

(defun migrate-quarantined-version-state (name from-hash target-hash)
  "Project quarantined instances onto TARGET-HASH's explicit state schema."
  (let* ((from (ourro.reflex.compiler:find-reflex-version name from-hash))
         (target (ourro.reflex.compiler:find-reflex-version name target-hash))
         (from-schema (and from
                           (pget (ourro.reflex.model:reflex-state-schema
                                  (ourro.reflex.model:version-definition from))
                                 :version)))
         (target-schema (and target
                             (pget (ourro.reflex.model:reflex-state-schema
                                    (ourro.reflex.model:version-definition target))
                                   :version)))
         (migrated 0))
    (unless (and from target (integerp from-schema) (integerp target-schema))
      (error "rollback versions require explicit integer state schemas"))
    (bt:with-lock-held (*runtime-lock*)
      (maphash
       (lambda (id instance)
         (declare (ignore id))
         (when (and (string= name (runtime-instance-reflex-name instance))
                    (string= from-hash
                             (runtime-instance-version-hash instance)))
           (let ((state
                   (if (= from-schema target-schema)
                       (copy-tree (runtime-instance-state instance))
                       (ourro.reflex.model:migrate-reflex-state
                        name (runtime-instance-state instance)
                        from-schema target-schema))))
             (setf (runtime-instance-state instance) state
                   (runtime-instance-version-hash instance) target-hash
                   ;; Historical work never resumes implicitly across rollback.
                   ;; A later trusted decision may explicitly restart it on N.
                   (runtime-instance-status instance) :paused
                   (runtime-instance-updated-at instance) (unix-time))
             (append-runtime-record
              :instance-state-rollback-migrated
              (runtime-instance-workspace instance)
              :instance-id (runtime-instance-id instance)
              :rollback-from from-hash :reflex-version target-hash
              :from-schema from-schema :to-schema target-schema
              :instance-snapshot (instance-snapshot instance))
             (incf migrated))))
       *instances*))
    (list :from from-hash :target target-hash :migrated migrated
          :acknowledged t)))

;; Compiler closes routing first, then this barrier prevents any pinned N+1
;; closure or effect from advancing before rollback acknowledgment.
(setf ourro.reflex.compiler:*version-quarantine-hook*
      #'quarantine-version-instances)
(setf ourro.reflex.compiler:*version-rollback-hook*
      #'migrate-quarantined-version-state)

(defun install-runtime-dispatch ()
  "Route persisted product events into the durable actor; never run effects inline."
  (ourro.observe:add-event-subscriber
   :durable-reflex-runtime
   (lambda (event)
     (unless (or (eq :runtime-transition (pget event :record-kind))
                 (not (ourro.observe:observation-admitted-p event)))
       ;; Publishing is an enqueue-only boundary. Matching, transition WAL
       ;; writes, and error records run on the durable runtime worker.
       (bt:with-lock-held (*dispatch-queue-lock*)
         (push event *dispatch-queue*))
       (bt:signal-semaphore *runtime-worker-semaphore*))))
  (start-runtime-worker)
  :durable-reflex-runtime)

(defun remove-runtime-dispatch ()
  (ourro.observe:remove-event-subscriber :durable-reflex-runtime)
  (stop-runtime-worker))

(defun purge-runtime-workspace (workspace)
  "Cancel and remove every transient actor/effect/timer owned by WORKSPACE.
The journal's append barrier is already closed when this hook runs, so a late
effect worker cannot recreate the partition during deletion."
  (let ((workspace (ourro.reflex.journal:normalize-workspace workspace))
        (pending '()) (workers '()) (instance-ids '()) (timer-ids '()))
    (bt:with-lock-held (*dispatch-queue-lock*)
      (setf *dispatch-queue*
            (remove workspace *dispatch-queue* :test #'string=
                    :key (lambda (event) (pget event :workspace)))))
    (bt:with-lock-held (*runtime-lock*)
      (setf pending
            (remove-if-not
             (lambda (intent) (string= workspace (pget intent :workspace)))
             *pending-intents*))
      (setf *pending-intents*
            (remove-if (lambda (intent)
                         (string= workspace (pget intent :workspace)))
                       *pending-intents*))
      (let ((inflight-ids '()))
        (maphash
         (lambda (id intent)
           (when (string= workspace (pget intent :workspace))
             (push id inflight-ids)
             (let ((worker (gethash id *effect-worker-threads*)))
               (when worker (push worker workers)))))
         *inflight-intents*)
        (dolist (id inflight-ids)
          (remhash id *inflight-intents*)
          (remhash id *effect-worker-threads*)))
      (let ((suspended-ids '()))
        (maphash
         (lambda (id intent)
           (when (string= workspace (pget intent :workspace))
             (push id suspended-ids)))
         *suspended-intents*)
        (dolist (id suspended-ids) (remhash id *suspended-intents*)))
      (maphash
       (lambda (id instance)
         (when (string= workspace (runtime-instance-workspace instance))
           (setf (runtime-instance-status instance) :cancelled
                 (runtime-instance-pending-decision instance) nil)
           (push id instance-ids)))
       *instances*)
      (dolist (id instance-ids) (remhash id *instances*))
      (maphash
       (lambda (id timer)
         (when (string= workspace (pget timer :workspace))
           (push id timer-ids)))
       *runtime-timers*)
      (dolist (id timer-ids) (remhash id *runtime-timers*)))
    (dolist (worker workers)
      (when (and worker (bt:thread-alive-p worker))
        (ignore-errors (bt:destroy-thread worker))))
    (when (some #'bt:thread-alive-p workers)
      (error "workspace effect workers did not terminate"))
    (list :instances (length instance-ids)
          :pending-effects (length pending)
          :inflight-effects (length workers)
          :timers (length timer-ids))))

(ourro.reflex.journal:register-workspace-deletion-hook
 :reflex-runtime #'purge-runtime-workspace)
