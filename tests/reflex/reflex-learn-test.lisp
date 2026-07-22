(in-package #:ourro.tests)

(def-suite reflex-learn-suite :in ourro)
(in-suite reflex-learn-suite)

(test demonstration-generalization-requires-three-distinct-typed-values
  (is (string= "a.lisp"
               (ourro.reflex.learn:generalize-demonstrated-slot
                :path '("a.lisp" "a.lisp" "a.lisp"))))
  (is (equal '(:var :path)
             (ourro.reflex.learn:generalize-demonstrated-slot
              :path '("a.lisp" "b.lisp" "c.lisp"))))
  (is (string= "a.lisp"
               (ourro.reflex.learn:generalize-demonstrated-slot
                :path '("a.lisp" "b.lisp" "c.lisp")
                :contradiction-p t))))

(defun demonstration-episode (id path &key branch)
  (list :episode-id id
        :trigger (append (list :kind :tool-call :path path)
                         (when branch (list :branch branch)))
        :reaction '(:kind :note :input (:text "run tests"))))

(test negative-episodes-block-unsafe-generalization-and-require-shadow
  (let* ((positive
           (list (demonstration-episode "p1" "a.lisp")
                 (demonstration-episode "p2" "b.lisp")
                 (demonstration-episode "p3" "c.lisp")))
         (negative (demonstration-episode "n1" "a.lisp" :branch "release")))
    (signals error
      (ourro.reflex.learn:mine-demonstration-candidate
       'unsafe positive :negative-episodes (list negative)))
    (let ((candidate
            (ourro.reflex.learn:mine-demonstration-candidate
             'guarded positive :negative-episodes (list negative)
             :guards '(:branch "main"))))
      (is (eq :shadow-required (pget candidate :status)))
      (is (equal '("n1") (pget candidate :counterexamples)))
      ;; The same-typed negative prevents PATH from becoming a variable.
      (is (string= "a.lisp" (pget (pget candidate :trigger) :path)))
      (is (equal '(:observe) (pget candidate :authority))))))

(test shadow-planning-never-invokes-live-effects
  (with-scratch-reflex-runtime ()
    (let* ((version (install-active-fixture-version))
           (calls 0))
      (setf (gethash :notify ourro.reflex.effects:*effect-hooks*)
            (lambda (input key)
              (declare (ignore input key)) (incf calls)))
      (let ((shadow (ourro.reflex.learn:run-shadow
                     version (fixture-runtime-event) :workspace "/repo/a/")))
        (is-true shadow)
        (is-true (pget shadow :no-effects-executed))
        (is (= 0 calls))))))

(test shadow-policy-is-under-sampled-until-count-and-day-minima
  (with-scratch-reflex-runtime ()
    (let ((version (install-active-fixture-version)))
      (dotimes (i 20)
        (let ((shadow (ourro.reflex.learn:run-shadow
                       version (fixture-runtime-event) :workspace "/repo/a/")))
          (ourro.reflex.learn:record-shadow-outcome
           version shadow :matched-user-reaction t :qualifying-reaction t
           :day (format nil "2026-07-~2,'0D" (1+ (mod i 5))))))
      (let ((metrics (ourro.reflex.learn:shadow-metrics version "/repo/a/")))
        (is (eq :sampled (pget metrics :status)))
        (is (= 20 (pget metrics :firings)))
        (is (= 1.0d0 (pget metrics :lower-95)))))))

(test failed-corrected-timed-out-and-undone-shadow-work-claims-no-benefit
  (with-scratch-reflex-runtime ()
    (let ((version (ourro.reflex.compiler:compile-reflex
                    (ourro.reflex.model:definition-from-form
                     (fixture-reflex-form)))))
      (ourro.reflex.compiler:install-reflex-version version)
      (ourro.reflex.compiler:stage-reflex-version
       'failed-job-briefing (ourro.reflex.model:version-hash version)
       :approved-authority '(:observe))
      (ourro.reflex.compiler:canary-reflex-version
       'failed-job-briefing (ourro.reflex.model:version-hash version)
       :approved-authority '(:observe))
      (dotimes (i 20)
        (let ((shadow (ourro.reflex.learn:run-shadow
                       version (fixture-runtime-event) :workspace "/repo/a/")))
          (ourro.reflex.learn:record-shadow-outcome
           version shadow :matched-user-reaction t :qualifying-reaction t
           :episode-id (format nil "episode-~D" i)
           :outcome (if (zerop i) :failed :succeeded)
           :benefit (if (zerop i) 999 10)
           :day (format nil "2026-07-~2,'0D" (1+ (mod i 5))))))
      (let ((metrics (ourro.reflex.learn:shadow-metrics version "/repo/a/")))
        (is (= 20 (pget metrics :opportunities)))
        (is (= 20 (pget metrics :episode-count)))
        (is (= 5 (length (pget metrics :by-day))))
        (is (= 1 (pget metrics :disqualified-outcomes)))
        (is (= 190 (pget metrics :claimed-benefit)))
        (is-false
         (ourro.reflex.learn:promote-read-only-canary version "/repo/a/"))))))

(test consent-binds-exact-hash-and-authority-and-corrections-only-narrow
  (with-scratch-reflex-runtime ()
    (let* ((version (ourro.reflex.compiler:compile-reflex
                     (ourro.reflex.model:definition-from-form
                      (fixture-reflex-form))))
           (hash (ourro.reflex.model:version-hash version)))
      (ourro.reflex.compiler:install-reflex-version version)
      (ourro.reflex.learn:stage-reflex-review version "/repo/a/"
                                             :rollback-target "previous")
      (signals error
        (ourro.reflex.learn:approve-reflex-canary
         version "/repo/a/" '(:observe :network)))
      (ourro.reflex.learn:approve-reflex-canary version "/repo/a/" '(:observe))
      (is (string= hash
                   (ourro.reflex.model:version-hash
                    (ourro.reflex.compiler:active-reflex-version
                     'failed-job-briefing))))
      (let ((proposal (ourro.reflex.learn:propose-correction-version
                       version :add-guard '(:branch "main")
                       :reduce-authority '(:observe) :correction-id "c1"
                       :responsible-firing-id "firing-1"
                       :workspace "/repo/a/")))
        (is (eq :staged (pget proposal :status)))
        (is-false (pget proposal :broadening))
        (is (equal '(:observe) (pget proposal :authority)))
        (is-true (pget proposal :source-form))
        (let ((record
                (first (ourro.reflex.journal:query-records
                        :workspace "/repo/a/" :kind :reflex-correction))))
          (is (string= "firing-1" (pget record :responsible-firing-id)))
          (is (string= hash (pget record :parent-version))))
        (is (string= hash
                     (ourro.reflex.model:version-hash
                      (ourro.reflex.compiler:active-reflex-version
                       'failed-job-briefing))))
        (let* ((broadened
                 (ourro.reflex.learn:propose-correction-version
                  version :remove-trigger-keys '(:outcome)
                  :correction-id "c2"))
               (new-version
                 (ourro.reflex.compiler:compile-reflex
                  (ourro.reflex.model:definition-from-form
                   (pget broadened :source-form)))))
          (is-true (pget broadened :broadening))
          (ourro.reflex.compiler:install-reflex-version new-version)
          (signals error
            (ourro.reflex.compiler:canary-reflex-version
             'failed-job-briefing
             (ourro.reflex.model:version-hash new-version)
             :approved-authority '(:observe)))
          (is (string= hash
                       (ourro.reflex.model:version-hash
                        (ourro.reflex.compiler:active-reflex-version
                         'failed-job-briefing)))))))))

(test effectful-canary-is-never-policy-promoted
  (with-scratch-reflex-runtime ()
    (is-false (ourro.reflex.learn:read-only-authority-p '(:llm)))
    (is-true (ourro.reflex.learn:read-only-authority-p
              '(:filesystem-read :observe)))))
