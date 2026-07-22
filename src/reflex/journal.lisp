
(defpackage #:ourro.reflex.journal
  (:use #:cl #:ourro.util)
  (:export #:journal-path
           #:open-journal
           #:close-journal
           #:journal-health
           #:journal-healthy-p
           #:ingest-event
           #:ingest-clean-event
           #:append-record
           #:append-record-batch
           #:append-clean-record
           #:journal-records
           #:query-records
           #:find-record
           #:causal-neighbors
           #:normalize-workspace
           #:sanitize-record
           #:sensitive-field-p
           #:data-preview
           #:with-causal-context
           #:with-workspace-restoration
           #:journal-thread-bindings
           #:*causal-context*
           #:*observation-policy-hook*
           #:*retention-policy-hook*
           #:*retention-policy-prepare-hook*
           #:*workspace-deletion-hook*
           #:register-workspace-deletion-hook
           #:unregister-workspace-deletion-hook
           #:register-schema-migration
           #:migrate-legacy-event-file
           #:export-workspace
           #:import-workspace
           #:delete-workspace
           #:compact-journal
           #:write-journal-snapshot
           #:read-canonical-file))

(in-package #:ourro.reflex.journal)

(defparameter +journal-schema-version+ 1)
(defparameter +default-retention-seconds+ (* 90 24 60 60))
(defvar *journal-path-override* nil)
(defvar *journal-enabled* nil)
(defvar *journal-lock* (bt:make-lock "ourro-causal-journal"))
(defvar *journal-records* '())
(defvar *journal-by-id* (make-hash-table :test #'equal))
(defvar *journal-by-workspace* (make-hash-table :test #'equal))
(defvar *journal-health* (list :status :closed))
(defvar *workspace-deletions-in-progress* (make-hash-table :test #'equal))
(defvar *deleted-workspace-hashes* (make-hash-table :test #'equal))
(defvar *workspace-restoration-authorized* '())
(defvar *schema-migrations* (make-hash-table))
(defvar *causal-context* nil
  "Dynamically propagated causal fields for records created in this extent.")
(defvar *observation-policy-hook* nil
  "Optional function of an observed event. Returns an admission policy plist.")
(defvar *retention-policy-hook* nil
  "Optional function of RECORD, all records, and the default retention seconds.")
(defvar *retention-policy-prepare-hook* nil
  "Optional function that builds one O(N) context before retention filtering.")
(defvar *retention-policy-context* nil)
(defvar *workspace-deletion-hook* '()
  "Registered compatibility/product-store purge functions called before the
journal deletion commit. Kept as one exported registry for staged-state audit.")

(defun journal-thread-bindings ()
  "Return the one reviewed set of causal journal specials safe to inherit."
  (flet ((binding (symbol value) (cons symbol (list 'quote value))))
    (append
     (list (binding 'ourro.util::*ourro-home* ourro.util::*ourro-home*)
           (binding 'ourro.reflex.journal:*causal-context* *causal-context*))
     (when *journal-path-override*
       (list (binding 'ourro.reflex.journal::*journal-path-override*
                      *journal-path-override*)
             (binding 'ourro.reflex.journal::*journal-enabled* *journal-enabled*)
             (binding 'ourro.reflex.journal::*journal-health* *journal-health*))))))

(defun register-workspace-deletion-hook (name function)
  "Register FUNCTION under NAME, replacing an older hook with that identity."
  (setf *workspace-deletion-hook*
        (acons name function
               (remove name *workspace-deletion-hook* :key #'car :test #'equal)))
  name)

(defun unregister-workspace-deletion-hook (name)
  (setf *workspace-deletion-hook*
        (remove name *workspace-deletion-hook* :key #'car :test #'equal))
  name)

(defun run-workspace-deletion-hooks (workspace)
  "Run every purge hook even if one fails, then fail the deletion call closed."
  (let ((failures '()))
    (dolist (entry (copy-list *workspace-deletion-hook*))
      (handler-case (funcall (cdr entry) workspace)
        (error (condition)
          (push (list :hook (car entry) :error (princ-to-string condition))
                failures))))
    (when failures
      (error "workspace deletion compatibility purge failed: ~S"
             (nreverse failures)))
    t))

(defmacro with-causal-context ((&rest fields) &body body)
  `(let ((*causal-context* (append (list ,@fields) *causal-context*)))
     ,@body))

(defmacro with-workspace-restoration ((workspace) &body body)
  "Authorize one verified import to recreate a previously deleted partition."
  (let ((normalized (gensym "WORKSPACE"))
        (returned-values (gensym "VALUES")))
    `(let* ((,normalized (normalize-workspace ,workspace))
            (*workspace-restoration-authorized*
              (cons ,normalized *workspace-restoration-authorized*)))
       (let ((,returned-values (multiple-value-list (progn ,@body))))
         (bt:with-lock-held (*journal-lock*)
           (remhash (ourro.txn:sha256-string ,normalized)
                    *deleted-workspace-hashes*))
         (values-list ,returned-values)))))

(defun journal-path ()
  (or *journal-path-override* (ourro-path "state" "causal.wal")))

(defun snapshot-path ()
  (ourro-path "state" "causal.snapshot"))

(defun strip-url-credentials (string)
  (let* ((scheme (search "://" string))
         (authority-start (and scheme (+ scheme 3)))
         (slash (and authority-start (position #\/ string :start authority-start)))
         (at (and authority-start
                  (position #\@ string :start authority-start
                                        :end (or slash (length string))))))
    (if at
        (concatenate 'string (subseq string 0 authority-start)
                     (subseq string (1+ at)))
        string)))

(defun normalize-workspace (workspace)
  "Return a stable, credential-free workspace identity."
  (let ((raw (etypecase workspace
               (null "workspace:unknown")
               (pathname (namestring workspace))
               (string workspace))))
    (strip-url-credentials
     (or (ignore-errors
           (namestring (truename (uiop:ensure-directory-pathname raw))))
         raw))))

(defun record-id (record)
  (or (pget record :event-id)
      (pget record :record-id)))

(defun context-value (key)
  (pget *causal-context* key))

(defparameter +non-secret-opaque-fields+
  '("idempotency-key" "proof-hash" "base-proof-hash" "source-hash"
    "input-hash" "result-hash" "manifest-hash" "wal-prefix-hash"
    "deleted-workspace-hash" "version-hash" "reflex-version"
    "dependency-closure-hash" "fingerprint"))

(defun sensitive-field-p (key)
  (let ((name (string-downcase
               (if (symbolp key) (symbol-name key) (princ-to-string key)))))
    ;; Exempt only explicitly named non-secret identities. In particular, a
    ;; suffix such as SECRET-HASH or AUTH-TOKEN is never a redaction bypass.
    (and (not (or (member name +non-secret-opaque-fields+ :test #'string=)
                  (member name '("prompt-tokens" "candidates-tokens"
                                 "total-tokens" "cache-read-tokens")
                          :test #'string=)))
         (some (lambda (needle) (search needle name))
               '("authorization" "api-key" "apikey" "password" "passwd"
                 "secret" "token" "credential"
                 "cookie")))))

(defun long-content-field-p (key)
  (member key '(:log :log-tail :bounded-log :source :prompt :final-text)
          :test #'equal))

(defun printable-plist-p (value)
  (and (listp value) (evenp (length value))
       (loop for tail on value by #'cddr
             always (or (keywordp (first tail)) (stringp (first tail))))))

(defun sanitize-record (value &optional key (depth 0))
  "Apply the journal's storage boundary policy to arbitrary producer data."
  (cond
    ((> depth 20) "«deep»")
    ((or (null value) (keywordp value) (numberp value) (characterp value)) value)
    ((stringp value)
     (let* ((clean (strip-url-credentials value))
            (lower (string-downcase clean)))
       (if (some (lambda (needle) (search needle lower))
                 '("authorization" "api-key" "apikey" "password" "passwd"
                   "secret" "credential" "cookie"))
           "«redacted»"
           (truncate-string clean
                            (if (long-content-field-p key) 64000 4000)))))
    ((symbolp value) (string-downcase (symbol-name value)))
    ((consp value)
     (if (printable-plist-p value)
         (loop for (field item) on value by #'cddr
               append (list field
                            (if (sensitive-field-p field)
                                "«redacted»"
                                (sanitize-record item field (1+ depth)))))
         (mapcar (lambda (item) (sanitize-record item key (1+ depth))) value)))
    ((hash-table-p value)
     (let ((pairs '()))
       (maphash (lambda (field item)
                  (push (list (sanitize-record field nil (1+ depth))
                              (if (sensitive-field-p field)
                                  "«redacted»"
                                  (sanitize-record item field (1+ depth))))
                        pairs))
                value)
       (nreverse pairs)))
    ((vectorp value)
     (map 'list (lambda (item) (sanitize-record item key (1+ depth))) value))
    ((pathnamep value) (namestring value))
    (t (truncate-string (princ-to-string value) 500))))

(defun data-preview (record &key model-bound-fields)
  "Return exactly what would be stored and which top-level fields may reach a model."
  (let ((sanitized (sanitize-record record)))
    (list :stored sanitized
          :fields
          (loop for (key value) on sanitized by #'cddr
                collect
                (list :field key
                      :class (cond ((sensitive-field-p key) :credential)
                                   ((member key '(:log :log-tail :bounded-log
                                                  :prompt :source :text :input)
                                            :test #'equal)
                                    :content)
                                   (t :metadata))
                      :captured t
                      :model-bound (and (member key model-bound-fields
                                                :test #'equal) t)
                      :value value)))))

(defun ensure-causal-record (record &key workspace)
  (let* ((id (or (record-id record) (make-id "event")))
         (workspace (normalize-workspace
                     (or workspace (pget record :workspace)
                         (context-value :workspace))))
         (trace (or (pget record :trace-id) (context-value :trace-id) id))
         (span (or (pget record :span-id) (context-value :span-id) id)))
    ;; Workspace identity is a storage invariant, not merely a default. Paths
    ;; such as macOS /var and /private/var can name the same checkout; retaining
    ;; a producer's spelling would split the partition index and make a durable
    ;; event unreachable from the runtime instance it caused.
    (loop with result = (plist-put (copy-list record) :workspace workspace)
          for (key value) in
            `((:schema-version ,+journal-schema-version+)
              (:record-kind ,(or (pget record :record-kind) :causal-event))
              (:event-id ,id)
              (:workspace ,workspace)
              (:trace-id ,trace)
              (:span-id ,span)
              (:parent-span-id ,(or (pget record :parent-span-id)
                                    (context-value :parent-span-id)))
              (:causation-id ,(or (pget record :causation-id)
                                  (context-value :causation-id)))
              (:correlation-id ,(or (pget record :correlation-id)
                                    (context-value :correlation-id) trace))
              (:actor ,(or (pget record :actor) (context-value :actor) :agent)))
          unless (pget result key) do (setf result (plist-put result key value))
          finally (return result))))

(defun validate-record (record)
  (unless (and (listp record)
               (integerp (pget record :schema-version))
               (stringp (record-id record))
               (stringp (pget record :workspace))
               (stringp (pget record :trace-id))
               (stringp (pget record :span-id)))
    (error "invalid causal journal record: ~S" record))
  record)

(defun clear-indexes ()
  (setf *journal-by-id* (make-hash-table :test #'equal)
        *journal-by-workspace* (make-hash-table :test #'equal)))

(defun index-record (record)
  (let ((id (record-id record))
        (workspace (pget record :workspace)))
    (setf (gethash id *journal-by-id*) record)
    (push record (gethash workspace *journal-by-workspace*))))

(defun rebuild-indexes (records)
  (clear-indexes)
  (dolist (record records) (index-record record)))

(defun rebuild-deletion-index (records)
  "Replay deletion/re-consent state in chronological journal order."
  (clrhash *workspace-deletions-in-progress*)
  (clrhash *deleted-workspace-hashes*)
  (dolist (record records)
    (cond
      ((eq :workspace-deleted (pget record :kind))
       (let ((hash (pget record :deleted-workspace-hash)))
         (when hash (setf (gethash hash *deleted-workspace-hashes*) t))))
      ((and (eq :local-control (pget record :record-kind))
            (eq :local-control-policy (pget record :kind)))
       (remhash (ourro.txn:sha256-string (pget record :workspace))
                *deleted-workspace-hashes*)))))

(defun snapshot-valid-for-wal-p (snapshot path)
  (let ((records (pget snapshot :records))
        (wal-bytes (pget snapshot :wal-bytes)))
    (and (eq :causal-snapshot (pget snapshot :record-kind))
         (listp records)
         (= (or (pget snapshot :record-count) -1) (length records))
         (stringp (pget snapshot :manifest-hash))
         (string= (pget snapshot :manifest-hash)
                  (ourro.txn:canonical-hash records))
         (integerp wal-bytes)
         (<= 0 wal-bytes)
         (stringp (pget snapshot :wal-prefix-hash))
         (string= (pget snapshot :wal-prefix-hash)
                  (ourro.txn:wal-prefix-hash path wal-bytes)))))

(defun hydrate-journal (path)
  "Return records, WAL health, hydration mode, and snapshot status."
  (let ((snapshot-status :absent))
    (when (probe-file (snapshot-path))
      (handler-case
          (let ((snapshot (read-canonical-file (snapshot-path))))
            (if (snapshot-valid-for-wal-p snapshot path)
                (multiple-value-bind (tail health valid-bytes)
                    (ourro.txn:read-wal-from-offset path
                                                   (pget snapshot :wal-bytes))
                  (declare (ignore valid-bytes))
                  (if (eq health :ok)
                      (return-from hydrate-journal
                        (values (append (copy-list (pget snapshot :records)) tail)
                                :ok :snapshot-tail :valid
                                (pget snapshot :record-count)))
                      ;; Tail repair remains centralized in RECOVER-WAL. A
                      ;; crash-torn tail is uncommon and may pay the full scan.
                      (setf snapshot-status :torn-tail-fallback)))
                (setf snapshot-status :stale)))
        (error () (setf snapshot-status :invalid))))
    (multiple-value-bind (records health) (ourro.txn:recover-wal path)
      (values records health :full-wal snapshot-status 0))))

(defun open-journal (&optional (path (journal-path)))
  "Recover PATH and hydrate indexes from an authenticated snapshot plus tail."
  (bt:with-lock-held (*journal-lock*)
    (handler-case
        (multiple-value-bind (records health hydration snapshot-status
                              snapshot-record-count)
            (hydrate-journal path)
          (mapc #'validate-record records)
          (setf *journal-records* records
                *journal-enabled* t
                *journal-health* (list :status health :path (namestring path)
                                       :hydration hydration
                                       :snapshot snapshot-status
                                       :tail-record-count
                                       (if (eq hydration :snapshot-tail)
                                           (- (length records)
                                              snapshot-record-count)
                                           (length records))))
          (rebuild-indexes records)
          (rebuild-deletion-index records)
          *journal-health*)
      (error (condition)
        (setf *journal-enabled* nil
              *journal-health* (list :status :degraded :path (namestring path)
                                     :reason (princ-to-string condition)))
        (error condition)))))

(defun close-journal ()
  (bt:with-lock-held (*journal-lock*)
    (setf *journal-enabled* nil
          *journal-health* (list :status :closed)))
  t)

(defun journal-health () (copy-list *journal-health*))

(defun journal-healthy-p ()
  (member (pget *journal-health* :status) '(:ok :torn-tail) :test #'eq))

(defun append-record-batch-internal (records workspace sanitize-p)
  (let ((records
          (mapcar (lambda (record)
                    (validate-record
                     (ensure-causal-record (if sanitize-p
                                               (sanitize-record record)
                                               record)
                                           :workspace workspace)))
                  records)))
    (bt:with-lock-held (*journal-lock*)
      (unless *journal-enabled*
        (error "causal journal is not open"))
      (unless (journal-healthy-p)
        (error "causal journal is degraded: ~S" *journal-health*))
      (let ((new-ids (make-hash-table :test #'equal)))
        (dolist (record records)
          (let* ((record-workspace (pget record :workspace))
                 (hash (ourro.txn:sha256-string record-workspace))
                 (restoration
                   (member record-workspace *workspace-restoration-authorized*
                           :test #'string=))
                 (local-control (eq :local-control (pget record :record-kind)))
                 (id (record-id record)))
            (when (or (gethash record-workspace *workspace-deletions-in-progress*)
                      (and (gethash hash *deleted-workspace-hashes*)
                           (not restoration) (not local-control)))
              (error "workspace partition is deleted or deletion is in progress"))
            (when (or (gethash id *journal-by-id*) (gethash id new-ids))
              (error "duplicate causal record identity ~A" id))
            (setf (gethash id new-ids) t))))
      (handler-case
          (progn
            (ourro.txn:append-wal-record-batch (journal-path) records)
            (setf *journal-records* (nconc *journal-records* records))
            (dolist (record records)
              (index-record record)
              (when (and (eq :local-control (pget record :record-kind))
                         (eq :local-control-policy (pget record :kind)))
                (remhash (ourro.txn:sha256-string (pget record :workspace))
                         *deleted-workspace-hashes*)))
            records)
        (error (condition)
          (setf *journal-health* (list :status :degraded
                                       :path (namestring (journal-path))
                                       :reason (princ-to-string condition)))
          (error condition))))))

(defun append-record-internal (record workspace sanitize-p)
  (first (append-record-batch-internal (list record) workspace sanitize-p)))

(defun append-record (record &key workspace)
  "Sanitize and append one validated causal record before publishing it."
  (append-record-internal record workspace t))

(defun append-record-batch (records &key workspace)
  "Sanitize, validate, and append RECORDS with one WAL durability boundary."
  (append-record-batch-internal records workspace t))

(defun append-clean-record (record &key workspace)
  "Append RECORD that already crossed SANITIZE-RECORD at a trusted boundary."
  (append-record-internal record workspace nil))

(defun ingest-event (event)
  "Add causal identities and durably append EVENT when the journal is open."
  (let* ((record (ensure-causal-record event))
         (policy (and *observation-policy-hook*
                      (funcall *observation-policy-hook* record)))
         (record (if policy
                     (append record
                             (list :observation-source (pget policy :source)
                                   :observation-enabled
                                   (and (pget policy :enabled) t)
                                   :observation-managed
                                   (and (pget policy :managed) t)))
                     record)))
    (if (and *journal-enabled*
             (or (null policy) (pget policy :enabled)))
        (append-record record)
        record)))

(defun ingest-clean-event (event)
  "Ingest EVENT after a trusted producer has sanitized the complete record."
  (let* ((record (ensure-causal-record event))
         (policy (and *observation-policy-hook*
                      (funcall *observation-policy-hook* record)))
         (record (if policy
                     (append record
                             (list :observation-source (pget policy :source)
                                   :observation-enabled
                                   (and (pget policy :enabled) t)
                                   :observation-managed
                                   (and (pget policy :managed) t)))
                     record)))
    (if (and *journal-enabled*
             (or (null policy) (pget policy :enabled)))
        (append-clean-record record)
        record)))

(defun journal-records ()
  (bt:with-lock-held (*journal-lock*) (copy-list *journal-records*)))

(defun query-records (&key workspace kind trace-id limit)
  "Query one required workspace partition. Cross-workspace scans are unavailable."
  (unless workspace (error "workspace is required for a causal journal query"))
  (let ((key (normalize-workspace workspace)))
    ;; Filter while traversing the indexed list and stop at LIMIT. This avoids
    ;; copying the entire 90-day partition under the append lock for the common
    ;; latest-policy/latest-status lookup.
    (bt:with-lock-held (*journal-lock*)
      (loop for record in (gethash key *journal-by-workspace*)
            when (and (or (null kind) (eq kind (pget record :kind)))
                      (or (null trace-id)
                          (equal trace-id (pget record :trace-id))))
              collect record into result
              and count 1 into count
            when (and limit (>= count limit)) return result
            finally (return result)))))

(defun find-record (id workspace)
  (let ((record (bt:with-lock-held (*journal-lock*)
                  (gethash id *journal-by-id*))))
    (and record
         (string= (normalize-workspace workspace) (pget record :workspace))
         record)))

(defun causal-neighbors (id workspace)
  "Return (:RECORD R :PARENTS (...) :CHILDREN (...)) within WORKSPACE."
  (let ((record (find-record id workspace)))
    (unless record (return-from causal-neighbors nil))
    (let* ((records (query-records :workspace workspace))
           (parent-ids (remove nil (list (pget record :causation-id)
                                         (pget record :parent-span-id))
                               :test #'equal))
           (parents (remove-if-not
                     (lambda (candidate)
                       (member (record-id candidate) parent-ids :test #'equal))
                     records))
           (children (remove-if-not
                      (lambda (candidate)
                        (or (equal id (pget candidate :causation-id))
                            (equal (pget record :span-id)
                                   (pget candidate :parent-span-id))))
                      records)))
      (list :record record :parents parents :children children))))

(defun register-schema-migration (from-version function)
  "Register the pure FROM-VERSION → FROM-VERSION+1 migration FUNCTION."
  (setf (gethash from-version *schema-migrations*) function))

(defun migrate-record (record)
  (loop with current = record
        for version = (or (pget current :schema-version)
                          (pget current :schema) 0)
        while (< version +journal-schema-version+) do
          (let ((migration (gethash version *schema-migrations*)))
            (unless migration (error "no causal schema migration from ~D" version))
            (setf current (funcall migration current)))
        finally (return (ensure-causal-record current))))

(register-schema-migration
 0 (lambda (record)
     (let ((copy (copy-list record)))
       (remf copy :schema)
       (plist-put copy :schema-version 1))))

(defun migration-marker-path (legacy-path)
  (ourro-path "state" "migrations"
             (format nil "legacy-events-~A.sexp"
                     (subseq (ourro.txn:sha256-string (namestring legacy-path)) 0 16))))

(defun migrate-legacy-event-file (legacy-path &key workspace)
  "Import a legacy line log once, retaining a backup and durable marker."
  (let ((marker (migration-marker-path legacy-path)))
    (when (probe-file marker) (return-from migrate-legacy-event-file :already-migrated))
    (let ((backup (make-pathname :defaults legacy-path
                                 :name (format nil "~A.pre-causal"
                                               (pathname-name legacy-path)))))
      (when (probe-file legacy-path)
        (uiop:copy-file legacy-path backup)
        (append-record-batch
         (mapcar #'migrate-record (read-sexp-lines legacy-path))
         :workspace workspace))
      (write-sexp-file marker
                       (list :schema-version 1 :source (namestring legacy-path)
                             :backup (namestring backup)
                             :completed-at (iso-time)))
      :migrated)))

(defun read-canonical-file (path)
  (with-open-file (in path :direction :input)
    (let ((text (make-string (file-length in))))
      (read-sequence text in)
      (ourro.txn:canonical-decode text))))

(defun export-workspace (workspace path)
  (let* ((workspace (normalize-workspace workspace))
         (records (reverse (query-records :workspace workspace)))
         (bundle (list :schema-version 1 :record-kind :workspace-export
                       :workspace workspace :exported-at (iso-time)
                       :records records
                       :manifest-hash (ourro.txn:canonical-hash records))))
    (ourro.txn:write-canonical-file path bundle)
    bundle))

(defun import-workspace (path &key expected-workspace)
  (let* ((bundle (read-canonical-file path))
         (workspace (pget bundle :workspace))
         (records (pget bundle :records)))
    (unless (and (eq :workspace-export (pget bundle :record-kind))
                 (stringp workspace)
                 (or (null expected-workspace)
                     (string= workspace (normalize-workspace expected-workspace)))
                 (string= (pget bundle :manifest-hash)
                          (ourro.txn:canonical-hash records)))
      (error "invalid or unexpected workspace export"))
    (with-workspace-restoration (workspace)
      (append-record-batch records :workspace workspace)
      (length records))))

(defun replace-journal (records)
  (let* ((path (journal-path))
         (temporary (merge-pathnames
                     (format nil ".~A.compacting" (pathname-name path)) path)))
    (when (probe-file temporary) (delete-file temporary))
    (ensure-directories-exist temporary)
    (if records
        (ourro.txn:append-wal-record-batch temporary records)
        (with-open-file (out temporary :direction :output :if-exists :supersede
                                      :if-does-not-exist :create)))
    (sb-posix:rename (namestring temporary) (namestring path))
    (setf *journal-records* records)
    (rebuild-indexes records)
    (rebuild-deletion-index records)
    ;; A replacement WAL invalidates every prior byte offset and prefix hash.
    (when (probe-file (snapshot-path)) (delete-file (snapshot-path)))
    records))

(defun compact-journal (&key (now (unix-time))
                             (retention-seconds +default-retention-seconds+))
  "Remove expired records and atomically rebuild the WAL and indexes."
  (bt:with-lock-held (*journal-lock*)
    (let* ((*retention-policy-context*
             (and *retention-policy-prepare-hook*
                  (funcall *retention-policy-prepare-hook* *journal-records*)))
           (kept (remove-if
                 (lambda (record)
                   (let ((timestamp (pget record :unix))
                         (record-retention
                           (or (and *retention-policy-hook*
                                    (funcall *retention-policy-hook*
                                             record *journal-records*
                                             retention-seconds))
                               retention-seconds)))
                     (and (not (eq :workspace-deletion
                                   (pget record :record-kind)))
                          (numberp timestamp)
                          (> (- now timestamp) record-retention))))
                 *journal-records*)))
      (replace-journal kept))))

(defun delete-workspace (workspace)
  "Remove WORKSPACE from the WAL and indexes; retain only a non-reversible hash."
  (let* ((workspace (normalize-workspace workspace))
         (hash (ourro.txn:sha256-string workspace)))
    (bt:with-lock-held (*journal-lock*)
      (setf (gethash workspace *workspace-deletions-in-progress*) t))
    (unwind-protect
         (progn
           ;; Stop/purge product consumers while the append barrier prevents a
           ;; late worker from recreating the partition behind the deletion.
           (run-workspace-deletion-hooks workspace)
           (bt:with-lock-held (*journal-lock*)
             (let ((kept (remove workspace *journal-records* :test #'string=
                                                          :key (lambda (record)
                                                                 (pget record :workspace)))))
               (replace-journal kept)
               (let ((tombstone
                       (ensure-causal-record
                        (list :record-kind :workspace-deletion
                              :kind :workspace-deleted
                              :deleted-workspace-hash hash
                              :time (iso-time) :unix (unix-time))
                        :workspace "workspace:system")))
                 (ourro.txn:append-wal-record (journal-path) tombstone)
                 (setf *journal-records* (nconc *journal-records* (list tombstone))
                       (gethash hash *deleted-workspace-hashes*) t)
                 (index-record tombstone)
                 ;; A pre-deletion snapshot is another persisted copy of the payload.
                 ;; REPLACE-JOURNAL invalidated it; write a new payload-free snapshot.
                 (write-journal-snapshot-unlocked (snapshot-path))
                 (list :status :deleted :workspace-hash hash)))))
      (bt:with-lock-held (*journal-lock*)
        (remhash workspace *workspace-deletions-in-progress*)))))

(defun write-journal-snapshot-unlocked (path)
  (let* ((records (copy-list *journal-records*))
         (wal-bytes (if (probe-file (journal-path))
                        (with-open-file (in (journal-path)
                                            :direction :input
                                            :element-type '(unsigned-byte 8))
                          (file-length in))
                        0))
         (snapshot (list :schema-version 1 :record-kind :causal-snapshot
                         :created-at (iso-time)
                         :record-count (length records)
                         :wal-bytes wal-bytes
                         :wal-prefix-hash
                         (ourro.txn:wal-prefix-hash (journal-path) wal-bytes)
                         :records records
                         :manifest-hash (ourro.txn:canonical-hash records))))
    (ourro.txn:write-canonical-file path snapshot)
    snapshot))

(defun write-journal-snapshot (&optional (path (snapshot-path)))
  (bt:with-lock-held (*journal-lock*)
    (write-journal-snapshot-unlocked path)))
