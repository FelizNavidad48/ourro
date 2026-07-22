
(in-package #:ourro.kernel)

(defvar *revert-table* (make-hash-table :test #'equal)
  "gene-name (string) → list of revert records, most recent first.
Each record is (:kind K :name SYM ...) with enough state to undo.")

(defvar *revert-lock* (bt:make-lock "ourro-revert"))

(defun snapshot-definition (name)
  "Capture the current global definition state of symbol NAME."
  (list :function (and (fboundp name)
                       (not (macro-function name))
                       (fdefinition name))
        :macro (macro-function name)))

(defun record-function-definition (gene-name symbol)
  "Record SYMBOL's pre-existing definition (if any) under GENE-NAME so the
imminent redefinition can be reverted."
  (bt:with-lock-held (*revert-lock*)
    (push (list* :kind :function :name symbol (snapshot-definition symbol))
          (gethash gene-name *revert-table*))))

(defun record-method-definition (gene-name generic-function previous-method
                                 qualifiers specializers)
  "Record the exact generic-function slot a gene is about to replace.  Revert
removes the newly installed method found by QUALIFIERS/SPECIALIZERS and then
re-adds PREVIOUS-METHOD when one existed."
  (bt:with-lock-held (*revert-lock*)
    (push (list :kind :method
                :generic-function generic-function
                :previous-method previous-method
                :qualifiers qualifiers
                :specializers specializers)
          (gethash gene-name *revert-table*))))

(defun record-revert-action (gene-name thunk &key description)
  "Record an arbitrary undo THUNK (used by higher layers — e.g. restoring
a tool-registry entry — without introducing dependencies into the kernel)."
  (bt:with-lock-held (*revert-lock*)
    (push (list :kind :thunk :thunk thunk :description description)
          (gethash gene-name *revert-table*))))

(defun revert-record (record)
  (ecase (pget record :kind)
    (:thunk
     (ignore-errors (funcall (pget record :thunk))))
    (:function
     (let ((name (pget record :name))
           (function (pget record :function))
           (macro (pget record :macro)))
       (cond (macro (setf (macro-function name) macro))
             (function (setf (fdefinition name) function))
             (t (when (fboundp name) (fmakunbound name))))))
    (:method
     (let ((gf (pget record :generic-function))
           (previous (pget record :previous-method))
           (qualifiers (pget record :qualifiers))
           (specializers (pget record :specializers)))
       (when gf
         (let ((installed (ignore-errors
                            (find-method gf qualifiers specializers nil))))
           (when installed (ignore-errors (remove-method gf installed))))
         (when previous (ignore-errors (add-method gf previous))))))))

(defun revert-gene-definitions (gene-name)
  "Undo every definition GENE-NAME installed, most recent first.
Returns the number of records reverted."
  (let ((records (bt:with-lock-held (*revert-lock*)
                   (prog1 (gethash gene-name *revert-table*)
                     (remhash gene-name *revert-table*)))))
    (mapc #'revert-record records)
    (length records)))

(defun revert-record-count (gene-name)
  (bt:with-lock-held (*revert-lock*)
    (length (gethash gene-name *revert-table*))))

(defun clear-revert-records (gene-name)
  "Forget GENE-NAME's revert records (the gene graduated probation and a
newer generation image now embodies it)."
  (bt:with-lock-held (*revert-lock*)
    (remhash gene-name *revert-table*)))


(defparameter *probation-uses* 3
  "Number of initial live invocations of an evolved gene that run under the
automatic-revert handler.")

(defvar *probation-counters* (make-hash-table :test #'equal))
(defvar *probation-failure-hook* nil
  "Function of (gene-name condition) called when probation reverts a gene;
used by the agent to write the ticker line and file the failure.")
(defvar *probation-graduation-hook* nil
  "Optional function of GENE-NAME called once its probation reaches zero.")

(defun probation-remaining (gene-name)
  (bt:with-lock-held (*revert-lock*)
    (gethash gene-name *probation-counters* 0)))

(defun start-probation (gene-name &optional (uses *probation-uses*))
  (bt:with-lock-held (*revert-lock*)
    (setf (gethash gene-name *probation-counters*) uses)))

(defun note-probation-success (gene-name)
  (let ((graduated nil))
    (bt:with-lock-held (*revert-lock*)
      (let ((remaining (gethash gene-name *probation-counters* 0)))
        (when (plusp remaining)
          (if (= remaining 1)
              (progn (remhash gene-name *probation-counters*)
                     (setf graduated t))
              (setf (gethash gene-name *probation-counters*) (1- remaining))))))
    (when (and graduated *probation-graduation-hook*)
      (ignore-errors (funcall *probation-graduation-hook* gene-name)))
    graduated))

(defun call-with-probation (gene-name thunk)
  "Run THUNK. If GENE-NAME is on probation and THUNK signals an ERROR, the
gene's definitions are reverted, the failure is reported through
*PROBATION-FAILURE-HOOK*, and EVOLVED-CODE-FAILURE is signaled with a
REVERT-DEFINITION restart already taken. Callers above (RUN-TOOL) treat it
as a recoverable tool failure."
  (if (zerop (probation-remaining gene-name))
      (funcall thunk)
      (handler-case (prog1 (funcall thunk)
                      (note-probation-success gene-name))
        (error (condition)
          (revert-gene-definitions gene-name)
          (bt:with-lock-held (*revert-lock*)
            (remhash gene-name *probation-counters*))
          (when *probation-failure-hook*
            (ignore-errors
             (funcall *probation-failure-hook* gene-name condition)))
          (error 'evolved-code-failure :gene gene-name :original condition)))))

(defmacro with-probation ((gene-name) &body body)
  `(call-with-probation ,gene-name (lambda () ,@body)))
