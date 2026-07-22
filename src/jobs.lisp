
(defpackage #:ourro.jobs
  (:use #:cl)
  (:import-from #:ourro.util
                #:make-id #:ourro-path #:write-sexp-file #:read-sexp-file
                #:pget #:plist-put #:string-join #:truncate-string #:trim)
  (:import-from #:ourro.kernel #:cap/launch-program)
  (:import-from #:ourro.observe #:log-event)
  (:export #:start-job #:job-status #:job-kill #:jobs-summary
           #:job-log-tail #:list-jobs #:job-record
           #:restore-jobs #:restore-jobs-from-disk #:jobs-for-handoff
           #:kill-all-jobs #:drain-exit-notes #:reset-jobs
           #:*job-exit-hook* #:running-job-count))

(in-package #:ourro.jobs)


(defvar *jobs* '()
  "Durable job plists, newest first: (:id :command :directory :pid :log
:started :status :exit). This — and only this — is persisted.")
(defvar *jobs-lock* (bt:make-lock "ourro-jobs"))
(defvar *id-lock* (bt:make-lock "ourro-jobs-id"))
(defvar *job-counter* 0)
(defvar *job-processes* (make-hash-table :test 'equal)
  "id -> uiop process-info, for jobs launched by THIS image (not persisted).")
(defvar *job-cursors* (make-hash-table :test 'equal)
  "id -> byte offset into the log already handed to the model (not persisted).")
(defvar *job-exit-notes* '()
  "Exit-note strings awaiting the next user message (drained by submit-message).")
(defvar *job-exit-hook* nil
  "Funcalled (id job) when a job exits; the agent installs a ticker + UI fire.")


(defun jobs-dir () (ourro-path "state/jobs/"))
(defun job-log-path (id) (merge-pathnames (format nil "~A.log" id) (jobs-dir)))
(defun jobs-state-path () (ourro-path "state/jobs.sexp"))

(defun persist-jobs ()
  "Mirror the durable job list to state/jobs.sexp (atomic via write-sexp-file)."
  (let ((snapshot (bt:with-lock-held (*jobs-lock*) (copy-tree *jobs*))))
    (ignore-errors
     (write-sexp-file (jobs-state-path) (list :version 1 :jobs snapshot)))))


(defun next-job-id ()
  (bt:with-lock-held (*id-lock*) (format nil "j~D" (incf *job-counter*))))

(defun bump-counter-for (id)
  "Keep the id counter ahead of a re-attached job so ids are never reused."
  (let ((n (ignore-errors (parse-integer id :start 1 :junk-allowed t))))
    (bt:with-lock-held (*id-lock*)
      (when (and n (> n *job-counter*)) (setf *job-counter* n)))))

(defun command-display (job)
  (let ((c (pget job :command))) (if (listp c) (string-join " " c) c)))

(defun pid-alive-p (pid)
  (and pid (handler-case (progn (sb-posix:kill pid 0) t) (error () nil))))

(defun process-identity (pid)
  "Return a stable-enough OS identity for PID, or NIL when it is not alive.
The start timestamp prevents a recycled PID with the same command from being
mistaken for an ourro-owned job.  PS is used only for observation; no shell
is involved and failure is deliberately fail-closed."
  (when (pid-alive-p pid)
    (handler-case
        (let ((text (uiop:run-program
                     (list "ps" "-o" "lstart="
                           "-p" (princ-to-string pid))
                     :output :string :error-output nil
                     :ignore-error-status t)))
          (let ((value (trim text)))
            (and (plusp (length value)) value)))
      (error () nil))))

(defun process-group (pid)
  (and pid (handler-case (sb-posix:getpgid pid) (error () nil))))

(defun job-process-matches-p (job)
  "True only when JOB still names the exact OS process that was launched."
  (let ((stored (pget job :identity)))
    (and stored (equal stored (process-identity (pget job :pid))))))

(defun job-record (id)
  (bt:with-lock-held (*jobs-lock*)
    (find id *jobs* :key (lambda (j) (pget j :id)) :test #'equal)))

(defun list-jobs () (bt:with-lock-held (*jobs-lock*) (copy-list *jobs*)))

(defun running-job-count ()
  (count :running (list-jobs) :key (lambda (j) (pget j :status))))

(defun update-job (id updater)
  "Replace job ID in *JOBS* with (funcall UPDATER job); returns the new job (or
NIL if absent). Rebuilds the list — never mutates a published plist in place."
  (let (result)
    (bt:with-lock-held (*jobs-lock*)
      (setf *jobs*
            (mapcar (lambda (j)
                      (if (equal (pget j :id) id)
                          (setf result (funcall updater j))
                          j))
                    *jobs*)))
    result))


(defun bytes->string (buf)
  (handler-case (sb-ext:octets-to-string buf :external-format :utf-8)
    (error () (map 'string #'code-char buf))))

(defun read-file-region (path start)
  "Return (values text end-offset) reading PATH's bytes from START to EOF."
  (if (probe-file path)
      (with-open-file (in path :direction :input :element-type '(unsigned-byte 8)
                               :if-does-not-exist nil)
        (if in
            (let ((len (file-length in)))
              (if (< start len)
                  (progn
                    (file-position in start)
                    (let ((buf (make-array (- len start) :element-type '(unsigned-byte 8))))
                      (read-sequence buf in)
                      (values (bytes->string buf) len)))
                  (values "" (min start len))))
            (values "" start)))
      (values "" start)))

(defun read-log-since-cursor (id log-path)
  "Read the log bytes since ID's cursor and advance it — atomically under the
lock, so two concurrent readers can't both start from the same offset and
double-report output to the model (latent today, since job_status is issued
serially from the turn worker, but M10-1 parallelizes read-only tools)."
  (bt:with-lock-held (*jobs-lock*)
    (multiple-value-bind (text new-cursor)
        (read-file-region log-path (gethash id *job-cursors* 0))
      (setf (gethash id *job-cursors*) new-cursor)
      text)))

(defun job-log-tail (id &key (bytes 65536))
  "The last BYTES of job ID's log (for /out). Does not touch the read cursor."
  (let ((job (job-record id)))
    (when job
      (let ((path (pget job :log)))
        (when (and path (probe-file path))
          (with-open-file (in path :element-type '(unsigned-byte 8))
            (let* ((len (file-length in))
                   (start (max 0 (- len bytes))))
              (file-position in start)
              (let ((buf (make-array (- len start) :element-type '(unsigned-byte 8))))
                (read-sequence buf in)
                (bytes->string buf)))))))))


(defun mark-exited (id code)
  "Record job ID as exited with CODE, log it, queue an exit note, fire the hook."
  (let ((transitioned nil)
        (job nil))
    (setf job
          (update-job id
                      (lambda (j)
                        (if (eq (pget j :status) :running)
                            (progn
                              (setf transitioned t)
                              (plist-put (plist-put j :status :exited) :exit code))
                            j))))
    (bt:with-lock-held (*jobs-lock*) (remhash id *job-processes*))
    (when (and job transitioned)
      (persist-jobs)
      (ignore-errors
        (log-event :job-exit :job id :exit code
                             :causation-id (pget job :start-event-id)
                             :parent-span-id (pget job :start-event-id)
                             :outcome (if (and (numberp code) (zerop code))
                                          :ok :error)
                             :command (command-display job)
                             :directory (pget job :directory)
                             :started (pget job :started)
                             :log-path (pget job :log)
                             ;; Persist a complete bounded evidence window; the
                             ;; causal journal sanitizes and frames it before a
                             ;; durable reflex can observe the exit.
                             :log-tail (or (job-log-tail id :bytes 64000) "")))
      (bt:with-lock-held (*jobs-lock*)
        (push (format nil "[job ~A (~A) exited ~A — job_status ~A for the log]"
                      id (command-display job) code id)
              *job-exit-notes*))
      (ignore-errors (when *job-exit-hook* (funcall *job-exit-hook* id job))))))

(defun quoted-job-binding (symbol value)
  (cons symbol (list 'quote value)))

(defun named-job-bindings (package-name symbol-names)
  "Capture optional SPECIAL variables without introducing an ASDF dependency.
JOBS loads before the reflex compiler; lifecycle threads are only created after
the complete system is loaded, so resolving the shared registries here keeps
that ordering honest while still preserving dynamic scratch/runtime context."
  (let ((package (find-package package-name)))
    (when package
      (loop for name in symbol-names
            for symbol = (find-symbol name package)
            when (and symbol (boundp symbol))
              collect (quoted-job-binding symbol (symbol-value symbol))))))

(defun job-thread-bindings ()
  "Propagate the durable causal/event plane into job lifecycle threads."
  (append
   (list
    (quoted-job-binding 'ourro.observe::*session-id* ourro.observe::*session-id*)
    (quoted-job-binding 'ourro.observe::*event-log-path*
                        ourro.observe::*event-log-path*)
    (quoted-job-binding 'ourro.observe::*workspace-context-fn*
                        ourro.observe::*workspace-context-fn*)
    (quoted-job-binding 'ourro.observe::*event-subscribers*
                        ourro.observe::*event-subscribers*)
    ;; Do not dynamically snapshot the replaceable journal collections.
    ;; Compaction and workspace deletion install fresh objects; lifecycle
    ;; threads must resolve those globals at append time or they can publish to
    ;; an index that is no longer live.
    )
   (ourro.reflex.journal:journal-thread-bindings)
   ;; The event subscriber evaluates trigger routing on the lifecycle thread
   ;; that publishes the job-exit event. Propagate the shared compiler
   ;; registries so scratch runtimes route the exact activated version rather
   ;; than silently consulting process-global defaults. Resolve these lazily:
   ;; JOBS intentionally loads before the reflex compiler.
   (named-job-bindings
    "OURRO.REFLEX.COMPILER"
    '("*VERSION-REGISTRY*" "*ACTIVE-VERSION-POINTERS*" "*CANARY-ROUTES*"))
   bt:*default-special-bindings*))

(defun spawn-waiter (id proc)
  "Reap PROC on a thread and record the exit code — the accurate path for a job
this image launched."
  (bt:make-thread
   (lambda () (mark-exited id (ignore-errors (uiop:wait-process proc))))
   :name (format nil "ourro-job-~A" id)
   :initial-bindings (job-thread-bindings)))

(defun spawn-liveness-poller (id)
  "The re-attach path: after an exec the process-info is gone, so poll kill -0
and the durable identity every 2s and mark the job exited when either ceases to
match. The precise exit code is unknowable after an image restart."
  (bt:make-thread
   (lambda ()
     (loop for job = (job-record id)
           while (and job (eq (pget job :status) :running)
                      (job-process-matches-p job))
           do (sleep 2))
     (mark-exited id :unknown-after-restart))
   :name (format nil "ourro-job-poll-~A" id)
   :initial-bindings (job-thread-bindings)))

(defun start-job (command &key directory)
  "Launch COMMAND (a shell string) as a background job with stdout+stderr going
to its log file. Returns the job id. A waiter thread records the exit."
  (let* ((id (next-job-id))
         (dir (or directory ourro.toolkit:*workspace*))
         (log (job-log-path id)))
    (ensure-directories-exist log)
    ;; A one-file launch latch closes the inspection race for commands such as
    ;; `true`: the parent records durable identity before allowing the requested
    ;; command to exec. COMMAND and the latch are arguments, never interpolated
    ;; into the wrapper program.
    (let* ((ready (merge-pathnames (format nil ".~A.ready" id) (jobs-dir)))
           (proc (cap/launch-program
                  (list "sh" "-c"
                        (concatenate
                         'string
                         "while [ ! -f \"$1\" ]; do sleep 0.01; done; "
                         "rm -f \"$1\"; exec sh -c \"$2\"")
                        "ourro-job" (namestring ready) command)
                  :directory dir :output-file log))
           (pid (uiop:process-info-pid proc))
           (pgid (process-group pid))
           (identity (process-identity pid))
           (job (list :id id
                      :command command
                      :directory (and dir (namestring dir))
                      :pid pid :pgid pgid :identity identity
                      :log (namestring log)
                      :started (get-universal-time)
                      :status :running :exit nil)))
      ;; UIOP launches asynchronous programs in a fresh process group on the
      ;; supported SBCL platforms.  Refuse ownership if that invariant is not
      ;; true: PID-only killing would leak the command's descendants.
      (unless (and identity pgid (= pgid pid)
                   (/= pgid (sb-posix:getpgrp)))
        (when pgid (ignore-errors (sb-posix:kill (- pgid) 9)))
        (ignore-errors (uiop:terminate-process proc :urgent t))
        (error "Background job did not acquire a dedicated process group"))
      (bt:with-lock-held (*jobs-lock*)
        (push job *jobs*)
        (setf (gethash id *job-processes*) proc
              (gethash id *job-cursors*) 0))
      (persist-jobs)
      (let ((start-event
              (ignore-errors
                (log-event :job-start :job id :command command
                                      :directory (and dir (namestring dir))))))
        (when (pget start-event :event-id)
          (setf job
                (update-job
                 id (lambda (record)
                      (plist-put record :start-event-id
                                 (pget start-event :event-id)))))
          (persist-jobs)))
      (with-open-file (out ready :direction :output :if-does-not-exist :create
                                 :if-exists :supersede)
        (write-line "go" out))
      (spawn-waiter id proc)
      id)))

(defun job-status (id &key peek)
  "Status of job ID plus the log tail since the caller's cursor (so the model
never re-reads what it has already seen). NIL if ID is unknown."
  (let ((job (job-record id)))
    (when job
      (list :id id
            :command (pget job :command)
            :status (pget job :status)
            :exit (pget job :exit)
            :running-p (eq (pget job :status) :running)
            :tail (if peek
                      (or (job-log-tail id) "")
                      (read-log-since-cursor id (pget job :log)))))))

(defun jobs-summary ()
  "A compact plist for the HUD and /jobs: running/total counts + a brief per-job
list. Cheap and read-only (capability :observe)."
  (let ((jobs (list-jobs)))
    (list :running (count :running jobs :key (lambda (j) (pget j :status)))
          :total (length jobs)
          :jobs (mapcar (lambda (j)
                          (list :id (pget j :id) :status (pget j :status)
                                :command (pget j :command) :exit (pget j :exit)
                                :pid (pget j :pid)))
                        jobs))))

(defun kill-job-process (job)
  "Terminate JOB's dedicated process group, after revalidating OS identity."
  (handler-case
      (let ((pid (pget job :pid))
            (pgid (pget job :pgid)))
        (when (and (job-process-matches-p job)
                   pgid (= pgid pid) (/= pgid (sb-posix:getpgrp)))
          (sb-posix:kill (- pgid) 15)
          (loop repeat 20 while (job-process-matches-p job) do (sleep 0.1))
          (when (job-process-matches-p job)
            (sb-posix:kill (- pgid) 9))))
    (error () nil)))

(defun job-kill (id)
  "TERM job ID, 2s grace, then KILL. The waiter/poller records the exit. Returns
:killed, :already-exited, or NIL (unknown id)."
  (let ((job (job-record id)))
    (cond
      ((null job) nil)
      ((not (eq (pget job :status) :running)) :already-exited)
      ((not (job-process-matches-p job))
       (mark-exited id :identity-lost)
       :already-exited)
      (t (kill-job-process job) :killed))))


(defun drain-exit-notes ()
  "Return pending job-exit notes (oldest first) and clear them."
  (bt:with-lock-held (*jobs-lock*)
    (prog1 (nreverse *job-exit-notes*) (setf *job-exit-notes* '()))))

(defun jobs-for-handoff ()
  "The durable job list to carry through a handoff/checkpoint :extra :jobs."
  (list-jobs))

(defun kill-all-jobs ()
  "TERM (then KILL) every running job — announced before a clean /quit. Returns
the ids reaped."
  (let ((running (remove-if-not (lambda (j) (eq (pget j :status) :running))
                                (list-jobs))))
    (dolist (j running) (ignore-errors (job-kill (pget j :id))))
    (mapcar (lambda (j) (pget j :id)) running)))

(defun restore-jobs (job-list)
  "Re-attach JOB-LIST (from a handoff or state/jobs.sexp) after a restart. A job
that was :running and whose pid is still alive stays :running with a liveness
poller; one whose pid is gone becomes :exited with :unknown-after-restart. Jobs
that had ALREADY exited are dropped — they are session history, not live work,
and carrying them forward would grow *jobs* and the mirror without bound across
the frequent generation restarts."
  (let ((restored '()))
    (dolist (job job-list)              ; newest-first in, newest-first out
      (when (eq (pget job :status) :running)
        (let* ((id (pget job :id))
               (alive (job-process-matches-p job)))
          (bump-counter-for id)
          (push (if alive
                    (plist-put job :status :running)
                    (plist-put (plist-put job :status :exited)
                               :exit :unknown-after-restart))
                restored))))
    (setf restored (nreverse restored))
    (bt:with-lock-held (*jobs-lock*)
      (setf *jobs* restored
            *job-processes* (make-hash-table :test 'equal)
            *job-cursors* (make-hash-table :test 'equal))
      (dolist (j restored) (setf (gethash (pget j :id) *job-cursors*) 0)))
    ;; Route restore-time losses through the ordinary exit transition so event
    ;; logging, notes, persistence and *JOB-EXIT-HOOK* happen exactly once.
    (dolist (j restored)
      (if (eq (pget j :status) :running)
          (spawn-liveness-poller (pget j :id))
          (progn
            (update-job (pget j :id)
                        (lambda (old) (plist-put old :status :running)))
            (mark-exited (pget j :id) :unknown-after-restart))))
    (persist-jobs)
    (list-jobs)))

(defun restore-jobs-from-disk ()
  "Crash-resume path: re-attach jobs recorded in state/jobs.sexp (a hard crash
leaves no handoff, only this mirror)."
  (let ((data (ignore-errors (read-sexp-file (jobs-state-path)))))
    (when (and data (pget data :jobs))
      (restore-jobs (pget data :jobs)))))

(defun reset-jobs ()
  "Clear all registry state (tests)."
  (bt:with-lock-held (*jobs-lock*)
    (setf *jobs* '() *job-exit-notes* '()
          *job-processes* (make-hash-table :test 'equal)
          *job-cursors* (make-hash-table :test 'equal)))
  (bt:with-lock-held (*id-lock*) (setf *job-counter* 0)))
