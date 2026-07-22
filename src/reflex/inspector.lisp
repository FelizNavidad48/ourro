
(defpackage #:ourro.reflex.inspector
  (:use #:cl #:ourro.util)
  (:export #:causal-graph
           #:inspect-reflex-version
           #:replay-reflex-version
           #:compare-reflex-versions
           #:export-reflex-workspace
           #:import-reflex-workspace
           #:verify-workspace-deleted))

(in-package #:ourro.reflex.inspector)

(defparameter +direct-reference-fields+
  '((:causation-id . :record)
    (:parent-span-id . :span)
    (:trigger-event-id . :event)
    (:shadow-plan-id . :event)
    (:responsible-firing-id . :event)
    (:effect-record-id . :event)
    (:start-event-id . :event)
    (:evidence-id . :event))
  "Singular fields which must resolve to exactly one durable journal record.")

(defparameter +direct-reference-list-fields+
  '((:trigger-event-ids . :event)
    (:evidence-ids . :event)
    (:related-failure-ids . :event)
    (:tool-call-ids . :event))
  "List-valued fields which must resolve to durable journal records.")

(defparameter +entity-reference-fields+
  '((:trace-id . :trace)
    (:span-id . :span)
    (:instance-id . :instance)
    (:intent-id . :intent)
    (:transaction-id . :transaction)
    (:reflex-version . :reflex-version)
    (:version-hash . :reflex-version)
    (:parent-version . :reflex-version)
    (:rollback-target . :reflex-version)
    (:rollback-from . :reflex-version)
    (:proof-hash . :proof)
    (:base-proof-hash . :proof)
    (:generation . :generation)
    (:job . :job)
    (:turn-id . :turn)
    (:condition-id . :condition)
    (:recovery-choice-id . :recovery-choice)
    (:correction-id . :correction)
    (:outcome-id . :outcome)
    (:episode-id . :episode)
    (:firing-id . :firing)
    (:step-id . :step)
    (:effect-id . :effect)
    (:timer-id . :timer)
    (:workflow-id . :workflow)
    (:logical-compiled-entry-id . :compiled-entry))
  "Fields naming durable entities. Aliases share a canonical entity kind so,
for example, :ROLLBACK-TARGET reaches records carrying :REFLEX-VERSION.")

(defun record-node-id (record)
  (pget record :event-id))

(defun entity-node-id (field value)
  (format nil "entity/~(~A~)/~A" field value))

(defun graph-component (roots nodes edges)
  (let ((seen (make-hash-table :test #'equal))
        (adjacency (make-hash-table :test #'equal))
        (frontier (copy-list roots)))
    (dolist (edge edges)
      (let ((from (pget edge :from)) (to (pget edge :to)))
        (push to (gethash from adjacency))
        (push from (gethash to adjacency))))
    (loop while frontier do
      (let ((id (pop frontier)))
        (unless (gethash id seen)
          (setf (gethash id seen) t)
          (dolist (neighbor (gethash id adjacency))
            (unless (gethash neighbor seen) (push neighbor frontier))))))
    (values (remove-if-not (lambda (node) (gethash (pget node :id) seen)) nodes)
            (remove-if-not (lambda (edge)
                             (and (gethash (pget edge :from) seen)
                                  (gethash (pget edge :to) seen)))
                           edges))))

(defun causal-graph (workspace &key root-id reflex-version)
  "Build a navigable graph with explicit nodes for records and durable entities.
Every direct causal identity resolves to exactly one record. REFLEX-VERSION is
an entity root, not a destructive record filter, so its trigger evidence and
other unversioned causal ancestors remain reachable."
  (let* ((records (reverse (ourro.reflex.journal:query-records
                            :workspace workspace)))
         (event-locations (make-hash-table :test #'equal))
         (span-locations (make-hash-table :test #'equal))
         (node-index (make-hash-table :test #'equal))
         (entities (make-hash-table :test #'equal))
         (nodes '()) (edges '()) (missing '()) (ambiguities '()))
    (labels ((index-location (table identity node-id)
               (when identity
                 (pushnew node-id (gethash identity table) :test #'equal)))
             (ensure-entity (kind value &key unresolved)
               (let* ((kind (if unresolved
                                (intern (format nil "UNRESOLVED-~A" kind)
                                        :keyword)
                                kind))
                      (id (entity-node-id kind value)))
                 (unless (gethash id entities)
                   (setf (gethash id entities) t)
                   (let ((node (list :id id :node-kind :entity
                                     :entity-kind kind :value value
                                     :unresolved (and unresolved t))))
                     (setf (gethash id node-index) node)
                     (push node nodes)))
                 id))
             (reference-candidates (mode value)
               (remove-duplicates
                (case mode
                  (:event (copy-list (gethash value event-locations)))
                  (:span (copy-list (gethash value span-locations)))
                  (:record (append (copy-list (gethash value event-locations))
                                   (copy-list (gethash value span-locations))))
                  (t (error "unknown causal identity mode ~S" mode)))
                :test #'equal))
             (add-direct-reference (record field mode value)
               (when value
                 (let* ((child (record-node-id record))
                        (candidates (reference-candidates mode value)))
                   (cond
                     ((null candidates)
                      (let ((unresolved (ensure-entity field value
                                                       :unresolved t)))
                        (push (list :from unresolved :to child :relation field
                                    :resolution :missing)
                              edges)
                        (push (list :record child :field field :identity value)
                              missing)))
                     ((null (rest candidates))
                      (push (list :from (first candidates) :to child
                                  :relation field :resolution :unique)
                            edges))
                     (t
                      (dolist (candidate candidates)
                        (push (list :from candidate :to child :relation field
                                    :resolution :ambiguous)
                              edges))
                      (push (list :record child :field field :identity value
                                  :candidates (sort (copy-list candidates)
                                                    #'string<))
                            ambiguities)))))))
      ;; Index all record and span identities before resolving any reference;
      ;; causal parents may commit after a child which reserved their identity.
      (dolist (record records)
        (let* ((id (record-node-id record))
               (node (list :id id :node-kind :record
                           :record-kind (pget record :record-kind)
                           :kind (pget record :kind) :record record)))
          (index-location event-locations id id)
          (index-location span-locations (pget record :span-id) id)
          (setf (gethash id node-index) node)
          (push node nodes)))
      (dolist (record records)
        (dolist (entry +direct-reference-fields+)
          (add-direct-reference record (car entry) (cdr entry)
                                (pget record (car entry))))
        (dolist (entry +direct-reference-list-fields+)
          (let ((values (pget record (car entry))))
            (when values
              (unless (listp values)
                (error "causal reference field ~S must be a list" (car entry)))
              (dolist (value values)
                (add-direct-reference record (car entry) (cdr entry) value)))))
        (dolist (entry +entity-reference-fields+)
          (let ((value (pget record (car entry))))
            (when value
              (let ((entity (ensure-entity (cdr entry) value)))
                (push (list :from entity :to (record-node-id record)
                            :relation (car entry) :resolution :entity)
                      edges))))))
      (setf nodes (nreverse nodes)
            edges (nreverse edges)
            missing (nreverse missing)
            ambiguities (nreverse ambiguities))
      (let* ((requested-root
               (or root-id
                   (and reflex-version
                        (entity-node-id :reflex-version reflex-version))))
             (root-candidates
               (when requested-root
                 (or (and (gethash requested-root node-index)
                          (list requested-root))
                     (remove-duplicates
                      (append (copy-list (gethash requested-root event-locations))
                              (copy-list (gethash requested-root span-locations))
                              (loop for node in nodes
                                    when (and (eq :entity (pget node :node-kind))
                                              (equal requested-root
                                                     (pget node :value)))
                                      collect (pget node :id)))
                      :test #'equal))))
             (root-missing (and requested-root (null root-candidates)))
             (root-ambiguous (and requested-root (rest root-candidates))))
        (when root-ambiguous
          (push (list :record :graph-root :field :root-id
                      :identity requested-root
                      :candidates (sort (copy-list root-candidates) #'string<))
                ambiguities))
        (cond
          (root-candidates
           (multiple-value-setq (nodes edges)
             (graph-component root-candidates nodes edges))
           (let ((included (make-hash-table :test #'equal)))
             (dolist (node nodes) (setf (gethash (pget node :id) included) t))
             (setf missing
                   (remove-if-not (lambda (item)
                                    (gethash (pget item :record) included))
                                  missing)
                   ambiguities
                   (remove-if-not
                    (lambda (item)
                      (or (eq :graph-root (pget item :record))
                          (gethash (pget item :record) included)))
                    ambiguities))))
          (root-missing
           (setf nodes '() edges '()
                 missing (list (list :record :graph-root :field :root-id
                                     :identity requested-root)))))
        (list :workspace (ourro.reflex.journal:normalize-workspace workspace)
              :root-id requested-root
              :resolved-root-ids (copy-list root-candidates)
              :reflex-version reflex-version
              :nodes nodes :edges edges
              :missing-identities missing
              :ambiguous-identities ambiguities
              :complete (and (null missing) (null ambiguities)
                             (or (null requested-root) root-candidates)))))))

(defun inspect-reflex-version (name hash workspace)
  (let ((version (ourro.reflex.compiler:find-reflex-version name hash)))
    (unless version (error "unknown reflex version ~A/~A" name hash))
    (let ((definition (ourro.reflex.model:version-definition version)))
      (list :logical-name (ourro.reflex.model:reflex-name definition)
            :version-hash hash
            :status (ourro.reflex.model:version-status version)
            :source (ourro.reflex.model:reflex-source-form definition)
            :canonical-ir (ourro.reflex.model:version-ir version)
            :generated-lisp (ourro.reflex.model:version-generated-lisp version)
            :proof (ourro.reflex.model:version-proof version)
            :lifecycle
            (remove-if-not
             (lambda (record) (equal hash (pget record :reflex-version)))
             (reverse (ourro.reflex.journal:query-records
                       :workspace workspace)))
            :graph (causal-graph workspace :reflex-version hash)))))

(defun replay-reflex-version (version event &key (maximum-transitions 100))
  "Replay deterministic transitions with synthetic receipts and no adapter calls."
  (let ((definition (ourro.reflex.model:version-definition version)))
    (unless (ourro.reflex.model:reflex-matches-p definition event)
      (return-from replay-reflex-version
        (list :matched nil :virtual-effects t :trace '())))
    (loop with state = (ourro.reflex.model:reflex-initial-state definition)
          with next-event = (copy-tree event)
          with results = nil
          with trace = '()
          for index below maximum-transitions
          for result = (funcall
                        (ourro.reflex.model:version-transition-function version)
                        (copy-tree state) next-event results)
          for effects = (copy-tree (pget result :effects))
          do (push (list :index index :old-state (copy-tree state)
                         :new-state (copy-tree (pget result :state))
                         :planned-effects effects
                         :terminal (and (pget result :terminal) t))
                   trace)
             (setf state (copy-tree (pget result :state))
                   next-event nil
                   results (and effects
                                (list :virtual t
                                      :receipts
                                      (loop for effect in effects
                                            collect
                                            (list :step-id (pget effect :id)
                                                  :status :virtual-succeeded)))))
          when (and (pget result :terminal) (null effects))
            return (list :matched t :virtual-effects t
                         :logical-version
                         (ourro.reflex.model:version-hash version)
                         :trace (nreverse trace) :terminal-state state)
          finally (error "reflex replay exceeded ~D transitions"
                         maximum-transitions))))

(defun compare-reflex-versions (left right event)
  (let ((left-trace (replay-reflex-version left event))
        (right-trace (replay-reflex-version right event)))
    (list :left-version (ourro.reflex.model:version-hash left)
          :right-version (ourro.reflex.model:version-hash right)
          :left left-trace :right right-trace
          :same-trace (ourro.txn:canonical-equal
                       (pget left-trace :trace) (pget right-trace :trace))
          :live-effects-invoked nil)))

(defun version-source-string (version)
  (with-standard-io-syntax
    (let ((*print-pretty* nil) (*print-circle* nil))
      (prin1-to-string
       (ourro.reflex.model:reflex-source-form
        (ourro.reflex.model:version-definition version))))))

(defun artifact-record (version)
  (let ((proof (ourro.reflex.model:version-proof version)))
    (list :logical-name
          (ourro.reflex.model:reflex-name
           (ourro.reflex.model:version-definition version))
          :version-hash (ourro.reflex.model:version-hash version)
          :source (version-source-string version)
          :canonical-ir (ourro.reflex.model:version-ir version)
          :generated-lisp (ourro.reflex.model:version-generated-lisp version)
          :proof proof
          :proof-hash (pget proof :proof-hash))))

(defun workspace-versions (workspace records)
  (let ((wanted (remove-duplicates
                 (remove nil (mapcar (lambda (record)
                                       (pget record :reflex-version))
                                     records))
                 :test #'equal))
        (versions '())
        (workspace (ourro.reflex.journal:normalize-workspace workspace)))
    (maphash
     (lambda (name entries)
       (declare (ignore name))
       (dolist (version entries)
         (let* ((definition (ourro.reflex.model:version-definition version))
                (declared (ourro.reflex.model:reflex-workspace definition)))
           (when (or (member (ourro.reflex.model:version-hash version)
                             wanted :test #'equal)
                     (and (not (eq declared :current))
                          (equal workspace
                                 (ourro.reflex.journal:normalize-workspace declared))))
             (pushnew version versions :test #'eq)))))
     ourro.reflex.compiler:*version-registry*)
    (nreverse versions)))

(defun export-reflex-workspace (workspace path)
  (let* ((workspace (ourro.reflex.journal:normalize-workspace workspace))
         (records (reverse (ourro.reflex.journal:query-records
                            :workspace workspace)))
         (artifacts (mapcar #'artifact-record
                            (workspace-versions workspace records)))
         (payload (list :workspace workspace :records records
                        :artifacts artifacts))
         (bundle (list :schema-version 1
                       :record-kind :reflex-workspace-export
                       :exported-at (iso-time)
                       :workspace workspace
                       :records records :artifacts artifacts
                       :manifest-hash (ourro.txn:canonical-hash payload))))
    (ourro.txn:write-canonical-file path bundle)
    bundle))

(defun source-form-from-ir (ir)
  (list (intern "DEFINE-REFLEX" :ourro.reflex.model)
        (intern (string-upcase (pget ir :name)) :keyword)
        (list :identity
              (list :version (pget ir :version)
                    :workspace (pget ir :workspace)
                    :capabilities (pget ir :capabilities)))
        (list :trigger (pget ir :trigger))
        (list :guards (pget ir :guards))
        (list :state (pget ir :state-schema))
        (list :workflow (pget ir :workflow))
        (list :policy (pget ir :policy))))

(defun import-artifact (artifact)
  (let* ((ir (pget artifact :canonical-ir))
         (source (handler-case
                     (ourro.kernel:safe-read-form
                      (pget artifact :source) :package :ourro.api)
                   (error () (source-form-from-ir ir))))
         (definition (ourro.reflex.model:definition-from-form source))
         (compiled (ourro.reflex.compiler:compile-reflex definition))
         (proof (pget artifact :proof)))
    (unless (and (string= (pget artifact :version-hash)
                          (ourro.reflex.model:version-hash compiled))
                 (ourro.txn:canonical-equal ir
                                           (ourro.reflex.model:version-ir compiled))
                 (ourro.reflex.proof:reflex-proof-valid-p proof)
                 (string= (pget artifact :proof-hash) (pget proof :proof-hash))
                 (ourro.reflex.compiler:generated-lisp-safe-p
                  (pget artifact :generated-lisp)))
      (error "reflex export artifact failed integrity verification"))
    ;; Preserve the exact exported proof while recompiling only the immutable
    ;; function object. Imported versions are always VERIFIED and unrouted.
    (ourro.reflex.compiler:install-reflex-version
     (make-instance
      'ourro.reflex.model:reflex-version
      :hash (pget artifact :version-hash)
      :definition definition :ir ir
      :generated-lisp (pget artifact :generated-lisp)
      :transition-function (compile nil (pget artifact :generated-lisp))
      :proof proof :status :verified))))

(defun import-reflex-workspace (path &key expected-workspace)
  (let* ((bundle (ourro.reflex.journal:read-canonical-file path))
         (workspace (pget bundle :workspace))
         (records (pget bundle :records))
         (artifacts (pget bundle :artifacts))
         (payload (list :workspace workspace :records records
                        :artifacts artifacts)))
    (unless (and (eq :reflex-workspace-export (pget bundle :record-kind))
                 (stringp workspace)
                 (or (null expected-workspace)
                     (string= workspace
                              (ourro.reflex.journal:normalize-workspace
                               expected-workspace)))
                 (string= (pget bundle :manifest-hash)
                          (ourro.txn:canonical-hash payload)))
      (error "invalid or unexpected reflex workspace export"))
    (let ((versions (mapcar #'import-artifact artifacts)) (imported 0))
      (ourro.reflex.journal:with-workspace-restoration (workspace)
        (dolist (record records)
          (unless (ourro.reflex.journal:find-record
                   (pget record :event-id) workspace)
            (ourro.reflex.journal:append-record record :workspace workspace)
            (incf imported)))
        (dolist (version versions)
          (ourro.reflex.journal:append-record
           (list :record-kind :reflex-lifecycle :kind :imported-inactive
                 :reflex
                 (ourro.reflex.model:reflex-name
                  (ourro.reflex.model:version-definition version))
                 :reflex-version (ourro.reflex.model:version-hash version)
                 :proof-hash
                 (pget (ourro.reflex.model:version-proof version) :proof-hash)
                 :inactive-safety-state t :time (iso-time) :unix (unix-time))
           :workspace workspace))
        (list :workspace workspace :records imported
              :artifacts (length versions) :active-versions 0
              :safety-state :inactive)))))

(defun contains-workspace-p (value workspace)
  (cond ((stringp value) (not (null (search workspace value))))
        ((consp value) (or (contains-workspace-p (car value) workspace)
                           (contains-workspace-p (cdr value) workspace)))
        ((vectorp value)
         (some (lambda (item) (contains-workspace-p item workspace)) value))
        (t nil)))

(defun candidate-context-residue (workspace)
  ;; OURRO.EVOLVE loads after this inspector module. Resolve its verifier at
  ;; call time so the dependency direction remains acyclic.
  (let* ((package (find-package :ourro.evolve))
         (symbol (and package
                      (find-symbol "CANDIDATE-WORKSPACE-RESIDUE" package))))
    (if (and symbol (fboundp symbol))
        (funcall (symbol-function symbol) workspace)
        (list :records 0 :unreadable nil :residue nil :store-loaded nil))))

(defun verify-workspace-deleted (workspace)
  "Verify durable, compatibility, memory, and future-model stores are clean."
  (let* ((workspace (ourro.reflex.journal:normalize-workspace workspace))
         (indexed (ourro.reflex.journal:query-records :workspace workspace))
         (wal-records (multiple-value-list
                       (ourro.txn:read-wal (ourro.reflex.journal:journal-path))))
         (wal-payload (first wal-records))
         (snapshot-path (ourro-path "state" "causal.snapshot"))
         (snapshot (and (probe-file snapshot-path)
                        (ourro.reflex.journal:read-canonical-file snapshot-path)))
         (observation
           (ourro.observe:workspace-observation-residue workspace))
         (candidates (candidate-context-residue workspace))
         (versions
           (ourro.reflex.compiler:workspace-version-residue workspace))
         (runtime-instances
           (ourro.reflex.runtime:list-runtime-instances :workspace workspace))
         (residue (or indexed
                      (some (lambda (record)
                              (contains-workspace-p record workspace))
                            wal-payload)
                      (and snapshot
                           (contains-workspace-p snapshot workspace))
                      (pget observation :residue)
                      (pget candidates :residue)
                      (pget versions :residue)
                      runtime-instances)))
    (list :workspace-hash (ourro.txn:sha256-string workspace)
          :deleted (not residue)
          :indexed-records (length indexed)
          :wal-residue (and (some (lambda (record)
                                    (contains-workspace-p record workspace))
                                  wal-payload)
                            t)
          :snapshot-residue (and snapshot
                                 (contains-workspace-p snapshot workspace) t)
          :observation-residue observation
          :candidate-context-residue candidates
          :version-registry-residue versions
          :runtime-instance-residue (length runtime-instances))))
