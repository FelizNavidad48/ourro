
(defpackage #:ourro.observe
  (:use #:cl #:ourro.util)
  (:export #:*session-id*
           #:*event-sink*
           #:*event-subscribers*
           #:add-event-subscriber
           #:remove-event-subscriber
           #:*gene-use-hook*
           #:start-event-log
           #:log-event
           #:observation-admitted-p
           #:read-events
           #:recent-events
           #:event-log-path
           #:redact-argument
           #:event-persistence-healthy-p
           #:*workspace-context-fn*
           #:with-timed-event
           #:purge-workspace-observations
           #:workspace-observation-residue
           ;; utility ledger (ledger.lisp, same package)
           #:*utility-ledger*
           #:*gene-measurable-hook*
           #:note-gene-use
           #:note-gene-created
           #:note-gene-revert
           #:set-gene-baseline
           #:set-gene-frozen
           #:set-gene-retired
           #:set-gene-milestone
           #:gene-utility
           #:gene-uses
           #:gene-mean-ms
           #:gene-savings-ms
           #:gene-frozen-p
           #:gene-retired-p
           #:utility-summary
           #:*genome-gene-count-fn*
           #:context-summary
           #:*context-summary-fn*
           ;; per-workspace memory (M14-4)
           #:workspace-known-p
           #:remember-workspace
           #:save-utility-ledger
           #:load-utility-ledger
           #:utility-path
           ;; corrections (corrections.lisp, same package)
           #:maybe-log-correction
           #:log-turn-corrections
           #:detect-verbal-correction
           #:detect-rework-file
           #:detect-command-preference
           #:events->turns
           #:backfill-corrections
           #:*dream-classify-corrections*
           ;; evolution queue + turn hooks (queue.lisp, same package)
           #:*evolution-queue*
           #:enqueue-pattern
           #:dequeue-pattern
           #:queue-length
           #:load-evolution-queue
           #:persist-evolution-queue
           #:*current-gene-context-fn*
           #:*turn-hooks*
           #:*turn-hook-failure-hook*
           #:add-turn-hook
           #:remove-turn-hook
           #:run-turn-hooks
           #:clear-turn-hooks))

(in-package #:ourro.observe)

(defvar *session-id* nil)
(defvar *event-log-path* nil)
(defvar *event-lock* (bt:make-lock "ourro-events"))
(defvar *recent-events* '()
  "In-memory ring of the most recent events, newest first.")
(defparameter *recent-limit* 2000)
(defvar *event-persistence-error* nil)
(defvar *workspace-context-fn* nil
  "Optional zero-argument function returning the current workspace identity.")

(defun observation-admitted-p (event)
  (or (not (loop for tail on event by #'cddr
                 thereis (eq (first tail) :observation-enabled)))
      (pget event :observation-enabled)))

(defun managed-observation-p (event)
  (and (pget event :observation-managed) t))

(defun event-persistence-healthy-p ()
  (and (null *event-persistence-error*)
       (or (not ourro.reflex.journal::*journal-enabled*)
           (ourro.reflex.journal:journal-healthy-p))))

(defvar *event-sink* nil
  "Optional extra sink (function of event plist) — the TUI subscribes here.")

(defvar *event-subscribers* '()
  "Alist (name . fn) of general event subscribers, fired on every LOG-EVENT
outside the lock beside *EVENT-SINK* (M13-1). The reflexes arc installs the
automation dispatcher here — a subscriber that MATCHES trigger patterns and
ENQUEUES firings (never runs gene code inline; that's the reflex worker's job).
Each is called under IGNORE-ERRORS so one bad subscriber can't wedge logging.
Not part of OURRO.API — genes reach the bus only through DEFINE-AUTOMATION.")
(defvar *event-subscribers-lock* (bt:make-lock "ourro-event-subscribers"))

(defun add-event-subscriber (name fn)
  "Register FN (a function of the event plist) under NAME, replacing any
existing subscriber with the same NAME. Returns NAME."
  (bt:with-lock-held (*event-subscribers-lock*)
    (setf *event-subscribers*
          (cons (cons name fn)
                (remove name *event-subscribers* :key #'car :test #'equal))))
  name)

(defun remove-event-subscriber (name)
  (bt:with-lock-held (*event-subscribers-lock*)
    (setf *event-subscribers*
          (remove name *event-subscribers* :key #'car :test #'equal))))

(defvar *gene-use-hook* nil
  "Optional (function of the event plist) run on every logged event; the
utility ledger (ledger.lisp) installs itself here so evolved tool calls are
measured. Kept as a hook so events.lisp needs no ledger knowledge.")

(defun event-log-path (&optional (session-id *session-id*))
  (ourro-path "sessions" session-id "events.sexp"))

(defun start-event-log (&key session-id)
  (setf *session-id* (or session-id (make-id "session"))
        *event-log-path* (event-log-path *session-id*)
        *event-persistence-error* nil)
  (ensure-directories-exist *event-log-path*)
  (handler-case (ourro.reflex.journal:open-journal)
    (error (condition)
      (setf *event-persistence-error* (princ-to-string condition)
            ourro.kernel:*automations-armed* nil)))
  ;; Generation restarts retain the session file; hydrate a bounded learning
  ;; window instead of pretending the retained evidence does not exist.
  (setf *recent-events*
        (let ((events (ignore-errors (read-events *event-log-path*))))
          (if events
              (reverse (subseq events (max 0 (- (length events)
                                                (1- *recent-limit*)))))
              '())))
  (log-event :session-start :pid (sb-posix:getpid))
  *session-id*)

(defun redact-argument (value)
  "Apply the causal journal's canonical storage-boundary policy."
  (ourro.reflex.journal:sanitize-record value))

(defun sensitive-key-p (key)
  (ourro.reflex.journal:sensitive-field-p key))

(defun plist-like-p (value)
  (and (listp value) (evenp (length value))
       (loop for tail on value by #'cddr
             for key = (first tail)
             always (or (keywordp key) (stringp key)))))

(defun sanitize (value &optional (depth 0) key)
  "Coerce VALUE using the causal journal's single canonical policy."
  (ourro.reflex.journal:sanitize-record value key depth))

(defun log-event (kind &rest payload)
  "Append an event. PAYLOAD is a plist; values are sanitized to readable data."
  (let* ((raw (sanitize
               (list* :kind kind
                      :schema 1
                      :time (iso-time)
                      :unix (unix-time)
                      :session *session-id*
                      :workspace (and *workspace-context-fn*
                                      (ignore-errors
                                       (funcall *workspace-context-fn*)))
                      payload)))
         (event
           (handler-case (ourro.reflex.journal:ingest-clean-event raw)
             (error (condition)
               (setf *event-persistence-error* (princ-to-string condition)
                     ourro.kernel:*automations-armed* nil)
               raw))))
    (when (observation-admitted-p event)
      (bt:with-lock-held (*event-lock*)
        (push event *recent-events*)
        (when (> (length *recent-events*) *recent-limit*)
          (setf *recent-events* (subseq *recent-events* 0 *recent-limit*)))
        ;; Once local-control policy manages a source, the causal journal is
        ;; its sole durable store. This keeps per-source retention and verified
        ;; deletion from being undermined by the legacy session log.
        (when (and *event-log-path* (not (managed-observation-p event)))
          (handler-case
              (append-sexp-line *event-log-path* event)
            (error (c)
              (setf *event-persistence-error* (princ-to-string c)
                    ;; Autonomous effects require an auditable event plane.
                    ourro.kernel:*automations-armed* nil)))))
      (when *event-sink*
        (ignore-errors (funcall *event-sink* event))))
    ;; General subscribers (M13-1): the automation dispatcher lives here. Fired
    ;; outside the lock, each guarded, so a subscriber can safely read the event
    ;; on any calling thread (turn worker, UI, job waiters, the evolver).
    (let ((subscribers (and (observation-admitted-p event)
                            (bt:with-lock-held (*event-subscribers-lock*)
                              *event-subscribers*))))
      (dolist (subscriber subscribers)
        (ignore-errors (funcall (cdr subscriber) event))))
    (when (and (observation-admitted-p event) *gene-use-hook*)
      (ignore-errors (funcall *gene-use-hook* event)))
    event))

(defmacro with-timed-event ((kind &rest payload) &body body)
  "Run BODY, then log KIND with PAYLOAD, :elapsed-ms, and :outcome
(:ok, or :error with the condition's text)."
  (let ((start (gensym "START")) (condition (gensym "C"))
        (event-id (gensym "EVENT-ID")) (trace-id (gensym "TRACE-ID"))
        (parent-span-id (gensym "PARENT-SPAN-ID"))
        (causation-id (gensym "CAUSATION-ID")))
    `(let* ((,start (get-internal-real-time))
            (,event-id (make-id "event"))
            (,trace-id (or (pget ourro.reflex.journal:*causal-context* :trace-id)
                           ,event-id))
            (,parent-span-id
              (or (pget ourro.reflex.journal:*causal-context* :span-id)
                  (pget ourro.reflex.journal:*causal-context* :parent-span-id)))
            (,causation-id
              (or (pget ourro.reflex.journal:*causal-context* :causation-id)
                  ,parent-span-id)))
       ;; Reserve the event/span identity before the activity begins. Children
       ;; (jobs, nested tools, notes) may therefore cite it even though the
       ;; timed parent record commits after its body finishes.
       (ourro.reflex.journal:with-causal-context
           (:trace-id ,trace-id :parent-span-id ,event-id
            :causation-id ,event-id)
         (handler-case
             (multiple-value-prog1 (progn ,@body)
               (log-event ,kind ,@payload
                          :event-id ,event-id :trace-id ,trace-id
                          :span-id ,event-id :parent-span-id ,parent-span-id
                          :causation-id ,causation-id
                          :elapsed-ms (elapsed-ms ,start) :outcome :ok))
           (error (,condition)
             (log-event ,kind ,@payload
                        :event-id ,event-id :trace-id ,trace-id
                        :span-id ,event-id :parent-span-id ,parent-span-id
                        :causation-id ,causation-id
                        :elapsed-ms (elapsed-ms ,start)
                        :outcome :error :error (princ-to-string ,condition))
             (error ,condition)))))))

(defun elapsed-ms (start)
  (round (* 1000 (- (get-internal-real-time) start))
         internal-time-units-per-second))

(defun recent-events (&key kind (limit 200))
  "Most recent events, newest first, optionally filtered by KIND."
  (bt:with-lock-held (*event-lock*)
    (let ((matches (if kind
                       (remove kind *recent-events*
                               :test-not #'eq
                               :key (lambda (event) (pget event :kind)))
                       (copy-list *recent-events*))))
      (subseq matches 0 (min limit (length matches))))))

(defun read-events (&optional (path *event-log-path*))
  "Read a whole event file (oldest first)."
  (when (and path (probe-file path))
    (with-open-file (in path :direction :input)
      (loop for form = (read-safe in :eof)
            until (eq form :eof)
            collect form))))

(defun rewrite-event-lines (path records)
  (uiop:with-staging-pathname (staging path)
    (with-open-file (out staging :direction :output :if-exists :supersede
                                 :if-does-not-exist :create)
      (with-sexp-syntax
        (let ((*print-pretty* nil))
          (dolist (record records)
            (prin1 record out)
            (terpri out))))))
  path)

(defun workspace-identity-matches-p (candidate workspace)
  (and (or (stringp candidate) (pathnamep candidate))
       (string= (ourro.reflex.journal:normalize-workspace candidate) workspace)))

(defun value-contains-workspace-p (value workspace)
  (cond ((or (stringp value) (pathnamep value))
         (workspace-identity-matches-p value workspace))
        ((consp value)
         (or (value-contains-workspace-p (car value) workspace)
             (value-contains-workspace-p (cdr value) workspace)))
        ((vectorp value)
         (some (lambda (item) (value-contains-workspace-p item workspace)) value))
        (t nil)))

(defun session-event-paths ()
  (let ((root (ourro-path "sessions")))
    (if (probe-file root)
        (directory (merge-pathnames "*/events.sexp"
                                    (uiop:ensure-directory-pathname root)))
        '())))

(defun purge-workspace-evolution-queue (workspace)
  ;; QUEUE.LISP loads after this file in the same package. Resolve its state
  ;; dynamically so this compatibility hook remains acyclic and warning-free.
  (let ((queue-symbol (find-symbol "*EVOLUTION-QUEUE*" :ourro.observe))
        (lock-symbol (find-symbol "*QUEUE-LOCK*" :ourro.observe)))
    (when (and queue-symbol lock-symbol
               (boundp queue-symbol) (boundp lock-symbol))
      (let ((kept
              (bt:with-lock-held ((symbol-value lock-symbol))
                (setf (symbol-value queue-symbol)
                      (remove-if (lambda (pattern)
                                   (value-contains-workspace-p pattern workspace))
                                 (symbol-value queue-symbol)))
                (copy-list (symbol-value queue-symbol)))))
        ;; Do not use PERSIST-EVOLUTION-QUEUE here: its compatibility behavior
        ;; intentionally ignores I/O errors, while deletion must fail closed.
        (write-sexp-file (ourro-path "state" "evolution-queue.sexp")
                         (list :queue kept)))))
  t)

(defun purge-known-workspace (workspace)
  (let ((path (ourro-path "state" "workspaces.sexp")))
    (when (probe-file path)
      (let* ((form (or (read-sexp-file path) '()))
             (known (pget form :workspaces))
             (kept (remove-if (lambda (candidate)
                                (workspace-identity-matches-p candidate workspace))
                              known)))
        (unless (= (length kept) (length known))
          (write-sexp-file path (list :workspaces kept))))))
  t)

(defun purge-workspace-observations (workspace)
  "Remove WORKSPACE from observation memory and every derived model input."
  (let ((workspace (ourro.reflex.journal:normalize-workspace workspace)))
    (bt:with-lock-held (*event-lock*)
      (setf *recent-events*
            (remove-if (lambda (event)
                         (workspace-identity-matches-p (pget event :workspace)
                                                       workspace))
                       *recent-events*))
      (dolist (path (session-event-paths))
        (let* ((records (read-events path))
               (kept (remove-if
                      (lambda (event)
                        (workspace-identity-matches-p (pget event :workspace)
                                                      workspace))
                      records)))
          (unless (= (length kept) (length records))
            (rewrite-event-lines path kept)))))
    (purge-workspace-evolution-queue workspace)
    (purge-known-workspace workspace)
    t))

(defun workspace-observation-residue (workspace)
  "Return fail-closed counts for stores which can feed a future model turn."
  (let* ((workspace (ourro.reflex.journal:normalize-workspace workspace))
         (memory
           (bt:with-lock-held (*event-lock*)
             (count-if (lambda (event)
                         (workspace-identity-matches-p (pget event :workspace)
                                                       workspace))
                       *recent-events*)))
         (session-records 0)
         (unreadable-sessions '()))
    (dolist (path (session-event-paths))
      (handler-case
          (incf session-records
                (count-if (lambda (event)
                            (workspace-identity-matches-p
                             (pget event :workspace) workspace))
                          (or (read-events path) '())))
        (error () (push (namestring path) unreadable-sessions))))
    (let* ((queue-symbol (find-symbol "*EVOLUTION-QUEUE*" :ourro.observe))
           (lock-symbol (find-symbol "*QUEUE-LOCK*" :ourro.observe))
           (queue-records
             (if (and queue-symbol lock-symbol
                      (boundp queue-symbol) (boundp lock-symbol))
                 (bt:with-lock-held ((symbol-value lock-symbol))
                   (count-if (lambda (pattern)
                               (value-contains-workspace-p pattern workspace))
                             (symbol-value queue-symbol)))
                 0))
           (queue-path (ourro-path "state" "evolution-queue.sexp"))
           (persisted-queue-records 0)
           (unreadable-queue nil)
           (known-path (ourro-path "state" "workspaces.sexp"))
           (known-records 0)
           (unreadable-known nil))
      (when (probe-file queue-path)
        (handler-case
            (setf persisted-queue-records
                  (count-if (lambda (pattern)
                              (value-contains-workspace-p pattern workspace))
                            (or (pget (read-sexp-file queue-path) :queue) '())))
          (error () (setf unreadable-queue t))))
      (when (probe-file known-path)
        (handler-case
            (setf known-records
                  (count-if (lambda (candidate)
                              (workspace-identity-matches-p candidate workspace))
                            (or (pget (read-sexp-file known-path) :workspaces) '())))
          (error () (setf unreadable-known t))))
      (list :memory-records memory
            :session-records session-records
            :unreadable-sessions (nreverse unreadable-sessions)
            :evolution-queue-records queue-records
            :persisted-evolution-queue-records persisted-queue-records
            :unreadable-evolution-queue unreadable-queue
            :known-workspace-records known-records
            :unreadable-known-workspaces unreadable-known
            :residue (or (plusp memory) (plusp session-records)
                         unreadable-sessions (plusp queue-records)
                         (plusp persisted-queue-records) unreadable-queue
                         (plusp known-records) unreadable-known)))))

(ourro.reflex.journal:register-workspace-deletion-hook
 :observation-stores #'purge-workspace-observations)
