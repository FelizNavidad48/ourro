# ourro — The Reflexes Plan (M13–M16): evolution as workflow automation

*Written 2026-07-18 against the working tree (commit `bde23ae` + the
uncommitted daily-driver arc, `make test` green). Companion to
`docs/ROADMAP.md`, `docs/plan-daily-driver.md` (M9–M12, landed), and the PRD.
Line anchors were verified against the working tree at plan time.*

## Context

The product mandate for this arc: **commands are manual overrides, not the
product.** Today nearly every unit of value is reached through a slash
command or a model turn the user must initiate — `/onboard`, `/evolutions`,
`/jobs`, `/out`, asking "why did the tests fail". The next big thing is not
more commands; it is evolution that delivers value to workflows through
**automation**.

The frame, and the arc's name: Gen 1 of the product grew **tools** — the
model's hands, used only when asked. Gen 2 (M3) grew **UI** — its face. This
arc grows **reflexes** — the autonomic nervous system: trigger-driven
**automation genes** that subscribe to the live event stream and act
proactively:

- your edit→test loop gets mined → one keystroke installs the reflex → from
  then on, edits to `src/**` start a background test job at the turn
  boundary, and a failure arrives as a note **with the root-cause diagnosis
  already prepared**, before you ask;
- a dev-server job dies → the sentinel posts the exit code, the log tail, and
  a briefing;
- first boot in an unknown repo → the onboarding probe has already run;
- a correction aimed at a reflex's note narrows that reflex's trigger — the
  same-name-redefinition path the substrate already prefers.

The Lisp thesis, extended one level: conventional agents have hooks — YAML
and shell config the **user hand-writes**. Here a hook is **mined from your
own event stream, proposed by the LLM, verified by the compiler-backed
gauntlet, hot-loaded as capability-bounded machine code, measured by the
utility ledger, probationary, and revertible with one keystroke**. The entire
existing evolution machine — observe → mine → propose → verify → hot-load →
measure → retire — is pointed at automation instead of tools. Homoiconicity
does real work: trigger patterns are S-expression data the miner itself
emits, the walker lints, the inspector diffs, and the duplicate gate compares.

**User decisions (asked & answered):** consent is **bless once, then
autonomous** — a proposed automation arrives staged with a one-keystroke
ticker install; once installed it fires autonomously within its declared
capabilities, with probation/three-strikes auto-revert, one-key undo, and a
global disarm switch. Background LLM spend is **unlimited by decision — no
token budget**; step and wall-clock caps remain purely as runaway protection,
and the HUD keeps showing honest spend.

### Why the substrate is ready (exploration findings)

Two exploration passes over the working tree found the edit surface unusually
prepared — every mechanism this arc needs has a direct template:

| Need | Existing template |
|---|---|
| event hook point | `*event-sink*` — fired on every `log-event` outside the lock (`src/observe/events.lisp:78`, `:144-147`) — **currently installed by nobody** |
| capability-scoped, revert-tracked, error→auto-remove hook | turn hooks (`src/observe/queue.lisp:73-121`): plists `(:name :capabilities :thunk :gene)`, gene-context capture, `record-revert-action`, amber ticker on failure |
| registration verb owned by a gene | `define-status-widget`'s owner-checked revert thunk (`src/tui/components.lisp:302-307`) |
| graceful degradation of live evolved behavior | UI three-strikes → revert + amber (`components.lisp:324-375`, `retire-ui-owner:356`) |
| optional gene contract verified by the gauntlet | `:determinism` metadata + probe stage (the shape/behavior split) |
| new miner family recipe | `:slow-tool` (M12-6): `mine-*` fn + `mine-patterns` append + baseline case + `describe-pattern-body` branch (`src/observe/miner.lisp:173-194`, `src/evolve/prompt.lisp:306`) |
| out-of-process verification | `--verify-gene` child runs the same `verify-gene-text` — new checks/rebinds inherited automatically |
| two-channel non-interrupting notification | jobs: ticker now + note prefixed to the next user message (`src/jobs.lisp:157-170`, `agent.lisp:452-458`) |
| background politeness | `*politeness-hook*` wait-while-busy (`src/evolve/engine.lisp:509-515`, `agent.lisp:1317-1319`) |

And what does **not** exist (all of it built here): general event
subscription, a scheduler (`:idle`/`:every`), per-workspace memory, live
ticker keys beyond hardcoded `e`/`u` (`agent.lisp:2023-2033` — `actions` are
display-only strings), automation measurement (a `:tool-call`'s `:gene` is
the *tool's* owner, `src/tools/protocol.lisp:92` — an automation's firings
are invisible to the ledger), a `:staged` candidate status, a global disarm
for live evolved behavior, or any background mini-turn machinery.

## Design decisions (resolved)

**D-R1 · The trigger lives in-form.** Automation genes are ordinary genes
whose `:code` contains
`(define-automation name (:on <pattern> :cooldown N :defer <mode>) body…)`.
No gene-grammar or metadata change (`genome.lisp:277` untouched);
`check-gene-structure` walks DEFINE-AUTOMATION forms exactly the way it walks
DEFTOOL's `:doc`/`:contract` today (`src/verify/verifier.lisp:79-93`);
`gene-definition-names` gains an `:automation` branch (`genome.lisp:489`) so
the inspector's structural diff shows `＋ automation <name>`.

**D-R2 · Trigger patterns are pure data.** Matched by a pure
`event-matches-p (pattern event)` (~40 LOC, exhaustive table tests). Pattern
keys match event plist keys; value forms: a literal (`equal`), `(:not x)`,
`(:any x y…)`, `(:matches "regex")` (cl-ppcre — already a dependency),
`(:> n)` / `(:< n)`, and a nested plist to descend into plist-valued fields
(`:args (:path (:matches "^src/")))`. Examples:

```lisp
(:on (:kind :job-exit :exit (:not 0)))
(:on (:kind :tool-call :tool "edit_file" :outcome :ok
      :args (:path (:matches "\\.lisp$"))))
(:on (:idle 300))      ; fires after 300s of user idleness
(:on (:every 600))     ; fires on an interval
```

Walker-safe (data, not lambdas — the *action* is the code), mineable (the
`:reaction` family emits trigger shapes directly), diffable, and comparable
by the duplicate gate.

**D-R3 · Dispatch = match + enqueue; one worker executes.** New
`ourro.observe:*event-subscribers*` — an alist `(name . fn)` fired in
`log-event` outside the lock, beside the untouched `*event-sink*`
(`events.lisp:144-147`). The automation dispatcher only **matches and
enqueues** (microseconds, safe on any calling thread — turn worker, UI, job
waiters, evolver); firings land on a bounded queue (cap 64, overflow drops +
warns) drained by a single **`ourro-reflex`** worker thread that:
politeness-waits while the user turn is busy (cap 30 s, the
`*politeness-hook*` pattern) → binds `*in-automation-context*` (events logged
by the action — its own tool calls — never recursively dispatch: the cascade
guard) → executes under `with-timed-event (:automation-fire :gene … :automation
… :trigger-kind …)` + `with-capabilities (gene caps)` +
`sb-ext:with-timeout *automation-timeout-seconds*` (60; long work must go
through `start-job` — the manual says so) + probation
(`ourro.kernel:call-with-probation` — **firings count as probation uses**, so
a fresh automation that errors auto-reverts immediately) + three-strikes
after probation (strike counter on the registry entry; at 3 →
`revert-gene-definitions` + amber ticker via `*probation-failure-hook*` — the
`retire-ui-owner` pattern).

**D-R4 · Debounce by deferral.** `:defer :turn-boundary` (the default for
`:tool-call`/`:user-message`/`:correction` triggers): matched firings
coalesce into a pending set (deduped per automation, keeping the latest
event) and flush from `on-turn-done`'s boundary worker — so test-on-edit
fires once per turn, after the turn, never racing the turn's own edits.
`:job-exit`/`:idle`/`:every` default `:defer :immediate`. Per-automation
`:cooldown` seconds (default 30) on top.

**D-R5 · Gating and the kill switch.** The dispatcher is inert when: new
kernel special `*automations-armed*` is nil (toggled by `/disarm` / `/arm`,
carried through handoff/checkpoint exactly like `*evolution-frozen*`),
when visiting (`agent-visiting` — effects are already ceiling-clamped, but
reflexes shouldn't even *fire* read-only in a museum), and during verifier
staging (`with-staged-registries` rebinds **both** `*event-subscribers*` and
the automation registry — a candidate's load-time `define-automation` can
never touch the live bus). `/freeze` keeps its existing meaning — no *new*
evolution — and continues to gate proposals/applies via `apply-candidate`;
installed reflexes keep firing under freeze unless `/disarm`ed (two levers,
documented).

**D-R6 · Consent: staged + one-keystroke install.** Mined/dreamed candidates
whose gene registers automations stop at a new **`:staged`** status (added to
the candidate vocabulary, `src/evolve/engine.lisp:122/135` — today dream
candidates just linger `:verified`) and announce via a consent ticker with
**real action keys**: `[y install] [n dismiss]`. Install = the inspector's
re-verify + `apply-candidate :force t :snapshot :async` path
(`src/inspector.lisp:256-286`, refactored into a shared
`install-staged-candidate`); dismiss = record `:dismissed` + the pattern
signature joins `attempted-pattern-signatures` so it is never re-proposed.
Deliberate `propose_gene` automations apply directly — user intent needs no
second blessing.

**D-R7 · Notes, never interruptions.** New `post-note (text &key style)` in
OURRO.API generalizes the jobs two-channel pattern: ticker immediately +
note prefixed to the **next user message**. Nothing an automation does ever
touches `compose-system-prompt` (the byte-stable prompt-cache prefix rule
from M10) or writes to the transcript mid-turn (D-1 stands).

**D-R8 · Measurement rides the existing ledger.** The reflex worker's
`with-timed-event (:automation-fire :gene <owner> …)` plus a one-clause
extension of `record-gene-use-from-event` (`src/observe/ledger.lisp:195-201`)
makes uses/errors/mean-ms/retirement/`/keep`/HUD-Σ work for automations with
**zero new ledger machinery**. Baseline: the `:reaction` pattern's
`:occurrence-cost-ms` — the measured cost of the manual reaction the reflex
pre-empts — flows through the existing `set-gene-baseline` on install, so
`gene-savings-ms` = firings × the manual work each one replaced. Honest by
construction.

---

## M13 — The reflex substrate (L, ~5–7 days)

New: `src/automation.lisp` (package `ourro.automation`; ourro.asd slot
after `jobs`, before `genome` — the `src/jobs.lisp` pattern),
`seed-genome/genes/auto/job-sentinel.gene`, `tests/automation-test.lisp`, a
QA T1 scenario. Modified: `src/observe/events.lisp` (subscribers seam),
`src/kernel/capabilities.lisp` + `src/kernel/walker.lisp` + `src/kernel/
conditions.lisp` (`:automate`, rows, `*automations-armed*`),
`src/genome/genome.lisp` (API block + `gene-definition-names`),
`src/verify/verifier.lisp` (structure check + staged rebinds),
`src/observe/ledger.lisp` (one clause), `src/evolve/prompt.lisp` (manual
section), `src/agent.lisp` (worker start, ui-loop tick, `/disarm`//`/arm`,
handoff carry), `seed-genome/manifest.sexp`, `ourro.asd`.

### M13-1 · Events grow subscribers (S)

`ourro.observe:*event-subscribers*` alist + `add-event-subscriber` /
`remove-event-subscriber`; fired in `log-event` after `*event-sink*`
(`events.lisp:144-147`), each under `ignore-errors`. Not exported to
OURRO.API — genes reach the bus only through `define-automation`.

### M13-2 · The registry + `define-automation` (M)

`*automations*`: entries `(:name :gene :trigger :action-fn :capabilities
:cooldown :defer :strikes :last-fired)` under `*automations-lock*`. **No
persistence file — the genome is the persistence**: automations re-register
when their genes load at every boot/restart/travel. `define-automation`
expands to a `register-automation` call capturing
`ourro.tools:*current-gene-context*` (name + capabilities, exactly like
`deftool` protocol.lisp:349-351) and recording an **owner-checked** revert
thunk (`components.lisp:302-307` pattern). `event-matches-p` per D-R2.

### M13-3 · Dispatcher, firing queue, `ourro-reflex` worker, ticks (M/L)

Per D-R3/D-R4/D-R5. The `:idle`/`:every` tick (`tick-automations`) is called
once per ui-loop iteration next to `maybe-dream` (`agent.lisp:2516`) — a
cheap now-vs-`:last-fired` compare that enqueues due firings. Deferred
firings flush from the `on-turn-done` boundary worker (`agent.lisp:1027`
neighborhood). Worker started in `wire-observer`; stopped at quit.

### M13-4 · Capability, walker, API, gauntlet, ledger (M)

`:automate` joins `+all-capabilities+` (`capabilities.lisp:14` — the closed
set, a deliberate edit). Walker rows: `DEFINE-AUTOMATION → :automate`,
`POST-NOTE → :observe` (`walker.lisp:~58`, after the `:ui` block). OURRO.API:
import block for `ourro.automation` (`genome.lisp:~97`) + exports (`~159`) —
`define-automation`, `post-note`, `fire-automation-for-test`.
Gauntlet: `check-gene-structure` walks DEFINE-AUTOMATION forms — well-formed
`(:on <pattern>)` with a known `:kind` (or `:idle`/`:every`), valid value
forms, body non-empty; a gene declaring `:automate` without any
DEFINE-AUTOMATION (or vice versa) is rejected. `with-staged-registries`
rebinds `*automations*` + `*event-subscribers*` (`verifier.lisp:164-188`).
**`fire-automation-for-test (name &optional event)`** runs a registered
automation synchronously under its caps — so a gene's `:tests` can exercise
its own reflex hermetically in the sandbox. Ledger: extend
`record-gene-use-from-event` to also count `:automation-fire` events.

### M13-5 · `post-note` + `/disarm` (S)

`post-note` per D-R7 (generalizes `*job-exit-notes*` — jobs migrate to it or
stay parallel; prefer migrating so there is one notes path). `/disarm` /
`/arm` toggle `*automations-armed*` with a statusbar hint while disarmed;
carried through handoff `:extra` + checkpoint like `*evolution-frozen*`
(`agent.lisp:1820/2424` pattern).

### M13-6 · Manual + seed sentinel (S/M)

`harness-manual` **AUTOMATION GENES** section after UI GENES
(`prompt.lisp:~189`): the verb, the trigger grammar with the value forms, the
`:automate` capability, the rules (background work goes through `start-job`;
surface via `post-note`; never write user files from a reflex; cooldown/defer
semantics), and one worked example. Seed
**`auto/job-sentinel`** — capabilities `(:observe :automate)`:

```lisp
(define-automation job-sentinel
    (:on (:kind :job-exit :exit (:not 0)) :cooldown 10)
  (post-note (format nil "job ~A (~A) exited ~A — ~A"
                     (pget event :job) (pget event :command)
                     (pget event :exit) (sentinel-log-tail event))
             :style :warning))
```

(the action receives the matched `event`; `sentinel-log-tail` is a pure
helper over `job-status`). Hermetic `:tests` via `fire-automation-for-test`
with a synthetic event. Manifest + seed-count assertions bumped.

**Tests** (`tests/automation-test.lisp`): `event-matches-p` table (every
value form, nested `:args`, non-matching kinds); register/revert round-trip
(owner check included); dispatch enqueues only on match, never executes
inline; cascade guard (an action that `log-event`s doesn't re-fire);
defer-to-boundary coalesces N matches into 1 firing; cooldown suppresses;
probation firing error auto-reverts; three-strikes post-probation reverts +
amber; disarm/visiting/staging inertness; walker requires `:automate`;
structure check rejects malformed triggers; ledger counts firings; sentinel
gene passes the gauntlet in-process **and** through `--verify-gene` (the
child inherits the new checks — assert once in `verify-e2e`).

**M13 verification (live)**: `make dev`; start a job that fails (`job_start
"sh -c 'sleep 1; exit 3'"`) → within ~2 s the warning ticker + on your next
message the model already knows; `/disarm` → silence; kill `-9` mid-queue →
reboot re-registers the sentinel from the genome.

---

## M14 — Consent + the reaction miner (M/L, ~4–6 days)

### M14-1 · Ticker actions become real keys (M)

`set-ticker` (`agent.lisp:325-330`) accepts actions as `(key label command)`
triples (plain strings stay display-only); `ticker-key`
(`agent.lisp:2023-2033`) dispatches on the *current ticker's* keys instead of
hardcoded `e`/`u` — the evolution tickers pass `((#\e "e explain" :explain)
(#\u "u undo" :revert))` so behavior is byte-identical; the empty-input guard
stays. Tests: existing e/u paths unchanged; a y/n ticker fires its commands;
keys inert while typing.

### M14-2 · The staged lifecycle (M)

New candidate status `:staged` (vocabulary at `engine.lisp:122/135`; ticker
`◐` glyph in the inspector already renders staged-style records). Policy: in
`process-evolution-queue`/`dream`, a **verified candidate whose gene
registers automations** (detected via `gene-definition-names` `:automation`
entries) and whose origin is mined/dreamed → mark `:staged`, do **not**
apply; announce with the consent ticker `"reflex proposed: run tests after
src edits · [y install] [n dismiss] · e details"`. Install = shared
`install-staged-candidate` (factored from `inspector.lisp:256-286`; the
inspector's `a` key now calls the same function). Dismiss = status
`:dismissed` + signature into the attempted set. Records persist as always
(`state/evolutions.sexp`).

### M14-3 · The `:reaction` miner family (M/L)

The arc's engine. `mine-reactions` (`src/observe/miner.lisp`, the
`:slow-tool` recipe): scan recent events for pairs (A, B) where A is a
trigger-shaped event (a `:tool-call` with stable tool + anti-unified skeleton,
or a nonzero `:job-exit`) and B is a `:tool-call` occurring within the
following 10 events / 2 turns; group by (A-signature, B-signature); support
≥ 3 → emit:

```lisp
(:kind :reaction
 :trigger-shape (:kind :tool-call :tool "edit_file"
                 :args (:path (:matches "\\.lisp$")))   ; derived, data
 :reaction-tool "shell" :reaction-skeleton (…)
 :occurrence-cost-ms <mean B cost> :evidence (…))
```

`describe-pattern-body` branch (`prompt.lisp:281-326`): *"After A the user
repeatedly does B. Write an automation gene: `define-automation` with exactly
this `:on` pattern; perform B in the background (use `start-job` for
subprocess work — never block); `post-note` the outcome with a short summary;
never modify user files from a reflex. Benefit to beat: the measured cost of
one manual B."* + evidence. `pattern-signature` extended with the trigger
shape; `duplicate-automation-verdict` (parallel to `duplicate-tool-verdict`,
`engine.lisp:273-302`): LLM compare of trigger+action against an
`automation-inventory-text` of the live registry, `:origin :mined` only,
fails open. Dream proposes reflexes for free once the family exists (it takes
the top patterns regardless of family).

### M14-4 · Per-workspace memory + auto-onboarding (M)

`state/workspaces.sexp` (atomic sexp file, D-4 conventions) + `ourro.observe`
fns `workspace-known-p` / `remember-workspace` (walker `:observe`). Seed
**`auto/onboard-new-repo`** — `(:on (:kind :session-start))`: if the
workspace is unknown, run the **pure** `probe-repository` (file reads only,
`onboard.lisp:54-115`) in the action, `remember-workspace`, and when probes
found candidates post the consent ticker *"unknown repo — probe & grow
repo/test + repo/build? [y]"*; `y` runs the existing
`run-probes → grow-onboarding-genes` flow (`onboard.lisp:124-194`) on a
worker. Executing foreign build commands keeps the one blessing; pure
detection is automatic. `/onboard` remains the manual override.

**Tests**: reaction mining table (support, window, skeleton derivation,
job-exit-as-A); staged policy (mined automation gene → `:staged`, tool gene →
applied as today; deliberate → applied); y installs / n dismisses + never
re-proposed; workspace memory round-trip; onboard seed's pure half fires on a
fixture tree. QA T1: scripted provider returns a canned reflex gene → staged
ticker asserted via qa-status/screen → `y` → `:automation-fire` after the
trigger event.

**M14 verification (live)**: in a scratch repo, edit a file then run tests
3× → dream or `maybe-mine` proposes the reflex → `y` → next edit-turn ends →
job starts, note arrives; `/evolutions` shows the staged→installed record
with measured savings accruing.

---

## M15 — The intern: agentic reflexes (M/L, ~4–6 days)

### M15-1 · Headless mini-turns (M/L)

New `src/investigate.lisp`: `run-investigation (provider prompt &key events
(max-steps 8))` — its own message list (system: investigator role, workspace,
read-only rules; user: prompt + serialized context events), loop of
`ourro.llm:complete-with-retry` + `ourro.tools:execute-tool-call` under
capability ceiling `(:filesystem-read :observe :llm)`, per-investigation
wall-clock watchdog (5 min) and step cap — **runaway protection only; no
token budget, per user decision**. Runs serialized on the reflex worker
(politeness-yields to user turns; one investigation at a time). **Never
touches the transcript or the tool-output ring** (D-1 — those belong to the
turn worker); its tool-call events are logged (observation is total) but
`*in-automation-context*` keeps them from re-triggering reflexes.

### M15-2 · Briefings (S/M)

Results land in a briefings ring (`(:n :title :text :time :automation)`,
cap 10) + `post-note` headline: `"⚡ j3 failed — diagnosis ready · /out b1"`.
Pager: `/out b<n>` synthesizes an item from the briefing (the `/out j<id>`
job-log pattern). Briefing text also prefixes the next user message in
condensed form (≤ 20 lines) so the model has it without a command — `/out b1`
is the override for the full text.

### M15-3 · `request-investigation` in OURRO.API (S)

`request-investigation (prompt &key events title)` — enqueues an
investigation; walker row → `:llm`. Upgrade **`auto/job-sentinel`**: after
the deterministic note, `request-investigation` with the job's log tail —
capabilities become `(:observe :llm :automate)`. The gene's tests keep the
deterministic half hermetic; the agentic half is covered by a scripted-
provider integration test.

### M15-4 · Honest accounting + correction tuning (S/M)

Background `:llm-call`s (investigations, evolver, dreamer, summarizer) sum
into `agent-session-cost` tagged `:context :background` so the context HUD's
`$` is the whole truth (display only — no gate). Correction tuning: a
`:correction` event arriving within 2 turns of an automation's note attaches
`(:automation <name>)` to the correction; `describe-pattern`'s `:correction`
branch, when the class references an automation, instructs *"redefine gene
<owner> with a narrower `:on` pattern or remove the automation"*; ≥ 2
corrections against one automation → retirement reason `:corrected`
(`retirement-reason`, `agent.lisp:1076-1093`) with the usual grace ticker +
`/keep` veto.

**Tests**: investigation loop with a scripted provider (tool calls execute,
step cap halts, watchdog reaps a stall, no transcript/ring mutation —
assert by inspecting agent state); briefing ring + pager item; cost
accumulation; correction→automation attribution table; sentinel-with-
diagnosis end-to-end scripted.

**M15 verification (live)**: fail a real test job → within ~30 s the ticker
says diagnosis ready → your next message shows the model already citing the
root cause; `/out b1` shows the full briefing; tell it "stop diagnosing lint
jobs" twice → the sentinel narrows or retires with the grace ticker.

---

## M16 — Prove it + close the loop (M, ~3–4 days)

1. **QA scenarios** (T1 scripted; T2 live where marked): sentinel end-to-end
   (fixture job fails → `:automation-fire` + note in next model input +
   briefing); mined reaction → `:staged` → `y` → firing → ledger uses > 0 →
   HUD Σ moves; three-strikes revert (a deliberately erroring reflex gene
   fixture); `/disarm` silence; freeze blocks proposals while armed reflexes
   still fire; visiting is fully inert; `kill -9` → restart re-registers
   reflexes from the genome (T2: the whole marquee beat live).
2. **Live-shoot beats** appended to `docs/live-shoot.md` (assert via
   `events.sexp` + logs, never screen-scraping).
3. **The command audit** — the arc's closing statement of the user's
   principle: for every command, name its automated path in `/help` and the
   README (`/onboard` → auto-onboarding; `/evolutions` → proposal tickers +
   arrival notes; `/out` → notes/briefings; `/jobs` → sentinel; `/genome` →
   HUD). Commands that remain manual-only (`/travel`, `/quit`, `/keep`,
   `/disarm`) are the deliberate overrides.
4. **Docs/SKILL/README refresh**: new gotchas (cascade guard, defer
   semantics, `fire-automation-for-test`, staged status, the two levers
   freeze-vs-disarm), ROADMAP scorecard row for the arc.

---

## Dependencies, effort, order

| Item | Effort | Depends on |
|---|---|---|
| M13-1 event subscribers | S | — |
| M13-2 registry + verb | M | — |
| M13-3 dispatcher/worker/ticks | M/L | M13-1/2 |
| M13-4 capability/walker/gauntlet/ledger | M | M13-2 |
| M13-5 post-note + disarm | S | — |
| M13-6 manual + sentinel seed | S/M | M13-2..5 |
| M14-1 ticker keys | M | — (independent) |
| M14-2 staged lifecycle | M | M13, M14-1 |
| M14-3 `:reaction` family | M/L | M13 (trigger shapes) |
| M14-4 workspace memory + auto-onboard | M | M13, M14-1 |
| M15-1 headless mini-turns | M/L | M13-3 (worker) |
| M15-2 briefings | S/M | M15-1 |
| M15-3 API + sentinel upgrade | S | M15-1/2 |
| M15-4 accounting + corrections | S/M | M15-1 |
| M16 prove-it | M | all |

Order: M13 → M14 → M15 → M16. M14-1 (ticker keys) and M14-4's workspace
memory are independent early fillers; M15 is independent of M14-3's miner.

## Cross-cutting risk register

| Interaction | Risk | Mitigation |
|---|---|---|
| action logs events | reflex cascade / infinite loop | `*in-automation-context*` binding + per-automation cooldown + bounded queue + firings-count in `:automation-fire` events for audit |
| mid-turn firing | reflex races the turn's own edits | `:defer :turn-boundary` default for tool-call triggers + politeness wait on the worker |
| staging leak | candidate's load-time registration reaches the live bus | rebind `*automations*` **and** `*event-subscribers*` in `with-staged-registries`; test pins both |
| gene tests need firings | tests can't wait for real events | `fire-automation-for-test` synchronous helper, sandbox-only semantics |
| probation semantics | a broken reflex fires 3× before anyone notices | firings run through `call-with-probation` — first error in probation reverts instantly |
| restart | in-flight queue + cooldown clocks lost | acceptable: genome re-registers automations; document; `:automation-fire` history persists in events |
| prompt cache | notes/status leak into the stable prefix | notes ride the next user message only (D-R7); rule already pinned in `compose-system-prompt` |
| ticker keys | y/n collides with typing or e/u | per-ticker key triples + the existing empty-input guard; e/u preserved as defaults |
| wrong mined reflex | annoying or harmful automation | bless-once gate + probation + three-strikes + `u` undo + correction-driven narrowing + retirement + `/disarm` |
| runaway investigation | infinite tool loop (cost is per-user-decision unlimited, but time isn't) | step cap 8 + 5-min watchdog + serialized worker |
| duplicate reflexes | near-identical triggers accumulate | signature extension + `duplicate-automation-verdict` (fails open, like tools) |
| freeze confusion | user expects /freeze to stop firings | two documented levers: `/freeze` = stop learning, `/disarm` = stop firing; statusbar shows both states |

## Critical files

New: `src/automation.lisp`, `src/investigate.lisp`,
`seed-genome/genes/auto/job-sentinel.gene`,
`seed-genome/genes/auto/onboard-new-repo.gene`, `tests/automation-test.lisp`,
`tests/investigate-test.lisp`, QA fixtures/scenarios.
Modified: `src/observe/events.lisp`, `src/observe/miner.lisp`,
`src/observe/ledger.lisp`, `src/kernel/{capabilities,walker,conditions}.lisp`,
`src/genome/genome.lisp`, `src/verify/verifier.lisp`,
`src/evolve/{engine,prompt}.lisp`, `src/agent.lisp`, `src/inspector.lisp`,
`src/pager.lisp`, `src/jobs.lisp` (notes migration), `src/onboard.lisp`
(callable halves), `seed-genome/manifest.sexp`, `ourro.asd`,
`scripts/verify-e2e.sh`, `.claude/skills/ourro/SKILL.md`, `README.md`,
`docs/ROADMAP.md`, `docs/live-shoot.md`.

## Reused machinery (no new deps, no new state formats beyond two sexp files)

The turn-hook contract (capability capture + revert + auto-remove + amber);
`record-revert-action` owner-checked thunks; the three-strikes/`retire-ui-owner`
degradation path; `call-with-probation`; `with-staged-registries`;
`check-gene-structure`'s DEFTOOL-walk precedent; the `:slow-tool` new-family
recipe; `pattern-signature` + `attempted-pattern-signatures` dedup;
`duplicate-tool-verdict`'s gate shape; the inspector apply path (shared
install); the jobs two-channel notification + `/out` synthesized pager items;
`start-job` for all subprocess work; `*politeness-hook*`; `complete-with-retry`
+ `execute-tool-call` (headless loop); `ourro.util` atomic sexp helpers
(`state/workspaces.sexp`, nothing else new — the genome persists automations);
`make-scripted-provider` + the QA T1 harness for every deterministic proof.
