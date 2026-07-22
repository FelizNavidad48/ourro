
(in-package #:ourro.observe)

(defvar *utility-ledger* (make-hash-table :test #'equal)
  "gene-name string → utility plist:
 (:uses N :errors N :reverts N :total-ms N :baseline-ms N :baseline-note S
  :frozen B :retired B :first-use T :last-use T :last-milestone N).")

(defvar *ledger-lock* (bt:make-lock "ourro-utility-ledger"))

(defvar *gene-measurable-hook* nil
  "Optional (name → boolean). When set, only genes it accepts are recorded —
the agent wires it to exclude seed genes (provenance :seed), which have no
baseline. Unset (tests, bare boot): everything is measured.")

(defun gene-measurable-p (gene)
  (and gene (stringp gene)
       (or (null *gene-measurable-hook*)
           (funcall *gene-measurable-hook* gene))))

(defun utility-path ()
  (ourro-path "state" "utility.sexp"))

(defun gene-utility (gene)
  "The stored plist for GENE (a fresh default if unseen), newest values."
  (or (gethash gene *utility-ledger*)
      (list :uses 0 :errors 0 :reverts 0 :total-ms 0
            :baseline-ms nil :baseline-note nil
            :frozen nil :retired nil
            :first-use nil :last-use nil :last-milestone 0)))

(defun (setf gene-utility) (plist gene)
  (setf (gethash gene *utility-ledger*) plist))

(defmacro updating-utility ((var gene) &body body)
  "Bind VAR to GENE's plist, run BODY (which returns the new plist), store it."
  `(bt:with-lock-held (*ledger-lock*)
     (let ((,var (gene-utility ,gene)))
       (setf (gene-utility ,gene) (progn ,@body)))))

(defun note-gene-use (gene elapsed-ms error-p)
  "Record one successful use or one error attributed to GENE. Failed calls do
not count as uses and their short duration cannot inflate claimed savings."
  (when (gene-measurable-p gene)
    (let ((now (unix-time)))
      (updating-utility (u gene)
        (let ((u (if error-p
                     (plist-put u :errors (1+ (pget u :errors 0)))
                     (plist-put u :uses (1+ (pget u :uses 0))))))
          (unless error-p
            (setf u (plist-put u :total-ms (+ (pget u :total-ms 0)
                                              (or elapsed-ms 0)))))
          (unless (pget u :first-use)
            (setf u (plist-put u :first-use now)))
          (plist-put u :last-use now))))))

(defun note-gene-created (gene)
  "Stamp GENE's genome-entry time (once). This is the clock for the
'unused for N days' retirement path — an unused gene has no :first-use, so
retirement age must be measured from creation, not first call."
  (when (and gene (stringp gene))
    (updating-utility (u gene)
      (if (pget u :created) u (plist-put u :created (unix-time))))))

(defun note-gene-revert (gene)
  "Record that GENE's probation reverted it."
  (when (and gene (stringp gene))
    (updating-utility (u gene)
      (plist-put u :reverts (1+ (pget u :reverts 0))))))

(defun set-gene-baseline (gene ms &optional note)
  "Record the manual-pattern cost GENE replaced (from the mined pattern)."
  (when (and gene (stringp gene) ms (plusp ms))
    (updating-utility (u gene)
      (plist-put (plist-put u :baseline-ms ms) :baseline-note note))))

(defun set-gene-frozen (gene value)
  (when (and gene (stringp gene))
    (updating-utility (u gene) (plist-put u :frozen (and value t)))))

(defun set-gene-retired (gene value)
  (when (and gene (stringp gene))
    (updating-utility (u gene) (plist-put u :retired (and value t)))))

(defun set-gene-milestone (gene n)
  (when (and gene (stringp gene))
    (updating-utility (u gene) (plist-put u :last-milestone n))))

(defun gene-frozen-p (gene) (pget (gene-utility gene) :frozen))
(defun gene-retired-p (gene) (pget (gene-utility gene) :retired))
(defun gene-uses (gene) (pget (gene-utility gene) :uses 0))

(defun gene-mean-ms (gene)
  "Mean measured elapsed-ms per use, or NIL with no uses."
  (let* ((u (gene-utility gene))
         (uses (pget u :uses 0)))
    (when (plusp uses)
      (round (pget u :total-ms 0) uses))))

(defun gene-savings-ms (gene)
  "Measured total time saved: uses × max(0, baseline − mean-evolved).
Zero until both a baseline and at least one use exist."
  (let* ((u (gene-utility gene))
         (uses (pget u :uses 0))
         (baseline (pget u :baseline-ms)))
    (if (and baseline (plusp uses))
        (* uses (max 0 (- baseline (round (pget u :total-ms 0) uses))))
        0)))


(defvar *genome-gene-count-fn* nil
  "Optional 0-arg closure returning the live genome's gene count. The agent
wires it (WIRE-OBSERVER) so the HUD can report a gene count without OBSERVE
depending on GENOME (a layering inversion). NIL in tests / bare boot → the
summary's :genes is NIL and the HUD renders an empty cell.")

(defun utility-summary ()
  "Aggregate the utility ledger for the always-on evolution HUD (M7-3): a plist
 (:saved-ms N :uses N :measured-genes N :genes N-or-NIL). :saved-ms is the total
measured time saved across all genes with a baseline; :uses is total measured
tool calls; :measured-genes counts genes with a baseline AND a use; :genes is
the live gene count via *GENOME-GENE-COUNT-FN* (NIL when unwired). Pure of the
genome — the count arrives through the hook."
  (bt:with-lock-held (*ledger-lock*)
    (let ((saved 0) (uses 0) (measured 0))
      (maphash
       (lambda (name plist)
         (declare (ignore name))
         (let ((gene-uses (pget plist :uses 0))
               (baseline (pget plist :baseline-ms)))
           (incf uses gene-uses)
           (when (and baseline (plusp gene-uses))
             (incf measured)
             (incf saved (* gene-uses
                            (max 0 (- baseline
                                      (round (pget plist :total-ms 0)
                                             (max 1 gene-uses)))))))))
       *utility-ledger*)
      (list :saved-ms saved :uses uses :measured-genes measured
            :genes (and *genome-gene-count-fn*
                        (ignore-errors (funcall *genome-gene-count-fn*)))))))

(defvar *context-summary-fn* nil
  "Optional 0-arg closure the agent wires (WIRE-OBSERVER) returning the live
context/cost numbers for the HUD, so OBSERVE need not depend on AGENT (M11-4).
NIL in tests / bare boot → the HUD renders an empty cell.")

(defun context-summary ()
  "The context/cost numbers for the HUD gene: a plist (:percent P :fraction F
:cost C :cost-known B), or NIL when unwired. Read-only (capability :observe)."
  (and *context-summary-fn* (ignore-errors (funcall *context-summary-fn*))))


(defun ledger->records ()
  (let ((records '()))
    (maphash (lambda (name plist) (push (cons name plist) records))
             *utility-ledger*)
    (sort records #'string< :key #'car)))

(defun save-utility-ledger (&optional (path (utility-path)))
  (bt:with-lock-held (*ledger-lock*)
    (write-sexp-file path (list :ledger (ledger->records))))
  path)

(defun load-utility-ledger (&optional (path (utility-path)))
  "Rebuild *UTILITY-LEDGER* from PATH. Returns the entry count."
  (let ((form (read-sexp-file path)))
    (bt:with-lock-held (*ledger-lock*)
      (clrhash *utility-ledger*)
      (dolist (record (pget form :ledger))
        (when (consp record)
          (setf (gethash (car record) *utility-ledger*) (cdr record))))
      (hash-table-count *utility-ledger*))))


(defvar *workspaces-lock* (bt:make-lock "ourro-workspaces"))

(defun workspaces-path () (ourro-path "state" "workspaces.sexp"))

(defun known-workspaces ()
  (or (pget (ignore-errors (read-sexp-file (workspaces-path))) :workspaces) '()))

(defun workspace-known-p (key)
  "Whether workspace KEY (a string) has been seen before (read-only, :observe)."
  (and key (member (princ-to-string key) (known-workspaces) :test #'string=) t))

(defun remember-workspace (key)
  "Record workspace KEY as seen (atomic sexp file). Returns KEY."
  (when key
    (let ((k (princ-to-string key)))
      (bt:with-lock-held (*workspaces-lock*)
        (let ((all (known-workspaces)))
          (unless (member k all :test #'string=)
            (ignore-errors
             (write-sexp-file (workspaces-path)
                              (list :workspaces (cons k all)))))))
      k)))


(defun record-gene-use-from-event (event)
  ;; A tool call and an automation firing are both a measured use of the owning
  ;; gene (M13-4): same uses/errors/mean-ms/savings machinery, zero new ledger
  ;; state. Seed genes (the sentinel) are excluded via *gene-measurable-hook*.
  (when (member (pget event :kind) '(:tool-call :automation-fire))
    (let ((gene (pget event :gene)))
      (when (gene-measurable-p gene)
        (note-gene-use gene
                       (pget event :elapsed-ms 0)
                       (eq (pget event :outcome) :error))))))

(setf *gene-use-hook* #'record-gene-use-from-event)
