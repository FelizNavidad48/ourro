(in-package #:ourro.tests)

(def-suite journal-suite :in ourro)
(in-suite journal-suite)

(defmacro with-scratch-journal (() &body body)
  `(let* ((root (uiop:ensure-directory-pathname
                 (merge-pathnames (format nil "ourro-journal-test-~A/" (make-id "tmp"))
                                  (uiop:temporary-directory))))
          (ourro.util::*ourro-home* root)
            (ourro.reflex.journal::*journal-path-override*
              (merge-pathnames "causal.wal" root))
            (ourro.reflex.journal::*journal-enabled* nil)
            (ourro.reflex.journal::*journal-records* '())
            (ourro.reflex.journal::*journal-health* (list :status :closed)))
       (ensure-directories-exist (merge-pathnames "sentinel" root))
       (ourro.reflex.journal:open-journal)
       (unwind-protect (progn ,@body)
         (ourro.reflex.journal:close-journal)
         (ignore-errors (uiop:delete-directory-tree root :validate (constantly t))))))

(test journal-adds-stable-causal-identities-and-replays
  (with-scratch-journal ()
    (let* ((parent (ourro.reflex.journal:append-record
                    (list :kind :job-exit :unix 10) :workspace "/repo/a/"))
           (parent-id (getf parent :event-id))
           (child (ourro.reflex.journal:append-record
                   (list :kind :briefing :unix 11 :causation-id parent-id)
                   :workspace "/repo/a/")))
      (is (stringp parent-id))
      (is (stringp (getf parent :trace-id)))
      (is (equal parent-id (getf child :causation-id)))
      (ourro.reflex.journal:close-journal)
      (ourro.reflex.journal:open-journal)
      (let ((neighbors (ourro.reflex.journal:causal-neighbors
                        parent-id "/repo/a/")))
        (is (= 1 (length (getf neighbors :children))))))))

(test journal-and-events-share-one-redaction-policy
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash :auth-token table) "bearer-value"
          (gethash :secret-hash table) "credential-digest"
          (gethash :proof-hash table) "public-proof")
    (let* ((sanitized (ourro.reflex.journal:sanitize-record
                       (list :auth-token "bearer-value"
                             :secret-hash "credential-digest"
                             :proof-hash "public-proof"
                             :table table)))
           (sanitized-table (pget sanitized :table)))
      (is (equal sanitized (ourro.observe::sanitize
                            (list :auth-token "bearer-value"
                                  :secret-hash "credential-digest"
                                  :proof-hash "public-proof"
                                  :table table))))
      (is (string= "«redacted»" (pget sanitized :auth-token)))
      (is (string= "«redacted»" (pget sanitized :secret-hash)))
      (is (string= "public-proof" (pget sanitized :proof-hash)))
      (is (string= "«redacted»"
                   (second (assoc :auth-token sanitized-table))))
      (is (string= "«redacted»"
                   (second (assoc :secret-hash sanitized-table)))))))

(test journal-record-identities-do-not-alias-entity-identities
  (with-scratch-journal ()
    (let* ((started (ourro.reflex.journal:append-record
                     (list :kind :reflex-instance-started
                           :instance-id "instance-1"
                           :intent-id "intent-1")
                     :workspace "/repo/a/"))
           (completed (ourro.reflex.journal:append-record
                       (list :kind :reflex-instance-completed
                             :instance-id "instance-1"
                             :intent-id "intent-1"
                             :causation-id (pget started :event-id))
                       :workspace "/repo/a/")))
      (is (not (string= (pget started :event-id) "instance-1")))
      (is (not (string= (pget started :event-id) "intent-1")))
      (is (not (string= (pget started :event-id)
                        (pget completed :event-id))))
      (is (eq started
              (ourro.reflex.journal:find-record
               (pget started :event-id) "/repo/a/")))
      (is (eq completed
              (ourro.reflex.journal:find-record
               (pget completed :event-id) "/repo/a/"))))))

(test journal-enforces-workspace-query-partitions
  (with-scratch-journal ()
    (ourro.reflex.journal:append-record (list :kind :tool-call :tool "same")
                                         :workspace "/repo/a/")
    (ourro.reflex.journal:append-record (list :kind :tool-call :tool "same")
                                         :workspace "/repo/b/")
    (is (= 1 (length (ourro.reflex.journal:query-records
                      :workspace "/repo/a/"))))
    (is (= 1 (length (ourro.reflex.journal:query-records
                      :workspace "/repo/b/"))))
    (signals error (ourro.reflex.journal:query-records))))

(test journal-export-import-and-verifiable-delete
  (with-scratch-journal ()
    (let ((export (merge-pathnames "workspace.export" ourro.util::*ourro-home*)))
      (ourro.reflex.journal:append-record (list :kind :one :unix 10)
                                           :workspace "/repo/a/")
      (ourro.reflex.journal:append-record (list :kind :two :unix 11)
                                           :workspace "/repo/b/")
      (let ((bundle (ourro.reflex.journal:export-workspace "/repo/a/" export)))
        (is (= 1 (length (getf bundle :records)))))
      (ourro.reflex.journal:delete-workspace "/repo/a/")
      (is (null (ourro.reflex.journal:query-records :workspace "/repo/a/")))
      (is (= 1 (length (ourro.reflex.journal:query-records
                        :workspace "/repo/b/"))))
      (is (= 1 (ourro.reflex.journal:import-workspace
                export :expected-workspace "/repo/a/"))))))

(test deletion-tombstone-survives-compaction-reopen-and-requires-reconsent
  (with-scratch-journal ()
    (ourro.reflex.journal:append-record (list :kind :private)
                                       :workspace "/repo/a/")
    (ourro.reflex.journal:delete-workspace "/repo/a/")
    (ourro.reflex.journal:compact-journal
     :now (+ (unix-time) (* 400 24 60 60)) :retention-seconds 1)
    (ourro.reflex.journal:close-journal)
    (ourro.reflex.journal:open-journal)
    (signals error
      (ourro.reflex.journal:append-record (list :kind :late)
                                         :workspace "/repo/a/"))
    ;; Local-control records are the only non-import writes admitted while a
    ;; tombstone is closed. The policy record reopens observation explicitly.
    (ourro.reflex.pilot:set-observation-source
     "/repo/a/" :jobs t :retention-days 30)
    (ourro.reflex.pilot:set-local-control-policy
     "/repo/a/" :provider :none :retention-days 30
     :crash-reporting nil :guided-experience t)
    (is-true (ourro.reflex.journal:append-record
              (list :kind :after-reconsent) :workspace "/repo/a/"))))

(test legacy-event-migration-is-idempotent-with-backup
  (with-scratch-journal ()
    (let ((legacy (merge-pathnames "events.sexp" ourro.util::*ourro-home*)))
      (ourro.util:append-sexp-line legacy
                                  (list :schema 1 :kind :legacy :workspace "/repo/a/"))
      (is (eq :migrated
              (ourro.reflex.journal:migrate-legacy-event-file
               legacy :workspace "/repo/a/")))
      (is (eq :already-migrated
              (ourro.reflex.journal:migrate-legacy-event-file
               legacy :workspace "/repo/a/")))
      (is (= 1 (length (ourro.reflex.journal:query-records
                        :workspace "/repo/a/")))))))

(test snapshot-authenticates-prefix-and-hydrates-only-wal-tail
  (with-scratch-journal ()
    (dotimes (index 100)
      (ourro.reflex.journal:append-record
       (list :kind :fixture :ordinal index :unix index)
       :workspace "/repo/a/"))
    (ourro.reflex.journal:write-journal-snapshot)
    (dotimes (index 3)
      (ourro.reflex.journal:append-record
       (list :kind :tail :ordinal index :unix (+ 100 index))
       :workspace "/repo/a/"))
    (ourro.reflex.journal:close-journal)
    (let ((health (ourro.reflex.journal:open-journal)))
      (is (eq :snapshot-tail (pget health :hydration)))
      (is (eq :valid (pget health :snapshot)))
      (is (= 3 (pget health :tail-record-count)))
      (is (= 103 (length (ourro.reflex.journal:query-records
                          :workspace "/repo/a/")))))))

(test journal-writes-canonical-workspace-identity-before-indexing
  (with-scratch-journal ()
    (let* ((workspace (merge-pathnames "workspace/" ourro.util::*ourro-home*))
           (nested (merge-pathnames "nested/" workspace)))
      (ensure-directories-exist (merge-pathnames "sentinel" nested))
      (let* ((alias (merge-pathnames "../" nested))
             (record (ourro.reflex.journal:append-record
                      (list :kind :aliased :workspace (namestring alias)))))
        (is (string= (ourro.reflex.journal:normalize-workspace workspace)
                     (pget record :workspace)))
        (is (= 1 (length (ourro.reflex.journal:query-records
                          :workspace workspace :kind :aliased))))))))
