# ourro Technical Review — Next Steps

## Direction

The most valuable future for ourro is not simply a coding assistant with
more tools. It is a locally evolving engineering organism that learns workflows,
acts proactively, explains its adaptations, and remains inspectable and
reversible.

The safety foundations identified in
[the quality-control review](technical-review-quality-control.md) are
prerequisites for these directions because each one increases the authority of
evolved code. This document intentionally does not duplicate the individual bug
findings or fixes.

## 1. Proof-carrying evolution

**What should be built:** Make every gene a versioned artifact carrying
provenance, capabilities, tests, replay evidence, utility claims, and an atomic
canary and rollback lifecycle.

**Why it matters:** This turns self-modification from a risky implementation
technique into ourro's defensible core technology. A user should be able to
trust an evolved behavior because its authority, evidence, and history are
explicit—not because the latest process happened not to crash.

**Definition of done:**

- An adversarial candidate cannot affect the host before promotion.
- Fault injection at every install, build, probation, and restart phase never
  leaves mixed state.
- Every active behavior traces to one auditable artifact and exact lineage.
- Promotion and rollback remain correct across process and generation restarts.

## 2. A reflex operating system

**What should be built:** Expand isolated callbacks into typed
trigger → state → action workflows with simulation, idempotency, workspace
scope, exactly-once execution, and user-editable policies.

**Why it matters:** The novel product is not an agent that can run cron jobs. It
is an agent that learns each developer's recurring engineering loops and turns
manual commands into safe overrides for normally autonomous behavior.

**Definition of done:**

- ourro learns an edit → test → diagnose → notify workflow in an unfamiliar
  repository.
- It presents the causal evidence and a dry-run trace before activation.
- The workflow runs autonomously after one explicit blessing.
- It survives restart exactly once and can be durably undone as one unit.
- Disarm reliably prevents queued, deferred, and newly triggered effects.

## 3. A workspace digital twin

**What should be built:** Create durable per-repository memory connecting
symbols, files, commands, failures, dependencies, user preferences, genes,
generations, and the observations supporting each conclusion.

**Why it matters:** Long-term compounding value requires remembering why a
behavior was learned, not merely retaining generated code. This would let the
agent develop a distinct, evidence-backed understanding of every workspace.

**Definition of done:**

- Knowledge learned weeks earlier reappears only in the correct workspace and
  includes supporting evidence.
- Cold onboarding happens once; subsequent sessions start from the accumulated
  model.
- Memory can be inspected, corrected, exported, scoped, and deleted.
- Automated tests prove that no knowledge or secret leaks between workspaces.

## 4. The proactive engineering intern

**What should be built:** Deliver bounded headless investigators that correlate
logs, diffs, tests, events, and history, produce non-interrupting evidence-backed
briefings, and optionally prepare a fix in an isolated worktree.

**Why it matters:** This changes ourro from a reactive coding interface into
a teammate that arrives with the diagnosis already assembled. Failures become
inputs to background understanding rather than another prompt the user must
write.

**Definition of done:**

- A real failed background job produces a causal briefing within the configured
  time bound, citing exact files, commands, and log evidence.
- Foreground turns retain their latency and can pre-empt background work.
- Investigation steps and wall time remain capped even when background token
  spend is unrestricted by user choice.
- Any proposed fix is prepared and verified outside the live workspace until the
  user explicitly accepts it.

## 5. Counterfactual trust and an evolution economy

**What should be built:** Add shadow execution, canaries, outcome comparison,
confidence estimates, correction signals, and automatic promotion and retirement
policies.

**Why it matters:** Time saved is not sufficient evidence of value. An
autonomous system must measure whether its intervention improved the actual task
and whether the result was correct, durable, and preferred by the user.

**Definition of done:**

- Every gene reports benefit, quality, cost, failures, corrections, and
  confidence.
- Failed or timed-out executions earn no benefit.
- Promotion and retirement decisions are reproducible from recorded evidence.
- User corrections narrow or demote the responsible behavior instead of merely
  becoming another undifferentiated event.

## 6. A time-travel laboratory for autonomous behavior

**What should be built:** Unify events, triggers, tool calls, reflexes, costs,
corrections, gene versions, and generations into one causal history that can be
replayed, compared, or forked.

**Why it matters:** Debuggable autonomy is a major differentiator. Users should
be able to ask not only what happened, but which evolved decision caused it and
how a different generation would have behaved.

**Definition of done:**

- Selecting any automated action reveals its complete causal graph.
- A historical failure can be reproduced offline without changing the live
  workspace.
- Two generations can be replayed against the same evidence and compared.
- A historical state can be forked into an experimental lineage and later
  restored or discarded safely.

## 7. A signed gene ecology

**What should be built:** Make genes portable across machines and teams through
signed provenance, capability manifests, compatibility checks, sandbox
attestations, and local forking.

**Why it matters:** This could create a new ecosystem of reusable executable
engineering habits that remain inspectable and adaptable instead of becoming
opaque marketplace agents.

**Definition of done:**

- A gene from another installation can be verified and simulated against the
  local workspace before installation.
- Its requested authority, provenance, compatibility, and supporting evidence
  are visible to the user.
- Import cannot increase authority beyond the locally approved capability
  ceiling.
- The gene can be locally evolved, independently signed, and cleanly removed or
  rolled back.
