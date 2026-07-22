
(defpackage #:ourro.verify
  (:use #:cl #:ourro.util)
  (:import-from #:ourro.kernel
                #:safe-read-form
                #:lint-gene-body
                #:lint-violations
                #:verification-failure
                #:unsafe-form-error
                #:capability-p
                #:+all-capabilities+
                #:with-capabilities)
  (:import-from #:ourro.genome
                #:gene #:gene-name #:gene-capabilities #:gene-code-forms
                #:gene-test-forms #:gene-doc #:gene-suite-name #:gene-determinism
                #:parse-gene-form #:parse-gene-source)
  (:export #:verify-gene-text
           #:*test-timeout-seconds*
           #:fail-verification))

(in-package #:ourro.verify)

(defparameter *test-timeout-seconds* 30)

(defparameter *test-capability-ceiling*
  '(:filesystem-read :filesystem-write :observe)
  "The capabilities a candidate's tests may actually exercise. Verification is
observational: :subprocess and :network are withheld even from a gene that
declares them, so tests must fake those host effects rather than perform them.")

(defun withheld-capability-hint (gene report)
  "When a test REPORT failed on a capability the GENE declared but the
observational ceiling withholds (:subprocess/:network), return a one-line hint
so the repair loop fixes the TEST (fake the effect) instead of chasing a
phantom missing declaration — the raw CAPABILITY-VIOLATION reads 'requires
undeclared capability' even though the gene did declare it. NIL otherwise."
  (let ((withheld (set-difference (gene-capabilities gene)
                                  *test-capability-ceiling*)))
    (when (and withheld (search "CAPABILITY-VIOLATION" report))
      (format nil "~%Note: verification withholds ~{~(~S~)~^, ~} even though ~
the gene declares ~:[it~;them~] — tests run observationally and must not ~
perform real host effects. Fake the ~:*~:[call~;calls~] in the test instead ~
of invoking cap/run-program or cap/http-request."
              withheld (cdr withheld)))))

(defun fail-verification (stage diagnostics &rest args)
  (error 'verification-failure
         :stage stage
         :diagnostics (if args
                          (apply #'format nil diagnostics args)
                          diagnostics)))


(defun make-scratch-package ()
  (make-package (format nil "GEN-CANDIDATE-~A" (string-upcase (make-id "c")))
                :use '(#:ourro.api)))

(defun delete-scratch-package (package)
  (when (and package (find-package package))
    (ignore-errors (delete-package package))))


(defun validate-automation-form (form)
  "Structural check of a DEFINE-AUTOMATION form (M13-4): well-formed name,
an :on trigger with a known :kind (or :idle/:every), and a non-empty body.
Returns a problem string or NIL."
  (unless (and (consp form) (>= (length form) 3) (symbolp (second form)))
    (return-from validate-automation-form
      "Malformed DEFINE-AUTOMATION (expected (define-automation NAME (:on …) body…))."))
  (let* ((name (second form))
         (options (third form))
         (body (cdddr form)))
    (unless (and (listp options) (evenp (length options)))
      (return-from validate-automation-form
        (format nil "Automation ~A: options must be a plist (:on … :cooldown … :defer …)." name)))
    (let ((on (getf options :on)))
      (unless on
        (return-from validate-automation-form
          (format nil "Automation ~A has no :on trigger pattern." name)))
      (unless (and (listp on) (evenp (length on)))
        (return-from validate-automation-form
          (format nil "Automation ~A: the :on pattern must be a plist." name)))
      (let ((idle (getf on :idle)) (every (getf on :every)))
        (cond
          ((or idle every)
           (let ((n (or idle every)))
             (unless (and (numberp n) (plusp n))
               (return-from validate-automation-form
                 (format nil "Automation ~A: :idle/:every needs a positive number of seconds." name)))))
          ((not (keywordp (getf on :kind)))
           (return-from validate-automation-form
             (format nil "Automation ~A: the :on pattern needs a :kind keyword (or :idle/:every)." name))))))
    (unless body
      (return-from validate-automation-form
        (format nil "Automation ~A has an empty body — a reflex must do something." name))))
  nil)

(defun automation-forms (gene)
  (remove-if-not (lambda (form)
                   (and (consp form) (symbolp (first form))
                        (string-equal (symbol-name (first form)) "DEFINE-AUTOMATION")))
                 (gene-code-forms gene)))

(defun reflex-forms (gene)
  (remove-if-not (lambda (form)
                   (and (consp form) (symbolp (first form))
                        (string-equal (symbol-name (first form)) "DEFINE-REFLEX")))
                 (gene-code-forms gene)))

(defun check-gene-structure (gene)
  (let ((problems '()))
    (dolist (capability (gene-capabilities gene))
      (unless (capability-p capability)
        (push (format nil "Unknown capability ~S; valid: ~S"
                      capability +all-capabilities+)
              problems)))
    (unless (gene-test-forms gene)
      (push "Gene has no (:tests …) section; at least one test is required."
            problems))
    (dolist (form (gene-code-forms gene))
      (when (and (consp form)
                 (symbolp (first form))
                 (string-equal (symbol-name (first form)) "DEFTOOL"))
        (let ((sections (cddr form)))
          (unless (find-if (lambda (s) (and (consp s) (eq (first s) :doc)))
                           sections)
            (push (format nil "Tool ~A has no (:doc …) section." (second form))
                  problems))
          (unless (find-if (lambda (s) (and (consp s) (eq (first s) :contract)))
                           sections)
            (push (format nil "Tool ~A has no (:contract …) section. Declare ~
(:contract (:pre (…) :post (…))) — empty pre/post lists are acceptable."
                          (second form))
                  problems)))))
    ;; Reflexes (M13-4): DEFINE-AUTOMATION and the :automate capability must
    ;; agree, and every trigger must be well-formed.
    (let ((automations (automation-forms gene))
          (reflexes (reflex-forms gene))
          (declares-automate (member :automate (gene-capabilities gene))))
      (when (and (or automations reflexes) (not declares-automate))
        (push "Gene defines automation/reflex behavior but does not declare the :automate capability."
              problems))
      (when (and declares-automate (null automations) (null reflexes))
        (push "Gene declares the :automate capability but defines no automation or reflex."
              problems))
      (dolist (form automations)
        (let ((problem (validate-automation-form form)))
          (when problem (push problem problems))))
      (dolist (form reflexes)
        (handler-case (ourro.reflex.model:definition-from-form form)
          (error (condition)
            (push (format nil "Invalid DEFINE-REFLEX: ~A" condition) problems)))))
    (when problems
      (fail-verification :structure
                         (format nil "~{- ~A~^~%~}" (nreverse problems))))))


(defparameter *whitelisted-warning-substrings*
  '("redefin")               ; redefining an existing gene's function is legal
  "Substrings of warning texts that do not reject a candidate. The old
\"undefined variable: common-lisp-user::\" escape hatch was removed in M4-5 —
it was a papered-over reader/package slip, and the gauntlet is stricter for
its absence (proven by `make test` + a full seed rebuild).")

(defun warning-whitelisted-p (condition)
  (let ((text (string-downcase (princ-to-string condition))))
    (some (lambda (substring) (search substring text))
          *whitelisted-warning-substrings*)))

(defun compile-gene-in-scratch (source-text scratch-package)
  "COMPILE-FILE the gene in SCRATCH-PACKAGE. Returns the fasl pathname.
Rejects on any error or non-whitelisted warning, with full diagnostics."
  (let* ((directory (ensure-dir (merge-pathnames
                                 "ourro-verify/"
                                 (uiop:temporary-directory))))
         (source (merge-pathnames (format nil "~A.lisp" (make-id "cand"))
                                  directory))
         (fasl (make-pathname :type "fasl" :defaults source))
         (diagnostics '()))
    (with-open-file (out source :direction :output :if-exists :supersede)
      (write-string source-text out))
    (multiple-value-bind (output warnings-p failure-p)
        (handler-bind ((warning
                         (lambda (condition)
                           (unless (warning-whitelisted-p condition)
                             (push (format nil "~:[WARNING~;STYLE-WARNING~]: ~A"
                                           (typep condition 'style-warning)
                                           condition)
                                   diagnostics))
                           (muffle-warning condition))))
          (let ((*package* scratch-package)
                (*read-eval* nil))
            (with-compilation-unit (:override t)
              (compile-file source :output-file fasl
                                   :verbose nil :print nil))))
      (declare (ignore warnings-p))
      (ignore-errors (delete-file source))
      (when (or failure-p (null output))
        (fail-verification :compile
                           "COMPILE-FILE failed.~@[ Diagnostics:~%~{~A~%~}~]"
                           (nreverse diagnostics)))
      (when diagnostics
        (ignore-errors (delete-file fasl))
        (fail-verification :compile
                           "Compiled with warnings (all warnings must be fixed):~%~{~A~%~}"
                           (nreverse diagnostics)))
      output)))


(defun copy-fiveam-bundle ()
  (let ((copy (make-instance 'fiveam::test-bundle)))
    (maphash (lambda (key value)
               (setf (gethash key (fiveam::%tests copy)) value))
             (fiveam::%tests fiveam::*test*))
    (setf (fiveam::%test-names copy)
          (copy-list (fiveam::%test-names fiveam::*test*)))
    copy))

(defmacro with-staged-registries ((sandbox-var prefix) &body body)
  "Run BODY with throwaway tool/gene/FiveAM/UI registries and a fresh sandbox
workspace bound to SANDBOX-VAR, so loading and exercising a candidate touches
nothing live (M3 UI isolation; reused by the M5-2 determinism probe). The
sandbox is deleted on exit, success or failure."
  `(let ((,sandbox-var (ensure-dir (merge-pathnames
                                    (format nil "~A/~A/" ,prefix (make-id "sb"))
                                    (uiop:temporary-directory)))))
     (unwind-protect
          (let ((ourro.tools:*tool-registry* (ourro.tools:copy-tool-registry))
                (ourro.genome:*gene-registry* (copy-gene-registry))
                (ourro.reflex.model:*reflex-definitions*
                  (ourro.reflex.model:copy-reflex-definitions))
                (ourro.reflex.model:*definition-registered-hook* nil)
                (fiveam::*test* (copy-fiveam-bundle))
                (fiveam::*suite* nil)
                ;; Verification is observational: even a gene that declares
                ;; network or subprocess may not exercise host effects in the
                ;; gauntlet. Its tests must replace those boundaries with Lisp
                ;; fakes. All mutable ourro state is rooted in the sandbox.
                (ourro.kernel:*capability-ceiling* *test-capability-ceiling*)
                (ourro.kernel:*active-capabilities* nil)
                ;; Revert/probation is part of the kernel, not the gene
                ;; registry.  A staged ADD-TURN-HOOK or hot-load may record
                ;; undo state, so give the gauntlet a completely private
                ;; lifecycle table and keep background execution disarmed.
                (ourro.kernel::*revert-table* (make-hash-table :test #'equal))
                (ourro.kernel::*probation-counters* (make-hash-table :test #'equal))
                (ourro.kernel::*probation-failure-hook* nil)
                (ourro.kernel::*probation-graduation-hook* nil)
                (ourro.kernel:*automations-armed* nil)
                (ourro.util::*ourro-home*
                  (ensure-dir (merge-pathnames "home/" ,sandbox-var)))
                (ourro.toolkit:*workspace* ,sandbox-var)
                ;; Candidate fixture reads/writes are capability-confined to
                ;; this disposable root. Absolute paths, .. traversal, and
                ;; existing symlink escapes fail before touching host state.
                (ourro.kernel:*capability-filesystem-root* ,sandbox-var)
                (ourro.observe:*event-sink* nil)
                (ourro.observe::*event-log-path* nil)
                (ourro.observe:*session-id* "verification")
                (ourro.observe::*recent-events* '())
                (ourro.observe::*event-persistence-error* nil)
                (ourro.observe:*workspace-context-fn* nil)
                (ourro.observe:*gene-use-hook* nil)
                (ourro.observe:*gene-measurable-hook* nil)
                (ourro.observe:*utility-ledger* (make-hash-table :test #'equal))
                (ourro.observe:*genome-gene-count-fn* nil)
                (ourro.observe:*context-summary-fn* nil)
                (ourro.observe:*turn-hooks* (copy-tree ourro.observe:*turn-hooks*))
                (ourro.observe:*turn-hook-failure-hook* nil)
                (ourro.observe:*evolution-queue* '())
                (ourro.observe:*dream-classify-corrections* nil)
                ;; A candidate's load-time ADD-PANE / DEFINE-STATUS-WIDGET /
                ;; BIND-KEY mutate these throwaway copies, so an unverified gene
                ;; can never touch the live screen or keymap.
                (ourro.tui:*active-view* (ourro.tui:make-view))
                (ourro.tui:*status-widgets* '())
                (ourro.tui:*keymap* (copy-alist ourro.tui:*keymap*))
                (ourro.tui:*commands* (copy-ui-commands))
                ;; Reflexes (M13-5): a candidate's load-time DEFINE-AUTOMATION
                ;; registers into this throwaway copy, never the live registry,
                ;; and no candidate event reaches the live dispatcher (the bus
                ;; is rebound empty) — the staging leak the risk register names.
                (ourro.automation:*automations* (ourro.automation:copy-automations))
                (ourro.automation::*automation-version* 0)
                (ourro.automation::*firing-queue* '())
                (ourro.automation::*firing-sem*
                  (bt:make-semaphore :name "ourro-verification-reflex"))
                (ourro.automation::*firings-dropped* 0)
                (ourro.automation::*dispatch-epoch* 0)
                (ourro.automation::*execution-lock*
                  (bt:make-lock "ourro-verification-reflex-execution"))
                (ourro.automation::*in-automation-context* t)
                (ourro.automation::*politeness-hook* nil)
                ;; Rebind the deferred set too: a candidate's load-time
                ;; register/unregister does (remhash … *deferred*), which would
                ;; otherwise drop a LIVE automation's coalesced firing (review LOW).
                (ourro.automation::*deferred* (make-hash-table :test #'equal))
                ;; A candidate test's request-investigation must enqueue into a
                ;; throwaway queue with no hook, never the live worker (M15).
                (ourro.automation::*investigation-queue* '())
                (ourro.automation:*investigation-hook* nil)
                ;; A candidate test's post-note must not push into the live
                ;; next-message channel or raise the live ticker (M13 review INFO).
                (ourro.automation::*pending-notes* '())
                (ourro.automation:*note-sink* nil)
                (ourro.observe:*event-subscribers* '())
                ;; Jobs and genome callbacks are also mutable registries.  A
                ;; candidate test can exercise the public API, but its records,
                ;; exit notices, revert actions, and hot-load callbacks must
                ;; disappear with the verification sandbox.
                (ourro.jobs::*jobs* '())
                (ourro.jobs::*job-counter* 0)
                (ourro.jobs::*job-processes* (make-hash-table :test #'equal))
                (ourro.jobs::*job-cursors* (make-hash-table :test #'equal))
                (ourro.jobs::*job-exit-notes* '())
                (ourro.jobs:*job-exit-hook* nil)
                (ourro.genome:*hot-load-hook* nil)
                (ourro.genome:*hot-loads-since-boot* 0))
            ,@body)
       (ignore-errors (uiop:delete-directory-tree
                       ,sandbox-var :validate (constantly t))))))

(defun run-staged-tests (fasl gene)
  "Load FASL and run the gene's suite entirely inside staged dynamic
bindings. Returns the test report string on success."
  (with-staged-registries (sandbox "ourro-sandbox")
    (handler-case
        (let ((ourro.kernel:*current-gene-context*
                (list :name (gene-name gene)
                      :capabilities (gene-capabilities gene))))
          (sb-ext:with-timeout (* 4 *test-timeout-seconds*)
            (load fasl)))
      (sb-ext:timeout ()
        (fail-verification :test "Loading the candidate timed out."))
      (error (condition)
        (fail-verification :test "Loading the candidate signaled: ~A"
                           condition)))
    (multiple-value-bind (passed report)
        (with-capabilities (union (gene-capabilities gene)
                                  '(:filesystem-read :filesystem-write))
          (run-suite-with-watchdog (gene-suite-name (gene-name gene))))
      (unless passed
        (fail-verification :test "Tests failed:~%~A~@[~A~]"
                           report (withheld-capability-hint gene report)))
      report)))

(defparameter *determinism-probe-runs* 5
  "How many times a declared :determinism probe re-runs its tool; every run
must be byte-identical for the gene to pass (M5-2).")

(defun run-determinism-probes (fasl gene)
  "Prove the gene's declared :determinism probes (M5-2). Each probe is
(\"tool_name\" :arg v …): the tool must produce byte-identical output across
*DETERMINISM-PROBE-RUNS* calls with those args. This wires VERIFY-DETERMINISM
into the gauntlet, turning the demo-only determinism check into a property the
gene cannot go live without. No-op for genes that declare no probes. Signals
VERIFICATION-FAILURE on a malformed probe, an unknown tool, or a
nondeterministic result."
  (let ((probes (gene-determinism gene)))
    (when probes
      (with-staged-registries (sandbox "ourro-determinism")
        ;; sb-ext:timeout is a SERIOUS-CONDITION, not an ERROR — it needs its
        ;; own clause (same reason RUN-STAGED-TESTS has one), or a load that
        ;; hangs escapes as a raw timeout instead of a clean verdict.
        (handler-case
            (let ((ourro.kernel:*current-gene-context*
                    (list :name (gene-name gene)
                          :capabilities (gene-capabilities gene))))
              (sb-ext:with-timeout (* 4 *test-timeout-seconds*) (load fasl)))
          (sb-ext:timeout ()
            (fail-verification :determinism "Loading the candidate timed out."))
          (error (c)
            (fail-verification :determinism
                               "Loading the candidate signaled: ~A" c)))
        ;; D3: the probe runs under the gene's *bare* declared capabilities —
        ;; unlike RUN-STAGED-TESTS above, which additionally grants
        ;; :filesystem-read/-write. That asymmetry is correct, not an oversight:
        ;; the walker already proved the tool cannot reach an effect it didn't
        ;; declare, so its declared caps are exactly what it needs to run. The
        ;; test-stage extras exist only so FiveAM *fixtures* can stage scratch
        ;; files; a determinism probe invokes the tool directly, with no fixture,
        ;; so granting it those extras would be strictly-broader-than-necessary
        ;; authority for no benefit.
        (with-capabilities (gene-capabilities gene)
          (dolist (probe probes)
            (unless (and (consp probe) (stringp (first probe)))
              (fail-verification :determinism
                                 "Malformed :determinism probe ~S ~
(expected (\"tool\" :arg v …))." probe))
            (let ((tool (first probe))
                  (args (plist->hash (rest probe))))
              (unless (ourro.tools:find-tool tool)
                (fail-verification :determinism
                                   "Determinism probe names unknown tool ~S." tool))
              ;; The probe EXECUTES untrusted tool code N times; it needs the
              ;; same watchdog the staged tests get, or a tool that loops on the
              ;; probe args (which are declared independently of the test args)
              ;; hangs the gauntlet — and the whole evolver thread with it.
              (multiple-value-bind (deterministic results)
                  (handler-case
                      (sb-ext:with-timeout *test-timeout-seconds*
                        (verify-determinism tool args
                                            :runs *determinism-probe-runs*))
                    (sb-ext:timeout ()
                      (fail-verification :determinism
                                         "Determinism probe for ~S exceeded the ~
~As watchdog — the tool may loop on these args."
                                         tool *test-timeout-seconds*))
                    (error (c)
                      (fail-verification :determinism
                                         "Determinism probe for ~S signaled: ~A"
                                         tool c)))
                (declare (ignore results))
                (unless deterministic
                  (fail-verification :determinism
                                     "Tool ~S is not deterministic: output ~
varied across ~A calls with identical args. A gene that declares :determinism ~
must be reproducible (PR-13)."
                                     tool *determinism-probe-runs*))))))))))

(defun copy-gene-registry ()
  (copy-hash-table ourro.genome:*gene-registry*))

(defun copy-ui-commands ()
  "A shallow copy of the keymap command table, for staging isolation (M3)."
  (copy-hash-table ourro.tui:*commands*))

(defun run-suite-with-watchdog (suite)
  "Run SUITE under the watchdog. Returns (values passed-p report).
FiveAM's dribble (\"Running test …\") is captured — never the terminal:
the TUI owns the tty and raw prints corrupt its frame."
  (handler-case
      (sb-ext:with-timeout *test-timeout-seconds*
        (let* ((results (let ((fiveam:*test-dribble* (make-broadcast-stream))
                              (*standard-output* (make-broadcast-stream))
                              (*error-output* (make-broadcast-stream)))
                          (fiveam:run suite)))
               (passed (and results
                            (every (lambda (result)
                                     (typep result 'fiveam::test-passed))
                                   results)))
               (report (with-output-to-string (out)
                         (let ((fiveam:*test-dribble* out))
                           (fiveam:explain! results)))))
          ;; An empty result list means the suite had no tests — reject.
          (if (null results)
              (values nil "The gene's test suite ran zero tests.")
              (values passed report))))
    (sb-ext:timeout ()
      (values nil (format nil "Tests exceeded the ~As watchdog timeout."
                          *test-timeout-seconds*)))
    (error (condition)
      (values nil (format nil "Test run signaled: ~A" condition)))))


(defun verify-gene-text (source-text)
  "Run SOURCE-TEXT through the full gauntlet. On success returns
(values gene report-plist); on failure signals VERIFICATION-FAILURE whose
diagnostics are suitable LLM feedback. Nothing the candidate defines is
visible after this function returns, success or not — visibility is the
hot-loader's job."
  (let ((scratch (make-scratch-package))
        (stages '()))
    (unwind-protect
         (progn
           ;; 1. safe read (+ parse)
           (let ((gene (handler-case
                           (parse-gene-source source-text :package scratch)
                         (unsafe-form-error (condition) (error condition))
                         (error (condition)
                           (fail-verification :read "~A" condition)))))
             (push (list :read :ok) stages)
             ;; 2. structure
             (check-gene-structure gene)
             (push (list :structure :ok) stages)
             ;; 3. lint. Code is linted strictly against the gene's declared
             ;; capabilities — that is what runs in the live image. Test forms
             ;; run in the sandbox (which always grants fs read+write for
             ;; fixtures), so they are linted against that wider set; this
             ;; still blocks eval/intern/subprocess/network they didn't declare.
             (let ((code-violations
                     (lint-gene-body (gene-code-forms gene)
                                     :capabilities (gene-capabilities gene)))
                   (test-violations
                     (lint-gene-body (gene-test-forms gene)
                                     :capabilities
                                     (union (gene-capabilities gene)
                                            '(:filesystem-read :filesystem-write))
                                     :allow-test-helpers t)))
               (when code-violations
                 (fail-verification :lint "~A" (lint-violations code-violations)))
               (when test-violations
                 (fail-verification :lint "In test code: ~A"
                                    (lint-violations test-violations))))
             (push (list :lint :ok) stages)
             ;; 4. compile gate
             (let ((fasl (compile-gene-in-scratch source-text scratch)))
               (push (list :compile :ok) stages)
               ;; 5. staged tests — run TWICE (M4-5). Each run loads the fasl
               ;; into fresh staged registries, so a gene whose test passes
               ;; once but leaves state that breaks a second run (a hidden
               ;; dependence on load order or a global) is caught here rather
               ;; than after it is live. The second report is the one we keep.
               (let ((report (progn
                               (run-staged-tests fasl gene)
                               (run-staged-tests fasl gene))))
                 (push (list :test :ok) stages)
                 ;; 6. determinism (M5-2). If the gene declares :determinism
                 ;; probes, prove each named tool is byte-identical across
                 ;; repeated calls before it goes live — determinism becomes a
                 ;; verified property, not just a demo tool (PR-13). No-op when
                 ;; the gene declares no probes.
                 (run-determinism-probes fasl gene)
                 (when (gene-determinism gene)
                   (push (list :determinism :ok) stages))
                 (ignore-errors (delete-file fasl))
                 (values gene
                         (list :stages (nreverse stages)
                               :test-report report))))))
      (delete-scratch-package scratch))))
