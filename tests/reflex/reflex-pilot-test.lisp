(in-package #:ourro.tests)

(def-suite reflex-pilot-suite :in ourro)
(in-suite reflex-pilot-suite)

(defun pilot-event (kind &rest fields)
  (apply #'ourro.reflex.pilot:record-pilot-event
         "/repo/a/" kind :participant-id (or (pget fields :participant-id) "u0")
         fields))

(test local-control-is-opt-in-inspectable-and-key-redacted
  (with-scratch-reflex-runtime ()
    (ourro.reflex.pilot:set-observation-source
     "/repo/a/" :jobs t :model-bound t :retention-days 30)
    (ourro.reflex.pilot:set-local-control-policy
     "/repo/a/" :provider :vertex :retention-days 30
     :crash-reporting nil :guided-experience t)
    (let* ((preview (ourro.reflex.pilot:preview-observation
                     "/repo/a/" :jobs
                     '(:command "make test" :password "do-not-store" :exit 1)
                     :model-bound-fields '(:command :exit)))
           (stored (pget (pget preview :preview) :stored)))
      (is-true (pget preview :enabled))
      (is (string= "«redacted»" (pget stored :password)))
      (is (= 30 (pget preview :retention-days))))))

(test local-control-enforces-source-opt-in-and-per-source-retention
  (with-scratch-reflex-runtime ()
    (ourro.reflex.pilot:set-observation-source
     "/repo/a/" :jobs t :retention-days 1)
    (ourro.reflex.pilot:set-observation-source
     "/repo/a/" :tools t :retention-days 30)
    (ourro.reflex.pilot:set-local-control-policy
     "/repo/a/" :provider :none :retention-days 90
     :crash-reporting nil :guided-experience t)
    (let ((job (ourro.reflex.journal:ingest-event
                (list :kind :job-exit :unix 0 :workspace "/repo/a/")))
          (tool (ourro.reflex.journal:ingest-event
                 (list :kind :tool-call :unix 0 :workspace "/repo/a/")))
          (feedback (ourro.reflex.journal:ingest-event
                     (list :kind :correction :unix 0 :workspace "/repo/a/"))))
      (is-true (pget job :observation-enabled))
      (is-true (pget tool :observation-enabled))
      (is-false (pget feedback :observation-enabled))
      (is (null (find (pget feedback :event-id)
                      (ourro.reflex.journal:query-records :workspace "/repo/a/")
                      :test #'equal :key (lambda (record)
                                           (pget record :event-id)))))
      (ourro.reflex.journal:compact-journal :now (* 2 24 60 60))
      (let ((records (ourro.reflex.journal:query-records :workspace "/repo/a/")))
        (is (null (find :job-exit records :key (lambda (record)
                                                (pget record :kind)))))
        (is-true (find :tool-call records :key (lambda (record)
                                                (pget record :kind))))))))

(test pilot-report-never-rounds-missing-evidence-into-a-pass
  (with-scratch-reflex-runtime ()
    (pilot-event :eligible-user :participant-id "one")
    (is (eq :inconclusive
            (pget (ourro.reflex.pilot:pilot-gate-report "/repo/a/") :status)))))

(test complete-preregistered-pilot-fixture-can-pass-exact-thresholds
  (with-scratch-reflex-runtime ()
    (dotimes (i 15)
      (pilot-event :eligible-user :participant-id (format nil "u~D" i)))
    (dotimes (i 12)
      (pilot-event :comparison-completed :participant-id (format nil "u~D" i))
      (dotimes (workflow 3)
        (pilot-event :workflow-qualified :participant-id (format nil "u~D" i)
                     :workflow-id (format nil "w~D-~D" i workflow)
                     :weekly-frequency 3)))
    (dotimes (i 100)
      (pilot-event :qualifying-event :participant-id (format nil "u~D" (mod i 15)))
      (pilot-event :briefing :participant-id (format nil "u~D" (mod i 15)))
      (pilot-event :briefing-rated :participant-id (format nil "u~D" (mod i 15))
                   :rating (if (< i 70) 5 3) :citations-accurate t))
    (dotimes (i 15)
      (pilot-event :candidate-exposed :participant-id (format nil "u~D" i)))
    (dotimes (i 8)
      (pilot-event :candidate-approved :participant-id (format nil "u~D" i)
                   :reflex-id (format nil "r~D" i) :week 4))
    (dotimes (i 150)
      (pilot-event :eligible-firing
                   :participant-id (format nil "u~D" (mod i 12))
                   :reflex-id (format nil "r~D" (mod i 10))
                   :path :briefing-only))
    (dotimes (i 300)
      (let ((participant (format nil "u~D" (mod i 12)))
            (reflex (format nil "r~D" (mod i 10)))
            (path (if (< i 150) :authored :learned)))
        (pilot-event :eligible-firing :participant-id participant
                     :reflex-id reflex :path path)
        (pilot-event :successful-outcome :participant-id participant
                     :reflex-id reflex :path path)))
    (dotimes (i 4)
      (pilot-event :week-eight-retention :participant-id (format nil "u~D" i)
                   :reflex-id (format nil "r~D" i) :active t))
    (dotimes (i 12)
      (pilot-event :attention :participant-id (format nil "u~D" i)
                   :path :authored :minutes 10)
      (pilot-event :attention :participant-id (format nil "u~D" i)
                   :path :learned :minutes 6)
      (pilot-event :path-assessment :participant-id (format nil "u~D" i)
                   :path :authored :diagnosis-accurate t :task-success t
                   :retained-net-value 10)
      (pilot-event :path-assessment :participant-id (format nil "u~D" i)
                   :path :learned :diagnosis-accurate t :task-success t
                   :retained-net-value 15)
      (pilot-event :path-choice :participant-id (format nil "u~D" i)
                   :choice (if (< i 8) :learned :authored))
      (pilot-event :comprehension :participant-id (format nil "u~D" i)
                   :why (< i 10) :authority (< i 10) :data-boundary (< i 10)
                   :pause-rollback (< i 10)))
    (dotimes (i 5)
      (pilot-event :payment :participant-id (format nil "u~D" i)
                   :amount 250 :budget-controller t :refundable nil))
    (dotimes (i 12)
      (pilot-event :source-week-eight :participant-id (format nil "u~D" i)
                   :source :jobs :required t :enabled (< i 9)))
    (let ((report (ourro.reflex.pilot:pilot-gate-report "/repo/a/")))
      (is (eq :go (pget report :status)))
      (is (eq :two-way-user-reflex-cluster-bootstrap-95
              (pget report :interval-method)))
      (is (equal 0 (pget (pget report :safety-counts)
                          :unapproved-authority))))))

(test release-record-fails-closed-on-missing-or-open-severe-review-findings
  (with-scratch-reflex-runtime ()
    (let ((missing (ourro.reflex.pilot:make-release-record
                    "/repo/a/" :enabled-effect-classes '(:job))))
      (is (eq :blocked (pget missing :status))))
    (let ((blocked
            (ourro.reflex.pilot:make-release-record
             "/repo/a/" :reviewer "independent.example"
             :threat-model "threat-model.md" :review-scope "scope.md"
             :review-evidence "review-report.pdf"
             :enabled-effect-classes '(:job)
             :findings '((:severity :high :effect-class :job :status :open)))))
      (is (eq :blocked (pget blocked :status))))
    (let ((eligible
            (ourro.reflex.pilot:make-release-record
             "/repo/a/" :reviewer "independent.example"
             :threat-model "threat-model.md" :review-scope "scope.md"
             :review-evidence "review-report.pdf"
             :enabled-effect-classes '(:job)
             :findings '((:severity :high :effect-class :job :status :closed)))))
      (is (eq :eligible (pget eligible :status)))
      (is-true (ourro.reflex.pilot:release-eligible-p "/repo/a/")))))
