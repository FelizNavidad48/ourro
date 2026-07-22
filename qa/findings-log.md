# ourro — QA Findings Log

Running log of agent-driven QA sessions (hand-driving the live TUI via `qa/bin/ourro-qa`).
Newest session first. Findings are also filed as canonical sexp in `qa/findings/`.

---

## Session 2026-07-18 17:36–17:52Z — ship-a-cli-tool mission (live, gemini-3.1-pro-preview) — validates the F-outproc fix

Persona: Rūta, a mildly-technical writer wanting a `wordsmith` Node CLI (word/char
counts, reading time, cliché detector). Ran the full 9-phase arc. Purpose: exercise
heavy write→run repetition to see whether the just-landed **F-outproc fix** makes
autonomous evolution actually work.

**HEADLINE — F-outproc fix VALIDATED live (`F-evolived`, :info).** The write_file→shell
repetition mined → proposed `tool/write-and-shell` → 3 repair rounds → **:VERIFIED (a
real verdict, not the pre-fix 'no verdict')** → hot-loaded (13→14 genes) → snapshotted
**gen-0002** (:good, image built). The evolved tool was then **actually used** in the
next turn. Independently confirmed via ledger/images/`/tools`. This is the exact path
that grew 0 genes in the prior sales-data session — now the complete lifecycle works.

**The next problem it exposed — `F-generedup` (P2).** Having proven it CAN grow a
useful tool, the same session grew **near-duplicates**: `tool/write-and-shell`
(gen-0002) AND `tool/write-and-run` (gen-0003), both hot-loaded, plus
`tool/write-and-run-commands` verified & rate-limited in the queue — three
functionally-identical write-then-run tools. The duplicate-detector catches "already
covered by shell" but never recognizes a new write+run gene as duplicating one
hot-loaded earlier THIS session. Redundant proliferation was previously masked because
nothing grew at all.

**Product correctness — all baseline-quality, verified independently:**
- Phase 1–2: counts exact (269 words / 1534 chars vs my `wc`), both planted clichés
  found; nitpick round landed `~1½ min` (real ½ symbol) + correct line numbers (1, 5).
- Phase 3: custom `wordsmith.json` + `--no-defaults` precedence correct (2 → 1 cliché).
- Phase 4: `node:test` suite is REAL — my off-by-one (`idx+1`→`idx+2`) turned 2 tests
  red; revert restored 4/4 green.
- Phase 5: markdown-awareness correct (61 → 45 reader-words; strips `#`/URLs/code but
  keeps cliché line numbers mapping to the original — good correction retention).
- Phase 6: `--json` valid + jq-pipeable (keys `wordCount`/`readingTimeRaw`/… —
  descriptive, raw+formatted split is thoughtful).
- Phase 8: honest publish advice (named write-good/alex/proselint competitors,
  flagged name-squatting, real tradeoffs — not a tutorial dump).
- Phase 9: full surface clean — `--help` exit 0, missing-file clear msg + exit 1,
  `--json|jq` valid, `--no-defaults` correct.

**`F-pkgclaim` (P3):** phase-7 packaging avoided global pollution correctly (P1 clean,
package.json wired) BUT the agent falsely claimed `npm install` created
`node_modules/.bin/wordsmith` — no node_modules exists; its "Classic Way"
(`PATH=./node_modules/.bin`) instruction fails command-not-found (only `npx` works). A
trust-the-transcript failure — reported a filesystem state it never checked.

**Invariants:** clean. 0 crashes, tick advanced 12→1051, no probation-revert/
snapshot-failed, agent's own sandbox hygiene good (no `-g` install, no node_modules
leak). NOTE: the live process stayed on gen-0001 (probation genes hot-loaded in-image)
rather than seamlessly restarting into gen-0003 — observation, not confirmed a bug.

**QA-hygiene note (my own, not the agent):** running `npx wordsmith` during phase-7
verification made npx cache the local package (name `wordsmith-cli`) into the real
`~/.npm/_npx/…` — a transient escape from the sandbox that *I* caused, now cleaned up.
Lesson: QA verification of npm/npx packaging must itself stay sandbox-scoped.

Findings filed: `F-evolived` (info+), `F-generedup` (p2), `F-pkgclaim` (p3). Evidence:
`qa/reports/ourro-qa-3993374213-31059/evidence/` (`evolution-hotload-success/`,
`redundant-gene-growth/`, `final/`).

---

## Session 2026-07-18 12:24–12:36Z — sales-data-analysis mission, full 8-phase arc (live, gemini-3.1-pro-preview via Vertex/ADC)

Persona: Priya, ops manager at Lumen Candle Co., a "spreadsheets not code" user
with a planted double-ingest anomaly in `sales_2025.csv`. Ran the mission
end-to-end (spawn `--fixture qa/fixtures/salesdata` → 8 user turns → teardown).
Ground truth computed independently up front (March raw 5025.8 → dedup 4227.2,
inflation 798.6; 8 dup order_ids March 8–14; June refunds total −$64).

**The analytical work was flawless — Claude-Code-baseline across every phase**
(→ `F-dataflow`, :info). Verified independently, not from the transcript:
- Found the planted duplicate in **one** nudge; corrected March = $4,227.20 (exact),
  inflation ~$800 (exact).
- Deduped the CSV to exactly 8 rows removed, 0 remaining dups, June refunds + all
  other months intact (my re-read confirmed 228 rows).
- Profit-by-product join correct **to the cent** for all 5 products incl. margins.
- Charts: `monthly_turnover.png` image-verified to plot the corrected $4,227 March bar.
- Phase-6 "call it turnover not revenue" correction **propagated** to the phases-7/8
  report (turnover 10×, revenue 0×) with no re-prompting.
- Phase-8 adversarial "June down because of refunds" → pushed back with numbers
  (−$64 only), did not cave.

**Autonomous evolution: the miner's judgment is healthy but the out-of-process
verifier is broken this session.**
- POSITIVE (`F-minerjudge`, :info): miner correctly declined 2 mined patterns as
  `:DUPLICATE` ("already covered by tool shell / write_file") — no noise genes.
- **P2 (`F-outproc`)**: all **3 of 3** genuinely-mined gene candidates (incl. a
  sensible `tool/write-and-run`) were `:REJECTED` at the OUT-OF-PROCESS stage with the
  identical content-free diagnostic *"verification child returned no single valid
  verdict; candidate was not loaded."* Deterministic — inspector `r` (retry)
  reproduced it verbatim. Net: **0 genes grew** in the exact workload meant to
  exercise gene-growth; genome stayed at 13. Core thesis didn't deliver this session.
- **P3 (`F-evojargon`)**: that raw internal error was surfaced verbatim to the
  foreground ticker and inspector detail — meaningless jargon for the persona; the
  inspector list row shows only `✗ (no gene)`.

**Invariants**: clean. 0 crashes in supervisor.log, tick advanced 12→828, gen stayed
gen-0001 (no successful evolution → no restart, expected), no sandbox escape, HUD made
no false Σ savings claim (honest — nothing evolved). ctrl-e inspector opened fine
(F-ctrle stays fixed). Total session cost $0.84.

Findings filed: `F-outproc` (p2), `F-evojargon` (p3), `F-dataflow` (info+),
`F-minerjudge` (info+). Evidence: `qa/reports/ourro-qa-3993366264-51930/evidence/`
(`evolution-verify-fail/`, `final/`).

### Fixes landed same session (2026-07-18, all verified live + make test 1405/0)

- **F-outproc (P2) FIXED** — root cause: the macOS `sandbox-exec` wrapper in
  `verify-out-of-process` (`src/evolve/engine.lisp`) built its seatbelt profile
  from only `deny` clauses. A version-1 profile with no base default is
  **deny-all**, which denies `process-exec` itself → `sandbox-exec: execvp() …
  Operation not permitted` → child never runs → no verdict → every mined gene
  rejected. Since `/usr/bin/sandbox-exec` exists on macOS the code *always* took
  this branch. Fix: profile now opens with `(allow default)` and keeps `(deny
  network*)` (the durable protection — gene test code can't phone home); dropped
  the fragile file-write jail (the child's compiler scratch ignores the injected
  `TMPDIR`, so the jail silently broke the compile stage). Added a **fallback**:
  if the wrapper can't launch the child, retry unwrapped so a broken OS-sandbox
  layer can't silently veto all evolution. Proven: previously-failing
  `write-and-run` gene now yields a real `:FAIL :STAGE :TEST` verdict;
  known-good gene → `:PASS` via both sandboxed + fallback paths; a live proposal
  ran the full gauntlet across 4 repair rounds.
- **F-evojargon (P3) FIXED** — `:gave-up` ticker no longer dumps raw internals;
  now "couldn't verify a new tool this time — skipped it (ctrl-e for details)"
  (`src/agent.lisp`). Inspector rejected-row shows the intended gene name
  ("tool/write-and-run (not installed)") instead of "(no gene)"
  (`src/inspector.lisp`, `inspector-intended-name`). Full diagnostic preserved
  in the ctrl-e detail pane. Both verified live.
- **F-capvhint (P3) FIXED** — a test-stage `CAPABILITY-VIOLATION` for a
  *declared-but-withheld* cap read "requires undeclared capability :SUBPROCESS"
  (misleading — the gene declared it; verification withholds :subprocess/:network
  observationally). Named `*test-capability-ceiling*` + `withheld-capability-hint`
  (`src/verify/verifier.lisp`) now appends a hint steering the repair loop to fake
  the effect rather than re-declare. This unblocks the most valuable mined-tool
  class (subprocess/fs). Verified live in the verdict.

Regression tests added: `sandbox-exec-profile-permits-exec`,
`verify-out-of-process-degrades-when-wrapper-cannot-launch` (invisible-evolution),
`withheld-capability-test-adds-repair-hint` (verifier).

---

## Session 2026-07-16 19:54–20:07Z — 15-min adversarial robustness sprint (live Bedrock opus-4-6 → isolated on scripted)

**Operator:** Claude (qa-operator skill). Goal: a time-boxed harder QA pass, actively trying to break the product at the edges. Probes A–D passed; Probe E found a **P1**.

| probe | what I threw at it | result |
|-------|--------------------|--------|
| **A · typeahead** | several `say` queued before a turn finished | all queued work survived and ran in order ✓ |
| **B · cancel/resubmit** | `escape` mid-stream, then resubmit | clean cancel, tick kept advancing, resubmit ran ✓ |
| **C · crash-resume under load** | `chaos kill-agent` mid-turn with a sentinel `ZEBRA-99` in scrollback | seamless restart; `ZEBRA-99` survived the resume ✓ |
| **D · adversarial rendering** | emoji/CJK/double-width + raw control bytes pasted | 0 raw-control-char corruption; frame stayed well-formed ✓ |
| **E · slash-command fuzz** | `/travel` to a bad gen during a freeze/unfreeze race | **agent PANE DIED** — isolated below |

**NEW finding — [F-travel](../qa/findings/F-travel.sexp) (P1, supervisor):** `/travel` **kills the whole session**. Any `/travel` — reproduced on a **non-existent gen (`/travel 99999`, live Bedrock)** AND, when I isolated it, on the **valid current gen (`/travel 1`, free scripted)** — exits the agent process with code **0**, which the supervisor reads as a clean user quit (`supervisor.lisp:1042`) and shuts down. Pane dies `status 0`, heartbeat freezes (tick stops), no respawn, `supervisor.log` clean (no crash/quarantine), `events.sexp` ends at `COMMAND travel`. Time travel (M4-6) is **entirely non-functional** — not just for bad targets.

**Root cause:** `request-travel` (`agent.lisp:1485`) sends the `:handoff` notification and lets the run loop end, exiting **0** (`main.lisp:98`); it never sets `agent-pending-handoff`, so `perform-handoff` — the path that exits **75** — never runs. The supervisor's graceful *"handoff to unknown generation … rebooting current"* branch (`supervisor.lisp:1058`) and its whole handoff branch require code **75** (`supervisor.lisp:1047`), so they never run for `/travel`. Contrast: the evolution auto-restart path sets `agent-pending-handoff` → `perform-handoff` → exit 75, and works. **`/travel` is the only handoff initiator that exits 0.**

**Test-coverage gap (why it shipped):** tests cover travel's *components* — read-only ceiling (`robustness-test.lisp:219`), checkpoint non-clobber (`robustness-test.lisp:48`), supervisor honoring a deliberate quarantined `/travel` target (`supervisor-test.lisp:231-253`, which *assumes* code 75) — but **nothing exercises the full round-trip** (agent `/travel` → exit code → supervisor decision). That integration seam is exactly what live QA caught.

Filed, **not yet fixed** (15-min box exceeded; fix touches the agent↔supervisor exit-code contract — recommend a deliberate fix pass). Sandboxes swept.

---

## Session 2026-07-16 19:43–19:52Z — fix F-wsroot + rerun (live, gemini-3.1-pro)

Fixed the isolation gap found in the regression pass and re-ran the leaking workflow.

**[F-wsroot](../qa/findings/F-wsroot.sexp) → FIXED.** (product) `boot` (`src/main.lisp`) reads `OURRO_WORKSPACE` (else `getcwd`), mirroring `OURRO_HOME` — inherits through every seamless-restart spawn. (harness) `op-spawn` creates an isolated `<sandbox>/work/`, forwards `OURRO_WORKSPACE`, and starts the pane there (`tmux -c`), only for the supervised `:run` mode. `make test` 900 green, `make smoke` green, `bin/ourro` rebuilt.

**Verified live:**
- Fresh boot: agent `pwd` = the sandbox `work/` dir; the pane carries `OURRO_WORKSPACE=/tmp/ourro-qa/…/work/`.
- The **exact original leaking command** (`cd svc && node server.js & echo $! > server.pid`) wrote `server.pid` into the sandbox, **not** the repo root; a bare relative `ws-probe.txt` also stayed in the sandbox.
- Survives a **crash-resume**: after `chaos kill-agent`, the workspace was still the sandbox (`after-restart.txt` landed there).
- Re-ran a full-stack build (Express :4802 + Next.js :3012, backgrounded servers): both up, F-bgshell/F-worknil still hold, and **zero leaks** — no `*.pid`, `board-api/`, or `tasks.json` at the repo root.

Invariants held; sandbox + servers swept. **0 open findings.**

---

## Session 2026-07-16 19:12–19:35Z — regression: re-run the original pre-fix workflows (live, gemini-3.1-pro)

**Operator:** Claude (qa-operator skill). Goal: re-run the exact workflows that originally exposed each fixed finding and confirm they hold up. **All six hold.** One NEW finding surfaced.

| finding | original workflow re-run | result |
|---------|--------------------------|--------|
| **F-ctrle** | press ctrl-e (was a dead no-op / acted as End) | `:OVERLAY T` — inspector opens ✓ |
| **F-keylit** | `key ctrl-w` (was typed as literal text) + an unknown name | `ctrl-w`→`C-w` sent, input stays empty; unknown name → `(:OK NIL …)` exit 1 ✓ |
| **F-bgshell** | full-stack build starting a backgrounded dev server | `node server.js &` returned in **3.3s**, `npm run dev` (long-lived) in **7.1s**; both servers up; turn ~50s, nothing hung (was 11+ min) ✓ |
| **F-worknil** | poll the status line during the busy build | clean `⠹ working…` throughout, no `NIL` ✓ |
| **F-turncap** | large single-turn task exceeding 25 tool steps (20-function strict-TDD) | **triggered live**: `⚠ stopped after 25 tool steps — say "continue" to keep going.` + `:turn-capped :steps 25`; clean state; **"continue" resumed** and finished all 20 functions (verified: test suite green, `factorial(5)=120`, `gcd(12,18)=6`). Was: silent stop mid-task ✓ |
| **F-llmwedge** | large single-turn generations | completed normally under the 600s deadline; deadline mechanism separately proven live last session (30s trip) ✓ |

Invariants held (header, 0 log error markers, no error events). Both full-stack builds + the miniblog + mathlib apps built and independently verified.

**NEW finding — [F-wsroot](../qa/findings/F-wsroot.sexp) (P2, harness/isolation):** the QA-spawned agent's `*workspace*` is `(uiop:getcwd)` and `op-spawn` sets no start-directory, so the **agent-under-test's workspace is the real ourro repo root** — not the sandbox. It only stays in the sandbox because tasks use absolute `/tmp/ourro-qa/…` paths; a relative write escapes into the product repo (observed twice now: stray `server.pid`/`frontend.pid` at the repo root, from `echo $! > server.pid` running in the un-cd'd foreground shell). OURRO_HOME is isolated but the workspace isn't. Fix: `op-spawn` should root the agent in an isolated work dir (tmux `new-session -c <sandbox/work>` or `cd <work> && <ourro> run`, plus an optional `OURRO_WORKSPACE` override). Filed, not yet fixed.

---

## Session 2026-07-16 18:25–18:45Z — realistic dev workflow on **Bedrock (Claude Opus 4.6)**

**Operator:** Claude (qa-operator skill). **Tier:** live, **`opus-4-6`** (`eu.anthropic.claude-opus-4-6-v1`), Bedrock, region eu-north-1. Credential lives in the user's `~/.zshrc` (my non-interactive shell doesn't source it, so I spawned under a login shell; also added `OURRO_MAX_STREAM_SECONDS`/`OURRO_THINKING_LEVEL`/`OURRO_MAX_TOKENS` to the operator's env-forward allowlist).

**No ourro product findings.** The product behaved correctly throughout, including under heavy provider throttling. The one flaw surfaced was in the *agent's output*, which the agent then fixed when flagged — see Phase 3.

**A realistic 3-phase feature-development workflow (all claims independently verified by my own curls, DB reads, and running the agent's own test suite):**

1. **Build to a ticket (EXP-1)** — a SQLite (`node:sqlite`) expense API: versioned migrations table, **integer-cents money via string parsing** (not `Math.round(x*100)` — `12.99`→1299, `12.9`→1290 padding correct, verified in the DB as `typeof=integer`), a single-query GROUP BY summary (total matched my independent `SUM` exactly), transactional writes, validation (non-positive/blank/bad-date → 400), and a `node:test` suite. git-tracked.
2. **Reviewer change requests** — (CR-1) `POST /expenses/bulk` **all-or-nothing in one transaction**: a 3-item batch with an invalid #2 → 400 `{index:1}` and **row count unchanged** (rollback verified); happy batch → 201. (CR-2) `Idempotency-Key` persisted in an `idempotency_keys` table — held under **10 concurrent same-key POSTs → 1 row**.
3. **Debugging challenge (real quality flaw in the agent's output)** — its test suite hit the live server (`BASE=localhost:4900`) instead of an isolated instance, so it passed on a fresh DB but **30/32 with 2 failures** once the shared DB had my verification data. Given only the symptom, the agent root-caused the isolation problem and fixed it the *clean* way — extracted a `createApp(db)` factory, injected a fresh `:memory:` DB on an ephemeral port — explicitly avoiding the truncation-hook band-aid. Verified: **32/32 green twice** against the still-populated (76-row) environment.

**Observation (environmental, not a defect):** Bedrock threw **13× HTTP 429 "Too many requests"** across the session. The product handled it correctly every time — `complete-with-retry` backed off (retries 3/3), then surfaced a clean `provider error: Bedrock request failed (429): …`, ended the turn without wedging (tick kept advancing), and kept the conversation well-formed so the next turn resumed the work. A 429 sometimes cut a turn's closing summary/commit; the bounded 3-retry policy could be more generous for a heavily-throttled provider, but that's tuning, not a bug. Invariants held (header, 0 log error markers, no error events, no `:turn-capped`). Sandbox + expense server (4900) swept; user's tmux session untouched.

---

## Session 2026-07-16 18:09–18:25Z — F-llmwedge fix + harder workflows (live)

**Operator:** Claude (qa-operator skill). **Tier:** live, `gemini-3.1-pro`. Three sandboxes.

**Closed the last open finding and verified it live:**

| id | sev | fix | live verification |
|----|-----|-----|-------------------|
| [F-llmwedge](../qa/findings/F-llmwedge.sexp) | P3 | `vertex-provider` gained `stream-deadline-seconds` (default 600, env `OURRO_MAX_STREAM_SECONDS`); `complete()` computes an absolute deadline and `stream-json-objects` checks it each time `read-char` returns, signalling `stream-deadline-exceeded` → converted to a non-retryable `provider-error`. | spawned with `OURRO_MAX_STREAM_SECONDS=30` (added an env-forward to the operator), drove a >30s generation → turn ended at 31s with `provider error: model stream exceeded the 30 s deadline …`; `:BUSY NIL`, tick advancing, next turn returned `PONG`. Was: 12+ min hang. |

`make test` 900 checks green; `make smoke` green. New tests: `stream-deadline-aborts-once-passed`, `vertex-provider-has-a-stream-deadline`.

**Three harder workflows — every claim independently verified by my own curls; no new findings:**

1. **Multi-service system with graceful degradation** — users-svc (5001) + orders-svc (5002) + gateway (adapted to 5003 when macOS held 5000, and said so). Gateway aggregates over HTTP with a 1s downstream timeout. Verified: happy-path `totalSpent=200` (50+150), unknown user → real **404** (correctly distinguished from a downed service), and killing either downstream → HTTP **200 + `degraded:[…]`** with the surviving data (partial degradation), responding in 0.03s.
2. **Refactor-under-test (axios → native fetch)** — the trap: `fetch` doesn't throw on 404. The agent threaded a `{notFound:true}` sentinel through `Promise.all` so a downstream 404 still yields a gateway 404 while an unreachable service yields `degraded`, kept `AbortSignal.timeout(1000)`, and made the two fetches concurrent. Verified all four cases live incl. **users-svc down → `user:null` + `degraded:["users"]`** (not a 404/500). (Nit: left the now-unused `axios` in package.json.)
3. **Debugging challenge (planted type-coercion bug)** — I seeded a string-typed order amount so user 2's `totalSpent` came back `"20075"`. Given only the symptom, the agent root-caused the string-concatenation, fixed it robustly with `parseFloat` + `!isNaN` guard (not a one-record patch), and proved 275 / 200 numeric. Verified live.

Invariants held throughout (header, 0 log error markers, no error events, tick advancing). Evolver mined a pattern and correctly rejected it as `≡ already covered by tool write_file`. All three sandboxes + service processes (5001/5002/5003) swept, ports freed, user's tmux session untouched.

---

## Session 2026-07-16 16:56–17:45Z — fix-verification + hard full-stack builds (live)

**Operator:** Claude (qa-operator skill). **Tier:** live, `gemini-3.1-pro` (no Bedrock key,
so Claude aliases unavailable). **Two isolated sandboxes.** ~1h wall-clock.

**Fixed the four open findings from the prior session, then a fifth found mid-run** — all with
regression tests; `make test` 895 checks green, `make smoke` green:

| id | sev | fix | live verification |
|----|-----|-----|-------------------|
| [F-bgshell](../qa/findings/F-bgshell.sexp) | **P2** | `cap/run-program` drain stays non-blocking after child death (1s quiet grace) + deadline bounds every path incl. reap | `node hello.js … &` shell call returned in **2863ms** (was 11+ min); server answered on :4830 |
| [F-worknil](../qa/findings/F-worknil.sexp) | P4 | statusbar joins non-nil spinner/activity with `·`, never prints raw NIL | polled status row through two busy turns — clean `⠹ working…`, no NIL |
| [F-ctrle](../qa/findings/F-ctrle.sexp) | **P2** | dropped `(5 :end)` special-case so byte 5 → `:ctrl-e`; keymap binding fires | ctrl-e → `:OVERLAY T` (inspector opens) in both sandboxes |
| [F-keylit](../qa/findings/F-keylit.sexp) | P3 | `normalize-key` covers all ctrl-a..z / fN / pgup-pgdn / etc. and returns NIL for unknown; `op-key` refuses with exit 1 | `key totally-bogus` → `(:OK NIL … exit 1)`; `ctrl-z`→`C-z`, `pgup`→`PageUp` accepted |
| [F-turncap](../qa/findings/F-turncap.sexp) | **P2** *(new)* | turn hitting `*max-tool-iterations*` (25) now emits `⚠ stopped after N tool steps — say "continue"…` + `:turn-capped` event instead of ending silently | deterministic unit test (live-forcing 25+ dependent calls is impractical — capable models refuse tedious loops) |

**New finding, filed not fixed:**

| id | sev | area | one-liner |
|----|-----|------|-----------|
| [F-llmwedge](../qa/findings/F-llmwedge.sexp) | P3 | perf | A slow/stalled provider stream kept a turn `:BUSY` **12+ min** past the nominal 300s read-timeout. `vertex` sets only a per-socket-read timeout (any dribble resets it); `stream-json-objects` has no overall wall-clock deadline. UI tick kept advancing (not wedged); `escape` cancelled cleanly. Fix deferred — it touches the hot LLM path and needs a slow-stream test. |

**Agent behaviour (live, independently verified by my own curls):** built working full-stack apps
(Express + Next.js) confined to the sandbox; a false "parallel POSTs lose data" premise was
correctly rejected — the agent ran 40 parallel POSTs, explained why my race theory was wrong,
found the real `Date.now()` ID-collision bug itself, fixed it with `randomUUID()`, and re-proved
it. Iteration (PATCH, pagination, `X-Total-Count`, edit page, related-entries ranking) all passed
my own checks. A second concurrency task got a promise-mutex + per-write UUID temp files; my own
50-parallel burst landed exactly 50/50. Applied an evolution proposal (`tool/start-service`) via
the inspector → seamless gen-0001→gen-0002 restart with full context continuity; the agent then
used the new tool. Escape-cancel recovery clean (incl. the stalled stream). Header + clean-log +
tick invariants held throughout; both sandboxes + orphan node servers swept, ports freed.

**Minor, not filed:** the agent used `echo -n 0 > count.txt` (non-portable — `/bin/sh`'s echo
wrote the literal `-n 0`); that's the agent's own shell-portability slip, not a product defect.

---

## Session 2026-07-15 21:39–21:55Z — fix-verification + exploration (round 2)

**Operator:** Claude (qa-operator skill). **Tier:** scripted, one isolated sandbox. **Cost:** $0.
Fresh `spawn` (its `init` rebuilds the gen image from source) picked up the F-onbfrz/F-toolind agent-side fixes.

**Two newest fixes verified FIXED live:**
- **F-toolind** — resized the pane to 62 cols to force wrapping; `/tools` descriptions now hang-indent under the
  tool name (`edit_file … Replace OLD-STRING with` / `   NEW-STRING in PATH …`) instead of drifting to the margin.
- **F-onbfrz** — `/freeze` then `/onboard`: probes still run (`✓ make test`, `✓ make smoke`), then one clear line —
  *"evolution is frozen — probed your toolchain but skipped growing 2 genes (repo/test repo/smoke). /unfreeze, then
  /onboard again to grow them."* — no cryptic "could not grow" spam. The non-frozen path still *attempts* growth
  (churns proposals, shows "could not grow" when the scripted junk fails verification), confirming the branch is correct.

**New findings (2):**

| id | sev | area | one-liner |
|----|-----|------|-----------|
| [F-ctrle](../qa/findings/F-ctrle.sexp) | **P2** | tui | **ctrl-e never opens the evolution inspector.** The key decoder maps byte 5 → `:end` (readline idiom) *before* the `:ctrl-e` keymap binding can fire (`term.lisp:258`), so the advertised "ctrl-e evolutions" affordance (in `/help`, the primer, and the arrival ticker) is dead code. The inspector is only reachable via `/evolutions` (verified working) or the ticker `e`. ctrl-o is unaffected (falls through to `:ctrl-o`). |
| [F-keylit](../qa/findings/F-keylit.sexp) | P3 | harness | `ourro-qa key <name>` sends an unrecognized name (ctrl-w, ctrl-a, ctrl-k, short pgup/pgdn) as **literal text**, silently corrupting the pane's input, instead of erroring. `*key-aliases*` only covers ctrl-e/o/c/u + a few named keys. Bit me this session (stray text turned a later `/evolutions` into chat). Product decoder itself is fine (raw `tmux send-keys C-w`/`C-a` verified correct). |

**Also exercised, no new defects:** `/tools` at narrow width; tab completion (`/gen`→`/genome`); `/mouse` ON/OFF;
`/keep` (usage) and `/revert` ("nothing to revert") empty states; rapid `/freeze`↔`/unfreeze` ×3 (mode stayed
consistent); F2 correctly a no-op (F-row keys deliberately unbound); inspector empty-state via `/evolutions`
(`no evolutions yet …`, `q` closes); product line-editing via raw bytes (C-w deletes a word, C-a home); 200-char
no-space input; scroll keys; header row-0 + clean logs + live `:tick` throughout. Sandbox collected & killed; env clean.

---

## Session 2026-07-15 08:42–09:00Z — fix-verification + exploration

**Operator:** Claude (qa-operator skill). **Tier:** scripted, isolated sandboxes. **Cost:** $0.
Rebuilt `bin/ourro` (`make supervisor`) so the supervisor fix ships; `spawn`'s `init` rebuilds the
gen image from source, so the agent/handoff/heartbeat fixes ship automatically.

**All four prior findings verified FIXED end-to-end on a live `bin/ourro run`:**

| id | live verification |
|----|-------------------|
| F-frzresm (P2) | `/freeze` → heartbeat `:FROZEN T` + `❄frozen`; `chaos kill-agent` (SIGKILL); after crash-resume the **new pid** still reports `:FROZEN T` and header `❄frozen` (was `◆auto` before). `/unfreeze` post-resume → `:FROZEN NIL`; a turn completes cleanly (ZEBRA-42 context intact). Re-confirmed on a second freshly-built image after the visiting-guard follow-up. |
| F-arg7f2 (P2) | `say --session S "/freeze"` (flag **before** message) → `:SAID "/freeze"` and the agent froze (was `:SAID ""`). A message with an embedded `--verbose` token (single quoted arg) delivered intact. |
| F-genchg (P3) | `await-generation-change` with **no** `--from` → `:GENERATION-CHANGED T :TO "gen-0001"` across a same-generation crash-resume (previously timed out). |
| F-crshmsg (P3) | Drove the supervisor to give up (crash #2 in-window quarantines the sole gen). Final pane: `[ourro] fatal: no good generation left` on its **own clean line**, no `shift+enter`/placeholder collision (was `…leftft+enter newline)`). |

**Follow-up fix found by self-review this session:** `restore-session` now guards the freeze restore with
`(unless (agent-visiting agent) …)` — a read-only time-travel (visiting) session boots `:manual` and must not
have its mode overwritten to `:auto` (evolution is blocked for a visitor regardless, but the symmetry mirrors
`checkpoint-session` skipping visiting). New test `restore-session-leaves-a-visiting-session-manual`. Suite: 858 checks, 0 fail.

**Two previously-unfiled cosmetic items now filed AND fixed** (see 06:15 session's "Unconfirmed / cosmetic"):
- [F-onbfrz](../qa/findings/F-onbfrz.sexp) (P3) — `/onboard` while frozen printed cryptic "could not grow &lt;gene&gt;"
  per pattern (and spent an LLM call on each doomed proposal). `onboard-grow` now has a frozen branch: it skips the
  grow loop, explains the freeze once, and suggests `/unfreeze`. Test: `onboard-grow-while-frozen-explains-instead-of-growing`.
- [F-toolind](../qa/findings/F-toolind.sexp) (P4) — a wrapped `/tools` description dropped its continuation lines to
  the margin. `wrapped-lines`/`add-wrapped` gained an opt-in `:hang` indent (additive, no other caller affected);
  `cmd-tools` uses `:hang "  "`. Test: `wrapped-lines-hang-indents-continuation-lines`. Suite now 868 checks, 0 fail.

**Also exercised, no new defects:** `:frozen` heartbeat field tracks `/freeze`↔`/unfreeze` live; `/travel` bad/empty
arg (clean "not a generation number" + usage); `/out 999` out-of-range (clean "no tool calls yet" empty-state pager);
multiline paste (buffers without auto-submit); 5-message rapid typeahead (6/6 user-message==turn-done, queue drained);
up-arrow history recall; header row-0 invariant + clean logs throughout. All sandboxes collected & killed; env clean.

---

## Session 2026-07-15 06:15–06:29Z — 30-min exploratory sweep

**Operator:** Claude (qa-operator skill). **Tier:** scripted (free/deterministic), isolated sandboxes,
evolver frozen except where noted. **Cost:** $0 (scripted; 0 live model calls). Live-tier evolution/gauntlet
testing was left out to avoid spend without explicit budget — worth a follow-up run.

**Sandboxes:** `ourro-qa-…-52462` (core + crash), `ourro-qa-…-60370` (feature coverage). Both collected & killed;
no stray sessions. Evidence under `qa/reports/<sandbox>/evidence/`.

### Findings (3 new this session, all filed in qa/findings/)

> **Update 2026-07-15 — all four findings below are now FIXED** (code + regression tests landed;
> `make test` green, `make smoke` green). Each `.sexp` carries a `:resolution` and `:status :fixed`.
> Fix summary at the end of this session block.

| id | sev | area | one-liner | status |
|----|-----|------|-----------|--------|
| [F-frzresm](../qa/findings/F-frzresm.sexp) | **P2** | evolution / supervisor | Freeze state is not persisted across a crash-resume — the agent silently thaws (auto-evolution re-enabled). | ✅ fixed |
| [F-genchg](../qa/findings/F-genchg.sexp) | P3 | harness (`ourro-qa`) | `await-generation-change` can never detect a same-generation crash-resume; its predicate requires `:generation` to change, contradicting its "keys on `:pid`" docstring. | ✅ fixed |
| [F-crshmsg](../qa/findings/F-crshmsg.sexp) | P3 | supervisor / tui | On crash-loop giveup, `[ourro] fatal: no good generation left` renders garbled over the input-line hint (`…leftft+enter newline)`). | ✅ fixed |

Carried over from the 2026-07-15 05:4xZ session: [F-arg7f2](../qa/findings/F-arg7f2.sexp) (P2) — `ourro-qa`
drops the positional message when a `--flag` precedes it (`say --session X "msg"` → silent `:SAID ""`). ✅ **fixed.**

#### F-frzresm (P2) — freeze lost across crash-resume  ← highest priority
Froze evolution (`❄frozen`), took a turn, SIGKILLed the agent. The supervisor correctly resumed the session
(new pid, token + scrollback intact) **but came back as `◆auto`** — re-issuing `/freeze` printed a *fresh*
"evolution frozen" confirmation, proving the state was gone. Root cause: freeze lives only in the special var
`ourro.kernel:*evolution-frozen*` / `agent-mode` (src/agent.lisp:1334-1336); **no checkpoint/resume code in
`src/` serializes it**, so a fresh image defaults it to nil. `/freeze` is in `*checkpoint-worthy-commands*`
(agent.lisp:1218) — the intent is durability — but the checkpoint payload never actually captures the flag.
Impact is both product-safety (a crash silently re-enables self-modification the user disabled) and a
QA-harness hazard (a frozen scripted scenario that crash-resumes wakes the evolver, which can then eat the
scripted responses meant for user turns).

#### F-genchg (P3) — await-generation-change blind to crash-resume
`await-generation-change --from <pid>` timed out for 40s while the restart had plainly happened (`await-idle`
immediately after showed the new pid). The predicate (operator.lisp:540-545) defaults `from` to the current
generation and then requires `generation != from`; a crash-resume keeps `gen-0001`, so it can never fire, and
there's no flag to anchor on the old pid. The chaos scenario already papers over this with `:optional t`.
Workaround for operators: detect crash-resume with `await-idle` + a pid comparison.

#### F-crshmsg (P3) — garbled crash-loop giveup frame
Killing the agent ~4× faster than the crash-window resets drove the supervisor to stop resuming after ~2
in-window crashes, print `[ourro] fatal: no good generation left`, and exit (tmux pane dies, status 70).
Giving up on a persistently-crashing *sole* generation is reasonable, but the fatal string is written at the
input-prompt row and collides with the `(… shift+enter newline)` placeholder → `…leftft+enter newline)`. The
last frame the user sees is corrupted. (No `checkpoint-poisoned.sexp` was written on giveup — noted, not judged.)

### Areas exercised & PASSED (no defect)

- **Core turn loop** — chat turns render correctly; user-message/turn-done events balanced throughout.
- **Tool calls** — `list_files` executes, logs `:tool-call` (gene `tool/list-files`, `:outcome :ok`); full-output
  overlay opens via ctrl-o and **closes via `q`** (the "won't close" reading in the prior session was
  cross-session contamination, re-verified clean here).
- **Slash commands** — `/genome`, `/tools` (well-formed "live tools (11)" list), `/log`, `/travel` (helpful usage
  string), `/mouse` (clear ON/OFF toggle messaging), `/out` (clean "no tool calls yet" empty state), F2 inspector
  ("no evolutions yet" empty state), unknown commands (`unknown command: /x (try /help)`). All render cleanly.
- **Crash-resume (single)** — supervisor catches exit 137, logs "crash #1 in window / resuming session from crash
  checkpoint", resurrects the agent; memory token (ZEBRA-42) + scrollback survive; **F-1 event-continuity holds**
  (post-restart turns still log `:turn-done`, new session log keeps appending); clean recovery banner shown.
- **Input edge cases** — multiline paste buffers correctly and submits as one message with embedded newlines;
  emoji + CJK (`😀🎉 日本語`) render without corruption; whitespace-only input is correctly dropped (no turn);
  240-char single-line input recorded intact.
- **Typeahead / queue** — 3-message and 10-message rapid bursts (no awaits between) all processed in order;
  user-message and turn-done counts stayed balanced (14/14); queue drained to 0.
- **/onboard** — actually probes the repo, runs `make test` (exit 0, 9.0s) and `make smoke` (exit 0, 0.6s). It
  reported "could not grow repo/test/smoke" — expected while frozen (can't create genes), though the freeze
  reason isn't surfaced to the user (minor UX nit, not filed).
- **Resize** — pane reflow to 80×24 keeps the header at row 0, no corruption.
- **Standing invariants** — header row present every settled frame; agent-output/supervisor logs free of
  `backtrace|fatal|unhandled`; no unexpected `:turn-hook-error/:dream-error/:probation-revert/:snapshot-failed`.

### Unconfirmed / cosmetic (not filed)

- **/tools indentation** — some tool rows render flush-left, others 3-space-indented, but word-wrap of long
  descriptions is active in the same view so I couldn't cleanly attribute it. Worth a glance if touching that view.
- **/onboard-while-frozen** — probes run but gene-growth fails with a cryptic "could not grow repo/test"; surfacing
  "(evolution frozen)" as the reason would be clearer.

### Fixes landed (2026-07-15, follow-up to the sweep)

- **F-frzresm** — freeze is now durable across restarts. `handoff-plist` gained a `:frozen` key
  (`src/kernel/handoff.lisp`); `session-payload` writes `*evolution-frozen*` into it; `restore-session`
  re-applies it through a new shared `set-evolution-frozen` helper (also backing `/freeze` + `/unfreeze`).
  The QA heartbeat now exposes `:frozen` (`collect-qa-status-fields`) so an operator can assert it directly.
  Tests: `handoff-test.lisp` freeze-survives-handoff-roundtrip / restore-session-reapplies-freeze /
  restore-session-thaws-when-payload-not-frozen.
- **F-arg7f2** — `positionals` (`qa/src/operator.lisp`) now collects every non-flag token and skips each
  `--flag` plus its value (unless the flag is in the new `*boolean-flags*` set), so a message after a flag
  survives. Tests: `qa-runner-test.lisp` positionals-collects-message-after-a-flag / -boolean-flags-take-no-value.
- **F-genchg** — `op-await-generation-change` no longer defaults `from` to the current generation; with
  `--from` omitted it fires on any new `:pid` (so a same-generation crash-resume is detected). Pass
  `--from <generation>` only when you also require leaving a specific generation.
- **F-crshmsg** — the supervisor's fatal handler now calls `restore-terminal-after-agent` before printing,
  leaving the TUI's alt-screen and resetting the cursor/attrs so the giveup message lands on a clean line
  (no-op when output isn't a terminal).

### Notes for the next operator
- Message-before-flags is no longer required (F-arg7f2 fixed), but still pass `--session NAME` to pin the
  sandbox. Either ordering now delivers the message.
- Don't hand-drive while `make qa-run/qa-test/qa-soak` runs: bare subcommands hijack the newest sandbox and
  `qa-clean` deletes yours.
- `await-generation-change` now works for crash-resume (F-genchg fixed) — no `--from` needed; it fires on the
  new pid. `await-idle` + pid compare still works as a belt-and-suspenders check.
- To verify F-frzresm end-to-end: `/freeze`, `chaos kill-agent`, `await-idle`, then `state` — the heartbeat's
  `:frozen` should still be `T` after the resume.

### legacy-rescue: successful run
All beats completed smoothly. Agent fixed the missing qty in total_value, found the restock bug and test gap, safely refactored the copy-pasted table code, added the CSV shop command, and appropriately solved the concurrency issue using temp files and lockfiles. Explanations were wonderfully jargon-free.
