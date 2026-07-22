# Greenfield plan: Lisp self-evolving coding agent

**Codename: ourro** — the snake that eats its own tail. A coding agent whose harness is a living Common Lisp image that observes you, rewrites itself, verifies the rewrite, and reboots into its next generation — without you ever leaving the keyboard.

---

## 1. Vision

Every "learning" coding agent on the market today learns _prose_. Hermes, pi.dev, Claude Code skills, CLAUDE.md/AGENTS.md — all of them accumulate Markdown that an LLM must re-read and re-interpret probabilistically on every session. The learning is a suggestion, not a capability. It costs tokens forever, it can be silently ignored, it rots, and it can never change what the agent _is_ — its tools, its UI, its dispatch logic are frozen at ship time.

ourro inverts this. Its unit of learning is **compiled, tested, contract-carrying code**, and its substrate is a **live Common Lisp image** — the only mainstream runtime designed from the ground up for programs that redefine themselves while running. When ourro notices you run `pytest -k` after every edit, it doesn't write a note to itself. It writes a new tool as an S-expression, structurally verifies it, compiles it inside its own image, gates it behind generated tests, hot-loads it into the running session, snapshots a new executable image, and restarts into it so seamlessly that the only evidence is a one-line ticker message and a generation counter that ticks from `gen 41` to `gen 42`.

The product thesis: **Lisp is not the implementation language; Lisp is the product.** Image-based persistence, live redefinition, CLOS/MOP, the condition system, homoiconicity, and the in-image compiler are precisely the missing primitives that make genuine self-evolution safe and seamless. No other runtime offers all of them; that is the moat.

---

## 2. Product Requirements (numbered, testable)

Each requirement has an acceptance test. "Generation" = a versioned, snapshotted state of the agent's own source and image.

**PR-1 — Workflow observation.** The agent records every tool invocation, its arguments, timing, outcome, and subsequent user corrections into a persistent event log.
_Test:_ After a 10-minute session, `/log` shows a structured event stream; killing the process loses at most the last 1 second of events.

**PR-2 — Pattern mining.** The agent detects repeated action sequences (≥3 occurrences of an n-gram of tool calls with unifiable arguments) and repeated user corrections, and surfaces them as evolution candidates.
_Test:_ Perform edit→shell(`make test`) three times; within one turn a candidate appears in the evolution queue.

**PR-3 — Code-level evolution.** An accepted evolution is realized as Common Lisp source (new tool, redefined function, redefined class, new TUI component, new keybinding, changed dispatch), never as a prompt/Markdown artifact.
_Test:_ Inspect the genome diff for any evolution; it contains only S-expressions plus metadata, and the new behavior executes with zero additional prompt tokens.

**PR-4 — Verification gates.** No evolved code reaches the live image without passing: safe read (`*read-eval*` = NIL), structural lint by a code walker, full `COMPILE-FILE` with zero errors and zero unhandled warnings in a scratch package, contract checks, and generated + regression tests.
_Test:_ Feed the pipeline a patch containing `(delete-file ...)` in a tool body without a declared `:filesystem-write` capability → rejected at lint. Feed it code with an undefined-variable warning → rejected at compile gate.

**PR-5 — Seamless restart.** After snapshotting a new generation, the agent restarts into the new image with full session continuity (conversation, scrollback, cursor, pending state) in under 2 seconds, with no dialog, no confirmation, at most one frame repaint.
_Test:_ Trigger an evolution mid-conversation; the next user message is answered by the new generation with full memory of the old conversation.

**PR-6 — No self-breakage.** A defective evolution can never leave the user without a working agent. In-image errors in evolved code are trapped and offer automatic reversion to the previous definition; boot failures trigger supervisor rollback to the last good image.
_Test:_ Force-inject a generation whose main loop signals an error on boot → within 5 seconds the supervisor has rebooted the previous generation and quarantined the bad one, with a ticker explanation.

**PR-7 — Holistic evolvability.** Tools, the TUI (panes, keybindings, renderer), the observation heuristics, prompt-assembly logic, and the pattern miner itself are all inside the evolvable genome. Only the safety kernel and supervisor are on a stricter path (PR-11).
_Test:_ An evolution that adds a new TUI pane renders it live in the current session without restart.

**PR-8 — Non-overwhelming TUI.** Default UI is a chat pane + status bar + one-line evolution ticker. All evolution detail (diffs, tests, rationale, history) is behind explicit keys. The user is informed _what changed and why it helps them_ in ≤ 120 characters per evolution.
_Test:_ A usability run of 30 minutes with 5 evolutions produces no modal, no interruption of typing, and each ticker line names the observed pattern and the benefit.

**PR-9 — Self-describing API.** The LLM's system prompt for evolution is assembled at request time by introspecting the _live image_: exported symbols, arglists, docstrings, type declarations, live examples harvested from the event log, and current genome conventions.
_Test:_ Rename an internal API function; the very next evolution prompt reflects the new name with no manually edited prompt file anywhere in the repo.

**PR-10 — Repo onboarding.** Pointed at an unfamiliar repository, the agent bootstraps repo-specific evolved tools (build, test, lint, run, common navigation) within the first working session, derived from observed and probed workflows.
_Test:_ Onboard to a Rails repo; within one session `gen+1` contains a compiled `run-specs` tool that wraps the repo's actual test invocation and parses its output.

**PR-11 — Kernel protection.** The safety kernel (verifier, supervisor protocol, rollback, capability checker) can only be modified through the _hardened path_: candidate change is built and booted in a child process, must pass the full kernel test suite plus replay of the last N recorded sessions, before the supervisor will register it.
_Test:_ An evolution that edits the verifier is not hot-loaded; it appears only after a successful child-process boot + replay pass.

**PR-12 — Generation ledger & time travel.** Every generation's genome (S-expression source) and image are retained (with configurable retention). The user can inspect any generation's diff, boot any past generation read-only, and hard-revert to it.
_Test:_ `/travel 12` boots generation 12's saved image against the current session's read-only transcript in < 5 seconds.

**PR-13 — Determinism of learned behavior.** For a learned behavior, given identical inputs, the evolved tool produces identical actions with zero LLM inference in the loop (unless the tool explicitly calls the LLM).
_Test:_ Run an evolved `edit-and-test` tool 10 times on the same fixture; byte-identical action traces, zero API calls.

---

## 3. Differentiation vs. text-based learning agents

| Dimension               | Hermes / pi.dev / Claude skills & CLAUDE.md                                                                                        | ourro                                                                                                                                                                          |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Unit of learning**    | Markdown prose (skills, memory files, instructions)                                                                                | Compiled Lisp code with contracts and tests, plus the metadata that justifies it                                                                                                   |
| **Execution semantics** | Probabilistic: the LLM must re-read, re-interpret, and _choose to follow_ the text every session                                   | Deterministic: learned behavior is machine code in the image; the LLM is not in the loop at execution time (PR-13)                                                                 |
| **Verification**        | None — a skill file can be wrong, stale, or contradictory and nothing detects it                                                   | Five mechanical gates: safe read → structural lint → compile → contracts → tests, plus session-replay regression for kernel changes                                                |
| **Scope of change**     | Prompt-layer only: memory, instructions, skill descriptions. The harness (tools, UI, dispatch) is immutable, shipped by the vendor | The harness itself: tools added/removed, tool _dispatch_ changed, TUI panes and keybindings changed, observation heuristics changed — the agent's body evolves, not just its notes |
| **Marginal cost**       | Every learned skill costs context tokens on every request, forever; learning degrades the context budget                           | Learned code costs zero tokens at runtime; more learning makes the agent cheaper, not more expensive                                                                               |
| **Failure mode**        | Silent: the model ignores or misreads a skill; nobody notices                                                                      | Loud and recoverable: conditions are signaled, restarts revert definitions, the supervisor rolls back images                                                                       |
| **Versioning / undo**   | Git-diff a Markdown file, hope the model behaves differently                                                                       | Structural S-expression diffs between generations; boot any prior generation as a whole; single-definition revert via restart                                                      |
| **Self-knowledge**      | A hand-written prompt describes the harness, and drifts from reality                                                               | The image introspects itself at prompt-assembly time; the description _cannot_ be stale (PR-9)                                                                                     |

The honest framing for marketing: _"Other agents take notes about you. ourro grows organs."_

A second, subtler differentiation: text-learning agents improve the _model's behavior_; ourro improves the _system's capability frontier_. A Markdown skill can never add a keybinding, fuse two tools into one atomic operation, add a CI-status widget to the status bar, or make dispatch of "edit" behave differently in this repo. ourro does all of these because its harness is data it can rewrite — homoiconicity all the way down.

---

## 4. Architecture

### 4.1 Process model

Two processes, deliberately asymmetric:

```
┌──────────────────────────────────────────────────────────┐
│ ourro-supervisor  (tiny, boring, ~1500 LOC, almost never   │
│ changes; hardened evolution path only)                    │
│  • owns the terminal session lifecycle                    │
│  • generation ledger (genome git repo + image store)      │
│  • spawns/monitors the agent image (heartbeat pipe)       │
│  • crash-loop detection → rollback to last-good image     │
│  • builds candidate images in child SBCL processes        │
└───────────────┬──────────────────────────────────────────┘
                │ spawns; heartbeat + control protocol
                │ (S-expressions over a Unix socket)
┌───────────────▼──────────────────────────────────────────┐
│ ourro-agent  (the living image; gen N executable made by   │
│ sb-ext:save-lisp-and-die)                                 │
│  • TUI (pure-Lisp ANSI renderer, inherits the tty)        │
│  • LLM client, tool registry, session state               │
│  • observer + pattern miner                               │
│  • evolution engine (propose → verify → hot-load)         │
│  • safety kernel (verifier, capabilities, revert tables)  │
└──────────────────────────────────────────────────────────┘
```

**Why a supervisor at all?** A process cannot save itself out of its own corruption. The supervisor is the fixed point: it survives every generation, holds the ledger, and is the only entity trusted to declare a generation "good." It is intentionally dull — no LLM calls, no TUI, no cleverness — because dull code doesn't need to evolve.

**Seamless restart protocol (PR-5):**

1. Agent finishes verifying + snapshotting `gen N+1` (see 4.4).
2. Agent serializes session state — conversation history, TUI layout, scrollback, pending tasks — as _readable_ S-expressions (`PRINT`/`READ` round-trippable, `*print-readably*` = T) to a handoff file. This is Lisp's free lunch: state that is data that is text that is data again.
3. Agent tells supervisor `(:handoff "gen-0042" "/state/handoff-8843.sexp")`, paints its final frame, and exits cleanly.
4. Supervisor execs `gen-0042 --resume handoff-8843.sexp` on the same tty. The new image's first act is to `READ` the handoff and repaint the identical frame with the ticker line appended. Cold start of a compressed SBCL core is ~150–400 ms; total handoff well under the 2-second budget.

### 4.2 Module breakdown (packages)

| Package              | Role                                                                                     | Evolvable?                                |
| -------------------- | ---------------------------------------------------------------------------------------- | ----------------------------------------- |
| `OURRO.KERNEL`        | Verifier, code walker, capability checker, revert tables, condition types, handoff       | Hardened path only (PR-11)                |
| `OURRO.SUPERVISOR`    | Separate binary; ledger, rollback, image builder                                         | Hardened path only                        |
| `OURRO.GENOME`        | Genome representation, structural diff, generation metadata, `DEFGENE` macro & readtable | Hardened path                             |
| `OURRO.TOOLS`         | Tool protocol (generic functions, custom method combination), built-in tools             | Fully evolvable                           |
| `OURRO.TUI`           | Renderer, CLOS component tree, keymaps, ticker                                           | Fully evolvable                           |
| `OURRO.LLM`           | API client, streaming, prompt assembly, S-expression extraction/validation               | Fully evolvable                           |
| `OURRO.OBSERVE`       | Event log, MOP instrumentation, pattern miner                                            | Fully evolvable                           |
| `OURRO.EVOLVE`        | Proposal loop, scratch-package staging, test generation, hot-loader                      | Verifier calls hardened; policy evolvable |
| `GEN-NNNN-CANDIDATE` | Throwaway scratch packages for staging candidates (`MAKE-PACKAGE` / `DELETE-PACKAGE`)    | Ephemeral                                 |

### 4.3 The genome

The agent's entire evolvable source is a **genome**: an ordered set of _genes_, each a `DEFGENE` form:

```lisp
(defgene tool/edit-and-test (:generation 42 :parent tool/edit
                             :capabilities (:filesystem-write :subprocess)
                             :provenance (:pattern pat-0177 :model "claude-opus" :turn 8812))
  (:contract (:pre  ((probe-file path))
              :post ((test-report-p result))))
  (:code
    (deftool edit-and-test (path edit-spec)
      "Apply EDIT-SPEC to PATH, then run the repo's test command scoped to PATH."
      ...))
  (:tests
    (test edit-and-test/roundtrip ...)
    (test edit-and-test/failing-test-reported ...)))
```

Key properties:

- **Genes are S-expressions**, so the LLM can generate them, the harness can `READ` them safely, a code walker can verify them structurally, `MACROEXPAND-ALL` can normalize them, and a tree-diff can compare them across generations — none of which is possible with opaque text patches in other languages. This is homoiconicity as load-bearing infrastructure, not aesthetics.
- The genome lives in a **git repository managed by the supervisor** (one commit per generation), giving durable history for free; but diffs shown to the user are _structural_ (S-expression tree edit script: "added `:around` method on `dispatch-tool` for `edit-tool`"), not line-based.
- A generation's image is always **reproducible from its genome**: the supervisor can rebuild any image by `COMPILE-FILE`-ing the genome in a fresh SBCL and `save-lisp-and-die`. Images are a cache; the genome is truth. This bounds image-bloat risk and enables SBCL-version migration.
- A custom **readtable** gives the LLM ergonomic sugar the walker understands: e.g. `#?(probe-file path)` marks a contract assertion, `#!shell"git status"` declares a subprocess capability inline (each reader macro expands to plain verified forms).

### 4.4 Evolution pipeline, end to end

```
observe ─→ mine ─→ propose (LLM) ─→ verify ─→ hot-load ─→ evaluate ─→ snapshot ─→ restart
   ▲                                   │ fail                │ fail                  │
   └───────────────────────────────────┴──── revert/discard ─┴── rollback (supervisor)
```

**Stage 1 — Observe.** Every tool is an instance of a class with metaclass `INSTRUMENTED-CLASS`; a custom method combination on the `RUN-TOOL` generic function guarantees an un-removable logging wrapper around every invocation (MOP: the wrapper is woven at class-finalization time via `COMPUTE-EFFECTIVE-METHOD` participation, so evolved tools are auto-instrumented with zero effort from the LLM). Events: tool calls, args (redacted per capability policy), durations, exit statuses, user edits to agent output, message text markers ("no, use pnpm not npm"), keystroke-level friction signals (repeated identical commands).

**Stage 2 — Mine.** A frequent-episode miner over the event stream finds: repeated n-grams of tool calls with unifiable argument skeletons; repeated user corrections of the same class; repeated manual sequences the agent could fuse; latency hot spots. Each finding becomes a _pattern record_ with evidence pointers. The miner itself is a gene — the agent can evolve better ways to notice.

**Stage 3 — Propose.** The evolution engine assembles a prompt (Section 8) from live introspection + the pattern record + relevant genome excerpts, and asks the LLM for a `DEFGENE` (or a `redefine-gene` / `retire-gene` form). Output must be a single S-expression in a tagged block.

**Stage 4 — Verify (the gauntlet, PR-4).** In order:

1. **Safe read**: `READ` with `*read-eval*` bound to NIL, custom readtable, package locked to the candidate's scratch package. Read errors → structured feedback to the LLM for one retry.
2. **Structural lint**: a code walker checks — declared capabilities cover every effectful operator used (`UIOP:RUN-PROGRAM` requires `:subprocess`, `DELETE-FILE` requires `:filesystem-write`, network calls require `:network`); no references to `OURRO.KERNEL` internals; no `EVAL` of non-constant data; contracts and ≥1 test present; docstring present.
3. **Compile gate**: `COMPILE-FILE` inside `WITH-COMPILATION-UNIT`, into scratch package `GEN-0043-CANDIDATE` (`MAKE-PACKAGE`), with `HANDLER-BIND` collecting every `WARNING`; SBCL's compile-time type derivation catches whole classes of LLM slop (wrong arg counts, unreachable code, type conflicts) _before anything runs_. Any `ERROR` or unwhitelisted `WARNING` → reject with the compiler's own diagnostics fed back to the LLM (SBCL's messages are excellent LLM feedback).
4. **Contract & test gate**: run the gene's tests plus the affected subsystem's regression suite (FiveAM) inside a `HANDLER-CASE` with a watchdog timeout thread; tests exercising real side effects run in a temp sandbox directory. Tests touching `:subprocess`/`:network` capabilities run in a **child SBCL process** instead of in-image.
5. **Kernel path** (only if the gene touches `OURRO.KERNEL`/verifier/supervisor protocol): supervisor builds a full candidate image in a child process, boots it headless, runs the kernel suite, and **replays the last N recorded sessions** against it, comparing action traces. Only then is it eligible.

**Stage 5 — Hot-load.** The verified gene is loaded into its real package in the live image. This is where Common Lisp does what nothing else can:

- `DEFUN`/`DEFGENERIC`/`DEFMETHOD` redefinition takes effect instantly; callers pick it up on next call.
- `DEFCLASS` redefinition triggers the standard `MAKE-INSTANCES-OBSOLETE` machinery; live objects (open TUI panes, in-flight tool objects, the session itself) are migrated by `UPDATE-INSTANCE-FOR-REDEFINED-CLASS` methods the gene may supply — the UI grows a new slot _while it is on screen_.
- Before overwriting, the kernel records `(FDEFINITION sym)` and method objects into the **revert table**, so every redefinition is individually undoable in O(1) via `(SETF FDEFINITION)` / `REMOVE-METHOD`.
- The scratch package is `DELETE-PACKAGE`d.

**Stage 6 — Evaluate (probation).** For its first K uses, the gene runs under a probation `HANDLER-BIND`: any `ERROR` signals `EVOLVED-CODE-FAILURE`, whose handler invokes the `REVERT-DEFINITION` restart automatically (restoring from the revert table), logs the failure, notifies the ticker, and files the diagnostics for a future retry. The user's task continues via the old definition — **recovery instead of crash** is the condition system's entire design purpose, and it is why in-image self-modification is survivable at all.

**Stage 7 — Snapshot.** The genome commit is sent to the supervisor, which builds `gen N+1`: fresh child SBCL, `COMPILE-FILE` the full genome, boot smoke test, then `sb-ext:save-lisp-and-die` with `:executable t :compression t`. (Building in a child sidesteps `save-lisp-and-die`'s single-thread requirement and guarantees the image is clean, not a snapshot of accumulated session heap.) The ledger records genome hash, parent, provenance, and test report.

**Stage 8 — Restart.** Handoff protocol from 4.1. If the user is mid-task, the restart is deferred until the next turn boundary — hot-loaded behavior is already live, so nothing is lost by waiting.

**Rollback path.** (a) Single gene: probation revert (Stage 6). (b) Generation: supervisor detects crash-loop (2 failed boots or missed heartbeats within 60 s) → boots `gen N`, quarantines `gen N+1` with its crash report attached for the LLM to study. (c) User-initiated: `/revert` (last evolution) or `/travel --hard 37`.

---

## 5. Which Lisp mechanisms power what — and why Lisp is essential

| Subsystem                              | Standard mechanism (named)                                                                                                                      | Why it's essential, concretely                                                                                                                                                                                                                                            |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Seamless new-version restarts          | `sb-ext:save-lisp-and-die :executable t`; readable serialization via `PRINT`/`READ`, `*print-readably*`                                         | The whole evolved program becomes a single self-contained executable in seconds; session state round-trips as text because Lisp data prints readably. In Python/Go you'd be re-installing a package and cold-starting an interpreter; here "new version" is a saved heap. |
| In-session evolution                   | Live redefinition semantics of `DEFUN`, `DEFGENERIC`, `DEFMETHOD`, `DEFCLASS`; `UPDATE-INSTANCE-FOR-REDEFINED-CLASS`, `MAKE-INSTANCES-OBSOLETE` | The language _standard_ specifies what happens to existing instances when a class changes under them. This is the difference between "restart to get the feature" and "the feature appears mid-conversation." No other mainstream runtime standardizes this.              |
| No-crash guarantee around evolved code | `DEFINE-CONDITION`, `HANDLER-BIND`, `RESTART-CASE`, `INVOKE-RESTART`, `WITH-SIMPLE-RESTART`                                                     | Restarts decouple _detecting_ a failure from _deciding_ the recovery, so the kernel can install policy ("revert this definition and retry") around code it has never seen. Exceptions-that-unwind (every other language) destroy the context needed to recover in place.  |
| Trustworthy LLM patches                | Homoiconicity: `READ` with `*read-eval*` NIL, code walking, `MACROEXPAND` / macroexpand-all, `EQUAL`-tree structural diffing                    | LLM output is parsed into the same data structure the compiler consumes — verification operates on the true program, not on a textual approximation (regex-linting a Python diff). The walker can prove "this gene performs no filesystem writes" structurally.           |
| Verification before execution          | `COMPILE-FILE`, `COMPILE`, `WITH-COMPILATION-UNIT`, `HANDLER-BIND` on `WARNING`/`STYLE-WARNING`; SBCL type derivation                           | A full native compiler lives _inside_ the running product; candidate code is compiled and type-checked in-process in milliseconds, and compiler diagnostics become LLM feedback.                                                                                          |
| Generation staging & isolation         | `MAKE-PACKAGE`, `DEFPACKAGE`, `DELETE-PACKAGE`, package locks (`sb-ext:lock-package`)                                                           | Candidates get a disposable namespace; failed candidates vanish without a trace; the kernel package is locked so evolved code cannot even _name_ its internals mutably.                                                                                                   |
| Extensible tool system                 | Generic functions, custom method combination (`DEFINE-METHOD-COMBINATION`), `:around`/`:before`/`:after` methods                                | New tools and cross-cutting behavior (logging, permissions, retries) are added by _defining methods_, never by editing a dispatch switch — the ideal shape for machine-written extension.                                                                                 |
| Auto-instrumentation of all tools      | The MOP: custom metaclass, `VALIDATE-SUPERCLASS`, participation in `COMPUTE-EFFECTIVE-METHOD` / funcallable instances                           | Observation (PR-1) is guaranteed by the _metaclass_, so the LLM cannot forget to instrument a tool it writes. Meta-level enforcement instead of convention.                                                                                                               |
| Self-description to the LLM            | `DO-EXTERNAL-SYMBOLS`, `DOCUMENTATION`, `DESCRIBE`, `sb-introspect:function-lambda-list`, `FIND-METHOD`, class precedence introspection         | The prompt is generated from the ground truth of the running image (PR-9). Stale documentation is structurally impossible.                                                                                                                                                |
| DSL ergonomics for the LLM             | `DEFMACRO`, `*READTABLE*` / `SET-DISPATCH-MACRO-CHARACTER`                                                                                      | `DEFGENE`, `DEFTOOL`, contract sugar — macros make the "harness API" small and declarative, which measurably improves LLM generation accuracy, while expansion produces plain verifiable Lisp.                                                                            |
| Time travel & ledger                   | Saved images per generation + genome-as-data                                                                                                    | Booting "the agent as it was last Tuesday" is starting a file.                                                                                                                                                                                                            |

**The one-paragraph "why Lisp" for the product owner:** every hard requirement in this brief reduces to "a running program must accept new source, prove it safe, splice it into itself, persist the result, and recover when wrong." Common Lisp standardized each of those verbs decades ago — `READ`, `COMPILE`, live redefinition + `UPDATE-INSTANCE-FOR-REDEFINED-CLASS`, `save-lisp-and-die`, `RESTART-CASE`. In any other stack each verb is a research project; here the product is mostly _composition_.

---

## 6. Safety architecture: never break yourself

Defense in depth, seven layers, ordered from cheapest to last-resort:

1. **Reader safety.** `*read-eval*` NIL always; candidate forms read in a locked-down readtable; symbols interned only into the scratch package; size/depth limits on forms.
2. **Capability lint.** Genes declare capabilities; the code walker proves the body needs no more than declared; effectful primitives are only reachable through kernel-provided capability-checked wrappers (the raw symbols are unexported and the kernel package is locked via `sb-ext:lock-package`, so evolved code gets a `PACKAGE-LOCK-VIOLATION` condition if it tries).
3. **Compile gate.** Zero errors, zero unwhitelisted warnings, in a scratch package that is `DELETE-PACKAGE`d on failure — a failed candidate leaves no residue in the image.
4. **Test gate.** Gene tests + regression suite for the touched subsystem, under watchdog timeouts; capability-heavy tests run in a child SBCL so a runaway candidate can be `SIGKILL`ed without touching the live image.
5. **Probation + restarts.** First K live invocations wrapped in `HANDLER-BIND` → `EVOLVED-CODE-FAILURE` → automatic `REVERT-DEFINITION` restart from the revert table (`(SETF FDEFINITION)` of the saved previous function, `REMOVE-METHOD` of added methods, class re-redefinition). The user-visible effect of a bad gene is one ticker line, never a stack trace.
6. **Supervisor rollback.** Heartbeats every 2 s over the control socket; missed heartbeats or boot failure → kill, boot last-good image, quarantine the bad generation _with its crash report_, which is fed back to the LLM as a learning signal ("gen 43 died because …, propose a fix or abandon").
7. **Hardened kernel path (PR-11).** The verifier, capability system, supervisor protocol, and revert machinery cannot be hot-loaded. Changes to them require: child-process image build → headless boot → kernel suite → deterministic replay of the last N recorded sessions with action-trace comparison. Only a green replay lets the supervisor register the generation. This closes the classic loophole of "the agent evolves its own safety checks away" without ever showing the user an approval dialog — the gate is mechanical, not social.

Additional invariants: the genome git repo is append-only from the agent's perspective (supervisor owns HEAD); at least 3 known-good images are always retained; evolution frequency is rate-limited (default: at most 1 hot-load per 10 minutes, snapshots at turn boundaries) to prevent thrash; and a global `EVOLUTION-FREEZE` restart is reachable from any condition for the paranoid moment (`/freeze`).

---

## 7. TUI design

**Philosophy:** the agent gets smarter loudly enough to build trust, quietly enough to never cost attention.

Default layout (single 80×24 works; scales up):

```
┌─ ourro · gen 42 · repo: tabula-rasa ────────────── ⚡2 ─┐
│                                                        │
│  (chat / agent output pane — 90% of the screen)        │
│                                                        │
├────────────────────────────────────────────────────────┤
│ ✦ learned: edit→test ×3 → new tool edit-and-test.      │
│   saves ~40s/cycle.  [e]xplain [u]ndo (dismisses in 8s)│
├────────────────────────────────────────────────────────┤
│ ❯ your message…                                        │
└────────────────────────────────────────────────────────┘
```

- **Status bar**: generation number (the heartbeat of the product), repo, and `⚡N` = evolutions pending in the queue. Nothing else by default.
- **Evolution ticker**: one line, auto-dismissing, verb-first, benefit-quantified ("saves ~40s/cycle" computed from observed timings). Two keys: `e` opens the inspector, `u` reverts instantly. Never a modal, never blocks input (PR-8).
- **Evolution inspector** (`F2` or `/evolutions`): scrollable list of generations; selecting one shows the _structural_ diff ("＋ tool `edit-and-test` (2 methods, 2 tests, caps: fs-write, subprocess)"), the triggering pattern with evidence ("you did this 3× today: …"), test results, and buttons: revert, freeze this gene, retry with feedback.
- **Time travel** (`/travel 37`): status bar turns amber `gen 37 (visiting)`; read-only session against the old image; `/travel --hard 37` re-roots.
- **Restart experience**: a subtle spinner in the status bar ("snapshotting gen 43…"), then the frame repaints identically with the ticker line "now running gen 43". If the user is typing, restart waits.

**Implementation**: a CLOS component tree (`pane`, `ticker`, `statusbar`, `input-line` classes) over a **bespoke pure-Lisp ANSI/VT100 renderer** with double-buffered diffs. Two reasons this beats ncurses bindings: (1) zero FFI state, so nothing breaks across `save-lisp-and-die`/resume (foreign handles don't survive image saves); (2) the renderer itself is genes — the agent can hot-swap its own drawing code, and `UPDATE-INSTANCE-FOR-REDEFINED-CLASS` migrates on-screen components when the LLM adds a slot to `pane`. Keymaps are data (alists of key → command symbol), hence trivially evolvable and diffable.

---

## 8. LLM integration

**Provider layer.** Vertex AI as the LLM provider; the _evolution_ channel uses plain text completion with a tagged S-expression block, which is easier to validate than JSON-embedded code). Provider-agnostic generic function `COMPLETE` so genes can add providers.

**Teaching the LLM the harness — the self-describing prompt.** No hand-maintained prompt file describes the API. At proposal time, `ASSEMBLE-EVOLUTION-PROMPT` builds the system prompt from the live image:

1. **API surface**: walk `OURRO.API`'s external symbols (`DO-EXTERNAL-SYMBOLS`), emitting for each: name, `sb-introspect:function-lambda-list`, `DOCUMENTATION`, declared types, and capability requirements. Classes get slot lists and relevant `UPDATE-INSTANCE-FOR-REDEFINED-CLASS` notes.
2. **Live exemplars**: 2–3 recent _real_ invocations of related tools pulled from the event log, so examples are grounded in this user's actual repo and arguments.
3. **Genome conventions**: the `DEFGENE` grammar, the contract/test sugar, 2 nearest-neighbor genes (by pattern similarity) as few-shot examples — the genome is its own training set.
4. **The pattern record**: mined evidence, frequency, timing cost, and the user's own words if a correction triggered it.
5. **House rules**: "respond with exactly one `DEFGENE`/`redefine-gene`/`retire-gene` form inside `<gene>…</gene>`; no `EVAL`; declare all capabilities; every claim in the docstring must be enforced by a contract or test."

**Output handling**: extract the tagged block → safe `READ` → the verification gauntlet. On any gate failure, the _machine diagnostics_ (reader error, walker verdict, full SBCL compiler output, failing test transcript) go back as the next user message, up to 3 repair rounds; then the candidate is shelved with its history. Because feedback is compiler-grade, repair convergence is high — this loop is the practical answer to "the LLM must be trained for this harness": it is taught continuously, by the image, with ground truth.

**Two LLM roles, one model**: the _coder_ role (normal agentic work in the user's repo, standard tool-use) and the _evolver_ role (writes genes). Evolver runs asynchronously in a worker thread at low priority; the user never waits on evolution.

---

## 9. Tech stack

| Choice             | Recommendation                                                                      | Rationale / alternatives                                                                                                                                                                                                                                                                                                                                               |
| ------------------ | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Implementation     | **SBCL**                                                                            | Best-in-class native compiler with warning-rich diagnostics (our verification signal), `save-lisp-and-die` with `:executable :compression`, `sb-introspect`, package locks, mature threads. Alternatives: CCL (nice but less maintained), ECL/ABCL (no comparable image story). Pin a version per genome; supervisor handles version migration by rebuild-from-genome. |
| System defs / deps | ASDF + ocicl (or Qlot-pinned Quicklisp)                                             | Reproducible, vendored dependencies — the supervisor must rebuild images offline and deterministically.                                                                                                                                                                                                                                                                |
| TUI                | **Bespoke ANSI renderer** (~1–2 kLOC) over CLOS components                          | No FFI across image saves; fully evolvable. Fallback if timeline slips: croatoan (CLOS ncurses) with a foreign-state reinit hook on resume.                                                                                                                                                                                                                            |
| HTTP / LLM client  | **dexador** + **com.inuoe.jzon** (JSON) + hand-rolled SSE reader (~100 LOC)         | dexador is the maintained standard; jzon is the safest/strictest JSON parser.                                                                                                                                                                                                                                                                                          |
| Testing            | **FiveAM** for genome/kernel suites                                                 | Ubiquitous, simple s-expression tests the LLM writes reliably; Parachute is the acceptable alternative. Replay harness is custom (action-trace recorder + comparator).                                                                                                                                                                                                 |
| Genome store       | git (libgit-free: shell out via `uiop:run-program` from the _supervisor_ only)      | Durable history, remotes for free ("push your agent's genome"), while structural diffing stays in Lisp.                                                                                                                                                                                                                                                                |
| Pattern mining     | Custom in-image (frequent-episode mining over event vectors)                        | Tiny data volumes; no dependency worth taking. Miner is itself evolvable.                                                                                                                                                                                                                                                                                              |
| Serialization      | Readable `PRINT`/`READ` S-expressions everywhere (events, handoff, ledger metadata) | One format, human-inspectable, diff-able, and the LLM speaks it natively.                                                                                                                                                                                                                                                                                              |

---

## 10. Implementation roadmap

**Phase 0 — Spine (3 weeks).** Supervisor binary: spawn/heartbeat/rollback; generation ledger over git; child-process image builder (`compile-file` genome → smoke boot → `save-lisp-and-die`); handoff protocol with a stub agent. _Exit test:_ kill -9 the stub agent → supervisor reboots last-good in <5 s (PR-6 skeleton).

**Phase 1 — A good ordinary agent (4 weeks).** ANSI TUI (chat, status bar, input), Vertex AI client with streaming + tool use, core tools (read/edit/glob/grep/shell) on the generic-function + instrumented-metaclass protocol, FiveAM harness, readable event log. _Exit test:_ usable for real coding work; every action instrumented (PR-1).

**Phase 2 — Genome & verifier (4 weeks).** `DEFGENE`/`DEFTOOL` macros + readtable; safe reader; code walker + capability lint; compile gate; scratch packages; revert tables; probation `HANDLER-BIND`/`RESTART-CASE` machinery; structural diff. Port Phase-1 tools into genes. _Exit test:_ hand-written genes pass the gauntlet and hot-load; a deliberately buggy gene auto-reverts (PR-3, PR-4, part of PR-6).

**Phase 3 — The loop closes (4 weeks).** Pattern miner; evolution queue; self-describing prompt assembly; LLM propose→repair loop; snapshot + seamless restart end-to-end; ticker + inspector UI. **This is the demo milestone.** _Exit test:_ PR-2, PR-5, PR-8, PR-9, PR-13 acceptance tests pass unattended.

**Phase 4 — Hardening (3 weeks).** Kernel path with session replay (PR-11); crash-loop quarantine with LLM postmortems; rate limiting; `/freeze`, `/revert`; retention/GC of images; security review of capability wrappers. _Exit test:_ PR-6 and PR-11 acceptance tests; a week of dogfooding with zero unrecoverable states.

**Phase 5 — Delight (3 weeks).** Repo onboarding flow (PR-10); time travel (PR-12); dream mode (idle-time offline evolution in child processes — "while you were away, I built 2 candidates; they're staged"); genome sharing (`ourro push`); TUI-evolution showcase genes. _Exit test:_ the demo script in Section 12 runs clean.

Total: ~5 months to a demo-complete 1.0 with a team of 2–3 Lisp-fluent engineers.

---

## 11. Risks & mitigations

| Risk                                                     | Mitigation                                                                                                                                                                                                                                                    |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| LLMs write mediocre Common Lisp                          | The gauntlet turns model weakness into a feedback loop: SBCL diagnostics are unusually instructive; `DEFGENE` keeps the required dialect tiny; few-shot from the user's own genome; 3-round repair loop; shelved candidates retried by stronger models later. |
| `save-lisp-and-die` constraints (threads, foreign state) | Never snapshot the live session heap: images are always rebuilt from genome in a single-threaded child process. Pure-Lisp TUI removes foreign state entirely.                                                                                                 |
| Evolution thrash / degradation over time                 | Rate limits; utility scoring (a gene that is never used or often reverted gets auto-retired by a housekeeping gene); replay regression suite grows with every session; user `u`ndo is one keystroke.                                                          |
| Self-modifying agent as a security surface               | Capability lint + locked kernel package + capability-checked effect wrappers; child-process execution for subprocess/network tests; genome is auditable S-expressions with provenance; hardened path for anything touching the checks themselves.             |
| "No approval dialog" alarms enterprise users             | Approval is replaced by _mechanical_ gates plus instant undo and full audit; a config flag can add a confirm step for policy-bound orgs without changing the architecture.                                                                                    |
| Image/ledger disk growth                                 | Images are a cache over the genome — keep last 3 + weekly pins, rebuild anything else on demand; compressed SBCL cores are ~15–40 MB.                                                                                                                         |
| Ecosystem risk (small Lisp library pool)                 | Deliberately thin dependency set (dexador, jzon, FiveAM); everything strategic (TUI, walker, miner, SSE) is in-house and therefore evolvable — which the product requires anyway.                                                                             |
| User trust ("what is it doing to itself?")               | Every change is one ticker line + inspectable structural diff + named benefit + provenance; generation number is always on screen; time travel makes history tangible.                                                                                        |

---

## 12. "Wow" demo scenarios

1. **Watch it grow an organ.** Live audience; presenter edits a file and runs tests, three times. Ticker: _"learned: edit→test ×3 → new tool edit-and-test · saves ~40s/cycle · [u]ndo"_. Fourth edit runs tests automatically. Press `e`: the compiled gene, its tests, and the evidence. Status bar ticks `gen 41 → 42` with no visible restart.
2. **Try to kill it.** Presenter force-injects a gene whose body divides by zero. First invocation: one amber ticker line — _"gene edit-and-test failed on use, reverted to previous definition; filed for repair"_ — and the task completes with the old tool. Then `kill -9` the agent: supervisor reboots last-good in 3 seconds, conversation intact.
3. **The agent redecorates.** Presenter asks "what's the diff?" three turns in a row. Next generation adds a live diff pane to its own TUI — the pane appears mid-session because `UPDATE-INSTANCE-FOR-REDEFINED-CLASS` migrated the on-screen layout object.
4. **Time travel.** `/travel 12` — instantly running last week's agent, which doesn't know any of today's tricks; `/travel --hard` back. "Every version of your agent still exists as a bootable file."
5. **Cold onboarding.** Point ourro at an unfamiliar open-source repo; within one session it has probed and evolved `build`, `run-specs`, and `lint-changed` tools wrapping that repo's actual toolchain, with parsed structured output — and a CI-status widget it added to its own status bar.
6. **While you were away.** Return in the morning to: _"dream mode built 2 candidates from yesterday's friction (staged, not applied): fuse grep→open→edit; add flaky-test retry. Press e to review."_
