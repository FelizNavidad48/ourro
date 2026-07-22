# ourro — The Daily-Driver Plan (Phase 0 + M9–M12)

*Written 2026-07-17 against commit `bde23ae` plus the uncommitted 429/wsroot
working tree. Companion to `docs/ROADMAP.md` (M0–M8 status),
`docs/plan-m6-m8.md` (M6–M8; its "M9 — Adaptation depth" sketch is absorbed
here as M12-6), `docs/async-evolution.md` (options A/B/C — this plan lands A
and B and moves restart policy toward C), and the PRD. Line anchors were
verified against the working tree at plan time.*

## Context

M0–M8 closed the self-evolution USP: mine → propose → gauntlet → hot-load →
restart is real, measured, and QA-verified live on both Gemini and Claude.
What the product is *not* yet is a genuinely useful, efficient daily-driver
coding agent. The QA rounds have a single recurring theme — **long-running
work is where it hurts**: a backgrounded dev server wedged a turn for 11
minutes (F-bgshell), a stalled stream held `:BUSY` for 12 (F-llmwedge), the
25-step cap ended big tasks silently (F-turncap), and a throttled provider
burned 13 × 429 in one session. The gaps, precisely:

1. **No background work.** `shell` is strictly synchronous; F-bgshell only
   stopped the hang. A dev server cannot coexist with chat. The seam already
   exists: `cap/launch-program` (`src/kernel/capabilities.lisp:134`) is
   exported in `OURRO.API` and walker-mapped to `:subprocess` — and has **zero
   callers**.
2. **The turn is serial everywhere.** `run-tool-calls` (`src/agent.lisp:549`)
   is a sequential `mapcar`; a batch of four file reads costs four latencies.
3. **No context management.** `agent-conversation` is unbounded append-only,
   sent whole every turn; token usage is parsed (`src/llm/vertex.lisp:554`,
   `src/llm/bedrock.lisp:202`) but never consumed. No compaction, no prompt
   caching on either provider, and Bedrock/Claude doesn't stream at all.
4. **Evolution still touches the user's flow.** The gauntlet compiles and
   tests in-process (shared heap/GC with the UI); the mined path snapshot-
   builds **synchronously on the evolver thread** (`src/evolve/engine.lisp:418`
   — verified; only deliberate `propose_gene` passes `:async`); and the
   generation restart drops keystrokes and transients after just 10 s idle.
5. **Open P1 F-travel.** `request-travel` (`src/agent.lisp:1485`) sends the
   `:handoff` protocol message but never sets `agent-pending-handoff`, so
   `run-agent` returns, `main.lisp:98` exits **0**, and the supervisor
   (`src/supervisor.lisp:1042`) reads a clean quit and shuts the session down.
   Every `/travel` kills the product.

**User decisions (asked & answered):** provider efficiency work targets
*both, Claude first* (build the Bedrock eventstream decoder + cachePoint);
the **full walker-gated `lisp_eval` scratchpad** is in scope; **jobs land
first** (M9 before M10–M12).

## Thesis

*Conventional coding agents' table stakes, rebuilt on Lisp primitives — plus
things only a live image can do.* Three standing principles carry forward
unchanged: **evolution never interrupts user flow** (async-evolution.md),
**genome is truth, the image is a cache**, and **all safety flows through
capabilities + the walker**. Four differentiators to keep on camera:

- **The scratchpad is the host compiler.** `lisp_eval` + a `(tool-output n)`
  accessor over the result ring: filter a 30 KB log *in-image* instead of
  re-reading it into context. Other agents get a bash calculator; this one
  gets SBCL.
- **Capabilities license parallelism.** The same declarations that gate
  safety decide which tool calls may run concurrently — evolved tools get
  parallel execution for free by declaring read-only caps. The metaclass
  measures; the ledger sees the saved wall-time.
- **Jobs outlive generations.** A dev server started by the agent survives
  the agent's own evolution restart — pid + log file re-attach across the
  exec-75 gap. "Your server outlives the agent that started it."
- **Efficiency is a mined pattern family.** The `:slow-tool` miner (M12-6)
  makes the agent notice *your* slow commands and grow faster ones — the
  optimizations in this plan are hand-built; the ones after it are evolved.

---

## Phase 0 — Land what's in flight (S, 1–2 days)

### P0-1 · Commit the 429-hardening + F-wsroot work

Two coherent commits from the current working tree: (1) LLM throttle
hardening — `src/llm/vertex.lisp` (`*retry-max-attempts*` 3→5,
`*retry-backoff-cap*` 30 s, `parse-retry-after`/`retry-sleep-seconds`,
`retry-after` slot), `src/llm/bedrock.lisp` + `src/llm/json.lisp` exports,
`tests/vertex-test.lisp` (5 new tests); (2) F-wsroot — `src/main.lisp`
(`OURRO_WORKSPACE` honored in `boot`), `qa/src/operator.lisp` (sandbox
`work/` + env forwarding), `docs/qa-findings.md`, `qa/findings/F-wsroot.sexp`
+ `qa/findings/F-travel.sexp` (filed).

### P0-2 · Fix F-travel (P1) — /travel must exit 75, and the contract becomes testable

- `request-travel` (`src/agent.lisp:1485`): stop `protocol-send`ing
  `:handoff` directly. Instead set `agent-pending-handoff` to the target id
  plus a new `agent-pending-travel` slot `(:hard h :visiting v)`, set
  `ourro.tui:*keep-screen-on-exit*`, and stop the run loop — travel is
  user-intent, so it deliberately bypasses the quiet-boundary gate.
- `perform-handoff` (`src/agent.lisp:2447`): include `:hard`/`:visiting`
  from the travel slot in the `:handoff` message, and **return 75** instead
  of calling `sb-ext:exit`; `run-agent` returns the code; `main.lisp` does
  the single `sb-ext:exit` — the agent-exit-code half of the supervisor
  contract becomes a pure, unit-testable seam.
- **Tests**: (unit) `request-travel` with a stub connection ⇒ pending slots
  set, payload carries `:hard`/`:visiting`, the run-agent path yields 75 —
  no process exit involved; (integration, the missing round-trip) `supervise
  :once` + `*spawn-agent-hook*` (pattern at `tests/supervisor-test.lisp:471`)
  with a stub that protocol-connects, sends `:handoff :visiting t`, and
  exits 75 ⇒ the supervisor takes the handoff branch and arms
  `resume`/`visiting`; reverting the fix makes the same test observe `:quit`.
  Also pin the invalid-target path (`gen-9999` ⇒ "rebooting current", session
  alive).

### P0-3 · Mined snapshots go async

`src/evolve/engine.lisp:418`: `(apply-candidate candidate)` →
`(apply-candidate candidate :snapshot :async)` — frees `ourro-evolver` from
the minutes-long image build and its 600 s `protocol-request`
(`src/agent.lisp:2361`). Document the known pre-existing wart it inherits:
the `ourro-snapshot` thread and the heartbeat thread share one supervisor
connection; safe today because `:heartbeat` has no reply and the protocol
splits send/request locks (`src/kernel/protocol.lisp:34-40`) — say so in a
comment. **Test**: evolve-test with a scripted provider + a
semaphore-blocking `*snapshot-hook*` ⇒ `process-evolution-queue` returns
before the hook completes; the candidate reaches its snapshot state after
release.

**Phase 0 verification**: `make test` (supervisor + new travel assertions
green). Live `make run`: `/travel 1` ⇒ read-only visit arrives; `/travel
9999` ⇒ "rebooting current" and the pane survives; `grep ':handoff'
$OURRO_HOME/state/supervisor.log`.

---

## M9 — "Jobs" — background work, the dev-server story (M/L, ~4–6 days)

New: `src/jobs.lisp` (package `ourro.jobs`),
`seed-genome/genes/tools/jobs.gene`, `seed-genome/genes/ui/jobs-hud.gene`,
`tests/jobs-test.lisp`, `qa/fixtures/slow-server.sh` + a T1 scenario.
Modified: `src/kernel/capabilities.lisp`, `src/genome/genome.lisp` (API
exports), `src/kernel/walker.lisp` (capability rows), `src/agent.lisp`,
`src/pager.lisp` (one synthesized item path), `src/main.lisp` (re-attach at
boot), `ourro.asd`.

### M9-1 · Kernel: `cap/launch-program` grows an output file

`src/kernel/capabilities.lisp:134`: add `:output-file` (stdout+stderr append
to the file) and force `:input nil` (a job must never touch the tty).
Currently it discards output (`:output nil :error-output nil`) — useless for
a dev server whose startup errors are the whole point. Already exported in
`OURRO.API` and walker-mapped to `:subprocess`, so job *genes* need no new
walker machinery for the launch itself.

### M9-2 · The registry (`src/jobs.lisp`, package `ourro.jobs`)

- Job plists `(:id "j1" :command :directory :pid :log :started :status
  :exit)` in `*jobs*` under `*jobs-lock*`; every mutation mirrors to
  `state/jobs.sexp` via the atomic `ourro.util:write-sexp-file` (D-4 style) so
  **crash-resume re-attaches too**, not just handoffs.
- `start-job (command &key directory)` → `cap/launch-program` with
  `:output-file state/jobs/<id>.log`, then a **waiter thread** per job:
  `uiop:wait-process` → record `:exited` + exit code, `log-event
  (:kind :job-exit …)`, fire a ticker hook the agent installs, and push a
  pending-note string (M9-4).
- `job-status (id)` → status + **log tail since the caller's per-job read
  cursor** (the model never re-reads what it has seen); `job-kill (id)` →
  TERM, 2 s grace, KILL; `jobs-summary ()` → compact plist for the HUD.
- Survival semantics (verified): the agent is **not** a session leader (the
  supervisor spawns it plainly, `src/supervisor.lisp:835`; the session leader
  is the user's shell running `ourro run`), so agent exit — including the
  exit-75 exec gap — only reparents children; SIGHUP arrives when the user
  closes the *terminal*, which is exactly the kill semantics a dev server
  should have. No `setsid` needed (macOS doesn't ship one anyway).

### M9-3 · Tools as a seed gene (`tool/jobs`)

Capabilities `(:subprocess :observe)`. Three tools composing `ourro.jobs`
helpers (exported into `OURRO.API`; walker rows: `START-JOB`/`KILL-JOB` →
`:subprocess`, `JOB-STATUS`/`JOBS-SUMMARY` → `:observe`):

- `job_start (command, directory?)` — returns the job id **plus ~2 s of
  early output** (brief sleep-poll on the log) so a crash-on-boot server is
  visible in the same tool result;
- `job_status (id?)` — one job's tail-since-cursor, or all jobs when no id;
- `job_kill (id)`.

`shell.gene` stays untouched — a separate tool family is clearer to the
model and keeps shell's contract simple. Gene tests run a `sleep`-based
fixture through the staged sandbox.

### M9-4 · Chat integration

- **Exit notes reach the model without polling**: job-exit pending-notes are
  drained by `submit-message` and *prefixed to the next user message* —
  `[job j1 (npm run dev) exited 1 — job_status j1 for the log]` — never the
  system prompt, which must stay byte-stable for prompt caching (M10-3).
  Ticker fires immediately on exit; the note covers the model's side.
- `/jobs` lists jobs in the transcript; `/out j1` opens the pager on the
  last ~64 KB of the job log — `cmd-out` (`src/agent.lisp:1323`) parses the
  `j` prefix and synthesizes one pager item plist (`:result` = tail), no
  pager internals change.
- `ui/jobs-hud.gene`: `(define-status-widget jobs-hud (:interval 5) …)` over
  `jobs-summary` → `"⚙ 2 jobs"`; capabilities `(:observe :ui)`; hermetic
  pure tests like `ui/evolution-hud.gene`.

### M9-5 · Survival across restarts and quit

- Handoff/checkpoint: `:extra :jobs` (id, command, pid, log path, started) —
  additive keys are forward/backward-compatible (verified:
  `read-handoff` checks only `:version 1`, `src/kernel/handoff.lisp:50`;
  `pget` → NIL for missing).
- `restore-session` re-attach: `kill -0` per pid ⇒ `:running` with the
  waiter replaced by a 2 s liveness poller (`process-info` objects don't
  survive exec; pid + log path is the durable identity), else `:exited` with
  `:exit :unknown-after-restart`.
- Clean `/quit` kills all running jobs (announced) before the `:quit` event;
  crash-resume re-attaches from `state/jobs.sexp`.

**Tests** (`tests/jobs-test.lisp`): registry lifecycle with `sh -c "sleep
0.2; echo done"`; exit-code capture via the waiter; tail-cursor semantics;
re-attach from a synthetic `jobs.sexp` (live pid vs dead pid); note-injection
ordering into `submit-message`; `/quit` reaps. **QA scenario** (T1,
scripted): `job_start` the fixture server → `:await-event` on `:job-start` →
chat stays responsive (`:await-idle` under 5 s) → force a generation restart
→ `job_status` still `:running` (same pid) → `/quit` → fixture pid dead. No
new QA DSL primitives needed.

**M9 verification (live)**: `make run` in a vite/npm repo: "start the dev
server" ⇒ id + early output, chat fully usable while it runs; trigger an
evolution ⇒ *the dev server survives the generation restart* (same pid);
kill the server externally ⇒ ticker + next-message note; `/out j1` pages the
log.

---

## M10 — "The efficient turn" (M/L, ~6–9 days)

### M10-1 · Capability-derived parallel tool batches (M)

Rewrite `run-tool-calls` (`src/agent.lisp:549`) around a partition:

- **Eligibility** (`parallel-eligible-p`): tool exists ∧ its declared
  capabilities ⊆ `{:filesystem-read}` ∧ its gene is not on probation ∧ the
  batch has >1 call. Consecutive eligible runs execute concurrently (≤8
  workers); everything else stays serial in order; a batch of one takes
  today's exact path.
- **Threading (verified — workers need no dynamic rebinding)**: workers call
  *only* `ourro.tools:execute-tool-call` and return `(result error-p ms)`.
  `call-instrumented` (`src/tools/protocol.lisp:90`) itself binds
  `*active-capabilities*` from the tool's declaration on whatever thread it
  runs; `*workspace*` and the capability ceiling are global-`setf`, not
  turn-`let`-bound; the event log is already locked (`*event-lock*`,
  `src/observe/events.lisp:134`). The turn worker prints all ⚙ lines up
  front, joins, then does ring-record + ↳ echoes + `tool-result-message`s
  **in original call order** — D-1 untouched; the turn worker remains the
  sole transcript writer.
- **Cancellation**: the join loop polls `cancel-requested`; on cancel it
  stops waiting and synthesizes cancelled results for unfinished calls
  (`repair-dangling-tool-calls` already covers the escalated-interrupt
  case). Orphaned workers are harmless *by construction* — read-only caps
  mean they can only waste CPU.
- One static sentence in the coder system prompt (cache-safe): read-only
  tools issued in one batch run concurrently — encourage batching.

**Tests**: order preservation; a concurrency proof via two 300 ms sleeping
read-caps fixture tools (batch elapsed < sum); mixed batch
`(read read shell read)` splits `[parallel][serial][serial]`; cancel
mid-join synthesizes results for every id; probation tool forces serial.

### M10-2 · Bedrock ConverseStream (M, ~1–2 days)

New `src/llm/eventstream.lisp`: AWS eventstream binary framing decoder —
`[u32 total][u32 headers-len][u32 prelude-crc][headers][payload][u32 crc]`,
big-endian; headers are `(u8 name-len)(name)(u8 type=7)(u16 len)(value)`.
CRC validation optional in v1 (length-framed reads are self-consistent).
Feed it from dexador `:want-stream t :force-binary t` (binary de-chunking is
dexador's job; the vertex path already trusts `:want-stream` in character
mode). Map events onto the existing block model: `contentBlockDelta`
`{delta:{text}}` → `:delta`; `toolUse` start + input deltas accumulate
args-json; `messageStop` → stop reason; `metadata` → the usage plist.
`converse-stream` endpoint in `src/llm/bedrock.lisp`; **automatic fallback**
to the non-streaming `converse` call (one retry) on any decode failure — a
broken stream must never lose a turn. Honor `stream-deadline-seconds`
(F-llmwedge) on this path too.

**Tests**: pure decoder over hand-built octet vectors — single frame, frame
split across reads, toolUse delta accumulation, metadata usage — no network.

### M10-3 · Prompt caching v1 — Claude first (S)

- Bedrock: `cachePoint` blocks after the system text and as the final entry
  of `toolConfig.tools` — **tools+system only in v1**. A sliding
  conversation cache point is deliberately deferred until after M11:
  compaction rewrites history and would thrash it.
- Parse `cacheReadInputTokens`/`cacheWriteInputTokens` into the usage plist
  (feeds M11's honest cost meter).
- Gemini: no code — implicit caching wants a stable prefix, which
  `compose-system-prompt` (`src/agent.lisp:158`) already is (verified
  byte-stable: a `format` over generation id, genome dir, workspace, sorted
  tool names). Pin the rule with a comment: **no volatile state (jobs,
  context %, tickers) ever enters the system prompt** — per-turn state rides
  the message tail (M9-4's pattern).

**Tests**: pure serialization — cachePoint placement in the request JSON;
usage plist round-trip.

### M10-4 · Step cap honesty knob (S)

Keep 25 as the default; add `OURRO_MAX_TOOL_STEPS` env override on
`*max-tool-iterations*` (`src/agent.lisp:391`). No auto-continue —
F-turncap's explicit "say continue" is the honest behavior. Budget-based
capping belongs with M11's token accounting if ever.

### M10-5 · `lisp_eval` — the compiler-backed scratchpad (M)

New `src/tools/scratchpad.lisp`, registered as a **trusted base tool** next
to `list_genes` (`src/agent.lisp:735ff`) — deliberately *not* a new `:eval`
capability: `+all-capabilities+` stays closed (the set is load-bearing for
the verifier structure check, walker, and evolution manual). Promote a real
capability only if genes should ever wrap it.

- Persistent `OURRO-SCRATCH` package (`:use OURRO.API`) — definitions survive
  across calls within a session; the model can build up helpers.
- Pipeline per call: `safe-read-form` (locked readtable, `*read-eval*` nil)
  → walker lint with granted caps `(:filesystem-read :observe)` — `random`,
  `eval`, kernel symbols all rejected exactly as for genes → `eval` under
  `(with-capabilities '(:filesystem-read :observe))` + `sb-ext:with-timeout
  10` + output capture + `clamp-output`.
- Install `(tool-output n)` in the scratch package: returns the full text of
  ring entry *n* (`agent-tool-results`) — the "filter a 30 KB log in-image"
  accessor. Document in the tool description with one worked example.

**Tests**: arithmetic; a `defun` persists across calls; `(cap/write-file …)`
⇒ clean capability-violation string; walker rejects `eval`/`random`;
infinite loop ⇒ watchdog timeout string; `tool-output` round-trip against a
populated ring.

**M10 verification (live, Bedrock)**: `OURRO_MODEL=sonnet-4-6 make dev` —
answers stream token-by-token; second turn's `:llm-call` event shows
`cache-read-tokens > 0`; "read these 4 files" issues one batch and
wall-time ≈ the slowest read; "use lisp_eval to count FIXMEs in tool output
3" works without re-reading the file.

---

## M11 — "The context engine" (M, ~4–6 days)

New: `src/context.lisp` (or a section in agent.lisp if it stays small),
`seed-genome/genes/ui/context-hud.gene`, `tests/context-test.lisp`.
Modified: `src/agent.lisp` (slots `last-prompt-tokens`,
`pending-compaction`), `src/llm/bedrock.lisp` (`*model-aliases*` metadata).

### M11-1 · Token accounting + model metadata (S)

Track `:prompt-tokens` from every assistant `message-usage` in
`process-turn` (already parsed by both providers, never consumed). Extend
`*model-aliases*` entries (`src/llm/bedrock.lisp:278`, verified additive —
readers `getf` and ignore unknown keys) with `:context-window` and optional
`:pricing (:in :out :cache-read)`; `model-context-window` falls back by
shape (gemini → 1M, claude → 200k).

### M11-2 · Stage 1 — deterministic tool-result elision (M)

At the top of `process-turn`, on the turn worker (the sanctioned conversation
mutator), when last prompt > 50 % of the window: rebuild the conversation
with `:tool` message bodies older than the last 8 turns replaced by
`first line + "… [N chars elided]"` — **keeping `:tool-call-id`/`:name`** so
both serializers still emit well-formed pairs (verified against the
canonical layer, `src/llm/json.lisp:97-133`: Gemini still emits its
`functionResponse`, Converse its `toolResult`; stubs are non-empty). Never
mutate message plists in place — a handoff/checkpoint may hold them; rebuild
(D-1 discipline applied to the conversation).

### M11-3 · Stage 2 — background summarization (M)

When > 70 %: **prepare** on `ourro-turn-boundary` (`src/agent.lisp:844` —
off-UI, off-turn) — summarize the oldest half via `complete-text`, cutting
**only at a `:user` message boundary** so no assistant tool-call is ever
separated from its `:tool` replies; store `(:prefix-n n :anchor <eq-cell>
:summary s)` in `agent-pending-compaction`. **Apply** at the next
`process-turn` top iff the anchor cell is still `eq` at position n−1
(conversation is append-only between turns; a stale summary is dropped,
not spliced). The summary splices as a *user* message — satisfies Converse's
first-message-must-be-user (its adjacent-role merge,
`src/llm/bedrock.lisp:124-154`, heals adjacency) and Gemini trivially;
`thoughtSignature` provider-data lives only on kept-tail assistant blocks,
so summarized-away history needs no signature echo. Optional stretch:
persist summaries to `sessions/<id>/summary.sexp` — durable session memory
as readable S-expressions, ~0 extra cost.

### M11-4 · Context/cost HUD seed gene (S)

`ui/context-hud.gene`: `"ctx 34% · $0.42"` (omit `$` when pricing unknown;
cache-read tokens at the discounted rate — data from M10-3). Expose the
numbers via an observe-level hook fn (the `*genome-gene-count-fn*` pattern,
`src/agent.lisp:2265`) so the gene needs only `(:observe :ui)`; walker row
for the new accessor.

### M11-5 · Free wins

Handoff/checkpoint payloads shrink automatically (same list serialized) —
helps the measured 2 s restart budget; the compacted conversation is also
what crash-recovery restores.

**Tests** (`tests/context-test.lisp`): stage-1 fires on a scripted long
session with 30 KB tool results; **both** `serialize-messages` and the
Bedrock serializer produce no orphan functionCall/toolUse after compaction
(walk the JSON and assert pairing); stale-anchor summary is dropped;
post-splice first serialized message is user-role; usage plumbing + window
lookup.

**M11 verification (live/scripted)**: soak a scripted session past 70 % ⇒
`(:kind :compaction)` events appear, next-turn `:prompt-tokens` drops ≥
40 %, and the model still answers a question about pre-compaction content
(it's in the summary); HUD ticks `ctx %` as the session grows.

---

## M12 — "Invisible evolution" (M/L, ~5–7 days)

### M12-1 · Evolution queue persists (S)

Mirror `*evolution-queue*` to `state/evolution-queue.sexp` inside the
existing `*queue-lock*` (`src/observe/queue.lisp`); load at `wire-observer`.
Queued-but-unproposed patterns stop dying at every restart.

### M12-2 · Calm restart policy (S/M)

`*restart-policy*` — `:calm` (**new default**: restart only when idle ≥
300 s ∨ inside the dream-idle window ∨ at `/quit`), `:eager` (today's 10 s),
`:manual` (only `/quit` or an explicit command); `OURRO_RESTART_POLICY` + a
config override; gates the quiet-boundary check in `ui-loop`
(`src/agent.lisp:2180-2188`). Coalescing is already natural —
`agent-pending-handoff` holds only the newest built generation. **The ledger
must still advance**: `/quit` with a pending handoff sends a new supervisor
message `:make-current <id>` (the supervisor already has
`set-current-generation`; builds record `:make-current nil`,
`src/supervisor.lisp:753`) — otherwise a calm user who always quits never
boots their new generations. Decision table (`restart-allowed-p policy
idle-seconds busy-p input-empty-p dream-p`) is a pure function.

### M12-3 · Out-of-process gauntlet (M) — async-evolution option B

New `--verify-gene <file>` child mode in `src/main.lisp` (sentinel-framed
output à la `--replay`, `src/main.lisp:62-83`): run
`ourro.verify:verify-gene-text` on the file, print the verdict + stage
diagnostics. `ourro.evolve::verify-out-of-process`: write the candidate
source to a temp file, spawn via `run-command` (`src/util.lisp:200`,
timeout = stage-watchdog sum + slack) on **`(first sb-ext:*posix-argv*)`** —
the agent's own binary, exactly the current generation's vintage, no ledger
lookup. **Mined path only.** Fall back in-process when: a
`*hot-loads-since-boot*` counter > 0 (the live registry is ahead of the
image — the simplest honest staleness rule), argv[0] isn't a built image
(`make dev`), the spawn/parse fails, or the path is deliberate
`propose_gene` (the model is waiting and iterates on genes it just loaded —
staleness is *likely* there). Removes compile/test GC contention from the
live image for the background path that doesn't care about child-startup
latency.

### M12-4 · Evolver politeness (S)

A `*politeness-hook*` the agent installs (wait-while-busy, capped 30 s),
called between the evolver's propose/verify/repair stages — user turns never
contend with gene compiles even before M12-3 lands, and after it, the LLM
repair round-trips still yield to the user.

### M12-5 · Restart-loss reduction (S)

Carry through handoff `:extra`: the tool-output ring (each `:result`
truncated to 4 KB for payload sanity — `/out` history survives),
`pending-retirements`, and `*last-evolution-time*` (the 300 s evolution rate
limit currently resets to zero at every restart). Jobs already ride
`:extra :jobs` (M9-5).

### M12-6 · `:slow-tool` miner family (S/M) — absorbs plan-m6-m8.md's M9 sketch

Group `:tool-call` events by `(tool . arg-skeleton)`; median `:elapsed-ms` >
~2000 ms with support ≥ 3 → a pattern whose benefit estimate **is the
measured median**, flowing into `set-gene-baseline` → honest HUD payback.
Prompt branch: "this call is slow for this user; propose a
caching/batching/narrowing gene." ~120 LOC in `src/observe/miner.lisp` +
miner tests. Efficiency itself becomes a mined pattern family — the purest
"adapts to *your* workflow" upgrade, and the bridge between this plan's
hand-built optimizations and evolved ones.

**Tests**: queue survives a simulated restart; the `restart-allowed-p`
decision table; `--verify-gene` verdict *parser* + fallback logic with a
stubbed runner (the real child run joins `make verify-e2e`); staleness
counter forces in-process; slow-tool miner units (median, support, skeleton
grouping).

**M12 verification**: extend `scripts/verify-e2e.sh` with a `--verify-gene`
check against a known-good and known-bad gene. Live: trigger a mined
evolution mid-typing ⇒ no restart until 5 min of true idle (gen counter
ticks only then); `kill -9` before the calm restart loses nothing (the
genome commit exists — async-evolution.md's "nearly free" claim, now
proven); after a restart, `/out` history and the evolution rate limit
survive.

---

## Dependencies, effort, order

| Item | Effort | Depends on |
|---|---|---|
| P0-1 commit in-flight | S | — |
| P0-2 F-travel | S/M | — |
| P0-3 mined snapshots async | S | — |
| M9-1 launch-program output | S | — |
| M9-2 jobs registry | M | M9-1 |
| M9-3 jobs seed gene | S | M9-2 (API exports) |
| M9-4 chat integration | S/M | M9-2 |
| M9-5 restart survival | S | M9-2, handoff `:extra` |
| M10-1 parallel batches | M | — |
| M10-2 Bedrock streaming | M | — |
| M10-3 prompt caching v1 | S | — (sliding point: after M11) |
| M10-4 step-cap env | S | — |
| M10-5 lisp_eval | M | — |
| M11-1 token accounting | S | — |
| M11-2 stage-1 elision | M | M11-1 |
| M11-3 stage-2 summarize | M | M11-2 |
| M11-4 context HUD | S | M11-1 (M10-3 for `$`) |
| M12-1 queue persistence | S | — (any-time filler) |
| M12-2 calm restarts | S/M | — |
| M12-3 child gauntlet | M | — |
| M12-4 politeness | S | — |
| M12-5 loss reduction | S | — |
| M12-6 slow-tool miner | S/M | — (any-time filler) |

Order: Phase 0 → M9 → M10 (10-1/10-4/10-5 independent of 10-2/10-3) → M11 →
M12 (12-1/12-6 are good fillers any time; 12-3 is independent of the rest).

## Cross-cutting risk register

| Interaction | Risk | Mitigation |
|---|---|---|
| parallel × probation | revert mutates global fdefinitions mid-batch | probation tools run serial (eligibility check) |
| parallel × cancel escalation | interrupt lands during join; workers orphaned | read-only-caps-only eligibility (orphans can only waste CPU); `repair-dangling-tool-calls` covers ids |
| job pid re-attach × pid reuse | dead job's pid recycled ⇒ false `:running` | store `:started` + command; liveness poller also sanity-checks `ps` comm; documented residual risk |
| job children × terminal close | SIGHUP kills the dev server | desired semantics; document in /help + SKILL |
| cachePoint × hot-load | a new tool mid-session invalidates the tools prefix | accepted (rare); cache re-warms next turn |
| compaction × handoff capture | in-place plist mutation corrupts a serialized payload | rebuild-only rule; test pins pairing on both serializers |
| compaction × Converse schema | first message must be user-role; adjacency | splice as user message; role-merge heals; test pins |
| stage-2 × concurrent turns | summary prepared against a moved conversation | eq-anchor compare-before-apply; stale summary dropped |
| eventstream × decode failure | broken stream loses a turn | automatic non-streaming `converse` fallback, one retry |
| child gauntlet × staleness | candidate needs a hot-loaded-not-imaged gene | `*hot-loads-since-boot*` > 0 ⇒ in-process; deliberate path always in-process |
| calm restarts × ledger | `/quit`-only users never advance generations | `:make-current` supervisor message on quit |
| lisp_eval × escape | eval as a walker bypass | safe-read + full walker lint + capability grant `(:filesystem-read :observe)` + 10 s watchdog + scratch package uses OURRO.API only |
| jobs/summary state × system prompt | volatile text breaks the cache prefix | hard rule: per-turn state rides the message tail, never `compose-system-prompt`; comment pins it |

## Critical files

`src/agent.lisp` (run-tool-calls, request-travel/perform-handoff, ui-loop
quiet gate, submit-message notes, slots), `src/kernel/capabilities.lisp`
(launch-program), new `src/jobs.lisp`, new `src/tools/scratchpad.lisp`, new
`src/context.lisp`, `src/llm/bedrock.lisp` (+ new `src/llm/eventstream.lisp`),
`src/llm/vertex.lisp`, `src/llm/json.lisp`, `src/evolve/engine.lisp`,
`src/observe/queue.lisp`, `src/observe/miner.lisp`, `src/supervisor.lisp`
(`:make-current`), `src/main.lisp` (`--verify-gene`, exit codes),
`src/kernel/walker.lisp`, `src/genome/genome.lisp` (OURRO.API exports), new
seed genes `tools/jobs.gene` / `ui/jobs-hud.gene` / `ui/context-hud.gene`,
new tests `jobs`/`context`/`eventstream`/`scratchpad` + extended
`supervisor`/`evolve`/`tools` suites, `scripts/verify-e2e.sh`,
`ourro.asd`, `.claude/skills/ourro/SKILL.md` (refresh on landing).

## Reused machinery (no new deps, no new state formats)

`cap/launch-program` + the walker `:subprocess` row (jobs); the overlay/pager
plumbing for `/out j<id>`; `enqueue-ui` marshaling + D-1 for every UI touch;
handoff `:extra` (additive, version-checked) for jobs/ring/clocks; the
`*genome-gene-count-fn*` observe-hook pattern for both HUD genes; the
gauntlet's safe-read + walker + `with-capabilities` stack for `lisp_eval`;
`run-command` + sentinel framing (`--replay` pattern) for `--verify-gene`;
`make-scripted-provider` for every deterministic test; `supervise :once` +
`*spawn-agent-hook*`/`*build-image-hook*`/`*snapshot-hook*` seams;
`ourro.util` atomic sexp file helpers for `state/jobs.sexp` +
`state/evolution-queue.sexp`.
