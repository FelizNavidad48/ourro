# ourro — M5–M8 Evaluation & Agent-Driven QA Plan

*Written 2026-07-13 against commit `3224af3` (fable-4-m8). Companion to
`docs/ROADMAP.md` (M0–M8 scorecard), `docs/plan-m6-m8.md` (M6–M8 plan), and
`docs/greenfield-lisp-self-evolving-agent.md` (the PRD). Line anchors verified
against the working tree at `3224af3`. **Status 2026-07-14: IMPLEMENTED** —
Part A landed (`fable-5-part-a`) and Part B QA-0…QA-4 landed (`fable-5-plan-b`);
QA-6 (compose-frame extraction) and the `:golden`/`--bless` assertion remain
deferred. How to operate the QA system: `qa/README.md`.*

*Status 2026-07-18: **partially superseded.** The Part-B scripted machinery —
T0 in-process backend, scenario-step runner/DSL, soak, task bank, and all cost
gates — was deliberately removed: QA is now live-only, mission-driven user
testing (`qa/missions/`, `qa/README.md`, `.claude/skills/qa-operator`).
The parts that survive unchanged: the QA-0 product seams (heartbeat, env
overrides, `:llm-call` events) and the `ourro-qa` tmux operator CLI.*

## Context

ourro has landed M0–M7 and the headless half of M8. This plan covers two
things:

1. **An evaluation of how well the repo actually implements M5–M8** (claimed
   done) with a fix list.
2. **The next major feature: automated QA / user-testing by an agent** — a way
   for a coding agent (e.g. Claude Code) to *operate* ourro like a real
   user: run workflows by prompting it (not by coding itself), evaluate
   performance, spot logic and visual bugs, report findings, and run overnight
   soak sessions — on cheap models, since credits are finite.

Decisions taken during planning (asked & answered):

- **QA must not interfere with the product** (dev-only, invisible to users);
  the driven **experience must match what a real human sees**; it must **not be
  flaky** for an agent operator. → Architecture: **tmux-driven real-terminal
  input + file-based synchronization**; *no* in-image driver socket; only tiny
  user-invisible observability seams in the product.
- Live QA model: **gemini-2.5-flash** (scripted-provider runs are the zero-cost
  regression backbone).
- Overnight: **autonomous Lisp soak runner**; Claude reviews reports in the
  morning.

---

# Part A — M5–M8 evaluation (verified against code, not docs)

| Milestone | Verdict |
|---|---|
| M5 (rebuild-on-demand, determinism gate, restart budget) | ✅ Genuinely implemented, wired, tested — docs accurate |
| M6 (hygiene, D1/D2 fixes, D3–D5 docs) | ✅ Confirmed, incl. substantive wiring tests |
| M7 (cancel, wcwidth, HUD gene, mouse/scroll, pager, streaming md, help) | ✅ All seven confirmed with dedicated suites |
| M8 | ◑ Headless half real (19 checks, `scripts/verify-e2e.sh`); **live-Gemini half never executed** — runbook only |

Key evidence: `rebuild-generation-image`/`ensure-generation-image`
(src/supervisor.lisp:545–592, detached worktrees + per-gen tags + build-lock);
6th gauntlet stage `run-determinism-probes` (src/verify/verifier.lisp:214–279)
with `random` walker-forbidden (src/kernel/walker.lisp:82); restart budget
measured at `:hello` (supervisor.lisp:765–783); `turn-cancelled` non-error
serious-condition + `repair-dangling-tool-calls` (src/kernel/conditions.lisp:147,
agent.lisp:486–507); wcwidth range vectors (src/tui/render.lisp:67–137); HUD
seed gene + `utility-summary` (ledger.lisp:131–155).

## Findings to fix

| # | Sev | Finding | Where |
|---|---|---|---|
| F-1 | **P1** | **Event persistence dies after the first restart.** `wire-observer` calls `start-event-log` only when `agent-session-id` is nil; a resumed/crash-recovered session has it set, so `*event-log-path*` (defvar nil, set only in `start-event-log`) stays nil → `log-event` stops appending to `events.sexp` for the rest of the session. PR-1 silently broken post-handoff. Fix: on the resume path call `(start-event-log :session-id (agent-session-id agent))` (the `&key session-id` param exists for this, events.lisp:85); the re-logged `:session-start` becomes a useful restart marker. | agent.lisp:2026–2030, events.lisp:68,85 |
| F-2 | High (honesty) | README claims "verified against the real Vertex AI Gemini 3.1 Pro" + specific live results — contradicts its own body, ROADMAP:847, plan-m6-m8.md:395; **no live shoot is recorded in the repo** | README.md:20–21, 67–72 |
| F-3 | Med | `verify-e2e` check [3] uses `--force`; base-core *staleness detection* never exercised | scripts/verify-e2e.sh:78–93 |
| F-4 | Med | `verify-e2e` check [4] proves replay *trace emission*, not the *divergence gate* (no negative test: two diverging images → build must fail) | scripts/verify-e2e.sh:97–105 |
| F-5 | Med | Supervisor `protocol-serve` thread death swallowed by `(error () nil)` — heartbeat/build processing stops with no log line | src/supervisor.lisp:861–875 |
| F-6 | Low | `:propose-generation` reply send under bare `ignore-errors` — agent waits forever on a lost `:generation-built`, untraced | src/supervisor.lisp:817 |
| F-7 | Low | `find-bootable-generation` never status-checks `preferred` (latent: a quarantined record with a present image would boot) | src/supervisor.lisp:612 |
| F-8 | Low | **Model id hardcoded** `"gemini-3.1-pro-preview"`, no env/config override — blocks cheap-model QA (fixed by QA-0) | vertex.lisp:111; main.lisp:31; scripts/dev-run.lisp:22 |
| F-9 | Info | Docs reference never-created `scripts/e2e-m2.exp`, `scripts/demo-scripted.lisp`; `make e2e-live` is echo-only (easily misread as a test) | ROADMAP:930–931, Makefile |
| F-10 | Info | Accepted D4 `restart-timer` race (measurement-only); gauntlet probe 5× vs demo tool 10× (cosmetic) | supervisor.lisp:716–773 |

## Next steps beyond fixes

- The **M8 live shoot** becomes the QA system's first customer: the six PRD §12
  beats become scenarios the operator runs (one pass on the pro model to close
  M8 honestly; recurring passes on flash).
- **M9 (`:slow-tool` latency miner)** stays next-cycle as sketched in
  plan-m6-m8.md — QA-0's `:llm-call`/latency observability feeds it directly.

---

# Part B — Agent-driven QA / user-testing system

## B.0 Architecture: three tiers, one scenario DSL, zero QA code in the image

| Tier | Input | Screen truth | Provider | Cost | Use |
|---|---|---|---|---|---|
| **T0 in-process** | direct calls (`make-agent` + `submit-message` — the existing test idiom) | `transcript-lines` | scripted | free | fast logic regression, `make qa-test` |
| **T1 tmux + scripted binary** | `tmux send-keys` into real `bin/ourro run` | `tmux capture-pane` grid | `OURRO_PROVIDER=scripted:<file>` | free | full-fidelity deterministic: real key decoding, rendering, handoffs, chaos |
| **T2 tmux + live** | same | same | `OURRO_MODEL=gemini-2.5-flash` | cheap | evolution scenarios, task bank, overnight soak |

Why tmux beats an in-image driver socket (validated against source):

- The front buffer (`screen-previous`, render.lisp:41) holds fully-rendered
  ANSI strings mutated on the UI thread — a structured cross-thread dump would
  need a paint-frame refactor + QA code in the image. `capture-pane` returns
  the **post-emulation grid** — literally what a human sees — for free.
- `send-keys` feeds real bytes through `open-tty`/`read-key`
  (term.lisp:56/203), exercising the true decode path (F2 = `ESC O Q` → `:f2`).
- Keystrokes wake `ui-loop`'s `wait-input` instantly; socket-marshaled ops
  would have had up to 250 ms wake latency.
- Anti-flake comes from **file-based sync** (below), never sleeps or scraping.

## B.1 QA-0 — Product seams (the *only* product changes; each with FiveAM tests)

1. **Env config overrides** in `make-vertex-provider` (vertex.lisp:110):
   `OURRO_MODEL` (default stays `gemini-3.1-pro-preview`), `OURRO_THINKING_LEVEL`,
   `OURRO_MAX_TOKENS`. No `boot` change needed — env inherits through
   `spawn-agent` (uiop:launch-program, no `:environment` override), so a var
   set before `make run` reaches every generation.
2. **Scripted provider in a real binary**: `OURRO_PROVIDER=scripted:<path>` —
   new `make-scripted-provider-from-file` (safe-read the file; responses are
   strings or `(:text … :tool-calls ((:id … :name … :args-json …)…))` plists
   fed through the existing `assistant-message` constructors; optional leading
   `(:loop t)` recycles for soak). `boot` (main.lisp:31) gets a
   `provider-from-env` dispatch. Deterministic scenarios open with `/freeze`
   so the evolver can't consume scripted responses.
3. **`:llm-call` events** (perf + cost meter): capture `usageMetadata` in the
   SSE chunk lambda (vertex.lisp:376–401 — currently only `"candidates"` is
   read; keep the last chunk's cumulative counts), attach `:usage` to the
   returned message; new hook `ourro.llm:*llm-call-hook*` fired from an
   `:around` method on `complete` (`provider` base class) with
   `(model elapsed-ms usage error-p)` — covers agent turns, evolver,
   onboarding; zero behavior when unset. `wire-observer` installs it →
   `(log-event :llm-call :model … :elapsed-ms … :usage … :outcome …)`.
4. **`:turn-done` event**: first form of the `"ourro-turn-boundary"` worker in
   `on-turn-done` (agent.lisp:820) — pairs with `:user-message` for turn
   latency metrics. (Not the sync primitive: slash commands never reach
   `on-turn-done`.)
5. **F-1 fix** (event-log continuity across restarts) — prerequisite for the
   harness's event tailing; test: resumed wiring appends to the same file.
6. **`state/qa-status.sexp` heartbeat, gated by `OURRO_QA=1`** (~35 lines):
   `write-qa-status` called from `ui-loop` before paint (UI thread → reads
   view state locklessly; `pending-submissions` under its lock). Atomic write
   via **`sb-posix:rename`** (never `cl:rename-file`). Throttled: write on
   field change or ≥1 s. Payload:
   `(:version 1 :pid :generation :session-id :busy :queue :activity :ticker
   :overlay :input-empty :pending-handoff :updated :tick)` — the monotonic
   `:tick` doubles as a **UI-loop-wedge detector**. Rationale for having it at
   all: events alone can't express busy-during-`/onboard`, queue depth,
   overlay state, or ticker text, and a fixed-path pollable file needs no
   parsing of a growing log. Users never see it (env-gated, dev-only).

Effort: **M (~1 day)**. Everything else depends on this.

## B.2 QA-1 — Operator library + CLI (`ourro/qa` system)

New `qa/` tree + `ourro/qa` ASDF system (depends on `ourro` only for
the T0 backend; `operator.lisp` also loads standalone for the CLI):

```
qa/src/operator.lisp   ; OURRO.QA.OPERATOR — tmux + file surfaces only
qa/src/report.lisp     ; OURRO.QA.REPORT — evidence + report writers
qa/src/runner.lisp     ; OURRO.QA.RUNNER — scenario DSL executor (B.3)
qa/src/soak.lisp       ; OURRO.QA.SOAK (B.5)
qa/bin/ourro-qa         ; sh shim → sbcl --script qa/bin/ourro-qa.lisp (~0.3s, no ASDF)
```

Operator vocabulary — each a Lisp function *and* a CLI subcommand (sexp
stdout, exit 0/1) so Claude Code drives everything from Bash:

- **`spawn`** — sandbox `OURRO_HOME=/tmp/ourro-qa/<ts>/home` (single-instance
  pid lock satisfied by construction); `bin/ourro init` once per sandbox; then
  `tmux new-session -d -s ourro-qa-<ts> -x 100 -y 31 -e OURRO_HOME=… -e OURRO_QA=1
  [-e OURRO_MODEL=… | -e OURRO_PROVIDER=scripted:…] './bin/ourro run'` (or
  `make dev`); `set status off` (don't steal a grid row), `set remain-on-exit
  on` (a crashed pane stays capturable — crash output is evidence). Writes
  `qa-session.sexp` (session name, home, tier, model) so later subcommands
  need only `--session`/newest.
- **`say TEXT`** — short lines: `send-keys -l -- 'TEXT'` + `Enter`; multiline
  or >200 chars: `load-buffer` + `paste-buffer -p` (bracketed paste — the real
  product path, term.lisp:359, never auto-submits) + `Enter`. CLI encodes the
  gotchas (no trailing `\` — line continuation, agent.lisp:1703).
- **`key NAME…`** — `send-keys F2 | C-o | Escape | C-c | Up …` (real terminfo
  bytes → real decoder).
- **`screen [--ansi] [--row N]`** — `capture-pane -p` (plain) / `-e` (SGR for
  style assertions + evidence).
- **`state`** — prints `qa-status.sexp` + derived `:fresh-p :stale-seconds`.
- **`await-idle [--timeout 120]`** — status fresh (≤3 s) ∧ `:busy` nil ∧
  `:queue` 0, then the **stable-frame protocol**: capture → 400 ms (> the
  250 ms idle paint tick) → capture → equal, ≤5 attempts. Also
  **`await-quiescent`** (+ `:activity` nil — evolver/dream done),
  **`await-generation-change [--from gen-NNNN]`** (poll same path until `:pid`
  differs ∧ `:tick` advances ∧ `:generation` changed; status staleness for the
  ~2 s respawn window is expected, 20 s escalation deadline; corroborated by
  the re-logged `:session-start` and supervisor.log "session restored in"),
  **`await-event KIND [--match plist]`** (tail `sessions/<id>/events.sexp`
  from a cached line offset, torn-final-line tolerant).
- **`events [--since-offset N] [--kind K]`** — offset-tracked event tail.
- **`chaos kill-agent|kill-supervisor|sleep-idle N`** — SIGKILL the `:pid`
  from qa-status / quiet windows for dream & deferred handoffs (a deferred
  handoff needs >10 s key silence + empty input, ui-loop step 5 — so
  scenarios must not type while awaiting a restart; encoded in the skill).
- **`collect [--label X]`** — snapshot evidence into
  `qa/reports/<run>/evidence/`: plain + ANSI screens, qa-status, log tails,
  full `events.sexp`, `ledger.sexp`, `utility.sexp`, `evolutions.sexp`.
- **`kill [--keep-home]`** — `tmux kill-session`, sweep sandbox.

Effort: **M (1.5–2 days)**, depends on QA-0.

## B.3 QA-2 — Scenario runner, DSL, assertions, reports

**DSL** (`qa/scenarios/*.sexp`, kernel safe-read, no eval):

```lisp
(scenario NAME
  :backend (:in-process | :tmux)
  :tier (:scripted | :live)          ; :live requires --allow-live, refuses *-pro* models
  :command (:run | :dev)             ; default :run
  :script FILE-or-inline             ; scripted responses
  :size (100 30) :timeout 300 :tags (…)
  :steps (STEP…))

STEP := (:say TEXT) | (:key K…) | (:paste TEXT)
      | (:await-idle …) | (:await-quiescent …) | (:await-event KIND …)
      | (:await-generation-change …) | (:sleep-idle SECONDS)
      | (:chaos :kill-agent|:kill-supervisor)
      | (:assert ASSERTION…) | (:note TEXT)
```

**Assertion vocabulary** (source of truth per tier):

| Assertion | Semantics |
|---|---|
| `(:screen-contains RX)` / `(:screen-lacks RX)` / `(:screen-row N RX)` | cl-ppcre over the capture-pane grid (T0: over transcript plain text); row 0 canonical header check `"ourro · gen-"` |
| `(:screen-invariants)` | exactly `height` rows; no C0 control chars; header + statusbar rows present; (T0 variant measures `display-width` of composed rows) |
| `(:frame-stable)` | two idle captures 400 ms apart identical |
| `(:golden NAME &key mask)` | grid vs `qa/golden/NAME.txt` after default masks (ISO timestamps, `gen-\d{4}`, session ids, durations, spinner glyphs, widget half of the status row) + scenario masks; `--bless` records |
| `(:event KIND &rest subset)` / `(:no-event KIND…)` | events.sexp match; scenario-end default deny-list `:turn-hook-error :evolver-error :dream-error :probation-revert :snapshot-failed` unless `:expect`ed |
| `(:file REL RX)` | workspace file exists + matches — task-completion proof |
| `(:gene NAME)` | genome `manifest.sexp` lists it (T0: `find-gene`) |
| `(:ledger :count>= N)` / `(:ledger :status ID :good)` | parse `ledger.sexp` |
| `(:restore-budget SECS)` | last "session restored in X.XXs" in supervisor.log ≤ SECS |
| `(:no-errors-in-logs)` | no `backtrace\|fatal\|Unhandled` in agent/supervisor logs since scenario start (offset-tracked) |
| `(:llm-calls :max N)` / `(:tokens :max N)` | count/sum `:llm-call` events — in-scenario cost guard |

**Weak-model semantics** (requirement: cheap models, failures are data):
`:optional t` on awaits sets a flag instead of failing; `:when :hot-loaded`
gates dependent asserts; the report always records the
proposal→repair→verdict funnel. A flash model failing the gauntlet is a
**measurement of the repair loop**, not scenario noise.

**Three example scenarios** (checked into `qa/scenarios/`):

A. `smoke-scripted` (T1, free): boot → assert header/gen/`:screen-invariants`/
`:frame-stable` → `/freeze` → chat turn (assert echo + `:user-message` +
`:turn-done`) → scripted `list_files` tool call (assert `:tool-call` + `[1]`
ring echo) → F2 inspector open/close → `(:golden smoke-idle)` → `/help` →
double ctrl-c quit → `(:no-errors-in-logs)`.

B. `evolve-live-flash` (T2, gemini-2.5-flash): ask it to grow `word_count`
and use it on README → `(:await-event :evolution-proposal :timeout 300)` →
optional `:evolution-hot-load` → `(:sleep-idle 15)` quiet window →
optional `(:await-generation-change)` → conditional
`(:restore-budget 2)` / `(:gene "word_count")` → hard caps
`(:llm-calls :max 40) (:tokens :max 400000)`.

C. `chaos-crash-resume` (T1, free): `(:loop t)` script → chat "remember token
ZEBRA-42" → `(:chaos :kill-agent)` → assert recovery ticker +
`(:restore-budget 2)` + ZEBRA-42 in restored scrollback → another turn →
assert `:turn-done` still persists (proves the F-1 fix) → second kill →
recover again → `(:screen-invariants) (:no-errors-in-logs)`.

**Runner + reports**: every step timed; on failure auto-`collect`, abort per
`:abort-on-failure` (default). Outputs `qa/reports/<ts>/report.sexp`
(per-scenario status, per-step ms, metrics: llm-calls/tokens/turn-latencies/
restore-seconds/gauntlet funnel, failures with evidence paths) + `REPORT.md`
digest + `evidence/`. **Findings** live in `qa/findings/<id>.sexp`:
`(:id :found :severity (:p1|:p2|:p3) :area (:tui|:evolution|:supervisor|:tools|:perf)
:title :repro (:scenario :step) :expected :actual :evidence :status)` — this
is the "report to the main agent" contract: Claude triages `qa/findings/` +
`REPORT.md`.

**Make targets**: `qa-test` (T0+T1, free), `qa-run SCENARIO=… [ALLOW_LIVE=1]`,
`qa-soak HOURS=8 BUDGET_CALLS=500 BUDGET_TOKENS=5000000`, `qa-clean` (kill
`ourro-qa-*` tmux sessions, sweep `/tmp/ourro-qa`, rotate reports).

Effort: **L (2.5–3 days)**, depends on QA-1.

## B.4 QA-3 — Task bank + qa-operator skill (Claude as the user)

- `qa/tasks/*.sexp` — same DSL + `:goal` prose; success criteria dominated by
  machine-checkable `(:file …) (:gene …) (:event :tool-call …)`. Seed set
  (~8): fix-a-failing-test in `qa/fixtures/tinyrepo/` (checked in), grow-a-
  tool-and-use-it, `/onboard` a fixture repo, multi-file refactor, summarize-
  a-file, deliberate correction ("no, use make test not pytest" → assert
  `:correction` event), long-output scroll, `/travel` there-and-back.
- `.claude/skills/qa-operator/SKILL.md` — teaches Claude Code the loop:
  sandbox first (`ourro-qa spawn`, never `~/.ourro`); one action → one
  await → one observe; judge against task criteria + standing invariants;
  exploratory testing guidance (probe edges: cancel mid-stream, paste
  multiline, resize, rapid typeahead); write findings in the findings format;
  `collect` before `kill`; live tier only on flash; cost telemetry from
  `:llm-call` events; the no-typing-during-handoff-wait gotcha.

Effort: **M (1 day)**, depends on QA-2. Claude can start operating here.

## B.5 QA-4 — Overnight autonomous soak

`qa/src/soak.lisp` + `make qa-soak` (no Claude in the loop overnight):

- Loop: weighted-random scenario/task from `qa/soak.sexp` config; fresh or
  reused sandbox; run → collect → score. Interleaved chaos: `kill-agent` at
  random in-turn moments; 90–180 s idle windows (dream mode mines — assert
  staged-not-applied + `:no-event :dream-error`); `/travel` churn to a random
  good gen and back; rare `kill-supervisor` + relaunch.
- **Budgets enforced every iteration**: wall clock (HOURS), LLM calls + token
  sum from `:llm-call` events across the sandbox's session files, disk cap
  (`du`), consecutive-failure circuit breaker (3 → stop, preserve all).
- Heartbeat `qa/reports/<run>/soak-status.sexp` (atomic, per iteration);
  failure snapshots copy the entire sandbox `$OURRO_HOME` (a complete repro
  world). Morning `REPORT.md`: pass/fail matrix, evolution funnel
  (proposed→verified→hot-loaded→survived-probation→retired), restore-latency
  distribution vs the 2 s budget, spend, top recurring log errors.

Effort: **M (1–1.5 days)**, depends on QA-2.

## B.6 QA-5 — Fixes milestone (Part A findings; independent, land anytime)

1. F-1 event-log continuity (in QA-0, listed here for completeness).
2. F-2 README honesty: reword the live-verification claims until the shoot
   runs; point at QA T2 reports as the ongoing evidence mechanism.
3. F-3/F-4 verify-e2e hardening: real staleness check (touch → rebuild without
   `--force`); replay-divergence negative gate (candidate whose read-only tool
   output differs → build must fail via `compare-traces`).
4. F-5/F-6/F-7 supervisor: log `protocol-serve` thread death before it dies;
   log lost `:generation-built` replies; status-check `preferred` in
   `find-bootable-generation`.
5. F-9 docs: drop `e2e-m2.exp`/`demo-scripted.lisp` references → point at
   `qa/`; note `make e2e-live` is a runbook pointer.

Effort: **S/M (0.5–1 day)**.

## B.7 QA-6 (optional) — `compose-frame` extraction

Split `paint-frame` (components.lisp:629) into pure `compose-frame view screen
→ (values lines cursor-row cursor-col)` + the tty-touching `render-lines`
call, giving T0 full-frame layout assertions headlessly. **S (0.5 day)**,
nice-to-have — tmux tiers already own visual truth.

---

# Files, order, risks

**New**: `qa/src/{operator,report,runner,soak}.lisp`, `qa/bin/ourro-qa{,.lisp}`,
`qa/scenarios/*.sexp` (3 seed), `qa/tasks/*.sexp` (~8), `qa/fixtures/tinyrepo/`,
`qa/golden/`, `qa/soak.sexp`, `.claude/skills/qa-operator/SKILL.md`,
`tests/qa-seams-test.lisp`, `tests/qa-runner-test.lisp`.
**Changed**: `src/llm/vertex.lisp` (env overrides, usageMetadata, scripted-
from-file, `complete` :around hook), `src/main.lisp` (provider-from-env),
`src/agent.lisp` (`:turn-done`, F-1 fix, hook install, qa-status writer),
`ourro.asd` (`ourro/qa` + tests), `Makefile` (4 targets),
`scripts/verify-e2e.sh`, `src/supervisor.lisp` (F-5/6/7), `README.md`,
`docs/ROADMAP.md`.

**Order** (one engineer, ~7.5–9.5 days):
QA-0 (M) → QA-1 (M) → QA-2 (L) → QA-3 (M) + QA-4 (M); QA-5 (S/M) independent;
QA-6 (S) optional.

**Risks & mitigations**

- *tmux availability/version*: require ≥3.0 at spawn (`tmux -V`), actionable
  error; unique `ourro-qa-<ts>` sessions + `qa-clean` prevent zombies.
- *capture vs paint throttle*: correctness asserts only after status-idle +
  stable-frame protocol (400 ms > 250 ms idle tick; spinner rows masked in
  goldens — busy paints mutate every 90 ms).
- *send-keys nuances*: `-l --` literals; multiline via bracketed paste
  (product-supported); no trailing `\`.
- *Flaky LLM / weak-model failures*: `:optional`/`:when` branches; machinery
  invariants always asserted; funnel metrics make failure a measurement;
  `complete-with-retry` absorbs 429/5xx.
- *Handoff windows*: status staleness expected ~2 s, awaits poll through with
  20 s escalation; positive markers (`:session-start`, supervisor.log line).
- *Runaway cost*: live tier behind `--allow-live`, refuses `*-pro*`;
  per-scenario `:llm-calls`/`:tokens` caps; soak budgets from `:llm-call`
  events; scripted default everywhere.
- *Disk*: per-run sandboxes in `/tmp/ourro-qa`, soak `du` cap, `prune-images`
  bounds images, report rotation.
- *Silent wedge*: qa-status monotonic `:tick` = liveness probe;
  `remain-on-exit` keeps crash output capturable.

# Verification

1. **QA-0**: `make test` green (new checks in vertex/events/handoff suites:
   env overrides, usage capture, `:turn-done`, resumed-session event
   continuity, qa-status payload) + `make smoke`.
2. **QA-1/2**: `make qa-test` runs the 3 seed scenarios green and free
   (T0 + T1 scripted); deliberately break a golden → run fails with evidence;
   `chaos-crash-resume` proves kill -9 recovery + the F-1 fix end-to-end.
3. **QA-3**: from a fresh Claude Code session, follow the qa-operator skill:
   spawn sandbox, run one task-bank task live on flash, produce a finding file
   + report — the full operator loop demonstrated.
4. **QA-4**: `make qa-soak HOURS=1 BUDGET_CALLS=50` (short soak) completes
   within budgets, emits heartbeats, and its `REPORT.md` shows the funnel.
5. **QA-5**: `make verify-e2e` (now with staleness + divergence checks) green;
   README no longer claims unproven live verification.
6. **Payoff**: run the six PRD §12 live-shoot beats as scenarios on flash;
   one curated pass on the pro model to close M8's honesty notes.
