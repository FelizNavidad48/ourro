(in-package #:ourro.tests)

(def-suite invisible-evolution-suite :in ourro)
(in-suite invisible-evolution-suite)


(defmacro with-evo-home (&body body)
  (let ((home (gensym)))
    `(let* ((,home (uiop:ensure-directory-pathname
                    (merge-pathnames (format nil "ourro-evo-~A/" (ourro.util:make-id "h"))
                                     (uiop:temporary-directory))))
            (ourro.util::*ourro-home* ,home))
       (ensure-directories-exist (merge-pathnames "state/" ,home))
       (unwind-protect (progn ,@body)
         (ignore-errors
          (uiop:delete-directory-tree ,home :validate (constantly t)))))))

(defun call-event (tool args &optional (elapsed 100))
  (list :kind :tool-call :outcome :ok :tool tool :args args
        :elapsed-ms elapsed :time (ourro.util:iso-time)))


(test evolution-queue-survives-a-restart
  (with-evo-home
    (let ((ourro.observe::*evolution-queue* '()))
      (ourro.observe:enqueue-pattern (list :id "p1" :kind :repeated-command))
      (ourro.observe:enqueue-pattern (list :id "p2" :kind :repeated-command))
      ;; Simulate a restart: drop in-memory state, reload from the mirror.
      (setf ourro.observe::*evolution-queue* '())
      (is (= 2 (ourro.observe:load-evolution-queue)))
      (is (= 2 (ourro.observe:queue-length))))))


(test restart-allowed-p-decision-table
  ;; Never while busy or mid-input, any policy.
  (is-false (ourro.agent::restart-allowed-p :eager 1000 t   t   nil))
  (is-false (ourro.agent::restart-allowed-p :eager 1000 nil nil nil))
  ;; :eager — after 10 s idle.
  (is-true  (ourro.agent::restart-allowed-p :eager 15 nil t nil))
  (is-false (ourro.agent::restart-allowed-p :eager 5  nil t nil))
  ;; :calm — 5 min idle OR the dream window.
  (is-false (ourro.agent::restart-allowed-p :calm 120 nil t nil))
  (is-true  (ourro.agent::restart-allowed-p :calm 400 nil t nil))
  (is-true  (ourro.agent::restart-allowed-p :calm 60  nil t t))
  ;; :manual — never here (only /quit fires it).
  (is-false (ourro.agent::restart-allowed-p :manual 100000 nil t t)))


(defun verify-nonce-from-argv (argv)
  (second (member "--verify-nonce" argv :test #'string=)))

(defun proof-pass-output (source argv)
  "A coordinator-shaped PASS for the out-of-process runner seam."
  (let* ((artifact (ourro.txn:make-verification-artifact
                    :transaction-id "test-verify"
                    :source source :authority '()
                    :fingerprints '(:test t)
                    :stages '((:read :ok) (:test :ok))))
         (report (list :stages '((:read :ok) (:test :ok))
                       :transaction-id "test-verify"
                       :verification-artifact artifact
                       :proof-hash (getf artifact :proof-hash))))
    (format nil "<<<OURRO-VERIFY~%~S~%OURRO-VERIFY>>>"
            (list :verdict :pass :nonce (verify-nonce-from-argv argv)
                  :report
                  (ourro.verify.coordinator:encode-report-for-transport
                   report)))))

(defun fail-output (argv &key (stage :compile) (diagnostics "boom"))
  (format nil "<<<OURRO-VERIFY~%~S~%OURRO-VERIFY>>>"
          (list :verdict :fail :nonce (verify-nonce-from-argv argv)
                :stage stage :diagnostics diagnostics)))

(test verify-verdict-parser
  (let ((out (format nil "boot chatter~%<<<OURRO-VERIFY~%(:VERDICT :PASS)~%OURRO-VERIFY>>>~%tail")))
    (is (eq :pass (getf (ourro.evolve:parse-verify-verdict out) :verdict))))
  ;; No sentinels → NIL (caller rejects the candidate).
  (is (null (ourro.evolve:parse-verify-verdict "just some output"))))

(test out-of-process-verification-decision
  (let ((image "/home/u/.ourro/images/gen-0007")
        (dev "/usr/local/bin/sbcl"))
    ;; Built image, no hot-loads, mined → out-of-process.
    (is-true  (ourro.evolve:should-verify-out-of-process-p
               :deliberate nil :hot-loads 0 :argv0 image))
    ;; All production candidates stay outside the live image.
    (is-true (ourro.evolve:should-verify-out-of-process-p
              :deliberate t :hot-loads 0 :argv0 image))
    (is-true (ourro.evolve:should-verify-out-of-process-p
              :deliberate nil :hot-loads 2 :argv0 image))
    ;; make dev (no built image) → in-process.
    (is-false (ourro.evolve:should-verify-out-of-process-p
               :deliberate nil :hot-loads 0 :argv0 dev))))

(test verify-out-of-process-uses-the-runner-seam
  (let* ((seen nil)
        (ourro.evolve:*verify-runner*
          (lambda (argv)
            (setf seen argv)
            (fail-output argv))))
    (let ((verdict (ourro.evolve:verify-out-of-process
                    "(defgene x)" :argv0 "/x/images/gen-0001")))
      (is (eq :fail (getf verdict :verdict)))
      (is (string= "boom" (getf verdict :diagnostics)))
      (is-true (find "--verify-home" seen :test #'string=))
      (is-true (find-if (lambda (arg)
                          (and (stringp arg)
                               (string-prefix-p "OURRO_HOME=" arg)))
                        seen)))))

(test verify-mined-block-out-of-process-pass-parses-gene
  ;; Eligible → the child verdict is authoritative; on :pass the live image only
  ;; parses the gene (the staged tests already ran in the child).
  (with-evo-home
    (let* ((block (ourro.evolve:extract-gene-block +proposed-gene+))
           (ourro.evolve:*verify-runner*
             (lambda (argv) (proof-pass-output block argv))))
      (multiple-value-bind (gene report)
          (ourro.evolve:verify-mined-block
           block :argv0 "/x/images/gen-0001" :hot-loads 0)
        (is (string= "tool/word-count" (ourro.genome:gene-name gene)))
        (is-true (getf report :out-of-process))
        (is (probe-file
             (ourro.txn:verification-artifact-path
              (getf report :proof-hash))))))))

(test verify-mined-block-out-of-process-fail-signals-verification-failure
  ;; A :fail verdict maps onto the SAME condition the in-process path signals,
  ;; so propose-gene's repair loop is unchanged.
  (let ((block (ourro.evolve:extract-gene-block +proposed-gene+))
        (ourro.evolve:*verify-runner*
          (lambda (argv) (fail-output argv))))
    (signals ourro.kernel:verification-failure
      (ourro.evolve:verify-mined-block block :argv0 "/x/images/gen-0001" :hot-loads 0))))

(test verify-mined-block-nil-verdict-fails-closed
  ;; Infrastructure failure is not permission to execute the candidate in the
  ;; live image.
  (let ((block (ourro.evolve:extract-gene-block +proposed-gene+))
        (ourro.evolve:*verify-runner*
          (lambda (argv) (declare (ignore argv)) "garbage, no sentinels")))
    (signals ourro.kernel:verification-failure
      (ourro.evolve:verify-mined-block
       block :argv0 "/x/images/gen-0001" :hot-loads 0))))

(test verify-verdict-parser-rejects-spoofed-duplicates
  (is (null (ourro.evolve:parse-verify-verdict
             (format nil "<<<OURRO-VERIFY~%(:verdict :pass)~%OURRO-VERIFY>>>~%~
<<<OURRO-VERIFY~%(:verdict :fail :stage :lint)~%OURRO-VERIFY>>>")))))

(test dedicated-verdict-channel-is-canonical-and-nonce-bound
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames
                (format nil "ourro-verdict-test-~A/" (ourro.util:make-id "v"))
                (uiop:temporary-directory))))
         (path (merge-pathnames "verdict.csexp" dir)))
    (unwind-protect
         (progn
           (ensure-directories-exist path)
           (ourro.main::write-verdict-file
            path '(:verdict :pass :nonce "right" :report "proof"))
           (is (eq :pass
                   (getf (ourro.evolve::read-verdict-channel path "right")
                         :verdict)))
           (is (null (ourro.evolve::read-verdict-channel path "wrong"))))
      (ignore-errors
       (uiop:delete-directory-tree dir :validate (constantly t))))))

(test verify-mined-block-not-eligible-uses-in-process
  ;; make dev (argv0 is bare sbcl, no built image) → in-process, runner untouched.
  (let* ((block (ourro.evolve:extract-gene-block +proposed-gene+))
         (ran nil)
        (ourro.evolve:*verify-runner* (lambda (argv) (declare (ignore argv)) (setf ran t) "")))
    (let ((gene (ourro.evolve:verify-mined-block
                 block :argv0 "/usr/bin/sbcl" :hot-loads 0)))
      (is (string= "tool/word-count" (ourro.genome:gene-name gene)))
      (is-false ran))))

(test sandbox-exec-profile-permits-exec
  ;; Regression for F-outproc: a version-1 seatbelt profile built from only
  ;; deny clauses defaults to deny-all, which denies process-exec itself so
  ;; sandbox-exec fails before the child runs — every candidate then rejected
  ;; with no verdict. The profile MUST open with (allow default) and keep the
  ;; durable protection, (deny network*), while NOT jailing file-writes.
  (let ((cmd (ourro.evolve::sandbox-exec-command
              "/x/images/gen-0001" #P"/tmp/c.gene" #P"/tmp/vg/")))
    (when cmd                           ; only asserted where sandbox-exec exists
      (let ((profile (nth (1+ (position "-p" cmd :test #'string=)) cmd)))
        (is (search "(allow default)" profile))
        (is (search "(deny network*)" profile))
        (is (null (search "(deny file-write*)" profile))))))
  ;; A launcher failure (wrapper could not exec the child) is distinguishable
  ;; from a verdict produced by a child that actually ran.
  (is-true (ourro.evolve::sandbox-launcher-failed-p
            "sandbox-exec: execvp() of '/usr/bin/env' failed: Operation not permitted"))
  (is-false (ourro.evolve::sandbox-launcher-failed-p
             (format nil "<<<OURRO-VERIFY~%(:VERDICT :PASS)~%OURRO-VERIFY>>>"))))

(test verify-out-of-process-degrades-when-wrapper-cannot-launch
  ;; When the OS sandbox wrapper cannot even exec the child, fall back to the
  ;; unwrapped child (Lisp capability ceiling still applies) rather than veto a
  ;; sound gene — the F-outproc robustness guarantee.
  (if (ourro.evolve::sandbox-exec-command
       "/x/images/gen-0001" #P"/tmp/c.gene" #P"/tmp/vg/")
      (let* ((calls 0)
             (ourro.evolve:*verify-runner*
               (lambda (argv)
                 (incf calls)
                 (if (= calls 1)
                     "sandbox-exec: execvp() of '/usr/bin/env' failed: Operation not permitted"
                     (proof-pass-output "(defgene x)" argv)))))
        (let ((v (ourro.evolve:verify-out-of-process
                  "(defgene x)" :argv0 "/x/images/gen-0001")))
          (is (= 2 calls))              ; retried unwrapped
          (is (eq :pass (getf v :verdict)))))
      ;; no sandbox-exec on this platform → nothing to wrap, no fallback branch
      (let ((ourro.evolve:*verify-runner*
              (lambda (argv)
                (proof-pass-output "(defgene x)" argv))))
        (is (eq :pass (getf (ourro.evolve:verify-out-of-process
                             "(defgene x)" :argv0 "/x/images/gen-0001")
                            :verdict))))))

(test hot-load-advances-the-staleness-counter
  ;; The counter that forces in-process verification once the live image is ahead.
  (let ((before ourro.genome:*hot-loads-since-boot*))
    (ourro.genome:hot-load-gene
     (ourro.evolve:extract-gene-block +proposed-gene+))
    (unwind-protect
         (is (= (1+ before) ourro.genome:*hot-loads-since-boot*))
      (ourro.tools:unregister-tool "word_count"))))


(test slow-tool-median-helper
  (is (= 3000 (ourro.miner::median-elapsed
               (list (call-event "t" nil 1000) (call-event "t" nil 3000)
                     (call-event "t" nil 5000)))))
  (is (= 4000 (ourro.miner::median-elapsed
               (list (call-event "t" nil 3000) (call-event "t" nil 5000))))))

(test slow-tool-miner-flags-slow-groups
  (let ((slow (list (call-event "shell" '(:command "big build") 4000)
                    (call-event "shell" '(:command "big build") 5000)
                    (call-event "shell" '(:command "big build") 6000))))
    (let ((pats (ourro.miner::mine-slow-tools slow)))
      (is (= 1 (length pats)))
      (is (eq :slow-tool (pget (first pats) :kind)))
      (is (equal '("shell") (pget (first pats) :tools)))
      ;; benefit-to-beat is the measured median (5000), not a guess
      (is (= 5000 (pget (first pats) :occurrence-cost-ms))))))

(test slow-tool-miner-ignores-fast-and-thin-groups
  ;; Fast calls → nothing.
  (is (null (ourro.miner::mine-slow-tools
             (list (call-event "read_file" '(:path "a") 50)
                   (call-event "read_file" '(:path "a") 60)
                   (call-event "read_file" '(:path "a") 70)))))
  ;; Slow but too few (support < 3) → nothing.
  (is (null (ourro.miner::mine-slow-tools
             (list (call-event "shell" '(:command "x") 9000)
                   (call-event "shell" '(:command "x") 9000))))))


(test handoff-carries-ring-and-evolution-clock
  (with-evo-home
    (let ((agent (ourro.agent::make-agent
                  :provider (ourro.llm:make-scripted-provider '()))))
      (setf (ourro.agent::agent-tool-results agent)
            (list (list :n 5 :name "read_file" :result "some output"
                        :error-p nil :ms 12))
            (ourro.agent::agent-tool-result-count agent) 5
            ourro.evolve:*last-evolution-time* 424242)
      ;; Build the payload while the clock reads 424242 (before shadowing it).
      (let* ((payload (ourro.agent::session-payload agent))
             (extra (pget payload :extra)))
        (is (= 5 (pget (first (pget extra :ring)) :n)))
        (is (= 5 (pget extra :ring-count)))
        (is (= 424242 (pget extra :last-evolution-time)))
        ;; Restore into a fresh agent with the clock reset — restore must set it.
        (let ((fresh (ourro.agent::make-agent
                      :provider (ourro.llm:make-scripted-provider '())))
              (ourro.evolve:*last-evolution-time* 0))
          (ourro.agent::restore-session fresh payload)
          (is (= 5 (ourro.agent::agent-tool-result-count fresh)))
          (is (= 5 (pget (first (ourro.agent::agent-tool-results fresh)) :n)))
          (is (= 424242 ourro.evolve:*last-evolution-time*)))))))
