
(defpackage #:ourro.automation
  (:use #:cl)
  (:import-from #:ourro.util
                #:pget #:plist-put #:make-id #:truncate-string)
  (:export ;; the OURRO.API surface (imported + re-exported by genome.lisp)
           #:define-automation
           #:post-note
           #:fire-automation-for-test
           ;; registry
           #:*automations*
           #:*automations-lock*
           #:register-automation
           #:unregister-automation
           #:find-automation
           #:list-automations
           #:copy-automations
           #:reset-automations
           #:automation
           #:automation-name
           #:automation-gene
           #:automation-trigger
           #:automation-action-fn
           #:automation-capabilities
           #:automation-cooldown
           #:automation-defer
           #:automation-strikes
           #:automation-last-fired
           #:automation-version
           ;; matching (pure)
           #:event-matches-p
           #:value-matches-p
           #:resolve-defer
           ;; dispatch + worker
           #:dispatch-event
           #:install-automation-dispatch
           #:remove-automation-dispatch
           #:start-reflex-worker
           #:stop-reflex-worker
           #:reflex-worker-running-p
           #:set-reflex-armed
           #:tick-automations
           #:flush-deferred-automations
           #:firing-queue-length
           #:cancel-pending-firings
           #:*firings-dropped*
           #:*automation-timeout-seconds*
           #:*in-automation-context*
           #:*politeness-hook*
           #:experimental-reflexes-enabled-p
           ;; notes
           #:*note-sink*
           #:drain-notes
           #:pending-note-count
           ;; investigations (M15-3)
           #:request-investigation
           #:*investigation-hook*
           #:drain-investigations
           #:pending-investigation-count))

(in-package #:ourro.automation)


(defstruct (automation (:constructor %make-automation))
  (name "" :type string)
  (gene nil)                            ; owning gene name string, or NIL
  (trigger '() :type list)              ; the :on pattern (pure data)
  (action-fn nil :type (or null function))
  (capabilities '() :type list)
  (cooldown 30)
  (defer :immediate)
  (strikes 0)                           ; post-probation error count (worker only)
  (last-fired 0.0d0)                    ; internal-real-time seconds of last fire
  (idle-armed t)                        ; :idle re-arms after the user acts again
  (version 0 :type integer))            ; immutable registry publication epoch

(defvar *automations* '()
  "List of AUTOMATION structs, newest first. Special so the verifier can stage
a candidate's load-time DEFINE-AUTOMATION against a copy (D-R5).")
(defvar *automations-lock* (bt:make-lock "ourro-automations"))
(defvar *automation-version* 0)

(defvar *deferred* (make-hash-table :test #'equal)
  "name → the latest coalesced firing for a :turn-boundary automation, flushed
at the turn boundary (D-R4). Guarded by *AUTOMATIONS-LOCK*.")

(defun now-seconds ()
  (/ (get-internal-real-time) (float internal-time-units-per-second 1.0d0)))

(defparameter +never-fired+ -1.0d12
  "The LAST-FIRED sentinel for an automation that has never fired. Far enough
below any NOW-SECONDS (process uptime) that the first COOLDOWN-OK-P is always
true — a plain 0 would wrongly suppress a first fire early in a young process.")

(defun canonical-name (name)
  (string-downcase (string name)))

(defun find-automation (name)
  (let ((key (canonical-name name)))
    (bt:with-lock-held (*automations-lock*)
      (find key *automations* :key #'automation-name :test #'string=))))

(defun list-automations ()
  (bt:with-lock-held (*automations-lock*) (copy-list *automations*)))

(defun copy-automations (&optional (source *automations*))
  "A shallow copy of the automation list, for staging isolation (verifier)."
  (copy-list source))

(defun reset-automations ()
  "Clear the registry and the deferred set (tests)."
  (bt:with-lock-held (*automations-lock*)
    (setf *automations* '())
    (clrhash *deferred*)))

(defun resolve-defer (trigger explicit)
  "The effective deferral mode. Explicit non-:auto wins; otherwise
:tool-call/:user-message/:correction triggers debounce to the turn boundary,
everything else fires immediately (D-R4)."
  (if (and explicit (not (eq explicit :auto)))
      explicit
      (let ((kind (getf trigger :kind)))
        (if (member kind '(:tool-call :user-message :correction))
            :turn-boundary
            :immediate))))

(defun register-automation (name &key trigger action-fn cooldown defer)
  "Install an automation. Captures the loading gene's name + capabilities from
OURRO.KERNEL:*CURRENT-GENE-CONTEXT* (exactly like DEFTOOL) and records an
owner-checked revert-action so REVERT-GENE-DEFINITIONS removes it (D-R3). Called
at gene load time by the DEFINE-AUTOMATION expansion."
  (let* ((name (canonical-name name))
         (context ourro.kernel:*current-gene-context*)
         (gene (pget context :name))
         (caps (or (pget context :capabilities) '()))
         (effective-defer (resolve-defer trigger defer))
         (previous (find-automation name))
         (version (bt:with-lock-held (*automations-lock*)
                    (incf *automation-version*)))
         (a (%make-automation
             :name name :gene gene :trigger trigger :action-fn action-fn
             :capabilities caps
             :cooldown (or cooldown 30)
             :defer effective-defer
             :version version
             ;; :every counts its interval from registration; everything else
             ;; starts "never fired" so cooldown never suppresses the first hit.
             :last-fired (if (getf trigger :every) (now-seconds) +never-fired+))))
    (unregister-automation name)
    (bt:with-lock-held (*automations-lock*)
      (push a *automations*))
    (when gene
      (ourro.kernel:record-revert-action
       gene
       (lambda ()
         ;; Undo only this publication. A later replacement with the same name
         ;; is a distinct version and must not be removed by a stale frame.
         (let ((current (find-automation name)))
           (when (and current (= (automation-version current) version))
             (unregister-automation name)
             (when previous
               (bt:with-lock-held (*automations-lock*)
                 (push previous *automations*))))))
       :description (format nil "restore automation ~A version ~D" name version)))
    name))

(defun unregister-automation (name)
  (let ((key (canonical-name name)))
    (bt:with-lock-held (*automations-lock*)
      (setf *automations*
            (remove key *automations* :key #'automation-name :test #'string=))
      (remhash key *deferred*))))


(defun find-symbol-named (name tree)
  "The first symbol in TREE whose name is NAME, or NIL. Reused to bind the
gene author's own EVENT symbol (the DEFTOOL RESULT trick) rather than interning
a fresh one under an unreliable *package*."
  (labels ((walk (x)
             (cond ((and (symbolp x) x (string= (symbol-name x) name)) x)
                   ((consp x) (or (walk (car x)) (walk (cdr x))))
                   (t nil))))
    (walk tree)))

(defmacro define-automation (name options &body body)
  "Register a trigger-driven automation named NAME.

  (define-automation run-tests
      (:on (:kind :tool-call :tool \"edit_file\" :outcome :ok
            :args (:path (:matches \"\\\\.lisp$\")))
       :cooldown 30 :defer :turn-boundary)
    (start-job \"make test\")
    (post-note \"tests running\" :style :info))

OPTIONS is a plist: :on <pattern> (required), :cooldown seconds (default 30),
:defer :immediate|:turn-boundary|:auto. The action BODY runs when the pattern
matches; the matched EVENT plist is bound if BODY names it. Requires the
:automate capability; long work must go through START-JOB."
  (let* ((on (getf options :on))
         (cooldown (getf options :cooldown 30))
         (defer (getf options :defer))
         (event-var (or (find-symbol-named "EVENT" body) (gensym "EVENT"))))
    `(register-automation ,(canonical-name name)
                          :trigger ',on
                          :cooldown ,cooldown
                          :defer ,(or defer :auto)
                          :action-fn (lambda (,event-var)
                                       (declare (ignorable ,event-var))
                                       ,@body))))


(defparameter *value-operators* '(:not :any :matches :> :<))

(defun value-matches-p (form actual)
  "Whether ACTUAL satisfies the trigger value FORM. Value forms: a literal
(EQUAL), (:not x), (:any x y…), (:matches \"regex\"), (:> n), (:< n), or a
nested plist to descend into a plist-valued field."
  (cond
    ((and (consp form) (member (first form) *value-operators*))
     (ecase (first form)
       (:not (not (value-matches-p (second form) actual)))
       (:any (some (lambda (f) (value-matches-p f actual)) (rest form)))
       (:matches (and (stringp actual)
                      (ignore-errors (cl-ppcre:scan (second form) actual)) t))
       (:> (and (realp actual) (> actual (second form))))
       (:< (and (realp actual) (< actual (second form))))))
    ;; A cons whose head is a (non-operator) keyword is a nested pattern plist:
    ;; descend into the plist-valued field (:args (:path (:matches …))).
    ((and (consp form) (keywordp (first form)))
     (and (listp actual) (plist-matches-p form actual)))
    (t (equal form actual))))

(defun plist-matches-p (pattern plist)
  "Every key in PATTERN (a plist) matches the same key in PLIST."
  (loop for (key value) on pattern by #'cddr
        always (value-matches-p value (getf plist key))))

(defun event-matches-p (pattern event)
  "Whether EVENT (a logged event plist) matches trigger PATTERN. :idle/:every
patterns never match a concrete event — they fire from TICK-AUTOMATIONS — so
this returns NIL for them."
  (cond ((or (getf pattern :idle) (getf pattern :every)) nil)
        (t (plist-matches-p pattern event))))


(defparameter *automation-timeout-seconds* 60
  "Wall-clock cap on one automation firing — runaway protection only. Long work
must go through START-JOB (a detached subprocess), never block the reflex
worker.")
(defparameter *firing-queue-cap* 64
  "Bounded firing queue: past this, firings are dropped (and counted) rather
than let an event storm grow memory without bound.")

(defvar *firing-queue* '() "FIFO of pending firings (plists).")
(defvar *firing-lock* (bt:make-lock "ourro-reflex-queue"))
(defvar *firing-sem* (bt:make-semaphore :name "ourro-reflex"))
(defvar *firings-dropped* 0 "Count of firings dropped on queue overflow.")
(defvar *dispatch-epoch* 0
  "Incremented on disarm; queued/dequeued work from an older epoch is inert.")
(defvar *execution-lock* (bt:make-lock "ourro-reflex-execution")
  "Serializes the final armed check/action with disarm completion.")
(defvar *investigation-queue* '() "Pending investigation requests, FIFO.")
(defvar *investigation-lock* (bt:make-lock "ourro-investigations"))

(defvar *in-automation-context* nil
  "Bound true on the reflex worker while an action runs, so events the action
logs (its own tool calls) never recursively dispatch — the cascade guard.")

(defvar *politeness-hook* nil
  "Optional 0-arg thunk the worker calls before a firing to wait while a user
turn is busy (the *politeness-hook* pattern, capped by the caller).")

(defvar *experimental-reflexes-override* :config
  "Test/development seam. :CONFIG reads config :experimental-reflexes; T/NIL force
the decision without touching the config file or the process environment.")

(defun experimental-reflexes-enabled-p ()
  "Whether Gate-0-incomplete background reflex execution is explicitly enabled."
  (if (eq *experimental-reflexes-override* :config)
      (and (ourro.config:setting :experimental-reflexes) t)
      (and *experimental-reflexes-override* t)))

(defun firing-queue-length ()
  (bt:with-lock-held (*firing-lock*) (length *firing-queue*)))

(defun enqueue-firing (firing)
  "Append FIRING to the bounded queue and wake the worker. Drops (and counts)
on overflow."
  (let ((enqueued nil))
    (bt:with-lock-held (*firing-lock*)
      (when (and ourro.kernel:*automations-armed*
                 (= (getf firing :dispatch-epoch -1) *dispatch-epoch*))
        (if (>= (length *firing-queue*) *firing-queue-cap*)
            (incf *firings-dropped*)
            (progn (setf *firing-queue*
                         (nconc *firing-queue* (list firing)))
                   (setf enqueued t)))))
    (when enqueued (bt:signal-semaphore *firing-sem*))
    enqueued))

(defun pop-firing ()
  (bt:with-lock-held (*firing-lock*)
    (when *firing-queue* (pop *firing-queue*))))

(defun make-firing (automation event trigger-kind)
  (list :automation-name (automation-name automation)
        :automation-version (automation-version automation)
        :dispatch-epoch *dispatch-epoch*
        :event event :trigger-kind trigger-kind))

(defun firing-automation-unlocked (firing)
  (let ((a (find (getf firing :automation-name) *automations*
                 :key #'automation-name :test #'string=)))
    (and a
         (= (automation-version a) (getf firing :automation-version))
         a)))

(defun firing-automation (firing)
  "Resolve a queued firing against the current immutable registry version."
  (bt:with-lock-held (*automations-lock*)
    (firing-automation-unlocked firing)))

(defun cooldown-ok-p (automation now)
  (>= (- now (automation-last-fired automation)) (automation-cooldown automation)))

(defun note-strike (automation condition)
  "Post-probation error accounting: three strikes retires the automation via
REVERT-GENE-DEFINITIONS + the amber-ticker *PROBATION-FAILURE-HOOK* (the
retire-ui-owner pattern). Runs on the single worker thread only."
  (incf (automation-strikes automation))
  (when (>= (automation-strikes automation) 3)
    (let ((gene (automation-gene automation)))
      (if gene
          (progn
            (ignore-errors (ourro.kernel:revert-gene-definitions gene))
            (when ourro.kernel:*probation-failure-hook*
              (ignore-errors
               (funcall ourro.kernel:*probation-failure-hook* gene condition))))
          ;; No owning gene (a test automation): just drop it.
          (unregister-automation (automation-name automation))))))

(defun run-firing (firing)
  "Execute one firing under the gene's caps, a wall-clock timeout, probation,
and three-strikes. Called only on the reflex worker."
  (let ((a (and ourro.kernel:*automations-armed*
                (= (getf firing :dispatch-epoch -1) *dispatch-epoch*)
                (firing-automation firing))))
    (unless a (return-from run-firing nil))
    (when *politeness-hook* (ignore-errors (funcall *politeness-hook*)))
    ;; The final check/action shares a lock with SET-REFLEX-ARMED. A dequeued
    ;; firing waiting in the politeness hook is invalidated before it starts;
    ;; if an action already started, disarm joins it before returning.
    (bt:with-lock-held (*execution-lock*)
      (setf a (and ourro.kernel:*automations-armed*
                   (= (getf firing :dispatch-epoch -1) *dispatch-epoch*)
                   (firing-automation firing)))
      (unless a (return-from run-firing nil))
      (let ((event (getf firing :event))
            (gene (automation-gene a))
            (caps (automation-capabilities a)))
        (handler-case
            (let ((*in-automation-context* t))
              (ourro.observe:with-timed-event
                  (:automation-fire :gene gene :automation (automation-name a)
                                    :trigger-kind (getf firing :trigger-kind))
                (ourro.kernel:with-capabilities caps
                  ;; Convert SB-EXT:TIMEOUT (a SERIOUS-CONDITION) to ERROR so
                  ;; probation, strike accounting, and event logging all see it.
                  (flet ((act ()
                           (handler-case
                               (sb-ext:with-timeout *automation-timeout-seconds*
                                 (funcall (automation-action-fn a) event))
                             (sb-ext:timeout ()
                               (error "automation ~A exceeded its ~As watchdog — ~
long work must go through start-job"
                                      (automation-name a)
                                      *automation-timeout-seconds*)))))
                    (if gene
                        (ourro.kernel:with-probation (gene) (act))
                        (act))))))
          ;; Probation already reverted the gene and fired the amber ticker.
          (ourro.kernel:evolved-code-failure () nil)
          (error (c) (note-strike a c)))))))

(defvar *reflex-worker-running* nil)
(defvar *reflex-worker-thread* nil)

(defun reflex-worker-running-p () *reflex-worker-running*)

(defun reflex-worker-loop ()
  (loop while *reflex-worker-running* do
    (when (bt:wait-on-semaphore *firing-sem* :timeout 0.5)
      (let ((firing (pop-firing)))
        (when firing
          ;; Catch SERIOUS-CONDITION, not just ERROR: a gene signalling a
          ;; non-error serious-condition (storage-condition, an interrupt) must
          ;; not unwind the loop and permanently kill the reflex worker with no
          ;; restart path (review MED/LOW). The worker survives to the next firing.
          (handler-case (run-firing firing)
            (serious-condition () nil))))
      ;; Drain any investigations a firing (or a prior wake) queued — off the
      ;; firing's watchdog, serialized on this one worker (M15-1).
      (handler-case (drain-investigations)
        (serious-condition () nil)))))

(defun start-reflex-worker ()
  "Start the single ourro-reflex worker if it is not already running."
  (unless (experimental-reflexes-enabled-p)
    (return-from start-reflex-worker nil))
  (unless *reflex-worker-running*
    (setf *reflex-worker-running* t
          *reflex-worker-thread*
          (bt:make-thread #'reflex-worker-loop :name "ourro-reflex")))
  *reflex-worker-thread*)

(defun stop-reflex-worker ()
  (setf *reflex-worker-running* nil)
  (bt:signal-semaphore *firing-sem*)
  (let ((thread *reflex-worker-thread*))
    (when (and thread (not (eq thread (bt:current-thread))))
      (ignore-errors (bt:join-thread thread)))
    (setf *reflex-worker-thread* nil)))

(defun cancel-pending-firings ()
  "Atomically discard queued and turn-boundary-deferred effects."
  (bt:with-lock-held (*firing-lock*)
    (incf *dispatch-epoch*)
    (setf *firing-queue* '()))
  (bt:with-lock-held (*automations-lock*) (clrhash *deferred*))
  (bt:with-lock-held (*investigation-lock*)
    (setf *investigation-queue* '()))
  t)

(defun set-reflex-armed (armed)
  "Set the kill switch with cancellation/join semantics.

Arming still requires the explicit experimental flag. Disarming invalidates
queued, deferred, and already-dequeued work before returning."
  ;; The flag is the asynchronous kill switch checked at every execution
  ;; boundary. Never wait for *EXECUTION-LOCK*: that lock intentionally spans
  ;; a firing/investigation, which is exactly the work /disarm must stop.
  (setf ourro.kernel:*automations-armed*
        (and armed (experimental-reflexes-enabled-p) t))
  (unless ourro.kernel:*automations-armed*
    (cancel-pending-firings))
  ourro.kernel:*automations-armed*)


(defun dispatch-active-p ()
  (and ourro.kernel:*automations-armed* (not *in-automation-context*)))

(defun dispatch-event (event)
  "The event subscriber: for every registered automation whose trigger matches
EVENT, either enqueue a firing (immediate) or coalesce it into the deferred set
(turn-boundary). Inert while disarmed or inside an automation (cascade guard).
Fast enough to run on any calling thread."
  (when (dispatch-active-p)
    (let ((to-enqueue '())
          (now (now-seconds)))
      (bt:with-lock-held (*automations-lock*)
        (dolist (a *automations*)
          (let ((trigger (automation-trigger a)))
            (when (and (not (getf trigger :idle))
                       (not (getf trigger :every))
                       (event-matches-p trigger event))
              (case (automation-defer a)
                (:turn-boundary
                 ;; Coalesce: keep only the latest matching event per automation.
                 (setf (gethash (automation-name a) *deferred*)
                       (make-firing a event (getf trigger :kind))))
                (t                       ; :immediate
                 (when (cooldown-ok-p a now)
                   (setf (automation-last-fired a) now)
                   (push (make-firing a event (getf trigger :kind))
                         to-enqueue))))))))
      (dolist (firing (nreverse to-enqueue))
        (enqueue-firing firing)))))

(defun flush-deferred-automations ()
  "Move every coalesced turn-boundary firing onto the queue (respecting
cooldown), then clear the deferred set. Called from the turn-boundary worker."
  (unless ourro.kernel:*automations-armed*
    (cancel-pending-firings)
    (return-from flush-deferred-automations 0))
  (let ((to-enqueue '())
        (now (now-seconds)))
    (bt:with-lock-held (*automations-lock*)
      (maphash (lambda (name firing)
                 (declare (ignore name))
                 (let ((a (firing-automation-unlocked firing)))
                   (when (and a (cooldown-ok-p a now))
                     (setf (automation-last-fired a) now)
                     (push firing to-enqueue))))
               *deferred*)
      (clrhash *deferred*))
    (dolist (firing to-enqueue) (enqueue-firing firing))
    (length to-enqueue)))

(defun tick-automations (idle-seconds)
  "Fire due :idle/:every automations. Called once per ui-loop iteration with the
current user idle time. Cheap now-vs-last-fired compares; enqueues, never runs."
  (when ourro.kernel:*automations-armed*
    (let ((to-enqueue '())
          (now (now-seconds)))
      (bt:with-lock-held (*automations-lock*)
        (dolist (a *automations*)
          (let* ((trigger (automation-trigger a))
                 (every (getf trigger :every))
                 (idle (getf trigger :idle)))
            (cond
              (every
               (when (>= (- now (automation-last-fired a)) every)
                 (setf (automation-last-fired a) now)
                 (push (make-firing a nil :every) to-enqueue)))
              (idle
               (cond
                 ((< idle-seconds idle) (setf (automation-idle-armed a) t))
                 ((automation-idle-armed a)
                  (setf (automation-idle-armed a) nil
                        (automation-last-fired a) now)
                  (push (make-firing a nil :idle) to-enqueue))))))))
      (dolist (firing (nreverse to-enqueue)) (enqueue-firing firing)))))

(defun install-automation-dispatch ()
  "Wire DISPATCH-EVENT into the event bus + start the worker. Called by the
agent (WIRE-OBSERVER) on a non-visiting boot."
  (when (experimental-reflexes-enabled-p)
    (ourro.observe:add-event-subscriber :automation-dispatch #'dispatch-event)
    (start-reflex-worker)))

(defun remove-automation-dispatch ()
  (ourro.observe:remove-event-subscriber :automation-dispatch)
  (stop-reflex-worker))


(defvar *pending-notes* '()
  "Note strings awaiting the next user message, newest last. Guarded by
*NOTE-LOCK*. Generalizes the jobs exit-note pattern.")
(defvar *note-lock* (bt:make-lock "ourro-notes"))
(defvar *note-sink* nil
  "Optional (text style) the agent installs so POST-NOTE also raises a ticker
immediately. NIL in tests / bare boot → only the next-message channel is used.")

(defun post-note (text &key (style :info))
  "Surface TEXT without interrupting: a ticker now (via *NOTE-SINK*) and the
same text prefixed to the next user message (drained by SUBMIT-MESSAGE). Never
writes the transcript mid-turn and never touches the system prompt (D-R7,
prompt-cache invariant). Returns TEXT."
  (when (stringp text)
    (bt:with-lock-held (*note-lock*)
      (push text *pending-notes*))
    (when *note-sink* (ignore-errors (funcall *note-sink* text style))))
  text)

(defun drain-notes ()
  "Return pending notes (oldest first) and clear them."
  (bt:with-lock-held (*note-lock*)
    (prog1 (nreverse *pending-notes*) (setf *pending-notes* '()))))

(defun pending-note-count ()
  (bt:with-lock-held (*note-lock*) (length *pending-notes*)))


(defparameter *investigation-queue-cap* 8)
(defvar *investigation-hook* nil
  "Installed by the agent: (prompt &key events title) → runs the mini-turn and
files a briefing. NIL in tests / bare boot → requests are dropped on drain.")

(defun request-investigation (prompt &key events title)
  "Enqueue a background read-only investigation (M15-3). Returns T if enqueued,
NIL if the queue is full. Fast: the mini-turn runs later on the reflex worker,
so a reflex's action never blocks on it (and never trips the 60s watchdog)."
  (when (and ourro.kernel:*automations-armed* (stringp prompt))
    (let ((enqueued (bt:with-lock-held (*investigation-lock*)
                      (when (< (length *investigation-queue*) *investigation-queue-cap*)
                        (setf *investigation-queue*
                              (nconc *investigation-queue*
                                     (list (list :prompt prompt :events events
                                                 :title title))))
                        t))))
      ;; Wake the worker only on a real enqueue (not on overflow, not from a
      ;; staged candidate test with a rebound queue) — review LOW.
      (when enqueued (bt:signal-semaphore *firing-sem*))
      enqueued)))

(defun pending-investigation-count ()
  (bt:with-lock-held (*investigation-lock*) (length *investigation-queue*)))

(defun drain-investigations ()
  "Run every pending investigation via *INVESTIGATION-HOOK*, on the calling
thread (the reflex worker). Binds *IN-AUTOMATION-CONTEXT* so the mini-turn's own
tool-call events never re-dispatch reflexes (the cascade guard)."
  (loop for req = (bt:with-lock-held (*investigation-lock*)
                    (when *investigation-queue* (pop *investigation-queue*)))
        while req
        do (when (and ourro.kernel:*automations-armed* *investigation-hook*)
             ;; Yield to a live user turn before spending the model (M15) — the
             ;; investigation runs off the firing watchdog, so without this it
             ;; would contend with the user's foreground turn.
             (when *politeness-hook* (ignore-errors (funcall *politeness-hook*)))
             (bt:with-lock-held (*execution-lock*)
               (when ourro.kernel:*automations-armed*
                 (let ((*in-automation-context* t))
                   (handler-case
                       (funcall *investigation-hook* (getf req :prompt)
                                :events (getf req :events)
                                :title (getf req :title))
                     (serious-condition () nil))))))))


(defun fire-automation-for-test (name &optional event)
  "Run a registered automation NAME synchronously under its declared
capabilities, returning the action's value. So a gene's :tests can exercise its
own reflex hermetically in the sandbox, with a synthetic EVENT — no worker, no
real event needed."
  (let ((a (find-automation name)))
    (if a
        (ourro.kernel:with-capabilities (automation-capabilities a)
          (funcall (automation-action-fn a) event))
        ;; Declarative reflex genes use the same hermetic seam. Keep this
        ;; dependency late-bound because AUTOMATION loads before REFLEX/MODEL.
        (let* ((package (find-package "OURRO.REFLEX.MODEL"))
               (finder (and package (find-symbol "FIND-REFLEX-DEFINITION" package)))
               (matcher (and package (find-symbol "REFLEX-MATCHES-P" package)))
               (planner (and package (find-symbol "PLAN-REFLEX-EFFECTS" package)))
               (definition (and finder (fboundp finder)
                                (funcall finder name))))
          (when (and definition matcher planner
                     (funcall matcher definition event))
            (funcall planner definition nil event))))))
