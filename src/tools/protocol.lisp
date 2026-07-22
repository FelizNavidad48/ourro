
(defpackage #:ourro.tools
  (:use #:cl #:ourro.util)
  (:import-from #:ourro.kernel
                #:with-capabilities
                #:with-attenuated-capabilities
                #:capability-p
                #:with-probation
                #:probation-remaining
                #:record-function-definition
                ;; D-3: the gene context now lives in the kernel; re-export it
                ;; so existing ourro.tools:*current-gene-context* callers hold.
                #:*current-gene-context*)
  (:export #:tool
           #:instrumented-class
           #:tool-name
           #:tool-lisp-name
           #:tool-description
           #:tool-parameters
           #:tool-function
           #:tool-gene
           #:tool-capabilities
           #:tool-contract
           #:run-tool
           #:*tool-registry*
           #:make-tool-registry
           #:copy-tool-registry
           #:register-tool
           #:unregister-tool
           #:find-tool
           #:list-tools
           #:tool-declarations
           #:execute-tool-call
           #:execute-tool-object
           #:deftool
           #:tool-arg
           #:contract-violation
           #:*current-gene-context*
           #:tool-error-string))

(in-package #:ourro.tools)


(defclass instrumented-class (standard-class) ())

(defmethod sb-mop:validate-superclass ((class instrumented-class)
                                       (super standard-class))
  t)

(defclass tool ()
  ((name :initarg :name :reader tool-name
         :documentation "API name exposed to the model, e.g. \"read_file\".")
   (lisp-name :initarg :lisp-name :initform nil :reader tool-lisp-name)
   (description :initarg :description :reader tool-description)
   (parameters :initarg :parameters :initform '() :reader tool-parameters
               :documentation "List of (name type description required default).")
   (function :initarg :function :reader tool-function)
   (gene :initarg :gene :initform nil :reader tool-gene)
   (capabilities :initarg :capabilities :initform '() :reader tool-capabilities)
   (contract :initarg :contract :initform nil :reader tool-contract))
  (:metaclass instrumented-class))


(define-condition contract-violation (ourro.kernel:ourro-error)
  ((tool :initarg :tool :reader contract-violation-tool)
   (which :initarg :which :reader contract-violation-which)
   (form :initarg :form :reader contract-violation-form))
  (:report (lambda (c stream)
             (format stream "Tool ~A violated its :~A contract: ~S"
                     (contract-violation-tool c)
                     (contract-violation-which c)
                     (contract-violation-form c)))))

(defun call-instrumented (tool args thunk)
  "The un-removable wrapper around every tool invocation."
  (let ((gene (tool-gene tool)))
    (ourro.observe:with-timed-event
        (:tool-call :tool (tool-name tool)
                    :gene gene
                    :args (hash-args-plist args))
      (with-attenuated-capabilities (tool-capabilities tool)
        (if (and gene (plusp (probation-remaining gene)))
            (with-probation (gene) (funcall thunk))
            (funcall thunk))))))

(defun hash-args-plist (args)
  (if (hash-table-p args)
      (let ((plist '()))
        (maphash (lambda (key value)
                   (push (intern (string-upcase (princ-to-string key)) :keyword)
                         plist)
                   (push value plist))
                 args)
        (nreverse plist))
      args))

(define-method-combination instrumented ()
  ((around (:around))
   (before (:before))
   (primary () :required t)
   (after (:after)))
  (:arguments tool args)
  (let* ((core `(multiple-value-prog1
                    (progn ,@(mapcar (lambda (m) `(call-method ,m)) before)
                           (call-method ,(first primary) ,(rest primary)))
                  ,@(mapcar (lambda (m) `(call-method ,m)) (reverse after))))
         (routed (if around
                     `(call-method ,(first around)
                                   (,@(rest around) (make-method ,core)))
                     core)))
    `(call-instrumented ,tool ,args (lambda () ,routed))))

(defgeneric run-tool (tool args)
  (:method-combination instrumented)
  (:documentation "Execute TOOL with ARGS (a hash table of JSON args).
Returns a string (or stringifiable) result for the model."))

(defmethod run-tool ((tool tool) args)
  (funcall (tool-function tool) args))


(defun make-tool-registry () (make-hash-table :test #'equal))

(defvar *tool-registry* (make-tool-registry))

(defun copy-tool-registry (&optional (registry *tool-registry*))
  (copy-hash-table registry))

(defun register-tool (tool)
  "Install TOOL; records the previous binding in the revert table when the
registration comes from a gene."
  (let ((name (tool-name tool)))
    (setf (gethash name *tool-registry*) tool)
    tool))

(defun unregister-tool (name)
  (remhash name *tool-registry*))

(defun find-tool (name &optional (registry *tool-registry*))
  (gethash name registry))

(defun list-tools (&optional (registry *tool-registry*))
  (let ((tools '()))
    (maphash (lambda (name tool) (declare (ignore name)) (push tool tools))
             registry)
    (sort tools #'string< :key #'tool-name)))


(defun parameter-json-schema (parameter)
  (destructuring-bind (name type description &key required default) parameter
    (declare (ignore required default))
    (list (string-downcase name)
          (ourro.llm:json-object
           "type" (ecase type
                    (:string "string") (:integer "integer") (:number "number")
                    (:boolean "boolean") (:array "array") (:object "object"))
           "description" (or description "")))))

(defun tool-json-parameters (tool)
  (let ((properties (ourro.llm:json-object))
        (required '()))
    (dolist (parameter (tool-parameters tool))
      (destructuring-bind (key schema) (parameter-json-schema parameter)
        (setf (gethash key properties) schema))
      (destructuring-bind (name type description &key required-p default)
          (normalize-parameter parameter)
        (declare (ignore type description default))
        (when required-p (push (string-downcase name) required))))
    (ourro.llm:json-object "type" "object"
                          "properties" properties
                          "required" (arrayify-strings (nreverse required)))))

(defun normalize-parameter (parameter)
  (destructuring-bind (name type description &key required default) parameter
    (list name type description :required-p required :default default)))

(defun arrayify-strings (list) (coerce list 'vector))

(defun tool-declarations (&optional (registry *tool-registry*))
  "The (name description parameters) triples OURRO.LLM serializes."
  (mapcar (lambda (tool)
            (list (tool-name tool)
                  (tool-description tool)
                  (tool-json-parameters tool)))
          (list-tools registry)))

(defun tool-error-string (condition)
  (format nil "ERROR: ~A" condition))

(defun execute-tool-call (name args)
  "The boundary the agent loop calls. Returns (values result-string error-p).
All conditions are captured — a failing tool (including a reverting
probation gene) becomes an error string for the model, never a crash."
  (let ((tool (find-tool name)))
    (if (null tool)
        (values (format nil "ERROR: unknown tool ~S" name) t)
        (execute-tool-object tool args))))

(defun execute-tool-object (tool args)
  "Execute the exact TOOL object authorized by the caller.  This is the
version-stable boundary used by parallel batches: registry replacement after
eligibility cannot swap in a different implementation or capability grant."
  (handler-case
      (values (let ((result (run-tool tool args)))
                (if (stringp result) result (princ-to-string result)))
              nil)
    (ourro.kernel:evolved-code-failure (condition)
      (values (format nil "ERROR: evolved tool failed and was reverted ~
to its previous definition (~A). Retry the call."
                      (ourro.kernel:evolved-code-failure-gene condition))
              t))
    (error (condition)
      (values (tool-error-string condition) t))))


;; *current-gene-context* is defined in ourro.kernel (D-3) and imported +
;; re-exported by this package's defpackage; DEFGENE binds it at load time.

;; Let the earlier-loading OURRO.OBSERVE read the loading gene's context (for
;; ADD-TURN-HOOK's capability capture) without depending on this package.
(setf ourro.observe:*current-gene-context-fn*
      (lambda () *current-gene-context*))

(defun tool-api-name (lisp-name)
  (substitute #\_ #\- (string-downcase (symbol-name lisp-name))))

(defun tool-arg (args name &key default required (type nil))
  "Extract argument NAME (string) from ARGS hash with coercion."
  (let ((value (ourro.llm:json-value args name)))
    (cond ((and (or (null value) (eq value 'null)) required)
           (error "Missing required argument ~S" name))
          ((or (null value) (eq value 'null)) default)
          (t (case type
               (:integer (if (numberp value) (round value)
                             (parse-integer (princ-to-string value))))
               (:boolean (and value (not (eq value 'null))
                              (not (equal value "false"))))
               (:string (if (stringp value) value (princ-to-string value)))
               (t value))))))

(defun find-symbol-named (name tree)
  "Return the first symbol in TREE whose name is NAME (case-sensitive), or
NIL. Used to reuse the exact RESULT symbol the gene author wrote instead of
interning a fresh one (which could hit a locked package)."
  (labels ((walk (x)
             (cond ((and (symbolp x) x (string= (symbol-name x) name)) x)
                   ((consp x) (or (walk (car x)) (walk (cdr x))))
                   (t nil))))
    (walk tree)))

(defmacro deftool (name parameters &body body)
  "Define and register a tool.

  (deftool read-file
      ((path :string \"Path to read\" :required t)
       (limit :integer \"Max lines\" :default 2000))
    (:doc \"Read a UTF-8 text file.\")
    (:contract (:pre ((stringp path)) :post ((stringp result))))
    …body, parameters bound…)

The :doc and :contract sections are mandatory for gene-authored tools
(the verifier enforces this); RESULT is bound in :post forms."
  (let* ((doc (second (assoc :doc body)))
         (contract (second (assoc :contract body)))
         (forms (remove-if (lambda (form)
                             (and (consp form)
                                  (member (first form) '(:doc :contract))))
                           body))
         ;; NAME may be a symbol inherited from another package (LIST-FILES,
         ;; or CL:SEARCH), and *package* is not reliably the gene package at
         ;; macroexpansion under every load path. So introduce NO interned
         ;; symbols: the impl function name is uninterned (belongs to no
         ;; package, immune to package locks), and RESULT is the exact symbol
         ;; the author already wrote in the :post forms.
         (impl-name (make-symbol (format nil "TOOL-IMPL/~A" (symbol-name name))))
         (result-var (or (find-symbol-named "RESULT" (getf contract :post))
                         (make-symbol "RESULT")))
         (args-var (gensym "ARGS"))
         (bindings
           (mapcar (lambda (parameter)
                     (destructuring-bind (pname type description
                                          &key required default)
                         parameter
                       (declare (ignore description))
                       `(,pname (tool-arg ,args-var
                                          ,(string-downcase (symbol-name pname))
                                          :required ,required
                                          :default ,default
                                          :type ,type))))
                   parameters))
         (pre-forms (pget contract :pre))
         (post-forms (pget contract :post)))
    `(progn
       (defun ,impl-name (,args-var)
         ,@(when doc (list doc))
         ;; A tool with no parameters never reads ARGS; keep the compile gate
         ;; (which rejects all warnings) happy for such genes.
         (declare (ignorable ,args-var))
         (let* ,bindings
           (declare (ignorable ,@(mapcar #'first parameters)))
           ,@(mapcar (lambda (form)
                       `(unless ,form
                          (error 'contract-violation
                                 :tool ,(tool-api-name name)
                                 :which :pre :form ',form)))
                     pre-forms)
           (let ((,result-var (progn ,@forms)))
             (declare (ignorable ,result-var))
             ,@(mapcar (lambda (form)
                         `(unless ,form
                            (error 'contract-violation
                                   :tool ,(tool-api-name name)
                                   :which :post :form ',form)))
                       post-forms)
             ,result-var)))
       (register-tool
        (make-instance 'tool
                       :name ,(tool-api-name name)
                       :lisp-name ',name
                       :description ,(or doc "")
                       :parameters ',(mapcar
                                      (lambda (parameter)
                                        (destructuring-bind (pname type description
                                                             &key required default)
                                            parameter
                                          (list pname type description
                                                :required required
                                                :default default)))
                                      parameters)
                       :function #',impl-name
                       :gene (pget *current-gene-context* :name)
                       ;; NIL is a real, least-authority declaration.  Only
                       ;; trusted base tools, loaded outside DEFGENE context,
                       ;; receive the full base grant.
                       :capabilities (if *current-gene-context*
                                         (copy-list
                                          (pget *current-gene-context*
                                                :capabilities))
                                         ourro.kernel:+all-capabilities+)
                       :contract ',contract))
       ',name)))
