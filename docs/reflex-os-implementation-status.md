# Reflex OS implementation status

*Audit date: 2026-07-19. Plan:
[`technical-review-reflex-os-plan.md`](technical-review-reflex-os-plan.md).
Repository base: `92bbd043e4910062f4d16b53584da6c815e47c85` plus the
current working-tree implementation.*

## Supported safety profile

The implemented and tested product profile is **local-control, read-only by
default**. Background evolution and reflex workers require an explicit
experimental opt-in. A host without a reviewed containment backend refuses an
effectful candidate before compilation or execution and records the reduced
threat model in its verification proof.

This is an enforced safety boundary, not a claim that the Lisp child is an OS
sandbox. The planned Linux namespace/seccomp/cgroup backend is not enabled in
this tree. Effectful release remains blocked until that backend is implemented
and exercised on Linux and the independent security gate accepts it.

## Milestone traceability

| Milestone | Status | Primary implementation | Acceptance evidence |
|---|---|---|---|
| Gate −1 | **Repository action pending** | Default-off workers and fail-closed gates are implemented. | Clean-home test, smoke, and E2E pass below. A named clean baseline commit cannot honestly be recorded while the shared tree contains unrelated/in-flight changes. |
| Gate 0 | **Implemented for the read-only profile; effectful release blocked** | `src/kernel/transaction.lisp`, `src/verify/coordinator.lisp`, `src/verify/verifier.lisp`, `src/kernel/capabilities.lisp`, `src/kernel/walker.lisp`, `src/supervisor.lisp`, scheduler/disarm paths in `src/automation.lisp` and `src/evolve/engine.lisp`. | Transaction, verifier, coordinator, walker, robustness, automation, evolution, supervisor, and 38-check supervised E2E suites. The child proof boundary also verifies the full onboarding automation through a bounded, versioned report envelope. |
| M17 | **Implemented** | `src/reflex/journal.lisp` plus causal propagation in observation, jobs, investigations, evolution, handoff, and agent paths. | Stable record/entity identities, torn-tail/interior-corruption recovery, snapshots, migration backup, workspace isolation, export/import, retention/compaction, deletion tombstones, re-consent, and partition tests. |
| M18 | **Implemented** | `src/reflex/model.lisp`, `src/reflex/compiler.lisp`, `src/reflex/proof.lisp`, coordinator integration, ASDF ordering, declarative and rewritten seed coverage. | Canonical IR/generated Lisp/proof tests, generated-code rejection, deterministic dependency-closure invalidation, legacy opaque classification, immutable activation/canary/rollback, exact authority, and reversible state migration. |
| M19 | **Implemented** | `src/reflex/runtime.lisp`, `src/reflex/effects.lisp`, `src/reflex/investigation.lisp`. | Durable version-pinned instances, serialized commands, timers/coalescing/pause/freeze/disarm/shutdown/preemption, per-workspace concurrency, supervised deadlines, every adapter at every effect crash boundary, bounded retry/reconcile/pause/compensation, virtual replay, 1,000-event p95 gate, stalled-worker responsiveness, canary control routing, and cold rollback recovery. |
| M20 | **Implemented** | `src/reflex/briefing.lisp`, durable job events in `src/jobs.lisp`, read-only investigation wiring and UI briefing paths, rewritten `job-sentinel.gene`. | Real failed-job fixture, idempotent crash replay, exact evidence reconstruction, provider/model/limit disclosure, uncited-claim fallback, three model-free failure classes, and workspace residue-manifest checks. |
| M21 | **Implemented** | `src/reflex/learn.lisp` plus compiler canary routing and journaled lifecycle evidence. | Causal episodes, conservative typed generalization, negative evidence, virtual shadow traces, exact precision/coverage counts, five-day/20-opportunity clustered lower bound, exact blessing, effectful auto-promotion refusal, reproducible outcome accounting, and narrowing-only correction versions. |
| M22 engineering | **Implemented** | `src/reflex/inspector.lisp`, `src/reflex/pilot.lisp`, coordinated deletion hooks across journal, observations, candidates, compiler, runtime, and agent context. | Complete/fail-closed causal graphs, deterministic replay and virtual version comparison, clean-home export/import preserving inactive safety state, durable deletion tombstones with future-context denial, per-source opt-in/retention/preview, pilot denominator calculations, and fail-closed release records. |
| M22 external product gate | **Evidence pending** | The repository provides the preregistered metrics and release-gate evaluator; it cannot manufacture longitudinal or independent evidence. | Requires the real eight-week 15–20-user pilot, payment/retention/comprehension outcomes, and an independent security review. Missing minima remain `:inconclusive`; open Critical/High findings keep affected effects disabled. |

## Validation record

Host: Darwin 25.5.0 arm64; SBCL 2.6.3. Commands were run from the working tree
with distinct temporary homes on 2026-07-19. No compiler warnings were emitted.

| Command | Result | Wall time |
|---|---|---:|
| `OURRO_HOME=<unique> make test` | 2,306 checks; 2,306 pass; 0 skip; 0 fail | 19.04 s |
| `OURRO_HOME=<unique> make smoke` | kernel self-test OK; 15 tools; 13 genes | 0.75 s |
| `make verify-e2e` | 38 pass; 0 fail, using its own throwaway home | 12.32 s |

The E2E run proves supervised initialization/build, immutable genome commit
pinning, production package locks, source-staleness rebuild, deterministic
replay divergence, a PASS for a read-only automation, and fail-closed rejection
of an effectful automation.

## What remains before a complete product/release claim

1. Reconcile the shared dirty tree, create the named Gate −1 commit, and repeat
   the validation record from a clean checkout. This is intentionally not done
   by silently committing user-owned or unrelated work.
2. For any effectful release, implement and validate the Linux containment
   backend, then obtain the independent review and close every applicable
   Critical/High finding. Until then effectful candidates remain disabled.
3. Run the preregistered eight-week design-partner pilot. The time, users,
   interviews, payments, opportunities, and outcomes are external observations,
   not test fixtures; the current synthetic threshold fixture validates only
   the calculations and fail-closed decision policy.

Accordingly, the repository engineering for the read-only Reflex OS path is
complete and verified. The plan as a whole is not declared complete until the
baseline, security, and longitudinal product evidence above exist.
