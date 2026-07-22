(in-package #:ourro.tests)

(def-suite evolve-suite :in ourro)
(in-suite evolve-suite)

(defparameter +proposed-gene+
  "<gene>
(defgene tool/word-count
    (:generation 2 :parent nil :capabilities (:filesystem-read)
     :provenance (:pattern \"pat-test\" :model \"scripted\"))
  (:doc \"Count the lines in a workspace file.\")
  (:code
   (deftool word-count
       ((path :string \"File to count lines in\" :required t))
     (:doc \"Return the number of lines in PATH.\")
     (:contract (:pre ((stringp path)) :post ((stringp result))))
     (format nil \"~A\" (length (split-lines (read-file-numbered path))))))
  (:tests
   (test word-count/counts
     (let ((p (workspace-path \"wc-test.txt\")))
       (cap/write-file p (format nil \"a~%b~%c~%\"))
       (let ((h (make-hash-table :test (quote equal))))
         (setf (gethash \"path\" h) \"wc-test.txt\")
         (is (stringp (run-tool (find-tool \"word_count\") h))))
       (cap/delete-file p)))))
</gene>")

(test extract-gene-block
  (let ((block (ourro.evolve:extract-gene-block +proposed-gene+)))
    (is (search "defgene tool/word-count" block))
    (is (not (search "<gene>" block)))))

(defclass throttling-provider (ourro.llm:provider)
  ((calls :initform 0 :accessor throttling-calls))
  (:default-initargs :model "throttled")
  (:documentation "Always 429s with a *retryable* provider-error — exercises the
sustained-throttle defer path (F-evolver-429)."))

(defmethod ourro.llm:complete ((provider throttling-provider)
                              system-prompt messages tools &key on-event)
  (declare (ignore system-prompt messages tools on-event))
  (incf (throttling-calls provider))
  (error 'ourro.llm:provider-error
         :message "Bedrock request failed (429): Too many requests"
         :status 429 :retryable-p t))

(defun drain-evolution-queue ()
  (loop while (plusp (ourro.observe:queue-length))
        do (ourro.observe:dequeue-pattern)))

(test propose-gene-defers-on-sustained-throttle
  ;; A 429 that outlasts COMPLETE-WITH-RETRY's whole backoff ride must NOT burn
  ;; the pattern or surface as an "evolver error": the candidate is :deferred
  ;; and the pattern is shelved back on the queue for a later retry
  ;; (F-evolver-429).
  (let* ((ourro.llm:*retry-max-attempts* 1)  ; re-signal at once — no test sleeps
         (provider (make-instance 'throttling-provider))
         (pattern (list :id "pat-throttle" :kind :repeated-command
                        :tools '("read_file") :count 3 :evidence '())))
    (drain-evolution-queue)
    (let ((candidate (ourro.kernel:with-capabilities '(:llm)
                       (ourro.evolve:propose-gene provider pattern))))
      (is (eq :deferred (ourro.evolve:candidate-status candidate)))
      ;; Shelved back exactly once, ready for a later evolver pass.
      (is (= 1 (ourro.observe:queue-length)))
      (is (equal "pat-throttle"
                 (getf (ourro.observe:dequeue-pattern) :id))))
    (drain-evolution-queue)))

(test propose-gene-non-retryable-error-still-burns
  ;; A NON-retryable provider error (e.g. a 400 rejecting the request) is a real
  ;; failure, not a throttle: it stays :error and is NOT re-queued — otherwise a
  ;; genuinely broken pattern would loop forever.
  (let* ((provider (ourro.llm:make-scripted-provider '()))
         (pattern (list :id "pat-hard-error" :kind :repeated-command
                        :tools '("read_file") :count 3 :evidence '())))
    (drain-evolution-queue)
    (let ((candidate (ourro.kernel:with-capabilities '(:llm)
                       (ourro.evolve:propose-gene provider pattern))))
      ;; The scripted provider exhausts immediately with a non-retryable error.
      (is (eq :error (ourro.evolve:candidate-status candidate)))
      (is (zerop (ourro.observe:queue-length))))
    (drain-evolution-queue)))

(test propose-gene-verifies
  (let* ((provider (ourro.llm:make-scripted-provider (list +proposed-gene+)))
         (pattern (list :id "pat-test" :kind :repeated-command
                        :tools '("read_file") :count 3 :evidence '()))
         (candidate (ourro.kernel:with-capabilities '(:llm)
                      (ourro.evolve:propose-gene provider pattern))))
    (is (eq :verified (ourro.evolve:candidate-status candidate)))
    (is (string= "tool/word-count"
                 (ourro.genome:gene-name (ourro.evolve:candidate-gene candidate))))
    ;; Not yet in the live registry — proposal doesn't apply.
    (is (null (ourro.tools:find-tool "word_count")))))

(test apply-candidate-requires-authoritative-proof
  (let* ((source (ourro.evolve:extract-gene-block +proposed-gene+))
         (gene (ourro.genome:parse-gene-source source))
         (candidate (make-instance 'ourro.evolve:evolution-candidate
                                   :pattern '(:id "forged")
                                   :gene gene :source source)))
    (setf (ourro.evolve:candidate-status candidate) :verified)
    (ourro.evolve:apply-candidate candidate :force t :snapshot :none)
    (is (eq :rejected (ourro.evolve:candidate-status candidate)))
    (is (search "authoritative verification proof"
                (ourro.evolve:candidate-diagnostics candidate)))))

(test stateful-candidate-cannot-use-hot-load-fast-path
  (let* ((source
           "(defgene state/schema
                (:generation 1 :capabilities ())
              (:doc \"Stateful fixture.\")
              (:code (defvar schema-state 1))
              (:tests (test schema/t (is-true t))))")
         (gene (ourro.genome:parse-gene-source source))
         (candidate (make-instance 'ourro.evolve:evolution-candidate
                                   :pattern '(:id "stateful")
                                   :gene gene :source source)))
    (setf (ourro.evolve:candidate-status candidate) :verified)
    (ourro.evolve:apply-candidate candidate :force t :snapshot :none)
    (is (eq :rejected (ourro.evolve:candidate-status candidate)))
    (is (search "versioned schema"
                (ourro.evolve:candidate-diagnostics candidate)))))

(test background-evolver-starts-by-default
  (let* ((agent (ourro.agent::make-agent
                 :provider (ourro.llm:make-scripted-provider '())))
         (worker (ourro.agent::spawn-evolver agent)))
    (is-true worker)
    (bt:join-thread worker)))

(test propose-gene-repairs-on-bad-output
  ;; First response has no gene; second is valid. The repair loop recovers.
  (let* ((provider (ourro.llm:make-scripted-provider
                    (list "I think we should add a tool."
                          +proposed-gene+)))
         (pattern (list :id "pat-repair" :kind :repeated-command
                        :tools '("read_file") :count 3 :evidence '()))
         (candidate (ourro.kernel:with-capabilities '(:llm)
                      (ourro.evolve:propose-gene provider pattern))))
    (is (eq :verified (ourro.evolve:candidate-status candidate)))))

(test harness-manual-mentions-capabilities
  (let ((manual (ourro.evolve:harness-manual)))
    (is (search "filesystem-write" manual))
    (is (search "DEFTOOL" manual))
    ;; PR-9: the manual reflects live tools by name.
    (is (search "read-file" (string-downcase manual)))))


(test api-surface-lists-macros
  (let ((surface (string-downcase (ourro.evolve:api-surface-description))))
    ;; DEFTOOL and DEFGENE were previously invisible to the evolver.
    (is (search "deftool" surface))
    (is (search "defgene" surface))
    (is (search "[macro]" surface))))

(test nearest-genes-prefers-shared-tools
  (ensure-seed-genome-loaded)
  (let* ((pattern (list :id "p" :kind :repeated-command
                        :tools '("read_file") :count 3 :evidence '()))
         (nearest (ourro.evolve::nearest-genes pattern :limit 2)))
    ;; The gene actually defining read_file must rank first.
    (is (string= "tool/read-file"
                 (ourro.genome:gene-name (first nearest))))))

(test hot-load-clears-manual-cache
  ;; PR-9: the cached manual cannot survive a redefinition.
  (setf ourro.evolve:*evolution-system-prompt* "STALE CACHED MANUAL")
  (unwind-protect
       (progn
         (ourro.genome:hot-load-gene
          (ourro.evolve:extract-gene-block +proposed-gene+))
         (is (null ourro.evolve:*evolution-system-prompt*)))
    (ourro.tools:unregister-tool "word_count")
    (setf ourro.evolve:*evolution-system-prompt* nil)))

(test harvest-exemplars-from-events
  (let ((ourro.observe::*recent-events* '())
        (ourro.observe::*event-log-path* nil))
    (ourro.observe:log-event :tool-call :tool "read_file"
                                       :args '(:path "a") :outcome :ok)
    (ourro.observe:log-event :tool-call :tool "read_file"
                                       :args '(:path "b") :outcome :error)
    (ourro.observe:log-event :tool-call :tool "shell"
                                       :args '(:command "ls") :outcome :ok)
    (let ((exemplars (ourro.evolve::harvest-exemplars
                      (list :tools '("read_file")))))
      ;; Only the successful read_file call is harvested.
      (is (= 1 (length exemplars)))
      (is (string= "read_file" (first (first exemplars)))))))

(test apply-candidate-hot-loads
  (let* ((provider (ourro.llm:make-scripted-provider (list +proposed-gene+)))
         (pattern (list :id "pat-apply" :kind :repeated-command
                        :tools '("read_file") :count 3 :evidence '()))
         (ourro.evolve:*last-evolution-time* 0)
         (ourro.evolve::*snapshot-hook* nil)
         (candidate (ourro.kernel:with-capabilities '(:llm)
                      (ourro.evolve:propose-gene provider pattern))))
    (ourro.evolve:apply-candidate candidate :force t)
    (is (member (ourro.evolve:candidate-status candidate)
                '(:hot-loaded :snapshotted)))
    ;; Now the tool is live.
    (is-true (ourro.tools:find-tool "word_count"))
    ;; Clean up so other tests don't see it.
    (ourro.tools:unregister-tool "word_count")))

(test mined-snapshot-runs-async-off-the-evolver-thread
  ;; P0-3: the mined path (process-evolution-queue) must snapshot :async — the
  ;; candidate hot-loads immediately and the minutes-long image build runs on a
  ;; worker thread, so ourro-evolver is never stalled on it. We block the snapshot
  ;; hook and prove the queue drain returns with the candidate merely :hot-loaded;
  ;; releasing the hook lets it reach :snapshotted. (A sync regression would call
  ;; the hook inline; the hook's own timeout then returns an id and the drain
  ;; yields :snapshotted — failing the :hot-loaded assertion cleanly rather than
  ;; hanging.)
  (let* ((provider (ourro.llm:make-scripted-provider (list +proposed-gene+)))
         (pattern (list :id "pat-async" :kind :repeated-command
                        :tools '("read_file") :count 3 :evidence '()))
         (ourro.observe::*evolution-queue* '())
         (ourro.evolve:*last-evolution-time* 0)
         (gate (bt:make-semaphore))
         (applied nil)                  ; on-applied must fire only AFTER snapshot
         (saved-hook ourro.evolve::*snapshot-hook*))
    ;; The snapshot runs on a fresh thread, which does NOT inherit a dynamic
    ;; LET binding of this special — set the GLOBAL (as the live agent does)
    ;; so the ourro-snapshot worker actually sees the hook.
    (setf ourro.evolve::*snapshot-hook*
          (lambda (changes message provenance)
            (declare (ignore changes message provenance))
            (bt:wait-on-semaphore gate :timeout 10)
            "gen-0099"))
    (unwind-protect
         (progn
           (ourro.observe:enqueue-pattern pattern)
           (let ((candidates
                   (ourro.kernel:with-capabilities '(:llm)
                     (ourro.evolve::process-evolution-queue
                      provider :max 1 :auto-apply t
                      :on-applied (lambda (c) (setf applied c))))))
             (is (= 1 (length candidates)))
             (let ((candidate (first candidates)))
               ;; Drain returned while the build is still blocked in the hook.
               (is (eq :hot-loaded (ourro.evolve:candidate-status candidate)))
               ;; The regression guard: on-applied has NOT fired yet — announce
               ;; (and the generation-restart arming) must wait for the snapshot,
               ;; or it would run while generation-id is still NIL and the mined
               ;; gene would never advance the generation.
               (is (null applied))
               ;; Release the build; the candidate advances to :snapshotted.
               (bt:signal-semaphore gate)
               (loop repeat 100
                     until (eq (ourro.evolve:candidate-status candidate) :snapshotted)
                     do (sleep 0.05))
               (is (eq :snapshotted (ourro.evolve:candidate-status candidate)))
               (is (string= "gen-0099"
                            (ourro.evolve:candidate-generation-id candidate)))
               ;; A durable generation is not published/handed off until three
               ;; successful live uses graduate probation.
               (is (null applied))
               (dotimes (i 3)
                 (ourro.kernel:with-probation ("tool/word-count") :ok))
               (loop repeat 100 until applied do (sleep 0.05))
               (is (eq applied candidate))
               (is (string= "gen-0099"
                            (ourro.evolve:candidate-generation-id applied))))))
      (bt:signal-semaphore gate)          ; never leave the worker blocked
      (setf ourro.evolve::*snapshot-hook* saved-hook)
      (ignore-errors (ourro.tools:unregister-tool "word_count")))))
