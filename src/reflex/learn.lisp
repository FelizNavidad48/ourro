
(defpackage #:ourro.reflex.learn
  (:use #:cl #:ourro.util)
  (:export #:episodes-from-records
           #:generalize-demonstrated-slot
           #:mine-demonstration-candidate
           #:candidate-reflex-form
           #:run-shadow
           #:record-shadow-outcome
           #:record-shadow-miss
           #:shadow-metrics
           #:stage-reflex-review
           #:approve-reflex-canary
           #:promote-read-only-canary
           #:recover-reflex-lifecycle
           #:propose-correction-version
           #:read-only-authority-p))

(in-package #:ourro.reflex.learn)

(defparameter +identity-keys+
  '(:event-id :record-id :trace-id :span-id :parent-span-id :causation-id
    :correlation-id :workspace :time :unix :schema :schema-version :record-kind))

(defun episode-key (record)
  (or (pget record :trace-id) (pget record :turn-id) (pget record :job)
      (pget record :event-id)))

(defun episodes-from-records (records)
  "Group one workspace partition into ordered causal episodes."
  (let ((groups (make-hash-table :test #'equal)))
    (dolist (record (sort (copy-list records) #'<
                          :key (lambda (item) (or (pget item :unix) 0))))
      (push record (gethash (episode-key record) groups)))
    (let ((episodes '()))
      (maphash
       (lambda (key values)
         (let* ((records (nreverse values))
                (trigger (find-if (lambda (record)
                                    (member (pget record :kind)
                                            '(:job-exit :tool-call :user-message)))
                                  records))
                (reaction (find-if (lambda (record)
                                     (member (pget record :kind)
                                             '(:job-failure-briefing :note
                                               :tool-call :job-start)))
                                   (cdr (member trigger records)))))
           (push (list :episode-id key :workspace (pget (first records) :workspace)
                       :day (and (pget (first records) :time)
                                 (subseq (pget (first records) :time) 0 10))
                       :trigger trigger :reaction reaction :records records)
                 episodes)))
       groups)
      (nreverse episodes))))

(defun demonstrated-value-type (value)
  (cond ((stringp value) :string)
        ((integerp value) :integer)
        ((numberp value) :number)
        ((keywordp value) :keyword)
        ((symbolp value) :symbol)
        ((listp value) :list)
        (t (type-of value))))

(defun generalize-demonstrated-slot (slot values &key contradiction-p)
  "Preserve a constant until three distinct typed values support a variable."
  (let ((distinct (remove-duplicates values :test #'equal)))
    (if (and (not contradiction-p) (>= (length distinct) 3)
             (every (lambda (value)
                      (eq (demonstrated-value-type value)
                          (demonstrated-value-type (first distinct))))
                    distinct))
        (list :var slot)
        (first values))))

(defun event-data-keys (event)
  (loop for (key value) on event by #'cddr
        unless (member key +identity-keys+) append (list key value)))

(defun pattern-matches-event-p (pattern event)
  (loop for (key expected) on pattern by #'cddr
        always (ourro.reflex.model::reflex-value-matches-p
                expected (pget event key))))

(defun mine-demonstration-candidate (name episodes &key negative-episodes guards)
  "Infer one trigger and one observed activity from explicit causal episodes."
  (unless (>= (length episodes) 3)
    (error "at least three causal episodes are required"))
  (let* ((triggers (mapcar (lambda (episode) (pget episode :trigger)) episodes))
         (reactions (mapcar (lambda (episode) (pget episode :reaction)) episodes))
         (first-trigger (event-data-keys (first triggers)))
         (pattern
           (loop for (key initial) on first-trigger by #'cddr
                 for values = (mapcar (lambda (event) (pget event key)) triggers)
                 for negative-values =
                   (remove nil
                           (mapcar (lambda (episode)
                                     (pget (pget episode :trigger) key))
                                   negative-episodes))
                 when (every (lambda (value) (not (null value))) values)
                   append
                   (list key
                         (generalize-demonstrated-slot
                          key values
                          :contradiction-p
                          (some (lambda (value)
                                  (eq (demonstrated-value-type value)
                                      (demonstrated-value-type initial)))
                                negative-values)))))
         (reaction (first reactions))
         (activity (or (pget reaction :activity)
                       (case (pget reaction :kind)
                         (:job-start :start-job)
                         ((:note :job-failure-briefing) :notify)
                         (t :read))))
         (workflow (list (list :id :act :activity activity
                               :input (copy-list (or (pget reaction :input) '()))
                               :next :done)))
         (authority (ourro.reflex.model:derive-capabilities workflow))
         (trigger-counterexamples
           (remove-if-not
            (lambda (episode)
              (pattern-matches-event-p pattern (pget episode :trigger)))
            negative-episodes))
         (unsafe-counterexamples
           (remove-if-not
            (lambda (episode)
              (or (null guards)
                  (pattern-matches-event-p guards (pget episode :trigger))))
            trigger-counterexamples)))
    (when unsafe-counterexamples
      (error "candidate still fires on ~D known negative episode~:P"
             (length unsafe-counterexamples)))
    (list :name (string-downcase (string name)) :support (length episodes)
          :episode-ids (mapcar (lambda (episode) (pget episode :episode-id)) episodes)
          :trigger pattern :guards (copy-list guards)
          :workflow workflow :authority authority
          :counterexamples
          (mapcar (lambda (episode) (pget episode :episode-id)) negative-episodes)
          :status (if negative-episodes :shadow-required :proposed))))

(defun candidate-reflex-form (candidate &key (version 1) (workspace :current))
  `(define-reflex ,(intern (string-upcase (pget candidate :name)) :keyword)
     (:identity (:version ,version :workspace ,workspace
                 :capabilities ,(pget candidate :authority)))
     (:trigger ,(pget candidate :trigger))
     (:guards ,(copy-list (pget candidate :guards)))
     (:state (:version 1 :initial-step :act))
     (:workflow ,(pget candidate :workflow))
     (:policy (:approval :required))))

(defun version-workspace (version workspace)
  (let ((declared (ourro.reflex.model:reflex-workspace
                   (ourro.reflex.model:version-definition version))))
    (if (eq declared :current) workspace declared)))

(defun run-shadow (version event &key workspace)
  "Plan a deterministic trace and persist it without invoking an adapter."
  (let* ((definition (ourro.reflex.model:version-definition version))
         (workspace (version-workspace version (or workspace (pget event :workspace)))))
    (unless (ourro.reflex.model:reflex-matches-p definition event)
      (return-from run-shadow nil))
    (let* ((state (list :step
                        (or (pget (ourro.reflex.model:reflex-state-schema definition)
                                  :initial-step)
                            (pget (first (ourro.reflex.model:reflex-workflow definition))
                                  :id))))
           (trace (funcall (ourro.reflex.model:version-transition-function version)
                           state event nil)))
      (ourro.reflex.journal:append-record
       (list :record-kind :shadow-plan :kind :shadow-plan
             :reflex (ourro.reflex.model:reflex-name definition)
             :reflex-version (ourro.reflex.model:version-hash version)
             :trigger-event-id (pget event :event-id)
             :planned-trace trace :no-effects-executed t
             :causation-id (pget event :event-id)
             :time (iso-time) :unix (unix-time))
       :workspace workspace))))

(defun benefit-eligible-p (outcome correction manually-undone)
  (and (member outcome '(:ok :succeeded :correct) :test #'eq)
       (null correction) (not manually-undone)))

(defun record-shadow-outcome (version shadow-record &key matched-user-reaction
                                                        qualifying-reaction
                                                        outcome correction cost day
                                                        episode-id benefit
                                                        manually-undone)
  (ourro.reflex.journal:append-record
   (list :record-kind :shadow-outcome :kind :shadow-outcome
         :reflex-version (ourro.reflex.model:version-hash version)
         :shadow-plan-id (pget shadow-record :event-id)
         :matched-user-reaction (and matched-user-reaction t)
         :qualifying-reaction (and qualifying-reaction t)
         :episode-id episode-id :fired t
         :outcome outcome :correction correction :cost cost
         :manually-undone (and manually-undone t)
         :claimed-benefit
         (and (benefit-eligible-p outcome correction manually-undone) benefit)
         :day (or day (subseq (iso-time) 0 10))
         :causation-id (pget shadow-record :event-id)
         :time (iso-time) :unix (unix-time))
   :workspace (pget shadow-record :workspace)))

(defun record-shadow-miss (version workspace &key qualifying-reaction outcome
                                                   correction cost day episode-id
                                                   benefit manually-undone)
  "Record an eligible opportunity where the candidate did not fire."
  (ourro.reflex.journal:append-record
   (list :record-kind :shadow-outcome :kind :shadow-miss
         :reflex-version (ourro.reflex.model:version-hash version)
         :episode-id episode-id :fired nil :matched-user-reaction nil
         :qualifying-reaction (and qualifying-reaction t)
         :outcome outcome :correction correction :cost cost
         :manually-undone (and manually-undone t)
         ;; A non-firing cannot claim the user's outcome as automated benefit.
         :claimed-benefit nil :offered-benefit benefit
         :day (or day (subseq (iso-time) 0 10))
         :time (iso-time) :unix (unix-time))
   :workspace workspace))

(defun cluster-bootstrap-lower-bound (records)
  "Deterministic day-cluster bootstrap lower bound for shadow precision."
  (let ((by-day (make-hash-table :test #'equal)) (seed 1729))
    (dolist (record records) (push record (gethash (pget record :day) by-day)))
    (let ((days '()) (samples '()))
      (maphash (lambda (day values) (push (cons day values) days)) by-day)
      (dotimes (iteration 1000)
        (let ((hits 0) (total 0))
          (dotimes (i (length days))
            (setf seed (lcg-next seed i))
            (dolist (record (cdr (nth (mod seed (length days)) days)))
              (incf total)
              (when (pget record :matched-user-reaction) (incf hits))))
          ;; Mix loop coordinates into the deterministic stream without
          ;; depending on CL's implementation-global random state.
          (incf seed (+ iteration (length days)))
          (push (if (zerop total) 0 (/ hits total 1.0d0)) samples)))
      (percentile samples 0.025))))

(defun shadow-metrics (version workspace)
  (let* ((hash (ourro.reflex.model:version-hash version))
         (records (remove-if-not
                   (lambda (record)
                     (and (member (pget record :kind)
                                  '(:shadow-outcome :shadow-miss))
                          (string= hash (pget record :reflex-version))))
                   (ourro.reflex.journal:query-records :workspace workspace)))
         (firing-records (remove-if-not (lambda (record) (pget record :fired))
                                        records))
         (firings (length firing-records))
         (matched (count-if (lambda (record)
                              (pget record :matched-user-reaction)) firing-records))
         (qualifying (count-if (lambda (record)
                                (pget record :qualifying-reaction)) records))
         (days (remove-duplicates (mapcar (lambda (record) (pget record :day)) records)
                                  :test #'equal))
         (sampled (and (>= (length records) 20) (plusp firings)
                       (>= (length days) 5)))
         (disqualified
           (count-if (lambda (record)
                       (or (member (pget record :outcome)
                                   '(:failed :timeout :timed-out) :test #'eq)
                           (pget record :correction)
                           (pget record :manually-undone)))
                     firing-records))
         (by-day
           (mapcar
            (lambda (day)
              (let ((day-records (remove day records :test-not #'equal
                                                   :key (lambda (record)
                                                          (pget record :day)))))
                (list :day day :opportunities (length day-records)
                      :firings (count-if (lambda (record) (pget record :fired))
                                         day-records)
                      :matched (count-if
                                (lambda (record)
                                  (pget record :matched-user-reaction))
                                day-records))))
            (sort (copy-list days) #'string<))))
    (list :firings firings :matched matched :qualifying-reactions qualifying
          :opportunities (length records)
          :episode-count
          (length (remove-duplicates
                   (remove nil (mapcar (lambda (record) (pget record :episode-id))
                                       records))
                   :test #'equal))
          :days (length days)
          :by-day by-day :disqualified-outcomes disqualified
          :claimed-benefit
          (reduce #'+ firing-records :initial-value 0
                  :key (lambda (record) (or (pget record :claimed-benefit) 0)))
          :precision (if (zerop firings) 0 (/ matched firings 1.0d0))
          :coverage (if (zerop qualifying) 0 (/ matched qualifying 1.0d0))
          :lower-95 (and sampled
                         (cluster-bootstrap-lower-bound firing-records))
          :status (if sampled :sampled :under-sampled))))

(defun lifecycle-record (kind version workspace &rest fields)
  (ourro.reflex.journal:append-record
   (list* :record-kind :reflex-lifecycle :kind kind
          :reflex (ourro.reflex.model:reflex-name
                   (ourro.reflex.model:version-definition version))
          :reflex-version (ourro.reflex.model:version-hash version)
          :time (iso-time) :unix (unix-time) fields)
   :workspace workspace))

(defun stage-reflex-review (version workspace &key evidence counterexamples
                                                   simulated-trace expected-benefit
                                                   uncertainty rollback-target)
  (let* ((definition (ourro.reflex.model:version-definition version))
         (authority (ourro.reflex.model:reflex-capabilities definition)))
    (ourro.reflex.compiler:stage-reflex-version
     (ourro.reflex.model:reflex-name definition)
     (ourro.reflex.model:version-hash version) :approved-authority authority)
    (lifecycle-record
     :staged version workspace
     ;; Retain exact artifact identities in the journal. The immutable version
     ;; registry/export bundle holds the full source/IR/generated Lisp/proof;
     ;; duplicating those deeply nested forms in every lifecycle record can
     ;; exceed the intentionally small canonical frame depth.
     :source (with-standard-io-syntax
               (let ((*print-pretty* nil))
                 (prin1-to-string
                  (ourro.reflex.model:reflex-source-form definition))))
     :canonical-ir-hash
     (ourro.txn:canonical-hash (ourro.reflex.model:version-ir version))
     :generated-lisp-hash
     (pget (ourro.reflex.model:version-proof version) :generated-lisp-hash)
     :proof-hash (pget (ourro.reflex.model:version-proof version) :proof-hash)
     :authority authority :evidence evidence :counterexamples counterexamples
     :simulated-trace simulated-trace :expected-benefit expected-benefit
     :uncertainty uncertainty :rollback-target rollback-target)))

(defun approve-reflex-canary (version workspace approved-authority &key actor)
  "Bless exactly one staged hash and authority; broader versions cannot inherit it."
  (let* ((definition (ourro.reflex.model:version-definition version))
         (name (ourro.reflex.model:reflex-name definition))
         (hash (ourro.reflex.model:version-hash version))
         (previous (ourro.reflex.compiler:active-reflex-version name)))
    (unless (equal approved-authority
                   (ourro.reflex.model:reflex-capabilities definition))
      (error "approval authority differs from the exact staged version"))
    (lifecycle-record :approved version workspace :authority approved-authority
                      :actor (or actor :user))
    (ourro.reflex.compiler:canary-reflex-version
     name hash :approved-authority approved-authority)
    (lifecycle-record :canary version workspace :authority approved-authority
                      :actor (or actor :user)
                      :rollback-target
                      (and previous (ourro.reflex.model:version-hash previous)))))

(defun read-only-authority-p (authority)
  (subsetp authority '(:filesystem-read :observe)))

(defun promote-read-only-canary (version workspace)
  (let* ((definition (ourro.reflex.model:version-definition version))
         (metrics (shadow-metrics version workspace)))
    (unless (and (read-only-authority-p
                  (ourro.reflex.model:reflex-capabilities definition))
                 (eq :sampled (pget metrics :status))
                 (zerop (pget metrics :disqualified-outcomes))
                 (>= (or (pget metrics :lower-95) 0) 0.80d0))
      (return-from promote-read-only-canary nil))
    (ourro.reflex.compiler:promote-reflex-version
     (ourro.reflex.model:reflex-name definition)
     (ourro.reflex.model:version-hash version)
     :approved-authority (ourro.reflex.model:reflex-capabilities definition))
    (lifecycle-record :active version workspace :policy-evidence metrics)))

(defun recover-reflex-lifecycle (workspace)
  "Restore only the newest explicit lifecycle state for each name.

An imported bundle appends :IMPORTED-INACTIVE, so historical ACTIVE evidence
cannot accidentally become current routing in a clean home."
  (let ((restored 0) (latest (make-hash-table :test #'equal)))
    ;; Queries are newest first. Keep exactly the first lifecycle state per name.
    (dolist (record (ourro.reflex.journal:query-records :workspace workspace))
      (when (and (eq :reflex-lifecycle (pget record :record-kind))
                 (pget record :reflex)
                 (not (gethash (pget record :reflex) latest)))
        (setf (gethash (pget record :reflex) latest) record)))
    (maphash
     (lambda (name record)
       (let ((version (ourro.reflex.compiler:find-reflex-version
                       name (pget record :reflex-version))))
         (when (and version (member (pget record :kind) '(:active :canary)))
           (let ((authority
                   (ourro.reflex.model:reflex-capabilities
                    (ourro.reflex.model:version-definition version))))
             (setf (ourro.reflex.model:version-status version) :verified)
             (if (eq :active (pget record :kind))
                 (ourro.reflex.compiler:activate-reflex-version
                  name (pget record :reflex-version)
                  :approved-authority authority)
                 (progn
                   (let ((fallback (pget record :rollback-target)))
                     (when fallback
                       (let ((old (ourro.reflex.compiler:find-reflex-version
                                   name fallback)))
                         (when old
                           (setf (ourro.reflex.model:version-status old) :verified)
                           (ourro.reflex.compiler:activate-reflex-version
                            name fallback
                            :approved-authority
                            (ourro.reflex.model:reflex-capabilities
                             (ourro.reflex.model:version-definition old)))))))
                   (ourro.reflex.compiler:stage-reflex-version
                    name (pget record :reflex-version)
                    :approved-authority authority)
                   (ourro.reflex.compiler:canary-reflex-version
                    name (pget record :reflex-version)
                    :approved-authority authority)))
             (incf restored)))))
     latest)
    restored))

(defun propose-correction-version (version &key add-guard remove-trigger-keys
                                                reduce-authority correction-id
                                                responsible-firing-id workspace)
  "Return an inspectable narrowing proposal; never mutate VERSION or routing."
  (let* ((definition (ourro.reflex.model:version-definition version))
         (trigger (copy-list (ourro.reflex.model:reflex-trigger definition)))
         (guards (append (copy-list (ourro.reflex.model:reflex-guards definition))
                         (copy-list add-guard)))
         (authority (if reduce-authority
                        (intersection
                         (ourro.reflex.model:reflex-capabilities definition)
                         reduce-authority)
                        (copy-list
                         (ourro.reflex.model:reflex-capabilities definition)))))
    ;; Removing a trigger predicate broadens matching; keep it inspectable but
    ;; never describe it as a narrowing correction or let it inherit consent.
    (dolist (key remove-trigger-keys) (remf trigger key))
    (let* ((broadening (and remove-trigger-keys t))
           (next-version
             (1+ (ourro.reflex.model:reflex-version-number definition)))
           (source-form
             `(define-reflex
                  ,(intern (string-upcase
                            (ourro.reflex.model:reflex-name definition)) :keyword)
                (:identity (:version ,next-version
                            :workspace ,(ourro.reflex.model:reflex-workspace definition)
                            :capabilities ,authority))
                (:trigger ,trigger)
                (:guards ,guards)
                (:state ,(copy-tree
                           (ourro.reflex.model:reflex-state-schema definition)))
                (:workflow ,(copy-tree
                              (ourro.reflex.model:reflex-workflow definition)))
                (:policy ,(copy-tree
                            (ourro.reflex.model:reflex-policy definition)))))
           (proposal
             (list :status :staged
                   :parent-version (ourro.reflex.model:version-hash version)
                   :version next-version :trigger trigger :guards guards
                   :authority authority :source-form source-form
                   :responsible-firing-id responsible-firing-id
                   :correction-id correction-id :broadening broadening)))
      (when (and workspace correction-id responsible-firing-id)
        (ourro.reflex.journal:append-record
         (list :record-kind :reflex-correction :kind :reflex-correction
               :correction-id correction-id
               :responsible-firing-id responsible-firing-id
               :parent-version (ourro.reflex.model:version-hash version)
               :proposal-hash (ourro.txn:canonical-hash proposal)
               :broadening broadening
               :causation-id responsible-firing-id
               :time (iso-time) :unix (unix-time))
         :workspace workspace))
      proposal)))
