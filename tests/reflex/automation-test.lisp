(in-package #:ourro.tests)

(def-suite automation-suite :in ourro)
(in-suite automation-suite)


(defmacro with-clean-reflexes (&body body)
  "Fresh, isolated automation + event + ledger state for one test."
  `(let ((ourro.automation::*automations* '())
         (ourro.automation::*deferred* (make-hash-table :test #'equal))
         (ourro.automation::*firing-queue* '())
         (ourro.automation::*firing-sem* (bt:make-semaphore :name "test-reflex"))
         (ourro.automation::*firings-dropped* 0)
         (ourro.automation::*dispatch-epoch* 0)
         (ourro.automation::*execution-lock*
           (bt:make-lock "test-reflex-execution"))
         (ourro.automation::*pending-notes* '())
         (ourro.automation::*note-sink* nil)
         (ourro.automation::*politeness-hook* nil)
         (ourro.automation::*investigation-queue* '())
         (ourro.automation::*investigation-hook* nil)
         (ourro.kernel:*automations-armed* t)
         (ourro.observe:*event-subscribers* '())
         (ourro.observe:*event-sink* nil)
         (ourro.observe:*utility-ledger* (make-hash-table :test #'equal))
         (ourro.observe:*gene-measurable-hook* nil))
     ,@body))

(defun reg-automation (name trigger action &key (caps '(:observe)) gene
                                                cooldown defer)
  "Register a test automation under an optional owning GENE."
  (let ((ourro.kernel:*current-gene-context*
          (list :name gene :capabilities caps)))
    (ourro.automation:register-automation name :trigger trigger
                                              :action-fn action
                                              :cooldown cooldown :defer defer)))


(test event-matches-literal-and-keys
  (is-true (ourro.automation:event-matches-p
            '(:kind :job-exit) '(:kind :job-exit :exit 0)))
  (is-false (ourro.automation:event-matches-p
             '(:kind :job-exit) '(:kind :tool-call)))
  ;; every key in the pattern must match
  (is-true (ourro.automation:event-matches-p
            '(:kind :tool-call :tool "edit_file")
            '(:kind :tool-call :tool "edit_file" :outcome :ok)))
  (is-false (ourro.automation:event-matches-p
             '(:kind :tool-call :tool "edit_file")
             '(:kind :tool-call :tool "read_file"))))

(test event-matches-value-forms
  (is-true (ourro.automation:value-matches-p '(:not 0) 3))
  (is-false (ourro.automation:value-matches-p '(:not 0) 0))
  (is-true (ourro.automation:value-matches-p '(:any :a :b) :b))
  (is-false (ourro.automation:value-matches-p '(:any :a :b) :c))
  (is-true (ourro.automation:value-matches-p '(:matches "\\.lisp$") "src/x.lisp"))
  (is-false (ourro.automation:value-matches-p '(:matches "\\.lisp$") "src/x.py"))
  (is-true (ourro.automation:value-matches-p '(:> 100) 200))
  (is-false (ourro.automation:value-matches-p '(:> 100) 50))
  (is-true (ourro.automation:value-matches-p '(:< 100) 50)))

(test event-matches-nested-plist-descent
  (is-true (ourro.automation:event-matches-p
            '(:kind :tool-call :args (:path (:matches "^src/")))
            '(:kind :tool-call :args (:path "src/foo.lisp"))))
  (is-false (ourro.automation:event-matches-p
             '(:kind :tool-call :args (:path (:matches "^src/")))
             '(:kind :tool-call :args (:path "tests/foo.lisp")))))

(test idle-and-every-never-match-a-concrete-event
  (is-false (ourro.automation:event-matches-p '(:idle 300) '(:kind :job-exit)))
  (is-false (ourro.automation:event-matches-p '(:every 600) '(:kind :job-exit))))


(test register-and-revert-round-trip
  (with-clean-reflexes
    (reg-automation "r1" '(:kind :foo) (lambda (e) (declare (ignore e)))
                    :gene "g/owner")
    (is-true (ourro.automation:find-automation "r1"))
    ;; The revert-action recorded under the owning gene removes it.
    (ourro.kernel:revert-gene-definitions "g/owner")
    (is-false (ourro.automation:find-automation "r1"))))

(test resolve-defer-defaults
  ;; tool-call/user-message/correction debounce; everything else is immediate.
  (is (eq :turn-boundary
          (ourro.automation:resolve-defer '(:kind :tool-call) nil)))
  (is (eq :immediate (ourro.automation:resolve-defer '(:kind :job-exit) nil)))
  ;; explicit wins
  (is (eq :immediate
          (ourro.automation:resolve-defer '(:kind :tool-call) :immediate))))


(test dispatch-enqueues-only-on-match-never-inline
  (with-clean-reflexes
    (let ((ran nil))
      (reg-automation "r" '(:kind :ping)
                      (lambda (e) (declare (ignore e)) (setf ran t))
                      :defer :immediate)
      ;; non-matching event → nothing
      (ourro.automation:dispatch-event '(:kind :pong))
      (is (zerop (ourro.automation:firing-queue-length)))
      ;; matching event → enqueued but NOT executed inline
      (ourro.automation:dispatch-event '(:kind :ping))
      (is (= 1 (ourro.automation:firing-queue-length)))
      (is-false ran)
      ;; the worker's execution path runs it
      (ourro.automation::run-firing (ourro.automation::pop-firing))
      (is-true ran))))

(test dispatch-inert-when-disarmed
  (with-clean-reflexes
    (reg-automation "r" '(:kind :ping) (lambda (e) (declare (ignore e)))
                    :defer :immediate)
    (let ((ourro.kernel:*automations-armed* nil))
      (ourro.automation:dispatch-event '(:kind :ping))
      (is (zerop (ourro.automation:firing-queue-length))))))

(test disarm-invalidates-queued-and-dequeued-firings
  (with-clean-reflexes
    (let ((ran nil))
      (reg-automation "r" '(:kind :ping)
                      (lambda (event) (declare (ignore event)) (setf ran t))
                      :defer :immediate :cooldown 0)
      (ourro.automation:dispatch-event '(:kind :ping))
      (let ((already-dequeued (ourro.automation::pop-firing)))
        (ourro.automation:dispatch-event '(:kind :ping))
        (is (= 1 (ourro.automation:firing-queue-length)))
        (ourro.automation:set-reflex-armed nil)
        (is (zerop (ourro.automation:firing-queue-length)))
        (ourro.automation::run-firing already-dequeued)
        (is-false ran)))))

(test disarm-wins-after-dequeued-firing-waits-politely
  (with-clean-reflexes
    (let ((ran nil))
      (reg-automation "r" '(:kind :ping)
                      (lambda (event) (declare (ignore event)) (setf ran t)))
      (let* ((firing (ourro.automation::make-firing
                      (ourro.automation:find-automation "r")
                      '(:kind :ping) :ping))
             (ourro.automation:*politeness-hook*
               (lambda () (ourro.automation:set-reflex-armed nil))))
        (ourro.automation::run-firing firing)
        (is-false ran)))))

(test disarm-never-waits-for-an-inflight-execution-lock-holder
  (with-clean-reflexes
    (let ((locked (bt:make-semaphore :name "execution-locked"))
          (release (bt:make-semaphore :name "execution-release")))
      (let ((holder
              (bt:make-thread
               (lambda ()
                 (bt:with-lock-held (ourro.automation::*execution-lock*)
                   (bt:signal-semaphore locked)
                   (bt:wait-on-semaphore release)))
               :name "test-long-investigation")))
        (unwind-protect
             (progn
               (is-true (bt:wait-on-semaphore locked :timeout 1))
               (let ((start (get-internal-real-time)))
                 (ourro.automation:set-reflex-armed nil)
                 (is (< (/ (- (get-internal-real-time) start)
                           internal-time-units-per-second)
                        0.25))))
          (bt:signal-semaphore release)
          (bt:join-thread holder))))))

(test reflex-worker-needs-explicit-experimental-flag
  (let ((ourro.automation::*experimental-reflexes-override* nil)
        (ourro.kernel:*automations-armed* nil))
    (is (null (ourro.automation:start-reflex-worker)))
    (is-false (ourro.automation:set-reflex-armed t))
    (is-false (ourro.automation:reflex-worker-running-p))))

(test dispatch-cascade-guard-suppresses-reentry
  (with-clean-reflexes
    (reg-automation "r" '(:kind :ping) (lambda (e) (declare (ignore e)))
                    :defer :immediate)
    ;; Inside an automation, an event the action logs must NOT re-dispatch.
    (let ((ourro.automation:*in-automation-context* t))
      (ourro.automation:dispatch-event '(:kind :ping))
      (is (zerop (ourro.automation:firing-queue-length))))))

(test staging-isolation-registration-does-not-leak
  (with-clean-reflexes
    ;; A candidate's load-time registration binds *automations* to a copy; the
    ;; live list is unaffected (the staging-leak mitigation).
    (let ((ourro.automation::*automations*
            (ourro.automation:copy-automations)))
      (reg-automation "staged" '(:kind :x) (lambda (e) (declare (ignore e))))
      (is-true (ourro.automation:find-automation "staged")))
    (is-false (ourro.automation:find-automation "staged"))))


(test turn-boundary-coalesces-many-into-one
  (with-clean-reflexes
    (reg-automation "r" '(:kind :edit) (lambda (e) (declare (ignore e)))
                    :defer :turn-boundary)
    ;; Three matching events within a turn → nothing queued yet (deferred).
    (dotimes (i 3) (ourro.automation:dispatch-event '(:kind :edit)))
    (is (zerop (ourro.automation:firing-queue-length)))
    ;; The turn boundary flushes exactly one coalesced firing.
    (is (= 1 (ourro.automation:flush-deferred-automations)))
    (is (= 1 (ourro.automation:firing-queue-length)))))

(test cooldown-suppresses-a-rapid-second-firing
  (with-clean-reflexes
    (reg-automation "r" '(:kind :ping) (lambda (e) (declare (ignore e)))
                    :defer :immediate :cooldown 30)
    (ourro.automation:dispatch-event '(:kind :ping))
    (is (= 1 (ourro.automation:firing-queue-length)))
    (ourro.automation::pop-firing)
    ;; A second match well inside the 30s cooldown is suppressed.
    (ourro.automation:dispatch-event '(:kind :ping))
    (is (zerop (ourro.automation:firing-queue-length)))))


(test probation-firing-error-auto-reverts
  (with-clean-reflexes
    (let* ((reverted nil)
           (ourro.kernel:*probation-failure-hook*
             (lambda (gene c) (declare (ignore gene c)) (setf reverted t))))
      (reg-automation "bad" '(:kind :ping)
                      (lambda (e) (declare (ignore e)) (error "boom"))
                      :gene "g/bad")
      (ourro.kernel:start-probation "g/bad")
      (ourro.automation::run-firing
       (ourro.automation::make-firing (ourro.automation:find-automation "bad")
                                     '(:kind :ping) :ping))
      ;; First error under probation reverts the gene immediately.
      (is-true reverted)
      (is-false (ourro.automation:find-automation "bad"))
      (ourro.kernel:clear-revert-records "g/bad"))))

