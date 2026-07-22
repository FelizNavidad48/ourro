# Cloud QA Loop — ourro-drives-ourro continuous QA on AWS

## Context

Today's QA is Claude Code hand-playing a persona through the `ourro-qa` tmux CLI against a sandboxed test subject — proven, but human/CC-driven and one-shot. The goal is a **nonstop, self-contained QA loop hosted on AWS** where every role is an ourro instance (maximal dogfooding):

1. A **QA-operator ourro** runs a mission against a **test-subject ourro** and files findings.
2. An **engineer ourro** fixes the findings in the ourro repo.
3. The subject is **replaced** with a rebuilt instance from the fixed source.
4. If fixes landed, the **same mission re-runs fresh** to confirm; then the loop advances to a different mission. Repeat forever.

User decisions: all three roles are ourro; deployable to AWS (Docker on EC2); **fully autonomous merge to main** (gated); **daily spend cap** with pause-until-midnight.

What's missing today (verified): no way to hand an ourro a task non-interactively (input = tmux keystrokes only; the supervisor socket is lifecycle-only), no Linux/Docker story, no cross-instance orchestration, no findings→fix→rebuild pipeline.

## Architecture

A small **deterministic (non-LLM) conductor** owns the loop; all intelligence lives in the three ourro instances. Everything runs in **one container** (tmux multiplexes the sessions; each instance gets its own `$OURRO_HOME` + `OURRO_WORKSPACE` — the single-instance lock at src/supervisor.lisp:1244 is per-home).

```
conductor (Lisp state machine, no LLM)
 ├─ subject ourro     — /tmp/ourro-qa sandbox, fixture workspace (existing op-spawn)
 ├─ operator ourro    — workspace = repo checkout; drives subject via qa/bin/ourro-qa (shell tool)
 └─ engineer ourro    — workspace = fresh clone on branch qa-loop/cycle-N
```

State machine: `:pick-scenario → :spawn-subject → :run-operator → :harvest-findings → :run-engineer → :gate → :merge → :rebuild-subject → :confirm-rerun → :next` (plus `:paused` for spend cap, `:halted` for kill switch). Every transition persists to `loop-state.sexp` before acting → crash-resumable.

## Key design decisions

### Mission mode: `OURRO_MISSION` env var (new ourro capability)
- Mirrors the existing `OURRO_WORKSPACE` pattern (src/main.lisp:35) — env vars inherit through every supervisor→generation spawn for free; a CLI flag would need threading through the supervisor.
- At cold boot (no `--resume`, no `$OURRO_HOME/state/mission-submitted` marker): enqueue the mission file's contents as the first user message, write the marker. The marker guard prevents re-submission on generation restarts.
- **Completion is a protocol, not a mechanism**: the mission text tells the agent to write a result plist to `$OURRO_MISSION_RESULT` (via its own `write-file` tool) then `/quit`. Conductor's done-signal = result file exists ∨ pane dead, under a wall-clock ceiling.
- Full TUI still runs under tmux — heartbeat/screen/events observation surfaces keep working; mission mode is independently useful for daily-driver scripting.

### Conductor: Lisp, reusing `OURRO.QA.OPERATOR`
- `qa/loop/conductor.lisp` + `qa/bin/ourro-loop` (an `sbcl --script` wrapper loading qa/src/operator.lisp first, like qa/bin/ourro-qa). The loop is sexp-in/sexp-out end to end; `read-sexp-file`/`pget`/`op-spawn`/awaits/`op-collect`/`op-kill` all exist.

### Operator enablement
- Conductor composes a per-cycle mission file: condensed doctrine (`qa/loop/doctrine-operator.md`, distilled from the qa-operator SKILL) + verbatim mission sexp + concrete paths (session name, findings dir, result file).
- Operator workspace = the repo checkout so it can run `qa/bin/ourro-qa` and write `qa/findings/F-*.sexp` directly; conductor harvests by diffing the findings listing before/after.
- 120s shell-tool timeout: doctrine says always `--timeout 90` on awaits, re-invoke on exit 1 (awaits are pure polls). `job_start` for long verification (fixture test suites, curling servers).
- **tmux nesting fix**: operator's shell runs inside a tmux pane, so `$TMUX` is set and `tmux new-session -d` inside op-spawn refuses to nest → `env -u TMUX` in qa/bin/ourro-qa. Phase-0 spike; silently breaks everything otherwise.

### Engineer enablement + trust boundary
- Fresh clone, branch `qa-loop/cycle-N`; mission = engineer doctrine + harvested findings (only `:scale :quick-fix`; `:engineering` findings are filed for humans, never auto-fixed). Instructions: reproduce, fix, add regression tests, run `make test` via `job_start` (build ≫ 120s), commit with finding IDs, write result file, `/quit`.
- **Engineer never pushes.** The conductor owns all git-remote authority.

### Merge gates (all must pass; conductor runs them itself, never trusting engineer claims)
1. `make test` fully green on the engineer's branch (conductor's own run).
2. `scripts/verify-e2e.sh` green (headless, no LLM cost).
3. Diff sanity: ≤20 files, ≤800 lines, zero touches to protected paths (`.github/`, `deploy/`, `qa/loop/`, `scripts/build-*`, `Makefile`) — violations demote to a PR for humans.
4. **Confirm re-run**: rebuild, fresh subject from candidate source, fresh operator re-running the same mission with a re-check section per fixed finding; every one must come back `:fixed`. Any `:still-broken` → PR instead, findings reopen, loop advances.
5. Merge = squash-merge → push to main. Rollout switch `OURRO_LOOP_NO_MERGE=1` (default ON): identical loop but opens PRs; graduate to auto-merge after ~10 clean supervised cycles.

Runaway rails: per-phase wall clocks (operator 90 min, engineer 60, gates 30), max 2 engineer attempts per findings batch, max 3 subject respawns per cycle, kill-switch file `/data/STOP` checked at every transition, sandbox sweep between cycles.

### Spend cap
- Source of truth: `:llm-call` events with `:usage` in each instance's `sessions/*/events.sexp` (hook at src/agent.lisp:2939; covers `:background` evolver/dreamer spend too). Priced via `qa/loop/pricing.sexp` — a checked-in mirror of the `:pricing` tables (src/llm/bedrock.lisp:454-508 + vertex counterpart) with a FiveAM sync test so drift fails CI.
- Daily UTC ledger `/data/ourro-loop/ledger/YYYY-MM-DD.sexp`; before any LLM-bearing phase, if total ≥ `OURRO_LOOP_DAILY_USD` → `:paused`, graceful wind-down, resume at the interrupted phase after UTC midnight. Watchdog re-sums every 5 min mid-phase; hard cap (1.5×) kills the phase.

### Scenario variety
Round-robin cursor over `qa/missions/*.sexp` filtered by `:needs` availability; re-run-after-fix replays the same mission before advancing. (Future extension, not in scope: an ourro mission-generator phase.)

### AWS
- `deploy/Dockerfile`: Debian slim + sbcl/tmux/git/make/curl/python3/node; Quicklisp deps as a cached layer; `make supervisor && make test` as a build-time gate (the Linux port proves itself in CI). `deploy/entrypoint.sh`: tmux server + `qa/bin/ourro-loop run`.
- **EC2 over Fargate**: one always-on instance (t3.large-class; SBCL builds are CPU/RAM hungry), docker-compose `restart: unless-stopped`, EBS at `/data` (loop state, ledgers, clones), CloudWatch shipping loop-log. Secrets (`OURRO_VERTEX_API_KEY`, `OURRO_BEDROCK_API_KEY`, GitHub machine-user PAT) from SSM Parameter Store — never baked into the image.

## Phases

### Phase 0 — De-risk spikes (throwaway)
- **A (the make-or-break question)**: can an ourro drive `ourro-qa` at all? Hand-spawn a subject + a second ourro (`OURRO_WORKSPACE=<repo>`), paste a mini-mission ("against session X: say hello, await-idle --timeout 90, screen, write what you saw to /tmp/result.sexp"). Calibrates doctrine depth + model tier for operator/engineer.
- **B**: tmux nesting — confirm `$TMUX` refusal, fix with `env -u TMUX` in qa/bin/ourro-qa.
- **C**: Linux — scratch Dockerfile, `make supervisor && make test` in-container, catalog failures.

### Phase 1 — Mission mode
- Modify `src/main.lisp` (boot) + `src/agent.lisp` (startup): `OURRO_MISSION` injection with cold-boot + marker guard; `state/mission-submitted`.
- Extend `op-spawn` (qa/src/operator.lisp:256): `--workspace DIR`, `--mission FILE`, `--mission-result FILE` (env forwarding, recorded in qa-session.sexp).
- Tests: guard logic (marker/resume → no submit); CLI arg parsing. Verify live: trivial mission ("write `(:ok t)` to result, /quit") → result appears, no double-submit across a forced generation change.

### Phase 2 — Operator-as-ourro end-to-end (riskiest; before any conductor code)
- `qa/loop/doctrine-operator.md` + `qa/loop/compose.lisp` (doctrine + mission + paths → one mission file).
- Run the full triangle manually once on `legacy-rescue` (most deterministic mission). Success bar: ≥6 arc beats, ≥1 well-formed finding, result file written, clean quit — repeatable ~2/3 runs. Record real cost per run (sizes the daily cap).

### Phase 3 — Conductor v1 (local; no engineer, no merge)
- `qa/loop/conductor.lisp` + `qa/bin/ourro-loop`: pick → spawn-subject → run-operator → harvest → next; persistent state, loop-log, wall clocks, kill switch, sweeps. Spend engine: pricing.sexp + event-log summation + daily ledger + pause/resume.
- Tests (`tests/qa-loop-test.lisp`): transitions with stubbed phases, crash-resume from every phase, pricing-sync assertion, cap arithmetic. Verify: 2 full cycles locally overnight; ledger vs provider console.

### Phase 4 — Engineer + gates + merge
*REMOVED 2026-07-21: the engineer arm (auto-fix on a branch, merge gates,
auto-merge) was built and live-verified, then deliberately deleted pending a
more tested-out process. Findings now surface as GitHub issues instead
(`qa/loop/github.lisp`, filed at `:harvest-findings`); the operator arm is
the whole loop. The engineer implementation remains in git history if it is
ever revived.*

### Phase 5 — Linux + Docker
- `deploy/Dockerfile`, `entrypoint.sh`, `docker-compose.yml`; fix Spike-C findings; CI job building the image + running `make test` inside. One full containerized cycle locally.

### Phase 6 — AWS deploy + burn-in
- EC2 + EBS + SSM secrets + machine-user PAT + CloudWatch; `docs/plan-cloud-qa.md` runbook (deploy, tmux-attach debugging, kill switch, cap tuning, NO_MERGE→merge promotion). Burn in ≥10 cycles in PR mode with human review, then flip auto-merge.

## Measured (2026-07-18, Phases 0–3 live runs)

- **Operator-ourro competence: proven.** Two full missions (legacy-rescue 9/9
  beats + 6 findings; automation-and-integration 9/9 beats + 5 findings),
  both first-try, findings well-formed, skeptical verification performed.
- **Per-cycle cost (gemini-3.1-pro both roles): ≈ $2.60** (subject ~$0.87 /
  57 calls, operator ~$1.71 / 74 calls, ~1.1M in / 25k out tokens). Nonstop
  ≈ $60–90/day — the scale `OURRO_LOOP_DAILY_USD` should anticipate.
  The loop's default model is now **opus-4-6 (Bedrock)**; at Opus pricing
  ($15/$75 per 1M vs Gemini's $2/$12) expect roughly **6–8× that per cycle
  (~$16–20)** — size the daily cap accordingly, or set
  `OURRO_LOOP_MODEL=gemini-3.1-pro` for cheap cycles.
- One operator mission ≈ 10–25 minutes wall-clock incl. sandbox init; the
  25-step turn cap fires every ~5 minutes and the conductor's auto-continue
  nudge handles it.
- Linux/arm64 container: `make supervisor` + full suite green (Spike C).

## Riskiest assumptions
1. **Operator-ourro competence** (an 8–12-turn QA arc through a CLI) — de-risked first (0-A, Phase 2); fallback: conductor scripts the arc beats, operator-ourro only judges screens.
2. **Autonomous merge** — conductor-owned git, four gates, protected paths, PR burn-in.
3. **Cost** — Phase 2 measures real per-cycle spend before AWS; cap enforced from Phase 3.
4. **Linux port** — cheap to test early (Spike C).

## Critical files
- `qa/src/operator.lisp` — reuse surface (op-spawn:256, awaits, sexp IO) + conductor's library
- `src/main.lisp:35` — OURRO_WORKSPACE pattern the OURRO_MISSION injection mirrors
- `src/agent.lisp:2939` — `:llm-call`/`:usage` hook the spend engine reads
- `src/llm/bedrock.lisp:454-508` (+ vertex) — pricing tables mirrored by `qa/loop/pricing.sexp` with a sync test
- `Makefile`, `scripts/verify-e2e.sh` — merge gates + Docker build/test story
- New: `qa/loop/{conductor,compose}.lisp`, `qa/loop/doctrine-{operator,engineer}.md`, `qa/loop/pricing.sexp`, `qa/bin/ourro-loop`, `deploy/{Dockerfile,entrypoint.sh,docker-compose.yml}`, `tests/qa-loop-test.lisp`, `docs/plan-cloud-qa.md`

## Runbook (Phase 6)

### Deploy
1. Create SSM parameters under `/ourro-loop/` (see
   `qa/deploy/fetch-secrets.sh` header — `daily-usd` is required;
   `bedrock-api-key` for the default model; `gh-token` is a fine-grained PAT
   with issues: read/write, for findings→GitHub issues).
2. Launch a t4g.large (Ubuntu 24.04 arm64) with an IAM role granting
   `ssm:GetParameter` on `/ourro-loop/*`, a second EBS volume, and
   `qa/deploy/user-data.sh` as user-data (the repo is public — the clone
   needs no credentials).
3. The box formats/mounts `/data`, clones the repo, fetches secrets, and
   `docker compose up -d --build` — the image build runs `make supervisor`
   and the full suite, so a running container is a verified build.

### Operate
- **Watch**: `docker logs -f <ctr>` shows the conductor's `[loop]` lines;
  `docker exec -it <ctr> tmux attach -r -t <session>` watches a live ourro
  (`ctrl-b d` detaches). `qa/bin/ourro-loop status` inside the container
  prints state + today's spend.
- **Kill switch**: `touch /data/ourro-loop/STOP` — the loop halts at the next
  transition (and won't restart cycles until the file is removed).
- **Spend**: daily ledgers in `/data/ourro-loop/ledger/YYYY-MM-DD.sexp`; the
  loop pauses when `OURRO_LOOP_DAILY_USD` is reached and resumes after UTC
  midnight. Rotate keys → rerun `deploy/fetch-secrets.sh` +
  `docker compose restart`.
- **Findings & evidence**: `qa/findings/F-*.sexp` and `qa/reports/` in the
  container's checkout; engineer branches land on the remote as
  `qa-loop/cycle-NNNN` while `OURRO_LOOP_NO_MERGE=1`.

### Promote to autonomous merge
Burn in ≥10 cycles with `no-merge=1`, human-reviewing the pushed branches.
When branches are consistently mergeable as-is, set the SSM parameter
`/ourro-loop/no-merge` to `0`, rerun fetch-secrets, restart. The four gates
(diff sanity incl. protected paths → conductor-run `make test` →
`verify-e2e` → confirm re-run via the kept-cursor next cycle) stay on
either way.

## Verification story
- Each phase has its own live verification (above). End-to-end: Phase 3's overnight 2-cycle local run, Phase 4's planted-bug seed test, Phase 5's containerized cycle, Phase 6's ≥10-cycle PR-mode burn-in with human review before enabling autonomous merge.
