
(defpackage #:ourro.evolve
  (:use #:cl #:ourro.util)
  (:import-from #:ourro.genome
                #:list-genes #:find-gene #:gene-name #:gene-source-text
                #:gene-capabilities #:render-gene-source #:gene-metadata
                #:gene-code-forms #:hot-load-gene)
  ;; The queue lives in OURRO.OBSERVE (M1-6); import + re-export so every
  ;; existing OURRO.EVOLVE call site and consumer is unchanged.
  (:import-from #:ourro.observe
                #:*evolution-queue* #:enqueue-pattern
                #:dequeue-pattern #:queue-length)
  (:export #:assemble-evolution-prompt
           #:harness-manual
           #:api-surface-description
           #:*evolution-system-prompt*
           ;; engine
           #:propose-gene
           #:evolve-from-pattern
           #:evolution-candidate
           #:candidate-status
           #:candidate-gene
           #:candidate-source
           #:candidate-previous-source
           #:candidate-report
           #:candidate-pattern
           #:candidate-diagnostics
           #:candidate-generation-id
           #:candidate->record
           #:record-candidate
           #:*candidate-record-hook*
           #:load-candidate-records
           #:candidate-records-path
           #:purge-workspace-candidate-records
           #:candidate-workspace-residue
           #:retry-shelved-candidates
           #:*evolution-queue*
           #:enqueue-pattern
           #:process-evolution-queue
           #:apply-candidate
           ;; staged consent lifecycle (M14-2)
           #:candidate-registers-automations-p
           #:should-stage-p
           #:stage-candidate
           #:duplicate-automation-verdict
           #:*rate-limit-seconds*
           #:*last-evolution-time*
           #:*progress-hook*
           #:*politeness-hook*
           #:extract-gene-block
           ;; out-of-process gauntlet (M12-3)
           #:should-verify-out-of-process-p
           #:built-image-argv0-p
           #:verify-out-of-process
           #:verify-mined-block
           #:parse-verify-verdict
           #:*verify-runner*))

(in-package #:ourro.evolve)

(defun harness-api-packages ()
  "Packages whose external symbols count as harness verbs (not CL re-exports).
OURRO.API is included so macros defined there — DEFGENE — are documented."
  (remove nil (list (find-package :ourro.kernel)
                    (find-package :ourro.tools)
                    (find-package :ourro.toolkit)
                    (find-package :ourro.tui)
                    (find-package :ourro.util)
                    (find-package :ourro.observe)
                    (find-package :ourro.api))))

(defun api-surface-description ()
  "Introspect OURRO.API's exported symbols into a documented API listing.
Functions AND macros are shown (DEFTOOL/DEFGENE were previously invisible),
macros marked [macro]; classes are listed with their direct slots so a gene
can subclass or migrate them (prerequisite knowledge for UI genes, PR-9)."
  (with-output-to-string (out)
    (let ((verbs '()) (classes '())
          (packages (harness-api-packages)))
      (do-external-symbols (symbol :ourro.api)
        (when (member (symbol-package symbol) packages)
          (cond
            ((or (fboundp symbol) (macro-function symbol))
             (pushnew symbol verbs))
            ((find-class symbol nil)
             (pushnew symbol classes)))))
      (dolist (symbol (sort verbs #'string< :key #'symbol-name))
        (let ((macro (macro-function symbol)))
          (format out "  (~(~A~)~{ ~(~A~)~})~:[~; [macro]~]~@[   ; ~A~]~%"
                  symbol
                  (ignore-errors (sb-introspect:function-lambda-list symbol))
                  macro
                  (let ((doc (documentation symbol 'function)))
                    (and doc (truncate-string (first-line doc) 90))))))
      (let ((class-lines (class-surface-description classes)))
        (when (plusp (length class-lines))
          (format out "~%CLASSES (subclass or migrate with UPDATE-INSTANCE-FOR-REDEFINED-CLASS):~%~A"
                  class-lines))))))

(defun class-surface-description (class-symbols)
  "For each class symbol, list its direct slots' names and initargs."
  (with-output-to-string (out)
    (dolist (symbol (sort (copy-list class-symbols) #'string< :key #'symbol-name))
      (let ((class (find-class symbol nil)))
        (when class
          (ignore-errors (sb-mop:finalize-inheritance class))
          (format out "  ~(~A~) — slots:~{ ~(~A~)~}~%"
                  symbol
                  (mapcar #'sb-mop:slot-definition-name
                          (ignore-errors (sb-mop:class-direct-slots class)))))))))

(defun first-line (string)
  (let ((newline (position #\Newline string)))
    (if newline (subseq string 0 newline) string)))

(defun harness-manual ()
  "The always-current description of the genome grammar and rules."
  (format nil "~
ourro HARNESS MANUAL (generated from the live image)

You write GENES. A gene is one S-expression that adds or redefines a
capability of the agent — most often a tool. Genes are compiled, contract-
checked, and tested before they ever run; the agent is never edited as text.

GENE GRAMMAR
  (defgene <category>/<name>
      (:generation <n> :parent <gene-name-or-nil>
       :capabilities (<caps>)                ; subset of ~S
       :provenance (:pattern \"<id>\" :model \"<model>\"))
    (:doc \"One paragraph: what this gene does and why it helps the user.\")
    (:code
      <one or more definitions — usually a single DEFTOOL>)
    (:tests
      (test <name> <fiveam assertions…>)     ; at least one required
      …))

DEFTOOL
  (deftool <lisp-name>
      ((<arg> <type> \"<description>\" :required t)      ; type ∈ :string
       (<arg> <type> \"<description>\" :default <value>))  ;  :integer :boolean
                                                          ;  :number :array
    (:doc \"What the tool does (becomes the model-facing description).\")
    (:contract (:pre (<forms true before>) :post (<forms true of RESULT>)))
    <body — the args are bound as locals; RESULT is bound in :post>)
  A tool MUST return a string. RESULT is bound to it in :post forms.

CAPABILITIES & EFFECTS
  Declare every capability your code uses. Effects are ONLY reachable through
  these wrappers (raw OPEN/DELETE-FILE/RUN-PROGRAM are rejected by the lint):
    :filesystem-read   (read-file-numbered path) (list-files …) (search-files …)
    :filesystem-write  (cap/write-file path content) (cap/delete-file path)
    :subprocess        (cap/run-program (list \"cmd\" \"arg\")) → (values output code)
    :network           (cap/http-request url …)
    :llm               (complete provider system messages tools)
    :observe           (recent-events …) (enqueue-pattern pattern)
                       (add-turn-hook name thunk)  ; be a smarter miner
  A tool that declares :filesystem-read but tries to write signals a
  capability violation at runtime AND is rejected by the walker at lint.

UI GENES (grow the interface, not just tools — capability :ui)
  The TUI is CLOS: panes are objects, RENDER-COMPONENT is a generic function,
  and keymaps are data. A gene with :ui can redecorate the live screen with no
  restart. Three verbs (all require :ui):
    (define-status-widget <name> (:interval <seconds>) <body…>)
        Register a right-aligned status-bar cell. BODY takes no arguments and
        returns a SHORT string; it is called at most every <seconds>. Read-only
        work only (e.g. (cap/read-file …) with :filesystem-read also declared).
    (add-pane <pane-instance>)   /   (remove-pane <pane-instance>)
        Splice a pane above the ticker. Define it as
          (defclass <name> (pane) (<slots…>))
          (defmethod render-component ((p <name>) width)
            (list (list (styled :accent \"…\")) …))   ; ≤6 lines
        then (add-pane (make-instance '<name>)). RENDER-COMPONENT must be a
        PURE function of the pane's slots → styled-span lines: no I/O, no
        effects. A styled span is (styled <style-keyword> \"text\"); a line is a
        list of spans; the method returns a list of lines.
    (bind-key <chord> <command-keyword> <thunk>)
        Bind a spare chord (:alt-<letter>, unused ctrl chords — NEVER an
        F-key; the whole F-row is reserved) to a 0-arg THUNK.
  SAFETY: every widget refresh and pane render runs guarded; three errors in a
  row retire the element and revert this gene automatically (like probation) —
  so a render that can signal is simply removed, never a torn screen. Keep
  RENDER bodies total and cheap.
  LIVE CLASS MIGRATION (the showcase): if you REDEFINE a pane class to add a
  slot, give the slot an :initform. On-screen instances are migrated in place
  by UPDATE-INSTANCE-FOR-REDEFINED-CLASS on the next repaint — you may
  specialize that generic for custom migration. The running object becomes the
  new shape without being recreated; the conversation and the pane persist.

AUTOMATION GENES (reflexes — act proactively, not just when asked; capability :automate)
  A reflex subscribes to the live event stream and runs a background action when
  a trigger fires — the edit→test loop, a dev-server's death, an idle lull. One
  verb (requires :automate):
    (define-automation <name>
        (:on <pattern> :cooldown <seconds> :defer :immediate|:turn-boundary)
      <body — the matched EVENT plist is bound if you name `event`>)
  TRIGGER PATTERNS are pure data (a plist keyed by event fields). Value forms:
  a literal (matched with EQUAL), (:not x), (:any x y…), (:matches \"regex\"),
  (:> n), (:< n), or a nested plist to descend into a plist-valued field.
    (:on (:kind :job-exit :exit (:not 0)))                  ; a job failed
    (:on (:kind :tool-call :tool \"edit_file\" :outcome :ok
          :args (:path (:matches \"\\\\.lisp$\"))))            ; a .lisp edit
    (:on (:idle 300))    ; 300s of user idleness    (:on (:every 600))  ; interval
  RULES:
    - Long or effectful work goes through (start-job \"…\") — a reflex must not
      block; the 60s watchdog reverts one that does.
    - Surface results with (post-note \"…\" :style :warning) — a ticker now and a
      note prefixed to the next user message. NEVER write user files from a
      reflex, and never print or touch the transcript.
    - :tool-call/:user-message/:correction triggers default to :turn-boundary
      (coalesced, fired once after the turn); job-exit/idle/every fire
      immediately. :cooldown (default 30s) rate-limits either way.
    - A gene with :automate MUST contain a DEFINE-AUTOMATION (and vice versa).
    - Firings run on probation and three-strikes: an erroring reflex reverts
      itself, exactly like a bad tool. Test yours hermetically with
      (fire-automation-for-test '<name> <synthetic-event-plist>) in :tests.
  Example:
    (define-automation retest-on-lisp-edit
        (:on (:kind :tool-call :tool \"edit_file\" :outcome :ok
              :args (:path (:matches \"\\\\.lisp$\"))) :cooldown 30)
      (start-job \"make test\")
      (post-note \"re-running tests after your edit\" :style :info))

AVAILABLE API (introspected — names and arglists are authoritative):
~A
RULES
  - Respond with EXACTLY ONE gene form inside <gene>…</gene> tags. No prose
    outside the tags, no markdown fences inside them.
  - Every claim in a :doc must be backed by a :contract or a test.
  - Prefer redefining an existing tool (same name) to adding a near-duplicate.
  - Keep tools deterministic: given the same args they do the same thing with
    no LLM call. There is no RANDOM in the gene surface — learned behavior must
    be reproducible machine code. For a pure read-only tool you may PROVE this
    by adding a :determinism probe to the metadata:
      :determinism ((\"<tool_name>\" :<arg> <value> …))
    the gauntlet re-runs that tool with those args and rejects the gene unless
    every run is byte-identical.
  - Tests must be HERMETIC: no live network calls, no absolute paths, no
    dependence on this machine's state. Tests run in a throwaway sandbox
    directory under a ~As watchdog — create any fixture files they need,
    and for a :network tool test the pure parts (URL building, parsing)
    rather than performing a real request.
"
          ourro.kernel:+all-capabilities+
          (api-surface-description)
          ourro.verify:*test-timeout-seconds*))

(defvar *evolution-system-prompt* nil
  "Cached manual; recomputed when NIL (after any redefinition it can be
cleared to force a refresh).")

(defun evolution-system-prompt ()
  (or *evolution-system-prompt*
      (setf *evolution-system-prompt* (harness-manual))))

;; PR-9: after any hot-load the cached manual describes the pre-evolution
;; image. Clear it so the next proposal re-introspects the live surface.
(setf ourro.genome:*hot-load-hook*
      (lambda (gene) (declare (ignore gene))
        (setf *evolution-system-prompt* nil)))


(defun gene-tool-api-names (gene)
  "The tool API names GENE defines (e.g. \"read_file\")."
  (loop for definition in (ourro.genome:gene-definition-names gene)
        when (eq (first definition) :tool)
          collect (second definition)))

(defun pattern-tool-names (pattern)
  (mapcar (lambda (tool) (string-downcase (princ-to-string tool)))
          (pget pattern :tools)))

(defun gene-category (gene)
  "The category prefix of a gene name, e.g. \"tool\" from \"tool/read-file\"."
  (let ((slash (position #\/ (gene-name gene))))
    (and slash (subseq (gene-name gene) 0 slash))))

(defun score-gene-for-pattern (gene pattern)
  "Relevance score: 2×|shared tools| + 1 (same category) + small recency term.
Higher is better; the recency term breaks ties toward newer genes."
  (let* ((gene-tools (gene-tool-api-names gene))
         (overlap (length (intersection gene-tools (pattern-tool-names pattern)
                                        :test #'string=)))
         (category (gene-category gene))
         (pattern-category (pget pattern :category "tool")))
    (+ (* 2 overlap)
       (if (equal category pattern-category) 1 0)
       (/ (or (ourro.genome:gene-generation gene) 0) 100000.0))))

(defun nearest-genes (pattern &key (limit 2))
  "Pick the genes most relevant to PATTERN as few-shot examples, scored by
shared tools, category match, and recency; deterministic tie-break by name."
  (let* ((scored (mapcar (lambda (gene)
                           (cons gene (score-gene-for-pattern gene pattern)))
                         (list-genes)))
         (ranked (stable-sort scored
                              (lambda (a b)
                                (if (= (cdr a) (cdr b))
                                    (string< (gene-name (car a)) (gene-name (car b)))
                                    (> (cdr a) (cdr b)))))))
    (mapcar #'car (subseq ranked 0 (min limit (length ranked))))))

(defun describe-pattern (pattern)
  (let ((base (describe-pattern-body pattern))
        (feedback (pget pattern :retry-feedback)))
    (if feedback
        (format nil "~A~%~%A previous attempt to automate this failed with:~%~A~%~
Avoid that mistake this time."
                base (truncate-string feedback 800))
        base)))

(defun describe-pattern-body (pattern)
  (case (pget pattern :kind)
    (:repeated-command
     (format nil "You repeatedly called the tool ~{~A~} with similar arguments ~
(~A times observed). Argument skeleton (:? marks the parts that varied):~%  ~S"
             (pget pattern :tools) (pget pattern :count)
             (pget pattern :skeleton)))
    (:repeated-sequence
     (format nil "You repeatedly ran this sequence of tools ~A times:~%  ~{~A~^ → ~}~%~
Consider fusing them into one tool that performs the whole sequence."
             (pget pattern :count) (pget pattern :tools)))
    (:onboarding
     (format nil "The user is onboarding ourro onto their repository. This ~
command was probed and works (exit ~A in ~Ams):~%  ~{~A~^ ~}~%~%~
Create the gene ~A defining a tool named repo-~(~A~) (callable as ~A) that runs ~
EXACTLY this command via cap/run-program (capabilities: (:subprocess)), ~
returning a compact summary — parse pass/fail counts from the output, and ~
include the output tail on a nonzero exit. Test the PARSING as pure functions ~
against this captured real output (do NOT run the command in the test):~%~%~A"
             (pget pattern :exit) (pget pattern :ms)
             (pget pattern :command)
             (pget pattern :gene-name)
             (pget pattern :role)
             (first (pget pattern :tools))
             (truncate-string (or (pget pattern :output-head) "") 1500)))
    (:slow-tool
     (format nil "The tool ~{~A~} is SLOW for this user: ~A calls with similar ~
arguments, median ~Ams each. Argument skeleton (:? marks the parts that ~
varied):~%  ~S~%~%Propose a gene that makes this specific call faster — cache a ~
repeated result, batch/narrow the work, or precompute — without changing its ~
answer. The benefit to beat is the measured median (~Ams/call)."
             (pget pattern :tools) (pget pattern :count)
             (pget pattern :occurrence-cost-ms)
             (pget pattern :skeleton)
             (pget pattern :occurrence-cost-ms)))
    (:reaction
     (format nil "After a recurring trigger, you repeatedly run the same tool ~
next (~A times observed). The trigger's shape (use it VERBATIM as the ~
automation's :on pattern):~%  ~S~%The reaction you keep performing is the tool ~
~A (argument skeleton, :? marks the parts that varied):~%  ~S~%~%Write an ~
AUTOMATION gene (capability :automate): a DEFINE-AUTOMATION with EXACTLY this ~
:on pattern that performs the reaction in the BACKGROUND — use (start-job \"…\") ~
for any subprocess work, never block — and (post-note \"…\" :style :info) a ~
short summary of the outcome. NEVER modify user files from a reflex. The ~
benefit to beat is the measured cost of one manual reaction (~Ams)."
             (pget pattern :count)
             (pget pattern :trigger-shape)
             (pget pattern :reaction-tool)
             (pget pattern :reaction-skeleton)
             (pget pattern :occurrence-cost-ms)))
    (:correction
     (format nil "The user corrected the agent ~A times about the same thing ~
(class ~S).~@[ In their own words:~%~{  \"~A\"~%~}~]~%~
Prefer REDEFINING the existing tool gene (same gene name) with the corrected ~
behavior rather than adding a near-duplicate — live redefinition through the ~
same revert tables is exactly what this substrate is for."
             (pget pattern :count)
             (pget pattern :correction-class)
             (remove nil (mapcar (lambda (e) (pget e :text))
                                 (pget pattern :evidence)))))
    (t (format nil "Observed pattern: ~S" pattern))))

(defun harvest-exemplars (pattern &key (limit 3))
  "Up to LIMIT recent successful real calls to the pattern's tools, harvested
independently from the event log — grounding beyond the pattern's own
evidence (PR-9)."
  (let ((tools (pattern-tool-names pattern))
        (found '()))
    (dolist (event (ourro.observe:recent-events :kind :tool-call :limit 400))
      (when (and (< (length found) limit)
                 (eq (pget event :outcome) :ok)
                 (member (string-downcase (princ-to-string (pget event :tool)))
                         tools :test #'string=))
        (push (list (pget event :tool) (pget event :args)) found)))
    (nreverse found)))

(defun assemble-evolution-prompt (pattern)
  "Return (values system-prompt user-prompt) for proposing a gene from
PATTERN, assembled from the live image."
  (let ((neighbors (nearest-genes pattern))
        (exemplars (append (mapcar (lambda (evidence)
                                     (list (pget evidence :tool) (pget evidence :args)))
                                   (pget pattern :evidence))
                           (harvest-exemplars pattern))))
    (values
     (evolution-system-prompt)
     (format nil "~
An automation opportunity was mined from the user's actual session:

~A

Recent real invocations (grounding examples):
~{  ~S~%~}
Here are the ~A nearest existing genes as style references:

~{~A~%~}
Propose ONE gene that automates this pattern and helps the user. Return it
inside <gene>…</gene>."
             (describe-pattern pattern)
             (remove-duplicates exemplars :test #'equal :from-end t)
             (length neighbors)
             (mapcar (lambda (gene)
                       (format nil "<gene>~%~A</gene>"
                               (or (gene-source-text gene)
                                   (render-gene-source gene))))
                     neighbors)))))

(defun extract-gene-block (text)
  "Extract the <gene>…</gene> body from model TEXT. Falls back to the first
top-level (defgene …) form if the tags are absent."
  (let ((start (search "<gene>" text))
        (end (search "</gene>" text)))
    (cond ((and start end (< start end))
           (trim (subseq text (+ start 6) end)))
          (t
           (let ((defgene (search "(defgene" text)))
             (when defgene (trim (subseq text defgene))))))))
