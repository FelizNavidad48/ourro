
(defpackage #:ourro.reflex.pilot
  (:use #:cl #:ourro.util)
  (:export #:set-observation-source
           #:observation-source-status
           #:set-local-control-policy
           #:local-control-status
           #:preview-observation
           #:record-guided-step
           #:guided-experience-status
           #:record-pilot-event
           #:pilot-funnel
           #:pilot-gate-report
           #:make-release-record
           #:release-eligible-p))

(in-package #:ourro.reflex.pilot)

(defparameter +pilot-event-kinds+
  '(:eligible-user :comparison-completed :qualifying-event :briefing
    :briefing-rated :candidate-exposed :candidate-approved
    :eligible-firing :successful-outcome :week-eight-retention
    :unwanted-firing :corrected-firing :undone-firing :safety-incident
    :attention :path-assessment :path-choice :comprehension :payment
    :source-week-eight :workflow-qualified))

(defun event-observation-source (event)
  (let ((kind (pget event :kind)))
    (cond
      ((member kind '(:job-start :job-exit :job-cancelled :job-output)) :jobs)
      ((member kind '(:tool-call :tool-result :parallel-tool-call)) :tools)
      ((member kind '(:user-message :correction :feedback)) :feedback)
      ((member kind '(:evolution-proposal :evolution-staged :evolution-hot-load
                      :evolution-repair :evolution-duplicate :probation-revert
                      :snapshot-failed :snapshot-request-failed))
       :worktrees)
      (t :ourro))))

(defun append-control-record (workspace kind &rest fields)
  (ourro.reflex.journal:append-record
   (list* :record-kind :local-control :kind kind
          :time (iso-time) :unix (unix-time) fields)
   :workspace workspace))

(defun set-observation-source (workspace source enabled
                               &key model-bound (retention-days 90) actor)
  (unless (keywordp source) (error "observation source must be a keyword"))
  (unless (and (integerp retention-days) (<= 1 retention-days 365))
    (error "retention must be between 1 and 365 days"))
  (append-control-record
   workspace :observation-source
   :source source :enabled (and enabled t) :opt-in t
   :model-bound (and model-bound t) :retention-days retention-days
   :actor (or actor :user)))

(defun observation-source-status (workspace &optional source)
  (let ((latest (make-hash-table :test #'eq)))
    (dolist (record (ourro.reflex.journal:query-records
                     :workspace workspace :kind :observation-source))
      (let ((key (pget record :source)))
        (unless (gethash key latest) (setf (gethash key latest) record))))
    (if source
        (copy-list (gethash source latest))
        (let ((result '()))
          (maphash (lambda (key value) (declare (ignore key)) (push value result))
                   latest)
          (sort result #'string< :key (lambda (item)
                                        (symbol-name (pget item :source))))))))

(defun observation-policy (event)
  "Fail closed per source once this workspace enters local-control mode."
  (let* ((workspace (pget event :workspace))
         (source (event-observation-source event))
         (managed (first (ourro.reflex.journal:query-records
                          :workspace workspace :kind :local-control-policy
                          :limit 1)))
         (deleted-hash (ourro.txn:sha256-string
                        (ourro.reflex.journal:normalize-workspace workspace)))
         (deleted
           (find deleted-hash
                 (ourro.reflex.journal:query-records
                  :workspace "workspace:system" :kind :workspace-deleted)
                 :key (lambda (record)
                        (pget record :deleted-workspace-hash))
                 :test #'string=))
         (control (and managed (observation-source-status workspace source))))
    ;; A deletion tombstone keeps future observation closed until a new
    ;; explicit local-control policy is recorded. The raw workspace identity
    ;; never needs to survive in the system tombstone.
    (list :source source :managed (and (or managed deleted) t)
          :enabled (cond (managed (and control (pget control :enabled)))
                         (deleted nil)
                         (t t)))))

(defun prepare-source-retention-policy (records)
  (let ((latest (make-hash-table :test #'equal)))
    (dolist (candidate records latest)
      (when (eq :observation-source (pget candidate :kind))
        (setf (gethash (list (pget candidate :workspace)
                             (pget candidate :source))
                       latest)
              candidate)))))

(defun source-retention-policy (record records default-seconds)
  "Return the latest configured retention for one managed observation source."
  (declare (ignore records))
  (let ((source (pget record :observation-source))
        (workspace (pget record :workspace))
        (latest nil))
    (when (and source (pget record :observation-managed))
      (setf latest
            (gethash (list workspace source)
                     ourro.reflex.journal::*retention-policy-context*)))
    (if latest
        (* (pget latest :retention-days) 24 60 60)
        default-seconds)))

(defun set-local-control-policy (workspace &key provider retention-days
                                                crash-reporting
                                                crash-endpoint
                                                guided-experience actor)
  (unless (and (integerp retention-days) (<= 1 retention-days 365))
    (error "retention must be between 1 and 365 days"))
  (when (and crash-reporting (null crash-endpoint))
    (error "opt-in crash reporting requires a disclosed endpoint"))
  (append-control-record
   workspace :local-control-policy
   :provider (or provider :none)
   :provider-disclosed t
   :retention-days retention-days
   :crash-reporting (and crash-reporting t)
   :crash-endpoint (and crash-reporting crash-endpoint)
   :guided-experience (and guided-experience t)
   :actor (or actor :user)))

(defun local-control-status (workspace)
  (let ((policy (first (ourro.reflex.journal:query-records
                        :workspace workspace :kind :local-control-policy))))
    (list :policy policy
          :sources (observation-source-status workspace)
          :journal-health (ourro.reflex.journal:journal-health)
          :armed (ourro.reflex.runtime:runtime-armed-p)
          :export-available t :delete-verifiable t)))

(defun preview-observation (workspace source payload &key model-bound-fields)
  (let ((control (observation-source-status workspace source)))
    (list :source source
          :enabled (and control (pget control :enabled))
          :retention-days (and control (pget control :retention-days))
          :preview (ourro.reflex.journal:data-preview
                    payload
                    :model-bound-fields
                    (and control (pget control :enabled)
                         (pget control :model-bound)
                         model-bound-fields)))))

(defun record-guided-step (workspace step &key completed actor)
  (append-control-record workspace :guided-first-reflex
                         :step step :completed (and completed t)
                         :actor (or actor :user)))

(defun guided-experience-status (workspace)
  (let ((latest (make-hash-table :test #'equal)))
    (dolist (record (ourro.reflex.journal:query-records
                     :workspace workspace :kind :guided-first-reflex))
      (unless (gethash (pget record :step) latest)
        (setf (gethash (pget record :step) latest) record)))
    (let ((steps '()))
      (maphash (lambda (step record)
                 (push (list :step step :completed (pget record :completed)) steps))
               latest)
      (list :steps (nreverse steps)
            :complete (and steps
                           (every (lambda (item) (pget item :completed)) steps))))))

(defun record-pilot-event (workspace kind &rest fields)
  (unless (member kind +pilot-event-kinds+)
    (error "unknown preregistered pilot event ~S" kind))
  (unless (pget fields :participant-id)
    (error "pilot events require a participant identity"))
  (ourro.reflex.journal:append-record
   (list* :record-kind :pilot-metric :kind kind
          :time (iso-time) :unix (unix-time) fields)
   :workspace workspace))

(defun pilot-records (workspace)
  (remove-if-not (lambda (record)
                   (eq :pilot-metric (pget record :record-kind)))
                 (ourro.reflex.journal:query-records :workspace workspace)))

(defun records-of-kind (records kind)
  (remove kind records :test-not #'eq :key (lambda (record)
                                             (pget record :kind))))

(defun distinct-values (records key)
  (remove-duplicates (remove nil (mapcar (lambda (record) (pget record key)) records))
                     :test #'equal))

(defun pilot-funnel (workspace)
  (let ((records (pilot-records workspace)))
    (loop for kind in '(:qualifying-event :briefing :briefing-rated
                        :candidate-exposed :candidate-approved
                        :eligible-firing :successful-outcome
                        :week-eight-retention)
          append (list kind (length (records-of-kind records kind))))))

(defun safe-ratio (numerator denominator)
  (if (zerop denominator) 0.0d0 (/ numerator denominator 1.0d0)))

(defun median (numbers)
  (when numbers
    (let* ((sorted (sort (copy-list numbers) #'<))
           (length (length sorted))
           (middle (floor length 2)))
      (if (oddp length)
          (nth middle sorted)
          (/ (+ (nth (1- middle) sorted) (nth middle sorted)) 2.0d0)))))

(defun unique-unwanted-firings (records)
  (let ((seen (make-hash-table :test #'equal)) (result '()))
    (dolist (record records (nreverse result))
      (let ((key (or (pget record :firing-id)
                     (pget record :responsible-firing-id)
                     (pget record :event-id))))
        (unless (gethash key seen)
          (setf (gethash key seen) t)
          (push record result))))))

(defun cluster-cell-counts (records)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (record records table)
      (let ((user (pget record :participant-id))
            (reflex (pget record :reflex-id)))
        (when (and user reflex)
          (incf (gethash (list user reflex) table 0)))))))

(defun two-way-cluster-bootstrap-interval (firings unwanted
                                           &key (replicates 2000)
                                                (seed 220022))
  "Deterministic percentile bootstrap resampling user and reflex clusters."
  (let ((users (distinct-values firings :participant-id))
        (reflexes (distinct-values firings :reflex-id)))
    (when (or (null firings) (null users) (null reflexes))
      (return-from two-way-cluster-bootstrap-interval (list 0.0d0 1.0d0)))
    (let ((denominators (cluster-cell-counts firings))
          (numerators (cluster-cell-counts unwanted))
          (state seed)
          (estimates '()))
      (labels ((next-index (bound)
                 (setf state (lcg-next state))
                 (mod state bound))
               (weights (clusters)
                 (let ((result (make-hash-table :test #'equal)))
                   (loop repeat (length clusters) do
                     (incf (gethash (nth (next-index (length clusters)) clusters)
                                    result 0))
                         finally (return result)))))
        (loop repeat replicates do
          (let ((user-weights (weights users))
                (reflex-weights (weights reflexes))
                (numerator 0) (denominator 0))
            (maphash
             (lambda (cell count)
               (let ((weight (* (gethash (first cell) user-weights 0)
                                (gethash (second cell) reflex-weights 0))))
                 (incf denominator (* weight count))
                 (incf numerator (* weight (gethash cell numerators 0)))))
             denominators)
            (when (plusp denominator)
              (push (safe-ratio numerator denominator) estimates))))
        (if estimates
            (list (percentile estimates 0.025d0)
                  (percentile estimates 0.975d0))
            (list 0.0d0 1.0d0))))))

(defun clustered-rates (firings unwanted key)
  (loop for id in (distinct-values firings key)
        for denominator = (count id firings :test #'equal
                                      :key (lambda (record) (pget record key)))
        for numerator = (count id unwanted :test #'equal
                                    :key (lambda (record) (pget record key)))
        collect (list key id :unwanted numerator :eligible denominator
                      :rate (safe-ratio numerator denominator))))

(defun path-metric (records path key)
  (let ((selected (remove path records :test-not #'eq
                                       :key (lambda (record) (pget record :path)))))
    (values (safe-ratio (count-if (lambda (record) (pget record key)) selected)
                        (length selected))
            (length selected))))

(defun latest-records-by (records keys)
  (let ((seen (make-hash-table :test #'equal)) (result '()))
    ;; Journal queries are newest first.
    (dolist (record records (nreverse result))
      (let ((identity (mapcar (lambda (key) (pget record key)) keys)))
        (unless (gethash identity seen)
          (setf (gethash identity seen) t)
          (push record result))))))

(defun reflex-opportunities (records reflex-id)
  (count reflex-id (records-of-kind records :eligible-firing)
         :test #'equal :key (lambda (record) (pget record :reflex-id))))

(defun report-check (name measured threshold pass &key minimum)
  (list :gate name :measured measured :threshold threshold
        :minimum minimum :pass (and pass t)))

(defun pilot-gate-report (workspace)
  "Evaluate the published M22 thresholds without manufacturing missing evidence."
  (let* ((records (pilot-records workspace))
         (eligible (records-of-kind records :eligible-user))
         (complete (records-of-kind records :comparison-completed))
         (briefings (records-of-kind records :briefing))
         (ratings (records-of-kind records :briefing-rated))
         (useful (count-if (lambda (record) (>= (or (pget record :rating) 0) 4))
                           ratings))
         (exposed (records-of-kind records :candidate-exposed))
         (approved (remove-if-not
                    (lambda (record) (<= (or (pget record :week) 99) 4))
                    (records-of-kind records :candidate-approved)))
         (retained (remove-if-not (lambda (record) (pget record :active))
                                  (records-of-kind records :week-eight-retention)))
         (eligible-users (distinct-values eligible :participant-id))
         (complete-users (distinct-values complete :participant-id))
         (qualified-workflows (records-of-kind records :workflow-qualified))
         (baseline-qualified-completers
           (count-if
            (lambda (participant)
              (>= (length
                   (distinct-values
                    (remove-if-not
                     (lambda (record)
                       (and (equal participant (pget record :participant-id))
                            (>= (or (pget record :weekly-frequency) 0) 3)))
                     qualified-workflows)
                    :workflow-id))
                  3))
            complete-users))
         (exposed-users (distinct-values exposed :participant-id))
         (approved-users (distinct-values approved :participant-id))
         (approved-reflexes (distinct-values approved :reflex-id))
         (retained-reflexes
           (remove-if-not
            (lambda (id)
              (and (find id retained :test #'equal
                         :key (lambda (record) (pget record :reflex-id)))
                   (>= (reflex-opportunities records id) 10)))
            approved-reflexes))
         (firings (records-of-kind records :eligible-firing))
         (unwanted-by-kind
           (loop for kind in '(:unwanted-firing :corrected-firing :undone-firing)
                 append (list kind (length (records-of-kind records kind)))))
         (unwanted
           (unique-unwanted-firings
            (append (records-of-kind records :unwanted-firing)
                    (records-of-kind records :corrected-firing)
                    (records-of-kind records :undone-firing))))
         (interval (two-way-cluster-bootstrap-interval firings unwanted))
         (safety (records-of-kind records :safety-incident))
         (safety-counts
           (loop for class in '(:unapproved-authority :cross-workspace
                                :mixed-generation :ambiguous-repeat)
                 append (list class
                              (count class safety :test #'eq
                                     :key (lambda (record)
                                            (pget record :incident-class))))))
         (arm-counts
           (loop for path in '(:briefing-only :authored :learned)
                 collect (cons path
                               (count path firings :test #'eq
                                      :key (lambda (record) (pget record :path))))))
         (attention (records-of-kind records :attention))
         (attention-medians
           (loop for path in '(:authored :learned)
                 collect
                 (cons path
                       (median
                        (mapcar (lambda (record) (pget record :minutes))
                                (remove path attention :test-not #'eq
                                        :key (lambda (record)
                                               (pget record :path))))))))
         (authored-attention (cdr (assoc :authored attention-medians)))
         (learned-attention (cdr (assoc :learned attention-medians)))
         (attention-reduction
           (if (and authored-attention learned-attention
                    (plusp authored-attention))
               (- 1.0d0 (/ learned-attention authored-attention 1.0d0))
               0.0d0))
         (assessments (records-of-kind records :path-assessment))
         (authored-accuracy (multiple-value-list
                             (path-metric assessments :authored
                                          :diagnosis-accurate)))
         (learned-accuracy (multiple-value-list
                            (path-metric assessments :learned
                                         :diagnosis-accurate)))
         (authored-success (multiple-value-list
                            (path-metric assessments :authored :task-success)))
         (learned-success (multiple-value-list
                           (path-metric assessments :learned :task-success)))
         (retained-value-medians
           (loop for path in '(:authored :learned)
                 collect
                 (cons path
                       (median
                        (remove nil
                                (mapcar
                                 (lambda (record) (pget record :retained-net-value))
                                 (remove path assessments :test-not #'eq
                                                           :key (lambda (record)
                                                                  (pget record :path)))))))))
         (authored-value (cdr (assoc :authored retained-value-medians)))
         (learned-value (cdr (assoc :learned retained-value-medians)))
         (choices (latest-records-by
                   (remove-if-not
                    (lambda (record)
                      (member (pget record :participant-id) complete-users
                              :test #'equal))
                    (records-of-kind records :path-choice))
                   '(:participant-id)))
         (learned-choices (count :learned choices :test #'eq
                                 :key (lambda (record) (pget record :choice))))
         (comprehension
           (latest-records-by (records-of-kind records :comprehension)
                              '(:participant-id)))
         (comprehension-passes
           (count-if (lambda (record)
                       (every (lambda (key) (pget record key))
                              '(:why :authority :data-boundary :pause-rollback)))
                     comprehension))
         (payment-users
           (distinct-values
            (remove-if-not
             (lambda (record)
               (and (pget record :budget-controller)
                    (not (pget record :refundable))
                    (>= (or (pget record :amount) 0) 250)))
             (records-of-kind records :payment))
            :participant-id))
         (source-retention
           (latest-records-by (records-of-kind records :source-week-eight)
                              '(:participant-id :source)))
         (required-sources
           (distinct-values (remove-if-not (lambda (record) (pget record :required))
                                           source-retention)
                            :source))
         (source-enabled-completers
           (count-if
            (lambda (participant)
              (and required-sources
                   (every
                    (lambda (source)
                      (let ((record
                              (find-if
                               (lambda (candidate)
                                 (and (equal participant
                                             (pget candidate :participant-id))
                                      (equal source (pget candidate :source))))
                               source-retention)))
                        (and record (pget record :enabled))))
                    required-sources)))
            complete-users))
         (source-retention-rate
           (safe-ratio source-enabled-completers (length complete-users)))
         (checks
           (list
            (report-check :eligible-users (length eligible-users) 15
                          (>= (length eligible-users) 15))
            (report-check :comparison-completers (length complete-users) 12
                          (>= (length complete-users) 12))
            (report-check :baseline-qualified-completers
                          baseline-qualified-completers 12
                          (>= baseline-qualified-completers 12))
            (report-check :ratings (length ratings) 100 (>= (length ratings) 100)
                          :minimum (safe-ratio (length ratings) (length briefings)))
            (report-check :briefing-usefulness
                          (safe-ratio useful (length ratings)) 0.70d0
                          (and (>= (length ratings) 100)
                               (>= (safe-ratio (length ratings) (length briefings))
                                   0.80d0)
                               (>= (safe-ratio useful (length ratings)) 0.70d0)))
            (report-check :candidate-user-approval-by-week-four
                          (safe-ratio (length approved-users)
                                      (length exposed-users))
                          0.50d0
                          (>= (safe-ratio (length approved-users)
                                          (length exposed-users)) 0.50d0))
            (report-check :approved-reflex-retention
                          (safe-ratio (length retained-reflexes)
                                      (length approved-reflexes))
                          0.50d0
                          (>= (safe-ratio (length retained-reflexes)
                                          (length approved-reflexes)) 0.50d0))
            (report-check :safety-incidents (length safety) 0 (null safety))
            (report-check :unwanted-firing-rate
                          (safe-ratio (length unwanted) (length firings)) 0.05d0
                          (and (>= (length firings) 200)
                               (>= (length (distinct-values firings :participant-id)) 10)
                               (>= (length (distinct-values firings :reflex-id)) 10)
                               (< (safe-ratio (length unwanted) (length firings))
                                  0.05d0)
                               (< (second interval) 0.10d0)))
            (report-check :attention-reduction attention-reduction 0.30d0
                          (>= attention-reduction 0.30d0))
            (report-check :diagnosis-accuracy
                          (first learned-accuracy) (first authored-accuracy)
                          (and (plusp (second authored-accuracy))
                               (plusp (second learned-accuracy))
                               (>= (first learned-accuracy)
                                   (first authored-accuracy))))
            (report-check :task-success
                          (first learned-success) (first authored-success)
                          (and (plusp (second authored-success))
                               (plusp (second learned-success))
                               (>= (first learned-success)
                                   (first authored-success))))
            (report-check :learned-retained-net-value learned-value authored-value
                          (and authored-value learned-value
                               (> learned-value authored-value)))
            (report-check :learned-preference
                          (safe-ratio learned-choices (length complete-users)) 0.60d0
                          (>= (safe-ratio learned-choices
                                          (length complete-users)) 0.60d0))
            (report-check :comprehension
                          (safe-ratio comprehension-passes
                                      (length complete-users)) 0.80d0
                          (>= (safe-ratio comprehension-passes
                                          (length complete-users)) 0.80d0))
            (report-check :payments (length payment-users) 5
                          (>= (length payment-users) 5))
            (report-check :source-retention source-retention-rate 0.70d0
                          (>= source-retention-rate 0.70d0))))
         (minima-met
           (and (>= (length eligible-users) 15)
                (>= (length complete-users) 12)
                (>= baseline-qualified-completers 12)
                (>= (length ratings) 100)
                (>= (safe-ratio (length ratings) (length briefings)) 0.80d0)
                (every (lambda (path)
                         (>= (or (cdr (assoc path arm-counts)) 0) 150))
                       '(:briefing-only :authored :learned))
                (>= (length firings) 200)
                (>= (length (distinct-values firings :participant-id)) 10)
                (>= (length (distinct-values firings :reflex-id)) 10)
                (plusp (second authored-accuracy))
                (plusp (second learned-accuracy))))
         (status (cond ((not minima-met) :inconclusive)
                       ((every (lambda (check) (pget check :pass)) checks) :go)
                       (t :no-go))))
    (list :status status :preregistered-thresholds t
          :funnel (pilot-funnel workspace)
          :checks checks :safety-counts safety-counts
          :unwanted-counts unwanted-by-kind
          :unwanted-total (length unwanted)
          :unwanted-interval interval
          :interval-method :two-way-user-reflex-cluster-bootstrap-95
          :per-user-rates (clustered-rates firings unwanted :participant-id)
          :per-reflex-rates (clustered-rates firings unwanted :reflex-id)
          :arm-opportunities arm-counts
          :attention-medians attention-medians
          :retained-value-medians retained-value-medians
          :unrated-as-non-useful
          (safe-ratio useful (max 1 (length briefings)))
          :evidence-citation-accuracy
          (safe-ratio
           (count-if (lambda (record) (pget record :citations-accurate)) ratings)
           (length ratings)))))

(defun open-severe-finding-p (finding enabled-effect-classes)
  (and (member (pget finding :severity) '(:critical :high))
       (not (member (pget finding :status) '(:closed :mitigated)))
       (or (eq :all (pget finding :effect-class))
           (member (pget finding :effect-class) enabled-effect-classes))))

(defun make-release-record (workspace &key build-commit toolchain threat-model
                                           review-scope review-evidence findings
                                           enabled-effect-classes residual-risks
                                           reviewer)
  "Persist the independent-review gate; missing review evidence fails closed."
  (let* ((open-severe (remove-if-not
                       (lambda (finding)
                         (open-severe-finding-p finding enabled-effect-classes))
                       findings))
         (review-present (and reviewer review-scope review-evidence threat-model))
         (eligible (and review-present (null open-severe)))
         (record
           (list :record-kind :release-record :kind :release-record
                 :build-commit build-commit :toolchain toolchain
                 :threat-model threat-model :reviewer reviewer
                 :review-scope review-scope :review-evidence review-evidence
                 :findings findings :open-critical-high open-severe
                 :enabled-effect-classes enabled-effect-classes
                 :disabled-effect-classes
                 (remove-if-not
                  (lambda (class)
                    (some (lambda (finding)
                            (and (eq class (pget finding :effect-class))
                                 (member (pget finding :severity)
                                         '(:critical :high))
                                 (not (member (pget finding :status)
                                              '(:closed :mitigated)))))
                          findings))
                  '(:read :notify :job :investigation :prepare-change))
                 :residual-risks residual-risks
                 :release-eligible (and eligible t)
                 :status (if eligible :eligible :blocked)
                 :time (iso-time) :unix (unix-time))))
    (ourro.reflex.journal:append-record record :workspace workspace)))

(defun release-eligible-p (workspace)
  (let ((record (first (ourro.reflex.journal:query-records
                        :workspace workspace :kind :release-record))))
    (and record (pget record :release-eligible) t)))

;; Installing the M22 product module activates policy enforcement for observed
;; events and compaction. Workspaces remain legacy-compatible until an explicit
;; local-control policy record is created; thereafter missing source consent is
;; a denial, not an implicit opt-in.
(setf ourro.reflex.journal:*observation-policy-hook* #'observation-policy
      ourro.reflex.journal:*retention-policy-hook* #'source-retention-policy
      ourro.reflex.journal:*retention-policy-prepare-hook*
      #'prepare-source-retention-policy)
