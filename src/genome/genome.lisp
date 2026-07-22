
(defpackage #:ourro.api
  (:use)
  (:import-from #:cl
                ;; A generous but *pure* slice of CL. Effectful operators are
                ;; excluded here and banned by the walker; genes get effects
                ;; only through CAP/* wrappers and OURRO.TOOLKIT helpers.
                #:&allow-other-keys #:&aux #:&body #:&key #:&optional #:&rest
                #:* #:+ #:- #:/ #:1+ #:1- #:< #:<= #:= #:/= #:> #:>=
                #:abs #:and #:append #:apply #:aref #:assoc #:atom
                #:butlast #:car #:case #:ccase #:cdr #:char #:char= #:char-downcase
                #:char-upcase #:check-type #:coerce #:concatenate #:cond #:cons
                #:consp #:copy-list #:copy-seq #:count #:count-if #:decf #:declare
                #:defclass #:defconstant #:defgeneric #:defmacro #:defmethod
                #:defparameter #:defstruct #:defun #:defvar #:destructuring-bind
                #:do #:do* #:dolist #:dotimes #:ecase #:eq #:eql #:equal #:equalp
                #:error #:etypecase #:evenp #:every #:expt #:fifth #:find #:find-if
                #:first #:flet #:floor #:format #:fourth #:funcall #:function
                #:gensym #:getf #:gethash #:handler-bind #:handler-case #:identity
                #:if #:ignorable #:ignore #:ignore-errors #:incf #:integerp
                #:labels #:lambda #:last #:length #:let #:let* #:list #:list*
                #:listp #:loop #:make-array #:make-hash-table #:make-instance
                #:make-string #:map #:mapc #:mapcan #:mapcar #:max #:maphash
                #:member #:min #:minusp #:mod #:multiple-value-bind
                #:multiple-value-list #:nconc #:not #:nreverse #:nth #:nthcdr
                #:null #:numberp #:oddp #:or #:parse-integer #:plusp #:pop
                #:position #:position-if #:prin1-to-string #:princ-to-string
                ;; NB: RANDOM is deliberately NOT imported (PR-13, M5-2): a gene
                ;; has no *randomness* primitive, so it can't be nondeterministic
                ;; by chance. This is not a total no-nondeterminism guarantee —
                ;; environmental inputs (the clock) and GENSYM remain by design;
                ;; a tool that must be byte-reproducible declares a :determinism
                ;; probe the gauntlet verifies.
                #:prog1 #:progn #:push #:pushnew #:quote #:read-line
                #:reduce #:remhash #:remove #:remove-duplicates #:remove-if
                #:remove-if-not #:rest #:return #:return-from #:reverse #:round
                #:search #:second #:setf #:setq #:signal #:sleep #:some #:sort
                #:stable-sort #:string #:string-downcase #:string-equal
                #:string-trim #:string-upcase #:string= #:string< #:stringp
                #:subseq #:svref #:symbol-name #:symbolp #:t #:terpri #:third
                #:truncate #:typecase #:typep #:unless #:values #:values-list
                #:vector #:vectorp #:warn #:when #:with-output-to-string
                #:with-input-from-string #:write-string #:write-line #:zerop
                #:nil #:char-code #:code-char #:elt #:keywordp #:numerator
                #:denominator #:realp #:floatp #:write-char #:print-object
                #:stream #:slot-value #:with-slots #:defmethod
                ;; CLOS surface for UI genes (M3): live class migration and
                ;; method combination, so a gene can add a slot to a pane class
                ;; and specialize how on-screen instances are migrated.
                #:update-instance-for-redefined-class
                #:call-next-method #:next-method-p #:slot-makunbound
                #:slot-boundp #:change-class #:find-class)
  (:import-from #:ourro.tui
                ;; Evolvable TUI surface (M3), legal now that tui loads before
                ;; genome (D-2). Requires the :ui capability (walker-enforced).
                #:pane #:render-component #:styled #:wrap-text
                #:add-pane #:remove-pane #:define-status-widget #:bind-key)
  (:import-from #:ourro.kernel
                #:cap/read-file #:cap/write-file #:cap/delete-file
                #:cap/ensure-directories #:cap/run-program #:cap/launch-program
                #:cap/http-request #:require-capability)
  (:import-from #:ourro.tools
                #:deftool #:tool-arg #:run-tool #:tool #:find-tool #:list-tools)
  (:import-from #:ourro.toolkit
                #:*workspace* #:workspace-path #:display-path #:list-files
                #:search-files #:file-info #:read-file-numbered
                #:apply-text-edit #:clamp-output #:count-occurrences)
  (:import-from #:ourro.util
                #:trim #:string-join #:split-lines #:truncate-string
                #:string-prefix-p #:string-suffix-p #:pget #:iso-time)
  (:import-from #:ourro.observe
                #:recent-events #:enqueue-pattern #:add-turn-hook
                #:utility-summary #:context-summary
                ;; per-workspace memory (M14-4) — :observe
                #:workspace-known-p #:remember-workspace)
  (:import-from #:ourro.jobs
                ;; background jobs (M9) — :subprocess to start/kill, :observe to read
                #:start-job #:job-status #:job-kill #:jobs-summary)
  (:import-from #:ourro.automation
                ;; reflexes (M13) — trigger-driven automation genes. DEFINE-AUTOMATION
                ;; needs :automate; POST-NOTE needs :observe (walker-enforced).
                ;; REQUEST-INVESTIGATION (M15) needs :llm.
                #:define-automation #:post-note #:fire-automation-for-test
                #:request-investigation)
  (:import-from #:ourro.reflex.model #:define-reflex)
  (:import-from #:fiveam
                #:is #:is-true #:is-false #:signals #:finishes #:pass #:fail)
  (:export
   ;; re-export the entire surface: OURRO.GENES inherits via :use
   #:&allow-other-keys #:&aux #:&body #:&key #:&optional #:&rest
   #:* #:+ #:- #:/ #:1+ #:1- #:< #:<= #:= #:/= #:> #:>=
   #:abs #:and #:append #:apply #:aref #:assoc #:atom
   #:butlast #:car #:case #:ccase #:cdr #:char #:char= #:char-downcase
   #:char-upcase #:check-type #:coerce #:concatenate #:cond #:cons
   #:consp #:copy-list #:copy-seq #:count #:count-if #:decf #:declare
   #:defclass #:defconstant #:defgeneric #:defmacro #:defmethod
   #:defparameter #:defstruct #:defun #:defvar #:destructuring-bind
   #:do #:do* #:dolist #:dotimes #:ecase #:eq #:eql #:equal #:equalp
   #:error #:etypecase #:evenp #:every #:expt #:fifth #:find #:find-if
   #:first #:flet #:floor #:format #:fourth #:funcall #:function
   #:gensym #:getf #:gethash #:handler-bind #:handler-case #:identity
   #:if #:ignorable #:ignore #:ignore-errors #:incf #:integerp
   #:labels #:lambda #:last #:length #:let #:let* #:list #:list*
   #:listp #:loop #:make-array #:make-hash-table #:make-instance
   #:make-string #:map #:mapc #:mapcan #:mapcar #:max #:maphash
   #:member #:min #:minusp #:mod #:multiple-value-bind
   #:multiple-value-list #:nconc #:not #:nreverse #:nth #:nthcdr
   #:null #:numberp #:oddp #:or #:parse-integer #:plusp #:pop
   #:position #:position-if #:prin1-to-string #:princ-to-string
   ;; RANDOM intentionally absent (see the import-from note above) — PR-13/M5-2.
   #:prog1 #:progn #:push #:pushnew #:quote #:read-line
   #:reduce #:remhash #:remove #:remove-duplicates #:remove-if
   #:remove-if-not #:rest #:return #:return-from #:reverse #:round
   #:search #:second #:setf #:setq #:signal #:sleep #:some #:sort
   #:stable-sort #:string #:string-downcase #:string-equal
   #:string-trim #:string-upcase #:string= #:string< #:stringp
   #:subseq #:svref #:symbol-name #:symbolp #:t #:terpri #:third
   #:truncate #:typecase #:typep #:unless #:values #:values-list
   #:vector #:vectorp #:warn #:when #:with-output-to-string
   #:with-input-from-string #:write-string #:write-line #:zerop
   #:nil #:char-code #:code-char #:elt #:keywordp #:numerator
   #:denominator #:realp #:floatp #:write-char #:print-object
   #:stream #:slot-value #:with-slots
   #:update-instance-for-redefined-class
   #:call-next-method #:next-method-p #:slot-makunbound
   #:slot-boundp #:change-class #:find-class
   ;; evolvable TUI surface (M3) — requires the :ui capability
   #:pane #:render-component #:styled #:wrap-text
   #:add-pane #:remove-pane #:define-status-widget #:bind-key
   ;; kernel capability wrappers
   #:cap/read-file #:cap/write-file #:cap/delete-file
   #:cap/ensure-directories #:cap/run-program #:cap/launch-program
   #:cap/http-request #:require-capability
   ;; tools
   #:deftool #:tool-arg #:run-tool #:tool #:find-tool #:list-tools
   ;; toolkit
   #:*workspace* #:workspace-path #:display-path #:list-files
   #:search-files #:file-info #:read-file-numbered
   #:apply-text-edit #:clamp-output #:count-occurrences
   ;; util
   #:trim #:string-join #:split-lines #:truncate-string
   #:string-prefix-p #:string-suffix-p #:pget #:iso-time
   ;; observe — evolvable mining surface (requires :observe capability)
   #:recent-events #:enqueue-pattern #:add-turn-hook #:utility-summary
   #:context-summary #:workspace-known-p #:remember-workspace
   ;; jobs — background subprocesses (M9)
   #:start-job #:job-status #:job-kill #:jobs-summary
   ;; reflexes — trigger-driven automation genes (M13) + the intern (M15)
   #:define-automation #:post-note #:fire-automation-for-test
   #:request-investigation #:define-reflex
   ;; fiveam
   #:is #:is-true #:is-false #:signals #:finishes #:pass #:fail
   ;; genome (defined below, re-exported here)
   #:defgene))

(defpackage #:ourro.genes
  (:use #:ourro.api)
  (:documentation "Home package of all genome code."))

(defpackage #:ourro.genome
  (:use #:cl #:ourro.util)
  (:import-from #:ourro.kernel
                #:record-function-definition
                #:record-method-definition
                #:safe-read-form)
  (:export #:gene
           #:gene-name
           #:gene-metadata
           #:gene-capabilities
           #:gene-doc
           #:gene-code-forms
           #:gene-test-forms
           #:gene-source-text
           #:gene-file
           #:gene-suite-name
           #:gene-generation
           #:gene-provenance
           #:gene-determinism
           #:*gene-registry*
           #:*loading-gene-file*
           #:find-gene
           #:list-genes
           #:register-gene
           #:parse-gene-form
           #:parse-gene-source
           #:gene-file-path
           #:read-manifest
           #:write-manifest
           #:load-genome
           #:hot-load-gene
           #:*hot-loads-since-boot*
           #:gene-definition-names
           #:render-gene-source
           #:genome-generation-number
           #:*genome-directory*
           #:*hot-load-hook*
           #:run-gene-tests))

(in-package #:ourro.genome)


(defclass gene ()
  ((name :initarg :name :reader gene-name
         :documentation "Canonical name string, e.g. \"tool/read-file\".")
   (metadata :initarg :metadata :initform '() :reader gene-metadata)
   (doc :initarg :doc :initform nil :reader gene-doc)
   (code-forms :initarg :code-forms :initform '() :reader gene-code-forms)
   (test-forms :initarg :test-forms :initform '() :reader gene-test-forms)
   (source-text :initarg :source-text :initform nil :reader gene-source-text)
   (file :initarg :file :initform nil :accessor gene-file
         :documentation "Manifest-relative path, e.g. \"genes/tools/read-file.gene\".")))

(defun gene-capabilities (gene) (pget (gene-metadata gene) :capabilities))
(defun gene-generation (gene) (pget (gene-metadata gene) :generation))
(defun gene-provenance (gene) (pget (gene-metadata gene) :provenance))
(defun gene-determinism (gene) (pget (gene-metadata gene) :determinism))

(defun gene-suite-name (gene-name)
  "FiveAM suite symbol for a gene."
  (intern (format nil "GENE-SUITE/~A" (string-upcase gene-name))
          :ourro.genes))

(defvar *gene-registry* (make-hash-table :test #'equal)
  "name string → GENE. Special so verification can stage against a copy.")

(defvar *loading-gene-file* nil
  "Bound while loading a gene file so registration records provenance.")

(defun canonical-gene-name (name)
  (string-downcase (princ-to-string name)))

(defun find-gene (name &optional (registry *gene-registry*))
  (gethash (canonical-gene-name name) registry))

(defun list-genes (&optional (registry *gene-registry*))
  (let ((genes '()))
    (maphash (lambda (name gene) (declare (ignore name)) (push gene genes))
             registry)
    (sort genes #'string< :key #'gene-name)))

(defun register-gene (gene)
  (setf (gethash (gene-name gene) *gene-registry*) gene))


(defun section (body key)
  (rest (assoc key body)))

(defun parse-gene-form (form &key source-text file)
  "Parse a (defgene NAME (METADATA…) SECTIONS…) form into a GENE.
Signals a descriptive error on malformed genes."
  (unless (and (consp form)
               (symbolp (first form))
               (string-equal (symbol-name (first form)) "DEFGENE"))
    (error "Not a DEFGENE form: ~A"
           (truncate-string (prin1-to-string form) 120)))
  (destructuring-bind (head name metadata &rest sections) form
    (declare (ignore head))
    (unless (symbolp name)
      (error "Gene name must be a symbol, got ~S" name))
    (unless (listp metadata)
      (error "Gene metadata must be a plist, got ~S" metadata))
    (dolist (s sections)
      (unless (and (consp s)
                   (member (first s) '(:doc :code :tests :contract)
                           :test #'string-equal))
        (error "Unknown gene section ~S (expected :doc, :code, :tests)"
               (if (consp s) (first s) s))))
    (let ((code (section sections :code))
          (tests (section sections :tests)))
      (unless code
        (error "Gene ~A has no (:code …) section" name))
      (make-instance 'gene
                     :name (canonical-gene-name name)
                     :metadata (normalize-metadata metadata)
                     :doc (first (section sections :doc))
                     :code-forms code
                     :test-forms tests
                     :source-text source-text
                     :file file))))

(defun normalize-metadata (metadata)
  (list :generation (pget metadata :generation)
        :parent (and (pget metadata :parent)
                     (canonical-gene-name (pget metadata :parent)))
        :capabilities (pget metadata :capabilities)
        :provenance (pget metadata :provenance)
        ;; Optional determinism contract (M5-2): a list of tool probes
        ;; ((\"tool_name\" :arg v …) …) the gauntlet re-runs to prove the tool
        ;; is byte-identical across calls. The gene declares what it claims is
        ;; reproducible; the verifier proves it before the gene goes live.
        :determinism (pget metadata :determinism)))

(defun parse-gene-source (text &key file (package (find-package :ourro.genes)))
  "Read TEXT (one DEFGENE form) in PACKAGE with *READ-EVAL* NIL and parse it.
This is the entry point for both trusted genome files and (via the
verifier, with a scratch package) untrusted candidates."
  (let ((form (safe-read-form text :package package)))
    (parse-gene-form form :source-text text :file file)))

(defun render-gene-source (gene)
  "The canonical textual form of GENE (what gets written to its file)."
  (or (gene-source-text gene)
      (with-standard-io-syntax
        (let ((*package* (find-package :ourro.genes))
              (*print-case* :downcase)
              (*print-pretty* t)
              (*print-readably* nil)
              (*print-right-margin* 78))
          (format nil "(defgene ~A~%    ~S~%~@[  (:doc ~S)~%~]  (:code~{~%    ~S~})~@[~%  (:tests~{~%    ~S~})~])~%"
                  (gene-name gene)
                  (gene-metadata gene)
                  (gene-doc gene)
                  (gene-code-forms gene)
                  (gene-test-forms gene))))))


(defun rewrite-test-form (form suite-name)
  "(test NAME …) → (fiveam:test (NAME :suite SUITE) …)."
  (if (and (consp form)
           (symbolp (first form))
           (string-equal (symbol-name (first form)) "TEST")
           (symbolp (second form)))
      `(fiveam:test (,(second form) :suite ,suite-name)
         ,@(cddr form))
      form))

;; Defined on the OURRO.API symbol: genes live in OURRO.GENES, which only
;; uses OURRO.API, so the macro must be that package's DEFGENE.
(defmacro ourro.api:defgene (name metadata &rest sections)
  (let* ((gene (parse-gene-form `(defgene ,name ,metadata ,@sections)))
         (name-string (gene-name gene))
         (suite (gene-suite-name name-string)))
    `(progn
       (eval-when (:load-toplevel :execute)
         (register-gene
          (make-instance 'gene
                         :name ,name-string
                         :metadata ',(gene-metadata gene)
                         :doc ,(gene-doc gene)
                         :code-forms ',(gene-code-forms gene)
                         :test-forms ',(gene-test-forms gene)
                         :source-text ourro.genome::*current-gene-source*
                         :file *loading-gene-file*)))
       ,@(gene-code-forms gene)
       (fiveam:def-suite ,suite)
       ,@(mapcar (lambda (form) (rewrite-test-form form suite))
                 (gene-test-forms gene))
       ',name)))

(defvar *current-gene-source* nil
  "Bound to the gene file's text while it is being compiled/loaded, so the
registered gene keeps its authoritative source.")

(defvar *hot-load-hook* nil
  "Optional (function of the freshly hot-loaded GENE) run after a successful
hot-load. The evolver uses it to invalidate its cached harness manual so the
self-describing prompt can never go stale after a redefinition (PR-9).")

(defvar *hot-loads-since-boot* 0
  "How many genes have been hot-loaded into THIS live image since boot. When
nonzero the live registry is ahead of the built image, so the out-of-process
gauntlet (M12-3) must stay in-process — a child of the image would be stale.")


(defvar *genome-directory* nil
  "The genome directory the running image was built from / loaded.")

(defun read-manifest (genome-dir)
  (let ((manifest (read-sexp-file (merge-pathnames "manifest.sexp" genome-dir))))
    (unless manifest
      (error "No manifest.sexp in ~A" genome-dir))
    manifest))

(defun write-manifest (genome-dir manifest)
  (write-sexp-file (merge-pathnames "manifest.sexp" genome-dir) manifest))

(defun manifest-gene-files (manifest)
  (pget manifest :genes))

(defun genome-generation-number (&optional (manifest nil manifest-p))
  (let ((manifest (if manifest-p manifest
                      (and *genome-directory*
                           (read-manifest *genome-directory*)))))
    (or (and manifest (pget manifest :generation)) 1)))

(defun gene-file-path (relative &optional (genome-dir *genome-directory*))
  (merge-pathnames relative genome-dir))

(defun compile-and-load-gene-file (path)
  "Compile PATH (a .gene file: one DEFGENE form) with *PACKAGE* = OURRO.GENES
and load the result. Returns the compiled fasl truename."
  (let* ((source-text (uiop:read-file-string path))
         (gene (parse-gene-source source-text :file path))
         (context (list :name (gene-name gene)
                        :capabilities (gene-capabilities gene))))
    (let ((*package* (find-package :ourro.genes))
          (*current-gene-source* source-text)
          (ourro.kernel:*current-gene-context* context)
          (fasl (merge-pathnames
                 (format nil "~A-~A.fasl" (pathname-name path) (make-id "f"))
                 (uiop:ensure-directory-pathname
                  (merge-pathnames "ourro-fasl/" (uiop:temporary-directory))))))
      (ensure-directories-exist fasl)
      (multiple-value-bind (output warnings-p failure-p)
          (compile-file path :output-file fasl :verbose nil :print nil)
        (declare (ignore warnings-p))
        (when failure-p
          (error "Gene file ~A failed to compile" path))
        (load output)
        output))))

(defun load-genome (genome-dir &key (record t))
  "Compile and load every gene in GENOME-DIR's manifest, in order.
Used both by the image build script and by dev-mode boot."
  (let* ((genome-dir (uiop:ensure-directory-pathname genome-dir))
         (manifest (read-manifest genome-dir)))
    (setf *genome-directory* genome-dir)
    (dolist (relative (manifest-gene-files manifest))
      (let ((*loading-gene-file* relative))
        (compile-and-load-gene-file (gene-file-path relative genome-dir))))
    (when record
      (setf *genome-directory* genome-dir))
    (length (manifest-gene-files manifest))))


(defun gene-definition-names (gene)
  "Statically extract the names GENE defines: ((:function f) (:tool \"x\")
(:method m qualifiers specializers) (:class c) …)."
  (let ((definitions '()))
    (dolist (form (gene-code-forms gene))
      (when (consp form)
        (let ((head (and (symbolp (first form)) (symbol-name (first form)))))
          (cond
            ((member head '("DEFUN" "DEFMACRO") :test #'string=)
             (push (list :function (second form)) definitions))
            ((string= head "DEFTOOL")
             ;; The tool's implementation function is bound to an *uninterned*
             ;; symbol (see DEFTOOL), reachable only through the tool object,
             ;; so there is no global definition to revert or name here — the
             ;; :tool entry fully covers install/revert. (Interning a
             ;; TOOL-IMPL/… symbol here also crashed for tools named after CL
             ;; symbols like SEARCH, whose home package is locked.)
             (push (list :tool (ourro.tools::tool-api-name (second form)))
                   definitions))
            ((string= head "DEFMETHOD")
             (let* ((name (second form))
                    (qualifiers (loop for x in (cddr form)
                                      until (listp x)
                                      collect x))
                    (lambda-list (nth (+ 2 (length qualifiers)) form))
                    (required (loop for parameter in lambda-list
                                    until (and (symbolp parameter)
                                               (string-prefix-p
                                                "&" (symbol-name parameter)))
                                    collect parameter)))
               (push (list :method name qualifiers
                           (mapcar (lambda (parameter)
                                     (if (consp parameter)
                                         (second parameter)
                                         t))
                                   required))
                     definitions)))
            ((member head '("DEFCLASS" "DEFSTRUCT") :test #'string=)
             (push (list :class (if (consp (second form))
                                    (first (second form))
                                    (second form)))
                   definitions))
            ((member head '("DEFVAR" "DEFPARAMETER") :test #'string=)
             (push (list :variable (second form)) definitions))
            ;; Reflexes (M13): DEFINE-AUTOMATION registers a trigger-driven
            ;; automation. Its revert-action is recorded at load time by
            ;; REGISTER-AUTOMATION (owner-checked), like a turn hook or UI
            ;; widget, so there is nothing to snapshot — the :automation entry
            ;; exists so the inspector's structural diff shows ＋ automation, and
            ;; so the consent lifecycle (M14) can detect automation-bearing genes.
            ((string= head "DEFINE-AUTOMATION")
             (push (list :automation (string-downcase (string (second form))))
                   definitions))
            ((string= head "DEFINE-REFLEX")
             (push (list :reflex (string-downcase (string (second form))))
                   definitions))))))
    (nreverse definitions)))

(defun snapshot-gene-targets (gene)
  "Record revert information for everything GENE is about to redefine."
  (let ((name (gene-name gene)))
    ;; One version, one undo frame.  Replacing A→B→C must undo C to B, not
    ;; replay both historical frames and jump all the way back to A.
    (ourro.kernel:clear-revert-records name)
    (let ((previous-gene (find-gene name)))
      (ourro.kernel:record-revert-action
       name
       (if previous-gene
           (lambda () (register-gene previous-gene))
           (lambda () (remhash name *gene-registry*)))
       :description (format nil "restore gene registry entry ~A" name)))
    (dolist (definition (gene-definition-names gene))
      (ecase (first definition)
        (:function
         (record-function-definition name (second definition)))
        (:tool
         (let* ((tool-name (second definition))
                (existing (ourro.tools:find-tool tool-name)))
           (ourro.kernel:record-revert-action
            name
            (if existing
                (lambda () (ourro.tools:register-tool existing))
                (lambda () (ourro.tools:unregister-tool tool-name)))
            :description (format nil "restore tool ~A" tool-name))))
        (:method
         (destructuring-bind (kind gf-name qualifiers specializers) definition
           (declare (ignore kind))
           (when (and (symbolp gf-name) (fboundp gf-name)
                      (typep (fdefinition gf-name) 'generic-function))
             (let* ((gf (fdefinition gf-name))
                    (classes (mapcar (lambda (s)
                                       (if (eq s t)
                                           (find-class t)
                                           (or (find-class s nil) (find-class t))))
                                     specializers))
                    (existing (ignore-errors
                               (find-method gf qualifiers classes nil))))
               (record-method-definition name gf existing qualifiers classes)))))
        (:variable
         (let* ((symbol (second definition))
                (bound (boundp symbol))
                (value (and bound (symbol-value symbol))))
           (ourro.kernel:record-revert-action
            name
            (if bound
                (lambda () (setf (symbol-value symbol) value))
                (lambda () (when (boundp symbol) (makunbound symbol))))
            :description (format nil "restore variable ~A" symbol))))
        (:class
         (let* ((symbol (second definition))
                (existing (find-class symbol nil)))
           (ourro.kernel:record-revert-action
            name
            (cond
              ((null existing)
               (lambda () (setf (find-class symbol) nil)))
              ((typep existing 'standard-class)
               (let ((supers (copy-list (sb-mop:class-direct-superclasses existing)))
                     (slots
                       (mapcar
                        (lambda (slot)
                          (list :name (sb-mop:slot-definition-name slot)
                                :initargs (copy-list (sb-mop:slot-definition-initargs slot))
                                :initform (sb-mop:slot-definition-initform slot)
                                :initfunction (sb-mop:slot-definition-initfunction slot)
                                :readers (copy-list (sb-mop:slot-definition-readers slot))
                                :writers (copy-list (sb-mop:slot-definition-writers slot))
                                :allocation (sb-mop:slot-definition-allocation slot)
                                :type (sb-mop:slot-definition-type slot)))
                        (sb-mop:class-direct-slots existing)))
                     (defaults (copy-tree
                                (sb-mop:class-direct-default-initargs existing)))
                     (metaclass (class-of existing)))
                 ;; ENSURE-CLASS performs a proper CLOS redefinition, including
                 ;; UPDATE-INSTANCE-FOR-REDEFINED-CLASS for live instances.
                 (lambda ()
                   (sb-mop:ensure-class
                    symbol :metaclass metaclass :direct-superclasses supers
                    :direct-slots slots :direct-default-initargs defaults))))
              (t
               (error "Cannot transactionally replace non-standard class ~A"
                      symbol)))
            :description (format nil "restore class ~A" symbol))))
        ;; :automation's revert-action is recorded at load time by
        ;; REGISTER-AUTOMATION (owner-checked).
        (:automation nil)))))

(defun hot-load-gene (source-text &key file)
  "Load verified gene SOURCE-TEXT into the live image: parse (trusted by
now), snapshot revert targets, compile+load in OURRO.GENES, register, and
put the gene on probation. Returns the GENE."
  ;; Uninterruptible section (M7-1): a mid-load escalated turn-cancel would tear
  ;; the revert table / registry, so an interrupt lambda no-ops while this is
  ;; set. let* so the guard is in effect for the whole body (parse included).
  (let* ((ourro.kernel:*cancel-inhibited* t)
         (gene (parse-gene-source source-text :file file)))
    (snapshot-gene-targets gene)
    (let ((path (merge-pathnames
                 (format nil "hotload-~A.gene" (make-id "hl"))
                 (uiop:ensure-directory-pathname
                  (merge-pathnames "ourro-hotload/" (uiop:temporary-directory))))))
      (ensure-directories-exist path)
      (with-open-file (out path :direction :output :if-exists :supersede)
        (write-string source-text out))
      (let ((*loading-gene-file* file))
        (compile-and-load-gene-file path))
      (ourro.kernel:start-probation (gene-name gene))
      ;; Retained as useful runtime state/telemetry. Production verification is
      ;; always isolated even when the live registry is ahead of the image.
      (incf *hot-loads-since-boot*)
      (let ((loaded (find-gene (gene-name gene))))
        (when *hot-load-hook*
          (ignore-errors (funcall *hot-load-hook* loaded)))
        loaded))))

(defun run-gene-tests (gene-name)
  "Run a loaded gene's FiveAM suite. Returns (values passed-p report)."
  (let* ((suite (gene-suite-name gene-name))
         (results (fiveam:run suite))
         (passed (every (lambda (result)
                          (typep result 'fiveam::test-passed))
                        results)))
    (values passed
            (with-output-to-string (out)
              (let ((fiveam:*test-dribble* out))
                (fiveam:explain! results))))))
