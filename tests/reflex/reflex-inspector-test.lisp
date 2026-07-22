(in-package #:ourro.tests)

(def-suite reflex-inspector-suite :in ourro)
(in-suite reflex-inspector-suite)

(test causal-inspector-links-artifacts-and-complete-evidence-chain
  (with-scratch-reflex-runtime ()
    (let* ((version (install-active-fixture-version))
           (trigger (fixture-runtime-event))
           (briefing
             (ourro.reflex.journal:append-record
              (list :kind :job-failure-briefing
                    :causation-id (pget trigger :event-id)
                    :evidence-ids (list (pget trigger :event-id))
                    :reflex-version (ourro.reflex.model:version-hash version))
              :workspace "/repo/a/"))
           (graph (ourro.reflex.inspector:causal-graph
                   "/repo/a/" :root-id (pget briefing :event-id))))
      (is-true (pget graph :complete))
      (is (null (pget graph :missing-identities)))
      (is (>= (length (pget graph :nodes)) 3))
      (let ((from-parent
              (ourro.reflex.inspector:causal-graph
               "/repo/a/" :root-id (pget trigger :event-id))))
        (is-true (pget from-parent :complete))
        (is-true
         (find (pget briefing :event-id) (pget from-parent :nodes)
               :key (lambda (node) (pget node :id)) :test #'string=)))
      (let ((view (ourro.reflex.inspector:inspect-reflex-version
                   'failed-job-briefing
                   (ourro.reflex.model:version-hash version) "/repo/a/")))
        (is-true (pget view :source))
        (is-true (pget view :canonical-ir))
        (is-true (ourro.reflex.proof:reflex-proof-valid-p
                  (pget view :proof)))
        ;; Version inspection roots at the durable version entity without
        ;; filtering away the unversioned trigger evidence.
        (is-true (pget (pget view :graph) :complete))
        (is-true
         (find (pget trigger :event-id) (pget (pget view :graph) :nodes)
               :key (lambda (node) (pget node :id)) :test #'string=))))))

(test causal-inspector-fails-closed-on-missing-or-ambiguous-identities
  (with-scratch-journal ()
    (ourro.reflex.journal:append-record
     (list :kind :parent-a :span-id "shared-span") :workspace "/repo/a/")
    (ourro.reflex.journal:append-record
     (list :kind :parent-b :span-id "shared-span") :workspace "/repo/a/")
    (let* ((child (ourro.reflex.journal:append-record
                   (list :kind :child :parent-span-id "shared-span")
                   :workspace "/repo/a/"))
           (ambiguous (ourro.reflex.inspector:causal-graph
                       "/repo/a/" :root-id (pget child :event-id)))
           (missing (ourro.reflex.inspector:causal-graph
                     "/repo/a/" :root-id "event-does-not-exist")))
      (is-false (pget ambiguous :complete))
      (is (= 1 (length (pget ambiguous :ambiguous-identities))))
      (is (= 2 (length (pget (first (pget ambiguous :ambiguous-identities))
                             :candidates))))
      (is-false (pget missing :complete))
      (is (= 1 (length (pget missing :missing-identities))))
      (is (null (pget missing :nodes))))))

(test historical-replay-and-version-compare-are-pure
  (with-scratch-reflex-runtime ()
    (let* ((left (install-active-fixture-version :version-number 1))
           (right (ourro.reflex.compiler:compile-reflex
                   (ourro.reflex.model:definition-from-form
                    (fixture-reflex-form :version 2))))
           (calls 0)
           (event (fixture-runtime-event)))
      (ourro.reflex.compiler:install-reflex-version right)
      (setf (gethash :notify ourro.reflex.effects:*effect-hooks*)
            (lambda (&rest values) (declare (ignore values)) (incf calls)))
      (let ((replay (ourro.reflex.inspector:replay-reflex-version left event))
            (repeated (ourro.reflex.inspector:replay-reflex-version left event))
            (comparison
              (ourro.reflex.inspector:compare-reflex-versions left right event)))
        (is-true (pget replay :matched))
        (is-true (pget replay :virtual-effects))
        (is-true (ourro.txn:canonical-equal (pget replay :trace)
                                           (pget repeated :trace)))
        (is-false (pget comparison :live-effects-invoked))
        (is (= 0 calls))))))

(test reflex-export-import-preserves-proof-history-and-inactive-safety
  (with-scratch-reflex-runtime ()
    (let* ((clean-root
             (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "ourro-reflex-import-~A/" (make-id "tmp"))
                               (uiop:temporary-directory))))
           (transfer-root
             (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "ourro-reflex-transfer-~A/" (make-id "tmp"))
                               (uiop:temporary-directory))))
           (export (merge-pathnames "reflex.bundle" transfer-root)))
      (ensure-directories-exist (merge-pathnames "sentinel" clean-root))
      (ensure-directories-exist export)
      (unwind-protect
           (let* ((version (ourro.reflex.compiler:compile-reflex
                            (ourro.reflex.model:definition-from-form
                             (fixture-reflex-form))))
                  (hash (ourro.reflex.model:version-hash version)))
             (ourro.reflex.compiler:install-reflex-version version)
             (ourro.reflex.learn:stage-reflex-review version "/repo/a/")
             (ourro.reflex.learn:approve-reflex-canary
              version "/repo/a/" '(:observe))
             (let* ((bundle (ourro.reflex.inspector:export-reflex-workspace
                             "/repo/a/" export))
                    (exported-history (copy-tree (pget bundle :records))))
               ;; Close the source home and rebind every durable journal path
               ;; to an otherwise empty OURRO_HOME before importing.
               (ourro.reflex.journal:close-journal)
               (let* ((ourro.util::*ourro-home* clean-root)
                      (ourro.reflex.journal::*journal-path-override*
                        (merge-pathnames "state/causal.wal" clean-root))
                      (ourro.reflex.journal::*journal-enabled* nil)
                      (ourro.reflex.journal::*journal-records* '())
                      (ourro.reflex.journal::*journal-health* (list :status :closed)))
                 (ensure-directories-exist
                  ourro.reflex.journal::*journal-path-override*)
                 (ourro.reflex.journal:open-journal)
                 (unwind-protect
                      (progn
                        (is (= 0 (length (ourro.reflex.journal:journal-records))))
                        (setf ourro.reflex.compiler:*version-registry*
                              (make-hash-table :test #'equal)
                              ourro.reflex.compiler:*active-version-pointers*
                              (make-hash-table :test #'equal)
                              ourro.reflex.compiler:*canary-routes*
                              (make-hash-table :test #'equal))
                        (let* ((summary
                                 (ourro.reflex.inspector:import-reflex-workspace
                                  export :expected-workspace "/repo/a/"))
                               (imported
                                 (ourro.reflex.compiler:find-reflex-version
                                  'failed-job-briefing hash))
                               (records
                                 (reverse
                                  (ourro.reflex.journal:query-records
                                   :workspace "/repo/a/")))
                               (history
                                 (remove :imported-inactive records
                                         :key (lambda (record)
                                                (pget record :kind))))
                               (graph
                                 (and imported
                                      (pget
                                       (ourro.reflex.inspector:inspect-reflex-version
                                        'failed-job-briefing hash "/repo/a/")
                                       :graph))))
                          (is (eq :inactive (pget summary :safety-state)))
                          (is (= 0 (pget summary :active-versions)))
                          (is (= (length exported-history)
                                 (pget summary :records)))
                          (is-true imported)
                          (is-true (ourro.reflex.proof:reflex-proof-valid-p
                                    (ourro.reflex.model:version-proof imported)))
                          (is-true (ourro.txn:canonical-equal exported-history
                                                             history))
                          (is-true (find :approved history
                                         :key (lambda (record)
                                                (pget record :kind))))
                          (is-true (pget graph :complete))
                          (is-false (ourro.reflex.compiler:active-reflex-version
                                     'failed-job-briefing))
                          (is (= 0 (ourro.reflex.learn:recover-reflex-lifecycle
                                    "/repo/a/")))))
                   (ourro.reflex.journal:close-journal)))))
        (ignore-errors (uiop:delete-directory-tree clean-root
                                                    :validate (constantly t)))
        (ignore-errors (uiop:delete-directory-tree transfer-root
                                                    :validate (constantly t)))))))

(test deletion-verifier-checks-every-durable-and-future-model-store
  (with-scratch-reflex-runtime ()
    (let* ((workspace-a (ourro.reflex.journal:normalize-workspace "/repo/a/"))
           (workspace-b (ourro.reflex.journal:normalize-workspace "/repo/b/"))
           (session-a (merge-pathnames "sessions/a/events.sexp"
                                       ourro.util::*ourro-home*))
           (session-b (merge-pathnames "sessions/b/events.sexp"
                                       ourro.util::*ourro-home*))
           (ourro.observe::*recent-events*
             (list (list :kind :private :workspace workspace-a)
                   (list :kind :public :workspace workspace-b)))
           (ourro.observe:*evolution-queue*
             (list (list :id "a" :workspace workspace-a)
                   (list :id "b" :workspace workspace-b))))
      (ourro.util:append-sexp-line
       session-a (list :kind :private :workspace workspace-a))
      (ourro.util:append-sexp-line
       session-a (list :kind :public :workspace workspace-b))
      (ourro.util:append-sexp-line
       session-b (list :kind :private :workspace workspace-a))
      (ourro.util:append-sexp-line
       (ourro.evolve:candidate-records-path)
       (list :id "candidate-a" :pattern (list :workspace workspace-a)))
      (ourro.util:append-sexp-line
       (ourro.evolve:candidate-records-path)
       (list :id "candidate-b" :pattern (list :workspace workspace-b)))
      (ourro.observe:remember-workspace workspace-a)
      (ourro.observe:remember-workspace workspace-b)
      (let ((version (install-active-fixture-version)))
        (declare (ignore version))
        (ourro.reflex.runtime:submit-command
         (list :type :arm :workspace workspace-a))
        (let ((event (fixture-runtime-event)))
          (ourro.reflex.runtime:submit-command
           (list :type :external-event :event event))))
      (is (= 1 (length (ourro.reflex.runtime:list-runtime-instances
                        :workspace workspace-a))))
      (ourro.reflex.journal:append-record
       (list :kind :private :payload "workspace payload")
       :workspace workspace-a)
      (ourro.reflex.journal:append-record
       (list :kind :public :payload "other workspace")
       :workspace workspace-b)
      (ourro.reflex.journal:write-journal-snapshot)
      (ourro.reflex.journal:delete-workspace workspace-a)
      (let ((verification
              (ourro.reflex.inspector:verify-workspace-deleted workspace-a)))
        (is-true (pget verification :deleted))
        (is (= 0 (pget verification :indexed-records)))
        (is-false (pget verification :wal-residue))
        (is-false (pget verification :snapshot-residue))
        (is-false (pget (pget verification :observation-residue) :residue))
        (is-false (pget (pget verification :candidate-context-residue) :residue))
        (is (= 0 (pget verification :runtime-instance-residue))))
      (is (= 1 (length (ourro.reflex.journal:query-records
                        :workspace workspace-b))))
      (is (= 1 (length (ourro.observe:read-events session-a))))
      (is (string= workspace-b
                   (pget (first (ourro.observe:read-events session-a))
                         :workspace)))
      (is (= 1 (length ourro.observe:*evolution-queue*)))
      (is (string= workspace-b
                   (pget (first ourro.observe:*evolution-queue*) :workspace)))
      (is (= 1 (length (ourro.evolve:load-candidate-records :limit 10))))
      (is-true (ourro.observe:workspace-known-p workspace-b))
      (is-false (ourro.observe:workspace-known-p workspace-a))
      ;; The tombstone blocks both trusted direct writes and observed/model
      ;; context until a fresh local-control consent record is supplied.
      (signals error
        (ourro.reflex.journal:append-record
         (list :kind :late-write) :workspace workspace-a))
      (let ((ourro.observe:*workspace-context-fn* (lambda () workspace-a))
            (ourro.observe::*event-log-path* session-b))
        (let ((event (ourro.observe:log-event :feedback :text "late payload")))
          (is-false (pget event :observation-enabled))
          (is (= 0 (length (ourro.reflex.journal:query-records
                            :workspace workspace-a)))))))))
