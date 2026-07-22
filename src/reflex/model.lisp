
(defpackage #:ourro.reflex.model
  (:use #:cl #:ourro.util)
  (:export #:define-reflex
           #:definition-from-form
           #:register-reflex-form
           #:validate-reflex
           #:canonical-reflex-ir
           #:derive-capabilities
           #:reflex-definition
           #:reflex-name
           #:reflex-version-number
           #:reflex-workspace
           #:reflex-capabilities
           #:reflex-trigger
           #:reflex-guards
           #:reflex-state-schema
           #:reflex-initial-state
           #:reflex-workflow
           #:reflex-policy
           #:reflex-source-form
           #:reflex-version
           #:version-hash
           #:version-definition
           #:version-ir
           #:version-generated-lisp
           #:version-transition-function
           #:version-proof
           #:version-status
           #:*reflex-definitions*
           #:*definition-registered-hook*
           #:copy-reflex-definitions
           #:find-reflex-definition
           #:register-state-migration
           #:migrate-reflex-state
           #:explain-reflex
           #:reflex-matches-p
           #:plan-reflex-effects))

(in-package #:ourro.reflex.model)

(defparameter +allowed-sections+
  '(:identity :trigger :guards :state :workflow :policy))
(defparameter +allowed-activities+
  '(:read :notify :start-job :await-job :investigate :branch :prepare-change :finish))
(defparameter +activity-capabilities+
  '((:read . :filesystem-read)
    (:notify . :observe)
    (:start-job . :subprocess)
    (:await-job . :observe)
    ;; An investigation is a model activity whose *available* tools are
    ;; separately constrained to causal evidence and read-only workspace data.
    ;; Listing the whole compound grant here prevents the product adapter from
    ;; acquiring ambient read authority beneath an :LLM-only reflex.
    (:investigate . (:filesystem-read :llm :observe))
    (:prepare-change . (:filesystem-read :filesystem-write))))

(defclass reflex-definition ()
  ((name :initarg :name :reader reflex-name)
   (version :initarg :version :reader reflex-version-number)
   (workspace :initarg :workspace :reader reflex-workspace)
   (capabilities :initarg :capabilities :reader reflex-capabilities)
   (trigger :initarg :trigger :reader reflex-trigger)
   (guards :initarg :guards :reader reflex-guards)
   (state-schema :initarg :state-schema :reader reflex-state-schema)
   (workflow :initarg :workflow :reader reflex-workflow)
   (policy :initarg :policy :reader reflex-policy)
   (source-form :initarg :source-form :reader reflex-source-form)))

(defclass reflex-version ()
  ((hash :initarg :hash :reader version-hash)
   (definition :initarg :definition :reader version-definition)
   (ir :initarg :ir :reader version-ir)
   (generated-lisp :initarg :generated-lisp :reader version-generated-lisp)
   (transition-function :initarg :transition-function
                        :reader version-transition-function)
   (proof :initarg :proof :reader version-proof)
   (status :initarg :status :initform :verified :accessor version-status)))

(defvar *reflex-definitions* (make-hash-table :test #'equal))
(defvar *definition-registered-hook* nil
  "Trusted post-model hook used by the compiler to publish immutable versions.")
(defvar *state-migrations* (make-hash-table :test #'equal))

(defun copy-reflex-definitions (&optional (source *reflex-definitions*))
  (copy-hash-table source))

(defun canonical-name (name)
  (string-downcase (string name)))

(defun section-value (sections key &optional default)
  (let ((section (assoc key sections)))
    (if section
        (if (= (length section) 2) (second section) (rest section))
        default)))

(defun proper-plist-p (value)
  (and (listp value) (evenp (length value))
       (loop for tail on value by #'cddr always (keywordp (first tail)))))

(defun normalize-data (value)
  "Normalize declarative data without evaluating it."
  (cond ((null value) nil)
        ((consp value) (mapcar #'normalize-data value))
        ((and (symbolp value) (not (keywordp value)))
         (string-downcase (symbol-name value)))
        (t value)))

(defun derive-capabilities (workflow)
  (sort (remove-duplicates
         (loop for step in workflow
               for activity = (and (proper-plist-p step) (pget step :activity))
               for required = (cdr (assoc activity +activity-capabilities+))
               when required append (if (listp required)
                                        (copy-list required)
                                        (list required)))
         :test #'eq)
        #'string< :key #'symbol-name))

(defun validate-workflow (workflow)
  (unless (and (listp workflow) workflow) (error "reflex workflow is empty"))
  (let ((ids '()))
    (dolist (step workflow)
      (unless (proper-plist-p step) (error "reflex step is not a plist: ~S" step))
      (let ((id (pget step :id)) (activity (pget step :activity)))
        (unless (keywordp id) (error "reflex step needs a keyword :id: ~S" step))
        (when (member id ids) (error "duplicate reflex step id ~S" id))
        (push id ids)
        (unless (member activity +allowed-activities+)
          (error "unsupported reflex activity ~S" activity))))
    (dolist (step workflow)
      (let ((next (pget step :next)))
        (unless (or (null next) (eq next :done) (member next ids))
          (error "reflex step ~S points to unknown next step ~S"
                 (pget step :id) next))))))

(defun validate-reflex (definition)
  (unless (plusp (reflex-version-number definition))
    (error "reflex version must be a positive integer"))
  (unless (proper-plist-p (reflex-trigger definition))
    (error "reflex trigger must be a plist"))
  (unless (keywordp (pget (reflex-trigger definition) :kind))
    (error "reflex trigger requires a :kind keyword"))
  (unless (proper-plist-p (reflex-state-schema definition))
    (error "reflex state schema must be a plist"))
  (unless (plusp (or (pget (reflex-state-schema definition) :version) 0))
    (error "reflex state schema requires a positive :version"))
  (validate-workflow (reflex-workflow definition))
  (let ((derived (derive-capabilities (reflex-workflow definition))))
    (unless (equal derived
                   (sort (copy-list (reflex-capabilities definition))
                         #'string< :key #'symbol-name))
      (error "requested reflex authority ~S must exactly equal derived authority ~S"
             (reflex-capabilities definition) derived)))
  definition)

(defun definition-from-form (form)
  "Parse one restricted (DEFINE-REFLEX NAME SECTION...) form without evaluation."
  (unless (and (consp form) (>= (length form) 4)
               (symbolp (first form))
               (string-equal "DEFINE-REFLEX" (symbol-name (first form)))
               (symbolp (second form)))
    (error "malformed DEFINE-REFLEX form"))
  (let ((sections (cddr form)))
    (dolist (section sections)
      (unless (and (consp section) (member (first section) +allowed-sections+))
        (error "unknown reflex section ~S" (and (consp section) (first section)))))
    (dolist (key +allowed-sections+)
      (when (> (count key sections :key #'first) 1)
        (error "duplicate reflex section ~S" key)))
    (let* ((identity (section-value sections :identity '()))
           (definition
             (make-instance
              'reflex-definition
              :name (canonical-name (second form))
              :version (or (pget identity :version) 1)
              :workspace (or (pget identity :workspace) :current)
              :capabilities (copy-list (or (pget identity :capabilities) '()))
              :trigger (normalize-data (section-value sections :trigger))
              :guards (normalize-data (section-value sections :guards '()))
              :state-schema
              (normalize-data (section-value sections :state
                                             '(:version 1 :initial (:step :start))))
              :workflow (normalize-data (section-value sections :workflow))
              :policy (normalize-data (section-value sections :policy '()))
              :source-form form)))
      (validate-reflex definition))))

(defun canonical-reflex-ir (definition)
  (validate-reflex definition)
  (list :ir-version 1
        :name (reflex-name definition)
        :version (reflex-version-number definition)
        :workspace (normalize-data (reflex-workspace definition))
        :capabilities (sort (copy-list (reflex-capabilities definition))
                            #'string< :key #'symbol-name)
        :trigger (normalize-data (reflex-trigger definition))
        :guards (normalize-data (reflex-guards definition))
        :state-schema (normalize-data (reflex-state-schema definition))
        :workflow (normalize-data (reflex-workflow definition))
        :policy (normalize-data (reflex-policy definition))))

(defun register-reflex-form (form)
  (let ((definition (definition-from-form form)))
    (setf (gethash (reflex-name definition) *reflex-definitions*) definition)
    (when *definition-registered-hook*
      (funcall *definition-registered-hook* definition))
    definition))

(defun find-reflex-definition (name)
  (gethash (canonical-name name) *reflex-definitions*))

(defmacro define-reflex (name &body sections)
  `(register-reflex-form '(define-reflex ,name ,@sections)))

(defun register-state-migration (name from-version to-version forward reverse)
  (unless (= to-version (1+ from-version))
    (error "state migrations must advance exactly one version"))
  (setf (gethash (list (canonical-name name) from-version to-version)
                 *state-migrations*)
        (cons forward reverse))
  t)

(defun migrate-reflex-state (name state from-version to-version)
  "Apply registered pure forward or reverse migrations one schema at a time."
  (loop with current = state
        with version = from-version
        until (= version to-version) do
          (let* ((forward (< version to-version))
                 (next (+ version (if forward 1 -1)))
                 (entry (if forward
                            (gethash (list (canonical-name name) version next)
                                     *state-migrations*)
                            (gethash (list (canonical-name name) next version)
                                     *state-migrations*)))
                 (function (and entry (if forward (car entry) (cdr entry)))))
            (unless function
              (error "no state migration for ~A ~D→~D" name version next))
            (setf current (funcall function (copy-tree current))
                  version next))
        finally (return current)))

(defgeneric reflex-matches-p (definition event))
(defun reflex-value-matches-p (expected actual)
  (if (and (consp expected) (keywordp (first expected)))
      (case (first expected)
        (:not (not (reflex-value-matches-p (second expected) actual)))
        (:any (some (lambda (choice)
                      (reflex-value-matches-p choice actual))
                    (rest expected)))
        (:var t)
        (:> (and (numberp actual) (> actual (second expected))))
        (:< (and (numberp actual) (< actual (second expected))))
        (:matches (and (stringp actual) (stringp (second expected))
                       (cl-ppcre:scan (second expected) actual)))
        (t nil))
      (equal expected actual)))

(defun match-plist-p (pattern event)
  (loop for (key expected) on pattern by #'cddr
        always (reflex-value-matches-p expected (pget event key))))

(defmethod reflex-matches-p ((definition reflex-definition) event)
  (and (match-plist-p (reflex-trigger definition) event)
       (or (null (reflex-guards definition))
           (match-plist-p (reflex-guards definition) event))))

(defun reflex-initial-state (definition)
  "Materialize the state schema's declared initial value for DEFINITION."
  (let ((schema (reflex-state-schema definition)))
    (or (copy-tree (pget schema :initial))
        (list :step (or (pget schema :initial-step)
                        (pget (first (reflex-workflow definition)) :id))))))

(defgeneric plan-reflex-effects (definition state event))
(defmethod plan-reflex-effects ((definition reflex-definition) state event)
  (declare (ignore event))
  (let* ((step-id (or (pget state :step)
                      (pget (reflex-initial-state definition) :step)))
         (step (find step-id (reflex-workflow definition)
                     :key (lambda (item) (pget item :id)))))
    (and step (list (copy-list step)))))

(defgeneric explain-reflex (definition))
(defmethod explain-reflex ((definition reflex-definition))
  (format nil "~A v~D: on ~S, run ~{~S~^ → ~} with authority ~S"
          (reflex-name definition) (reflex-version-number definition)
          (reflex-trigger definition)
          (mapcar (lambda (step) (pget step :activity))
                  (reflex-workflow definition))
          (reflex-capabilities definition)))
