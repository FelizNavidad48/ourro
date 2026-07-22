# ourro Technical Review — Quality Control

> Historical review, assessed at the cutoff below. The remediation described in
> “Implementation status” landed afterward; findings are retained as the threat
> model and rationale for the regression tests.

## Executive assessment

ourro has a compelling architecture and unusually broad implementation, but
its strongest guarantees are not currently true end to end. Capability isolation
is bypassable, verification executes untrusted code without real containment,
rollback is incomplete, and supervised background evolution is effectively
disconnected. Autonomous mined reflexes should not be enabled until these
foundations are corrected.

## Implementation status — 2026-07-18

The quality-control pass is implemented. The design remains Lisp-native: the
positive grammar is checked as S-expressions, rollback uses CLOS redefinition
and the MOP, state is readable data, and conditions—not hidden exception
translation—carry failures across the system.

| Finding | Status | Landed control |
|---|---|---|
| 1 capability boundary | Resolved | Positive `OURRO.API` callable boundary; dynamic invocation/raw registry access rejected; nested grants attenuate; explicit empty grants stay empty. |
| 2 verifier containment | Resolved for production | Built generations always verify in a child with isolated home/workspace, denied network/host writes on macOS, a restricted capability ceiling, bounded runtime, and fail-closed results. `make dev` deliberately retains the in-process verifier as a developer seam. |
| 3 PASS spoofing | Resolved | Exactly one complete, single-form verdict frame is accepted; duplicates, trailing data, child failure, and missing verdicts reject. |
| 4 install transaction | Resolved | One undo frame per gene version restores functions, methods, variables, standard classes through `ENSURE-CLASS`, tools, registry state, and owner-scoped automations. Snapshot publication waits for successful live probation; failure cancels it. |
| 5 background evolution | Resolved | Heartbeat, evolver, and dreamer are named independently tracked workers. |
| 6 turn race | Resolved | The actor/UI event is the sole owner of busy→idle; workers enqueue completion without clearing shared turn state. |
| 7 parallel tools | Resolved | Exact authorized tool objects execute under a process-wide semaphore; cancellation destroys and joins workers; subprocess capture is bounded. |
| 8 handoff/recovery | Resolved | Handoff is acknowledged before checkpoint retirement, fallbacks retain the supplied state, frames are strict and bounded, and the supervisor recreates a failed listener. |
| 9 provider truncation | Resolved | Vertex and Bedrock require valid terminal metadata, complete JSON/tool arguments, and explicitly surface exception frames/EOF. |
| 10 build gates | Resolved | Replay evidence and package locking fail closed; kernel content identity is persisted in generation records instead of relying only on timestamps. |
| 11 job ownership | Resolved | Dedicated process groups, persisted start identity/PGID, identity revalidation, group termination, and idempotent restore exits. |
| 12 automations | Resolved | Versioned firing identity, armed-state rechecks, queue cancellation on disarm, joined worker shutdown, non-consuming sentinel reads, and staged consent. |
| 13 event data | Resolved | Schema/session/workspace fields, bounded hydration, key-aware recursive redaction, persistence health that disarms autonomy, success/error-separated utility, confidence, and workspace-isolated mining. |
| 14 QA oracle | Resolved | Missing evidence fails assertions, chaos milestones are mandatory, ledger parsing follows the real schema, compiler warnings were removed, and clean CI runs the four gates. |
| 15 public status | Resolved | Stale exports and the skill path were corrected; this status table and the roadmap are the dated implementation record. |

Validation after remediation: `make test` passes **1,324 checks** with no
compiler warnings; `make smoke` reports 15 tools/13 genes; `make qa-test` passes
all three scripted scenarios; and `make verify-e2e` passes **29/29** assertions.

## Review basis and implementation status

This review covers the living agent, supervisor, genome/verifier/evolver,
providers, jobs, TUI, observation/mining, QA infrastructure, seed genes, scripts,
tests, and documentation.

The working tree changed concurrently during review. The reproducible review
cutoff is **2026-07-18 13:24:52 EEST**. M14 reaction-miner edits began after that
cutoff and are not treated as reviewed implementation. Later work visible in the
tree, including M15 files, is likewise outside this report's assessed snapshot.

At the cutoff:

- M9–M12 functionality—jobs, parallel tools, context management, recovery,
  Bedrock, and invisible evolution—was broadly present.
- Most of M13's substrate had appeared: the event bus, automation registry,
  bounded worker, trigger matching, `/arm`/`/disarm`, notes, and
  `auto/job-sentinel`.
- M14's bless-once lifecycle and workspace memory, M15 investigations, and M16
  acceptance program were not integrated as described in
  [plan-reflexes.md](plan-reflexes.md).
- The principal execution path was TUI → turn worker → provider → tools → event
  log → turn-boundary miner → evolver → gauntlet → hot-load/probation → supervisor
  snapshot → generation handoff. Several findings below break that chain.

## Validation results

The following gates passed against the cutoff:

- `make test`: 1,105 checks, zero failures, with compiler warnings.
- `make smoke`: passed, reporting 15 tools and 12 genes.
- `make qa-test`: three scenarios passed.
- `make verify-e2e`: 28 assertions passed, including a locked built image.

These green results overstate confidence because multiple build gates and QA
assertions explicitly fail open.

## Findings

### 1. Critical — The capability boundary is bypassable

`deftool` converts an explicitly empty capability list into all capabilities,
while nested calls through exported `find-tool`/`run-tool` replace the caller's
grant with the callee's grant rather than intersecting them. See
[`call-instrumented`](../src/tools/protocol.lisp#L90),
[`deftool`](../src/tools/protocol.lisp#L269), and the public gene API in
[genome.lisp](../src/genome/genome.lisp#L83).

The blacklist walker is also escapable: a package-qualified
`CL:APROPOS-LIST`/`FIND`/`FUNCALL` expression can dynamically obtain
`CL:DELETE-FILE` without containing the forbidden symbol. Both that probe and a
no-capability nested-tool probe returned no violations from
[`lint-gene-body`](../src/kernel/walker.lisp#L175).

**Impact:** A verified read-only or no-capability gene can read, write, spawn
processes, or bypass visiting-mode restrictions.

**Recommended fix:** Replace blacklist safety with a positive callable-symbol
whitelist; prohibit non-whitelisted qualified symbols and dynamic function
designators; remove raw registry invocation from the gene API; intersect every
nested grant with the active grant; and add OS-level containment.

### 2. Critical — Verification is not hermetic

Candidates are compiled and sometimes loaded inside the live SBCL process. The
staged environment only copies selected registries in
[`with-staged-registries`](../src/verify/verifier.lisp#L218). Global functions,
generic-function methods, classes, turn hooks, jobs, queues, revert state, notes,
and other specials can survive a rejected candidate.

Even the out-of-process path is only a child running with the same user
privileges. Capability wrappers accept arbitrary absolute paths and can launch
persistent processes or network requests; the sandbox workspace is not a
filesystem jail. See [capabilities.lisp](../src/kernel/capabilities.lisp#L61).

**Impact:** Code that ultimately fails verification can still modify the live
agent or host.

**Recommended fix:** Make all candidate verification mandatory out-of-process
and fail-closed, using an isolated home/workspace, read-only project snapshot,
network denial, process-group cleanup, resource limits, and a strict top-level
grammar. Add residue tests comparing every live registry and hook before and
after rejected candidates.

### 3. Critical — A candidate can spoof an out-of-process PASS

[`parse-verify-verdict`](../src/evolve/engine.lisp#L56) reads the first
sentinel-shaped block from combined child stdout. Candidate top-level code can
print a fake PASS before
[`verify-gene-mode`](../src/main.lisp#L88) emits the real verdict. A direct parser
probe containing a fake PASS followed by a FAIL returned PASS.

Spawn or parse failures also fall back to in-process verification in
[`verify-mined-block`](../src/evolve/engine.lisp#L66).

**Impact:** Candidate output can bypass the gauntlet, while infrastructure
failure moves verification onto the live image.

**Recommended fix:** Return one authenticated verdict through a dedicated file
descriptor or nonce-bound result file, separate candidate stdout, require a
successful child exit, reject duplicate or malformed verdicts, and never fall
back to live verification.

### 4. Critical — Installation, rollback, probation, and snapshots are not one transaction

Method rollback records the old method and later removes that old object rather
than removing the newly installed method and restoring the previous one. Classes,
structures, variables, nested definitions, and parts of the gene registry have no
complete rollback. See
[`snapshot-gene-targets`](../src/genome/genome.lisp#L508) and
[`revert-record`](../src/kernel/revert.lisp#L48).

Revert records accumulate by gene name, so an A→B→C failure can replay both
frames and return to A. Hot-loading sets global gene context without guaranteed
cleanup, and [`apply-candidate`](../src/evolve/engine.lisp#L408) starts the durable
snapshot before probation concludes. A live probation revert does not invalidate
the built generation, manifest change, or pending handoff.

**Impact:** Rollback can leave a mixed runtime or resurrect a rejected gene after
restart.

**Recommended fix:** Create one versioned install transaction per candidate,
recording previous and newly installed objects. Atomically publish it, graduate
or undo exactly that version, and bind snapshot, ledger status, probation,
handoff, and durable quarantine to the same transaction ID.

### 5. High — Supervised background evolution is effectively disabled

[`spawn-evolver`](../src/agent.lisp#L1227) treats `agent-worker-threads` as a
single evolver slot. [`start-heartbeat`](../src/agent.lisp#L2841) places its
permanent heartbeat in that same list. After supervised startup, later mining
sees one live worker and never starts the evolver. Dreamer threads, meanwhile,
are created without being tracked in
[`spawn-dreamer`](../src/agent.lisp#L1417).

**Impact:** The core observe → mine → evolve differentiator works only in
boot-time or development edge cases, while other background work can overlap
uncontrolled.

**Recommended fix:** Introduce a named background scheduler with separate slots,
priorities, cancellation, and lifecycle state. Add a supervised test proving a
newly mined pattern drains while heartbeat and foreground turns are active.

### 6. High — Turn state has a race that can create concurrent turns

`process-turn` clears BUSY before enqueuing `:turn-done` in
[agent.lisp](../src/agent.lisp#L548). The UI processes keyboard input before
worker events in [`ui-loop`](../src/agent.lisp#L2510), so Enter can begin a new
turn in that gap. The stale completion then calls
[`on-turn-done`](../src/agent.lisp#L1010), clearing the new turn's BUSY state and
starting untracked boundary work.

**Impact:** Conversation, transcript, checkpoints, tools, and handoffs can be
mutated by multiple turns concurrently.

**Recommended fix:** Make one actor own turn state. Give every submission and
completion a turn epoch; only the matching completion may transition
active→idle. Capture an immutable boundary snapshot before the next turn starts.

### 7. High — Parallel tools are neither safely cancellable nor version-stable

Parallel execution abandons unfinished worker threads after cancellation in
[agent.lisp](../src/agent.lisp#L656), and its concurrency bound is batch-local.
Eligibility examines one tool object, but workers later look it up again in the
unlocked mutable registry at
[tools/protocol.lisp](../src/tools/protocol.lisp#L140), allowing a hot-load to
replace the implementation between authorization and execution.

Synchronous subprocess output is also accumulated without a byte limit in
[`cap/run-program`](../src/kernel/capabilities.lisp#L91).

**Impact:** Blocked evolved tools survive cancellation, repeated batches leak
resources, and an approved read-only call can execute a newly published effectful
implementation.

**Recommended fix:** Use a global bounded pool, execute the exact captured
versioned tool object, enforce deadlines and joined cancellation, atomically
publish immutable registry snapshots, and stream output into a bounded ring
buffer.

### 8. High — Handoff and supervisor recovery can lose the session

[`perform-handoff`](../src/agent.lisp#L2869) deletes the crash checkpoint before
the supervisor acknowledges the handoff. A missing connection still leads to
exit 75. For an unknown target or failed rebuild, the supervisor prints
"rebooting current" but does not preserve the supplied state file in
[supervisor.lisp](../src/supervisor.lisp#L1061).

The control server can also die permanently: disconnect clears the heartbeat
guard, accept failures terminate the listener, and no component restarts it.
Protocol framing accepts junk-suffixed, negative, and unbounded lengths in
[protocol.lisp](../src/kernel/protocol.lisp#L93).

**Impact:** Travel or generation advancement can cold-boot without the
conversation, and a broken control plane can leave a hung agent running
indefinitely.

**Recommended fix:** Use acknowledged, idempotent handoff requests; retain
recovery state until durable acceptance; resume it on every fallback; strictly
bound frames; and supervise and recreate the listener with a reconnect deadline.

### 9. High — Provider streams accept truncated responses as success

Bedrock ignores exception-frame headers and does not require `messageStop`; EOF
defaults to `end_turn` in
[bedrock.lisp](../src/llm/bedrock.lisp#L258). Vertex swallows malformed
JSON/callback errors, ignores an unfinished object at EOF, and defaults a missing
finish reason to `STOP` in
[vertex.lisp](../src/llm/vertex.lisp#L400).

**Impact:** Partial text or incomplete tool arguments can be accepted and
executed without retry or a visible provider failure.

**Recommended fix:** Treat both streams as strict protocol automata requiring
terminal events, complete tool arguments, and valid finish metadata. Map
provider exception frames explicitly and add EOF, truncation, and fault-injection
tests.

### 10. High — Hardened build gates fail open

Missing candidate replay output explicitly means "no divergence," and replay
infrastructure errors are skipped in
[`replay-gate`](../src/supervisor.lisp#L304). Kernel-change detection depends on
mutable timestamps rather than content identity.

Kernel package-lock failure only prints a warning in
[build-agent-image.lisp](../scripts/build-agent-image.lisp#L24), while smoke
merely reports the lock state.

**Impact:** An unverifiable or unlocked generation can still become good.

**Recommended fix:** When replay or locking is required, make unavailable
evidence fail the build. Persist source hashes, replay inputs, verdicts, and lock
status in the generation ledger, and add injected failure tests.

### 11. High — Jobs do not own process trees or durable process identity

Jobs launch through `sh -c`, record only a PID, and signal only that PID in
[jobs.lisp](../src/jobs.lisp#L192). Restore trusts `kill(pid, 0)`, so PID reuse can
attach to an unrelated process. Dead jobs found during restore bypass the normal
`mark-exited` event and hook path in
[`restore-jobs`](../src/jobs.lisp#L281).

**Impact:** Dev servers can survive `/quit`, unrelated processes can be displayed
or killed, and restart-gap failures never reach the job reflex.

**Recommended fix:** Use dedicated process groups, persist PGID plus start-time
and command identity, signal the entire group, reject identity mismatches, and
synthesize the ordinary exit transition exactly once during restoration.

### 12. High — The in-flight M13 reflex substrate is not yet a trustworthy killable unit

`/disarm` prevents new dispatch but queued and deferred firings remain executable
because [`run-firing`](../src/automation.lisp#L313) and
[`flush-deferred-automations`](../src/automation.lisp#L393) do not recheck the
armed state. Queued entries retain stale automation objects even after unregister
or revert. Same-name replacement removes the old automation, but its revert
action only removes the replacement in
[`register-automation`](../src/automation.lisp#L139).

The seed sentinel uses cursor-advancing `job-status`, consuming log output before
the model asks for it in
[job-sentinel.gene](../seed-genome/genes/auto/job-sentinel.gene#L12). Worker stop
does not join. Most importantly, verified candidates are still auto-applied
without the authoritative M14 bless-once lifecycle.

**Impact:** Actions can run after disarm or revert, replacements cannot be
restored correctly, and fixing the evolver could enable unapproved mined
reflexes.

**Recommended fix:** Version every firing and validate it immediately before
execution; make disarm cancel deferred and queued work and stop or join the
worker; restore previous same-name entries; use a non-destructive log peek; and
land reaction mining only behind a durable staged and approved lifecycle.

### 13. High — The learning data plane is neither durable nor trustworthy enough for autonomy

[`start-event-log`](../src/observe/events.lisp#L115) discards the in-memory
learning window on every generation restart despite retaining the disk log.
Redaction is value-substring based, so opaque secrets under sensitive keys can be
persisted, while append failures are swallowed.

Utility accounting counts failed calls as uses and includes their short durations
in "savings" in [ledger.lisp](../src/observe/ledger.lisp#L55).
Repeated-sequence mining uses tool names without argument, outcome, turn, or
workspace context in [miner.lisp](../src/observe/miner.lisp#L105).

**Impact:** Restarts erase evidence, secrets can enter durable memory, fast
failures can look valuable, and unrelated workflows can be merged.

**Recommended fix:** Build a workspace-scoped, schema-versioned event store with
bounded hydration, key-aware redaction, persistence health,
success/failure-separated utility, confidence, corrections, and context-aware
clustering.

### 14. High — The validation oracle has false-green paths

The chaos scenario does not require a successful kill, and generation change is
optional in
[chaos-crash-resume.sexp](../qa/scenarios/chaos-crash-resume.sexp#L20).
Negative assertions such as `screen-lacks`, `no-event`, and `no-errors` can pass
when their observation source is unavailable in
[runner.lisp](../qa/src/runner.lisp#L268). Ledger assertions parse the wrong
level of the real ledger structure.

The final test run also compiled with an undefined `RAN` caused by a broken spy
binding in
[invisible-evolution-test.lisp](../tests/invisible-evolution-test.lisp#L118).
Tests reuse an ambient or fixed temporary home, soak budgets can overshoot by a
whole scenario, and no checked-in CI runs the gates.

**Impact:** Recovery, verification, evolution, and negative safety behavior can
be reported green without occurring.

**Recommended fix:** Make unavailable evidence fail, require mandatory
milestones, use unique test homes and reset global state, treat warnings as
errors, enforce budgets at the provider boundary, return nonzero on soak failure,
and run all four gates in clean CI.

### 15. Low — Public surface and status documentation are stale

`STYLE` and `VERIFICATION-REPORT` are exported without implementations in
[term.lisp](../src/tui/term.lisp#L44) and
[verifier.lisp](../src/verify/verifier.lisp#L39). README described eight seed
genes at the review cutoff while smoke reported twelve.
[qa-findings.md](qa-findings.md) marked travel
broken while the roadmap and implementation said it was fixed. `AGENTS.md`
pointed to a nonexistent `.Codex` skill path.

**Impact:** Operators and future contributors cannot reliably distinguish
current behavior, historical findings, and planned work.

**Recommended fix:** Establish one generated status source, mark resolved
findings explicitly, validate public exports, and derive volatile counts from the
manifest.
