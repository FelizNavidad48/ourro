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

(test three-strikes-post-probation-reverts
  (with-clean-reflexes
    (let* ((amber 0)
           (ourro.kernel:*probation-failure-hook*
             (lambda (gene c) (declare (ignore gene c)) (incf amber))))
      (reg-automation "flaky" '(:kind :ping)
                      (lambda (e) (declare (ignore e)) (error "boom"))
                      :gene "g/flaky")
      ;; Not on probation → errors accumulate strikes; the 3rd retires it.
      (let ((a (ourro.automation:find-automation "flaky")))
        (dotimes (i 3)
          (ourro.automation::run-firing
           (ourro.automation::make-firing a '(:kind :ping) :ping))))
      (is (= 1 amber))
      (is-false (ourro.automation:find-automation "flaky"))
      (ourro.kernel:clear-revert-records "g/flaky"))))

(test firing-timeout-accrues-a-strike-not-silently-lost
  ;; A firing that exceeds the watchdog is a SERIOUS-CONDITION, not an ERROR;
  ;; run-firing must convert it so it strikes (and logs) rather than vanishing.
  (with-clean-reflexes
    (let ((ourro.automation:*automation-timeout-seconds* 0.05))
      (reg-automation "slow" '(:kind :ping)
                      (lambda (e) (declare (ignore e)) (sleep 0.5))
                      :gene "g/slow")
      (let ((a (ourro.automation:find-automation "slow")))
        (ourro.automation::run-firing
         (ourro.automation::make-firing a '(:kind :ping) :ping))
        (is (= 1 (ourro.automation:automation-strikes a)))))))

(test firing-timeout-under-probation-reverts
  (with-clean-reflexes
    (let* ((ourro.automation:*automation-timeout-seconds* 0.05)
           (reverted nil)
           (ourro.kernel:*probation-failure-hook*
             (lambda (g c) (declare (ignore g c)) (setf reverted t))))
      (reg-automation "slowp" '(:kind :ping)
                      (lambda (e) (declare (ignore e)) (sleep 0.5))
                      :gene "g/slowp")
      (ourro.kernel:start-probation "g/slowp")
      (ourro.automation::run-firing
       (ourro.automation::make-firing (ourro.automation:find-automation "slowp")
                                     '(:kind :ping) :ping))
      ;; A probation-phase hang reverts immediately, exactly like an error.
      (is-true reverted)
      (is-false (ourro.automation:find-automation "slowp"))
      (ourro.kernel:clear-revert-records "g/slowp"))))


(test walker-requires-automate-capability
  ;; DEFINE-AUTOMATION without :automate → a violation; with it → clean.
  (is-true (ourro.kernel:lint-gene-body
            '((define-automation x (:on (:kind :foo)) (post-note "hi")))
            :capabilities '(:observe)))
  (is-false (ourro.kernel:lint-gene-body
             '((define-automation x (:on (:kind :foo)) (post-note "hi")))
             :capabilities '(:observe :automate))))

(test walker-allows-keywords-named-like-forbidden-operators
  ;; A trigger pattern's :exit / :load / :search key is inert data, never a call
  ;; to EXIT / LOAD / SEARCH — the walker must not reject it (regression: the
  ;; sentinel's (:exit (:not 0)) tripped the forbidden-name rule).
  (is-false (ourro.kernel:lint-gene-body
             '((define-automation r
                   (:on (:kind :job-exit :exit (:not 0) :load 1 :search "x"))
                 (post-note "x")))
             :capabilities '(:observe :automate))))

(test structure-check-rejects-malformed-triggers
  ;; No :on pattern.
  (is-true (ourro.verify::validate-automation-form
            '(define-automation x () (post-note "hi"))))
  ;; No :kind and not idle/every.
  (is-true (ourro.verify::validate-automation-form
            '(define-automation x (:on (:tool "edit")) (post-note "hi"))))
  ;; Empty body.
  (is-true (ourro.verify::validate-automation-form
            '(define-automation x (:on (:kind :job-exit)))))
  ;; Well-formed → NIL (no problem).
  (is-false (ourro.verify::validate-automation-form
             '(define-automation x (:on (:kind :job-exit) :cooldown 10)
               (post-note "hi"))))
  (is-false (ourro.verify::validate-automation-form
             '(define-automation x (:on (:idle 300)) (post-note "hi")))))


(test ledger-counts-automation-firings
  (with-clean-reflexes
    (ourro.observe::record-gene-use-from-event
     '(:kind :automation-fire :gene "g/reflex" :elapsed-ms 5 :outcome :ok))
    (ourro.observe::record-gene-use-from-event
     '(:kind :automation-fire :gene "g/reflex" :elapsed-ms 7 :outcome :error))
    (is (= 1 (ourro.observe:gene-uses "g/reflex")))
    (is (= 1 (pget (ourro.observe:gene-utility "g/reflex") :errors)))))


(test post-note-queues-and-tickers
  (with-clean-reflexes
    (let* ((tickered nil)
           (ourro.automation:*note-sink*
             (lambda (text style) (declare (ignore style)) (setf tickered text))))
      (ourro.automation:post-note "server died" :style :warning)
      (is (string= "server died" tickered))          ; ticker channel
      (is (= 1 (ourro.automation:pending-note-count)))
      (is (equal '("server died") (ourro.automation:drain-notes)))  ; message channel
      (is (zerop (ourro.automation:pending-note-count))))))



(defun ev-tool (tool args &optional (ms 100))
  (call-event tool args ms))

(defun ev-jobexit (id exit)
  (list :kind :job-exit :job id :exit exit :time (ourro.util:iso-time)))


(test mine-reactions-finds-a-b-pairs-and-derives-the-trigger
  (let* ((oldest (loop repeat 3
                       append (list (ev-tool "edit_file" '(:path "a.lisp"))
                                    (ev-tool "shell" '(:command "make test") 500))))
         (pats (ourro.miner:mine-reactions (reverse oldest))))   ; recent-events order
    (is (= 1 (length pats)))
    (let ((p (first pats)))
      (is (eq :reaction (pget p :kind)))
      (is (equal '("shell") (pget p :tools)))
      (is (eq :tool-call (pget (pget p :trigger-shape) :kind)))
      (is (string= "edit_file" (pget (pget p :trigger-shape) :tool)))
      ;; the constant :path is kept in the derived trigger (skeleton derivation)
      (is (equal '(:path "a.lisp") (pget (pget p :trigger-shape) :args)))
      ;; benefit-to-beat is the measured mean B cost, not a guess
      (is (= 500 (pget p :occurrence-cost-ms))))))

(test mine-reactions-counts-independent-episodes-not-triggers
  ;; Three edits before ONE test run is ONE reaction episode, not three — each
  ;; B is consumed once, so support < threshold and nothing is mined (review F1).
  (let* ((oldest (list (ev-tool "edit_file" '(:path "a.lisp"))
                       (ev-tool "edit_file" '(:path "b.lisp"))
                       (ev-tool "edit_file" '(:path "c.lisp"))
                       (ev-tool "shell" '(:command "make test") 500)))
         (pats (ourro.miner:mine-reactions (reverse oldest))))
    (is (null pats))))

(test mine-reactions-job-exit-as-trigger
  (let* ((oldest (loop repeat 3
                       append (list (ev-jobexit "j1" 1)
                                    (ev-tool "read_file" '(:path "log.txt")))))
         (pats (ourro.miner:mine-reactions (reverse oldest))))
    (is (= 1 (length pats)))
    (is (equal '(:kind :job-exit :exit (:not 0))
               (pget (first pats) :trigger-shape)))))

(test mine-reactions-respects-the-window
  (let ((ourro.miner:*reaction-window* 2))
    ;; A job-exit A, then two non-tool events, then the tool-call B at offset 3
    ;; (> window 2) → no pair mined.
    (let ((oldest (loop repeat 3
                        append (list (ev-jobexit "j" 1)
                                     (list :kind :other :time "t")
                                     (list :kind :other :time "t")
                                     (ev-tool "read_file" '(:path "x"))))))
      (is (null (ourro.miner:mine-reactions (reverse oldest)))))))

(test reaction-signature-includes-the-trigger-shape
  ;; Two reactions with the same action but different triggers are distinct.
  (let ((a (list :kind :reaction :tools '("shell")
                 :trigger-shape '(:kind :tool-call :tool "edit_file")))
        (b (list :kind :reaction :tools '("shell")
                 :trigger-shape '(:kind :tool-call :tool "write_file"))))
    (is (not (string= (ourro.miner:pattern-signature a)
                      (ourro.miner:pattern-signature b))))))


(defparameter +auto-gene-src+
  "(defgene x/reflex (:capabilities (:observe :automate) :provenance (:seed nil))
     (:doc \"d\")
     (:code (define-automation r (:on (:kind :job-exit)) (post-note \"hi\")))
     (:tests (test t1 (is (= 1 1)))))")

(defun make-candidate (gene-source origin)
  (let ((c (make-instance 'ourro.evolve:evolution-candidate
                          :pattern (list :origin origin))))
    (setf (ourro.evolve:candidate-gene c) (ourro.genome:parse-gene-source gene-source)
          (ourro.evolve:candidate-status c) :verified)
    c))

(test should-stage-only-mined-automation-candidates
  (let ((auto (make-candidate +auto-gene-src+ :mined))
        (tool (make-candidate (ourro.evolve:extract-gene-block +proposed-gene+) :mined))
        (delib (make-candidate +auto-gene-src+ :deliberate)))
    (is-true (ourro.evolve:candidate-registers-automations-p auto))
    (is-false (ourro.evolve:candidate-registers-automations-p tool))
    ;; a mined reflex stages; a mined tool applies; a deliberate reflex applies.
    (is-true (ourro.evolve:should-stage-p auto))
    (is-false (ourro.evolve:should-stage-p tool))
    (is-false (ourro.evolve:should-stage-p delib))))


(test ticker-command-for-key-dispatches-triples
  (let ((actions '((#\y "y install" :install-staged)
                   (#\n "n dismiss" :dismiss-staged))))
    (is (eq :install-staged (ourro.agent::ticker-command-for-key actions #\y)))
    (is (eq :dismiss-staged (ourro.agent::ticker-command-for-key actions #\n)))
    (is (null (ourro.agent::ticker-command-for-key actions #\z)))
    ;; legacy plain-string actions stay display-only (no key dispatch)
    (is (null (ourro.agent::ticker-command-for-key '("e explain") #\e)))
    ;; case-sensitive (review F2): capital E stays an ordinary character
    (is (eq :install-staged (ourro.agent::ticker-command-for-key actions #\y)))
    (is (null (ourro.agent::ticker-command-for-key actions #\Y)))))

(test ticker-action-label-handles-strings-and-triples
  (is (string= "y install" (ourro.tui::ticker-action-label '(#\y "y install" :x))))
  (is (string= "e explain" (ourro.tui::ticker-action-label "e explain"))))


(test workspace-memory-round-trip
  (with-evo-home
    (is-false (ourro.observe:workspace-known-p "/repo/a"))
    (ourro.observe:remember-workspace "/repo/a")
    (is-true (ourro.observe:workspace-known-p "/repo/a"))
    (is-false (ourro.observe:workspace-known-p "/repo/b"))
    ;; idempotent
    (ourro.observe:remember-workspace "/repo/a")
    (is-true (ourro.observe:workspace-known-p "/repo/a"))))

(test tick-fires-idle-once-per-idle-stretch
  (with-clean-reflexes
    (reg-automation "idler" '(:idle 300) (lambda (e) (declare (ignore e))))
    ;; Below the threshold: nothing, and it stays armed.
    (ourro.automation:tick-automations 100)
    (is (zerop (ourro.automation:firing-queue-length)))
    ;; Past the threshold: one firing.
    (ourro.automation:tick-automations 400)
    (is (= 1 (ourro.automation:firing-queue-length)))
    ;; Still idle: it does NOT re-fire (armed only once per idle stretch).
    (ourro.automation:tick-automations 500)
    (is (= 1 (ourro.automation:firing-queue-length)))
    ;; Activity resets idle, re-arming; a later idle fires again.
    (ourro.automation:tick-automations 10)
    (ourro.automation:tick-automations 400)
    (is (= 2 (ourro.automation:firing-queue-length)))))
