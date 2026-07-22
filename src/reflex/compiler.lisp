
(defpackage #:ourro.reflex.compiler
  (:use #:cl #:ourro.util)
  (:export #:compile-reflex
           #:compile-gene-reflexes
           #:reflex-forms-in-gene
           #:legacy-automation-semantics
           #:generate-transition-form
           #:generated-lisp-safe-p
           #:version-current-p
           #:rebuild-reflex-dependency-closure
           #:refresh-reflex-dependency-fingerprint
           #:install-reflex-version
           #:activate-reflex-version
           #:stage-reflex-version
           #:canary-reflex-version
           #:promote-reflex-version
           #:active-reflex-version
           #:active-reflex-versions
           #:select-routed-reflex-versions
           #:record-canary-firing
           #:canary-route
           #:find-reflex-version
           #:quarantine-reflex-version
           #:rollback-reflex-version
           #:purge-workspace-reflex-versions
           #:workspace-version-residue
           #:copy-version-registry
           #:*version-registry*
           #:*active-version-pointers*
           #:*canary-routes*
           #:*version-quarantine-hook*
           #:*version-rollback-hook*))

(in-package #:ourro.reflex.compiler)

(defvar *version-registry* (make-hash-table :test #'equal))
(defvar *active-version-pointers* (make-hash-table :test #'equal))
(defvar *canary-routes* (make-hash-table :test #'equal))
(defvar *version-lock* (bt:make-lock "ourro-reflex-versions"))
(defvar *version-quarantine-hook* nil
  "Trusted runtime barrier invoked after routing closes and before rollback returns.")
(defvar *version-rollback-hook* nil
  "Trusted runtime hook that migrates the quarantined state view before routing rolls back.")
(defvar *transition-generator* nil
  "Trusted lowering seam. Tests bind this to prove the generated-code gate fails closed.")
(defvar *dependency-fingerprint-override* nil
  "Hermetic test seam for invalidating the trusted compiler dependency closure.")
(defvar *dependency-fingerprint-cache* nil)

(defparameter +trusted-reflex-dependencies+
  '("src/kernel/transaction.lisp"
    "src/kernel/walker.lisp"
    "src/reflex/model.lisp"
    "src/reflex/proof.lisp"
    "src/reflex/compiler.lisp"
    "src/reflex/effects.lisp"))

(defun copy-version-registry ()
  (copy-hash-table *version-registry* :value-copier #'copy-list))

(defun reflex-forms-in-gene (gene)
  (remove-if-not
   (lambda (form)
     (and (consp form) (symbolp (first form))
          (string-equal "DEFINE-REFLEX" (symbol-name (first form)))))
   (ourro.genome:gene-code-forms gene)))

(defun operator-named-p (form name)
  (and (consp form) (symbolp (first form))
       (string-equal name (symbol-name (first form)))))

(defun automation-forms-in-gene (gene)
  (remove-if-not (lambda (form) (operator-named-p form "DEFINE-AUTOMATION"))
                 (ourro.genome:gene-code-forms gene)))

(defun declarative-note-automation-form (form)
  "Return an equivalent one-step DEFINE-REFLEX form, or NIL for opaque Lisp."
  (when (and (= (length form) 4)
             (symbolp (second form))
             (listp (third form))
             (evenp (length (third form)))
             (listp (pget (third form) :on))
             (operator-named-p (fourth form) "POST-NOTE")
             (stringp (second (fourth form)))
             (or (= (length (fourth form)) 2)
                 (and (= (length (fourth form)) 4)
                      (eq :style (third (fourth form)))
                      (keywordp (fourth (fourth form))))))
    (let* (;; Candidate source is read in a disposable package. Retaining its
           ;; NAME symbol would leave an uninterned symbol after verification,
           ;; which the canonical proof codec correctly rejects. The DSL name
           ;; is data, so lower it into the stable keyword package.
           (name (intern (string-upcase (symbol-name (second form))) :keyword))
           (options (third form))
           (call (fourth form))
           (input (append (list :text (second call))
                          (when (fourth call) (list :style (fourth call))))))
      `(define-reflex ,name
         (:identity (:version 1 :workspace :current
                     :capabilities (:observe)))
         (:trigger ,(copy-tree (pget options :on)))
         (:guards ())
         (:state (:version 1 :initial-step :notify))
         (:workflow ((:id :notify :activity :notify
                      :input ,input :next :done)))
         (:policy (:approval :required
                   :legacy-automation :declarative-subset
                   :cooldown ,(or (pget options :cooldown) 30)
                   :defer ,(or (pget options :defer) :auto)))))))

(defun legacy-automation-semantics (gene)
  "Classify legacy DEFINE-AUTOMATION forms without granting Lisp bodies durable semantics."
  (mapcar
   (lambda (form)
     (let ((lowered (declarative-note-automation-form form)))
       (list :name (and (symbolp (second form))
                        (string-downcase (string (second form))))
             :semantics (if lowered :compiled-subset :opaque)
             :replayable (and lowered t)
             :promotable (and lowered t)
             :lowered-reflex-form lowered
             :reason (unless lowered
                       "arbitrary legacy Lisp body has no durable/replayable semantics"))))
   (automation-forms-in-gene gene)))

(defun generated-lisp-safe-p (form)
  "Reject any generated form that names a raw effect or trusted product internals."
  (let ((forbidden '("CAP/READ-FILE" "CAP/WRITE-FILE" "CAP/DELETE-FILE"
                     "CAP/RUN-PROGRAM" "CAP/HTTP-REQUEST" "RUN-PROGRAM"
                     "OPEN" "DELETE-FILE" "EVAL" "COMPILE" "FUNCALL")))
    (labels ((safe (node)
               (cond ((consp node) (and (safe (car node)) (safe (cdr node))))
                     ((symbolp node)
                      (and (not (member (symbol-name node) forbidden :test #'string=))
                           (let ((package (symbol-package node)))
                             (or (null package)
                                 (member (package-name package)
                                         '("COMMON-LISP" "KEYWORD"
                                           "OURRO.REFLEX.COMPILER")
                                         :test #'string=)))))
                     (t t))))
      (safe form))))

(defun generate-transition-form (definition)
  "Generate a deterministic transition closure over retained declarative data."
  (let* ((workflow (ourro.reflex.model:reflex-workflow definition))
         (first-step (pget (first workflow) :id)))
    `(lambda (state event activity-results)
       (declare (ignore activity-results))
       (let* ((step-id (or (getf state :step) ,first-step))
              ;; Durable instance state retains the causal identity, not a
              ;; recursively embedded copy of an arbitrarily wide event. The
              ;; journal is the source of truth for the payload and effects
              ;; dereference it at their commit boundary.
              (trigger-event-id
                (or (and event (getf event :event-id))
                    (getf state :trigger-event-id)
                    (getf (getf state :trigger-event) :event-id)))
              (step (find step-id ',workflow
                          :key (lambda (item) (getf item :id)))))
         ;; :DONE is a durable state, not a workflow activity.  Effect results
         ;; advance an instance once more after the activity completes, so the
         ;; terminal state must be idempotently readable during that advance.
         (if (eq step-id :done)
             (list :state (copy-list state) :effects '() :terminal t)
             (progn
               (unless step (error "unknown durable reflex step ~S" step-id))
               (let ((next (or (getf step :next) :done))
                     (next-state (copy-list state)))
                 ;; Schema-owned state survives transitions. Only the durable
                 ;; workflow cursor and causal reference are compiler-managed.
                 (setf (getf next-state :step) next
                       (getf next-state :trigger-event-id) trigger-event-id)
                 (list :state next-state
                       :effects (if (eq (getf step :activity) :finish)
                                    '()
                                    (list (copy-list step)))
                       :terminal (eq next :done)))))))))

(defun trusted-dependency-fingerprint ()
  (or *dependency-fingerprint-override*
      *dependency-fingerprint-cache*
      (setf *dependency-fingerprint-cache*
            (let ((root (ignore-errors
                          (asdf:system-source-directory "ourro"))))
              (if root
                  (ourro.txn:canonical-hash
                   (mapcar (lambda (relative)
                             (let ((path (merge-pathnames relative root)))
                               (list relative
                                     (if (probe-file path)
                                         (ourro.txn:sha256-file path)
                                         :unavailable))))
                           +trusted-reflex-dependencies+))
                  :unavailable)))))

(defun refresh-reflex-dependency-fingerprint ()
  "Re-read trusted compiler sources. Existing compiled closures then fail closed."
  (setf *dependency-fingerprint-cache* nil)
  (trusted-dependency-fingerprint))

(defun compiler-fingerprints ()
  (list :dsl-version 1
        :compiler-version 1
        :dependency-closure-hash (trusted-dependency-fingerprint)
        :lisp-implementation (lisp-implementation-type)
        :lisp-version (lisp-implementation-version)
        :machine (machine-type)
        :compiler-policy '((safety 1) (debug 1) (speed 1) (space 1))))

(defun compile-reflex (definition &key base-proof-hash)
  (ourro.reflex.model:validate-reflex definition)
  (let* ((ir (ourro.reflex.model:canonical-reflex-ir definition))
         (generated (funcall (or *transition-generator*
                                 #'generate-transition-form)
                             definition)))
    (unless (generated-lisp-safe-p generated)
      (error "trusted reflex lowering produced forbidden generated Lisp"))
    (let* ((function (compile nil generated))
           (fingerprints (compiler-fingerprints))
           (proof (ourro.reflex.proof:make-reflex-proof
                   :definition definition :ir ir :generated-lisp generated
                   :base-proof-hash base-proof-hash :fingerprints fingerprints
                   :diagnostics '(:validation :passed :generated-walk :passed)
                   :replay-cases '()))
           ;; Logical version identity is reproducible from genome + trusted
           ;; toolchain. Verification/install facts reference it but do not
           ;; perturb it, so a cold image reconstructs the same version.
           (hash (ourro.txn:canonical-hash (list ir fingerprints))))
      (unless (ourro.reflex.proof:reflex-proof-valid-p proof)
        (error "reflex compiler produced an invalid proof bundle"))
      (make-instance 'ourro.reflex.model:reflex-version
                     :hash hash :definition definition :ir ir
                     :generated-lisp generated :transition-function function
                     :proof proof :status :verified))))

(defun compile-gene-reflexes (gene &key base-proof-hash)
  (let ((forms
          (append
           (reflex-forms-in-gene gene)
           (remove nil
                   (mapcar (lambda (entry)
                             (pget entry :lowered-reflex-form))
                           (legacy-automation-semantics gene))))))
    (mapcar (lambda (form)
              (compile-reflex (ourro.reflex.model:definition-from-form form)
                              :base-proof-hash base-proof-hash))
            forms)))

(defun version-current-p (version)
  "True when VERSION was compiled by this exact trusted dependency closure."
  (let ((fingerprints (pget (ourro.reflex.model:version-proof version)
                            :fingerprints)))
    (equal (pget fingerprints :dependency-closure-hash)
           (trusted-dependency-fingerprint))))

(defun ensure-current-version (version operation)
  (unless (version-current-p version)
    (error "reflex dependency closure changed; ~A requires an explicit rebuild"
           operation))
  version)

(defun rebuild-reflex-dependency-closure ()
  "Invalidate every stale closure and rebuild all registered definitions.

Routing remains closed: rebuilt hashes require a fresh exact-version blessing."
  (let ((definitions '()) (rebuilt '()))
    (maphash (lambda (name definition)
               (declare (ignore name))
               (push definition definitions))
             ourro.reflex.model:*reflex-definitions*)
    (bt:with-lock-held (*version-lock*)
      (maphash (lambda (name versions)
                 (declare (ignore name))
                 (dolist (version versions)
                   (unless (version-current-p version)
                     (setf (ourro.reflex.model:version-status version) :stale))))
               *version-registry*)
      (clrhash *active-version-pointers*)
      (clrhash *canary-routes*))
    (dolist (definition definitions)
      (push (install-reflex-version (compile-reflex definition)) rebuilt))
    (nreverse rebuilt)))

(defun install-reflex-version (version)
  "Publish immutable VERSION as verified but do not activate it."
  (let* ((definition (ourro.reflex.model:version-definition version))
         (name (ourro.reflex.model:reflex-name definition))
         (hash (ourro.reflex.model:version-hash version)))
    (bt:with-lock-held (*version-lock*)
      (unless (find hash (gethash name *version-registry*)
                    :key #'ourro.reflex.model:version-hash :test #'string=)
        (push version (gethash name *version-registry*))))
    version))

(defun find-reflex-version-unlocked (name hash)
  (find hash (gethash (string-downcase (string name)) *version-registry*)
        :key #'ourro.reflex.model:version-hash :test #'string=))

(defun find-reflex-version (name hash)
  (bt:with-lock-held (*version-lock*)
    (find-reflex-version-unlocked name hash)))

(defun activate-reflex-version (name hash &key approved-authority)
  "Atomically route new instances to exactly the reviewed immutable version."
  (bt:with-lock-held (*version-lock*)
    (let ((version (find hash (gethash (string-downcase (string name))
                                      *version-registry*)
                         :key #'ourro.reflex.model:version-hash :test #'string=)))
      (unless version (error "unknown reflex version ~A/~A" name hash))
      (ensure-current-version version "activation")
      (unless (eq :verified (ourro.reflex.model:version-status version))
        (error "reflex version is not eligible for activation"))
      (unless (equal approved-authority
                     (ourro.reflex.model:reflex-capabilities
                      (ourro.reflex.model:version-definition version)))
        (error "approval does not match the exact version authority"))
      (setf (gethash (string-downcase (string name)) *active-version-pointers*)
            hash
            (ourro.reflex.model:version-status version) :active)
      (remhash (string-downcase (string name)) *canary-routes*)
      version)))

(defun stage-reflex-version (name hash &key approved-authority)
  "Enter the reviewed staged state without changing runtime routing."
  (bt:with-lock-held (*version-lock*)
    (let ((version (find hash (gethash (string-downcase (string name))
                                      *version-registry*)
                         :key #'ourro.reflex.model:version-hash :test #'string=)))
      (unless version (error "unknown reflex version ~A/~A" name hash))
      (ensure-current-version version "staging")
      (unless (eq :verified (ourro.reflex.model:version-status version))
        (error "only a verified reflex can enter staged review"))
      (unless (equal approved-authority
                     (ourro.reflex.model:reflex-capabilities
                      (ourro.reflex.model:version-definition version)))
        (error "staged authority does not match the exact compiled version"))
      (setf (ourro.reflex.model:version-status version) :staged)
      version)))

(defun canary-reflex-version (name hash &key approved-authority)
  "Route new instances to a once-blessed exact version in CANARY state."
  (bt:with-lock-held (*version-lock*)
    (let* ((key (string-downcase (string name)))
           (fallback (gethash key *active-version-pointers*))
           (version (find hash (gethash key *version-registry*)
                          :key #'ourro.reflex.model:version-hash :test #'string=)))
      (unless version (error "unknown reflex version ~A/~A" name hash))
      (ensure-current-version version "canary routing")
      (unless (eq :staged (ourro.reflex.model:version-status version))
        (error "only a staged reflex can enter canary"))
      (unless (equal approved-authority
                     (ourro.reflex.model:reflex-capabilities
                      (ourro.reflex.model:version-definition version)))
        (error "canary authority does not match the reviewed version"))
      (setf (gethash key *active-version-pointers*) hash
            (ourro.reflex.model:version-status version) :canary
            (gethash key *canary-routes*)
            (list :candidate hash :fallback fallback
                  :percent (or (pget (ourro.reflex.model:reflex-policy
                                      (ourro.reflex.model:version-definition version))
                                     :canary-percent)
                               10)
                  :maximum (or (pget (ourro.reflex.model:reflex-policy
                                      (ourro.reflex.model:version-definition version))
                                     :canary-max-firings)
                               20)
                  :firings 0))
      version)))

(defun promote-reflex-version (name hash &key approved-authority)
  "Promote the currently routed canary; policy evidence is checked by caller."
  (bt:with-lock-held (*version-lock*)
    (let* ((key (string-downcase (string name)))
           (version (find hash (gethash key *version-registry*)
                          :key #'ourro.reflex.model:version-hash :test #'string=)))
      (unless (and version
                   (eq :canary (ourro.reflex.model:version-status version))
                   (equal hash (gethash key *active-version-pointers*)))
        (error "only the routed canary can be promoted"))
      (ensure-current-version version "promotion")
      (unless (equal approved-authority
                     (ourro.reflex.model:reflex-capabilities
                      (ourro.reflex.model:version-definition version)))
        (error "promotion authority does not match the reviewed version"))
      (setf (ourro.reflex.model:version-status version) :active)
      (remhash key *canary-routes*)
      version)))

(defun canary-route (name)
  (bt:with-lock-held (*version-lock*)
    (copy-list (gethash (string-downcase (string name)) *canary-routes*))))

(defun event-canary-bucket (event)
  (parse-integer (subseq (ourro.txn:canonical-hash event) 0 8) :radix 16))

(defun select-routed-reflex-versions (event)
  "Choose old or canary closures deterministically, under one routing lock."
  (bt:with-lock-held (*version-lock*)
    (let ((selected '()) (bucket (mod (event-canary-bucket event) 100)))
      (maphash
       (lambda (name active-hash)
         (let* ((route (gethash name *canary-routes*))
                (candidate-p
                  (and route
                       (< (or (pget route :firings) 0)
                          (or (pget route :maximum) 0))
                       (< bucket (or (pget route :percent) 0))))
                (hash (if candidate-p
                          (pget route :candidate)
                          (or (and route (pget route :fallback)) active-hash)))
                (version (find hash (gethash name *version-registry*)
                               :key #'ourro.reflex.model:version-hash
                               :test #'string=)))
           (when version
             (ensure-current-version version "runtime routing")
             (push version selected))))
       *active-version-pointers*)
      (nreverse selected))))

(defun record-canary-firing (version)
  "Charge one canary budget unit after VERSION actually matches and fires."
  (bt:with-lock-held (*version-lock*)
    (let* ((name (ourro.reflex.model:reflex-name
                  (ourro.reflex.model:version-definition version)))
           (route (gethash (string-downcase (string name)) *canary-routes*)))
      (when (and route
                 (string= (pget route :candidate)
                          (ourro.reflex.model:version-hash version))
                 (< (or (pget route :firings) 0)
                    (or (pget route :maximum) 0)))
        (incf (getf route :firings))
        t))))

(defun active-reflex-version (name)
  (let* ((name (string-downcase (string name)))
         (hash (bt:with-lock-held (*version-lock*)
                 (gethash name *active-version-pointers*))))
    (let ((version (and hash (find-reflex-version name hash))))
      (and version (version-current-p version) version))))

(defun active-reflex-versions ()
  (let ((pairs '()))
    (bt:with-lock-held (*version-lock*)
      (maphash (lambda (name hash) (push (cons name hash) pairs))
               *active-version-pointers*))
    (remove nil (mapcar (lambda (pair)
                          (find-reflex-version (car pair) (cdr pair)))
                        pairs))))

(defun quarantine-reflex-version (name hash &key approved-authority)
  (let ((version
          (bt:with-lock-held (*version-lock*)
            (let* ((key (string-downcase (string name)))
                   (version (find hash (gethash key *version-registry*)
                                  :key #'ourro.reflex.model:version-hash
                                  :test #'string=)))
              (unless version (error "unknown reflex version"))
              (ensure-current-version version "quarantine")
              (unless (equal approved-authority
                             (ourro.reflex.model:reflex-capabilities
                              (ourro.reflex.model:version-definition version)))
                (error "quarantine authority does not match the exact version"))
              ;; Close new routing before asking the runtime to drain/cancel.
              (setf (ourro.reflex.model:version-status version) :quarantined)
              (when (equal hash (gethash key *active-version-pointers*))
                (remhash key *active-version-pointers*))
              (let ((route (gethash key *canary-routes*)))
                (when (and route
                           (or (equal hash (pget route :candidate))
                               (equal hash (pget route :fallback))))
                  (remhash key *canary-routes*)))
              version))))
    (when *version-quarantine-hook*
      (funcall *version-quarantine-hook* (string-downcase (string name)) hash))
    version))

(defun rollback-reflex-version (name target-hash)
  "Quarantine/drain the routed version, then atomically route to TARGET-HASH."
  (let* ((key (string-downcase (string name)))
         (current (bt:with-lock-held (*version-lock*)
                    (gethash key *active-version-pointers*)))
         (target (find-reflex-version key target-hash)))
    (unless target (error "rollback target does not exist"))
    (ensure-current-version target "rollback")
    (when (eq :quarantined (ourro.reflex.model:version-status target))
      (error "rollback target is quarantined"))
    (when (and current (not (equal current target-hash)))
      (let ((current-version (find-reflex-version key current)))
        (quarantine-reflex-version
         key current
         :approved-authority
         (ourro.reflex.model:reflex-capabilities
          (ourro.reflex.model:version-definition current-version)))))
    ;; The runtime barrier runs outside the registry lock: it may inspect the
    ;; immutable versions while projecting state back to the target schema.
    (when (and current (not (equal current target-hash))
               *version-rollback-hook*)
      (funcall *version-rollback-hook* key current target-hash))
    (bt:with-lock-held (*version-lock*)
      (setf (gethash key *active-version-pointers*) target-hash
            (ourro.reflex.model:version-status target) :active)
      (remhash key *canary-routes*)
      target)))

(defun definition-owned-by-workspace-p (definition workspace)
  (let ((declared (ourro.reflex.model:reflex-workspace definition)))
    (and (not (eq declared :current))
         (string= workspace
                  (ourro.reflex.journal:normalize-workspace declared)))))

(defun workspace-version-residue (workspace)
  "Count compiled definitions explicitly owned by WORKSPACE. :CURRENT versions
are reusable code and contain no workspace payload; their instances are purged
by the runtime deletion hook."
  (let ((workspace (ourro.reflex.journal:normalize-workspace workspace))
        (versions 0) (definitions 0))
    (bt:with-lock-held (*version-lock*)
      (maphash
       (lambda (name entries)
         (declare (ignore name))
         (incf versions
               (count-if
                (lambda (version)
                  (definition-owned-by-workspace-p
                   (ourro.reflex.model:version-definition version) workspace))
                entries)))
       *version-registry*)
      (maphash
       (lambda (name definition)
         (declare (ignore name))
         (when (definition-owned-by-workspace-p definition workspace)
           (incf definitions)))
       ourro.reflex.model:*reflex-definitions*))
    (list :versions versions :definitions definitions
          :residue (or (plusp versions) (plusp definitions)))))

(defun purge-workspace-reflex-versions (workspace)
  "Revoke and remove compiled artifacts explicitly scoped to WORKSPACE."
  (let ((workspace (ourro.reflex.journal:normalize-workspace workspace))
        (removed-hashes '()) (removed-names '()))
    (bt:with-lock-held (*version-lock*)
      (let ((updates '()))
        (maphash
         (lambda (name entries)
           (let ((kept
                   (remove-if
                    (lambda (version)
                      (when (definition-owned-by-workspace-p
                             (ourro.reflex.model:version-definition version)
                             workspace)
                        (push (ourro.reflex.model:version-hash version)
                              removed-hashes)
                        t))
                    entries)))
             (push (cons name kept) updates)))
         *version-registry*)
        (dolist (update updates)
          (if (cdr update)
              (setf (gethash (car update) *version-registry*) (cdr update))
              (remhash (car update) *version-registry*))))
      (maphash
       (lambda (name definition)
         (when (definition-owned-by-workspace-p definition workspace)
           (push name removed-names)))
       ourro.reflex.model:*reflex-definitions*)
      (dolist (name removed-names)
        (remhash name ourro.reflex.model:*reflex-definitions*))
      (let ((active-removals '()) (route-removals '()))
        (maphash
         (lambda (name hash)
           (when (member hash removed-hashes :test #'equal)
             (push name active-removals)))
         *active-version-pointers*)
        (maphash
         (lambda (name route)
           (when (or (member (pget route :candidate) removed-hashes :test #'equal)
                     (member (pget route :fallback) removed-hashes :test #'equal))
             (push name route-removals)))
         *canary-routes*)
        (dolist (name active-removals) (remhash name *active-version-pointers*))
        (dolist (name route-removals) (remhash name *canary-routes*))))
    (list :versions (length removed-hashes)
          :definitions (length removed-names))))

(ourro.reflex.journal:register-workspace-deletion-hook
 :reflex-compiler #'purge-workspace-reflex-versions)

;; Genome loading reconstructs immutable compiled versions. Verification staging
;; dynamically binds this hook to NIL, so unaccepted candidates cannot publish.
(setf ourro.reflex.model:*definition-registered-hook*
      (lambda (definition)
        (install-reflex-version (compile-reflex definition))))
