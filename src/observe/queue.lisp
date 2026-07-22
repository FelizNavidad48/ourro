
(in-package #:ourro.observe)


(defvar *evolution-queue* '()
  "Pending patterns awaiting a proposal, newest last.")
(defvar *queue-lock* (bt:make-lock "ourro-evolve-queue"))

(defun evolution-queue-path () (ourro-path "state/evolution-queue.sexp"))

(defun persist-evolution-queue ()
  "Mirror the queue to state/evolution-queue.sexp (atomic via write-sexp-file),
so patterns mined but not yet proposed survive a restart instead of dying with
the process (M12-1)."
  (ignore-errors
   (write-sexp-file (evolution-queue-path)
                    (list :queue (bt:with-lock-held (*queue-lock*)
                                   (copy-list *evolution-queue*))))))

(defun load-evolution-queue ()
  "Restore the mirrored queue at boot (called from wire-observer)."
  (let ((data (ignore-errors (read-sexp-file (evolution-queue-path)))))
    (when (and data (pget data :queue))
      (bt:with-lock-held (*queue-lock*) (setf *evolution-queue* (pget data :queue)))
      (length (pget data :queue)))))

(defun enqueue-pattern (pattern)
  "Append PATTERN to the evolution queue (deduped by :id). Returns the new
length."
  (bt:with-lock-held (*queue-lock*)
    (unless (find (pget pattern :id) *evolution-queue*
                  :key (lambda (p) (pget p :id)) :test #'equal)
      (setf *evolution-queue* (append *evolution-queue* (list pattern)))))
  (persist-evolution-queue)
  (length *evolution-queue*))

(defun dequeue-pattern ()
  (prog1
      (bt:with-lock-held (*queue-lock*)
        (when *evolution-queue*
          (pop *evolution-queue*)))
    (persist-evolution-queue)))

(defun queue-length ()
  (bt:with-lock-held (*queue-lock*) (length *evolution-queue*)))


(defvar *current-gene-context-fn* nil
  "Installed by OURRO.TOOLS (which loads later) to return the plist of the gene
currently being loaded, so ADD-TURN-HOOK can capture its name + capabilities
without a compile-time dependency on the later package (relocated properly by
D-3 in M3).")

(defvar *turn-hooks* '()
  "List of hook plists (:name :capabilities :thunk :gene) run at turn end.")
(defvar *turn-hooks-lock* (bt:make-lock "ourro-turn-hooks"))

(defvar *turn-hook-failure-hook* nil
  "Optional (name condition) called when a turn hook errors and is removed —
the agent surfaces it as an amber ticker.")

(defun loading-gene-context ()
  (and *current-gene-context-fn*
       (ignore-errors (funcall *current-gene-context-fn*))))

(defun remove-turn-hook (name)
  (bt:with-lock-held (*turn-hooks-lock*)
    (setf *turn-hooks*
          (remove name *turn-hooks* :key (lambda (h) (pget h :name))
                                    :test #'equal))))

(defun add-turn-hook (name thunk)
  "Register THUNK to run at every turn boundary under the current gene's
declared capabilities. If registered from a gene, records a revert-action so
the hook is removed when the gene is reverted (same table as gene code)."
  (let* ((context (loading-gene-context))
         (gene (pget context :name))
         (capabilities (pget context :capabilities)))
    (remove-turn-hook name)
    (bt:with-lock-held (*turn-hooks-lock*)
      (setf *turn-hooks*
            (append *turn-hooks*
                    (list (list :name name :capabilities capabilities
                                :thunk thunk :gene gene)))))
    (when gene
      (ourro.kernel:record-revert-action
       gene (lambda () (remove-turn-hook name))
       :description (format nil "remove turn hook ~A" name)))
    name))

(defun run-turn-hooks ()
  "Run every registered turn hook under its declared capabilities. A hook that
errors is removed and reported; the rest still run."
  (dolist (hook (bt:with-lock-held (*turn-hooks-lock*) (copy-list *turn-hooks*)))
    (handler-case
        (ourro.kernel:with-capabilities (or (pget hook :capabilities) '())
          (funcall (pget hook :thunk)))
      (error (condition)
        (remove-turn-hook (pget hook :name))
        (when *turn-hook-failure-hook*
          (ignore-errors
           (funcall *turn-hook-failure-hook* (pget hook :name) condition)))))))

(defun clear-turn-hooks ()
  (bt:with-lock-held (*turn-hooks-lock*) (setf *turn-hooks* '())))
