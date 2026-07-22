# ourro QA

Everything QA lives in this folder. QA here is **live-only, mission-driven
user testing**: an agent operator (you, or Claude Code via the
`.claude/skills/qa-operator` skill) *is* a real user with a real project — it
drives a live `bin/ourro run` in a tmux sandbox through the `ourro-qa` CLI,
types into the real TUI, watches the real screen, iterates like a human
client, and judges results with Claude Code as the baseline. There is no
scripted runner on purpose: a QA run that doesn't exercise the real LLM in a
real workflow measures nothing.

Three pillars:

1. **Real work.** Missions are real-world jobs — build a landing page, ship a
   backend API, analyze a sales CSV, rescue an inherited codebase — never
   synthetic exercises.
2. **Long, iterative sessions.** Every mission is an arc of 8–12+ user turns:
   feedback, bug reports, changed minds, technical questions.
3. **Evolution observed, never staged.** The operator never says "evolve" and
   never manufactures repetition. It works naturally and watches whether the
   self-evolution machinery shows up **uninvited and useful**, responding
   with the product's own levers (ticker `y`/`n`, inspector `u`, `/revert`,
   `/disarm`, `/freeze`) like a real power user.

The only product hooks are dev-only and env-gated (`OURRO_QA=1` heartbeat,
`OURRO_MODEL`/`OURRO_PROVIDER` overrides, `:llm-call`/`:turn-done` events). A
real user never sees any of it.

## Layout

```
bin/ourro-qa        the interactive operator CLI (bash shim + ourro-qa.lisp)
bin/ourro-loop      the cloud QA loop conductor (run|once|status)
src/operator.lisp  the tmux+file operator library (standalone: plain CL, ~0.3s cold load)
loop/              cloud loop: compose.lisp, spend.lisp, github.lisp, conductor.lisp,
                   doctrine-operator.md (the operator ourro's mission doctrine)
missions/          the mission bank (*.sexp — real-world jobs)
fixtures/          seed projects for missions (salesdata, legacy-inventory, tinyrepo)
findings/          findings land here as F-*.sexp (gitignored; surfaced as GitHub issues)
findings-log.md    session narratives / findings journal
reports/           collected evidence per run (gitignored)
deploy/            Docker + EC2 infra for the always-on cloud loop
docs/              design history (plan-qa.md, plan-cloud-qa.md)
```

## Prerequisites

- **tmux ≥ 3.0** (`brew install tmux`).
- SBCL + Quicklisp (same as the rest of the repo) and a built `bin/ourro`
  (`make build`).
- An API key in the environment (see the config tables below). The model
  alias picks the provider by itself.
- Host toolchains for the mission you pick (`node`/`npm`, `python3`, `git` —
  each mission declares `:needs`).
- `gh` (GitHub CLI), authenticated, if you want findings filed as issues.

## Interactive QA — the `ourro-qa` CLI

One Bash call per action; one readable sexp out; exit 0/1. Every command
targets the newest sandbox unless `--session NAME` is given.

```sh
# spawn — ALWAYS live; alias picks provider:
#   gemini-3.1-pro / gemini-3.5-flash → Vertex · opus-4-6 / sonnet-4-6 → Bedrock
# --fixture seeds the isolated workspace (<sandbox>/work/) with a project.
qa/bin/ourro-qa spawn --fixture qa/fixtures/legacy-inventory
qa/bin/ourro-qa spawn --model sonnet-4-6 --size 120x35
qa/bin/ourro-qa spawn --command dev            # from-source dev loop (no supervisor)

qa/bin/ourro-qa await-idle [--timeout N]       # boot/turn settled (files, not sleeps)
qa/bin/ourro-qa await-quiescent                # …AND evolver/dream finished
qa/bin/ourro-qa await-generation-change        # seamless restart happened (new pid)
qa/bin/ourro-qa await-event evolution-hot-load --timeout 300 [--match "(:k v)"]

qa/bin/ourro-qa say "text"                     # type + Enter (multiline → paste)
qa/bin/ourro-qa key ctrl-e                     # real keys: y n e u f2 escape ctrl-o …
qa/bin/ourro-qa paste "…"                      # bracketed paste, no submit
qa/bin/ourro-qa screen [--ansi] [--row N]      # the post-emulation grid
qa/bin/ourro-qa state                          # qa-status heartbeat (busy/queue/tick)
qa/bin/ourro-qa events [--kind K] [--since-offset N]

qa/bin/ourro-qa chaos kill-agent|kill-supervisor|sleep-idle [--seconds N]
qa/bin/ourro-qa collect --label <label>        # evidence → qa/reports/<session>/
qa/bin/ourro-qa issues [--dry-run]             # file GitHub issues for new findings
qa/bin/ourro-qa kill [--keep-home]             # teardown
qa/bin/ourro-qa sessions · help
```

The discipline that keeps it non-flaky: **one action → one await → one
observe**. Awaits key on the `state/qa-status.sexp` heartbeat (fresh ∧ not
busy ∧ empty queue) plus a stable-frame check — never sleeps. Give real work
real timeouts (300s+ for build-sized turns). Watch any session live:
`tmux attach -r -t <session>`.

## The mission bank — `qa/missions/*.sexp`

| Mission | What it exercises |
|---|---|
| `react-landing-page` | Non-technical client persona; React scaffold; dev server as a background job; vague bug reports; production build |
| `python-backend-api` | Technical persona; tests-first backend; regression-test discipline; auth; a judgment trap (missing schema data) |
| `sales-data-analysis` | Data work with a **planted, discoverable anomaly** (double-ingested week); charts; corrections; a leading-question trap |
| `legacy-rescue` | Inherited buggy codebase (fixture): failing test, latent bug reported mid-session "by a user", refactor with byte-identical output |
| `automation-and-integration` | git, hooks, live HTTP APIs, scheduling, a web-research probe — the mission most likely to surface capability gaps vs Claude Code |
| `ship-a-cli-tool` | Plain-Node product polish: UX nitpicks, config, packaging, honest publishing advice |
| `marathon-context-switch` | One messy session: interrupts, typeahead, a mid-turn kill ("battery died"), `/travel` curiosity, `/freeze`+`/disarm` honesty |

A mission file is a readable sexp:

```lisp
(mission "name"
  :title "…" :needs ("python3") :fixture "qa/fixtures/…"  ; omit when none
  :persona "who you are — stay in character all session"
  :ground-truth "planted facts only the operator knows (never reveal)"
  :brief "the opening ask, in the persona's words"
  :arc ("beat 1 …" "beat 2 …" …)       ; 6+ beats — the iteration spine
  :verify ("independent checks run OUTSIDE the pane …")
  :watch ("what to observe implicitly — evolution, reflexes, jobs, notes …")
  :baseline "the Claude-Code comparison rubric"
  :wrap-up "evidence to collect + findings to file")
```

Writing a new one: keep it a job a real person pays for, give it iteration
beats, plant verifiable ground truth where possible, and always include the
implicit-evolution watch list. The suite lints the bank
(`tests/qa/qa-operator-test.lisp`): required sections, ≥6 arc beats, fixture
dirs must exist.

## Judging and reporting

- **Independent verification is mandatory.** Run the tests yourself in
  `/tmp/ourro-qa/<session>/work/`, curl the servers, recompute numbers, diff
  refactor outputs. The transcript's claims are under test too.
- **Claude Code is the baseline.** Every "Claude would have done this
  better/at all" moment is a `:gap` finding (`:scale :quick-fix` or
  `:scale :engineering`). Strategic gaps are a primary QA output.
- **Evolution ledger per session.** What appeared uninvited, what you
  blessed/dismissed, what fired, what the notes/briefings were worth. Zero
  autonomous activity across a long varied session is itself reportable.
- Findings go to `qa/findings/<id>.sexp` (shape + severity/scale rubric in
  the `qa-operator` skill), session narratives to `qa/findings-log.md`,
  evidence via `collect` to `qa/reports/<session>/evidence/`.

## Findings → GitHub issues

Findings are **not** committed to git; the public record is GitHub issues.
`qa/loop/github.lisp` files one issue per finding via the `gh` CLI:

- Title `[QA] F-<id>: <finding title>`; body from the finding's
  repro/expected/actual/root-cause/impact/evidence fields; labels
  `qa-finding`, `P1`/`P2`/…, `area:<area>` (created without labels if the
  repo doesn't define them).
- **Dedupe**: a filed finding gets `:issue N` written back into its sexp; a
  fresh checkout falls back to searching issue titles for the `F-…` id, so
  re-runs converge on one issue per finding.
- **Best-effort**: no gh, unauthed gh, or GitHub down → filing is skipped and
  logged; nothing ever fails because of it. `OURRO_QA_GH_ISSUES=0` disables
  filing outright.
- The cloud loop files issues automatically after each cycle's harvest;
  interactively, run `qa/bin/ourro-qa issues` (or `--dry-run` to preview).

## The cloud loop — `ourro-loop`

A deterministic, no-LLM state machine (`qa/loop/conductor.lisp`) sequencing
ourro instances around the clock: pick a mission (round-robin) → spawn a
subject ourro → spawn an operator ourro to drive it → babysit (turn-cap
nudges, wall clock) → harvest findings → file GitHub issues → price the
cycle against a daily USD cap → next. Design history: `qa/docs/plan-cloud-qa.md`.

```sh
qa/bin/ourro-loop run       # the nonstop loop
qa/bin/ourro-loop once      # exactly one cycle (smoke a deployment)
qa/bin/ourro-loop status    # loop state + today's spend
touch $OURRO_LOOP_ROOT/STOP # kill switch (checked between polls/cycles)
```

## Configuration

**QA env vars** (read by qa/ code only — the product never reads these):

| Var | Meaning | Default |
|---|---|---|
| `OURRO_QA` | `1` enables the product's dev-only QA heartbeat (`state/qa-status.sexp`) | unset |
| `OURRO_QA_REPO` | repo root override for the operator CLI | auto-detected |
| `OURRO_QA_GH_ISSUES` | `0` disables findings→GitHub-issue filing | enabled |
| `OURRO_MISSION` / `OURRO_MISSION_RESULT` | mission file / result file for a mission-mode instance (set by spawn) | unset |
| `OURRO_LOOP_ROOT` | durable loop state dir | `/tmp/ourro-loop` |
| `OURRO_LOOP_REPO` | repo the loop runs against | the checkout |
| `OURRO_LOOP_MODEL` | model alias for all spawned instances | `sonnet-4-6` |
| `OURRO_LOOP_DAILY_USD` | daily spend cap (pause till UTC midnight) | uncapped |
| `OURRO_LOOP_OPERATOR_MINUTES` | wall clock per operator mission run | 90 |

**Product env vars QA passes through** to spawned instances:
`OURRO_BEDROCK_API_KEY` / `AWS_BEARER_TOKEN_BEDROCK`, `OURRO_VERTEX_API_KEY` /
`GOOGLE_API_KEY` / `GEMINI_API_KEY`, `OURRO_MODEL`, `OURRO_PROVIDER`,
`OURRO_HOME`, `OURRO_WORKSPACE` — full table in the repo README.

Sandboxes live under `/tmp/ourro-qa/<session>/` with their own `$OURRO_HOME`
(`home/`) and workspace (`work/`) — QA never collides with your real
`~/.ourro`.

## Deploy (the always-on loop box)

`qa/deploy/` is the whole story: `Dockerfile` (one container: conductor +
spawned instances; the image build runs the supervisor build and the full
test suite as a Linux port gate), `docker-compose.yml`, `entrypoint.sh`
(`run|once|status|shell`), `user-data.sh` (EC2 bootstrap: Docker, `/data`
EBS volume, clone, compose up), `fetch-secrets.sh` (AWS SSM
`/ourro-loop/*` parameters → env file: `bedrock-api-key`, `vertex-api-key`,
`model`, `daily-usd`, `gh-token`).

## Cleanup & troubleshooting

```sh
make qa-clean    # kill stray ourro-qa-* tmux sessions, sweep /tmp/ourro-qa + qa/reports
```

- Never `qa-clean` while a session you care about is running.
- `await-idle` timing out at spawn → `screen` anyway: the pane stays
  capturable after a crash (`remain-on-exit`) — the crash output is evidence.
- Don't type while waiting for a generation restart (needs >10s key silence
  + empty input line); ticker keys (`e`/`u`/`y`/`n`) fire only on an empty
  input line.
- The heartbeat's `:tick` is monotonic per process — alive pane + frozen tick
  = wedged UI loop (that's a finding).
