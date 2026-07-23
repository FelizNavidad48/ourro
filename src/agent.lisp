
(defpackage #:ourro.agent
  (:use #:cl #:ourro.util)
  (:export #:run-agent
           #:*agent*
           #:agent
           #:make-agent
           #:agent-provider
           #:agent-view
           #:agent-conversation
           #:submit-message
           #:process-turn
           #:enqueue-ui
           #:handle-key
           #:dispatch-command
           #:serialize-session
           #:restore-session
           #:agent-generation
           #:smoke-test))

(in-package #:ourro.agent)

;; Defined with their production defaults in investigate.lisp, which loads
;; after the core agent implementation. Declaring the specials here keeps the
;; explicit ASDF order warning-free while WIRE-OBSERVER remains product-layer.
(defvar *investigation-max-steps*)
(defvar *investigation-watchdog-seconds*)

(defvar *agent* nil "The singleton agent for the running image.")

(defclass agent ()
  ((provider :initarg :provider :accessor agent-provider)
   (view :initarg :view :accessor agent-view)
   (screen :initarg :screen :initform nil :accessor agent-screen)
   (conversation :initform '() :accessor agent-conversation
                 :documentation "Canonical messages, oldest first.")
   (system-prompt :initarg :system-prompt :accessor agent-system-prompt)
   (generation :initarg :generation :initform "gen-0001"
               :accessor agent-generation)
   (session-id :initarg :session-id :initform nil :accessor agent-session-id)
   (supervisor :initarg :supervisor :initform nil :accessor agent-supervisor)
   (event-queue :initform '() :accessor agent-event-queue)
   (queue-lock :initform (bt:make-lock "ourro-agent-queue") :accessor agent-queue-lock)
   (queue-cv :initform (bt:make-condition-variable) :accessor agent-queue-cv)
   (running :initform t :accessor agent-running)
   (busy :initform nil :accessor agent-busy)
   ;; Turn cancellation (M7-1). Plain single-writer slots, the same discipline
   ;; as BUSY: the UI thread sets CANCEL-REQUESTED, the turn worker reads it at
   ;; its natural boundaries (a torn read only costs one boundary's latency).
   (cancel-requested :initform nil :accessor agent-cancel-requested
                     :documentation "Set by the UI thread (esc / first ctrl-c)
while a turn is busy; the turn worker checks it at stream/tool boundaries and
unwinds via TURN-CANCELLED. Cleared when a turn is claimed and in its cleanup.")
   (cancel-time :initform 0 :accessor agent-cancel-time
                :documentation "get-universal-time of the cancel request, for
escalation timing.")
   (cancel-escalated :initform nil :accessor agent-cancel-escalated
                     :documentation "T once MAYBE-ESCALATE-CANCEL has interrupted
the worker, so it fires at most once per request.")
   (turn-thread :initform nil :accessor agent-turn-thread
                :documentation "The live turn worker thread, recorded at claim
time so escalation can BT:INTERRUPT-THREAD it.")
   (last-interrupt :initform 0 :accessor agent-last-interrupt
                   :documentation "get-universal-time of the last ctrl-c press,
for the double-press-quits window in INTERRUPT-ACTION.")
   (tool-results :initform '() :accessor agent-tool-results
                 :documentation "Tool-output ring (M7-5): newest-first plists
(:n :name :args :result :error-p :ms), capped at *TOOL-RESULT-RING-SIZE*. The
pager overlay (ctrl-o / /out) reads a snapshot. Rebuild+setf per D-1 — the turn
worker writes, the UI thread reads. Transient: never serialized into handoffs.")
   (tool-result-count :initform 0 :accessor agent-tool-result-count
                      :documentation "Monotonic count of tool results recorded
this session, so the newest ring entry keeps its original [N] index label.")
   (last-prompt-tokens :initform 0 :accessor agent-last-prompt-tokens
                       :documentation "Prompt (input) tokens the provider
reported for the most recent model call — the live context-window gauge (M11-1).")
   (session-cost :initform 0.0d0 :accessor agent-session-cost
                 :documentation "Accumulated USD cost this session when the
model's pricing is known, else 0 (M11-1); surfaced by the context/cost HUD.")
   (pending-compaction :initform nil :accessor agent-pending-compaction
                       :documentation "A prepared stage-2 summary awaiting
application: (:prefix-n N :anchor <message-at-n-1> :summary S). Applied at the
next process-turn iff the anchor is still eq at position N-1 — a stale summary
(the conversation moved) is dropped, never spliced (M11-3).")
   (briefings :initform '() :accessor agent-briefings
              :documentation "Briefings ring (M15-2): newest-first plists
(:n :title :text :time :automation), capped at *BRIEFING-RING-SIZE*. Filled by
background investigations; read by /out b<n>. Rebuild+setf (D-1): the reflex
worker writes, the UI thread reads.")
   (briefing-count :initform 0 :accessor agent-briefing-count
                   :documentation "Monotonic briefing counter, so /out b<n>
labels stay stable as the ring rolls.")
   (stream-text :initform "" :accessor agent-stream-text
                :documentation "Accumulated text of the assistant message
currently streaming into the transcript (M2-1).")
   (stream-start :initform nil :accessor agent-stream-start
                 :documentation "Index in transcript-lines where the
in-progress streamed message begins, or NIL when nothing is streaming.")
   (stream-head :initform nil :accessor agent-stream-head
                :documentation "The transcript lines BEFORE the streamed
message, captured once when streaming begins. Reused each delta so a token
rebuilds only the tail rather than re-copying the whole prior transcript
twice (subseq + append) per delta (M2-1).")
   (mode :initarg :mode :initform :auto :accessor agent-mode)
   (visiting :initarg :visiting :initform nil :accessor agent-visiting)
   (recovered-from-checkpoint :initform nil :accessor agent-recovered-from-checkpoint
                              :documentation "T between a crash-recovery resume
and the first turn that proves the restored session healthy. While set, the
supervisor still treats this boot's checkpoint as suspect (poison on a crash);
we clear it — and tell the supervisor — once a full turn survives, so a much
later, unrelated crash resumes the FRESH checkpoint instead of discarding it
(M4-1 review #1).")
   (pending-handoff :initform nil :accessor agent-pending-handoff)
   (pending-travel :initform nil :accessor agent-pending-travel
                   :documentation "Plist (:hard B :visiting B) set by
REQUEST-TRAVEL to distinguish a user /travel from a generation restart. When
set, PERFORM-HANDOFF forwards :hard/:visiting to the supervisor so it re-roots
or read-only-visits rather than advancing the current generation (F-travel).")
   (pending-arrival :initform nil :accessor agent-pending-arrival
                    :documentation "Plist (:from :to :gene :benefit) describing
the evolution that triggered a pending generation restart, surfaced as the
arrival moment after the seamless restart (M2-5).")
   (worker-threads :initform '() :accessor agent-worker-threads)
   (last-mine :initform 0 :accessor agent-last-mine)
   (candidates :initform '() :accessor agent-candidates
               :documentation "Applied/attempted candidates, newest first.")
   (candidates-lock :initform (bt:make-lock "ourro-agent-candidates")
                    :accessor agent-candidates-lock
                    :documentation "Serializes the candidate-list
read-modify-writes: the record hook fires on evolver/onboarding worker
threads while the UI thread mutates the same slot in cmd-revert.")
   (pending-retirements :initform '() :accessor agent-pending-retirements
                        :documentation "Alist (gene-name . reason) of genes
announced for retirement, effective at the next turn boundary unless /keep
freezes them first (M1-1).")
   (pending-submissions :initform '() :accessor agent-pending-submissions
                        :documentation "FIFO of submission texts the user
entered mid-turn (typeahead, M4-2). Drained one per turn boundary; serialized
into the handoff so queued work survives a generation restart.")
   (submissions-lock :initform (bt:make-lock "ourro-agent-submissions")
                     :accessor agent-submissions-lock
                     :documentation "Guards PENDING-SUBMISSIONS: enqueue runs
on the UI thread, drain is triggered from turn-done on the UI thread, but a
handoff serialization can read it from a worker.")))

(defun make-agent (&key provider (generation "gen-0001") supervisor
                        (mode :auto) visiting session-id)
  (or (ourro.tui:set-theme (ourro.config:setting :theme :light))
      (ourro.tui:set-theme :light))
  (let ((view (ourro.tui:make-view
               :repo (display-repo)
               :generation generation)))
    (setf (ourro.tui:statusbar-mode (ourro.tui:view-statusbar view)) mode)
    (make-instance 'agent
                   :provider provider
                   :view view
                   :generation generation
                   :supervisor supervisor
                   :mode mode
                   :visiting visiting
                   :session-id session-id
                   :system-prompt (compose-system-prompt
                                   :provider provider
                                   :generation generation))))

(defun display-repo ()
  (let ((name (first (last (pathname-directory
                            (uiop:ensure-directory-pathname
                             ourro.toolkit:*workspace*))))))
    (or name "workspace")))


(defun compose-system-prompt (&key provider (generation "gen-0001"))
  ;; PROMPT-CACHE INVARIANT (M10-3): this text must stay byte-stable within a
  ;; generation — it is the cached prefix for both Bedrock (an explicit
  ;; cachePoint) and Gemini (implicit prefix caching). NO volatile state may
  ;; enter it: jobs, context %, tickers, token counts, timestamps. Per-turn
  ;; state rides the message tail instead (e.g. job-exit notes prefixed to the
  ;; next user message, M9-4). It is a pure format over the generation id, the
  ;; genome dir, and the sorted tool names — keep it that way.
  (declare (ignore provider))
  (format nil "~
You are ourro, a self-evolving Common Lisp coding agent — currently ~
generation ~A.

You live as a compiled SBCL image. Your capabilities are GENES: verified ~
DEFGENE S-expressions kept in a genome git repository~@[ at ~A~]. You can ~
genuinely read and modify yourself:
- list_genes and read_gene inspect your own genome source.
- evolution_manual returns the exact gene grammar, your OURRO.API surface, ~
capability wrappers, and the rules a gene must satisfy.
- propose_gene submits a gene you wrote to the verification gauntlet ~
(safe-read → structure → capability lint → compile → sandboxed tests). If it ~
passes, it hot-loads IMMEDIATELY — the new tool is callable on your very next ~
step of this same conversation — and a new generation image builds in the ~
background.

When the user asks for a new capability or tool: call evolution_manual, write ~
the gene, submit it with propose_gene, then use the new tool. Never write ~
.gene files into the workspace with write_file — that does nothing; ~
propose_gene is the only path into your genome. Independently, a background ~
miner watches your tool usage for repeated patterns and grows tools ~
automatically between turns.

You can also grow UI: status widgets, panes, and keybindings are genes too ~
(capability :ui — see evolution_manual). A pane redefined to add a slot ~
migrates its live on-screen instance in place, no restart.

You are working in the repository at ~A. You help the user with real software ~
tasks: reading and editing files, running the project's build/test/lint ~
commands, searching, and answering questions. Use the available tools; prefer ~
making concrete edits and running commands over describing what you would do. ~
Read-only tools (reads, searches, listings) issued together in one step run ~
concurrently, so batch independent reads rather than fetching them one by one. ~
Keep replies concise and technical.

Available tools this generation: ~{~A~^, ~}. This list refreshes on every ~
step, so tools you or the miner grow appear immediately."
          generation
          (and ourro.genome:*genome-directory*
               (namestring ourro.genome:*genome-directory*))
          ourro.toolkit:*workspace*
          (mapcar #'ourro.tools:tool-name (ourro.tools:list-tools))))

(defun refresh-system-prompt (agent)
  (setf (agent-system-prompt agent)
        (compose-system-prompt :provider (agent-provider agent)
                               :generation (agent-generation agent))))


(defvar *log-stream* nil)
(defvar *saved-output-streams* nil)

(defun redirect-side-output ()
  (unless *log-stream*
    (setf *log-stream*
          (handler-case
              (let ((path (ourro-path "state/agent-output.log")))
                (ensure-directories-exist path)
                (open path :direction :output
                           :if-exists :append
                           :if-does-not-exist :create))
            (error () (make-broadcast-stream)))))
  (setf *saved-output-streams*
        (list *standard-output* *error-output* *trace-output*))
  (setf *standard-output* *log-stream*
        *error-output* *log-stream*
        *trace-output* *log-stream*))

(defun restore-side-output ()
  (when *saved-output-streams*
    (destructuring-bind (out err trace) *saved-output-streams*
      (setf *standard-output* out
            *error-output* err
            *trace-output* trace))
    (setf *saved-output-streams* nil))
  (when *log-stream*
    (ignore-errors (finish-output *log-stream*))))


(defun enqueue-ui (agent event)
  "Push EVENT (a plist) onto the agent's event queue and wake the runloop.
Safe from any thread."
  (bt:with-lock-held ((agent-queue-lock agent))
    (setf (agent-event-queue agent)
          (append (agent-event-queue agent) (list event)))
    (bt:condition-notify (agent-queue-cv agent)))
  event)

(defun drain-events (agent)
  (bt:with-lock-held ((agent-queue-lock agent))
    (prog1 (agent-event-queue agent)
      (setf (agent-event-queue agent) '()))))

(defun wait-for-events (agent &key (timeout 0.1))
  (bt:with-lock-held ((agent-queue-lock agent))
    (when (null (agent-event-queue agent))
      (bt:condition-wait (agent-queue-cv agent) (agent-queue-lock agent)
                         :timeout timeout))))


(defun add-transcript-line (agent line)
  (let ((transcript (ourro.tui:view-transcript (agent-view agent))))
    (setf (ourro.tui:transcript-lines transcript)
          (append (ourro.tui:transcript-lines transcript) (list line)))))

(defun wrapped-lines (agent text style &key prefix hang)
  "TEXT word-wrapped to the current width as a list of single-span styled
lines (PREFIX, if any, leads the first line). HANG, if given, is a string
prepended to every continuation (non-first) line so wrapped text keeps a hanging
indent aligned under the first line's content instead of drifting to the margin."
  (let ((width (max 20 (- (screen-width-or-default agent) 2))))
    (loop for wrapped in (ourro.tui:wrap-text text width)
          for first = t then nil
          collect (list (ourro.tui:styled style
                                         (format nil " ~A~A"
                                                 (cond (first (or prefix ""))
                                                       (hang hang)
                                                       (t ""))
                                                 wrapped))))))

(defun add-wrapped (agent text style &key prefix hang)
  (dolist (line (wrapped-lines agent text style :prefix prefix :hang hang))
    (add-transcript-line agent line)))

(defun screen-width-or-default (agent)
  (if (agent-screen agent)
      (ourro.tui:screen-width (agent-screen agent))
      80))

(defun set-ticker (agent text &key (style :ticker) actions (seconds 8))
  (let ((ticker (ourro.tui:view-ticker (agent-view agent))))
    (setf (ourro.tui:ticker-text ticker) text
          (ourro.tui:ticker-style ticker) style
          (ourro.tui:ticker-actions ticker) actions
          (ourro.tui:ticker-expires ticker) (+ (get-universal-time) seconds))))

(defun tick-ticker (agent)
  (let ((ticker (ourro.tui:view-ticker (agent-view agent))))
    (when (and (ourro.tui:ticker-text ticker)
               (> (get-universal-time) (ourro.tui:ticker-expires ticker)))
      (setf (ourro.tui:ticker-text ticker) nil))))

(defun set-activity (agent text)
  (setf (ourro.tui:statusbar-activity
         (ourro.tui:view-statusbar (agent-view agent)))
        text))


(defparameter *cancel-double-press-window* 1.5
  "Seconds within which a second ctrl-c means quit, not cancel.")

(defparameter *cancel-escalate-after* 2
  "Seconds a turn may keep running after a cancel request before the worker is
force-interrupted (it may be blocked in a provider read that never checks the
flag).")

(defun request-cancel (agent)
  "Flag the in-flight turn for cancellation (UI thread). Idempotent."
  (unless (agent-cancel-requested agent)
    (setf (agent-cancel-requested agent) t
          (agent-cancel-time agent) (get-universal-time)
          (agent-cancel-escalated agent) nil)
    (set-activity agent "cancelling… (ctrl-c again to quit)")
    (enqueue-ui agent '(:kind :dirty))))

(defun interrupt-action (busy-p last-press now &key (window-ms *cancel-double-press-window*))
  "Pure state machine for a ctrl-c press. Returns :quit when idle or when this
press double-taps within WINDOW-MS of LAST-PRESS; otherwise :cancel (first
press during a busy turn). NOW and LAST-PRESS are universal-times."
  (cond
    ((not busy-p) :quit)
    ((<= (- now last-press) window-ms) :quit)
    (t :cancel)))

(defun check-cancel (agent)
  "Signal TURN-CANCELLED if a cancel is pending. Called at turn boundaries on
the worker thread — the sanctioned unwind point."
  (when (agent-cancel-requested agent)
    (error 'ourro.kernel:turn-cancelled :reason "user cancelled")))

(defun clear-cancel (agent)
  (setf (agent-cancel-requested agent) nil
        (agent-cancel-escalated agent) nil))

(defun maybe-escalate-cancel (agent)
  "If a cancel has been pending for *CANCEL-ESCALATE-AFTER* seconds and the
worker is still busy, interrupt it: the lambda signals TURN-CANCELLED on the
worker thread UNLESS that thread is in an uninterruptible section
(*CANCEL-INHIBITED*), in which case it no-ops. Fires exactly ONCE per request
(CANCEL-ESCALATED latches); if that single shot lands in an inhibited section
the cooperative CHECK-CANCEL boundaries catch the cancel afterward. Runs on the
UI thread (from ui-loop)."
  (when (and (agent-cancel-requested agent)
             (agent-busy agent)
             (not (agent-cancel-escalated agent))
             (> (- (get-universal-time) (agent-cancel-time agent))
                *cancel-escalate-after*))
    (let ((thread (agent-turn-thread agent)))
      (when (and thread (bt:thread-alive-p thread))
        (setf (agent-cancel-escalated agent) t)
        (ignore-errors
         (bt:interrupt-thread
          thread
          (lambda ()
            (unless ourro.kernel:*cancel-inhibited*
              (error 'ourro.kernel:turn-cancelled :reason "user cancelled (escalated)")))))))))


(defun max-tool-iterations ()
  "How many model→tool iterations one turn runs before it stops and asks the
user to say continue (F-turncap: an explicit prompt, never a silent auto-
continue). 25 by default; config :max-tool-steps raises it for big mechanical
tasks (M10-4). Read at turn time so a baked image still honours the config."
  (let ((v (ourro.config:setting :max-tool-steps)))
    (or (and (integerp v) (plusp v) v) 25)))

(defun submit-message (agent text)
  "Handle a user submission: a slash command or a model turn. Runs on a
worker thread so the UI stays responsive."
  (cond
    ((and (plusp (length text)) (char= (char text 0) #\/))
     (dispatch-command agent text)
     ;; A command can mutate durable state (/keep, /revert, /freeze) without
     ;; running a model turn — refresh the crash checkpoint for those (M4-1).
     ;; Pure-display commands (/help, /log, /genome, /tools, /evolutions)
     ;; change nothing the checkpoint captures, so skip the full serialize +
     ;; disk write on them (M4-1 review #3).
     (when (checkpoint-worthy-command-p text)
       (ignore-errors (checkpoint-session agent))))
    ((zerop (length (trim text))) nil)
    (t
     (let ((turn-event (ourro.observe:log-event
                        :user-message :text text
                        :generation (agent-generation agent))))
     ;; A correction ("no, use pnpm not npm") is the highest-signal event we
     ;; can observe — capture it before the turn buries it (M1-2).
     (ignore-errors (ourro.observe:maybe-log-correction text))
     (add-wrapped agent text :user :prefix "❯ ")
     ;; Background-job exit notes reach the model here, prefixed to the next user
     ;; message (M9-4) — never the system prompt, which stays byte-stable for
     ;; prompt caching. The user already saw the ticker fire on exit; this covers
     ;; the model's side. Shown to the model only, not echoed in the transcript.
     (let* ((notes (append (ignore-errors (ourro.jobs:drain-exit-notes))
                           ;; Reflex notes (M13-5) ride the same channel: a
                           ;; ticker fired when they were posted; this gives the
                           ;; model its side, prefixed to the next user message.
                           (ignore-errors (ourro.automation:drain-notes))))
            (full-text (if notes
                           (format nil "~{~A~%~}~%~A" notes text)
                           text)))
       (setf (agent-conversation agent)
             (append (agent-conversation agent)
                     (list (ourro.llm:user-message full-text)))))
     (enqueue-ui agent '(:kind :dirty))
     (ourro.reflex.journal:with-causal-context
         (:trace-id (pget turn-event :trace-id)
          :parent-span-id (pget turn-event :span-id)
          :causation-id (pget turn-event :event-id)
          :turn-id (pget turn-event :event-id)
          :generation (agent-generation agent))
       (process-turn agent))))))

(defun process-turn (agent)
  "Run the model→tool loop until the model stops calling tools."
  (setf (agent-busy agent) t)
  ;; Keep the context window in check before the (whole-conversation) model call
  ;; — apply any ready summary, then elide old tool results past 50% (M11).
  (ignore-errors (maybe-compact-conversation agent))
  (enqueue-ui agent '(:kind :dirty))
  (unwind-protect
       (handler-case
           (progn
           (dotimes (iteration (max-tool-iterations))
             ;; Cancel checkpoint (M7-1): a pending request unwinds here via
             ;; TURN-CANCELLED, before we spend another expensive model call.
             (check-cancel agent)
             (let ((message
                     (handler-case
                         (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
                           (ourro.llm:complete-with-retry
                            (agent-provider agent)
                            (agent-system-prompt agent)
                            (agent-conversation agent)
                            (ourro.tools:tool-declarations)
                            :on-event (lambda (event) (stream-event agent event))
                            ;; A transient 429/5xx shouldn't surface as a hard
                            ;; error — retry with backoff and narrate it (M4-3).
                            :on-retry
                            (lambda (attempt condition)
                              (declare (ignore condition))
                              (set-activity
                               agent
                               (format nil "provider busy — retrying (~D/~D)…"
                                       attempt (ourro.llm:retry-max-attempts)))
                              (enqueue-ui agent '(:kind :dirty)))))
                       (ourro.llm:provider-error (c)
                         ;; Finalize whatever streamed FIRST: the unwind-protect
                         ;; cleanup rebuilds the transcript from the stream head and
                         ;; would otherwise discard an error line appended here
                         ;; (M2-1 review #1). Do it now, then report the error.
                         (when (agent-stream-start agent)
                           (finish-stream agent (agent-stream-text agent)))
                         (reset-stream agent)
                         (add-wrapped agent (format nil "provider error: ~A"
                                                    (ourro.llm:provider-error-message c))
                                      :danger)
                         (enqueue-ui agent '(:kind :dirty))
                         (return-from process-turn)))))
               (setf (agent-conversation agent)
                     (append (agent-conversation agent) (list message)))
               ;; Consume the usage the provider reported (M11-1): the live
               ;; context gauge + the honest running cost.
               (ignore-errors
                (record-turn-usage agent (ourro.llm:message-usage message)))
               (let ((text (ourro.llm:assistant-text message))
                     (tool-calls (ourro.llm:assistant-tool-calls message)))
                 (finish-stream agent text)
                 (cond
                   ((null tool-calls)
                    (enqueue-ui agent '(:kind :dirty))
                    (return-from process-turn))
                   (t
                    (let ((results (run-tool-calls agent tool-calls)))
                      (setf (agent-conversation agent)
                            (append (agent-conversation agent) results))
                      (enqueue-ui agent '(:kind :dirty))
                      ;; A propose_gene call may have grown a tool mid-turn.
                      (refresh-system-prompt agent)))))))
           ;; Falling out of the DOTIMES means we ran all (max-tool-iterations)
           ;; while the model was STILL calling tools (the model-is-done path
           ;; RETURN-FROMs, so it never reaches here). Say so — a silent stop
           ;; is indistinguishable from a clean finish and hides that
           ;; explicitly-requested work never ran (F-turncap).
           (note-turn-capped agent))
         ;; The cancel unwind (M7-1): keep what streamed, mark it, log it. The
         ;; conversation is already well-formed — RUN-TOOL-CALLS synthesized a
         ;; functionResponse for every outstanding call before this fired.
         (ourro.kernel:turn-cancelled () (finalize-cancelled-turn agent)))
    ;; A provider error mid-stream must never leave a dangling ▌ cursor: strip
    ;; it by finalizing whatever streamed, then clear the stream slots.
    (when (agent-stream-start agent)
      (finish-stream agent (agent-stream-text agent)))
    (reset-stream agent)
    (clear-cancel agent)
    ;; BUSY is owned by the UI actor. Keep it true until that actor consumes
    ;; this completion; otherwise keyboard processing can start a new turn in
    ;; the worker→event-queue gap.
    (enqueue-ui agent '(:kind :turn-done)))
  (values nil t))

(defun repair-dangling-tool-calls (agent)
  "If the conversation ends with an assistant message whose tool calls never
received responses, synthesize a cancelled tool-result for each (M7-1 review
#1). The cooperative cancel path already answers every call before unwinding,
but an *escalated* interrupt (bt:interrupt-thread → turn-cancelled) can land
INSIDE execute-tool-call, so RUN-TOOL-CALLS never returns and its results are
never appended — leaving functionCalls with no functionResponse, which 400s the
next Gemini turn. A no-op when the last message is already a tool result (the
cooperative path) or not an assistant turn."
  (let* ((conversation (agent-conversation agent))
         (last (car (last conversation))))
    (when (and last (eq (pget last :role) :assistant))
      (let ((calls (ourro.llm:assistant-tool-calls last)))
        (when calls
          (setf (agent-conversation agent)
                (append conversation
                        (mapcar (lambda (call)
                                  (ourro.llm:tool-result-message
                                   (ourro.llm:tool-call-id call)
                                   (ourro.llm:tool-call-name call)
                                   "cancelled by user" :error-p t))
                                calls))))))))

(defun finalize-cancelled-turn (agent)
  "Handle a TURN-CANCELLED unwind inside PROCESS-TURN: keep the conversation
well-formed (answer any dangling tool calls), finalize any partial streamed text
(the user keeps what arrived), drop a dim marker line, log it, and clear the
activity notice. The unwind-protect cleanup clears BUSY + the cancel flag and
fires :turn-done as usual."
  (repair-dangling-tool-calls agent)
  (when (agent-stream-start agent)
    (finish-stream agent (agent-stream-text agent)))
  (reset-stream agent)
  (add-transcript-line
   agent (list (ourro.tui:styled :dim "⏹ (cancelled)")))
  (set-activity agent nil)
  (ourro.observe:log-event :turn-cancelled)
  (enqueue-ui agent '(:kind :dirty)))

(defun note-turn-capped (agent)
  "The turn hit *MAX-TOOL-ITERATIONS* while the model was still calling tools:
make that visible instead of ending silently (F-turncap). The conversation is
already well-formed (every tool call got a response), so 'continue' resumes it
as an ordinary next turn."
  (set-activity agent nil)
  (add-wrapped agent
               (format nil "stopped after ~D tool steps — say \"continue\" to keep going."
                       (max-tool-iterations))
               :warning :prefix "⚠ ")
  (ourro.observe:log-event :turn-capped :steps (max-tool-iterations))
  (enqueue-ui agent '(:kind :dirty)))

(defparameter *max-parallel-tools* 8
  "Cap on concurrent workers for a read-only tool batch (M10-1).")
(defvar *parallel-tool-semaphore*
  (bt:make-semaphore :count *max-parallel-tools*)
  "Process-wide read-tool admission bound shared by every turn/batch.")

(defun parallel-eligible-p (call)
  "A tool call may run concurrently iff its tool exists, its declared
capabilities are a subset of the read-only set {:filesystem-read}, and its gene
is not on probation. Capabilities license parallelism: the same declarations the
walker gates safety on decide what may run at once. Everything else stays serial
in original order (M10-1)."
  (let ((tool (ourro.tools:find-tool (ourro.llm:tool-call-name call))))
    (and tool
         (subsetp (ourro.tools:tool-capabilities tool) '(:filesystem-read))
         (let ((gene (ourro.tools:tool-gene tool)))
           (or (null gene) (zerop (ourro.kernel:probation-remaining gene))))
         tool)))

(defun tool-call-⚙-line (agent call)
  (add-transcript-line
   agent (list (ourro.tui:styled
                :tool (format nil "   ⚙ ~A ~A" (ourro.llm:tool-call-name call)
                              (truncate-string
                               (compact-args (ourro.llm:tool-call-args call)) 80))))))

(defun finalize-tool-result (agent call result error-p ms)
  "Ring-record, echo the ↳ line, and build the tool-result message — the turn
worker's in-order bookkeeping for one completed call (D-1: sole transcript
writer)."
  (let ((name (ourro.llm:tool-call-name call)))
    (record-tool-result agent name (ourro.llm:tool-call-args call) result error-p ms)
    (echo-tool-result agent result error-p ms)
    (ourro.llm:tool-result-message
     (ourro.llm:tool-call-id call) name
     (ourro.toolkit:clamp-output result :max-chars 20000) :error-p error-p)))

(defun run-tool-call-serial (agent call)
  "Run one tool call the classic way: ⚙ line, execute, record + ↳, result msg."
  (tool-call-⚙-line agent call)
  (enqueue-ui agent '(:kind :dirty))
  (let ((start (get-internal-real-time)))
    (multiple-value-bind (result error-p)
        (ourro.tools:execute-tool-call (ourro.llm:tool-call-name call)
                                      (ourro.llm:tool-call-args call))
      (finalize-tool-result agent call result error-p
                            (elapsed-ms start (get-internal-real-time))))))

(defun tool-call-cancelled-message (agent call)
  (add-transcript-line
   agent (list (ourro.tui:styled
                :dim (format nil "   ⏹ ~A skipped (cancelled)"
                             (ourro.llm:tool-call-name call)))))
  (ourro.llm:tool-result-message
   (ourro.llm:tool-call-id call) (ourro.llm:tool-call-name call)
   "cancelled by user" :error-p t))

(defun run-parallel-tool-batch (agent entries)
  "Run CALLS (all read-only-cap eligible, length ≥2) concurrently, ≤N workers.
Prints every ⚙ line up front, joins (bailing early on cancel — read-only orphans
can only burn CPU), then records the ring + ↳ echoes + result messages IN
ORIGINAL ORDER. Workers touch only execute-tool-call + a locked outcomes table;
all transcript/ring mutation stays on the turn worker (D-1). Returns the
tool-result messages in order."
  ;; Keep the internal helper convenient for focused tests: callers may pass
  ;; bare calls; production passes (call . captured-tool) pairs.
  (setf entries
        (mapcar (lambda (entry)
                  (if (and (consp entry) (keywordp (first entry)))
                      (cons entry
                            (ourro.tools:find-tool
                             (ourro.llm:tool-call-name entry)))
                      entry))
                entries))
  (dolist (entry entries) (tool-call-⚙-line agent (car entry)))
  (enqueue-ui agent '(:kind :dirty))
  (let* ((n (length entries))
         (vec (coerce entries 'vector))
         (outcomes (make-hash-table :test 'eql))   ; index → (result error-p ms)
         (lock (bt:make-lock "ourro-tool-batch"))
         (threads
           (loop for i below n
                 collect (let ((i i))
                           (bt:make-thread
                            (lambda ()
                              (bt:wait-on-semaphore *parallel-tool-semaphore*)
                              (unwind-protect
                                   (let* ((entry (aref vec i))
                                          (call (car entry))
                                          (tool (cdr entry))
                                          (start (get-internal-real-time)))
                                     (multiple-value-bind (result error-p)
                                         (handler-case
                                             (ourro.tools:execute-tool-object
                                              tool
                                              (ourro.llm:tool-call-args call))
                                           (error (c) (values (princ-to-string c) t)))
                                       (bt:with-lock-held (lock)
                                         (setf (gethash i outcomes)
                                               (list result error-p
                                                     (elapsed-ms start (get-internal-real-time)))))))
                                (bt:signal-semaphore *parallel-tool-semaphore*)))
                            :name (format nil "ourro-tool-~A" i)
                            :initial-bindings
                            (list (cons 'ourro.reflex.journal:*causal-context*
                                        (list 'quote
                                              ourro.reflex.journal:*causal-context*))))))))
    ;; Cancellation is joined: no worker from an old turn survives into the
    ;; next turn. DESTROY-THREAD is the bounded last resort for a worker blocked
    ;; in foreign I/O; eligibility limits this path to read-only tools.
    (loop until (or (agent-cancel-requested agent)
                    (notany #'bt:thread-alive-p threads))
          do (sleep 0.01))
    (when (agent-cancel-requested agent)
      (dolist (thread threads)
        (when (bt:thread-alive-p thread)
          (ignore-errors (bt:destroy-thread thread)))))
    (dolist (thread threads) (ignore-errors (bt:join-thread thread)))
    ;; In-order finalize on the turn worker. A call with no recorded outcome
    ;; (still running at cancel time) gets a synthesized cancelled result.
    (prog1
        (loop for i below n
              for call = (car (aref vec i))
              for outcome = (bt:with-lock-held (lock) (gethash i outcomes))
              collect (if outcome
                          (destructuring-bind (result error-p ms) outcome
                            (finalize-tool-result agent call result error-p ms))
                          (tool-call-cancelled-message agent call)))
      (enqueue-ui agent '(:kind :dirty)))))

(defun run-tool-calls (agent tool-calls)
  "Execute the tool calls and return their tool-result messages, IN ORDER.
Consecutive read-only-eligible calls run concurrently (capability-derived
parallelism, M10-1); everything else — and any call once a cancel is seen — runs
serially exactly as before. A cancel mid-batch gives every remaining call a
synthesized cancelled result: Gemini/Converse require a response per call, so a
dangling call would 400 the next turn; the next PROCESS-TURN boundary unwinds."
  (let ((results '())
        (cancelled nil)
        (vec (coerce tool-calls 'vector))
        (captured (make-array (length tool-calls) :initial-element nil))
        (i 0)
        (n (length tool-calls)))
    (loop while (< i n) do
      (cond
        ((or cancelled (agent-cancel-requested agent))
         (setf cancelled t)
         (push (tool-call-cancelled-message agent (aref vec i)) results)
         (enqueue-ui agent '(:kind :dirty))
         (incf i))
        (t
         ;; Extend a maximal run of consecutive parallel-eligible calls.
         (let ((run-end i))
           (loop while (< run-end n)
                 for tool = (parallel-eligible-p (aref vec run-end))
                 while tool
                 do (setf (aref captured run-end) tool)
                    (incf run-end))
           (if (> run-end (1+ i))
               ;; ≥2 eligible in a row → run them together.
               (let ((batch (loop for k from i below run-end
                                  collect (cons (aref vec k)
                                                (aref captured k)))))
                 (dolist (msg (run-parallel-tool-batch agent batch))
                   (push msg results))
                 (setf i run-end))
               ;; A single call (eligible-singleton or not) → today's serial path.
               (progn
                 (push (run-tool-call-serial agent (aref vec i)) results)
                 (incf i)))))))
    (nreverse results)))

(defun elapsed-ms (start end)
  (round (* 1000 (/ (- end start) internal-time-units-per-second))))

(defparameter *tool-result-ring-size* 20
  "How many recent tool outputs the pager ring keeps (M7-5).")

(defvar *tool-output-hint-shown* nil
  "Whether the one-time 'ctrl-o opens full tool output' hint has fired.")


(defun install-job-hooks (agent)
  "Route job-exit notifications to the UI (M9-4). The hook fires on a job's
waiter/poller thread, so it only marshals a UI event via enqueue-ui (D-1); the
note for the MODEL is queued separately and drained by submit-message."
  (setf ourro.jobs:*job-exit-hook*
        (lambda (id job)
          (enqueue-ui agent (list :kind :job-exit :id id :job job)))))

(defun on-job-exit (agent event)
  "A background job exited — announce it in the ticker (UI thread)."
  (let* ((job (pget event :job))
         (id (pget event :id))
         (code (pget job :exit)))
    (set-ticker agent
                (format nil "⚙ job ~A (~A) exited ~A — /out ~A"
                        id (pget job :command) code id)
                :style (if (eql code 0) :success :warning)
                :seconds 8)
    (enqueue-ui agent '(:kind :dirty))))

(defun record-tool-result (agent name args result error-p ms)
  "Push a tool call's full result onto the ring (M7-5), newest-first, capped.
Rebuild-and-setf so the UI thread only ever sees a complete list head (D-1)."
  (let* ((n (incf (agent-tool-result-count agent)))
         (entry (list :n n :name name
                      :args (ignore-errors (compact-args args))
                      :result (princ-to-string result)
                      :error-p error-p :ms ms))
         (ring (cons entry (agent-tool-results agent))))
    (setf (agent-tool-results agent)
          (if (> (length ring) *tool-result-ring-size*)
              (subseq ring 0 *tool-result-ring-size*)
              ring))
    (unless *tool-output-hint-shown*
      (setf *tool-output-hint-shown* t)
      (set-ticker agent "tip: ctrl-o opens full tool output" :style :dim :seconds 6))))

(defun echo-tool-result (agent result error-p ms)
  (let ((head (truncate-string (first-line (princ-to-string result)) 90))
        (n (agent-tool-result-count agent)))
    (add-transcript-line
     agent
     (if error-p
         (list (ourro.tui:styled :danger (format nil "   ↳ [~D] ERROR: ~A" n head)))
         (list (ourro.tui:styled :dim (format nil "   ↳ [~D] ~A · ~Ams" n head ms)))))
    (enqueue-ui agent '(:kind :dirty))))

(defun compact-args (args)
  (with-output-to-string (out)
    (when (hash-table-p args)
      (let ((first t))
        (maphash (lambda (key value)
                   (unless first (write-string " " out))
                   (setf first nil)
                   (format out "~A=~A" key
                           (truncate-string (princ-to-string value) 40)))
                 args)))))


(defun stream-event (agent event)
  ;; Cancel checkpoint (M7-1): a cancel during a stream unwinds from right here,
  ;; on the turn worker. TURN-CANCELLED is not an ERROR, so it passes cleanly
  ;; through the vertex chunk-guard's `(error () nil)` up to PROCESS-TURN.
  (check-cancel agent)
  (case (pget event :kind)
    (:delta
     (let ((chunk (pget event :text "")))
       (when (plusp (length chunk))
         (stream-append agent chunk))))
    (:thinking
     (set-activity agent "reasoning…")
     (enqueue-ui agent '(:kind :dirty)))
    (:done nil)))

(defun stream-tail-lines (agent)
  "The in-progress streamed message rendered through the FULL markdown pipeline
every delta (M7-6), with a block cursor (▌) appended to the last line. Because
the tail and the finalized message call the same MARKDOWN-LINES, finalized text
never 'pops in' — the last streamed frame equals the final render minus the
cursor. Partial markdown degrades gracefully by construction: an unclosed fence
renders as code (which it will become), an unclosed ** falls through literally.
MARKDOWN-LINES is pure and O(message length) — the same class as the per-delta
wrap it replaces — and ui-loop throttles paints, so re-rendering the tail each
delta is not a cost. (A pathological >32KB message could render only up to its
last complete line; not built — noted here as the escape hatch.)"
  (let ((lines (assistant-message-lines agent (agent-stream-text agent))))
    (if lines
        (append (butlast lines)
                (list (append (car (last lines))
                              (list (ourro.tui:styled :accent "▌")))))
        (list (list (ourro.tui:styled :accent " ▌"))))))

(defun stream-append (agent chunk)
  "Append CHUNK to the streaming message and rebuild the transcript tail.
Only the streamed message (from STREAM-START onward) is rewritten (D-1). The
head (everything before the message) is snapshotted once on the first delta and
reused, so a token rebuilds just the tail rather than re-copying the whole prior
transcript per delta."
  (let ((transcript (ourro.tui:view-transcript (agent-view agent))))
    (when (null (agent-stream-start agent))
      (let ((lines (ourro.tui:transcript-lines transcript)))
        (setf (agent-stream-start agent) (length lines)
              (agent-stream-head agent) lines
              (agent-stream-text agent) ""))
      ;; The first streamed token also clears the "reasoning…" activity a
      ;; :thinking event may have set — visible text has begun (M2-5 review).
      (set-activity agent nil))
    (setf (agent-stream-text agent)
          (concatenate 'string (agent-stream-text agent) chunk))
    (setf (ourro.tui:transcript-lines transcript)
          (append (agent-stream-head agent) (stream-tail-lines agent)))
    (enqueue-ui agent '(:kind :dirty))))

(defun reset-stream (agent)
  (setf (agent-stream-start agent) nil
        (agent-stream-head agent) nil
        (agent-stream-text agent) ""))

(defun finish-stream (agent text)
  "Swap the in-progress streamed tail for the final rendered message and reset
the stream slots. When nothing streamed this turn (e.g. a non-streaming
provider), append TEXT normally. Called once per assistant message."
  (let ((transcript (ourro.tui:view-transcript (agent-view agent))))
    (cond
      ((agent-stream-start agent)
       (let ((final (and (plusp (length (trim text)))
                         (assistant-message-lines agent text))))
         (setf (ourro.tui:transcript-lines transcript)
               (append (agent-stream-head agent) final))))
      ((plusp (length (trim text)))
       (dolist (line (assistant-message-lines agent text))
         (add-transcript-line agent line))))
    (reset-stream agent)))

(defun assistant-message-lines (agent text)
  "Final rendered lines for a completed assistant message: minimal markdown
(M2-2) — fenced code, headings, bullets, bold, and inline code."
  (let ((width (max 20 (- (screen-width-or-default agent) 2))))
    (ourro.tui:markdown-lines text width)))


(ourro.tools:deftool list-genes ()
  (:doc "List the genes in your own genome — your evolvable source code. Shows each gene's name, tools, tests, and declared capabilities. Use read_gene to see a gene's full source.")
  (with-output-to-string (out)
    (format out "genome generation ~A · ~A genes~@[ · ~A~]~%"
            (ourro.genome:genome-generation-number)
            (length (ourro.genome:list-genes))
            (and ourro.genome:*genome-directory*
                 (namestring ourro.genome:*genome-directory*)))
    (dolist (gene (ourro.genome:list-genes))
      (format out "  ~A~%" (ourro.genome:gene-summary gene)))))

(ourro.tools:deftool read-gene
    ((name :string "Gene name, e.g. \"tool/read-file\" (see list_genes)" :required t))
  (:doc "Read the full DEFGENE source of one of your own genes. This is self-inspection: the returned S-expression is the authoritative definition of that part of you.")
  (let ((gene (ourro.genome:find-gene name)))
    (if gene
        (or (ourro.genome:gene-source-text gene)
            (ourro.genome:render-gene-source gene))
        (format nil "No gene named ~S. Known genes:~%~{  ~A~%~}"
                name
                (mapcar #'ourro.genome:gene-name (ourro.genome:list-genes))))))

(ourro.tools:deftool evolution-manual ()
  (:doc "Return your harness manual, generated from the live image: the DEFGENE grammar, the OURRO.API surface with real arglists, capability wrappers, and the rules a gene must satisfy. Always read this before writing a gene for propose_gene.")
  (ourro.evolve:harness-manual))

(ourro.tools:deftool verify-determinism
    ((tool :string "Name of a read-only tool to check, e.g. \"read_file\"" :required t)
     (args :string "JSON object of arguments to pass on every run, e.g. {\"path\":\"src/main.lisp\"}" :default "{}"))
  (:doc "Prove a tool is deterministic (PR-13): run it 10 times with identical arguments and confirm every run is byte-identical. This is the demonstration that learned behavior is compiled machine code with zero LLM inference, not a re-prompt. Restricted to side-effect-free read tools (read_file, list_files, search, file_info).")
  (if (not (member tool ourro.verify:*replayable-tools* :test #'string=))
      (format nil "verify_determinism only runs on side-effect-free read tools ~{~A~^, ~}; ~A is not one."
              ourro.verify:*replayable-tools* tool)
      (let ((args-hash (handler-case (ourro.llm:json-decode args)
                         (error () (ourro.llm:json-object)))))
        (multiple-value-bind (deterministic results)
            (ourro.verify:verify-determinism tool args-hash :runs 10)
          (if deterministic
              (format nil "DETERMINISTIC: ~A produced byte-identical output across ~A runs — this is compiled, inference-free behavior."
                      tool (length results))
              (format nil "NON-DETERMINISTIC: ~A varied across 10 runs." tool))))))

(ourro.tools:deftool propose-gene
    ((source :string "Complete (defgene …) source text following the grammar from evolution_manual" :required t)
     (reason :string "One line of provenance: why this gene is being added" :default "user request"))
  (:doc "Submit a gene you wrote to the verification gauntlet (safe-read → structure → capability lint → compile → sandboxed tests). On success the gene hot-loads immediately — its tools are callable on your next step in this conversation — and a new generation image builds in the background. On failure you get compiler-grade diagnostics: fix the gene and call propose_gene again. This is the ONLY way to change your genome deliberately.")
  (deliberate-evolution source reason))

(defun deliberate-evolution (source reason)
  (when ourro.kernel:*evolution-frozen*
    (return-from deliberate-evolution
      "REJECTED: evolution is frozen. Ask the user to run /unfreeze first."))
  ;; propose_gene compiles + hot-loads + snapshots; shield the whole path from a
  ;; mid-mutation escalated turn-cancel (M7-1). HOT-LOAD-GENE re-binds this too.
  (let ((ourro.kernel:*cancel-inhibited* t))
  (handler-case
      (multiple-value-bind (gene report)
          (ourro.evolve::verify-mined-block source)
        (let ((agent *agent*)
              (candidate (make-instance 'ourro.evolve:evolution-candidate
                                        :pattern (list :id (make-id "user")
                                                       :kind :deliberate
                                                       :reason reason))))
          (setf (ourro.evolve:candidate-source candidate) source
                (ourro.evolve:candidate-gene candidate) gene
                (ourro.evolve:candidate-report candidate) report
                (ourro.evolve:candidate-status candidate) :verified)
          (ourro.evolve:apply-candidate
           candidate :force t :snapshot :async
           :on-snapshot (and agent
                             (lambda (done)
                               (announce-candidate agent done))))
          (when agent
            ;; The record hook mirrors the candidate into the list.
            (refresh-system-prompt agent)
            (enqueue-ui agent '(:kind :dirty)))
          (case (ourro.evolve:candidate-status candidate)
            ((:hot-loaded :snapshotted)
             (format nil "VERIFIED and HOT-LOADED gene ~A. Its tools are ~
available to you right now (your tool list refreshes each step) — use them. ~
A generation snapshot is building in the background; the UI announces it ~
when pinned.~%~%Staged test report:~%~A"
                     (ourro.genome:gene-name gene)
                     (or (pget report :test-report) "(no report)")))
            (t
             (format nil "Gene ~A verified but was NOT applied: ~A"
                     (ourro.genome:gene-name gene)
                     (or (ourro.evolve:candidate-diagnostics candidate)
                         "unknown reason"))))))
    (ourro.kernel:verification-failure (failure)
      (format nil "REJECTED at the ~A gate.~%~A~%~%Fix the gene and call ~
propose_gene again with the corrected source."
              (ourro.kernel:verification-failure-stage failure)
              (ourro.kernel:verification-failure-diagnostics failure)))
    (error (c)
      (format nil "ERROR while verifying the gene: ~A" c)))))


(defun on-turn-done (agent)
  (setf (agent-busy agent) nil)
  (refresh-system-prompt agent)
  ;; The rest is turn-boundary bookkeeping that must NOT run on the UI thread:
  ;; run-turn-hooks executes arbitrary evolved gene code, and
  ;; utility-housekeeping can block on a supervisor snapshot round-trip and a
  ;; ledger file write. A slow or misbehaving gene must not be able to freeze
  ;; key handling — so it runs on a short-lived worker that signals the UI via
  ;; enqueue-ui (the same pattern the evolver worker uses for update-pending).
  (bt:make-thread
   (lambda ()
     ;; A turn just completed — pairs with :user-message for turn-latency
     ;; metrics in the QA harness (QA-0). Not a sync primitive: slash commands
     ;; never reach on-turn-done, so awaits key on qa-status, not this event.
     (ignore-errors
      (ourro.observe:log-event :turn-done :generation (agent-generation agent)))
     ;; Turn-structural corrections (rework-same-file, command-preference) can
     ;; only be judged once the turn's tool calls are all in the log (M1-2).
     (ignore-errors (ourro.observe:log-turn-corrections))
     ;; Evolved miners: gene-registered turn hooks, each under its declared
     ;; capabilities (M1-6). update-pending reflects anything enqueued.
     (ignore-errors (ourro.observe:run-turn-hooks))
     ;; Reflexes (M13-4): flush turn-boundary-deferred automations now — after
     ;; the turn's own edits are logged, so test-on-edit fires once, cleanly.
     (ignore-errors (ourro.automation:flush-deferred-automations))
     (ignore-errors (update-pending agent))
     (ignore-errors (utility-housekeeping agent))
     ;; Prepare a stage-2 summary off-turn if we're past 70% of the window; it
     ;; is applied (if still valid) at the next process-turn (M11-3).
     (ignore-errors (prepare-compaction agent))
     (ignore-errors (maybe-mine agent))
     ;; Snapshot the conversation for crash recovery (M4-1): every turn
     ;; boundary is a natural, consistent point — the turn's tool calls are
     ;; all in the log and the transcript is settled.
     (ignore-errors (checkpoint-session agent))
     ;; A recovered session has now survived a full turn and written a fresh
     ;; checkpoint that supersedes the one it resumed. Tell the supervisor to
     ;; stop treating this boot's checkpoint as poison, so a much-later crash
     ;; resumes the fresh state instead of discarding it (M4-1 review #1).
     (ignore-errors (note-recovery-proven agent))
     (enqueue-ui agent '(:kind :dirty)))
   :name "ourro-turn-boundary"
   :initial-bindings
   (list (cons 'ourro.reflex.journal:*causal-context*
               (list 'quote ourro.reflex.journal:*causal-context*)))))


(defparameter *savings-milestones-ms* '(60000 300000 900000)
  "Realized-savings thresholds (60s / 5min / 15min) that fire a ticker once.")

(defun seed-gene-p (name)
  (let ((gene (ourro.genome:find-gene name)))
    (and gene (pget (ourro.genome:gene-provenance gene) :seed))))

(defun format-duration (ms)
  "Compact human duration for a millisecond count: 900ms / 4s / 9m / 1h20m."
  (cond ((< ms 1000) (format nil "~Dms" ms))
        ((< ms 60000) (format nil "~Ds" (round ms 1000)))
        ((< ms 3600000)
         (let ((m (round ms 60000))) (format nil "~Dm" (max 1 m))))
        (t (multiple-value-bind (h rem) (floor ms 3600000)
             (format nil "~Dh~Dm" h (round rem 60000))))))

(defun gene-utility-summary (name)
  "\"14 uses · ≈9m saved\" (savings clause only once measured), or a bare use
count, or NIL when the gene has no recorded uses."
  (let ((uses (ourro.observe:gene-uses name))
        (saved (ourro.observe:gene-savings-ms name)))
    (cond ((and (plusp uses) (plusp saved))
           (format nil "~D use~:P · ≈~A saved" uses (format-duration saved)))
          ((plusp uses) (format nil "~D use~:P" uses))
          (t nil))))

(defun retirement-reason (name)
  "Why NAME should retire, or NIL. Non-seed, non-frozen genes only."
  (when (and (not (seed-gene-p name))
             (not (ourro.observe:gene-frozen-p name))
             (not (ourro.observe:gene-retired-p name)))
    (let* ((u (ourro.observe:gene-utility name))
           (uses (pget u :uses 0))
           (errors (pget u :errors 0))
           (reverts (pget u :reverts 0))
           ;; Age for the unused-gene path is measured from creation, not
           ;; :first-use — a zero-use gene has no first-use to age from.
           (created (pget u :created))
           (age (and created (- (unix-time) created))))
      (cond
        ((>= reverts 2) "reverted repeatedly")
        ((and (>= uses 4) (> errors (floor uses 2))) "errors on most uses")
        ((and (zerop uses) age (> age (* 7 24 60 60))) "unused for 7 days")
        (t nil)))))

(defun utility-housekeeping (agent)
  "Fire savings-milestone tickers; execute + announce gene retirements."
  (ignore-errors
   ;; 1. Execute retirements announced last turn that weren't vetoed by /keep.
   (dolist (entry (agent-pending-retirements agent))
     (destructuring-bind (name . reason) entry
       (unless (ourro.observe:gene-frozen-p name)
         (retire-gene agent name reason))))
   (setf (agent-pending-retirements agent) '())
   ;; 2. Milestones + fresh retirement announcements over every measured gene.
   (dolist (gene (ourro.genome:list-genes))
     (let ((name (ourro.genome:gene-name gene)))
       (unless (seed-gene-p name)
         (announce-savings-milestone agent name)
         (let ((reason (retirement-reason name)))
           (when (and reason
                      (not (assoc name (agent-pending-retirements agent)
                                  :test #'string=)))
             (push (cons name reason) (agent-pending-retirements agent))
             (set-ticker agent
                         (format nil "retiring ~A (~A) · /keep ~A to veto"
                                 name reason name)
                         :style :warning :seconds 12)
             (enqueue-ui agent '(:kind :dirty)))))))
   (ignore-errors (ourro.observe:save-utility-ledger))))

(defun announce-savings-milestone (agent name)
  (let* ((saved (ourro.observe:gene-savings-ms name))
         (u (ourro.observe:gene-utility name))
         (last (pget u :last-milestone 0))
         (crossed (car (last (remove-if (lambda (m) (or (> m saved) (<= m last)))
                                        *savings-milestones-ms*)))))
    (when crossed
      (ourro.observe:set-gene-milestone name crossed)
      (set-ticker agent
                  (format nil "⚡ ~A paid for itself: ~A"
                          name (gene-utility-summary name))
                  :style :success :seconds 10)
      (enqueue-ui agent '(:kind :dirty)))))

(defun retire-gene (agent name reason)
  "Undo NAME's definitions in-image and drop it from the genome manifest.
The .gene file and its git history stay; the genome remains the source of
truth. In dev mode (no supervisor) only the in-image revert happens."
  (let* ((gene (ourro.genome:find-gene name))
         (count (ourro.kernel:revert-gene-definitions name)))
    (when (and gene (zerop count))
      (dolist (definition (ourro.genome:gene-definition-names gene))
        (when (eq (first definition) :tool)
          (ourro.tools:unregister-tool (second definition)))))
    (ourro.observe:set-gene-retired name t)
    (ourro.observe:log-event :gene-retired :gene name :reason reason)
    (when (and gene (ourro.genome:gene-file gene) (agent-supervisor agent))
      (ignore-errors
       (request-snapshot agent
                         (list (list :manifest-remove (ourro.genome:gene-file gene)))
                         (format nil "retire ~A (~A)" name reason)
                         (list :retired name))))
    (refresh-system-prompt agent)
    (set-ticker agent (format nil "retired ~A (~A)" name reason)
                :style :dim :seconds 6)
    (enqueue-ui agent '(:kind :dirty))))

(defun cmd-keep (agent args)
  "Veto a pending retirement: freeze the gene so it is never auto-retired."
  (let ((name (and args (ourro.genome::canonical-gene-name (first args)))))
    (cond
      ((null name)
       (add-wrapped agent "usage: /keep <gene-name>" :dim))
      ((null (ourro.genome:find-gene name))
       (add-wrapped agent (format nil "no gene named ~A" name) :warning))
      (t
       (ourro.observe:set-gene-frozen name t)
       (setf (agent-pending-retirements agent)
             (remove name (agent-pending-retirements agent)
                     :key #'car :test #'string=))
       (add-wrapped agent (format nil "keeping ~A — frozen, will not auto-retire."
                                  name)
                    :success)))))

(defparameter *mine-interval* 20
  "Seconds between mining passes.")

(defun attempted-pattern-signatures ()
  "Signatures of every pattern already attempted (any status — learned,
rejected, reverted, duplicate) plus everything still waiting in the queue.
Mining must never re-enqueue one of these: the event log keeps the old tool
calls around, so without this memory the same pattern is re-mined with a
fresh :id every pass and the genome fills with evolutions of the same thing."
  (append
   (loop for record in (ignore-errors
                        (ourro.evolve:load-candidate-records :limit 200))
         for pattern = (pget record :pattern)
         when pattern collect (ourro.miner:pattern-signature pattern))
   (loop for pattern in ourro.evolve:*evolution-queue*
         collect (ourro.miner:pattern-signature pattern))))

(defun maybe-mine (agent)
  (when (and (eq (agent-mode agent) :auto)
             (not (agent-visiting agent))
             (> (- (get-universal-time) (agent-last-mine agent)) *mine-interval*))
    (setf (agent-last-mine agent) (get-universal-time))
    (let ((patterns (ignore-errors (ourro.miner:mine-patterns))))
      (when patterns
        (let* ((seen (ignore-errors (attempted-pattern-signatures)))
               (top (find-if (lambda (p)
                               (and (>= (pget p :count 0)
                                        ourro.miner:*support-threshold*)
                                    (not (member (ourro.miner:pattern-signature p)
                                                 seen :test #'string=))))
                             patterns)))
          (when top
            ;; :origin :mined opts this pattern into the evolver's LLM
            ;; duplicate-tool gate (deliberate/onboarding patterns skip it).
            (ourro.evolve:enqueue-pattern (plist-put top :origin :mined))
            (update-pending agent)
            (spawn-evolver agent)))))))

(defun update-pending (agent)
  (setf (ourro.tui:statusbar-pending (ourro.tui:view-statusbar (agent-view agent)))
        (ourro.evolve::queue-length)))


(defun prune-workers (agent)
  (setf (agent-worker-threads agent)
        (remove-if-not #'bt:thread-alive-p (agent-worker-threads agent))))

(defun named-worker-running-p (agent name)
  (prune-workers agent)
  (find name (agent-worker-threads agent)
        :key #'bt:thread-name :test #'string=))

(defun register-worker (agent thunk name)
  "Start one named background role. Permanent heartbeat, evolver and dreamer
occupy independent slots instead of competing for a single list-length slot."
  (or (named-worker-running-p agent name)
      (let ((thread (bt:make-thread thunk :name name)))
        (push thread (agent-worker-threads agent))
        thread)))

(defun spawn-evolver (agent)
  "Spawn a low-priority worker to drain the evolution queue, if one is not
already running."
  (register-worker agent (lambda () (evolver-loop agent)) "ourro-evolver"))

(defun evolver-loop (agent)
  (handler-case
      ;; The evolver's model spend is background (M15-4).
      (let ((ourro.llm:*llm-call-context* :background))
       (loop
        (when (or (not (agent-running agent))
                  (zerop (ourro.evolve::queue-length)))
          (return))
        (let ((candidates
                (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
                  (ourro.evolve:process-evolution-queue
                   (agent-provider agent)
                   :max 1
                   :auto-apply (eq (agent-mode agent) :auto)
                   ;; Applied candidates announce (and arm the generation
                   ;; restart) via this callback AFTER their async snapshot
                   ;; builds the image and sets candidate-generation-id — the
                   ;; snapshot is off the evolver thread now (P0-3), so doing it
                   ;; inline here would run before generation-id existed and the
                   ;; restart would never arm.
                   :on-applied (lambda (done) (announce-candidate agent done))))))
          (dolist (candidate candidates)
            ;; The record hook already mirrored the candidate into the list.
            ;; Applied candidates (:hot-loaded/:snapshotted) announce via
            ;; on-applied once their snapshot finishes; only the un-applied ones
            ;; (:duplicate, :rejected, rate-limited :verified) need announcing
            ;; here, where there is no snapshot callback to carry them.
            (unless (member (ourro.evolve:candidate-status candidate)
                            ;; :staged already announced via on-applied (M14-2);
                            ;; :deferred already showed a calm ticker via the
                            ;; progress hook and will be retried on a later pass.
                            '(:hot-loaded :snapshotted :staged :deferred))
              (announce-candidate agent candidate)))
          (update-pending agent)
          ;; A throttle deferral re-queued its pattern; stop draining now so we
          ;; don't hot-spin against the rate limit. The next evolver spawn
          ;; (after a later turn or idle mining) retries it once load subsides
          ;; (F-evolver-429).
          (when (some (lambda (c)
                        (eq (ourro.evolve:candidate-status c) :deferred))
                      candidates)
            (return)))))
    (error (c)
      (ourro.observe:log-event :evolver-error :error (princ-to-string c))))
  (set-activity agent nil)
  (enqueue-ui agent '(:kind :dirty)))

(defun promote-candidate-generation (agent candidate)
  "Tell the supervisor live probation passed for this exact proof-gated build."
  (let ((connection (agent-supervisor agent))
        (id (ourro.evolve:candidate-generation-id candidate))
        (report (ourro.evolve:candidate-report candidate)))
    (and connection id report
         (let ((reply
                 (ignore-errors
                  (ourro.kernel:protocol-request
                   connection
                   (list :promote-generation
                         :id id
                         :transaction-id (pget report :transaction-id)
                         :proof-hash (pget report :proof-hash))
                   :timeout 30))))
           (eq (first reply) :ok)))))

(defun announce-candidate (agent candidate)
  (case (ourro.evolve:candidate-status candidate)
    ((:hot-loaded :snapshotted)
     (let* ((gene (ourro.evolve:candidate-gene candidate))
            (name (ourro.genome:gene-name gene))
            (pattern (ourro.evolve:candidate-pattern candidate)))
       (set-ticker agent
                   (format nil "learned: ~A → tool ~A · est. ~A"
                           (pattern-short pattern)
                           name
                           (ourro.miner:pattern-benefit-estimate pattern))
                   :style :ticker
                   :actions '((#\e "e explain" :explain) (#\u "u undo" :revert))
                   :seconds 20)
       (when (ourro.evolve:candidate-generation-id candidate)
         (if (promote-candidate-generation agent candidate)
             (let ((from (agent-generation agent))
                   (to (ourro.evolve:candidate-generation-id candidate)))
               (setf (agent-generation agent) to)
               (setf (ourro.tui:statusbar-generation
                      (ourro.tui:view-statusbar (agent-view agent)))
                     to)
               ;; Only a probation-promoted generation may arm a handoff.
               (setf (agent-pending-handoff agent) to
                     (agent-pending-arrival agent)
                     (list :from from :to to :gene name
                           :benefit
                           (ourro.miner:pattern-benefit-estimate pattern))))
             (set-ticker
              agent
              "probation passed, but supervisor promotion failed; generation remains non-bootable"
              :style :warning :seconds 12)))
       (enqueue-ui agent '(:kind :dirty))))
    (:staged
     ;; A mined reflex awaiting one-key consent (M14-2). Real action keys.
     (let* ((gene (ourro.evolve:candidate-gene candidate))
            (name (and gene (ourro.genome:gene-name gene)))
            (pattern (ourro.evolve:candidate-pattern candidate)))
       (set-ticker agent
                   (format nil "reflex proposed: ~A~@[ → ~A~] · install?"
                           (pattern-short pattern) name)
                   :style :accent
                   :actions '((#\y "y install" :install-staged)
                              (#\n "n dismiss" :dismiss-staged)
                              (#\e "e details" :explain))
                   :seconds 30)
       (enqueue-ui agent '(:kind :dirty))))
    (:duplicate
     (set-ticker agent
                 (format nil "skipped: ~A — ~A"
                         (pattern-short (ourro.evolve:candidate-pattern candidate))
                         (truncate-string
                          (or (ourro.evolve:candidate-diagnostics candidate)
                              "an existing tool already covers it")
                          110))
                 :style :dim :seconds 8)
     (enqueue-ui agent '(:kind :dirty)))
    (t nil)))


(defun newest-staged-record (agent)
  "The most recent :staged candidate record, or NIL (agent-candidates is
newest-first)."
  (find :staged (agent-candidates agent) :key (lambda (r) (pget r :status))))

(defun install-staged-candidate (agent record)
  "Re-verify RECORD's source and hot-load it (M14-2 consent granted). Shared by
the consent ticker's `y` and the inspector's `a`. Runs on a worker thread so the
gauntlet + build never block the UI."
  (let ((name (pget record :gene-name))
        (source (pget record :source)))
    (cond
      ((null source)
       (set-ticker agent "this record has no source to install" :style :warning :seconds 5))
      (t (bt:make-thread
          (lambda ()
            (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
              (handler-case
                  (multiple-value-bind (gene report)
                      (ourro.evolve::verify-mined-block source)
                    (let ((candidate (make-instance 'ourro.evolve:evolution-candidate
                                                    :pattern (pget record :pattern))))
                      (setf (ourro.evolve:candidate-source candidate) source
                            (ourro.evolve:candidate-gene candidate) gene
                            (ourro.evolve:candidate-report candidate) report
                            (ourro.evolve:candidate-status candidate) :verified)
                      (ourro.evolve:apply-candidate candidate :force t :snapshot :async
                                                   :on-snapshot
                                                   (lambda (c) (announce-candidate agent c)))
                      (refresh-system-prompt agent)))
                (error (c)
                  (set-ticker agent (format nil "install failed: ~A"
                                            (truncate-string (princ-to-string c) 80))
                              :style :warning :seconds 8)
                  (enqueue-ui agent '(:kind :dirty))))))
          :name "ourro-install-staged")
         (set-ticker agent (format nil "installing ~A…" (or name "reflex"))
                     :style :accent :seconds 6)))))

(defun install-newest-staged (agent)
  (let ((record (newest-staged-record agent)))
    (if record
        (install-staged-candidate agent record)
        (set-ticker agent "no staged reflex to install" :style :dim :seconds 4))))

(defun dismiss-newest-staged (agent)
  "Decline the newest staged reflex (M14-2): record :dismissed so its pattern
signature joins the attempted set and it is never re-proposed."
  (let ((record (newest-staged-record agent)))
    (if (null record)
        (set-ticker agent "no staged reflex to dismiss" :style :dim :seconds 4)
        (let ((dismissed (plist-put record :status :dismissed)))
          (bt:with-lock-held ((agent-candidates-lock agent))
            (setf (agent-candidates agent)
                  (substitute dismissed record (agent-candidates agent))))
          (ignore-errors
           (append-sexp-line (ourro.evolve:candidate-records-path) dismissed))
          (set-ticker agent "reflex dismissed — won't be proposed again"
                      :style :dim :seconds 6)))))


(defparameter *briefing-ring-size* 10)

(defun add-briefing (agent title text &optional automation workspace)
  "File a briefing (newest first, capped). Returns its stable number N."
  (let* ((n (incf (agent-briefing-count agent)))
         (entry (list :n n :title title :text text
                      :time (ourro.util:iso-time) :automation automation
                      :workspace workspace))
         (ring (cons entry (agent-briefings agent))))
    (setf (agent-briefings agent)
          (subseq ring 0 (min *briefing-ring-size* (length ring))))
    n))

(defun find-briefing (agent n)
  (find n (agent-briefings agent) :key (lambda (b) (pget b :n))))

(defun condense-briefing (text &optional (max-lines 20))
  "The first MAX-LINES of TEXT — the condensed form prefixed to the next user
message (the full text stays available via /out b<n>)."
  (let ((lines (split-lines text)))
    (if (<= (length lines) max-lines)
        text
        (format nil "~{~A~%~}… (/out for the rest)"
                (subseq lines 0 max-lines)))))

(defun run-investigation-and-brief (agent prompt &key events title)
  "Run a background investigation (M15-1) and file its diagnosis as a briefing
plus a non-interrupting note (headline + condensed text on the next message).
Called on the reflex worker via ourro.automation:*investigation-hook*."
  (let ((text (ignore-errors (run-investigation (agent-provider agent) prompt
                                                :events events))))
    (when (and text (plusp (length text)))
      (let ((n (add-briefing agent (or title "investigation") text title
                             (pget (first events) :workspace))))
        (ourro.automation:post-note
         (format nil "⚡ ~A — diagnosis ready · /out b~A~%~A"
                 (or title "investigation") n (condense-briefing text))
         :style :accent)))))


(defun wire-evolution-progress (agent)
  (setf ourro.evolve:*progress-hook*
        (lambda (stage &rest info)
          (evolution-progress agent stage info)))
  ;; Evolver politeness (M12-4): between stages, the background evolver waits
  ;; while a user turn is in flight (capped at 30 s so a wedged turn can't stall
  ;; evolution forever), so gene compiles never contend with the user.
  (setf ourro.evolve:*politeness-hook*
        (lambda ()
          (loop repeat 300 while (agent-busy agent) do (sleep 0.1)))))

(defun evolution-progress (agent stage info)
  (set-activity
   agent
   (case stage
     (:proposing
      (let ((round (first info)))
        (if (and round (plusp round))
            (format nil "⚡ evolving: asking for a repaired gene (round ~A)…"
                    round)
            "⚡ evolving: proposing a gene…")))
     (:verifying "⚡ evolving: running the verification gauntlet…")
     (:repairing (format nil "⚡ evolving: candidate failed the ~(~A~) gate — repairing…"
                         (first info)))
     (:verified (format nil "⚡ evolving: ~A verified" (first info)))
     (:hot-loaded (format nil "⚡ hot-loaded ~A (live on probation)" (first info)))
     (:snapshotting (format nil "⚡ building generation snapshot for ~A…"
                            (first info)))
     (t nil)))
  (case stage
    (:gave-up
     ;; The raw diagnostic is internal-stage vocabulary ("verification child
     ;; returned no single valid verdict", "OUT-OF-PROCESS stage") that is
     ;; noise even to a power user (F-evojargon). Keep the ticker calm and
     ;; actionable; the full diagnostic lives one keystroke away in ctrl-e.
     (set-ticker agent
                 "couldn't verify a new tool this time — skipped it (ctrl-e for details)"
                 :style :warning :seconds 8))
    (:snapshot-failed
     (set-ticker agent "generation snapshot failed to build (gene stays live in-image)"
                 :style :warning :seconds 8))
    (:deferred
     ;; A sustained provider throttle (429/5xx) — expected under load, not a
     ;; defect. The pattern is re-queued and retries on a later pass, so keep
     ;; the ticker calm and never say "error" (F-evolver-429).
     (set-ticker agent "provider busy — evolution paused, will retry later"
                 :style :warning :seconds 6))
    (:error
     (set-ticker agent
                 (format nil "evolver error: ~A"
                         (truncate-string (princ-to-string (or (first info) "?"))
                                          140))
                 :style :warning :seconds 10)))
  (enqueue-ui agent '(:kind :dirty)))


(defparameter *dream-idle-seconds* 120
  "Seconds of no user activity before dream mode may run.")

(defvar *last-activity* 0)


(defparameter *calm-idle-seconds* 300
  "Idle seconds before a :calm restart fires (5 min — a real lull).")

(defun restart-policy ()
  "The generation-restart policy, from config :restart-policy (read at runtime).
:calm (default) restarts only at a real lull (≥5 min idle or in the dream window)
or at /quit; :eager keeps the old 10 s behavior; :manual only ever restarts at
/quit."
  (let ((v (ourro.config:setting :restart-policy)))
    (cond ((member v '(:eager "eager") :test #'equalp) :eager)
          ((member v '(:manual "manual") :test #'equalp) :manual)
          (t :calm))))

(defun restart-allowed-p (policy idle-seconds busy-p input-empty-p dream-p)
  "Whether a pending generation handoff may fire now (M12-2). Pure. Never while
busy or mid-input. :eager → after 10 s idle; :calm → ≥5 min idle or inside the
dream window; :manual → never here (only /quit fires it)."
  (and (not busy-p) input-empty-p
       (ecase policy
         (:eager (> idle-seconds 10))
         (:calm (or (>= idle-seconds *calm-idle-seconds*) (and dream-p t)))
         (:manual nil))))

(defun note-activity ()
  (setf *last-activity* (get-universal-time)))

(defun maybe-dream (agent)
  (when (and (eq (agent-mode agent) :auto)
             (not (agent-visiting agent))
             (not (agent-busy agent))
             (not ourro.kernel:*evolution-frozen*)
             (> (- (get-universal-time) *last-activity*) *dream-idle-seconds*))
    (setf *last-activity* (get-universal-time))   ; don't re-trigger immediately
    (spawn-dreamer agent)))

(defun spawn-dreamer (agent)
  (register-worker agent (lambda () (dream agent)) "ourro-dreamer"))

(defun dream (agent)
  (handler-case
      (progn
       ;; Backfill corrections the interactive path missed before mining (M1-2).
       (ignore-errors (ourro.observe:backfill-corrections))
       (let* ((seen (ignore-errors (attempted-pattern-signatures)))
              (patterns (remove-if
                         (lambda (p)
                           (member (ourro.miner:pattern-signature p)
                                   seen :test #'string=))
                         (ourro.miner:mine-patterns)))
              (built 0)
              ;; The dreamer's model spend is background (M15-4).
              (ourro.llm:*llm-call-context* :background))
        (ourro.kernel:with-capabilities ourro.kernel:+all-capabilities+
          (dolist (pattern (subseq patterns 0 (min 2 (length patterns))))
            (let ((candidate (ourro.evolve:propose-gene
                              (agent-provider agent)
                              (plist-put pattern :origin :mined))))
              ;; propose-gene records the candidate via the record hook.
              (when (eq (ourro.evolve:candidate-status candidate) :verified)
                (incf built)
                ;; A dreamed reflex gets the same one-key consent ticker as a
                ;; live-mined one (M14-2) instead of lingering :verified.
                (when (ourro.evolve:should-stage-p candidate)
                  (ourro.evolve:stage-candidate candidate)
                  (announce-candidate agent candidate))))))
        (when (plusp built)
          (set-ticker agent
                      (format nil "dream mode: built ~A candidate~:P from your friction (staged, not applied). /evolutions to review"
                              built)
                      :style :accent :seconds 12)
          (enqueue-ui agent '(:kind :dirty)))))
    (error (c)
      (ourro.observe:log-event :dream-error :error (princ-to-string c))))
  (set-activity agent nil)
  (enqueue-ui agent '(:kind :dirty)))

(defun pattern-short (pattern)
  (case (pget pattern :kind)
    (:repeated-sequence (format nil "~{~A~^→~}" (pget pattern :tools)))
    (:repeated-command (format nil "~A ×~A" (first (pget pattern :tools))
                               (pget pattern :count)))
    (:reaction (format nil "after ~A → ~A"
                       (or (pget (pget pattern :trigger-shape) :tool)
                           (pget (pget pattern :trigger-shape) :kind) "trigger")
                       (pget pattern :reaction-tool)))
    (:slow-tool (format nil "slow ~A" (first (pget pattern :tools))))
    (:deliberate "your request")
    (t "pattern")))


(defparameter *slash-commands*
  '("help" "log" "evolutions" "out" "jobs" "genome" "tools" "freeze" "unfreeze"
    "disarm" "arm" "keep" "revert" "travel" "onboard" "mouse" "theme" "quit")
  "Completion vocabulary for the input's ghost suggestions.")

(defparameter *checkpoint-worthy-commands*
  '("keep" "revert" "freeze" "unfreeze" "disarm" "arm" "onboard" "travel")
  "Slash commands whose effects are worth re-checkpointing after (M4-1 review
#3): they change durable evolution state or grow the transcript with recovered
work. Pure-display commands mutate nothing a checkpoint captures and are
excluded, so /help, /log, /genome, /tools, /evolutions skip the disk write.")

(defun command-name (input)
  "The bare command word of a slash INPUT (\"/keep gene\" → \"keep\"), or NIL."
  (let ((parts (uiop:split-string (trim input) :separator '(#\Space))))
    (when (and parts (plusp (length (first parts))))
      (string-downcase (subseq (first parts) 1)))))

(defun checkpoint-worthy-command-p (input)
  (let ((command (command-name input)))
    (and command
         (member command *checkpoint-worthy-commands* :test #'string=)
         t)))

(defun dispatch-command (agent input)
  (let* ((parts (uiop:split-string (trim input) :separator '(#\Space)))
         (command (string-downcase (subseq (first parts) 1)))
         (args (rest parts)))
    (ourro.observe:log-event :command :name command)
    (cond
      ((member command '("help" "?") :test #'string=) (cmd-help agent))
      ((string= command "log") (cmd-log agent))
      ((member command '("evolutions" "evo") :test #'string=)
       (cmd-evolutions agent))
      ((string= command "out") (cmd-out agent args))
      ((string= command "jobs") (cmd-jobs agent))
      ((string= command "genome") (cmd-genome agent))
      ((string= command "tools") (cmd-tools agent))
      ((string= command "freeze") (cmd-freeze agent))
      ((string= command "unfreeze") (cmd-unfreeze agent))
      ((string= command "disarm") (cmd-disarm agent))
      ((string= command "arm") (cmd-arm agent))
      ((string= command "keep") (cmd-keep agent args))
      ((string= command "revert") (cmd-revert agent))
      ((string= command "travel") (cmd-travel agent args))
      ((string= command "onboard") (cmd-onboard agent))
      ((string= command "mouse") (cmd-mouse agent))
      ((string= command "theme") (cmd-theme agent args))
      ((member command '("quit" "exit" "q") :test #'string=)
       ;; A clean quit reaps background jobs (announced) — a deliberate exit,
       ;; unlike a generation restart, which leaves them running (M9-5).
       (announce-and-kill-jobs agent)
       ;; A calm (or :manual) user who always quits would never boot the
       ;; generations they grew — a pending handoff never fires. So on quit,
       ;; tell the supervisor to make the newest built generation current; the
       ;; next `ourro run` boots it (M12-2).
       (advance-generation-on-quit agent)
       (setf (agent-running agent) nil)
       (enqueue-ui agent '(:kind :quit)))
      (t (add-wrapped agent (format nil "unknown command: /~A (try /help)" command)
                      :warning)))
    (enqueue-ui agent '(:kind :dirty))))

(defun cmd-help (agent)
  (add-wrapped agent "commands: /log /evolutions /out [n] /genome /tools /freeze /unfreeze /disarm /arm /keep <gene> /revert /travel <gen> /onboard /mouse /theme <light|dark> /quit"
               :accent)
  (add-wrapped agent "two levers: /freeze stops new evolution · /disarm stops installed reflexes firing"
               :dim)
  (add-wrapped agent "editing: shift+enter or ctrl-j newline · ↑/↓ history · tab completes /commands"
               :dim)
  (add-wrapped agent "cockpit: ctrl-e evolutions · ctrl-o tool output · shift-↑↓/pgup/pgdn scroll · end ⇢ bottom · /mouse toggles wheel scroll (off = select/copy text normally)"
               :dim)
  (add-wrapped agent "while busy: esc/ctrl-c cancels · ctrl-c ctrl-c quits · ticker: e explain · u undo · y/n install/dismiss a proposed reflex"
               :dim))

(defun cmd-mouse (agent)
  "Toggle mouse-wheel scrolling. Mouse reporting is OFF by default so the
terminal's native text selection/copy works; turning it on trades selection
for wheel scrolling (shift-↑↓/pgup/pgdn always scroll either way)."
  (let ((on (ourro.tui:set-mouse-reporting (not ourro.tui:*mouse-reporting*))))
    (add-wrapped agent
                 (if on
                     "mouse wheel scrolling ON — terminal text selection is captured while on; /mouse to turn off"
                     "mouse wheel scrolling OFF — select/copy text normally; scroll with shift-↑↓ or pgup/pgdn")
                 :accent)))

(defun cmd-theme (agent args)
  "Switch the live TUI palette. Set :THEME in config.sexp for the next boot."
  (let ((requested (first args)))
    (cond
      ((null requested)
       (add-wrapped agent
                    (format nil "theme: ~A · usage: /theme light or /theme dark"
                            (string-downcase
                             (symbol-name (ourro.tui:current-theme))))
                    :accent))
      ((ourro.tui:set-theme requested)
       ;; Theme changes alter every rendered escape sequence. Empty the diff
       ;; cache so the next paint rewrites every row immediately.
       (let ((screen (agent-screen agent)))
         (when screen
           (ourro.tui:screen-resize screen
                                   (ourro.tui:screen-width screen)
                                   (ourro.tui:screen-height screen))))
       (add-wrapped agent
                    (format nil "theme switched to ~A. Set :theme :~A in config.sexp to keep it after restart."
                            (string-downcase requested)
                            (string-downcase requested))
                    :accent))
      (t
       (add-wrapped agent "unknown theme. usage: /theme light or /theme dark"
                    :warning)))))

(defun cmd-log (agent)
  (add-wrapped agent "recent events:" :accent)
  (dolist (event (reverse (ourro.observe:recent-events :limit 12)))
    (add-wrapped agent (format nil "~A ~A~@[ ~A~]"
                               (pget event :time)
                               (pget event :kind)
                               (or (pget event :tool) (pget event :name)))
                 :dim)))

(defun cmd-evolutions (agent)
  "Open the evolution inspector overlay (M2-4). Slash commands run on a worker
thread, so the UI mutation is marshalled to the UI thread via enqueue-ui (D-1)."
  (enqueue-ui agent '(:kind :open-inspector)))

(defun job-arg-p (arg)
  "True when ARG names a job — j followed by digits, e.g. j1 (M9-4)."
  (and (stringp arg) (> (length arg) 1)
       (char-equal (char arg 0) #\j)
       (every #'digit-char-p (subseq arg 1))))

(defun briefing-arg-p (arg)
  "True when ARG names a briefing — b followed by digits, e.g. b1 (M15-2)."
  (and (stringp arg) (> (length arg) 1)
       (char-equal (char arg 0) #\b)
       (every #'digit-char-p (subseq arg 1))))

(defun cmd-out (agent args)
  "Open the tool-output pager (M7-5), optionally on a specific result index
 (/out 7), a background job's log (/out j1, M9-4), or an intern's briefing
 (/out b1, M15-2). Marshalled to the UI thread like /evolutions."
  (let ((arg (first args)))
    (cond
      ((briefing-arg-p arg)
       (let ((b (find-briefing agent (parse-integer (subseq arg 1)))))
         (if (null b)
             (progn (add-wrapped agent (format nil "no such briefing: ~A" arg) :warning)
                    (enqueue-ui agent '(:kind :dirty)))
             ;; Reuse the single-item pager path (same as /out j1).
             (enqueue-ui agent
                         (list :kind :open-job-pager
                               :item (list :n 0
                                           :name (format nil "briefing ~A: ~A"
                                                         arg (pget b :title))
                                           :args (or (pget b :time) "")
                                           :result (pget b :text)
                                           :error-p nil))))))
      ((job-arg-p arg)
       (let ((job (ourro.jobs:job-record arg)))
         (if (null job)
             (progn (add-wrapped agent (format nil "no such job: ~A" arg) :warning)
                    (enqueue-ui agent '(:kind :dirty)))
             ;; Synthesize one pager item from the job log — the pager internals
             ;; are unchanged; it just pages a single supplied entry.
             (enqueue-ui agent
                         (list :kind :open-job-pager
                               :item (list :n 0
                                           :name (format nil "job ~A (~A)"
                                                         arg (pget job :command))
                                           :args (pget job :command)
                                           :result (let ((tail (ourro.jobs:job-log-tail arg)))
                                                     (if (and tail (plusp (length tail)))
                                                         tail "(log empty)"))
                                           :error-p nil))))))
      (t (let ((n (and arg (parse-integer arg :junk-allowed t))))
           (enqueue-ui agent (list :kind :open-pager :n n)))))))

(defun cmd-jobs (agent)
  "List background jobs in the transcript (M9-4)."
  (let ((jobs (ourro.jobs:list-jobs)))
    (if (null jobs)
        (add-wrapped agent "no background jobs." :dim)
        (progn
          (add-wrapped agent (format nil "background jobs (~A):" (length jobs)) :accent)
          (dolist (j jobs)
            (add-wrapped agent
                         (format nil "~A  ~A  ~A~@[ [exit ~A]~]  · /out ~A"
                                 (pget j :id)
                                 (string-downcase (symbol-name (pget j :status)))
                                 (pget j :command)
                                 (and (not (eq (pget j :status) :running)) (pget j :exit))
                                 (pget j :id))
                         :dim))))))

(defun advance-generation-on-quit (agent)
  "If a built generation is pending (calm restart never fired), tell the
supervisor to make it current so the next boot uses it (M12-2). Best-effort."
  (let ((pending (agent-pending-handoff agent))
        (connection (agent-supervisor agent)))
    (when (and pending connection
               ;; A /travel visit or re-root is user-directed, not a generation
               ;; advance — don't hijack it here.
               (null (agent-pending-travel agent)))
      (ignore-errors
       (ourro.kernel:protocol-send connection
                                  (list :make-current :id pending))))))

(defun announce-and-kill-jobs (agent)
  "Reap every running job before a clean quit, announcing it (M9-5)."
  (let ((killed (ignore-errors (ourro.jobs:kill-all-jobs))))
    (when killed
      (add-wrapped agent
                   (format nil "stopped ~A background job~:P (~{~A~^ ~})"
                           (length killed) killed)
                   :dim))))

(defun cmd-genome (agent)
  (add-wrapped agent (format nil "genome: gen ~A, ~A genes"
                             (agent-generation agent)
                             (length (ourro.genome:list-genes)))
               :accent)
  (dolist (gene (ourro.genome:list-genes))
    (let ((summary (gene-utility-summary (ourro.genome:gene-name gene))))
      (add-wrapped agent (format nil "  ~A~@[ · ~A~]"
                                 (ourro.genome:gene-summary gene) summary)
                   :dim))))

(defun cmd-tools (agent)
  (let ((tools (ourro.tools:list-tools)))
    (add-wrapped agent (format nil "live tools (~A):" (length tools)) :accent)
    (dolist (tool tools)
      (add-wrapped agent
                   (format nil "  ~A~@[ [~A]~] — ~A"
                           (ourro.tools:tool-name tool)
                           (ourro.tools:tool-gene tool)
                           (truncate-string
                            (first-line (ourro.tools:tool-description tool))
                            90))
                   :dim
                   ;; Match the 2-space lead above so a wrapped description
                   ;; stays aligned under the tool name, not at the margin.
                   :hang "  "))))

(defun first-line (string)
  (let ((newline (position #\Newline (or string ""))))
    (if newline (subseq string 0 newline) (or string ""))))

(defun set-evolution-frozen (agent frozen)
  "Apply FROZEN to every place the evolution-frozen state lives: the kernel
special var (which the evolver checks), the agent mode, and the statusbar
indicator. Shared by /freeze, /unfreeze, and session restore so a resumed
session (handoff or crash-resume) keeps the freeze the user set (F-frzresm)."
  (setf ourro.kernel:*evolution-frozen* (and frozen t)
        (agent-mode agent) (if frozen :frozen :auto)
        (ourro.tui:statusbar-mode (ourro.tui:view-statusbar (agent-view agent)))
        (if frozen :frozen :auto)))

(defun cmd-freeze (agent)
  (set-evolution-frozen agent t)
  (add-wrapped agent "evolution frozen. /unfreeze to resume." :warning))

(defun cmd-unfreeze (agent)
  (set-evolution-frozen agent nil)
  (add-wrapped agent "evolution resumed." :success))

(defun set-automations-armed (agent armed)
  "Toggle the reflex kill switch (M13-5). Distinct from /freeze: /disarm stops
installed automations firing; /freeze stops new evolution. Two levers. Shared by
/disarm, /arm, and session restore so a resumed session keeps the user's choice.
  AGENT is accepted for call-site symmetry with SET-EVOLUTION-FROZEN."
  (declare (ignore agent))
  (let ((armed (ourro.automation:set-reflex-armed armed)))
    ;; Legacy and durable reflexes share one visible kill switch. The journal
    ;; may be unopened in unit tests or early boot, so production performs an
    ;; authoritative sync again after START-EVENT-LOG.
    (ignore-errors
      (ourro.reflex.runtime:submit-command
       (list :type (if armed :arm :disarm)
             :workspace (or ourro.toolkit:*workspace* "workspace:system"))))
    armed))

(defun cmd-disarm (agent)
  (set-automations-armed agent nil)
  (add-wrapped agent "reflexes disarmed — installed automations will not fire. /arm to re-enable."
               :warning))

(defun cmd-arm (agent)
  (set-automations-armed agent t)
  (if ourro.kernel:*automations-armed*
      (add-wrapped agent "reflexes armed (experimental) — installed automations fire again."
                   :success)
      (add-wrapped agent
                   "reflexes remain disarmed — Gate 0 is incomplete; set :experimental-reflexes t in config.sexp to opt in."
                   :warning)))

(defun cmd-revert (agent)
  (let ((record (find-if (lambda (r)
                           (member (pget r :status) '(:hot-loaded :snapshotted)))
                         (agent-candidates agent))))
    (if (or (null record) (null (pget record :gene-name)))
        (add-wrapped agent "nothing to revert." :dim)
        (let* ((name (pget record :gene-name))
               (count (ourro.kernel:revert-gene-definitions name))
               (reverted (plist-put record :status :reverted)))
          (bt:with-lock-held ((agent-candidates-lock agent))
            (setf (agent-candidates agent)
                  (substitute reverted record (agent-candidates agent))))
          (ignore-errors
           (append-sexp-line (ourro.evolve:candidate-records-path) reverted))
          (refresh-system-prompt agent)
          (add-wrapped agent (format nil "reverted ~A (~A definition~:P undone)."
                                     name count)
                       :success)))))

(defun cmd-travel (agent args)
  (if (null args)
      (add-wrapped agent "usage: /travel <generation-number> (visit read-only) or /travel hard <n>" :dim)
      (let* ((hard (string-equal (first args) "hard"))
             (target-number (parse-integer (car (last args)) :junk-allowed t)))
        (if (null target-number)
            (add-wrapped agent "not a generation number." :warning)
            (request-travel agent target-number :hard hard)))))

(defun cmd-onboard (agent)
  "Probe the repository, run each build/test/lint candidate once, then grow a
verified `repo/<role>` gene per green command (PR-10, M1-5). Runs on the
submission worker thread, so the LLM proposals do not block the UI."
  (add-wrapped agent "onboarding: probing repo build/test/lint…" :accent)
  (enqueue-ui agent '(:kind :dirty))
  (let ((candidates (ignore-errors (probe-repository))))
    (cond
      ((null candidates)
       (add-wrapped agent "no build/test/lint markers found (looked for Makefile, package.json, Cargo.toml, pyproject.toml, go.mod, Gemfile, mix.exs)."
                    :warning))
      (t
       (let ((probes (run-probes candidates
                                 :progress (lambda (msg)
                                             (set-activity agent msg)
                                             (enqueue-ui agent '(:kind :dirty))))))
         (set-activity agent nil)
         (add-wrapped agent "probe results:" :accent)
         (dolist (probe probes)
           (add-wrapped agent
                        (format nil "  ~A ~A  (~A · exit ~A · ~Ams)"
                                (if (green-probe-p probe) "✓" "✗")
                                (pget probe :label) (pget probe :source)
                                (pget probe :exit) (pget probe :ms))
                        (if (green-probe-p probe) :success :dim)))
         (enqueue-ui agent '(:kind :dirty))
         (onboard-grow agent probes))))))

(defun onboard-grow (agent probes)
  (let ((patterns (onboard-patterns probes)))
    (cond
      ((null patterns)
       (add-wrapped agent "no command succeeded — nothing to grow. Fix the toolchain and retry /onboard."
                    :warning))
      (ourro.kernel:*evolution-frozen*
       ;; Growing a gene hot-loads it, which apply-candidate refuses while
       ;; frozen (engine.lisp) — so every proposal would be verified then
       ;; rejected. Don't spend LLM calls on doomed proposals, and say WHY
       ;; instead of emitting one cryptic "could not grow" line per pattern.
       (add-wrapped agent
                    (format nil "evolution is frozen — probed your toolchain but skipped growing ~A gene~:P (~{~A~^ ~}). /unfreeze, then /onboard again to grow them."
                            (length patterns)
                            (mapcar (lambda (p) (pget p :gene-name)) patterns))
                    :warning)
       ;; The coder role still benefits from the detected toolchain summary.
       (setf (agent-conversation agent)
             (append (agent-conversation agent)
                     (list (ourro.llm:user-message
                            (onboard-toolchain-summary probes)))))
       (enqueue-ui agent '(:kind :dirty)))
      (t
       (set-ticker agent (format nil "onboarding: growing ~A gene~:P from your toolchain…"
                                 (length patterns))
                   :style :accent :seconds 30)
       (enqueue-ui agent '(:kind :dirty))
       (let ((grown (ignore-errors (grow-onboarding-genes agent patterns))))
         (refresh-system-prompt agent)
         (dolist (pattern patterns)
           (let ((exists (ourro.genome:find-gene (pget pattern :gene-name))))
             (add-wrapped agent
                          (format nil "  ~A ~A"
                                  (if exists "grew" "could not grow")
                                  (pget pattern :gene-name))
                          (if exists :success :warning))))
         ;; Let the coder role in on the toolchain too.
         (setf (agent-conversation agent)
               (append (agent-conversation agent)
                       (list (ourro.llm:user-message
                              (onboard-toolchain-summary probes)))))
         (when grown
           (set-ticker agent
                       (format nil "onboarded: ~{~A~^ ~} grown · try them"
                               (mapcar (lambda (p) (pget p :gene-name)) grown))
                       :style :success :seconds 12))
         (enqueue-ui agent '(:kind :dirty)))))))


(defun request-travel (agent target-number &key hard)
  (let ((id (format nil "gen-~4,'0D" target-number)))
    (if (null (agent-supervisor agent))
        (add-wrapped agent "time travel needs the supervisor (run via `ourro run`)." :warning)
        (progn
          (add-wrapped agent (format nil "~:[visiting~;re-rooting to~] ~A…" hard id) :accent)
          ;; Travel is user intent, so we arm a pending handoff (exactly like a
          ;; generation restart) and stop the loop NOW — deliberately bypassing
          ;; the quiet-boundary gate. PERFORM-HANDOFF then sends the :handoff
          ;; with the travel flags and yields exit 75, so the supervisor exec's
          ;; the target generation with --resume. The previous code sent the
          ;; :handoff here and let RUN-AGENT return an exit 0, which the
          ;; supervisor read as a clean quit and shut the session down — every
          ;; /travel killed the product (F-travel, P1).
          (setf (agent-pending-handoff agent) id
                (agent-pending-travel agent) (list :hard hard :visiting (not hard))
                ourro.tui:*keep-screen-on-exit* t
                (agent-running agent) nil)
          (enqueue-ui agent '(:kind :handoff))))))


(defun session-payload (agent &key arrival checkpoint)
  "Build the handoff/checkpoint payload plist from AGENT's live session. The
one place the session is turned into data; SERIALIZE-SESSION writes it to a
fresh handoff file, CHECKPOINT-SESSION writes it to the fixed checkpoint."
  (let ((input (ourro.tui:view-input (agent-view agent))))
    (ourro.kernel:handoff-plist
     :session-id (agent-session-id agent)
     :generation (agent-generation agent)
     :conversation (agent-conversation agent)
     :scrollback (mapcar #'serialize-line
                         (ourro.tui:transcript-lines
                          (ourro.tui:view-transcript (agent-view agent))))
     :input-text (ourro.tui:input-text input)
     :cwd ourro.toolkit:*workspace*
     :pending (bt:with-lock-held ((agent-submissions-lock agent))
                (copy-list (agent-pending-submissions agent)))
     :checkpoint checkpoint
     :pid (and checkpoint (sb-posix:getpid))
     :frozen ourro.kernel:*evolution-frozen*
     :ticker (let ((ticker (ourro.tui:view-ticker (agent-view agent))))
               (and (ourro.tui:ticker-text ticker)
                    (list :text (ourro.tui:ticker-text ticker))))
     :extra (list :history
                  (let ((history (ourro.tui:input-history input)))
                    (subseq history 0 (min 50 (length history))))
                  :arrival arrival
                  ;; Background jobs survive a restart (M9-5): id/command/pid/log
                  ;; ride the payload so the next generation re-attaches them.
                  ;; Additive key — older readers pget → NIL and ignore it.
                  :jobs (ignore-errors (ourro.jobs:jobs-for-handoff))
                  ;; Restart-loss reduction (M12-5): the tool-output ring (each
                  ;; result truncated for payload sanity, so /out history
                  ;; survives), the current [N] label counter, pending gene
                  ;; retirements, and the evolution rate-limit clock (which would
                  ;; otherwise reset to 0 every restart).
                  :ring (mapcar (lambda (e)
                                  (list :n (pget e :n) :name (pget e :name)
                                        :args (pget e :args)
                                        :result (truncate-string
                                                 (or (pget e :result) "") 4096)
                                        :error-p (pget e :error-p) :ms (pget e :ms)))
                                (agent-tool-results agent))
                  :ring-count (agent-tool-result-count agent)
                  :pending-retirements (agent-pending-retirements agent)
                  :last-evolution-time ourro.evolve:*last-evolution-time*
                  ;; Reflexes (M13-5): the disarm kill switch is durable state,
                  ;; carried like :frozen so /disarm survives a restart. Additive
                  ;; key — an older reader pget → NIL, and restore defaults to
                  ;; armed when the key is absent.
                  :armed ourro.kernel:*automations-armed*))))

(defun serialize-session (agent &key arrival)
  (ourro.kernel:write-handoff (session-payload agent :arrival arrival)))


(defun checkpoint-path () (ourro-path "state/checkpoint.sexp"))

(defun checkpoint-session (agent)
  "Persist the live session to the fixed crash-recovery checkpoint. Atomic
(WRITE-SEXP-FILE stages then renames), so a crash mid-write leaves at worst
the previous good checkpoint. Never during a visiting session — a read-only
time-travel view must not clobber the real session's recovery point."
  (unless (agent-visiting agent)
    (ignore-errors
     (write-sexp-file (checkpoint-path) (session-payload agent :checkpoint t)))))

(defun delete-checkpoint ()
  "Drop the crash checkpoint — after a clean quit, a deliberate handoff, or a
successful restore (its job is done and it must not resurrect a stale session)."
  (ignore-errors
   (let ((path (checkpoint-path)))
     (when (probe-file path) (delete-file path)))))

(defun note-recovery-proven (agent)
  "Once a crash-recovered session survives a full turn, tell the supervisor its
checkpoint latch can be cleared: the resumed state proved healthy and has been
superseded by a fresh checkpoint, so a later unrelated crash should resume the
fresh one — not poison it (M4-1 review #1). Idempotent and a no-op unless this
boot was itself a recovery."
  (when (agent-recovered-from-checkpoint agent)
    (setf (agent-recovered-from-checkpoint agent) nil)
    (let ((connection (agent-supervisor agent)))
      (when connection
        (ignore-errors
         (ourro.kernel:protocol-send connection (list :checkpoint-superseded)))))))

(defun serialize-line (line)
  "Turn a styled line (list of (style . string)) into readable data."
  (mapcar (lambda (span)
            (if (consp span)
                (list (car span) (cdr span))
                (list :default span)))
          (if (listp line) line (list line))))

(defun deserialize-line (data)
  (mapcar (lambda (span) (cons (first span) (second span))) data))

(defun restore-session (agent payload)
  "Rehydrate AGENT from a handoff PAYLOAD."
  (when payload
    (setf (agent-conversation agent) (pget payload :conversation)
          (agent-session-id agent) (or (pget payload :session-id)
                                       (agent-session-id agent)))
    ;; Restore the working directory the session was rooted at (M4-2). Written
    ;; since M2 but never read back; without it a resumed session silently
    ;; snaps to the process's cwd and every relative path tool misfires.
    (let ((cwd (pget payload :cwd)))
      (when (and cwd (uiop:directory-exists-p cwd))
        (setf ourro.toolkit:*workspace* (uiop:ensure-directory-pathname cwd))))
    (let ((transcript (ourro.tui:view-transcript (agent-view agent))))
      (setf (ourro.tui:transcript-lines transcript)
            (mapcar #'deserialize-line (pget payload :scrollback))))
    (let ((input (ourro.tui:view-input (agent-view agent))))
      (ourro.tui:input-set-text input (or (pget payload :input-text) ""))
      (setf (ourro.tui:input-history input)
            (pget (pget payload :extra) :history)))
    ;; Typeahead queued at handoff time survives the restart (M4-2); the first
    ;; item drains once the runloop is up.
    (setf (agent-pending-submissions agent) (pget payload :pending))
    ;; Re-attach background jobs (M9-5): a job whose pid is still alive resumes
    ;; :running under a liveness poller; a dead one becomes :exited. Fall back to
    ;; the state/jobs.sexp mirror when the payload predates jobs (:jobs absent).
    (let ((jobs (pget (pget payload :extra) :jobs)))
      (if jobs
          (ignore-errors (ourro.jobs:restore-jobs jobs))
          (ignore-errors (ourro.jobs:restore-jobs-from-disk))))
    ;; Restart-loss reduction (M12-5): restore the /out ring, its label counter,
    ;; pending retirements, and the evolution rate-limit clock.
    (let ((extra (pget payload :extra)))
      (let ((ring (pget extra :ring)))
        (when ring
          (setf (agent-tool-results agent) ring
                (agent-tool-result-count agent)
                (or (pget extra :ring-count) (agent-tool-result-count agent)))))
      (when (pget extra :pending-retirements)
        (setf (agent-pending-retirements agent) (pget extra :pending-retirements)))
      (let ((clock (pget extra :last-evolution-time)))
        (when (and clock (numberp clock))
          (setf ourro.evolve:*last-evolution-time* clock))))
    ;; A user's /freeze is durable evolution state (F-frzresm): restore it so a
    ;; handoff or crash-resume doesn't silently thaw self-modification the user
    ;; disabled. A fresh image defaults to :auto, so only frozen needs applying,
    ;; but set-evolution-frozen handles both directions idempotently. Skip a
    ;; visiting session: it is read-only (:manual mode, can't evolve regardless)
    ;; and its statusbar shows the visited generation, not a freeze mode — the
    ;; same reason checkpoint-session skips it.
    (unless (agent-visiting agent)
      (set-evolution-frozen agent (pget payload :frozen)))
    ;; Restore the reflex kill switch (M13-5). Absent (a pre-reflexes payload) →
    ;; default disarmed while Gate 0 is incomplete. Even an older payload that
    ;; says armed is clamped by the config :experimental-reflexes setting.
    (let ((extra (pget payload :extra)))
      (set-automations-armed agent (if (member :armed extra)
                                       (pget extra :armed)
                                       nil)))
    ;; The arrival moment (M2-5): if this restart was triggered by an
    ;; evolution, make it visible — a divider + a success ticker — instead of
    ;; silently re-showing the stale pre-restart ticker. A crash-recovery
    ;; resume (M4-1) gets its own amber "recovered" ticker instead.
    (let ((arrival (pget (pget payload :extra) :arrival))
          (ticker-data (pget payload :ticker)))
      (cond
        ((pget payload :checkpoint)
         ;; Mark the boot as on-probation until a turn proves it healthy: the
         ;; supervisor poisons this checkpoint if we crash again before then,
         ;; but must resume the fresh one we write later (M4-1 review #1).
         (setf (agent-recovered-from-checkpoint agent) t)
         (set-ticker agent
                     (format nil "recovered your session after a crash (~A) — ~
the last turn may be incomplete"
                             (agent-generation agent))
                     :style :warning :seconds 12))
        (arrival (announce-arrival agent arrival))
        (ticker-data (set-ticker agent (pget ticker-data :text) :seconds 6)))))
  agent)

(defun announce-arrival (agent arrival)
  "Make a seamless generation restart legible: a dim transcript divider naming
the transition and a success ticker whose `e` opens the inspector."
  (let ((from (pget arrival :from))
        (to (pget arrival :to))
        (gene (pget arrival :gene))
        (benefit (pget arrival :benefit)))
    (add-transcript-line
     agent
     (list (ourro.tui:styled :dim
                            (format nil "── evolved: ~A → ~A~@[ (~A)~] ──"
                                    from to gene))))
    (set-ticker agent
                (format nil "⚡ now running ~A~@[ — grew ~A~]~@[ · ~A~] · e explain"
                        to gene benefit)
                :style :success :actions '((#\e "e explain" :explain)) :seconds 10)))



(defun handle-key (agent key)
  (note-activity)
  (let* ((view (agent-view agent))
         (input (ourro.tui:view-input view)))
    (cond
      ;; 1. Overlay (modal) consumes everything — including paste, which must
      ;; not leak into the input line hidden behind the modal (M2-4 review #4).
      ((ourro.tui:view-overlay view)
       (dispatch-overlay-key agent key))
      ;; Bracketed paste otherwise goes straight to the editor.
      ((and (consp key) (eq (car key) :paste))
       (handle-editor-key agent input key))
      ;; 2. Keymap chords.
      ((and (keywordp key) (ourro.tui:keymap-command key))
       (ourro.tui:invoke-command (ourro.tui:keymap-command key)))
      ;; 3. Ticker affordance.
      ((ticker-key agent input key))
      ;; 4. The editor.
      (t (handle-editor-key agent input key)))
    (update-suggestion input)
    (enqueue-ui agent '(:kind :dirty))))

(defun ticker-command-for-key (actions key)
  "The command keyword bound to KEY in ACTIONS (a list of (key label command)
triples), or NIL. Plain-string actions are display-only (M14-1)."
  (dolist (action actions)
    ;; char= (not char-equal): the old case used eql, so capital E/U/Y/N stay
    ;; ordinary characters that begin a typed message (review F2).
    (when (and (consp action) (characterp (first action))
               (char= (first action) key))
      (return-from ticker-command-for-key (third action))))
  nil)

(defun run-ticker-command (agent command)
  "Execute a ticker action COMMAND (M14-1)."
  (case command
    (:explain (open-inspector agent :expanded t))
    (:revert (cmd-revert agent))
    (:install-staged (install-newest-staged agent))
    (:dismiss-staged (dismiss-newest-staged agent))
    (t nil)))

(defun ticker-key (agent input key)
  "With a visible ticker carrying (key label command) actions and an empty input
line, KEY runs the matching action's command — the evolution tickers bind e→explain
and u→undo (byte-identical to before), a consent ticker binds y/n. Returns T if
consumed."
  (let ((ticker (ourro.tui:view-ticker (agent-view agent))))
    (when (and (ourro.tui:ticker-text ticker)
               (ourro.tui:ticker-actions ticker)
               (zerop (length (ourro.tui:input-text input))))
      (let ((command (ticker-command-for-key (ourro.tui:ticker-actions ticker) key)))
        (when command
          (run-ticker-command agent command)
          t)))))


(defun toggle-inspector (agent)
  (if (ourro.tui:view-overlay (agent-view agent))
      (close-inspector agent)
      (open-inspector agent)))

(defun open-inspector (agent &key expanded)
  "Open the evolution inspector. With EXPANDED, the newest record's detail
block starts open — the ticker's `e explain` lands on the explanation itself
rather than a collapsed list."
  (let ((inspector (make-evolution-inspector agent)))
    (when (and expanded (inspector-items inspector))
      (setf (inspector-expanded inspector) t))
    (setf (ourro.tui:view-overlay (agent-view agent)) inspector))
  (enqueue-ui agent '(:kind :dirty)))

(defun close-inspector (agent)
  (setf (ourro.tui:view-overlay (agent-view agent)) nil)
  (enqueue-ui agent '(:kind :dirty)))

(defun dispatch-overlay-key (agent key)
  (let ((overlay (ourro.tui:view-overlay (agent-view agent))))
    (when overlay
      (case (ourro.tui:overlay-key overlay key)
        (:close (close-inspector agent))
        (t nil)))))

(defun install-builtin-keys ()
  "Register the built-in keymap chords (ctrl-e opens the inspector). These
bypass BIND-KEY's reserved-key guard because they ARE the built-ins.
F-row keys are deliberately unbound (and unbindable) — terminals, OSes, and
window managers already fight over them."
  (setf (gethash :toggle-inspector ourro.tui:*commands*)
        (lambda () (when *agent* (toggle-inspector *agent*))))
  ;; ctrl-o opens the tool-output pager (M7-5).
  (setf (gethash :toggle-pager ourro.tui:*commands*)
        (lambda () (when *agent* (toggle-pager *agent*))))
  (setf ourro.tui:*keymap*
        (list* (cons :ctrl-e :toggle-inspector)
               (cons :ctrl-o :toggle-pager)
               (remove-if (lambda (k) (member k '(:f2 :ctrl-e :ctrl-o)))
                          ourro.tui:*keymap* :key #'car))))

(defun handle-editor-key (agent input key)
  (cond
    ;; Bracketed paste: one event, inserted literally, never auto-submits.
    ((and (consp key) (eq (car key) :paste))
     (ourro.tui:input-insert input (cdr key))
     (reset-history-cursor input))
    (t
     (case key
       (:enter (handle-enter agent input))
         (:shift-enter (ourro.tui:input-insert input (string #\Newline)))
         (:backspace (ourro.tui:input-backspace input))
         ((:alt-backspace :ctrl-w) (ourro.tui:input-delete-word-back input))
         (:delete (ourro.tui:input-delete-forward input))
         (:left (ourro.tui:input-move input -1))
         (:right (if (and (ourro.tui:input-suggestion input)
                          (= (ourro.tui:input-cursor input)
                             (length (ourro.tui:input-text input))))
                     (accept-suggestion input)
                     (ourro.tui:input-move input 1)))
         (:word-left (ourro.tui:input-word-move input :left))
         (:word-right (ourro.tui:input-word-move input :right))
         (:home (ourro.tui:input-line-home input))
         (:end
          ;; With an empty input line and a scrolled-up transcript, End jumps to
          ;; the bottom (M7-4); otherwise it moves to line end as before.
          (if (and (zerop (length (ourro.tui:input-text input)))
                   (plusp (ourro.tui:transcript-scroll
                           (ourro.tui:view-transcript (agent-view agent)))))
              (scroll-to-bottom agent)
              (ourro.tui:input-line-end input)))
         (:ctrl-k (ourro.tui:input-kill-to-line-end input))
         (:ctrl-u (ourro.tui:input-clear input))
         (:tab (accept-suggestion input))
         (:escape
          ;; Esc during a busy turn with an empty input line cancels the turn
          ;; (M7-1); otherwise it clears the input as before.
          (if (and (agent-busy agent)
                   (zerop (length (ourro.tui:input-text input))))
              (request-cancel agent)
              (progn (ourro.tui:input-clear input)
                     (reset-history-cursor input))))
         (:ctrl-c
          ;; First ctrl-c during a turn cancels it; a second within the window,
          ;; or ctrl-c while idle, quits (M7-1).
          (let ((now (get-universal-time)))
            (case (interrupt-action (agent-busy agent)
                                    (agent-last-interrupt agent) now)
              (:quit (setf (agent-running agent) nil))
              (:cancel (request-cancel agent)))
            (setf (agent-last-interrupt agent) now)))
         (:ctrl-d
          (setf (agent-running agent) nil))
         (:ctrl-l (when (agent-screen agent)
                    (ourro.tui:screen-resize (agent-screen agent)
                                            (ourro.tui:screen-width (agent-screen agent))
                                            (ourro.tui:screen-height (agent-screen agent)))))
         ((:up :ctrl-p)
          (unless (ourro.tui:input-move-line input :up)
            (history-previous input)))
         ((:down :ctrl-n)
          (unless (ourro.tui:input-move-line input :down)
            (history-next input)))
         (:shift-up (scroll agent 1))
         (:shift-down (scroll agent -1))
         (:page-up (scroll agent 10))
         (:page-down (scroll agent -10))
         ;; Mouse wheel scrolls the transcript ±3 lines; a click/drag (:mouse)
         ;; is a deliberate no-op so a stray click never clears the input (M7-4).
         (:wheel-up (scroll agent 3))
         (:wheel-down (scroll agent -3))
         (:mouse nil)
         (t
          (when (characterp key)
            (ourro.tui:input-insert input (string key))
            (reset-history-cursor input)))))))

(defun handle-enter (agent input)
  (let ((text (ourro.tui:input-text input)))
    (cond
      ;; Trailing backslash: line continuation (works in every terminal,
      ;; even ones that can't report shift+enter).
      ((and (plusp (length text))
            (char= (char text (1- (length text))) #\\)
            (= (ourro.tui:input-cursor input) (length text)))
       (ourro.tui:input-set-text input
                                (concatenate 'string
                                             (subseq text 0 (1- (length text)))
                                             (string #\Newline))))
      (t
       ;; Complete a half-typed slash command before submitting.
       (when (and (ourro.tui:input-suggestion input)
                  (plusp (length text))
                  (char= (char text 0) #\/))
         (accept-suggestion input)
         (setf text (ourro.tui:input-text input)))
       (ourro.tui:input-clear input)
       (reset-history-cursor input)
       (unless (zerop (length (trim text)))
         ;; A fresh submission jumps back to the live bottom (M7-4).
         (scroll-to-bottom agent)
         (push-history input text)
         (run-submission agent text))))))

(defun push-history (input text)
  (unless (equal text (first (ourro.tui:input-history input)))
    (push text (ourro.tui:input-history input))))

(defun reset-history-cursor (input)
  (setf (ourro.tui:input-history-index input) nil))

(defun history-previous (input)
  (let ((history (ourro.tui:input-history input))
        (index (ourro.tui:input-history-index input)))
    (when history
      (cond
        ((null index)
         (setf (ourro.tui:input-history-stash input) (ourro.tui:input-text input)
               (ourro.tui:input-history-index input) 0)
         (ourro.tui:input-set-text input (first history)))
        ((< index (1- (length history)))
         (let ((next (1+ index)))
           (setf (ourro.tui:input-history-index input) next)
           (ourro.tui:input-set-text input (nth next history))))))))

(defun history-next (input)
  (let ((history (ourro.tui:input-history input))
        (index (ourro.tui:input-history-index input)))
    (when index
      (if (zerop index)
          (progn
            (setf (ourro.tui:input-history-index input) nil)
            (ourro.tui:input-set-text input (ourro.tui:input-history-stash input)))
          (let ((previous (1- index)))
            (setf (ourro.tui:input-history-index input) previous)
            (ourro.tui:input-set-text input (nth previous history)))))))

(defun accept-suggestion (input)
  (let ((suggestion (ourro.tui:input-suggestion input)))
    (when suggestion
      (ourro.tui:input-insert input suggestion)
      (setf (ourro.tui:input-suggestion input) nil))))

(defun update-suggestion (input)
  (let ((text (ourro.tui:input-text input)))
    (setf (ourro.tui:input-suggestion input)
          (when (and (plusp (length text))
                     (char= (char text 0) #\/)
                     (= (ourro.tui:input-cursor input) (length text))
                     (not (find #\Space text))
                     (not (find #\Newline text)))
            (let* ((prefix (string-downcase (subseq text 1)))
                   (match (find-if (lambda (command)
                                     (string-prefix-p prefix command))
                                   *slash-commands*)))
              (when (and match (> (length match) (length prefix)))
                (subseq match (length prefix))))))))

(defun scroll (agent delta)
  (let ((transcript (ourro.tui:view-transcript (agent-view agent))))
    (setf (ourro.tui:transcript-scroll transcript)
          (max 0 (+ (ourro.tui:transcript-scroll transcript) delta)))))

(defun scroll-to-bottom (agent)
  "Pin the transcript to the newest line (M7-4)."
  (setf (ourro.tui:transcript-scroll (ourro.tui:view-transcript (agent-view agent))) 0))

(defun slash-command-p (text)
  (let ((trimmed (trim text)))
    (and (plusp (length trimmed)) (char= (char trimmed 0) #\/))))

(defun enqueue-submission (agent text)
  "Queue a submission the user entered while a turn is in flight (typeahead,
M4-2) and show a dim marker. It drains at the next turn boundary — one per
boundary — instead of spawning a concurrent, interleaved turn."
  (bt:with-lock-held ((agent-submissions-lock agent))
    (setf (agent-pending-submissions agent)
          (append (agent-pending-submissions agent) (list text))))
  (add-wrapped agent
               (format nil "(queued) ~A" (truncate-string (first-line text) 76))
               :dim))

(defun dequeue-submission (agent)
  (bt:with-lock-held ((agent-submissions-lock agent))
    (when (agent-pending-submissions agent)
      (pop (agent-pending-submissions agent)))))

(defun maybe-drain-submission (agent)
  "Start the oldest queued submission if idle (M4-2). Runs on the UI thread at
a turn boundary, where BUSY is already clear."
  (when (and (not (agent-busy agent))
             (agent-pending-submissions agent))
    (let ((text (dequeue-submission agent)))
      (when text (run-submission agent text)))))

(defun run-submission (agent text)
  "Run a submission on a worker thread — slash commands included (/onboard
drives a full model turn; running it inline froze the UI). If a turn is
already in flight, queue it (typeahead, M4-2) rather than spawn a concurrent
turn that would interleave tool calls and mangle the transcript."
  (cond
    ((agent-busy agent)
     (enqueue-submission agent text))
    ((slash-command-p text)
     ;; Claim BUSY synchronously on the UI thread — a slow slash command
     ;; (/onboard shells out and drives LLM gene proposals for tens of
     ;; seconds) must make a following Enter QUEUE, not spawn a concurrent
     ;; turn that interleaves genome mutation with a model turn (M4-2 review
     ;; #2). Slash commands don't run PROCESS-TURN, so clear BUSY here in the
     ;; worker's unwind-protect and fire a drain so the queue still advances.
     (setf (agent-busy agent) t)
     (clear-cancel agent)
     (bt:make-thread
      (lambda ()
        (setf (agent-turn-thread agent) (bt:current-thread))
        (unwind-protect
             (handler-case (submit-message agent text)
               ;; Belt-and-braces (M7-1): an escalated interrupt that lands
               ;; outside PROCESS-TURN's own handler kills only this turn.
               (ourro.kernel:turn-cancelled () (finalize-cancelled-turn agent))
               (error (c)
                 (add-wrapped agent (format nil "error: ~A" c) :danger)
                 (enqueue-ui agent '(:kind :dirty))))
          (setf (agent-busy agent) nil)
          (clear-cancel agent)
          (enqueue-ui agent '(:kind :drain-submissions))))
      :name "ourro-turn"))
    (t
     ;; Claim the turn synchronously on the UI thread: a second Enter in the
     ;; gap before the worker's PROCESS-TURN sets BUSY must not spawn a
     ;; concurrent turn (M4-2).
     (setf (agent-busy agent) t)
     (clear-cancel agent)
     (bt:make-thread
      (lambda ()
        (let ((completion-enqueued nil))
         (setf (agent-turn-thread agent) (bt:current-thread))
         (unwind-protect
             (handler-case
                 (multiple-value-bind (value completed)
                     (submit-message agent text)
                   (declare (ignore value))
                   (setf completion-enqueued completed))
               ;; Belt-and-braces (M7-1): an escalated interrupt landing outside
               ;; PROCESS-TURN's handler kills only this turn, not the worker.
               (ourro.kernel:turn-cancelled () (finalize-cancelled-turn agent))
               (error (c)
                 (add-wrapped agent (format nil "error: ~A" c) :danger)
                 (enqueue-ui agent '(:kind :dirty))))
          ;; PROCESS-TURN normally clears BUSY + fires :turn-done. If the turn
          ;; died before reaching that cleanup, don't let BUSY stick and make
          ;; sure the queue still drains.
          (unless completion-enqueued
            (clear-cancel agent)
            (enqueue-ui agent '(:kind :turn-done))))))
      :name "ourro-turn"))))



(defun mission-marker-path ()
  (ourro-path "state/mission-submitted"))

(defun mission-text-to-submit ()
  "Return the OURRO_MISSION file's contents when this boot should auto-submit
them, else NIL: the env var must name a readable, non-empty file and the
once-per-home marker must not exist. Unreadable/empty files return NIL rather
than signal — a broken mission must not take the agent down."
  (let ((mission (getenv "OURRO_MISSION")))
    (when (and mission (plusp (length (trim mission)))
               (not (probe-file (mission-marker-path))))
      (let ((text (ignore-errors (uiop:read-file-string (trim mission)))))
        (when (and text (plusp (length (trim text))))
          (trim text))))))

(defun note-mission-submitted ()
  "Write the marker that suppresses re-submission on generation restarts."
  (let ((path (mission-marker-path)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede :if-does-not-exist :create)
      (write-line (iso-time) out))))

(defun maybe-submit-mission (agent)
  "Cold-boot half of mission mode: queue the mission as the first submission.
The marker is written before the enqueue so a crash mid-turn resumes (or
respawns) without running the mission twice."
  (let ((text (mission-text-to-submit)))
    (when text
      (note-mission-submitted)
      (enqueue-submission agent text)
      t)))

(defun run-agent (agent &key resume-payload)
  (setf *agent* agent)
  ;; UI genes (M3) target the live view through this special; set it before
  ;; anything can hot-load a pane or status widget.
  (setf ourro.tui:*active-view* (agent-view agent))
  (setf ourro.tui:*keep-screen-on-exit* nil)
  (install-builtin-keys)
  ;; Wire job-exit notifications before restoring jobs, so a re-attached job that
  ;; dies during boot still tickers (M9-4).
  (install-job-hooks agent)
  (if resume-payload
      (progn
        (restore-session agent resume-payload)   ; re-attaches jobs from :extra
        ;; The recovery point has done its job the moment we're back on screen;
        ;; drop it so a later crash can't resurrect this already-restored session
        ;; (and so the supervisor's crash branch won't loop on it) (M4-1).
        (delete-checkpoint))
      ;; A cold boot with no handoff/checkpoint still re-attaches any jobs left
      ;; running by a prior process, from the state/jobs.sexp mirror (M9-5).
      (ignore-errors (ourro.jobs:restore-jobs-from-disk)))
  (wire-observer agent)
  (wire-evolution-progress agent)
  (connect-supervisor agent)
  (shelve-retry agent)
  ;; Mission mode: a cold boot (no handoff payload) with OURRO_MISSION set and
  ;; the marker absent queues the mission file as the first user message; it
  ;; drains through the same typeahead kick below.
  (unless resume-payload
    (maybe-submit-mission agent))
  ;; Typeahead that rode across a restart (M4-2): kick the first item once the
  ;; runloop is up.
  (when (agent-pending-submissions agent)
    (enqueue-ui agent '(:kind :drain-submissions)))
  (greet agent)
  (redirect-side-output)
  (unwind-protect
       (ourro.tui:with-raw-terminal ()
         (multiple-value-bind (width height) (ourro.tui:terminal-size)
           (setf (agent-screen agent) (ourro.tui:make-screen width height)))
         (start-heartbeat agent)
         (unwind-protect
              (ui-loop agent)
           (setf (agent-running agent) nil)))
    (restore-side-output))
  (if (agent-pending-handoff agent)
      ;; Returns 75; MAIN performs the single sb-ext:exit so the supervisor
      ;; exec's the pending/target generation.
      (perform-handoff agent)
      (progn
        ;; Reached only on a clean quit: no crash happened, so the recovery
        ;; point must not linger to be resumed later (M4-1).
        (delete-checkpoint)
        0)))

(defparameter *max-keys-per-tick* 2048
  "Upper bound on keys drained before a repaint (paste bursts).")


(defvar *qa-status-enabled* :unknown
  "Cached OURRO_QA gate: :unknown until first checked, then T/NIL.")
(defvar *qa-status-tick* 0
  "Monotonic write counter — an external observer watching it stall detects a
wedged UI loop even when every other field is unchanged.")
(defvar *qa-status-fields* nil
  "The last-written significant fields, for change detection (throttle).")
(defvar *qa-status-last-write* 0)

(defun qa-status-enabled-p ()
  (when (eq *qa-status-enabled* :unknown)
    (setf *qa-status-enabled*
          (let ((v (getenv "OURRO_QA")))
            (and v (member (string-downcase (trim v)) '("1" "true" "yes" "on")
                           :test #'string=)
                 t))))
  *qa-status-enabled*)

(defun collect-qa-status-fields (agent)
  "The significant (throttle-compared) qa-status fields — everything but the
volatile :updated timestamp and the monotonic :tick."
  (let* ((view (agent-view agent))
         (statusbar (ourro.tui:view-statusbar view))
         (ticker (ourro.tui:view-ticker view))
         (input (ourro.tui:view-input view)))
    (list :pid (sb-posix:getpid)
          :generation (agent-generation agent)
          :session-id (agent-session-id agent)
          :frozen (and ourro.kernel:*evolution-frozen* t)
          :armed (and ourro.kernel:*automations-armed* t)
          :busy (and (agent-busy agent) t)
          :queue (bt:with-lock-held ((agent-submissions-lock agent))
                   (length (agent-pending-submissions agent)))
          :activity (ourro.tui:statusbar-activity statusbar)
          :ticker (ourro.tui:ticker-text ticker)
          :overlay (and (ourro.tui:view-overlay view) t)
          :input-empty (zerop (length (ourro.tui:input-text input)))
          :pending-handoff (agent-pending-handoff agent))))

(defun write-qa-status-file (payload)
  "Atomically replace state/qa-status.sexp with PAYLOAD via sb-posix:rename
(never cl:rename-file — it would merge the .tmp type into the target)."
  (let ((path (namestring (ourro-path "state/qa-status.sexp")))
        (tmp (namestring (ourro-path "state/qa-status.sexp.tmp"))))
    (ensure-directories-exist path)
    (with-open-file (out tmp :direction :output
                             :if-exists :supersede :if-does-not-exist :create)
      (with-standard-io-syntax
        (let ((*package* (find-package :keyword)))
          (prin1 payload out)
          (terpri out))))
    (sb-posix:rename tmp path)))

(defun write-qa-status (agent)
  "Write the QA heartbeat if enabled and either a field changed or ≥1s elapsed."
  (when (qa-status-enabled-p)
    (let ((fields (ignore-errors (collect-qa-status-fields agent)))
          (now (get-universal-time)))
      (when (and fields
                 (or (not (equal fields *qa-status-fields*))
                     (>= (- now *qa-status-last-write*) 1)))
        (setf *qa-status-fields* fields
              *qa-status-last-write* now)
        (incf *qa-status-tick*)
        (ignore-errors
         (write-qa-status-file
          (list* :version 1 :updated (iso-time) :tick *qa-status-tick* fields)))))))

(defparameter *self-heal-repaint-seconds* 30
  "Interval for the defensive full repaint: anything that scrolls or corrupts
the terminal underneath the diff renderer (a stray library print, a terminal
glitch) is silently repaired within this window — the classic symptom was the
input ❯ vanishing until the next resize.")

(defun ui-loop (agent)
  (let ((spinner-frames #("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"))
        (spinner-index 0)
        (last-size-check 0)
        (last-full-repaint (get-universal-time)))
    (loop while (agent-running agent) do
      ;; 1. keyboard — drain EVERYTHING pending, then paint once. Reading a
      ;; single key per frame made fast typing, key-repeat backspace, and
      ;; pastes crawl (one repaint per character).
      (loop repeat *max-keys-per-tick*
            for key = (ourro.tui:read-key)
            while key
            do (if (eq key :eof)
                   (progn (setf (agent-running agent) nil)
                          (return))
                   (handle-key agent key)))
      ;; 2. drain queued events from workers
      (dolist (event (drain-events agent))
        (case (pget event :kind)
          (:turn-done (on-turn-done agent) (maybe-drain-submission agent))
          (:drain-submissions (maybe-drain-submission agent))
          (:open-inspector (open-inspector agent))
          (:open-pager (open-pager agent (pget event :n)))
          (:open-job-pager (open-job-pager agent (pget event :item)))
          (:job-exit (on-job-exit agent event))
          (:quit (setf (agent-running agent) nil))
          (:handoff (setf (agent-running agent) nil))
          (t nil)))
      ;; 3. resize (SIGWINCH flag, with a slow fallback poll — the size
      ;; probe spawns stty, far too costly to run per keystroke), ticker,
      ;; idle dream mode
      (when (or (ourro.tui:resize-pending-p)
                (> (- (get-universal-time) last-size-check) 5))
        (setf last-size-check (get-universal-time))
        (ourro.tui:clear-resize-pending)
        (check-resize agent))
      ;; Self-healing repaint: periodically drop the diff buffer so the next
      ;; paint rewrites every row, repairing any external screen corruption.
      (when (> (- (get-universal-time) last-full-repaint)
               *self-heal-repaint-seconds*)
        (setf last-full-repaint (get-universal-time))
        (let ((screen (agent-screen agent)))
          (when screen
            (ourro.tui:screen-resize screen
                                    (ourro.tui:screen-width screen)
                                    (ourro.tui:screen-height screen)))))
      (tick-ticker agent)
      (maybe-dream agent)
      ;; Reflexes (M13-3): fire due :idle/:every automations. A cheap
      ;; now-vs-last-fired compare that only enqueues; the worker executes. Inert
      ;; in a visiting museum (the dispatcher isn't even installed there).
      (unless (agent-visiting agent)
        (ignore-errors
         (ourro.automation:tick-automations
          (- (get-universal-time) *last-activity*))))
      (maybe-escalate-cancel agent)
      ;; QA heartbeat (QA-0): dev-only, env-gated, throttled — reflects the
      ;; frame about to be painted so an operator polls a settled snapshot.
      (write-qa-status agent)
      ;; 4. paint
      (paint agent (when (agent-busy agent)
                     (setf spinner-index (mod (1+ spinner-index)
                                              (length spinner-frames)))
                     (format nil "~A working…" (aref spinner-frames spinner-index))))
      ;; 5. deferred handoff at a genuinely quiet boundary — a generation
      ;; restart must not yank the screen out from under someone mid-thought.
      ;; How quiet is the restart policy's call (M12-2, default :calm — 5 min
      ;; idle or the dream window; the old 10 s is :eager).
      (when (and (agent-pending-handoff agent)
                 (restart-allowed-p
                  (restart-policy)
                  (- (get-universal-time) *last-activity*)
                  (agent-busy agent)
                  (zerop (length (ourro.tui:input-text
                                  (ourro.tui:view-input (agent-view agent)))))
                  (> (- (get-universal-time) *last-activity*) *dream-idle-seconds*)))
        ;; Leave the last frame on screen through the restart gap — the next
        ;; generation repaints over it, so the prompt never visibly vanishes.
        (setf ourro.tui:*keep-screen-on-exit* t)
        (return))
      ;; 6. block until a key arrives (instant wake) or a short timeout so
      ;; worker events and the spinner stay fresh.
      (unless (agent-event-queue agent)
        (ourro.tui:wait-input (if (agent-busy agent) 0.09 0.25))))))

(defun paint (agent &optional spinner)
  (when (agent-screen agent)
    (ourro.tui:paint-frame (agent-screen agent) (agent-view agent)
                          :spinner spinner)))

(defun check-resize (agent)
  (multiple-value-bind (width height) (ourro.tui:terminal-size)
    (let ((screen (agent-screen agent)))
      (when (and screen (or (/= width (ourro.tui:screen-width screen))
                            (/= height (ourro.tui:screen-height screen))))
        (ourro.tui:screen-resize screen width height)))))

(defun shelve-retry (agent)
  "On boot, re-enqueue recently-rejected candidates once (M1-3), letting the
evolver take another attempt with the prior failure as feedback."
  (when (and (eq (agent-mode agent) :auto)
             (not (agent-visiting agent))
             (not ourro.kernel:*evolution-frozen*))
    (let ((n (ignore-errors (ourro.evolve:retry-shelved-candidates))))
      (when (and n (plusp n))
        (update-pending agent)
        (spawn-evolver agent)))))

(defun greet (agent)
  ;; The header pane already shows "ourro · gen · repo" — don't repeat
  ;; it in the transcript. A genuinely cold boot (empty transcript) also gets a
  ;; one-time primer; a resume restores scrollback BEFORE greet runs (run-agent),
  ;; so a restored/visiting session skips it (M7-7).
  (let ((cold (null (ourro.tui:transcript-lines
                     (ourro.tui:view-transcript (agent-view agent))))))
    (add-wrapped agent "a self-evolving Lisp coding agent · type to chat · /help for commands"
                 :dim)
    (cond
      ((agent-visiting agent)
       (setf (ourro.tui:statusbar-visiting (ourro.tui:view-statusbar (agent-view agent)))
             (agent-generation agent))
       (add-wrapped agent "(visiting a past generation, read-only)" :warning))
      (cold (greet-primer agent)))))

(defun greet-primer (agent)
  "A one-time cold-boot primer teaching the evolution loop (M7-7)."
  (add-wrapped agent "─ how this works ─" :dim)
  (add-wrapped agent "• watch the ✦ ticker — when I learn a tool it says so; press e to explain, u to undo"
               :dim)
  (add-wrapped agent "• ctrl-e opens the evolution inspector; the gen counter (top-left) ticks on seamless restarts"
               :dim)
  (add-wrapped agent "• I grow tools from your repeated actions and from what you ask for directly"
               :dim)
  (add-wrapped agent "try: /onboard to teach me this repo's build/test/lint commands" :accent))


(defun wire-observer (agent)
  ;; Reflexes (M13/M14): wire POST-NOTE's ticker channel and the reflex worker's
  ;; politeness wait, then install the dispatcher + start the ourro-reflex worker
  ;; — BEFORE start-event-log below, so the boot :session-start event reaches
  ;; session-start reflexes (auto-onboard, M14-4). Never in a visiting museum,
  ;; where reflexes must not even fire read-only.
  (setf ourro.automation:*note-sink*
        (lambda (text style)
          (set-ticker agent text
                      :style (case style
                               (:warning :warning) (:accent :accent) (t :ticker))
                      :seconds 12)
          (enqueue-ui agent '(:kind :dirty))))
  (setf ourro.automation:*politeness-hook*
        (lambda () (loop repeat 300 while (agent-busy agent) do (sleep 0.1))))
  ;; The intern (M15): a reflex's request-investigation runs through here on the
  ;; reflex worker — a read-only mini-turn whose diagnosis becomes a briefing.
  (setf ourro.automation:*investigation-hook*
        (lambda (prompt &key events title)
          (run-investigation-and-brief agent prompt :events events :title title)))
  ;; M20 durable activity adapters return journal records. Only this product
  ;; layer mirrors a completed briefing into the transient pager and ticker.
  (setf (gethash :investigate ourro.reflex.effects:*effect-hooks*)
        (lambda (input key)
          (let* ((provider (agent-provider agent))
                 (provider-name
                   (string-downcase
                    (symbol-name (class-name (class-of provider)))))
                 (record nil)
                 (created-p nil))
            (multiple-value-setq (record created-p)
              (ourro.reflex.briefing:briefing-from-effect-input
               input key
               :provider provider-name
               :model (ignore-errors (ourro.llm:provider-model provider))
               :limits (list :steps *investigation-max-steps*
                             :seconds *investigation-watchdog-seconds*)
               :investigator
               (lambda (prompt evidence)
                 (let ((ourro.reflex.investigation:*maximum-steps*
                         *investigation-max-steps*)
                       (ourro.reflex.investigation:*watchdog-seconds*
                         *investigation-watchdog-seconds*))
                   (ourro.util:plist-put
                    (ourro.util:plist-put
                     (ourro.reflex.investigation:run-investigation
                      provider prompt :events (list evidence)
                      :workspace (pget input :event-workspace))
                     :provider provider-name)
                    :model (ignore-errors
                             (ourro.llm:provider-model provider)))))))
            (when created-p
              (let* ((text (pget record :text))
                     (n (add-briefing
                         agent (format nil "job ~A failed" (pget record :job))
                         text "job-sentinel" (pget record :workspace))))
                (ourro.automation:post-note
                 (format nil "⚡ job ~A — diagnosis ready · /out b~A~%~A"
                         (pget record :job) n (condense-briefing text))
                 :style :accent)))
            record)))
  (setf (gethash :notify ourro.reflex.effects:*effect-hooks*)
        (lambda (input key)
          (declare (ignore key))
          (ourro.automation:post-note
           (or (pget input :text) "reflex notification") :style :info)
          (list :notified t)))
  (unless (agent-visiting agent)
    (ourro.automation:install-automation-dispatch)
    (ourro.reflex.runtime:install-runtime-dispatch))
  ;; START-EVENT-LOG is the only thing that sets OURRO.OBSERVE::*EVENT-LOG-PATH*,
  ;; so it must run on BOTH a fresh boot and a resume (F-1). A resumed or
  ;; crash-recovered session already carries an id; pass it through so we keep
  ;; appending to the *same* events.sexp. Skipping it on resume — as this did
  ;; before — left *event-log-path* nil in the reborn image, so LOG-EVENT
  ;; silently dropped every append for the rest of the session and PR-1's
  ;; observation stream died after the first restart. The re-logged :session-start
  ;; also doubles as a useful restart marker in the stream.
  (setf ourro.observe:*workspace-context-fn*
        (lambda () (and ourro.toolkit:*workspace*
                        (namestring ourro.toolkit:*workspace*))))
  (setf (agent-session-id agent)
        (ourro.observe:start-event-log :session-id (agent-session-id agent)))
  (unless (agent-visiting agent)
    ;; Genome loading has reconstructed immutable versions by this point.
    ;; Restore only a latest lifecycle state that remains explicitly active;
    ;; imported bundles carry a newer :IMPORTED-INACTIVE attestation.
    (ignore-errors
      (ourro.reflex.learn:recover-reflex-lifecycle
       (or ourro.toolkit:*workspace* "workspace:unknown")))
    (ignore-errors
      (ourro.reflex.runtime:recover-runtime
       (or ourro.toolkit:*workspace* "workspace:unknown")))
    (when ourro.kernel:*automations-armed*
      (ourro.reflex.runtime:submit-command
       (list :type :arm :workspace ourro.toolkit:*workspace*))))
  ;; Utility ledger (M1-1): restore measured history and exclude seed genes
  ;; (they have no baseline) from measurement + auto-retirement.
  (ignore-errors (ourro.observe:load-utility-ledger))
  (setf ourro.observe:*gene-measurable-hook*
        (lambda (name) (not (seed-gene-p name))))
  ;; Feed the evolution HUD gene a live gene count without OBSERVE depending on
  ;; GENOME (M7-3): the hook closes over the genome, observe just calls it.
  (setf ourro.observe:*genome-gene-count-fn*
        (lambda () (length (ourro.genome:list-genes))))
  ;; Feed the context/cost HUD gene the live window %/cost the same way (M11-4).
  (setf ourro.observe:*context-summary-fn*
        (lambda () (context-hud-data agent)))
  ;; Restore any mined-but-unproposed patterns from before the last restart —
  ;; queued work should not die at every generation switch (M12-1).
  (ignore-errors (ourro.observe:load-evolution-queue))
  ;; Perf + cost meter (QA-0): every model call (agent turn, evolver,
  ;; onboarding) logs an :llm-call event with model, latency, token usage, and
  ;; outcome. The QA harness's cost caps and soak budgets sum these; zero effect
  ;; on the product beyond one appended event per call.
  (setf ourro.llm:*llm-call-hook*
        (lambda (model elapsed-ms usage error-p)
          (ourro.observe:log-event :llm-call
                                  :model model
                                  :elapsed-ms elapsed-ms
                                  :usage usage
                                  :context ourro.llm:*llm-call-context*
                                  :outcome (if error-p :error :ok))
          ;; Honest accounting (M15-4): background model spend (evolver, dreamer,
          ;; investigator) sums into the session cost so the HUD's $ is the whole
          ;; truth. The user turn is already costed by record-turn-usage, so only
          ;; :background is added here — no double count. Display only, no gate.
          (when (and (eq ourro.llm:*llm-call-context* :background) usage (not error-p))
            (ignore-errors
             (let ((pricing (ourro.llm:model-pricing model)))
               (when pricing
                 (incf (agent-session-cost agent) (turn-cost usage pricing))))))))
  ;; Candidate records (M1-3): restore the last 50 across restarts and mirror
  ;; every future status change into the in-memory list + UI.
  (setf (agent-candidates agent)
        (ignore-errors (ourro.evolve:load-candidate-records :limit 50)))
  (setf ourro.evolve:*candidate-record-hook*
        (lambda (record) (mirror-candidate-record agent record)))
  ;; An evolved turn-hook that errors is removed and surfaced (M1-6) — same
  ;; conditions-not-crashes recovery story as probation.
  (setf ourro.observe:*turn-hook-failure-hook*
        (lambda (name condition)
          (set-ticker agent
                      (format nil "turn hook ~A errored — removed; filed for repair"
                              name)
                      :style :warning :seconds 10)
          (ourro.observe:log-event :turn-hook-error :name name
                                  :error (princ-to-string condition))
          (enqueue-ui agent '(:kind :dirty))))
  ;; When a probation gene reverts, surface it as an amber ticker (PR-6/PR-8)
  ;; and file a persisted :reverted record so the inspector can show it.
  (setf ourro.kernel:*probation-failure-hook*
        (lambda (gene-name condition)
          (ourro.evolve::cancel-pending-graduation gene-name)
          (ourro.observe:note-gene-revert gene-name)
          (record-probation-revert agent gene-name condition)
          (set-ticker agent
                      (format nil "gene ~A failed on use — reverted to previous definition; filed for repair"
                              gene-name)
                      :style :warning :seconds 10)
          (ourro.observe:log-event :probation-revert :gene gene-name
                                  :error (princ-to-string condition))
          (enqueue-ui agent '(:kind :dirty)))))

(defun mirror-candidate-record (agent record)
  "Fold RECORD into the in-memory candidate list (newest first, one entry per
:id, capped at 50) and refresh the UI. Called from the evolve record hook."
  (let ((id (pget record :id)))
    (bt:with-lock-held ((agent-candidates-lock agent))
      (setf (agent-candidates agent)
            (cons record
                  (if id
                      (remove id (agent-candidates agent)
                              :key (lambda (r) (pget r :id)) :test #'equal)
                      (agent-candidates agent))))
      (when (> (length (agent-candidates agent)) 50)
        (setf (agent-candidates agent) (subseq (agent-candidates agent) 0 50)))))
  (enqueue-ui agent '(:kind :dirty)))

(defun purge-agent-workspace-context (workspace)
  "Remove transient, workspace-tagged product views after verified deletion."
  (let ((workspace (ourro.reflex.journal:normalize-workspace workspace)))
    (when *agent*
      (bt:with-lock-held ((agent-candidates-lock *agent*))
        (setf (agent-candidates *agent*)
              (remove-if
               (lambda (record)
                 (ourro.evolve::candidate-value-contains-workspace-p
                  record workspace))
               (agent-candidates *agent*))))
      (setf (agent-briefings *agent*)
            (remove-if
             (lambda (briefing)
               (let ((candidate (pget briefing :workspace)))
                 (and candidate
                      (string= workspace
                               (ourro.reflex.journal:normalize-workspace
                                candidate)))))
             (agent-briefings *agent*)))
      (bt:with-lock-held ((agent-queue-lock *agent*))
        (setf (agent-event-queue *agent*)
              (remove-if
               (lambda (event)
                 (ourro.evolve::candidate-value-contains-workspace-p
                  event workspace))
               (agent-event-queue *agent*)))))
    t))

(ourro.reflex.journal:register-workspace-deletion-hook
 :agent-transient-context #'purge-agent-workspace-context)

(defun record-probation-revert (agent gene-name condition)
  (let ((record (list :id (make-id "revert") :status :reverted
                      :gene-name gene-name
                      :diagnostics (princ-to-string condition)
                      :time (iso-time) :unix (unix-time))))
    (ignore-errors
     (append-sexp-line (ourro.evolve:candidate-records-path) record))
    (mirror-candidate-record agent record)))


(defun connect-supervisor (agent)
  (let ((socket (getenv "OURRO_SOCKET")))
    (when socket
      (let ((connection (ourro.kernel:protocol-connect socket :timeout 3)))
        (when connection
          (setf (agent-supervisor agent) connection)
          (ignore-errors
           (ourro.kernel:protocol-request
            connection (list :hello :generation (agent-generation agent)
                                    :pid (sb-posix:getpid))
            :timeout 10))
          (install-snapshot-hook agent))))))

(defun install-snapshot-hook (agent)
  (setf ourro.evolve::*snapshot-hook*
        (lambda (changes message provenance)
          (request-snapshot agent changes message provenance))))

(defun request-snapshot (agent changes message provenance)
  "Ask the supervisor to build gen N+1 from CHANGES. Returns its id or NIL.
The manifest-add markers are expanded here into a manifest update change."
  (let* ((connection (agent-supervisor agent))
         (expanded (expand-changes-with-manifest changes)))
    (when connection
      (let ((reply (handler-case
                       (ourro.kernel:protocol-request
                        connection
                        (list :propose-generation
                              :changes expanded
                              :message message
                              :provenance provenance
                              :transaction-id
                              (pget provenance :verification-transaction)
                              :proof-hash
                              (pget provenance :verification-proof))
                        :timeout 600)
                     (error (c)
                       (ourro.observe:log-event :snapshot-request-failed
                                               :error (princ-to-string c))
                       nil))))
        (case (first reply)
          (:generation-built (getf (rest reply) :id))
          (:build-failed
           (set-ticker agent "evolution snapshot failed to build (kept live in-image)"
                       :style :warning :seconds 8)
           (ourro.observe:log-event :snapshot-failed
                                   :report (getf (rest reply) :report))
           nil)
          (t nil))))))

(defun expand-changes-with-manifest (changes)
  "Turn :manifest-add / :manifest-remove markers into an explicit manifest.sexp
change. A change carrying only a :manifest-remove writes no file content — the
.gene file stays on disk and in git history; only the manifest drops it."
  (let ((additions '())
        (removals '())
        (plain '()))
    (dolist (change changes)
      (when (and (pget change :path) (pget change :content))
        (push (list :path (pget change :path) :content (pget change :content))
              plain))
      (when (pget change :manifest-add)
        (push (pget change :manifest-add) additions))
      (when (pget change :manifest-remove)
        (push (pget change :manifest-remove) removals)))
    (if (or additions removals)
        (append (nreverse plain)
                (list (list :path "manifest.sexp"
                            :content (updated-manifest-source
                                      (nreverse additions)
                                      (nreverse removals)))))
        (nreverse plain))))

(defun updated-manifest-source (additions &optional removals)
  "Read the current genome manifest, append ADDITIONS and drop REMOVALS,
returning its new readable source. Runs in-image against the loaded genome."
  (let* ((manifest (if ourro.genome:*genome-directory*
                       (ourro.genome:read-manifest ourro.genome:*genome-directory*)
                       (list :generation 1 :genes '())))
         (genes (remove-if (lambda (g) (member g removals :test #'equal))
                           (pget manifest :genes)))
         (new-genes (append genes (remove-if (lambda (a) (member a genes :test #'equal))
                                             additions))))
    (print-readable-to-string
     (list :generation (1+ (or (pget manifest :generation) 1))
           :genes new-genes))))

(defun start-heartbeat (agent)
  (when (agent-supervisor agent)
    (register-worker
     agent
     (lambda ()
       (loop while (agent-running agent) do
         (handler-case
             (ourro.kernel:protocol-send (agent-supervisor agent)
                                        (list :heartbeat))
           (error () (reconnect-supervisor agent)))
         (sleep 2)))
     "ourro-heartbeat")))

(defun reconnect-supervisor (agent)
  "Re-establish a dropped supervisor connection and say hello again so the
watchdog re-arms. Called from the heartbeat thread when a send fails."
  (let ((socket (getenv "OURRO_SOCKET")))
    (when socket
      (let ((connection (ignore-errors
                         (ourro.kernel:protocol-connect socket :timeout 1))))
        (when connection
          (setf (agent-supervisor agent) connection)
          (ignore-errors
           (ourro.kernel:protocol-request
            connection (list :hello :generation (agent-generation agent)
                                    :pid (sb-posix:getpid))
            :timeout 5)))))))

(defun perform-handoff (agent)
  "Serialize the session and tell the supervisor to boot the pending
generation, then RETURN 75 so the supervisor exec's the new image. RUN-AGENT
propagates the code and MAIN performs the single process exit — making the
agent-exit-code half of the supervisor contract a pure, unit-testable seam
(no process teardown to observe it). A /travel forwards its :hard/:visiting
flags (agent-pending-travel); a plain generation restart carries neither, so
the supervisor advances the current generation as before."
  (let ((state-file (serialize-session agent :arrival (agent-pending-arrival agent)))
        (connection (agent-supervisor agent))
        (travel (agent-pending-travel agent)))
    (unless connection
      (error "cannot hand off without a supervisor connection; recovery state retained"))
    (let ((reply (ourro.kernel:protocol-request
                  connection
                  (list* :handoff :generation (agent-pending-handoff agent)
                                  :state-file (namestring state-file)
                                  travel)
                  :timeout 5)))
      (unless (eq (first reply) :ok)
        (error "supervisor rejected handoff: ~S" reply))
      ;; Only durable acknowledgement makes the handoff state supersede the
      ;; crash checkpoint. Failure leaves both recovery artifacts intact.
      (delete-checkpoint)
      75)))


(defun smoke-test ()
  "Prove the image boots and its core subsystems are intact. Exit 0/1."
  (handler-case
      (progn
        (assert (plusp (length (ourro.tools:list-tools))))
        (assert (ourro.genome:list-genes))
        (let ((form (ourro.kernel:safe-read-form "(+ 1 2)")))
          (assert (equal form '(+ 1 2))))
        ;; The kernel proves itself before this image is ever registered good
        ;; (PR-11, M4-5): a base-core change that broke safe-read, the walker,
        ;; revert/probation, protocol framing, or the capability ceiling fails
        ;; the build here rather than shipping.
        (multiple-value-bind (passed report) (ourro.kernel:run-kernel-selftest)
          (unless passed
            (format *error-output* "SMOKE-FAIL: kernel selftest failed:~%~A~%"
                    report)
            (sb-ext:exit :code 1))
          (format t "kernel selftest OK~%"))
        ;; Expose every hardened package lock so a built image self-confirms the
        ;; trust boundary. Informational: T in a built image, NIL under source
        ;; smoke/dev where packages remain pokeable.
        (dolist (package '("OURRO.KERNEL" "OURRO.TXN" "OURRO.VERIFY"
                           "OURRO.VERIFY.COORDINATOR" "OURRO.AUTOMATION"))
          (format t "~A locked: ~A~%" package
                  (and (find-package package)
                       (sb-ext:package-locked-p (find-package package)) t)))
        (format t "SMOKE-OK: ~A tools, ~A genes~%"
                (length (ourro.tools:list-tools))
                (length (ourro.genome:list-genes)))
        (sb-ext:exit :code 0))
    (error (c)
      (format *error-output* "SMOKE-FAIL: ~A~%" c)
      (sb-ext:exit :code 1))))
