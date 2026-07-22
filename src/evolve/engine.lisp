
(in-package #:ourro.evolve)

(defparameter *max-repairs* 3)
(defparameter *rate-limit-seconds* 300
  "Minimum seconds between hot-loads (anti-thrash).")


(defvar *verify-runner* nil
  "Test seam: a function (argv-list) → combined-output-string standing in for a
real child run. NIL → the real run-command spawn.")

(defun should-verify-out-of-process-p (&key deliberate (hot-loads 0) argv0)
  "Whether production verification can use a child generation image.
Every built generation uses the child, including deliberate and post-hot-load
candidates. The developer-only `make dev` process has no executable image and
retains the in-process verifier as an explicit development seam."
  (declare (ignore deliberate hot-loads))
  (built-image-argv0-p argv0))

(defun built-image-argv0-p (argv0)
  "argv[0] looks like a built generation image (…/images/gen-NNNN…), not the
bare sbcl of a `make dev` run."
  (and (stringp argv0) (search "gen-" argv0) t))

(defun verify-framed-blocks (text begin end)
  "All complete sentinel blocks in TEXT. Malformed/duplicate protocol output
is rejected by PARSE-VERIFY-VERDICT instead of selecting an attacker-controlled
first block."
  (loop with from = 0
        for start = (search begin text :start2 from)
        while start
        for after = (+ start (length begin))
        for stop = (search end text :start2 after)
        unless stop do (return (list :malformed))
        collect (subseq text after stop)
        do (setf from (+ stop (length end)))))

(defun parse-verify-verdict (output &key nonce)
  "Parse the sentinel-framed verdict plist from a --verify-gene child's OUTPUT.
Returns the plist (:verdict :pass|:fail …) or NIL if absent/malformed."
  (let ((blocks (verify-framed-blocks output "<<<OURRO-VERIFY" "OURRO-VERIFY>>>")))
    (and (= (length blocks) 1)
         (not (eq (first blocks) :malformed))
         (ignore-errors
          (with-standard-io-syntax
            (let ((*read-eval* nil) (*package* (find-package :keyword)))
              (multiple-value-bind (form end)
                  (read-from-string (first blocks))
                (and (member (getf form :verdict) '(:pass :fail))
                     (or (null nonce) (equal nonce (getf form :nonce)))
                     (every (lambda (char)
                              (member char '(#\Space #\Tab #\Return #\Newline)))
                            (subseq (first blocks) end))
                     form))))))))

(defun verdict-form-valid-p (form nonce)
  (and (listp form)
       (member (getf form :verdict) '(:pass :fail))
       (equal nonce (getf form :nonce))))

(defun read-verdict-channel (pathname nonce)
  "Read the child's dedicated canonical verdict channel, failing closed."
  (when (probe-file pathname)
    (ignore-errors
     (let ((form (ourro.txn:canonical-decode
                  (uiop:read-file-string pathname))))
       (and (verdict-form-valid-p form nonce) form)))))

(defun verify-mined-block (block &key (argv0 (first sb-ext:*posix-argv*))
                                      (hot-loads ourro.genome:*hot-loads-since-boot*))
  "Verify a MINED candidate's gene source (M12-3). When eligible, run the
gauntlet in a child of this image (moving the compile/test GC contention off the
live image); the child ran the full gauntlet, so on :pass the live image only
parses the gene (cheap) — the expensive staged tests already happened. Child or
protocol failure rejects the candidate; it never falls back into the live image.
Returns (values gene report) on success; signals VERIFICATION-FAILURE
on a :fail verdict — exactly what the in-process path signals, so propose-gene's
repair loop is unchanged."
  (if (should-verify-out-of-process-p :deliberate nil :hot-loads hot-loads :argv0 argv0)
      (let ((verdict (verify-out-of-process block)))
        (cond
          ((null verdict)
           (error 'ourro.kernel:verification-failure
                  :stage :out-of-process
                  :diagnostics "verification child returned no single valid verdict; candidate was not loaded"))
          ((eq (getf verdict :verdict) :pass)
           (handler-case
               ;; The verdict reader intentionally interns into KEYWORD. Plain
               ;; nested Lisp data would therefore turn NIL/T into :NIL/:T and
               ;; invalidate a proof. The child transports a shallow canonical
               ;; envelope containing the independently encoded artifact;
               ;; decode it only after the nonce-bound frame has been accepted.
               (let ((report (and (stringp (getf verdict :report))
                                  (ourro.verify.coordinator:decode-report-from-transport
                                   (getf verdict :report)))))
                 (unless (ourro.verify.coordinator:authoritative-pass-report-p
                          report block)
                   (error "child PASS did not carry a valid proof for this source"))
                 ;; The verifier child uses a disposable HOME. Adopt its
                 ;; self-hashing proof into the live home before the source
                 ;; can be parsed, hot-loaded, or proposed to the supervisor.
                 (ourro.verify.coordinator:adopt-authoritative-report report block)
                 (values (ourro.genome:parse-gene-source block)
                         (append report (list :out-of-process t))))
             (error (c)
               (error 'ourro.kernel:verification-failure
                      :stage :out-of-process
                      :diagnostics (format nil "verified child result could not be parsed by parent: ~A" c)))))
          (t
           (error 'ourro.kernel:verification-failure
                  :stage (or (getf verdict :stage) :out-of-process)
                  :diagnostics (or (getf verdict :diagnostics)
                                   "out-of-process verification failed")))))
      (ourro.verify.coordinator:verify-source block)))

(defun sandbox-exec-command (argv0 file sandbox &optional nonce verdict-file)
  "The macOS sandbox-exec wrapper for the --verify-gene child, or NIL when
sandbox-exec is unavailable. The profile MUST open with (allow default): a
version-1 profile with only deny clauses defaults to deny-all, which denies
process-exec itself and makes sandbox-exec fail before the child ever runs
(the QA F-outproc failure — every candidate rejected with no verdict). We keep
the durable, high-value protection — (deny network*), so a gene's own test code
cannot phone home during verification — and redirect HOME/TMPDIR into the
throwaway sandbox. We do NOT jail file-writes: the child's compiler scratch is
placed by (uiop:temporary-directory), which does not reliably honor TMPDIR, so
a write jail keyed on the sandbox path silently fails the compile stage. The
Lisp capability ceiling remains the effect boundary, exactly as on the
platforms that have no OS sandbox at all."
  (when (probe-file #P"/usr/bin/sandbox-exec")
    (list "/usr/bin/sandbox-exec" "-p"
          "(version 1) (allow default) (deny network*)"
          "/usr/bin/env" "-i"
          (format nil "HOME=~A" (namestring sandbox))
          (format nil "OURRO_HOME=~A" (namestring sandbox))
          (format nil "TMPDIR=~A" (namestring sandbox))
          "PATH=/usr/bin:/bin" argv0 "--verify-gene"
          (namestring file)
          "--verify-nonce" (or nonce "")
          "--verify-verdict-file"
          (if verdict-file (namestring verdict-file) "")
          "--verify-home" (namestring sandbox))))

(defun sandbox-launcher-failed-p (output)
  "T when OUTPUT is a sandbox-exec launcher failure (it could not exec the
child at all) rather than a verdict from a child that ran. Distinguishes a
broken OS-sandbox layer from a gene that legitimately failed verification."
  (and (stringp output)
       (search "sandbox-exec:" output)
       (search "execvp" output)))

(defun verify-out-of-process (source-text &key (argv0 (first sb-ext:*posix-argv*))
                                               (timeout 180))
  "Verify SOURCE-TEXT in a child of this image (--verify-gene). Returns the
verdict plist, or NIL on any spawn/parse/infrastructure failure. Production
accepts a verdict only from a dedicated canonical result file; stdout/stderr is
captured solely as evidence, so candidate output cannot forge PASS. Callers
MUST fail closed on NIL. If macOS sandbox-exec itself cannot launch, read-only
verification retries unwrapped; the coordinator has already refused effectful
authority on hosts without a reviewed containment backend."
  (ignore-errors
   (let* ((nonce (ourro.txn:make-transaction-id "nonce"))
          (sandbox (uiop:ensure-directory-pathname
                    (merge-pathnames (format nil "ourro-verify/~A/" (make-id "vg"))
                                     (uiop:temporary-directory))))
          (file (merge-pathnames "candidate.gene" sandbox))
          (verdict-file (merge-pathnames "verdict.csexp" sandbox)))
     (ensure-directories-exist file)
     (ignore-errors (sb-posix:chmod (namestring sandbox) #o700))
     (unwind-protect
          (progn
            (with-open-file (out file :direction :output :if-exists :supersede)
              (write-string source-text out))
            (ignore-errors (sb-posix:chmod (namestring file) #o400))
            (let* ((plain (list "/usr/bin/env"
                                (format nil "HOME=~A" (namestring sandbox))
                                (format nil "OURRO_HOME=~A" (namestring sandbox))
                                (format nil "TMPDIR=~A" (namestring sandbox))
                                argv0 "--verify-gene" (namestring file)
                                "--verify-nonce" nonce
                                "--verify-verdict-file"
                                (namestring verdict-file)
                                "--verify-home" (namestring sandbox)))
                   (wrapped (sandbox-exec-command argv0 file sandbox nonce
                                                  verdict-file)))
              (flet ((run (command)
                       (if *verify-runner*
                           (funcall *verify-runner* plain)
                           (handler-case
                               (ourro.util:run-command command :directory sandbox
                                                              :timeout timeout)
                             (ourro.util:command-failed (c)
                               (ourro.util:command-failed-output c))))))
                (cond
                  ;; Test runners emulate old children through captured output;
                  ;; no production decision enters this seam.
                  (*verify-runner*
                   (let ((output (run (or wrapped plain))))
                     (or (parse-verify-verdict output :nonce nonce)
                         (when (and wrapped
                                    (sandbox-launcher-failed-p output))
                           (parse-verify-verdict (run plain) :nonce nonce)))))
                  (wrapped
                   (let ((output (run wrapped)))
                     (or (read-verdict-channel verdict-file nonce)
                         (when (sandbox-launcher-failed-p output)
                           (ignore-errors (delete-file verdict-file))
                           (run plain)
                           (read-verdict-channel verdict-file nonce)))))
                  (t
                   (run plain)
                   (read-verdict-channel verdict-file nonce))))))
       (ignore-errors
        (uiop:delete-directory-tree sandbox :validate (constantly t)))))))

(defvar *progress-hook* nil
  "When set, called as (fn STAGE &rest INFO) at each evolution stage so the
UI can show what the background evolver is doing. Stages: :proposing
:verifying :repairing :verified :gave-up :error :deferred :hot-loaded
:snapshotting :built :snapshot-failed :duplicate.")

(defun note-progress (stage &rest info)
  (when *progress-hook*
    (ignore-errors (apply *progress-hook* stage info)))
  nil)

(defvar *last-evolution-time* 0)

(defclass evolution-candidate ()
  ((pattern :initarg :pattern :reader candidate-pattern)
   (status :initarg :status :initform :proposed :accessor candidate-status
           :documentation ":proposed :verified :staged :hot-loaded :snapshotted
:rejected :dismissed :duplicate :deferred :error. :staged is a verified
automation-bearing candidate awaiting the user's one-key consent (M14-2);
:dismissed is one the user declined; :deferred is one whose proposal hit a
sustained provider throttle and was re-queued to retry later (F-evolver-429).")
   (gene :initarg :gene :initform nil :accessor candidate-gene)
   (source :initarg :source :initform nil :accessor candidate-source)
   (previous-source :initarg :previous-source :initform nil
                    :accessor candidate-previous-source
                    :documentation "Source text of the gene this candidate
overwrites, captured before hot-load — feeds the M2 inspector's structural diff.")
   (report :initarg :report :initform nil :accessor candidate-report)
   (diagnostics :initarg :diagnostics :initform nil
                :accessor candidate-diagnostics)
   (generation-id :initarg :generation-id :initform nil
                  :accessor candidate-generation-id)))


(defvar *candidate-record-hook* nil
  "Optional (function of a record plist) run after a record is persisted; the
agent mirrors records into its in-memory list and refreshes the UI.")

(defun candidate-records-path ()
  (ourro.util:ourro-path "state" "evolutions.sexp"))

(defun candidate->record (candidate)
  "A readable, self-contained snapshot of CANDIDATE's current state."
  (let ((gene (candidate-gene candidate))
        (pattern (candidate-pattern candidate)))
    (list :id (pget pattern :id)
          :status (candidate-status candidate)
          ;; A pattern re-enqueued by RETRY-SHELVED-CANDIDATES carries
          ;; :retry-feedback; propagate a :retried marker so that if this
          ;; second attempt is *also* rejected, its (now latest) record is not
          ;; re-enqueued on the next boot — the retry stays one-shot.
          :retried (and (pget pattern :retry-feedback) t)
          :gene-name (and gene (gene-name gene))
          :source (candidate-source candidate)
          :previous-source (candidate-previous-source candidate)
          :diagnostics (candidate-diagnostics candidate)
          :report (and (candidate-report candidate)
                       (pget (candidate-report candidate) :test-report))
          :pattern pattern
          :generation-id (candidate-generation-id candidate)
          :time (ourro.util:iso-time)
          :unix (ourro.util:unix-time))))

(defun record-candidate (candidate)
  "Persist CANDIDATE's current state to the append-only history and notify
the record hook. Returns the record."
  (let ((record (candidate->record candidate)))
    (ignore-errors
     (ourro.util:append-sexp-line (candidate-records-path) record))
    (when *candidate-record-hook*
      (ignore-errors (funcall *candidate-record-hook* record)))
    record))

(defun load-candidate-records (&key (limit 50))
  "The most recent LIMIT candidate records, newest first, deduped by :id
(keeping the latest status seen for each)."
  (let* ((all (ourro.util:read-sexp-lines (candidate-records-path)))
         (seen (make-hash-table :test #'equal))
         (latest '()))
    ;; ALL is oldest first; walk newest→oldest keeping the first (latest) per id.
    (dolist (record (reverse all))
      (let ((id (pget record :id)))
        (unless (and id (gethash id seen))
          (when id (setf (gethash id seen) t))
          (push record latest))))
    (let ((newest-first (nreverse latest)))
      (subseq newest-first 0 (min limit (length newest-first))))))

(defun candidate-value-contains-workspace-p (value workspace)
  (cond ((or (stringp value) (pathnamep value))
         (string= (ourro.reflex.journal:normalize-workspace value) workspace))
        ((consp value)
         (or (candidate-value-contains-workspace-p (car value) workspace)
             (candidate-value-contains-workspace-p (cdr value) workspace)))
        ((vectorp value)
         (some (lambda (item)
                 (candidate-value-contains-workspace-p item workspace))
               value))
        (t nil)))

(defun rewrite-candidate-records (records)
  (let ((path (candidate-records-path)))
    (ensure-directories-exist path)
    (uiop:with-staging-pathname (staging path)
      (with-open-file (out staging :direction :output :if-exists :supersede
                                   :if-does-not-exist :create)
        (with-sexp-syntax
          (let ((*print-pretty* nil))
            (dolist (record records)
              (prin1 record out)
              (terpri out)))))))
  t)

(defun purge-workspace-candidate-records (workspace)
  "Remove mined/staged candidate evidence which could re-enter a model prompt."
  (let* ((workspace (ourro.reflex.journal:normalize-workspace workspace))
         (records (or (read-sexp-lines (candidate-records-path)) '()))
         (kept (remove-if
                (lambda (record)
                  (candidate-value-contains-workspace-p record workspace))
                records)))
    (unless (= (length kept) (length records))
      (rewrite-candidate-records kept))
    (- (length records) (length kept))))

(defun candidate-workspace-residue (workspace)
  "Return a fail-closed residue report for the persisted candidate history."
  (let ((workspace (ourro.reflex.journal:normalize-workspace workspace)))
    (handler-case
        (let ((count
                (count-if
                 (lambda (record)
                   (candidate-value-contains-workspace-p record workspace))
                 (or (read-sexp-lines (candidate-records-path)) '()))))
          (list :records count :unreadable nil :residue (plusp count)))
      (error (condition)
        (list :records 0 :unreadable (princ-to-string condition) :residue t)))))

(ourro.reflex.journal:register-workspace-deletion-hook
 :evolution-candidates #'purge-workspace-candidate-records)

(defun retry-shelved-candidates (&key (records (load-candidate-records))
                                      (max-age-hours 48))
  "Re-enqueue patterns from :rejected records younger than MAX-AGE-HOURS that
were not already retried, attaching the prior diagnostics as :retry-feedback,
and write a :retried marker back so each is retried at most once. Returns the
number re-enqueued."
  (let ((retried 0)
        (cutoff (* max-age-hours 60 60)))
    (dolist (record records retried)
      (when (and (eq (pget record :status) :rejected)
                 (not (pget record :retried))
                 (pget record :pattern)
                 (< (- (ourro.util:unix-time) (pget record :unix 0)) cutoff))
        (enqueue-pattern
         (plist-put (pget record :pattern)
                    :retry-feedback (pget record :diagnostics)))
        (ignore-errors
         (ourro.util:append-sexp-line (candidate-records-path)
                                     (plist-put record :retried t)))
        (incf retried)))))


(defparameter *duplicate-check-enabled* t
  "When true, mined :repeated-command/:repeated-sequence patterns are screened
against the live tool inventory by one small LLM call before proposal.
Deliberate requests (propose_gene), onboarding, and corrections skip the gate —
those either name their gene explicitly or WANT a redefinition.")

(defun tool-inventory-text ()
  "The live tool inventory as prompt lines: name, arguments, first doc line."
  (with-output-to-string (out)
    (dolist (tool (ourro.tools:list-tools))
      (format out "  ~A(~{~A~^, ~}) — ~A~%"
              (ourro.tools:tool-name tool)
              (mapcar #'first (ourro.tools:tool-parameters tool))
              (let* ((doc (or (ourro.tools:tool-description tool) ""))
                     (newline (position #\Newline doc)))
                (truncate-string (if newline (subseq doc 0 newline) doc) 110))))))

(defun parse-duplicate-verdict (text)
  "Parse the judge's reply. Returns (values tool-name reason) when the first
significant token is DUPLICATE, else NIL — anything malformed reads as NOVEL."
  (let* ((line (trim (or text "")))
         (line (subseq line 0 (or (position #\Newline line) (length line)))))
    (when (and (>= (length line) 9)
               (string-equal "DUPLICATE" line :end2 9))
      (let* ((rest (trim (subseq line 9)))
             (name-end (or (position-if (lambda (c)
                                          (member c '(#\Space #\: #\— #\-)))
                                        rest)
                           (length rest)))
             (name (trim (subseq rest 0 name-end))))
        (when (plusp (length name))
          (values name (trim (string-left-trim ":—- " (subseq rest name-end)))))))))

(defun duplicate-tool-verdict (provider pattern)
  "Ask PROVIDER whether an existing tool already automates PATTERN.
Returns (values tool-name reason) for a confident duplicate, NIL otherwise
(including on any error — the gate fails open)."
  (handler-case
      (let* ((system "You are the evolution gatekeeper of a self-evolving coding agent. \
Given the agent's existing tools and a newly mined automation pattern, decide whether an \
existing tool ALREADY automates this exact pattern. Be conservative: tools with similar \
names can differ in behavior, and small argument differences can matter — answer DUPLICATE \
only when an existing tool clearly covers the same use, including its arguments. \
When in doubt, answer NOVEL. Reply with EXACTLY one line: \
'DUPLICATE <tool_name>: <one-sentence reason>' or 'NOVEL: <one-sentence reason>'.")
             (user (format nil "EXISTING TOOLS:~%~A~%MINED PATTERN:~%~A~%~%One line verdict:"
                           (tool-inventory-text)
                           (describe-pattern pattern)))
             (response (ourro.llm:complete-with-retry
                        provider system
                        (list (ourro.llm:user-message user)) nil)))
        (parse-duplicate-verdict (ourro.llm:assistant-text response)))
    (error () nil)))

(defun automation-inventory-text ()
  "The live automation (reflex) inventory as prompt lines: name, trigger, owner."
  (with-output-to-string (out)
    (dolist (a (ourro.automation:list-automations))
      (format out "  ~A on ~S — gene ~A~%"
              (ourro.automation:automation-name a)
              (ourro.automation:automation-trigger a)
              (or (ourro.automation:automation-gene a) "?")))))

(defun duplicate-automation-verdict (provider pattern)
  "Ask PROVIDER whether an existing reflex already reacts to the same trigger
with the same action (M14-3). Returns (values name reason) for a confident
duplicate, NIL otherwise (including any error — the gate fails open like the
tool gate)."
  (handler-case
      (let* ((system "You are the evolution gatekeeper of a self-evolving coding agent. \
Given the agent's existing AUTOMATIONS (reflexes: a trigger pattern + a background action) \
and a newly mined reaction pattern, decide whether an existing automation ALREADY reacts to \
the same trigger with the same action. Be conservative: different triggers or different \
actions are NOVEL, and small differences can matter. When in doubt, answer NOVEL. Reply with \
EXACTLY one line: 'DUPLICATE <name>: <one-sentence reason>' or 'NOVEL: <one-sentence reason>'.")
             (user (format nil "EXISTING AUTOMATIONS:~%~A~%MINED REACTION:~%~A~%~%One line verdict:"
                           (automation-inventory-text)
                           (describe-pattern pattern)))
             (response (ourro.llm:complete-with-retry
                        provider system
                        (list (ourro.llm:user-message user)) nil)))
        (parse-duplicate-verdict (ourro.llm:assistant-text response)))
    (error () nil)))

(defun reaction-duplicate-checkable-p (pattern)
  "Mined :reaction patterns pass the automation dedup gate; deliberate/retry
patterns skip it, same rules as the tool gate."
  (and *duplicate-check-enabled*
       (eq (pget pattern :origin) :mined)
       (not (pget pattern :retry-feedback))
       (eq (pget pattern :kind) :reaction)))

(defun duplicate-checkable-p (pattern)
  "Only miner-originated command/sequence patterns pass the gate: onboarding
and corrections name their gene / want redefinition, deliberate requests are
explicit, an inspector retry (:retry-feedback) was explicitly asked for, and
test/QA patterns constructed by hand carry no :origin."
  (and *duplicate-check-enabled*
       (eq (pget pattern :origin) :mined)
       (not (pget pattern :retry-feedback))
       (member (pget pattern :kind) '(:repeated-command :repeated-sequence))))


(defun throttled-provider-error-p (condition)
  "True when CONDITION is a *retryable* provider error (HTTP 429 / 5xx) that
survived COMPLETE-WITH-RETRY's whole backoff ride — i.e. a sustained throttle
under load, not a defect in this pattern. Such an error should DEFER the
pattern (re-queue + retry later), never burn it or alarm the user with an
`evolver error' ticker (F-evolver-429)."
  (and (typep condition 'ourro.llm:provider-error)
       (ourro.llm:provider-error-retryable-p condition)))

(defun propose-gene (provider pattern &key (max-repairs *max-repairs*))
  "Ask PROVIDER for a gene automating PATTERN, verifying and repairing up to
MAX-REPAIRS times. Returns an EVOLUTION-CANDIDATE. Mined command/sequence
patterns first pass the duplicate-tool gate; a confident duplicate is recorded
(status :duplicate) and never proposed, so the genome doesn't accumulate
evolutions of the same thing under different names."
  (when (duplicate-checkable-p pattern)
    (multiple-value-bind (dup-tool reason) (duplicate-tool-verdict provider pattern)
      (when dup-tool
        (let ((candidate (make-instance 'evolution-candidate :pattern pattern)))
          (setf (candidate-status candidate) :duplicate
                (candidate-diagnostics candidate)
                (format nil "already covered by tool ~A~@[ — ~A~]" dup-tool reason))
          (ourro.observe:log-event :evolution-duplicate
                                  :pattern (pget pattern :id)
                                  :tool dup-tool)
          (note-progress :duplicate dup-tool)
          (record-candidate candidate)
          (return-from propose-gene candidate)))))
  ;; The parallel gate for mined reactions (M14-3): don't grow a near-identical
  ;; reflex when one already reacts to the same trigger.
  (when (reaction-duplicate-checkable-p pattern)
    (multiple-value-bind (dup reason) (duplicate-automation-verdict provider pattern)
      (when dup
        (let ((candidate (make-instance 'evolution-candidate :pattern pattern)))
          (setf (candidate-status candidate) :duplicate
                (candidate-diagnostics candidate)
                (format nil "already covered by reflex ~A~@[ — ~A~]" dup reason))
          (ourro.observe:log-event :evolution-duplicate
                                  :pattern (pget pattern :id) :automation dup)
          (note-progress :duplicate dup)
          (record-candidate candidate)
          (return-from propose-gene candidate)))))
  (multiple-value-bind (system user) (assemble-evolution-prompt pattern)
    (let ((messages (list (ourro.llm:user-message user)))
          (candidate (make-instance 'evolution-candidate :pattern pattern)))
      (dotimes (round (1+ max-repairs) candidate)
        (note-progress :proposing round)
        (let* ((response (handler-case
                             ;; Ride out a transient 429/5xx rather than burning
                             ;; a repair round on it (M4-3).
                             (ourro.llm:complete-with-retry provider system
                                                           messages nil)
                           (error (c)
                             (cond
                               ;; A retryable throttle that outlasted the whole
                               ;; backoff ride: shelve the pattern back on the
                               ;; queue and DEFER rather than burning a proposal
                               ;; or crying "evolver error" at the user. The next
                               ;; evolver pass retries it once the burst clears
                               ;; (F-evolver-429). No record — a deferral is not
                               ;; a candidate outcome, and the boot-time retry
                               ;; machinery must not shelve it.
                               ((throttled-provider-error-p c)
                                (enqueue-pattern pattern)
                                (setf (candidate-status candidate) :deferred
                                      (candidate-diagnostics candidate)
                                      (princ-to-string c))
                                (ourro.observe:log-event
                                 :evolution-deferred
                                 :pattern (pget pattern :id)
                                 :reason (princ-to-string c))
                                (note-progress :deferred (princ-to-string c)))
                               (t
                                (setf (candidate-status candidate) :error
                                      (candidate-diagnostics candidate)
                                      (princ-to-string c))
                                (note-progress :error (princ-to-string c))
                                (record-candidate candidate)))
                             (return-from propose-gene candidate))))
               (text (ourro.llm:assistant-text response))
               (block (extract-gene-block text)))
          (ourro.observe:log-event :evolution-proposal
                                  :pattern (pget pattern :id)
                                  :round round
                                  :has-gene (and block t))
          (cond
            ((null block)
             (setf messages
                   (append messages
                           (list response
                                 (ourro.llm:user-message
                                  "No <gene>…</gene> block found. Respond with exactly one gene inside the tags.")))))
            (t
             (setf (candidate-source candidate) block)
             (note-progress :verifying)
             (handler-case
                 (multiple-value-bind (gene report)
                     ;; The mined path: verify in a child image when eligible
                     ;; (M12-3), else in-process. Signals VERIFICATION-FAILURE on
                     ;; a fail exactly like the in-process path, so the repair
                     ;; loop below is unchanged.
                     (verify-mined-block block)
                   (setf (candidate-gene candidate) gene
                         (candidate-report candidate) report
                         (candidate-status candidate) :verified)
                   (note-progress :verified (gene-name gene))
                   (record-candidate candidate)
                   (return-from propose-gene candidate))
               (ourro.kernel:verification-failure (failure)
                 (let ((diagnostics
                         (format nil "Verification failed at the ~A stage:~%~A"
                                 (ourro.kernel:verification-failure-stage failure)
                                 (ourro.kernel:verification-failure-diagnostics
                                  failure))))
                   (setf (candidate-diagnostics candidate) diagnostics
                         (candidate-status candidate) :rejected)
                   (note-progress :repairing
                                  (ourro.kernel:verification-failure-stage failure)
                                  round)
                   (ourro.observe:log-event :evolution-repair
                                           :pattern (pget pattern :id)
                                           :round round
                                           :stage (ourro.kernel:verification-failure-stage failure))
                   (setf messages
                         (append messages
                                 (list response
                                       (ourro.llm:user-message
                                        (format nil "~A~%~%Fix the gene and return the corrected version inside <gene>…</gene>."
                                                diagnostics))))))))))))
      (when (eq (candidate-status candidate) :rejected)
        (note-progress :gave-up (candidate-diagnostics candidate))
        (record-candidate candidate))
      candidate)))


(defun candidate-registers-automations-p (candidate)
  "True when CANDIDATE's gene installs at least one automation (a reflex), so it
needs consent before it can fire on its own."
  (let ((gene (candidate-gene candidate)))
    (and gene
         (find-if (lambda (definition)
                    (member (first definition) '(:automation :reflex)))
                  (ourro.genome:gene-definition-names gene))
         t)))

(defun should-stage-p (candidate)
  "A verified, MINED/DREAMED automation-bearing candidate is staged, not applied
 — the user blesses a reflex once before it acts autonomously (D-R6)."
  (and (eq (candidate-status candidate) :verified)
       (eq (pget (candidate-pattern candidate) :origin) :mined)
       (candidate-registers-automations-p candidate)))

(defun stage-candidate (candidate)
  "Mark CANDIDATE :staged and persist the record. It is NOT hot-loaded; consent
 (the ticker's y, or the inspector's a) later runs INSTALL-STAGED-CANDIDATE."
  (setf (candidate-status candidate) :staged)
  (ourro.observe:log-event :evolution-staged
                          :pattern (pget (candidate-pattern candidate) :id)
                          :gene (and (candidate-gene candidate)
                                     (gene-name (candidate-gene candidate))))
  (record-candidate candidate)
  candidate)


(defvar *snapshot-hook* nil
  "Function (changes message provenance) → generation-id-or-nil. Set by the
agent to route snapshots through the supervisor connection.")

(defvar *pending-graduation-callbacks* (make-hash-table :test #'equal))
(defvar *pending-graduation-lock* (bt:make-lock "ourro-graduations"))

(defun defer-until-graduated (gene-name candidate callback)
  (bt:with-lock-held (*pending-graduation-lock*)
    (setf (gethash gene-name *pending-graduation-callbacks*)
          (cons candidate callback))))

(defun publish-graduated-candidate (gene-name)
  "Publish the exact snapshotted candidate only after live probation succeeds."
  (let ((pending (bt:with-lock-held (*pending-graduation-lock*)
                   (prog1 (gethash gene-name *pending-graduation-callbacks*)
                     (remhash gene-name *pending-graduation-callbacks*)))))
    (when pending (funcall (cdr pending) (car pending)))))

(defun cancel-pending-graduation (gene-name)
  (bt:with-lock-held (*pending-graduation-lock*)
    (remhash gene-name *pending-graduation-callbacks*)))

(setf ourro.kernel:*probation-graduation-hook* #'publish-graduated-candidate)

(defun rate-limited-p ()
  (< (- (get-universal-time) *last-evolution-time*) *rate-limit-seconds*))

(defun stateful-fast-path-definitions (gene)
  "Definitions requiring a versioned schema/migration path, never hot-load."
  (remove-if-not (lambda (definition)
                   (member (first definition) '(:class :variable)))
                 (ourro.genome:gene-definition-names gene)))

(defun apply-candidate (candidate &key force (snapshot :sync) on-snapshot)
  "Hot-load a :verified CANDIDATE into the live image and request a snapshot.
Respects the rate limit unless FORCE. SNAPSHOT is :sync (block until the
supervisor built gen N+1), :async (hot-load now, build on a worker thread —
used by the deliberate propose_gene tool so the model isn't stalled for the
minutes an image build takes), or :none. ON-SNAPSHOT, if given, is called
with the candidate once the snapshot attempt finishes. Returns the candidate."
  (when ourro.kernel:*evolution-frozen*
    (setf (candidate-status candidate) :rejected
          (candidate-diagnostics candidate) "Evolution is frozen.")
    (record-candidate candidate)
    (return-from apply-candidate candidate))
  (unless (eq (candidate-status candidate) :verified)
    (return-from apply-candidate candidate))
  ;; PR-11: a candidate that names the kernel/verifier/supervisor may never
  ;; take the fast in-image path. (The walker already rejects such genes, so
  ;; this is defense in depth — a verified candidate should never trip it.)
  (when (ourro.verify:kernel-touching-p (candidate-source candidate))
    (setf (candidate-status candidate) :rejected
          (candidate-diagnostics candidate)
          "Candidate references the safety kernel; hardened path required.")
    (record-candidate candidate)
    (return-from apply-candidate candidate))
  (let ((stateful (and (candidate-gene candidate)
                       (stateful-fast-path-definitions
                        (candidate-gene candidate)))))
    (when stateful
      (setf (candidate-status candidate) :rejected
            (candidate-diagnostics candidate)
            (format nil "Stateful ~{~A~^, ~} definitions require a versioned schema and tested forward/reverse migration; they cannot use the hot-load fast path."
                    (mapcar #'first stateful)))
      (record-candidate candidate)
      (return-from apply-candidate candidate)))
  ;; Status alone is never authority. This closes internal/test-call bypasses:
  ;; every source entering the live image must still carry the exact immutable
  ;; proof issued by the coordinator.
  (unless (ourro.verify.coordinator:authoritative-pass-report-p
           (candidate-report candidate) (candidate-source candidate))
    (setf (candidate-status candidate) :rejected
          (candidate-diagnostics candidate)
          "Candidate has no authoritative verification proof for its exact source.")
    (record-candidate candidate)
    (return-from apply-candidate candidate))
  (when (and (not force) (rate-limited-p))
    (return-from apply-candidate candidate))
  (let ((gene (candidate-gene candidate)))
    ;; Capture the source of the gene we are about to overwrite BEFORE the
    ;; hot-load replaces it — this feeds the inspector's structural diff (M1-3).
    (let ((existing (ourro.genome:find-gene (gene-name gene))))
      (when existing
        (setf (candidate-previous-source candidate)
              (or (gene-source-text existing) (render-gene-source existing)))))
    ;; Hot-load from the authoritative source text.
    (ourro.genome:hot-load-gene (candidate-source candidate)
                               :file (gene-file-for gene))
    (setf (candidate-status candidate) :hot-loaded
          *last-evolution-time* (get-universal-time))
    (note-progress :hot-loaded (gene-name gene))
    ;; Record the manual-pattern cost this gene replaces so the utility ledger
    ;; can later measure realized savings against it (M1-1).
    (let ((pattern (candidate-pattern candidate)))
      (ourro.observe:set-gene-baseline
       (gene-name gene)
       (pget pattern :occurrence-cost-ms)
       (pattern-baseline-note pattern)))
    ;; Stamp creation time so a gene that is never called can still age into
    ;; the "unused for N days" retirement path (an unused gene has no
    ;; :first-use to measure from).
    (ourro.observe:note-gene-created (gene-name gene))
    (ourro.observe:log-event :evolution-hot-load
                            :gene (gene-name gene)
                            :pattern (pget (candidate-pattern candidate) :id))
    (record-candidate candidate)
    (flet ((snapshot-now ()
             (when *snapshot-hook*
               (note-progress :snapshotting (gene-name gene))
               (let* ((report (candidate-report candidate))
                      (provenance
                        (ourro.util:plist-put
                         (ourro.util:plist-put
                          (copy-list (gene-metadata gene))
                          :verification-transaction
                          (pget report :transaction-id))
                         :verification-proof
                         (pget report :proof-hash)))
                      (id (ignore-errors
                            (funcall *snapshot-hook*
                                     (gene-changes gene)
                                     (format nil "evolve ~A" (gene-name gene))
                                     provenance))))
                 (cond
                   (id (setf (candidate-generation-id candidate) id
                             (candidate-status candidate) :snapshotted)
                       (note-progress :built id)
                       (record-candidate candidate))
                   (t (note-progress :snapshot-failed (gene-name gene))))))
             (when on-snapshot
               (if (and (candidate-generation-id candidate)
                        (plusp (ourro.kernel:probation-remaining
                                (gene-name gene))))
                   (defer-until-graduated (gene-name gene) candidate on-snapshot)
                   (ignore-errors (funcall on-snapshot candidate))))))
      (case snapshot
        (:none (when on-snapshot (ignore-errors (funcall on-snapshot candidate))))
        (:async (bt:make-thread #'snapshot-now :name "ourro-snapshot"))
        (t (snapshot-now))))
    candidate))

(defun pattern-baseline-note (pattern)
  "A short human note describing the manual pattern a gene's baseline came from."
  (case (pget pattern :kind)
    (:repeated-sequence
     (format nil "manual ~{~A~^→~}" (pget pattern :tools)))
    (:repeated-command
     (format nil "manual ~A" (first (pget pattern :tools))))
    (t (and (pget pattern :kind)
            (format nil "~(~A~)" (pget pattern :kind))))))

(defun gene-file-for (gene)
  "Manifest-relative path a new gene should occupy."
  (format nil "genes/~A.gene"
          (substitute #\/ #\Space (gene-name gene))))

(defun gene-changes (gene)
  "The genome change-set installing GENE: its file + manifest update."
  (let* ((relative (gene-file-for gene))
         (source (or (gene-source-text gene)
                     (ourro.genome:render-gene-source gene))))
    (list (list :path relative :content source
                :manifest-add relative))))


(defvar *politeness-hook* nil
  "Optional 0-arg thunk the agent installs (M12-4): called between evolver stages
so a user turn never contends with a gene compile. It waits while the user is
busy (capped), then returns. NIL in tests / bare boot → no waiting.")

(defun be-polite ()
  (when *politeness-hook* (ignore-errors (funcall *politeness-hook*))))

(defun process-evolution-queue (provider &key (max 1) auto-apply on-applied)
  "Propose genes for up to MAX queued patterns. When AUTO-APPLY, verified
candidates are hot-loaded (subject to freeze + rate limit). ON-APPLIED, if
given, is called with each applied candidate once its snapshot attempt finishes
(on the ourro-snapshot thread, since the snapshot is async) — the mined path uses
it to announce the gene and arm the generation restart only AFTER the build set
`candidate-generation-id`. Returns the list of candidates produced."
  (let ((candidates '()))
    (dotimes (i max)
      (let ((pattern (dequeue-pattern)))
        (unless pattern (return))
        ;; Yield to the user before the (LLM propose + gauntlet compile) stage —
        ;; a background evolution must never make an interactive turn wait (M12-4).
        (be-polite)
        (let ((candidate (propose-gene provider pattern)))
          (be-polite)
          (when (and auto-apply (eq (candidate-status candidate) :verified)
                     (should-stage-p candidate))
            ;; A mined reflex stops for consent (M14-2): stage + announce via the
            ;; same on-applied callback, then skip the hot-load below.
            (stage-candidate candidate)
            (when on-applied (ignore-errors (funcall on-applied candidate))))
          (when (and auto-apply (eq (candidate-status candidate) :verified))
            ;; Snapshot on a worker thread (P0-3): the mined path must not stall
            ;; ourro-evolver for the minutes an image build (and its 600 s
            ;; protocol-request) takes. The candidate is already hot-loaded and
            ;; live before the build starts, so nothing user-visible waits on it.
            ;; ON-APPLIED fires from that same thread once the generation id is
            ;; known — so the seamless-restart arming happens after the build,
            ;; exactly as it did when the snapshot was synchronous (fixing the
            ;; async regression where announce ran while generation-id was NIL).
            ;; Known inherited wart: the ourro-snapshot thread and the heartbeat
            ;; thread share one supervisor connection. This is safe today because
            ;; :heartbeat expects no reply and the protocol splits its send/request
            ;; locks (src/kernel/protocol.lisp) — the snapshot's request-reply and
            ;; a fire-and-forget heartbeat can't interleave into a corrupt frame.
            (apply-candidate candidate :snapshot :async :on-snapshot on-applied))
          (push candidate candidates))))
    (nreverse candidates)))

(defun evolve-from-pattern (provider pattern &key auto-apply)
  "Convenience: propose (and optionally apply) a gene for one PATTERN."
  (let ((candidate (propose-gene provider pattern)))
    (when (and auto-apply (eq (candidate-status candidate) :verified))
      (apply-candidate candidate))
    candidate))
