---
name: ourro
description: Working on the ourro self-evolving Lisp agent — build/test/run workflow, architecture map, and hard-won gotchas. Read before touching src/ or tests/, writing genes, or debugging the TUI/supervisor.
---

# Working in the ourro repo

A self-evolving Common Lisp (SBCL) agent: a supervisor (`bin/ourro`) owns a
git-backed generation ledger and builds each generation as an executable image;
the agent image observes tool use, mines patterns, asks the LLM (Vertex Gemini or Bedrock Claude)
for `defgene` S-expressions, verifies them through a **6-stage gauntlet**,
hot-loads them live, and restarts seamlessly into snapshots.

Tracked docs: `README.md` (product + configuration), `AGENTS.md`,
`CONTRIBUTING.md`, `qa/README.md`. `docs/` is a gitignored local scratch
area for plans and notes — read it when present, never commit it.

## Commands

| Command | What it does |
|---|---|
| `make test` | Full FiveAM suite (`ourro.tests::run-all-tests`); 28 suites. Check count drifts run-to-run (persisted temp state) — the invariant is **0 failures**, not a fixed number. |
| `make dev` | Agent **from source**, no supervisor — fast loop; hot-load works, snapshots/restarts don't |
| `make build && ./bin/ourro` | Full supervised loop. `make build` is a **clean slate** (passes `ourro init --force`: fresh base.core + image AND genome re-seeded from seed-genome/). To rebuild keeping the evolved genome/ledger: `./bin/ourro init --source-dir . --rebuild`. Reuse an existing image with plain `./bin/ourro`. Scratch home: prefix with `OURRO_HOME=/tmp/oh`. |
| `make smoke` | Load source + compile genome + boot check, no TUI (prints `OURRO.KERNEL locked: NIL` from source, `T` in a built image) |
| `make verify-e2e` | Headless M8 end-to-end: real `make build` + kernel-path proof (selftest, `OURRO.KERNEL` lock, rebuild, `--replay`); no LLM. |
| `make supervisor` | Rebuild just `bin/ourro` (internal; implied by build/install) |

Single suite: load `ourro/tests`, then `(fiveam:run! 'ourro.tests::<suite>)`.

**Config vs env (M20):** env vars are for **secrets + model choice ONLY** —
`OURRO_BEDROCK_API_KEY` / `AWS_BEARER_TOKEN_BEDROCK` (Bedrock, default provider),
`OURRO_VERTEX_API_KEY` (Vertex, de-emphasized), and `OURRO_MODEL` (a friendly
alias — `opus-4-6`/`sonnet-4-6` → Bedrock, `gemini-*` → Vertex; unset →
`:default-model`, opus-4-6). Everything else is `$OURRO_HOME/config.sexp`'s
`:settings` plist, read via `ourro.config:setting` (`src/config.lisp`):
`:thinking-level :max-tokens :max-stream-seconds :max-tool-steps :restart-policy
:experimental-reflexes :default-model :bedrock-region`
(always `eu-north-1`) `:retry-max-attempts :retry-backoff-cap`. `ourro init` seeds
the template and preserves edits. Tests/QA pin values with
`ourro.config:with-settings`; the suite reads no file (hermetic). `OURRO_HOME`
defaults to `~/.ourro/`.

## Architecture map (one line per file)

- `src/agent.lisp` — conductor: session state, model→tool turn loop, TUI runloop
  (`ui-loop`), slash commands, deliberate-evolution tools (`propose_gene` …),
  dream mode, handoff/restore.
- `src/supervisor.lisp` — fixed point: ledger, git genome store, child-SBCL image
  builder, heartbeat monitor, crash-loop quarantine/rollback. Separate binary; no LLM.
- `src/verify/verifier.lisp` — the gauntlet (see gotchas). `with-staged-registries`
  is the shared isolation macro.
- `src/genome/genome.lisp` — `OURRO.API` (the *only* surface genes see), `OURRO.GENES`,
  `gene` class/registry, `defgene`, manifest load, `hot-load-gene`.
  `diff.lisp` — structural gene/genome diff.
- `src/inspector.lisp` — modal evolution overlay (view's `overlay` slot; j/k/enter/u/r/f/a/q).
  `src/pager.lisp` — tool-output pager overlay (ctrl-o / `/out`).
  `src/onboard.lisp` — `/onboard` probes a repo's toolchain → grows `repo/<role>` genes.
- `src/tools/protocol.lisp` — `INSTRUMENTED-CLASS` metaclass + `instrumented` method
  combination (un-removable observation), `deftool`, tool registry, `execute-tool-call`.
- `src/kernel/` — conditions/restarts, capability wrappers (`cap/*`), safe reader,
  code walker, revert tables + probation, socket protocol, handoff. Genes can't name it.
- `src/observe/` — event log (`log-event`), frequent-episode + `:slow-tool` miner
  (M12-6), utility ledger + context/cost summary (`ledger.lisp`), correction detectors,
  evolution queue (`queue.lisp`, mirrored to `state/evolution-queue.sexp`, M12-1).
- `src/evolve/` — self-describing prompt + propose→repair→apply; `verify-out-of-process`
  (`--verify-gene` child gauntlet, M12-3), `*politeness-hook*` (M12-4).
- `src/jobs.lisp` (`ourro.jobs`, M9) — background subprocess registry: detached jobs
  with per-job log cursors, waiter/poller threads, `state/jobs.sexp` re-attach. Genes
  reach it via `start-job`/`job-status`/`job-kill`/`jobs-summary` in `OURRO.API`.
- `src/context.lisp` (M11) — token accounting + two-stage conversation compaction
  (stage-1 tool-result elision, stage-2 eq-anchored background summarization).
- `src/scratchpad.lisp` (M10-5) — `lisp_eval`, the compiler-backed scratchpad (a
  trusted base tool: safe-read → walker → capability-bounded eval + watchdog).
- `src/tui/` — `term.lisp` (raw tty, key decoding, kitty/CSI-u, paste), `render.lisp`
  (double-buffered ANSI diff renderer), `components.lisp` (CLOS view), `markdown.lisp`.
- `src/llm/vertex.lisp` — Vertex Gemini provider (streaming SSE). `bedrock.lisp` —
  Claude on Bedrock (Converse + `eventstream.lisp` ConverseStream decoder, M10-2;
  cachePoint prompt caching, M10-3; `*model-aliases*` window/pricing). Provider is
  picked from `OURRO_MODEL`; `make-scripted-provider` for tests.
- `run-tool-calls` (`src/agent.lisp`, M10-1) runs consecutive read-only-cap tool
  calls concurrently (`parallel-eligible-p`); `restart-allowed-p`/`OURRO_RESTART_POLICY`
  (M12-2, default `:calm`) gates when a pending generation handoff fires.
- Genome ≠ src: live genes in `$OURRO_HOME/genome/` (supervisor-owned git repo);
  `seed-genome/` holds the seed manifest + `.gene` files. Images are a cache.

## Gotchas (each has bitten — trust them)

- **FiveAM**: `(is x)` needs a decomposable form; for bare values use `(is-true x)`.
- **Never intern `TOOL-IMPL/<name>`**: `deftool` uses an uninterned `make-symbol`
  for the impl fn and reuses the author's `RESULT` symbol from the `:post` forms
  (`src/tools/protocol.lisp`). Tool names like `search`/`list-files` are inherited
  `CL:` symbols (locked home package); `*package*` is unreliable under `--load`.
- **Protocol is length-prefixed** `<count>\n<payload>\n` (`src/kernel/protocol.lisp`).
  Never line-frame: gene source has literal newlines (PRIN1 doesn't escape them) →
  chopped frames → dropped connection → a healthy agent gets SIGKILLed as "hung".
- **`tui:read-key`**: `read-char-no-hang` → NIL = "no key", eof-value = `:eof`.
  Swap them and the TUI reads `:eof` on its first idle poll → flash-and-die.
- **`cl:rename-file` merges pathname types** (`gen-0001.building` stays `.building`) —
  the supervisor uses `sb-posix:rename`.
- **Nothing prints to the tty while the TUI is up**: agent stdout/stderr →
  `state/agent-output.log`, supervisor → `state/supervisor.log`; a stray note corrupts
  the renderer. Don't screen-scrape (alt screen) — assert via `sessions/<id>/events.sexp`
  + log markers, and debug by tailing those logs.
- **pty/expect tests**: `stty rows 24 columns 80 < $spawn_out(slave,name)` right after
  spawn (ptys default 0×0, the TUI clamps to 20×6).
- **Test seams**: `ourro.llm:make-scripted-provider` (deterministic LLM);
  `ourro.supervisor::*build-image-hook*` / `*spawn-agent-hook*` (stub build/spawn).
- **TUI threading**: only the active turn worker mutates the transcript (rebuild list
  + `setf`, never mutate a published list); workers → `enqueue-ui`; keys stay on the UI thread.
- **Genome entry points**: only `propose_gene` (in-session gauntlet + hot-load) and the
  supervisor's `build-generation`. Writing `.gene` files does nothing. Hand-verify with
  `(ourro.verify:verify-gene-text …)`. Grammar: `seed-genome/genes/tools/edit-file.gene`
  (`defgene` meta → `:doc` → `:code` `deftool` w/ typed args, `:contract`, `cap/*` → `:tests`).
- **Single instance**: `state/supervisor.pid` lock; kill a stuck run before re-running.
- **Build caching/artifacts**: `base.core` rebuilds on `src/` change (stale → `make clean`
  then `make build`). `bin/ourro`, `*.fasl`, `*.core` are gitignored (M6) — don't re-track;
  builds no longer dirty the tree.
- **Gauntlet is 6 stages**: safe-read → structure → walker lint → compile → staged tests
  (run twice) → determinism probe. `random`/`make-random-state` are walker-forbidden by
  symbol-name (`cl:random` too) and `random` isn't in `OURRO.API`. A gene opts in with
  `:determinism (("tool" :arg v …) …)` metadata; the probe runs each tool 5× under the
  test watchdog and the gene's *bare* caps, requiring byte-identical output.
- **Images are a cache** — never assume `images/gen-NNNN` exists (GC keeps current + 3
  newest good + quarantine parents). `ensure-generation-image`/`find-bootable-generation`
  rebuild from the genome git commit via a throwaway `state/worktrees/` worktree (pinned
  by a per-gen tag); boot/crash/travel self-heal, falling back to an older bootable gen.
- **Crash-resume is at-most-once** (M4-1): `state/checkpoint.sexp` is resumed once; if that
  boot also crashes it's renamed `-poisoned`. `booted-from-checkpoint` is cleared by the
  agent's `:checkpoint-superseded` once a recovered turn proves healthy.
- **Typeahead queues** (`pending-submissions`, drained one per `:turn-done`, survives handoff
  via `:pending`) — never spawn a second concurrent turn worker.
- **Dream mode stages, never applies**: idle mining leaves `◐ staged` candidates for the
  inspector's `a` key; it does not hot-load them. Don't "fix" it to auto-apply.
- **`handle-key` is a 4-stage pipeline**: overlay → keymap → ticker → editor. Ticker
  `e`/`u` fire only on an **empty input line**. `*keymap*`/`*commands*` are data; `bind-key`
  records a revert-action for gene bindings.
- **Staging isolates the live UI**: `with-staged-registries` dynamically rebinds
  `*active-view*`/`*status-widgets*`/`*keymap*`/`*commands*` (+ tool/gene/FiveAM registries)
  to throwaway copies. Live widget/pane mutation is serialized under `*ui-lock*`.
- **`display-width` is column-accurate (M7-2)**: `char-display-width` binary-searches two
  sorted range vectors (wide=2, zero-width=0) in render.lisp; `take-columns` never splits a
  wide char. Every fit/wrap/truncate/cursor-column site measures columns, not chars.
- **`turn-cancelled` is a non-error `serious-condition` (M7-1)** — never make it an `error`
  subtype: it must pass through generic `(error () …)` handlers to unwind a cancelled turn to
  its boundary. Cancel mid-tool-batch synthesizes a functionResponse for every remaining call
  (a dangling call 400s Gemini). `*cancel-inhibited*` guards genome mutation from the
  escalation interrupt. Esc/ctrl-c cancels a turn; ctrl-c-ctrl-c (or idle) quits.
- **Tool-output ring (M7-5)**: full results kept in a 20-entry ring (transient, never
  serialized); the ↳ echo shows `[N]`; ctrl-o / `/out [n]` opens the pager (`src/pager.lisp`).
- **Reflexes = automation genes (M13–M15, `src/automation.lisp`)**: a gene with `:automate`
  writes `(define-automation name (:on <pattern> …) body…)`; the trigger is pure data matched
  by `event-matches-p`. The dispatcher (an `*event-subscribers*` entry) ONLY matches + enqueues
  — never runs gene code inline — and one `ourro-reflex` worker executes firings under caps + a
  60 s watchdog + probation + three-strikes. **Cascade guard**: `*in-automation-context*` is a
  worker-thread special that suppresses re-dispatch of events an action logs synchronously — it
  does NOT cover an async `:job-exit` from a job the action started (bounded by `:cooldown`
  instead; the seed sentinel avoids it by using `request-investigation`, not a job). **Defer
  semantics**: `:tool-call`/`:user-message`/`:correction` triggers default to `:turn-boundary`
  (coalesced, flushed once from the turn-boundary worker); everything else is `:immediate`;
  `:idle`/`:every` fire from `tick-automations` in the ui-loop. **Timeouts** are a
  `serious-condition` — `run-firing` converts them to an `error` so probation/ledger see them.
  Test a reflex hermetically with `(fire-automation-for-test 'name <event>)` in `:tests`.
- **Two levers, don't confuse them**: `/freeze` stops NEW evolution (proposals/applies gate in
  `apply-candidate`); `/disarm` (kernel `*automations-armed*`, carried through handoff like
  `*evolution-frozen*`) stops installed reflexes FIRING. A visiting museum never installs the
  dispatcher at all.
- **Staged consent (M14)**: a MINED automation-bearing candidate stops at `:staged` (never
  hot-loads) and shows a `[y install] [n dismiss]` consent ticker — set-ticker actions are now
  `(key label command)` triples, dispatched case-sensitively by `ticker-command-for-key`; plain
  strings stay display-only. Deliberate `propose_gene` reflexes apply directly. `install-staged-candidate`
  is the shared install path (ticker `y` and inspector `a`).
- **Investigations (M15)**: `request-investigation` only ENQUEUES; the reflex worker drains it
  and runs `run-investigation` (`src/investigate.lisp`) — a headless read-only mini-turn that
  binds `*capability-ceiling*` to `(:filesystem-read :observe :llm)` so EVERY tool it calls is
  clamped (a write/subprocess call fails, like visiting). Results land in the briefings ring
  (`/out b<n>`). Background model spend is tagged via `*llm-call-context* :background` so it
  sums into session cost without double-counting the user turn.

## $OURRO_HOME layout

| Path | Contents |
|---|---|
| `config.sexp` · `ledger.sexp` | `:source-dir` + `:sbcl` + the `:settings` plist (all tunables — see Config vs env) · generation records (`:id :number :parent :commit :status :image`) |
| `base.core` | cached base image (deps + src, no genome) |
| `genome/` | git repo: `manifest.sexp` + `genes/**/*.gene` — **the truth** |
| `images/gen-NNNN` | generation images (a cache) |
| `state/` | logs, handoffs, pid, socket; plus `utility.sexp` (M1), `evolutions.sexp` (M1), `checkpoint.sexp` (M4, `-poisoned` on re-crash), `worktrees/<id>/` (M5, swept at start) |
| `sessions/<id>/events.sexp` | per-session event log (observation stream) |
| `quarantine/` | crash reports for rolled-back generations |
