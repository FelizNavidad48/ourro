(in-package #:ourro.tests)

(def-suite reflex-briefing-suite :in ourro)
(in-suite reflex-briefing-suite)

(defun briefing-event (&rest fields)
  (append (list :kind :job-exit :event-id "job-event-1"
                :workspace "/repo/a/" :job "j1" :command "make test"
                :exit 1)
          fields))

(defun wait-for-briefing-condition (predicate seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop
      (when (funcall predicate) (return t))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.02))))

(defun briefing-job-done-p (id)
  (let ((job (ourro.jobs:job-record id)))
    (and job (not (eq :running (pget job :status))))))

(test model-free-briefings-cover-fixed-failure-classes
  (with-scratch-journal ()
    (loop for case in
             (list (list :test-failure
                         (briefing-event :log "suite/widget FAILED"
                                         :changed-files '("src/widget.lisp")))
                   (list :compiler-failure
                         (briefing-event :log "COMPILE-FILE-ERROR"
                                         :diagnostic-file "src/a.lisp"
                                         :diagnostic-line 42
                                         :diagnostic-code "E-COMPILE"
                                         :source-hash "abc"))
                   (list :timeout
                         (briefing-event :exit :timeout :deadline 30
                                         :elapsed-ms 30001
                                         :last-progress "compiling"
                                         :process-outcome :killed)))
          for index from 1 do
      (let* ((record (ourro.reflex.briefing:produce-job-failure-briefing
                      (second case)
                      :idempotency-key (format nil "failure-~D" index)))
             (text (pget record :text))
             (evidence
               (ourro.reflex.journal:find-record
                (first (pget record :evidence-ids)) "/repo/a/")))
        (is (eq (first case) (pget record :failure-class)))
        (is (search "No cause was inferred" text))
        (is (search "evidence:" text))
        (ecase (first case)
          (:test-failure
           (is (string= "make test" (pget evidence :command)))
           (is (= 1 (pget evidence :exit)))
           (is (search "FAILED" (pget evidence :failing-test)))
           (is (equal '("src/widget.lisp")
                      (pget evidence :changed-files))))
          (:compiler-failure
           (is (string= "src/a.lisp" (pget evidence :diagnostic-file)))
           (is (= 42 (pget evidence :diagnostic-line)))
           (is (string= "E-COMPILE" (pget evidence :diagnostic-code)))
           (is (string= "abc" (pget evidence :source-hash))))
          (:timeout
           (is (= 30 (pget evidence :deadline)))
           (is (= 30001 (pget evidence :elapsed-ms)))
           (is (string= "compiling" (pget evidence :last-progress)))
           (is (eq :killed (pget evidence :process-outcome)))))))))

(test briefing-is-idempotent-and-reconstructable
  (with-scratch-journal ()
    (let* ((event (briefing-event :log "test alpha failed"
                                  :changed-files '("src/a.lisp")))
           (first (ourro.reflex.briefing:produce-job-failure-briefing
                   event :idempotency-key "same"))
           (second (ourro.reflex.briefing:produce-job-failure-briefing
                    event :idempotency-key "same")))
      (is (string= (pget first :event-id) (pget second :event-id)))
      (is (= 1 (length (ourro.reflex.journal:query-records
                        :workspace "/repo/a/" :kind :job-failure-briefing))))
      (is (= 1 (length (pget first :evidence-ids)))))))

(test replaying-the-same-investigation-does-not-repeat-the-model-or-note-decision
  (with-scratch-journal ()
    (let ((calls 0) (created-states '()))
      (flet ((investigator (prompt evidence)
               (declare (ignore prompt))
               (incf calls)
               (list :text (format nil "diagnosis [evidence:~A]"
                                   (pget evidence :event-id)))))
        (multiple-value-bind (first created-p)
            (ourro.reflex.briefing:produce-job-failure-briefing
             (briefing-event :log "suite failed")
             :idempotency-key "crash-replay" :investigator #'investigator)
          (push created-p created-states)
          (multiple-value-bind (second replay-created-p)
              (ourro.reflex.briefing:produce-job-failure-briefing
               (briefing-event :log "suite failed")
               :idempotency-key "crash-replay" :investigator #'investigator)
            (push replay-created-p created-states)
            (is (string= (pget first :event-id) (pget second :event-id))))))
      (is (= 1 calls))
      (is (equal '(nil t) created-states)))))

(test investigator-input-and-provider-identity-are-durable
  (with-scratch-journal ()
    (let ((seen nil))
      (let ((record
              (ourro.reflex.briefing:produce-job-failure-briefing
               (briefing-event :log "suite failed")
               :investigator
               (lambda (prompt evidence)
                 (setf seen (list prompt evidence))
                 (list :text (format nil "Cause is cited [evidence:~A]"
                                     (pget evidence :event-id))
                       :provider :scripted :model "fixture" :cost 0))
               :limits '(:steps 8 :seconds 300))))
        (is-true seen)
        (is (eq :scripted (pget record :provider)))
        (is (string= "fixture" (pget record :model)))
        (is-true (pget record :citations-accurate))
        (is-true (pget record :no-changes-made))))))

(test uncited-model-claims-fall-back-without-losing-audit-metadata
  (with-scratch-journal ()
    (let ((record
            (ourro.reflex.briefing:produce-job-failure-briefing
             (briefing-event :log "suite failed")
             :investigator
             (lambda (prompt evidence)
               (declare (ignore prompt evidence))
               (list :text "The cause is definitely a race."
                     :provider :scripted :model "fixture"
                     :tool-results '((:tool "read_file" :result "x")))))))
      (is-true (pget record :fallback-used))
      (is-false (pget record :citations-accurate))
      (is (search "No cause was inferred" (pget record :text)))
      (is (= 1 (length (pget record :tool-results)))))))

(test real-failed-job-produces-one-durable-briefing-off-the-foreground-lane
  (with-scratch-reflex-runtime ()
    (let* ((workspace (uiop:ensure-directory-pathname
                       (merge-pathnames (format nil "ourro-briefing-repo-~A/"
                                                (make-id "repo"))
                                        (uiop:temporary-directory))))
           (ourro.toolkit:*workspace* workspace)
           (ourro.observe:*workspace-context-fn*
             (lambda () (namestring workspace)))
           (ourro.observe::*event-subscribers* '())
           (ourro.observe::*event-log-path* nil)
           (ourro.observe::*recent-events* '())
           (started (bt:make-semaphore :name "briefing-investigation-start"))
           (calls 0))
      (ensure-directories-exist (merge-pathnames "tracked.txt" workspace))
      (with-open-file (out (merge-pathnames "tracked.txt" workspace)
                           :direction :output :if-exists :supersede
                           :if-does-not-exist :create)
        (write-line "unchanged" out))
      (let ((before (ourro.txn:sha256-file
                     (merge-pathnames "tracked.txt" workspace)))
            (before-manifest
              (ourro.reflex.briefing:workspace-residue-manifest workspace)))
        (ourro.jobs:reset-jobs)
        (unwind-protect
             (progn
               (let* ((definition
                        (ourro.reflex.model:definition-from-form
                         '(define-reflex job-sentinel-e2e
                            (:identity
                             (:version 1 :workspace :current
                              :capabilities
                              (:filesystem-read :llm :observe)))
                            (:trigger (:kind :job-exit :exit (:not 0)))
                            (:guards ())
                            (:state (:version 1 :initial-step :brief))
                            (:workflow
                             ((:id :brief :activity :investigate :next :done)))
                            (:policy (:approval :required :timeout 2)))))
                      (version (ourro.reflex.compiler:compile-reflex definition)))
                 (ourro.reflex.compiler:install-reflex-version version)
                 (ourro.reflex.compiler:activate-reflex-version
                  'job-sentinel-e2e (ourro.reflex.model:version-hash version)
                  :approved-authority '(:filesystem-read :llm :observe)))
               (setf (gethash :investigate ourro.reflex.effects:*effect-hooks*)
                     (lambda (input key)
                       (incf calls)
                       (ourro.reflex.briefing:briefing-from-effect-input
                        input key
                        :investigator
                        (lambda (prompt evidence)
                          (declare (ignore prompt))
                          (bt:signal-semaphore started)
                          (sleep 0.25)
                          (list :text
                                (format nil "Fixture diagnosis [evidence:~A]"
                                        (pget evidence :event-id))
                                :provider :scripted :model "fixture"
                                :tool-results '())))))
               (ourro.reflex.runtime:install-runtime-dispatch)
               (ourro.reflex.runtime:submit-command
                (list :type :arm :workspace workspace))
               (let ((job (ourro.jobs:start-job
                           "echo 'suite/widget FAILED'; exit 7"
                           :directory workspace)))
                 (is-true (wait-for-briefing-condition
                           (lambda () (briefing-job-done-p job)) 5))
                 (is-true (bt:wait-on-semaphore started :timeout 2))
                 (let ((start (get-internal-real-time)))
                   (is-true (pget (ourro.reflex.runtime:submit-command
                                   '(:type :status))
                                  :armed))
                   (is (< (/ (- (get-internal-real-time) start)
                             internal-time-units-per-second)
                          0.1)))
                 (is-true
                  (wait-for-briefing-condition
                   (lambda ()
                     (= 1 (length
                           (ourro.reflex.journal:query-records
                            :workspace workspace
                            :kind :job-failure-briefing))))
                   5))
                 (let* ((briefing
                          (first (ourro.reflex.journal:query-records
                                  :workspace workspace
                                  :kind :job-failure-briefing)))
                        (evidence
                          (ourro.reflex.journal:find-record
                           (first (pget briefing :evidence-ids)) workspace))
                        (job-exit
                          (ourro.reflex.journal:find-record
                           (pget evidence :causation-id) workspace))
                        (job-start
                          (ourro.reflex.journal:find-record
                           (pget job-exit :causation-id) workspace)))
                   (is (= 1 calls))
                   (is (search "Fixture diagnosis" (pget briefing :text)))
                   (is (search "FAILED" (pget evidence :log)))
                   (is-true (pget briefing :no-changes-made))
                   (is (eq :failure-evidence (pget evidence :kind)))
                   (is (eq :job-exit (pget job-exit :kind)))
                   (is (eq :job-start (pget job-start :kind)))
                   (is (string= (pget briefing :causation-id)
                                (pget evidence :event-id)))
                   (is (string= (pget evidence :causation-id)
                                (pget job-exit :event-id)))
                   (is (string= (pget job-exit :causation-id)
                                (pget job-start :event-id))))
               (is (string= before
                            (ourro.txn:sha256-file
                             (merge-pathnames "tracked.txt" workspace))))
               (is (equal before-manifest
                          (ourro.reflex.briefing:workspace-residue-manifest
                           workspace))))
          (ignore-errors (ourro.reflex.runtime:remove-runtime-dispatch))
          (ignore-errors (ourro.jobs:kill-all-jobs))
          (ourro.jobs:reset-jobs)
          (ignore-errors
            (uiop:delete-directory-tree workspace :validate (constantly t)))))))))
