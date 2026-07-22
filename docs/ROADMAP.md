# ourro — Status Evaluation & Roadmap

*Written 2026-07-12, against commit `73109a0` (~9,100 LOC). Companion to
`docs/greenfield-lisp-self-evolving-agent.md` (the PRD; "PR-N" below refers to
its numbered product requirements). M1–M5 are landed (scorecard below);
**M6–M8 are planned in `docs/plan-m6-m8.md`** (hygiene/defect-fixes/docs →
TUI cockpit → live end-to-end proof), with M6 landed as of this refresh.*

*Update 2026-07-13: `docs/plan-qa.md` Part A (M5–M8 fix list) landed, and Part B
— the **agent-driven QA system** — is now implemented (staged): QA-0 product
seams (`OURRO_MODEL/THINKING_LEVEL/MAX_TOKENS` env overrides,
`OURRO_PROVIDER=scripted:<file>`, the `:llm-call`/`:turn-done` events + cost
meter, and the `OURRO_QA=1` `qa-status` heartbeat — all dev-only, invisible to
users); the `ourro/qa` system + `qa/bin/ourro-qa` tmux operator CLI; a
scenario runner + DSL + assertions with T0 in-process and T1/T2 tmux backends
(`make qa-test`/`qa-run`); an overnight soak (`make qa-soak`); a task bank +
`.claude/skills/qa-operator`. Three seed scenarios pass end-to-end (T0 + T1 over
real tmux, including kill-9 crash recovery). See `docs/plan-qa.md`.*

*Update 2026-07-15: first live-QA feedback round landed. (1) Evolution dedup:
`ourro.miner:pattern-signature` (stable identity vs the random `:id`) + the
`attempted-pattern-signatures` memory stop `maybe-mine`/dream re-enqueuing
already-attempted patterns, and a conservative **LLM duplicate-tool gate**
(`ourro.evolve::duplicate-tool-verdict`, `:origin :mined` patterns only, fails
open, new `:duplicate` candidate status ≡ in the inspector) screens semantic
near-misses against the live tool inventory before proposal. (2) TUI: mouse
reporting now **off by default** so terminal text selection/copy works
(`/mouse` toggles wheel scroll); F-row fully unbound + reserved (ctrl-e opens
the inspector); ticker `e` opens the inspector with the newest record's detail
expanded; inspector `f` toggles freeze/unfreeze; the last frame stays on screen
through a seamless-restart gap (`ourro.tui:*keep-screen-on-exit*`) and a 30s
self-healing full repaint repairs external screen corruption (the vanishing ❯).
(3) `/onboard` detects more Makefile roles (build/all/compile, lint/check/fmt,
smoke). (4) QA harness: `pane-dead-p` aborts every `await-*` and the scenario
runner fails fast when the tmux pane dies instead of hanging. (5) `make
install` + a boot-time workspace reset make `ourro` runnable from any repo with
the shared `$OURRO_HOME` genome. Async-evolution thinking: `docs/async-evolution.md`.*

*Update 2026-07-17: the daily-driver plan (`docs/plan-daily-driver.md`) landed —
Phase 0 + M9–M12, `make test` green (1074 checks). **Phase 0:** F-travel (P1)
fixed — `request-travel` arms a pending handoff + travel flags and `perform-handoff`
returns exit 75 (a pure, unit-tested seam; `main` does the single exit), so
`/travel` no longer exits 0 into a supervisor shutdown; mined snapshots go async.
**M9 jobs:** `cap/launch-program` grows an output file, a new `ourro.jobs` registry
(`src/jobs.lisp`) runs detached subprocesses with per-job log cursors + waiter/
poller threads, `tool/jobs` + `ui/jobs-hud` seed genes, chat integration
(`/jobs`, `/out j1`, exit-notes prefixed to the next user message, exit ticker),
and restart survival (handoff `:extra :jobs` + `state/jobs.sexp` re-attach;
`/quit` reaps). **M10 efficient turn:** capability-derived parallel read-only tool
batches (`run-parallel-tool-batch`), Bedrock ConverseStream (`src/llm/eventstream.lisp`
AWS event-stream decoder + streaming assembler with non-streaming fallback),
prompt-caching v1 (Bedrock `cachePoint` on system+tools; the system prompt is
pinned byte-stable), `OURRO_MAX_TOOL_STEPS`, and `lisp_eval` — the compiler-backed
scratchpad (`src/scratchpad.lisp`, safe-read → walker → capability-bounded eval +
watchdog, with `(tool-output n)` over the ring). **M11 context engine:**
(`src/context.lisp`) token accounting + `*model-aliases*` window/pricing, stage-1
tool-result elision (>50%, keeps call/result pairing), stage-2 background
summarization (>70%, eq-anchor compare-before-apply), `ui/context-hud`. **M12
invisible evolution:** persisted evolution queue, calm restart policy
(`restart-allowed-p` + `OURRO_RESTART_POLICY` + `:make-current` on quit),
out-of-process gauntlet (`--verify-gene` child mode + `verify-out-of-process` +
staleness counter), evolver politeness, restart-loss reduction (ring/retirements/
evolution-clock ride the handoff), and the `:slow-tool` miner family. New suites:
`jobs`, `eventstream`, `parallel-tools`, `scratchpad`, `context`,
`invisible-evolution`. All changes uncommitted for review.*

*Update 2026-07-18: the Technical Review quality-control pass landed across all
15 findings (`docs/technical-review-quality-control.md`). The capability model
is now a positive Lisp/API boundary with attenuated nested grants; production
verification is an isolated, fail-closed child protocol; hot-load rollback is a
versioned CLOS transaction whose durable generation is not published before
probation graduates; background roles and parallel tool admission have explicit
ownership; handoff/control/provider/job protocols fail closed; automations and
events carry version/workspace identity; build gates use persisted kernel
content hashes; and negative QA evidence is mandatory. A checked-in macOS CI
workflow runs `make test`, `make smoke`, `make qa-test`, and `make verify-e2e`.
The implementation deliberately preserves the thesis: genes and protocols stay
readable S-expressions, rollback uses the MOP and live redefinition, and safety
is enforced by Lisp conditions plus small OS containment at the trust edge.
Final local gates: `make test` 1,324/1,324 with no warnings; `make smoke` 15
tools/13 genes; `make qa-test` 3/3 scenarios; `make verify-e2e` 29/29.*

*Update 2026-07-18 (later): **QA refocused on real-workflow value.** The
scripted/T0 tiers, scenario-step runner, soak, task bank, and every cost gate
(`--allow-live`, call/token caps, `make qa-test`/`qa-run`/`qa-soak`) were
deliberately removed — a QA run that doesn't exercise the live LLM in a real
workflow measures nothing. QA is now **live-only, mission-driven user
testing**: `qa/missions/*.sexp` (7 real-world jobs — React landing page,
Python API, data analysis with a planted anomaly, legacy-codebase rescue,
automation/integration, a Node CLI product, an interruption marathon) run as
long iterative sessions by an agent operator in persona, with autonomous
evolution *observed never staged*, the product's own commands exercised
(ticker y/n, inspector, /revert, /freeze vs /disarm, /travel), independent
out-of-pane verification, and **Claude Code as the explicit baseline** (gap
findings carry `:scale :quick-fix|:engineering`). `ourro-qa spawn` is live-only
(`--fixture` seeds the sandbox workspace; the only remaining guard is the
Bedrock boot-crash fail-fast); new fixtures `qa/fixtures/salesdata/` +
`legacy-inventory/`; `tests/qa-operator-test.lisp` lints the mission bank +
CLI arg parsing; doctrine in `.claude/skills/qa-operator/SKILL.md`, how-to in
`docs/qa-guide.md`. CI drops the scripted-scenario gate accordingly.*

*Update 2026-07-19 (Reflex OS engineering audit): the Gate 0 read-only safety
profile and M17–M22 engineering path from
`docs/technical-review-reflex-os-plan.md` are implemented. This includes the
causal journal/workspace spine, compiled reflex language and proofs, durable
runtime/effect recovery, failure briefings, demonstration/shadow/canary policy,
causal inspector, verifiable export/delete, local-control policy, and
fail-closed pilot/release evaluators. Effectful verification remains disabled
without a reviewed containment backend. Clean-home gates on Darwin arm64/SBCL
2.6.3: `make test` 2,306/2,306, `make smoke`, and `make verify-e2e` 38/38 with
no compiler warnings. See `docs/reflex-os-implementation-status.md` for exact
traceability and the three remaining non-code/release conditions: a reconciled
named Gate −1 commit and clean checkout rerun, Linux effectful containment plus
independent security review, and the real eight-week design-partner pilot.*

*Update 2026-07-21 (QA remediation): thirteen follow-up findings were fixed:
credential-token redaction is fail-closed; lifecycle threads no longer snapshot
replaceable journal indexes; `/disarm` is an immediate asynchronous kill switch;
canary budgets count matched firings only; verification children use isolated
homes; supervisor request errors stay connection-local; background tool workers
propagate causal context; journal queries and WAL hydration avoid full-history
copies/duplicate reads; investigations admit capability-safe grown tools; effect
recovery uses adapter-declared tokens; the runtime export typo and job-sentinel
gauntlet coverage are repaired. Regression coverage accompanies every safety
boundary.*

*Update 2026-07-21 (review follow-up): the durability/runtime review findings
are closed around shared boundaries. Events and the causal journal now use one
redaction policy and sanitize once; canonical files use the transaction
layer's fsync writer; WALs have per-path locks and batch append; runtime event
dispatch is enqueue-only and effect execution has one supervised path. Runtime
control/state initialization, percentile/bootstrap math, registry copies,
thread bindings, and observation admission each have one authority. Journal
retention and causal graph traversal are linear, snapshot boot avoids a second
decode, verification fingerprints are bounded/cached, and promotion/quarantine
bind exact current authority. Local gates: `make test` 2,559/2,559, `make
smoke` 15 tools/13 genes, and `make verify-e2e` 38/38.*

**North star:** a Lisp-native evolving coding agent that adapts to the user's
workflow, modifies itself, needs no restarts between generations, and has a
minimal TUI whose UX makes the evolution obvious. The USP is evolution that is
*clear, impactful, and measurably worth it* — and every mechanism below leans
on what only Common Lisp offers: live redefinition, CLOS/MOP,
`UPDATE-INSTANCE-FOR-REDEFINED-CLASS`, conditions/restarts, homoiconicity, the
in-image compiler, and the package system. Lisp is the product.

---

## Part I — Where the repo stands

### What is genuinely done

The whole loop is real and closed, verified against live Vertex Gemini:

- **Observation** — every tool call flows through the `instrumented` method
  combination woven by the `INSTRUMENTED-CLASS` metaclass
  (`src/tools/protocol.lisp:87-124`); events append one readable S-expression
  per line, flushed per event (`src/observe/events.lisp:80-94`).
- **Mining** — repeated-command (with anti-unification of argument skeletons)
  and repeated-sequence n-grams (`src/observe/miner.lisp:76-137`).
- **Propose→repair** — async evolver thread; ≤4 attempts; on each gate failure
  the *machine diagnostics* (reader error, walker verdict, full SBCL compiler
  output, failing test transcript) go back to the model
  (`src/evolve/engine.lisp:72-135`).
- **The gauntlet** — safe read (`*read-eval*` nil, locked-down readtable,
  scratch package) → structure checks → capability lint by a full-tree code
  walker → `compile-file` with every warning collected → staged tests in a
  sandboxed copy of the tool/gene/FiveAM registries under a watchdog
  (`src/verify/verifier.lisp:231-281`).
- **Hot-load + probation** — revert records for every definition a gene
  overwrites; first 3 uses under a probation handler that auto-reverts on any
  error (`src/genome/genome.lisp:472-488`, `src/kernel/revert.lisp`).
- **Generations** — supervisor builds each generation in a child SBCL
  (`compile-file` genome → smoke boot → `save-lisp-and-die`), atomic rename,
  git-backed ledger, crash-loop quarantine + rollback
  (`src/supervisor.lisp:282-331`, `582-607`).
- **Seamless restart** — exit 75 → `--resume handoff.sexp`; conversation,
  scrollback, input, and history restored (`src/agent.lisp:782-828`, `1198`).
- **Deliberate evolution** — `list_genes` / `read_gene` / `evolution_manual` /
  `propose_gene` model tools; a verified gene is callable *on the next step of
  the same conversation* (`src/agent.lisp:340-423`).
- **Dream mode** — after 120 s idle, mines and stages (but does not apply)
  up to 2 candidates (`src/agent.lisp:560-610`).
- **A solid TUI** — pure-Lisp double-buffered ANSI renderer that emits nothing
  on idle frames (`src/tui/render.lisp`), CLOS component tree with an extras
  `panes` slot (`src/tui/components.lisp:78-90`), kitty/CSI-u + modifyOtherKeys
  key decoding, bracketed paste, multiline editor with history and slash-command
  ghost completion (`src/tui/term.lisp`, `components.lisp:100-219`).

### Scorecard vs the PRD

| PR | Verdict | Evidence / gap |
|---|---|---|
| PR-1 observation | ✅ | Durable per-line event log `src/observe/events.lisp:80-94`; MOP-woven instrumentation `src/tools/protocol.lisp:87-124`. **Gap closed (M1-2):** deterministic correction detectors (`src/observe/corrections.lisp`) now emit `:correction` events from `submit-message`/`on-turn-done`, so the richest adaptation signal *is* captured. |
| PR-2 mining | ✅ (2 of 3 families) | repeated-command + repeated-sequence with anti-unification `src/observe/miner.lisp:76-137`; **`mine-corrections` is live as of M1-2** — the correction detectors feed it real input, so it is no longer dead code. Latency is still only a score multiplier, not a pattern family — the third family is the M9 `:slow-tool` sketch. |
| PR-3 code-level evolution | ✅ | Genes are S-expressions; learned behavior costs zero prompt tokens at runtime; hot-load `src/genome/genome.lisp:472-488`. |
| PR-4 gauntlet | ✅ | Five stages `src/verify/verifier.lisp:231-281`; both PRD acceptance cases hold. Minor hole: warning whitelist entry `"undefined variable: common-lisp-user::"` (verifier.lisp:101-104). |
| PR-5 seamless restart | ✅ | Works end-to-end; the arrival moment lands (M2-5). M4-2 closed two gaps: `:cwd` is restored (`restore-session`), and `:pending` typeahead is populated + survives the restart. **M5-3 measures the budget:** the supervisor times respawn→`:hello` (session restored) and logs `session restored in N.NNs (budget 2s: ok/over)` to `supervisor.log`. |
| PR-6 no self-breakage | ✅ | Probation auto-revert + crash-loop quarantine + rollback all work and are tested. **Caveat closed (M4-1):** a `kill -9` now recovers the session from `state/checkpoint.sexp` (supervisor resumes it once, poisons it if that resume also crashes) — demo scenario 2's "conversation intact" holds. |
| PR-7 holistic evolvability | ✅ | Tool evolution complete; mining is evolvable (M1-6 turn hooks); the UI half now lands (M3): `OURRO.API` exports `pane`/`add-pane`/`remove-pane`/`define-status-widget`/`bind-key` + the CLOS migration surface, behind a new `:ui` capability the walker enforces; keymaps are data (M2-3); a seed `ui/git-branch` widget is the few-shot exemplar. Broken evolved widgets/panes degrade gracefully (three-strikes revert). |
| PR-8 non-overwhelming TUI | ✅ | Ticker `e`/`u` are live (M2-3: four-stage `handle-key` pipeline, empty-input guard); `/evolutions`, `e`, and F2/ctrl-e open the modal evolution inspector with structural diff + evidence + tests + measured payback (M2-4, `src/inspector.lisp`); answers stream token-by-token then snap to markdown (M2-1/M2-2); tool results show a `↳` line. F-keys decode (SS3 + CSI). |
| PR-9 self-describing prompt | ✅ | Real live introspection: `DO-EXTERNAL-SYMBOLS` + `sb-introspect:function-lambda-list` + docstrings. **All the gaps this row once listed were closed by M1-4 (row was stale):** macros are marked `[macro]` so `deftool`/`defgene` are visible (`api-surface-description`); classes render direct slots via `sb-mop:class-direct-slots` (`class-surface-description`); `nearest-genes` scores `2×shared-tools + category + recency` (not substring); live successful-tool-call exemplars are harvested; and `*evolution-system-prompt*` is cleared on every hot-load (`*hot-load-hook*`). |
| PR-10 onboarding | ✅ | **Closed by M1-5:** `/onboard` (`src/onboard.lisp`) now *probes* the repo (Makefile/package.json/Cargo.toml/pyproject/go.mod/…, whitelisted command shapes only), runs each candidate, and drives the propose→gauntlet→hot-load loop to grow `repo/build`, `repo/test`, `repo/lint` as compiled, tested genes — not a fixed text prompt. |
| PR-11 kernel path | ✅ | Exclusion half strong (walker + `kernel-touching-p`). Hardened gate built (M4-5): a `src/kernel/selftest.lisp` FiveAM suite runs at every `--smoke` (`kernel selftest OK`); a `--replay` mode + supervisor replay gate; `sb-ext:lock-package OURRO.KERNEL` in built images; staged tests run twice; the `common-lisp-user::` whitelist entry removed. **A supervised `make init` build has run** (image rebuild → smoke selftest → replay gate → install): the smoke selftest passes, the replay gate engages and skips cleanly (a first build has nothing to replay against), and the package lock loads in the built image. (Fix landed making `run-command`'s timeout enforced so a stuck replay child can never wedge the build.) The *deeper* end-to-end proofs — `sb-ext:lock-package` actually **rejecting** a kernel mutation, and the replay gate catching a real **divergence** between two generation images — are wired + unit-tested but not yet exercised live; that live proof is scheduled for **M8** (see the M4-5 honesty note at the end of the M4 section, which this row now matches, and the softened README safety bullet). |
| PR-12 ledger & travel | ✅ | Ledger complete; `/travel` visiting + hard re-root work. M4-6 made visiting **actually read-only** (a `*capability-ceiling*` of `(:filesystem-read :llm)` intersects every grant); M4-4 added image retention/GC. **M5-1 closes the last gap:** a pruned generation is rebuilt on demand from its genome git commit (`git worktree` at the commit → `build-image` → cleanup), so `/travel` reaches any generation and boot/crash paths self-heal a missing image. The genome is truth; the image is a cache. |
| PR-13 determinism | ✅ | The execution path is LLM-free. M4-5 registered `verify_determinism` as a base tool (a demo beat). **M5-2 makes determinism enforced two ways:** `random` is removed from `OURRO.API` and walker-forbidden (no randomness primitive — a gene can't vary by chance), and a gene may declare a `:determinism` contract the gauntlet proves via a byte-identity probe (with its own watchdog) before hot-load. Not a blanket guarantee — the clock and `gensym` remain reachable by design — but the one purposeless nondeterminism source is gone and any *declared* determinism is verified. |

### The three USP gaps (why this roadmap existed)

*All three are now closed — M1–M5 landed. Kept here as the original problem
statement with pointers to where each was resolved.*

1. ~~**Evolution doesn't yet prove its value.**~~ *Closed by M1:* benefit is now
   **measured**, not estimated — the utility ledger (`src/observe/ledger.lisp`)
   records per-gene use counts and realized time saved, with auto-retirement
   (M1-1); user corrections are observed (M1-2); onboarding is a real
   probe→gene capability (M1-5); and failed candidates persist across restarts
   in `state/evolutions.sexp` (M1-3). The original estimate lived at
   miner.lisp:183-188.
2. ~~**Evolution is barely visible.**~~ *Closed by M2:* the ticker `[e]`/`[u]`
   affordances are live (M2-3); the structural-diff library
   (`src/genome/diff.lisp:50-137`) is surfaced in the evolution inspector
   (M2-4); streaming deltas render token-by-token into the transcript (M2-1);
   and generation switches announce themselves with the arrival ticker (M2-5).
3. ~~**The "agent redecorates" demo is unreachable.**~~ *Closed by M3:* a
   `:ui`-capable gene can `add-pane`, `define-status-widget`, and `bind-key`
   through `OURRO.API`; redefining a pane class migrates its live on-screen
   instance via `UPDATE-INSTANCE-FOR-REDEFINED-CLASS`. Safety rails (three
   strikes → revert + amber ticker) keep the frame from ever tearing.

Also noted: the README currently oversells streaming, the "inspector UI",
read-only travel, and the hardened path — fixed by M0's honesty pass.

### Accepted deviations from the PRD (fine as-is, documented for honesty)

- No custom reader-macro sugar (`#?(…)`, `#!shell"…"`); plain `(:contract …)`
  / `(:capabilities …)` sections work well for the LLM.
- Structural diff is a keyed tree-`EQUAL` compare, not a tree edit-script with
  `macroexpand-all` normalization. Good enough for the inspector; upgrade only
  if diff quality becomes a complaint.
- Hot-load rate limit is 300 s (engine.lisp:19) vs the PRD's 600 s, and
  deliberate `propose_gene` bypasses it (`:force t`) — deliberate evolution is
  user-intent, so bypassing is correct.
- Kernel protection is by non-export + walker rather than
  `sb-ext:lock-package` — M4-5 adds the lock in built images.

---

## Part II — Cross-cutting decisions

Decided once here; items below reference them.

**D-1 · Threading contract (write down what the code already does).**
The transcript is mutated only by the active turn worker (or the UI thread
before the loop starts); every mutation *rebuilds* the list and `setf`s the
slot (`add-transcript-line`, agent.lisp:200). Rule: never destructively mutate
a published list (no `nconc`, no `(setf (nth …))`); UI work from workers
marshals through `enqueue-ui`; key handling stays on the UI thread. Streaming
(M2-1) and the inspector (M2-4) must follow this.

**D-2 · ASDF reorder (prerequisite for M3).**
`OURRO.API` (defined in `src/genome/genome.lisp`) can only `:import-from`
packages already loaded, and the `tui` module currently loads *after*
`genome` (`ourro.asd:52-67`). Move `tui` before `tools`/`genome`:
`util → kernel → observe → llm → tui → tools → genome → verify → evolve →
agent → inspector → onboard → main`. Before moving, confirm `src/tui/*.lisp`
still depends only on `cl` / `ourro.util` / `sb-posix` / `uiop`. New files join
as `(:file "inspector")` and `(:file "onboard")` between `agent` and `main`.

**D-3 · Gene-context relocation (prerequisite for M3).**
`ourro.tools:*current-gene-context*` (src/tools/protocol.lisp:231) is how
load-time registration learns which gene owns a definition. UI registration
(M3) happens in `ourro.tui`, which will load before `ourro.tools`. Move the
`defvar` to `ourro.kernel` (src/kernel/conditions.lisp); `ourro.tools`
imports + re-exports the same symbol — zero call-site churn.

**D-4 · Persistence conventions.**
New state files are readable S-expressions via the existing
`ourro.util:write-sexp-file` / `append-sexp-line` (atomic staging built in):
`$OURRO_HOME/state/utility.sexp` (per-gene utility ledger),
`$OURRO_HOME/state/evolutions.sexp` (append-only candidate history),
`$OURRO_HOME/state/checkpoint.sexp` (crash-resume checkpoint).
All safe to delete; none is load-bearing for correctness.

---

## Part III — Milestones

Ordering (user decision): **evolution depth first**, then showcase/UX, then
TUI evolvability, then hardening. Hygiene rides along first because it is
cheap and unblocks clean diffs.

### M0 — Hygiene (S)

- `git rm --cached bin/ourro src/**/*.fasl src/**/**/*.fasl`; add `.gitignore`
  with `bin/`, `*.fasl`, `*.core`. (`bin/ourro` is an 11.5 MB committed Mach-O
  binary, currently dirty from a supervisor rebuild; `make supervisor`
  regenerates it.)
- Delete `docs/repo-aware-tasa-evolution.md` — it documents a *different,
  earlier project* ("tasa": `artifacts.lisp`, CLIM presentations — none exist
  here) and will confuse every future reader.
- README honesty pass: mark streaming, the evolution inspector, read-only
  travel, and the hardened kernel path as roadmap items (they are currently
  claimed as working); link this file.
- `CLAUDE.md` + `.claude/skills/ourro/SKILL.md` exist as of this commit.

### M1 — "Evolution earns its keep" (depth: measure, learn corrections, onboard)

**✅ Landed (all six sub-items).** `make test` green (270 checks) + `make smoke`.
New source: `src/observe/ledger.lisp`, `src/observe/corrections.lisp`,
`src/observe/queue.lisp`, `src/onboard.lisp`. New suites: `ledger-test`,
`corrections-test`, `records-test`, `onboard-test`, `queue-test`. Substrate
fix along the way: `deftool` now declares its args-var ignorable so a no-arg
gene tool (e.g. `repo/test`) clears the warning-is-error compile gate.

#### M1-1 · ✅ Utility ledger — measured benefit, not estimated (M)

*The claim "saves ~40s/cycle" must become an audited fact.*

- **New `src/observe/ledger.lisp`** (package `ourro.observe`, .asd after
  `events`): `*utility-ledger*` — `equal` hash `gene-name → plist`
  `(:uses N :errors N :reverts N :total-ms N :baseline-ms N :baseline-note S
  :frozen B :retired B :first-use T :last-use T :last-milestone N)`.
  Functions: `note-gene-use (gene elapsed-ms error-p)`, `note-gene-revert`,
  `set-gene-baseline (gene ms note)`, `gene-utility`, `gene-savings-ms`
  = `uses × max(0, baseline-ms − mean-evolved-ms)`, `save-utility-ledger` /
  `load-utility-ledger` → `state/utility.sexp` (D-4).
- **Hook — zero new instrumentation:** inside `log-event`
  (src/observe/events.lisp:80), when `kind` is `:tool-call` with a non-seed
  `:gene` (provenance `:seed` excluded), call `note-gene-use` with the event's
  `:elapsed-ms`/`:outcome`. Because the `instrumented` method combination
  weaves logging at effective-method computation
  (src/tools/protocol.lisp:110-124), **evolved tools cannot dodge
  measurement** — the metaclass is the enforcement. This is the Lisp story;
  say it in the UI copy and the README.
- **Baseline:** `make-pattern` (src/observe/miner.lisp:157) adds
  `:occurrence-cost-ms` — for `:repeated-sequence`, the summed elapsed of one
  occurrence window; for `:repeated-command`, the mean. On `apply-candidate`
  success (src/evolve/engine.lisp:174), `set-gene-baseline` from the pattern.
- **Surfacing (pre-inspector):**
  - `announce-candidate` (agent.lisp:494-498) labels the initial estimate
    `"est. saves ~Ns/use"` — honesty first.
  - `on-turn-done` (agent.lisp:428) calls new `utility-housekeeping`:
    when a gene's `gene-savings-ms` crosses 60 s / 5 min / 15 min
    (tracked via `:last-milestone`), ticker
    `"⚡ edit-and-test paid for itself: 14 uses · ≈9m saved"` (`:success`).
  - `cmd-genome` (agent.lisp:682) appends `"· 14 uses · ≈9m saved"` per gene.
- **Auto-retirement:** in `utility-housekeeping`, a non-seed, non-frozen gene
  retires when `(uses = 0 ∧ age > 7 days) ∨ (uses ≥ 4 ∧ errors > uses/2) ∨
  (reverts ≥ 2)`. Grace UX (keymap arrives in M2): ticker
  `"retiring <gene> (<reason>) · /keep <gene> to veto"`, effective at the
  *next* turn boundary; new slash command `/keep <gene>` sets `:frozen`.
  Retire = `revert-gene-definitions` if revert records exist, else
  `unregister-tool` each `:tool` from `gene-definition-names`; mark
  `:retired t`; snapshot with **manifest-remove**: extend
  `expand-changes-with-manifest` (agent.lisp:1142) and
  `updated-manifest-source` (agent.lisp:1157) to accept a
  `:manifest-remove <relative-path>` change (the `.gene` file stays on disk
  and in git history; only the manifest drops it — the genome remains truth).
- **Tests** `tests/ledger-test.lisp`: use accumulation; savings formula;
  persistence round-trip; table-driven retirement predicate; manifest-remove
  yields a manifest without the entry.
- **Verify:** `make dev`; grow a gene; use its tool 3× → `/genome` shows
  `3 uses · ≈Ns saved`; force a gene whose tool errors → after 4 uses the
  retirement ticker fires; `/keep` vetoes it.

#### M1-2 · ✅ Correction capture (M)

*"No, use pnpm not npm" is the highest-signal event the agent can observe —
and today it observes nothing.*

- **Event schema:**
  `(:kind :correction :class (<kind> <key-string>) :text "<user words ≤200>"
  :ref-tool "shell" :confidence :high|:medium)`. `:class` is readable data
  compared with `equal` by the existing `mine-corrections`
  (src/observe/miner.lisp:139, threshold 2) — which comes alive with **zero
  changes** once events exist.
- **New `src/observe/corrections.lisp`** — deterministic, in-image, no LLM in
  the loop (cl-ppcre is already a dependency):
  1. *Verbal negation* — `detect-verbal-correction (text)`: downcased first
     80 chars match
     `^(no[,.\s]|not |don'?t |do not |stop |wrong|undo|revert|actually[, ]|wait[, ]|instead)`
     or contain `use (\S+) (instead of|not) (\S+)`. Class
     `(:verbal <normalized-first-6-words>)`; the use-X-not-Y form gets the
     sharper `(:substitute "X|Y")`. Emit only when the last 10 events include
     a `:tool-call` — a correction corrects *something*.
  2. *Rework-same-file* — at turn end: this turn's `edit_file`/`write_file`
     touched a path the *previous* turn also wrote, and the turn opened with a
     negation → `(:rework-file <pathname-type>)`.
  3. *Command preference* — a `shell` call whose first word differs from the
     previous turn's `shell` first word on similar args, after a negation →
     `(:command-preference "<new-first-word>")`.
- **Wiring:** `maybe-log-correction (text)` called from `submit-message`
  (agent.lisp:252) right after `log-event :user-message`; detectors 2–3 run in
  `on-turn-done`.
- **Prompting:** `describe-pattern`'s `:correction` branch
  (src/evolve/prompt.lisp:168) quotes the captured `:text`s and instructs:
  *"Prefer REDEFINING the existing tool gene (same gene name) with the
  corrected behavior rather than adding a near-duplicate."* Same-name
  redefinition is already fully supported by `hot-load-gene` + revert tables —
  live redefinition is the point of the substrate.
- **Async enrichment (optional, evolver-side only):** in `dream`
  (agent.lisp:590), before mining, one cheap classifier call over the last 20
  `:user-message` events → enriched `:correction` events with
  `:confidence :llm`; behind `*dream-classify-corrections*` (default T).
  Never in the interactive path (PR-13 stays intact).
- **Tests** `tests/corrections-test.lisp`: text table → expected class /
  no-detection; rework detection over synthetic event lists; end-to-end: two
  corrections → `mine-patterns` yields a `:correction` pattern.
- **Verify:** `make dev`; have the model run a shell command; type
  "no, use pnpm not npm" → `grep '(:kind :correction'
  $OURRO_HOME/sessions/*/events.sexp`; repeat once → header shows `⚡1`.

#### M1-3 · ✅ Candidate records persist + shelf/retry (S/M)

- `record-candidate` in `src/evolve/engine.lisp`: append a sanitized plist
  (`:id :status :gene-name :source :previous-source :diagnostics :report
  :pattern :generation-id :time`) to `state/evolutions.sexp` on every status
  change (terminal states of `propose-gene`, `apply-candidate`, and the
  probation-revert hook at agent.lisp:1083).
- Capture `:previous-source` in `apply-candidate` *before* `hot-load-gene`
  (engine.lisp:170) via `(find-gene (gene-name gene))` — this feeds the M2
  inspector's structural diff.
- Boot loads the last 50 records into `agent-candidates`; unify consumers on
  plists (`candidate->record` converter for live candidates).
- Retry: on boot, `:rejected` records with a pattern younger than 48 h are
  re-enqueued once (`:retried t` written back); `:retry-feedback` on a pattern
  is appended by `describe-pattern`: *"A previous attempt failed with: …
  Avoid that mistake."* (Also consumed by the inspector's `r` key in M2-4.)

#### M1-4 · ✅ PR-9 prompt-assembly upgrades (M)

In `src/evolve/prompt.lisp`:

- `api-surface-description` (line 42): stop skipping macros for harness
  packages — **`deftool` and `defgene` are currently invisible to the
  evolver** — mark them `[macro]`. Add classes: `do-external-symbols` →
  `find-class` → `sb-mop:class-direct-slots` → slot names + initargs
  (prerequisite knowledge for M3 UI genes).
- `nearest-genes` (line 139): replace substring match with scoring
  `2×|tools(gene) ∩ pattern-tools| + 1 if same category prefix + recency`,
  where `tools(gene)` comes from `gene-definition-names`' `:tool` entries;
  deterministic tie-break by name.
- Live exemplars: `assemble-evolution-prompt` (line 173) harvests up to 3
  recent *successful* `:tool-call` events for the pattern's tools from
  `recent-events` — grounded examples beyond the pattern's own evidence.
- **Fix the stale-manual bug:** clear `*evolution-system-prompt*` on
  `hot-load-gene` success. Today a hot-load leaves the cached manual
  describing the pre-evolution image, violating PR-9's "cannot be stale".

#### M1-5 · ✅ Onboarding as a real flow (L) — PR-10

*Day-one wow: point ourro at a repo and watch it grow `repo/build`,
`repo/test`, `repo/lint` as compiled, tested genes.*

- **New `src/onboard.lisp`** (package `ourro.agent`; .asd per D-2):
  - `probe-repository ()` — pure reads: `Makefile` (regex targets
    `^([a-zA-Z][a-zA-Z0-9_-]*):`, prefer test/build/lint/check),
    `package.json` (`ourro.llm:json-decode` on `"scripts"`; lockfile →
    pnpm/yarn/npm), `Cargo.toml`, `pyproject.toml`/`setup.py`, `go.mod`,
    `*.asd`, `Gemfile`, `mix.exs`. Output: candidate commands per role
    `(:build :test :lint)` — **whitelisted shapes only** (`make <t>`,
    `npm|pnpm|yarn run <s>`/`test`, `cargo build|test|clippy`, `pytest`,
    `go build|test ./...`, `ruff check`, `bundle exec rspec`, `mix test`);
    never free-form strings from manifest files.
  - `run-probes (candidates)` — each via `cap/run-program :timeout 90`,
    recording `(:cmd :exit :ms :output-head "first 30 lines")`; worker
    thread; narrated via `set-activity`
    (`"onboarding: probing \`make test\` (2/4)…"`).
  - `onboard-patterns (probes)` — one pattern per green role:
    `(:kind :onboarding :role :test :command ("pnpm" "test") :exit 0 :ms 8500
    :output-head … :evidence …)`.
  - New `:onboarding` branch in `describe-pattern`: *"Create gene
    `repo/<role>` wrapping exactly this command via `cap/run-program`,
    returning a compact summary (parse pass/fail counts; include the output
    tail on failure). Capabilities: (:subprocess). Test the parsing as pure
    functions against this captured output:"* + the real captured output —
    grounded, hermetic test fixtures from the user's own repo.
  - Drive the **existing** loop: `propose-gene` → `apply-candidate :force t
    :snapshot :async`, sequentially per role, progress via `*progress-hook*`.
- Rewrite `cmd-onboard` (agent.lisp:743): probe → transcript summary table →
  proposals → ticker `"onboarded: repo/build repo/test grown · try them"` →
  append a user-visible toolchain summary message (so the coder role knows
  the toolchain too) → print honestly which of `repo/build|test|lint` now
  exist (`find-gene`).
- **Tests** `tests/onboard-test.lisp`: detection over fixture trees (temp
  dirs with `package.json` etc.); whitelist rejection of weird scripts;
  end-to-end with a scripted provider returning a canned `repo/test` gene.
- **Verify:** scratch npm fixture repo, `make dev`, `/onboard` → status row
  narrates probes → `⚡ hot-loaded repo/test` → `/genome` lists it → ask "run
  the tests" → the model calls `repo_test`, with zero prompt tokens spent
  describing how (PR-3's token claim, demo scenario 5).

#### M1-6 · ✅ Make mining actually evolvable (S/M) — PR-7 honesty

- Relocate the queue: move `*evolution-queue*` / `enqueue-pattern` /
  `dequeue-pattern` / `queue-length` into new `src/observe/queue.lisp`
  (package `ourro.observe`); `ourro.evolve` imports + re-exports (call sites
  unchanged). (Reason: `evolve` loads after `genome`, so `OURRO.API` cannot
  import from it; `observe` loads before.)
- New capability **`:observe`** in `+all-capabilities+`
  (src/kernel/capabilities.lisp:13); walker requires it for `RECENT-EVENTS`
  and `ADD-TURN-HOOK` (src/kernel/walker.lisp:32).
- `ourro.observe:*turn-hooks*` — list of `(name capabilities thunk)`; API
  `add-turn-hook (name thunk)` captures `*current-gene-context*` for
  capabilities + a revert-action that removes the hook. `on-turn-done` runs
  each hook under `(with-capabilities <declared>)` inside `handler-case`; an
  erroring hook is removed + amber ticker (same recovery story as probation).
- `OURRO.API` exports: `recent-events`, `enqueue-pattern`, `add-turn-hook`.
  Update `harness-manual`. A gene can now *be* a smarter miner: read events,
  enqueue patterns.
- **Tests:** walker requires `:observe`; a fixture gene adding a turn hook
  that enqueues a pattern passes the gauntlet and grows the queue at
  `on-turn-done`.

### M2 — "The demo is undeniable" (showcase: see it stream, learn, explain itself)

**✅ Landed (all five sub-items).** `make test` green (396 checks) + `make
smoke`. New source: `src/tui/markdown.lisp`, `src/inspector.lisp`. New suites:
`keymap-test`, `inspector-test`, `stream-test`, `markdown-test`; `handoff-test`
extended with the arrival round-trip. Notes along the way: the TUI keymap
runner is named `invoke-command` (not `run-command`) to avoid colliding with
`ourro.util:run-command`; F-keys decode in both SS3 (`ESC O P..S`) and CSI
(`11-24 ~`) forms; the inspector is a modal overlay in the view's `overlay`
slot that owns the transcript region while the rest of the chrome stays put.

#### M2-1 · ✅ Live streaming into the transcript (M)

- Agent slots `stream-text` / `stream-start`. Rewrite `stream-event`
  (agent.lisp:333) — it runs on the turn worker (the `complete` call at
  agent.lisp:269 is synchronous on that thread), the sanctioned transcript
  writer per D-1:
  - `:delta` → append to `stream-text`; re-wrap **only** the in-progress
    message via `ourro.tui:wrap-text` at current width, style `:assistant`,
    append a `("▌" . :accent)` cursor span to the last line; rebuild
    `transcript-lines` as `(append (subseq lines 0 stream-start) new-tail)`;
    `enqueue-ui '(:kind :dirty)`. First delta records `stream-start`.
    Painting stays throttled by `ui-loop`'s 0.09 s busy tick — cheap.
  - `:thinking` → `set-activity "reasoning…"` (emit `(:kind :thinking)` from
    src/llm/vertex.lisp:281-290 when a thinking part is parsed).
- `process-turn` (agent.lisp:283-286): replace `add-wrapped` with
  `finish-stream` — swap the streamed tail for final markdown-rendered lines
  (M2-2), reset stream slots. Reset also in the `unwind-protect` cleanup so a
  provider error never leaves a dangling `▌`.
- Extend `scripted-provider` (src/llm/vertex.lisp:314-339) with `:stream t`
  (word-by-word deltas) — offline demos and tests.
- **Tests** `tests/stream-test.lisp`: headless agent, synthetic deltas →
  tail replacement, cursor present during / absent after `finish-stream`.

#### M2-2 · ✅ Minimal markdown + visible tool results (M)

- **New `src/tui/markdown.lisp`** (~150 LOC, pure): `markdown-lines (text
  width)` → styled lines. Fences toggle code mode (`:code` style, 2-space
  indent, truncate not wrap, language tag `:dim`); `**bold**`; `` `inline` ``
  → `:inline-code`; `#`/`##` prefixes → `:accent`; `- ` bullets with hanging
  indent. Add `wrap-spans (spans width)` for styled wrapping; plain
  `wrap-text` untouched. New styles in `*styles*` (src/tui/render.lisp:11):
  `:code`, `:inline-code`, `:bold`.
- `finish-stream` + assistant `add-wrapped` calls use `markdown-lines`.
- Tool results: in `run-tool-calls` (agent.lisp:301-320), after
  `execute-tool-call`, append `(:dim "   ↳ <first-line ≤90 chars> · <N>ms")`
  or `(:danger "   ↳ ERROR: …")`. (Today the user sees only the `⚙` call
  line; results go exclusively to the model.)
- **Tests** `tests/markdown-test.lisp`: fence round-trip, width respect,
  style keywords; a `run-tool-calls` test asserting the `↳` line.

#### M2-3 · ✅ Keymap-as-data + focus pipeline + live ticker keys (M)

*Makes the components.lisp:9 comment ("keymaps are alists — data") true, and
turns the ticker's dead affordance into the product's signature interaction.*

- `src/tui/components.lisp`:
  - `view` gains an `overlay` slot (one modal component or NIL).
  - Exported: `*keymap*` — alist `(key . command-keyword)` where key is
    exactly what `read-key` returns; `*commands*` — `eq` hash keyword→thunk;
    `(bind-key key command thunk &key gene)` — validates against
    `*reserved-keys*` (everything `handle-key` consumes today + all printable
    chars; allowed: `:f5`–`:f12`, spare ctrl chords, `:alt-<letter>`); when
    `ourro.kernel:*current-gene-context*` is bound, records a revert-action
    that unbinds — **gene keybindings undo through the same revert table as
    gene code**. One mechanism, code and UI alike.
- `src/tui/term.lisp`: decode F-keys — `ESC O P..S` → `:f1..:f4`
  (decode-escape's `#\O` branch, term.lisp:240); CSI `11-15,17-21,23,24 ~` →
  `:f1..:f12` (decode-csi-final's `#\~` case, term.lisp:284).
- `src/agent.lisp`: `handle-key` (833) becomes a four-stage pipeline, each
  stage may consume:
  1. **Overlay** — if `(view-overlay view)`, call new generic
     `ourro.tui:overlay-key (overlay key)` → `:close` / `:handled` (modal:
     swallow everything).
  2. **Keymap** — `*keymap*` chords only (never plain chars).
  3. **Ticker keys** — only when the ticker is visible with actions **and
     the input is empty**: `e` → open inspector on newest record; `u` →
     revert (existing `cmd-revert` logic). The empty-input guard keeps `e`
     a normal letter while typing.
  4. **Editor** — the existing `case`, renamed `handle-editor-key`.
- Register built-ins: `:f2` and `:ctrl-e` → toggle inspector.
- **Tests** `tests/keymap-test.lisp`: reserved-key rejection; ticker-key
  guard both ways; `ESC O Q` → `:f2` in tui-test's `with-key-stream` harness.

#### M2-4 · ✅ Evolution inspector overlay (L)

*The marquee surface: press `e` and see the compiled gene, its structural
diff, the evidence that triggered it, its test report, and its measured
payback.*

- **New `src/inspector.lisp`** (package `ourro.agent`):
  `evolution-inspector` class — slots `agent`, `items` (records from M1-3,
  newest first), `cursor`, `expanded`, `scroll`.
- `render-component` method → styled lines: title row
  (`"evolutions · j/k move · enter detail · u undo · r retry · f freeze ·
  a apply staged · q close"`), then per item: status glyph
  (`✓ hot-loaded · ◐ staged · ✗ rejected · ↩ reverted · ❄ frozen`), gene
  name, measured benefit from the M1-1 ledger (`"14 uses · ≈9m saved"`).
  Expanded under the cursor row:
  - **Structural diff** — `describe-genome-diff` over
    `(genome-diff (list previous) (list current))` using M1-3's
    `:previous-source`; new genes render as `＋ tool <name> (1 tool, 2 tests,
    caps: …)` via `gene-summary`. This finally surfaces
    `src/genome/diff.lisp:50-137`. Homoiconicity on camera: the diff is a
    tree compare of the actual program, not a textual patch.
  - **Evidence** — the pattern's `:evidence` entries ("you did: read_file
    src/x.lisp (1.2s) ×3"); for corrections, the user's own words.
  - **Tests** — first 8 lines of the stage report.
  - **Provenance** — pattern id, model, generation, timestamps.
- `overlay-key` method: `j`/`k`/arrows move; `enter` toggles detail; `u`
  revert selected (`revert-gene-definitions`, mark `:reverted`, ticker); `r`
  retry-with-feedback (enqueue pattern with `:retry-feedback` + diagnostics,
  `spawn-evolver`); `f` freeze gene (ledger `:frozen`); `a` apply a staged
  dream candidate (`apply-candidate :force t :snapshot :async`); `q`/escape →
  `:close`.
- **Layout:** in `paint-frame` (components.lisp:314), when
  `(view-overlay view)` is set, substitute the *transcript region only* with
  the overlay's clipped lines — header/ticker/status/input stay; the
  double-buffer diffing needs zero changes.
- `/evolutions` opens it by enqueueing `(:kind :open-inspector)`, handled in
  `ui-loop`'s event case (agent.lisp:1024) — slash commands run on worker
  threads; UI mutation must marshal (D-1).
- **Tests** `tests/inspector-test.lisp`: render fixtures at width 80 assert
  diff lines (`＋ tool` / `~ changed`); navigation; `u` triggers a recorded
  revert on a fixture gene; `q` closes.

#### M2-5 · ✅ The arrival moment (S)

- `perform-handoff` (agent.lisp:1198) adds
  `:arrival (:from <gen> :to <gen> :gene <name> :benefit <string>)` to the
  handoff `:extra`.
- `restore-session` (agent.lisp:812): when `:arrival` present → ticker
  `"⚡ now running gen-0042 — grew edit-and-test · saves ~40s/use · e explain"`
  (`:success`, 10 s) + a `:dim` transcript divider
  `"── evolved: gen-0041 → gen-0042 (edit-and-test) ──"`; suppress the
  stale-ticker restore in that case (today the *old* ticker is re-shown).
- Extend `tests/handoff-test.lisp` with an `:arrival` round-trip.

### M3 — "The agent redecorates" (TUI evolvability — PR-7's UI half, demo 3)

**✅ Landed (all four sub-items).** `make test` green (433 checks) + `make
smoke` (10 tools, 7 genes). New source: `seed-genome/genes/ui/git-branch.gene`.
New suite: `ui-api-test`. Notes along the way: the keymap runner named in M2 is
untouched; `define-status-widget`'s refresh interval is floored to 1 s (no
per-frame widgets); the three-strikes retirement reuses the probation amber
ticker (`*probation-failure-hook*`) so a broken widget/pane reverts its gene
exactly like a gene that failed on use; UI mutations are isolated during
staging by rebinding `*active-view*`/`*status-widgets*`/`*keymap*`/`*commands*`.

#### M3-0 · ✅ Prerequisites (S)
D-2 ASDF reorder (`tui` now loads before `tools`/`genome`) + D-3 gene-context
relocation (`*current-gene-context*` lives in `ourro.kernel`; `ourro.tools`
imports + re-exports it). `make test` + `make smoke` green after each.

#### M3-1 · ✅ UI surface in `ourro.tui` with safety rails (L)

- `src/tui/components.lisp`:
  - Exported base class `pane` — slots `gene` (`:initform` captures
    `*current-gene-context*`'s name at instantiation), `visible`.
  - `*active-view*` — set by `run-agent` at boot; **rebound to a throwaway
    `make-view` in verifier staging** (add to `run-staged-tests`' dynamic
    bindings, src/verify/verifier.lisp:162) so a candidate's load-time
    `add-pane` can never touch the live screen.
  - `add-pane (pane)` / `remove-pane` — mutate `view-panes` (already rendered
    by `paint-frame`, components.lisp:324-329); gene context ⇒ revert-action.
  - `*status-widgets*` — alist `(name . (:fn f :interval s :cache str
    :next-refresh t :gene g :strikes 0))`; macro
    `(define-status-widget name (:interval 5) body…)` registers a 0-arg
    closure; statusbar render appends right-aligned cached strings; refresh
    in `paint-frame` before layout for widgets past `:next-refresh`.
  - **Three-strikes rule:** every widget refresh / pane render runs inside
    `handler-case`; an error increments `:strikes`; at 3 → remove the
    widget/pane, `revert-gene-definitions` on the owning gene, amber ticker
    via `*probation-failure-hook*`. **The frame always paints** — a broken
    evolved widget degrades to its cached string, never to a torn screen.
    Same conditions-instead-of-crashes story as probation (PR-6), applied to
    pixels.
- **`OURRO.API` additions** (src/genome/genome.lisp:23-128), legal after D-2:
  import + export `pane`, `render-component`, `styled`, `wrap-text`,
  `add-pane`, `remove-pane`, `define-status-widget`, `bind-key`; plus CL's
  `update-instance-for-redefined-class`, `call-next-method`, `next-method-p`
  (currently missing — genes cannot write `:around` methods or class
  migration methods at all).
- **Kernel:** new `:ui` capability in `+all-capabilities+`; walker
  `*capability-requiring-names*` gains `ADD-PANE`, `REMOVE-PANE`,
  `DEFINE-STATUS-WIDGET`, `BIND-KEY` → `:ui`.
- **`harness-manual`** (src/evolve/prompt.lisp:67) new section **UI GENES**:
  the three verbs, the `:ui` capability, the render contract (pure function
  of state → list of styled-span lines, ≤6 lines, no I/O), and the showcase
  paragraph: *"If you redefine a pane class to add a slot, give it an
  `:initform`; live on-screen instances are migrated by
  `UPDATE-INSTANCE-FOR-REDEFINED-CLASS` on the next repaint — you may
  specialize it for custom migration."* The language standard specifies what
  happens to on-screen objects when their class changes under them; that is
  the whole demo.
- **Tests** `tests/ui-api-test.lisp`: widget strike-out reverts its gene;
  staged verification leaves the live view untouched; walker demands `:ui`;
  UIFRC smoke — define a pane class via gene A, instantiate, redefine with a
  new defaulted slot via gene B, `slot-value` migrates on the live instance.

#### M3-2 · ✅ Seed UI gene — the few-shot exemplar (S)

`seed-genome/genes/ui/git-branch.gene`: a `define-status-widget` reading
`.git/HEAD` via `cap/read-file` (no subprocess; 5 s interval), rendering
`⎇ main`; a pure parse test against fixture HEAD contents. Capabilities
`(:filesystem-read :ui)`. Add to `seed-genome/manifest.sexp`; update any
seed-count assertions in tests. `nearest-genes` will select it for any UI
request — the genome is its own training set.

#### M3-3 · ✅ Demo path (S)

- One sentence in the coder system prompt (agent.lisp:91): *"You can also
  grow UI: status widgets, panes, and keybindings are genes (see
  evolution_manual)."*
- Scripted demo beats: "add a clock to your status bar" → one-shot
  `propose_gene` → widget appears mid-conversation, **no restart** (hot-load
  → `*status-widgets*` → next frame). "Make it show seconds" → live gene
  redefinition. "Show a pane with the git diff stat of the last file you
  edited" → `defclass diff-pane (pane)` + `render-component` method +
  `add-pane` → pane appears live; ticker `u` removes it via the revert thunk.

### M4 — "Unkillable + trustworthy" (robustness + hardening)

**✅ Landed (all six sub-items).** `make test` green (492 checks) + `make
smoke` (11 tools — `verify_determinism` added, 7 genes, `kernel selftest OK`).
New source: `src/kernel/selftest.lisp`. New suite: `robustness-test`;
`supervisor-test`/`vertex-test` extended. Notes along the way: the capability
ceiling (M4-6) is enforced at the single `with-capabilities` choke point, so it
covers both the per-tool grant and the turn's blanket grant without touching
either call site; the crash-resume decision is a pure `crash-resume-plan`
(resume a checkpoint at most once, then poison it) so the no-crash-loop
guarantee is unit-tested; the kernel self-test is a FiveAM suite compiled into
the image and run at `--smoke`, and the `--replay` gate + `sb-ext:lock-package`
run only inside a supervised image build (see the honesty note at the end of
this section). Deferred-safe: the replay gate signals a build failure only on a
*confirmed* action-trace divergence; any infrastructure hiccup is logged and
skipped so it never blocks a build spuriously.

#### M4-1 · ✅ Crash-safe session checkpoint (M) — closes PR-6's caveat, demo 2

- Factor the payload construction out of `serialize-session` (agent.lisp:782)
  → `session-payload (agent)`; `checkpoint-session` writes it to the fixed
  `state/checkpoint.sexp` (atomic staging in util.lisp), called from
  `on-turn-done` and after `dispatch-command`, with `:pid`, `:written`,
  `:checkpoint t`.
- Supervisor crash branch (supervisor.lisp:581-606): before respawn, if
  `state/checkpoint.sexp` exists and the previous boot was **not** itself a
  checkpoint resume, pass it as `--resume`. Track `resumed-from-checkpoint`
  in the supervision state; if a checkpoint-resumed boot crashes, rename the
  file `checkpoint-poisoned.sexp` (kept for forensics) — a poisonous
  checkpoint must not feed the crash loop.
- Graceful handoff (`perform-handoff`) and clean quit delete the checkpoint;
  agent boot deletes it after successful restore.
- Recovery ticker: `"recovered your session after a crash (gen N) — last
  turn may be incomplete"` (amber).
- **Tests:** extend `tests/supervisor-test.lisp` via the `*spawn-agent-hook*`
  seam: crash-with-checkpoint → next spawn args contain `--resume
  …checkpoint.sexp`; immediate second crash → they don't.
- **Verify:** `make run`, chat twice, `kill -9` the agent → TUI back in ~3 s
  **with the conversation**, amber ticker.

#### M4-2 · ✅ Handoff completeness + typeahead (S)

- Restore `:cwd` → `(setf ourro.toolkit:*workspace* dir)` when it exists
  (written today at agent.lisp:793, never read back).
- Typeahead: a mid-turn Enter currently spawns a **concurrent turn** (no
  gating in `handle-enter`/`run-submission`). Add a `pending-submissions`
  queue: when busy, enqueue + `:dim` transcript line `"(queued)"`; drain one
  per `:turn-done`; serialize as `:pending` in the handoff (field exists at
  handoff.lisp:26, never populated) and restore.
- Politer restarts: defer a pending generation handoff until input is empty
  **and** ≥10 s since the last keystroke (today: only `not busy`).

#### M4-3 · ✅ LLM retry/backoff (S)

`complete-with-retry` in src/llm/vertex.lisp: `handler-case` on
`provider-error`; when `provider-error-retryable-p` (computed at
vertex.lisp:302, currently never consumed) and attempts remain → sleep
1 s/2 s/4 s + jitter, `on-retry` callback (agent sets activity
`"provider busy — retrying (2/3)…"`), else re-signal. Use in `process-turn`
and `propose-gene`. Test with a scripted provider that fails retryably twice.

#### M4-4 · ✅ Image retention / GC (S)

`prune-images` in supervisor.lisp, after `add-generation-record` and at
`supervise` start: keep image files for `:current`, the 3 newest `:good`, and
quarantine-record parents; delete the rest. Ledger records stay — the genome
is truth and any image is rebuildable. `/travel` to a pruned generation:
refuse with `"image pruned — rebuild not yet implemented"` (rebuild-on-demand
from the generation's git commit is a follow-on M).

#### M4-5 · ✅ Kernel-path hardening (L) — PR-11 for real

Key insight: kernel code is not in the genome; it enters images only when
`base.core` is rebuilt (`ensure-base-core`, supervisor.lisp:262). So the gate
keys on "base core changed":

1. **Kernel selftest in every image:** new `src/kernel/selftest.lisp` —
   FiveAM suite (FiveAM is already an image dependency, ourro.asd:16):
   safe-read rejects `#.`/depth bombs; walker rejects uncapped effects and
   kernel references; revert round-trip; probation fires
   `EVOLVED-CODE-FAILURE` + hook; protocol length-prefixed framing
   round-trip; capability-ceiling enforcement (M4-6). `run-kernel-selftest`
   → boolean + report. `--smoke` (agent.lisp:1213) runs it, so **every**
   generation build (which already smoke-boots, supervisor.lisp:317-326)
   self-tests in <5 s.
2. **Replay gate:** `--replay <events-file>` mode in src/main.lisp — run
   `ourro.verify:replay-session` (replay.lisp:55) and `prin1` the action
   traces. Supervisor `build-image`, when the base core is newer than the
   parent generation's image: replay the newest ≤3
   `sessions/*/events.sexp` against **both** current and staged images (same
   filesystem, same moment; only read-only tools replay —
   `*replayable-tools*`, replay.lisp:73 — and traces carry no timestamps, so
   `compare-traces` needs no tolerance logic). Divergence →
   `generation-build-failure` with the report; verdict logged to
   `state/supervisor.log`.
3. **Gauntlet tightening:** remove the
   `"undefined variable: common-lisp-user::"` whitelist entry
   (verifier.lisp:103) — prove with `make test` + a full seed rebuild; run
   staged tests **twice** (cheap catch for state-dependent genes); register
   `verify_determinism` as a base tool next to `list_genes` so the *model*
   can prove PR-13 on request (a demo beat); `sb-ext:lock-package` on
   `OURRO.KERNEL` in `scripts/build-agent-image.lisp` (built images only —
   dev/test stay unlocked so suites can poke internals).

**Verification honesty.** The parts that run *inside the live image and test
suite* are unit-tested here: the kernel self-test suite (12 invariants) is
green under `make test` and at `--smoke`; the whitelist removal + double-run
staging survive the full suite and the seed genome (`make smoke`, 7 genes); the
`verify_determinism` tool loads; `extract-between` and `crash-resume-plan` are
covered. The parts that only execute during a *supervised image build* — the
`sb-ext:lock-package` on `OURRO.KERNEL` and the `--replay` divergence gate
against two real generation images — compile and are wired, but were **not**
exercised end-to-end in this environment (no gcloud auth / no full
`make init && make run` build here). Both are deliberately fail-safe: the lock
is non-fatal (ship unlocked on failure) and the replay gate blocks only on a
confirmed divergence. Re-shoot §12 scenario 2's `kill -9` beat and touch a
kernel file to see `kernel selftest OK` + `replay: 0 divergences` in a live
supervised run before calling PR-11 fully proven.

#### M4-6 · ✅ `/travel` visiting is actually read-only (S/M)

New `ourro.kernel:*capability-ceiling*` (default `+all-capabilities+`);
`call-instrumented` (src/tools/protocol.lisp:94) and `process-turn`'s blanket
grant (agent.lisp:268) intersect grants with the ceiling; `boot`
(src/main.lisp:21) sets it to `(:filesystem-read :llm)` under `--visiting`.
A visiting `write_file` now signals a clean `capability-violation` tool error
(the model sees it and explains); the statusbar already says
`"visiting <gen> (read-only)"` — now it's true. Covered by the kernel
selftest.

### M5 — "The genome is the whole truth" (completeness: rebuildable, provable, measured)

**✅ Landed (all three sub-items).** `make test` green (552 checks) + `make
smoke` (11 tools, 7 genes, `kernel selftest OK`). No new source files; changes
in `src/supervisor.lisp`, `src/genome/genome.lisp`, `src/kernel/walker.lisp`,
`src/verify/verifier.lisp`, `src/evolve/prompt.lisp`; new tests in
`supervisor-test`, `verifier-test`, `walker-test`. Closes the last three 🟡
scorecard rows (PR-5, PR-12, PR-13) and the M4-4 rebuild-on-demand follow-on.

The theme is finishing the claims M1–M4 leaned on: *the genome is truth and an
image is only a cache* (so any generation is rebuildable), *learned behavior is
reproducible machine code* (so determinism is enforced, not asserted), and *the
restart budget is real* (so PR-5's <2 s is measured, not hoped).

#### M5-1 · ✅ Rebuild-on-demand for pruned/missing images (L) — PR-12 → ✅

Every generation's genome state is a git commit in the genome repo, so a pruned
image (M4-4) is fully reproducible. New `rebuild-generation-image` /
`ensure-generation-image` (supervisor.lisp): check the record's `:commit` out
into a throwaway `state/worktrees/<id>/` git worktree (never disturbing the live
genome working tree or HEAD), `build-image` from it — `build-image` already
takes an arbitrary `genome-dir`, so nothing there changed — then remove the
worktree. Each generation commit is pinned by a per-generation git tag
(`pin-generation-commit`) so a hard re-root can't leave it unreachable for `git
gc` to prune — the "rebuildable" claim actually holds. The rebuild's git ops
serialize under the build lock so they can't race a concurrent
`build-generation`. Wired into (a) the `/travel` handoff branch that used to
refuse a pruned target ("rebuild not yet implemented"), which now rebuilds and
proceeds, and (b) a defensive pre-spawn guard so boot/crash paths self-heal a
missing image instead of exec'ing a file that isn't there. Caveat, documented in
the code: the rebuild uses the current base core (kernel); for a genome-only
generation that reproduces the image exactly, and when the kernel has since
changed it is that genome on today's kernel — the same equivalence the M4-5
replay gate guards. **Tests:** present-image is a no-op (no build); no-commit →
NIL; a real 2-commit scratch genome + `*build-image-hook*` seam asserts the
build ran against a worktree checked out at exactly the record's commit, the
image landed, and the worktree was cleaned up.

#### M5-2 · ✅ Determinism becomes structural + verified (M) — PR-13 → ✅

Two complementary moves close "verify-determinism is not in the gauntlet, and
`random` is in `OURRO.API`":

1. **No randomness primitive.** `random` is removed from `OURRO.API` (import
   *and* export) and added to the walker's `*forbidden-symbol-names*` (which
   matches regardless of package, so a fully-qualified `cl:random` is caught
   too, with a clear rejection). A gene can no longer be nondeterministic *by
   chance* — the package system bars the one primitive with no legitimate use.
   (This is not a blanket no-nondeterminism guarantee: environmental inputs like
   the clock, and `gensym`, remain reachable by design — a gene that uses them
   without declaring a `:determinism` probe simply isn't proven reproducible.)
2. **Verified property.** A gene may declare an optional `:determinism` contract
   in its metadata — `((\"tool_name\" :arg v …) …)` — and the gauntlet gains a
   6th stage (`run-determinism-probes`) that runs each named tool
   `*determinism-probe-runs*` (5) times in a fresh staged sandbox — under the
   same `*test-timeout-seconds*` watchdog the staged tests get, so a tool that
   loops on the probe args can't hang the gauntlet — via `verify-determinism`,
   and rejects the gene unless every run is byte-identical.
   The gene *declares* what it claims is reproducible; the compiler-backed
   gauntlet *proves* it before hot-load — determinism is now a checked contract
   next to `:capabilities` and `:contract`, not a demo-only tool. The staged
   sandbox setup that M3 grew for tests is factored into a
   `with-staged-registries` macro the probe reuses.
   `harness-manual` documents both (no `random`; how to add a `:determinism`
   probe). **Tests:** walker rejects `random`/`cl:random`/`make-random-state`;
   a gene reaching for `random` fails the gauntlet; the contract survives
   parsing; a probe on a pure tool passes and adds a `:determinism` stage; a
   probe on a `gensym`-based tool is rejected even though its test passes; a
   probe on a looping tool is reaped by the watchdog, not left to hang.

#### M5-3 · ✅ Restart budget is measured (S) — PR-5 → ✅

The supervisor stamps `get-internal-real-time` when it launches a
session-restoring respawn (a handoff or a crash-checkpoint resume — never a cold
boot), and on the new agent's `:hello` — by which point `restore-session` has
run — measures the round-trip and logs `"[ourro] session restored in 1.34s
(budget 2s: ok)"` to `state/supervisor.log`. Both ends are the same process, so
the monotonic clock is comparable. `last-restart-seconds` is retained for
surfacing/testing. **Tests:** the pure `elapsed-seconds`; `:hello` measures and
clears the timer for a resume but leaves it untouched for a cold boot.

### M6 — "Truth & polish" (hygiene, defect fixes, docs/skill)

**✅ Landed (all six sub-items).** Detailed plan: `docs/plan-m6-m8.md`. Repo
hygiene made permanent (`bin/ourro`, `*.fasl`, `*.core`, `.DS_Store` gitignored
and untracked); the `fable-3-m5` boot/crash guard now honors a rebuild failure
(`find-bootable-generation`) and stale rebuild worktrees are swept at supervise
start; D3/D4/D5 documented in-code; README/ROADMAP/SKILL refreshed. `make test`
green, `make smoke` (7 genes at the time).

### M7 — "The cockpit" (TUI/UX)

**✅ Landed (all seven sub-items).** Detailed plan: `docs/plan-m6-m8.md`. `make
test` green (0 failures, 31 suites) + `make smoke` (11 tools, 8 genes). The
live-demo cockpit: **turn-cancel** (Esc/ctrl-c stops a turn via a non-error
`turn-cancelled` `serious-condition`, synthesizing functionResponses so the
Gemini conversation stays well-formed, escalating a wedged worker via
`bt:interrupt-thread` guarded by `*cancel-inhibited*`); **column-accurate
`display-width`** (wcwidth range vectors so emoji/CJK stop shearing the layout);
an **always-on evolution HUD** that is itself a seed gene (`Σ … saved · N
genes`, dogfooding M3); **mouse-wheel scroll** + scroll indicator + viewport
pinning + `End`-to-bottom; a **tool-output ring + pager** (ctrl-o / `/out`);
**streaming markdown** (the in-flight tail runs the full pipeline every delta, so
finalized text never pops in); and an expanded **/help** + cold-boot primer. New
source: `src/pager.lisp`, `seed-genome/genes/ui/evolution-hud.gene`; new suites:
`cancel`, `pager`, `help`. The `make dev` live re-shoot is folded into the M8
end-to-end pass (needs gcloud auth).

### M8 — "Prove it live" (end-to-end supervised verification)

**◑ Headless half proven; live-Gemini half is a runbook pending live-model auth.**
Detailed plan: `docs/plan-m6-m8.md`; live runbook: `docs/live-shoot.md`.
Auth was the blocker; the provider now also accepts an **API key**
(`OURRO_VERTEX_API_KEY` / `GOOGLE_API_KEY` / `GEMINI_API_KEY`), so the live half
no longer requires an interactive gcloud login — a key is enough.

The automatable, no-LLM half is **done and reproducible** as `make verify-e2e`
(`scripts/verify-e2e.sh`, 19 checks, all green): it builds a throwaway
`$OURRO_HOME` from source and proves — against real generation images — that the
supervised build produces a commit-pinned, `:GOOD` gen-0001 with a genome git
repo; that every built image self-tests the kernel at `--smoke` **and locks
`OURRO.KERNEL`** (now observable: `--smoke` prints `OURRO.KERNEL locked: T`, the
M8-a code change); that a kernel source change forces a base-core rebuild whose
new image re-validates and re-locks; and that the replay machinery the kernel
gate compares emits its action-trace blocks (`--replay`). The restore-budget,
pruned-generation rebuild-on-demand, and replay-comparison are additionally
covered by unit tests (`supervisor-test`, `replay-test`).

The **live-Gemini half** — the six PRD §12 beats (grow a gene, probation +
`kill -9` recovery, redecorate, `/travel` to a pruned gen, `/onboard` an npm
repo, dream + inspector `a`), the build-time replay *verdict* on a
kernel-touching generation, and the restore-budget log line from a real handoff
— needs live-model auth (an `OURRO_VERTEX_API_KEY`, or `gcloud auth
application-default login` + `OURRO_VERTEX_PROJECT`) and a live TUI session, so it
is a step-by-step runbook (`docs/live-shoot.md`,
`make e2e-live`) that asserts each beat via `events.sexp` + the logs, never by
screen-scraping. Flip the README/ROADMAP honesty notes to "proven live" per beat
after the shoot, or file the defects found.

### Next cycle — "Reflexes" (M13–M16)

*Planned 2026-07-18 in `docs/plan-reflexes.md`.* The product's next big thing:
commands become manual overrides — value arrives through **automation genes**
("reflexes"): trigger-driven genes subscribing to the live event stream via
pure-data `:on` patterns, dispatched match-and-enqueue to a single politeness-
yielding worker, capability-bounded, probationary, three-strikes-reverting,
ledger-measured. M13 builds the substrate + the `auto/job-sentinel` seed; M14
adds bless-once consent (real ticker keys, `:staged` candidates) + the
`:reaction` miner family (A-then-B pairs → proposed reflexes) + per-workspace
memory with auto-onboarding; M15 adds agentic reflexes — headless read-only
background investigations ("the intern") delivering briefings before the user
asks (unlimited background LLM by user decision; step/time caps only); M16
proves it live + audits every command's automated path. Where conventional
agents have hand-written hook config, ourro mines, verifies, compiles,
measures, and reverts its hooks — the whole evolution machine pointed at
workflow automation.

### Previous cycle — "The Daily Driver" (Phase 0 + M9–M12) — ✅ landed 2026-07-17

*Planned 2026-07-17 in `docs/plan-daily-driver.md`; landed the same day (see
the header update above).* The self-evolution USP was
closed; this arc made the product a genuinely useful, efficient daily
driver: **background jobs** (dev servers that don't block chat and survive the
agent's own generation restarts), **capability-derived parallel tool
execution**, **Bedrock streaming + prompt caching**, a walker-gated
**`lisp_eval` compiler scratchpad**, a token-aware **context engine**
(two-stage compaction + cost HUD), and **invisible evolution**
(`docs/async-evolution.md` options A+B: async mined snapshots, calm restart
policy, out-of-process gauntlet). Its Phase 0 fixed the open **F-travel P1**
and it absorbed `docs/plan-m6-m8.md`'s M9 sketch (the `:slow-tool` miner
family) as M12-6.

---

## Part IV — Dependencies, effort, suggested order

| Item | Effort | Depends on |
|---|---|---|
| M0 hygiene | S | — |
| M1-1 utility ledger | M | — |
| M1-2 corrections | M | — |
| M1-3 records + shelf | S/M | — |
| M1-4 prompt upgrades | M | — |
| M1-5 onboarding | L | M1-4 (`:onboarding` branch) |
| M1-6 evolvable mining | S/M | queue relocation |
| M2-1 streaming | M | — |
| M2-2 markdown + results | M | M2-1 |
| M2-3 keymap / ticker keys | M | — |
| M2-4 inspector | L | M2-3; consumes M1-1/M1-3 data |
| M2-5 arrival moment | S | M1-3 |
| M3-0 D-2/D-3 prereqs | S | — |
| M3-1 UI API | L | M3-0, M2-3 (`bind-key`) |
| M3-2 seed UI gene | S | M3-1 |
| M3-3 demo path | S | M3-1/2, M1-4 |
| M4-1 checkpoint | M | `serialize-session` factor |
| M4-2 handoff/typeahead | S | — |
| M4-3 retry | S | — |
| M4-4 image GC | S | — |
| M4-5 kernel gate | L | — |
| M4-6 travel ceiling | S/M | — |
| M5-1 rebuild-on-demand | L | M4-4 (image GC), `build-image` genome-dir arg |
| M5-2 determinism gate | M | `verify-determinism`, walker, gene grammar |
| M5-3 restart budget | S | M4-1/M4-2 (resume paths) |

Suggested in-repo order:
M0 → M1-1 → M1-2 → M1-3 → M1-4 → M1-5 → M1-6 → M2-3 → M2-1 → M2-2 → M2-4 →
M2-5 → M3-0 → M3-1 → M3-2 → M3-3 → M4-1 → M4-2 → M4-3 → M4-4 → M4-5 → M4-6.

Items with no dependency edge (e.g. M4-3, M4-4) are good fillers any time.

## Part V — Per-milestone verification

**M1 — evolution earns its keep.**
`make test` (new ledger/corrections/onboard/queue suites green).
Live: `make dev`; grow a gene, use its tool 3× → `/genome` shows
`3 uses · ≈Ns saved`; type "no, use pnpm not npm" after a shell call →
`grep '(:kind :correction' $OURRO_HOME/sessions/*/events.sexp`; repeat →
`⚡1` pending in the header. `/onboard` in a scratch npm fixture →
`/genome` lists `repo/test`; "run the tests" → the model calls `repo_test`.

**M2 — the demo is undeniable.**
`make dev` → answers stream token-by-token, then snap to styled markdown;
`↳` result lines under tool calls; `F2` opens the inspector with structural
diff + evidence + tests; ticker `e`/`u` work with empty input. Supervised
(`make run`): trigger an evolution → arrival ticker
`"⚡ now running gen-0002 …"` after the quiet-boundary restart.
Offline: drive the agent from a scripted provider (`make dev` +
`ourro.llm:make-scripted-provider`) for a deterministic loop with streaming
deltas. The headless build + kernel-path proof is `make verify-e2e`; the live
supervised beats are the runbook in `docs/live-shoot.md` — assert via
`events.sexp` + supervisor.log heartbeats, never scrape the alt screen.

**M3 — the agent redecorates.**
"add a clock widget to your status bar" → appears without restart;
"make it show seconds" → live redefinition; erroring-widget fixture gene →
removed after 3 frames + amber ticker, frame never tears;
`tests/ui-api-test.lisp` green.

**M4 — unkillable + trustworthy.**
`make run`; `kill -9` the agent → session restored <5 s with recovery
ticker; immediate second crash → cold boot, no poison loop. `/travel 1`,
ask for a file write → clean capability error. Touch a kernel file →
next build's supervisor.log shows `kernel selftest OK` and
`replay: 0 divergences`. After ≥6 evolutions, `ls $OURRO_HOME/images` → ≤4
image files.

**M13–M16 — Reflexes: evolution as workflow automation.**
The autonomic nervous system: trigger-driven **automation genes** that
subscribe to the live event stream and act proactively. `make test` green
(automation + investigate suites). Delivered:
- **M13 substrate** — `(define-automation name (:on <pattern> …) body…)` in a
  gene's `:code`; a pure `event-matches-p` matcher (literal / `:not` / `:any` /
  `:matches` / `:>` `:<` / nested plist); a dispatcher that only matches +
  enqueues (safe on any thread) drained by one `ourro-reflex` worker under caps
  + a 60 s watchdog + probation + three-strikes; `:automate` capability;
  `post-note` (ticker + next-message, never the cached prompt); `/disarm`//`/arm`
  kill switch (carried through handoff); seed `auto/job-sentinel`.
- **M14 consent + reaction miner** — ticker action keys (`[y install] [n dismiss]`);
  a `:staged` candidate status so a mined reflex waits for one-key consent
  (deliberate `propose_gene` reflexes apply directly); the `:reaction` miner
  family (after A the user repeatedly does B → an automation); a
  `duplicate-automation-verdict` gate; per-workspace memory + seed
  `auto/onboard-new-repo`.
- **M15 the intern** — headless read-only `run-investigation` mini-turns
  (`request-investigation`, capability-ceiling-clamped, step-cap + 5 min
  watchdog); a briefings ring paged with `/out b<n>`; the sentinel upgraded to
  diagnose a failed job in the background; honest background-`:llm-call` cost
  accounting into the session cost.
- **Two levers, documented:** `/freeze` stops new evolution; `/disarm` stops
  installed reflexes firing.
- **Deferred:** M15-4 correction-driven reflex tuning (attributing a
  `:correction` to a nearby automation note → `:corrected` retirement) — a
  refinement on the existing correction/retirement machinery, not yet wired.
- **Verify:** `make dev`; `job_start "sh -c 'sleep 1; exit 3'"` → within ~2 s a
  warning ticker, and on your next message the model already knows why; `/disarm`
  → silence; in a fresh repo, first boot nudges `/onboard`.

---

*When an item lands, update the scorecard in Part I and check the item off
here. When all of M1–M2 are done, re-shoot the demo script in the PRD §12 —
scenarios 1, 2, 5, and 6 should run clean; M3 adds scenario 3; M4-1 completes
scenario 2's kill -9 beat and M4-4/12 keep scenario 4 fast.*
