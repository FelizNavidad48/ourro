# ourro

**A self-evolving Common Lisp coding agent.** Its harness is a living SBCL
image that observes you, writes new tools for itself as S-expressions,
verifies them through a compiler-backed gauntlet, hot-loads them into the
running session, snapshots a new executable generation, and restarts into it
— without you leaving the keyboard.

> Other agents take notes about you. ourro grows organs.

The unit of learning is **compiled, contract-carrying, tested code**, not
Markdown prose. Learned behaviour is deterministic machine code in the image
(zero tokens at runtime), verified before it ever runs, and reversible by
construction.

## Quick start

Requirements: SBCL 2.6+, [Quicklisp](https://www.quicklisp.org), and an LLM
API key (see *Configuration*).

```sh
make build      # build bin/ourro + a fresh generation image (clean slate)
./bin/ourro      # run the supervised, self-evolving agent in this repo
```

That's the whole story: **`./bin/ourro` keeps using the image you have**
(everything the agent has learned); **`make build` starts over from the
latest source** with the genome re-seeded. `make` alone lists every target.

To use it from any repository:

```sh
make install    # symlink ourro into ~/.local/bin
cd ~/code/some-other-repo
ourro            # the agent works in this repo; its learning lives in $OURRO_HOME
```

## What it is

- **A living image agent** — a pure-Lisp ANSI TUI, streaming LLM client with
  tool use, and a seed genome of 13 genes (tools, UI/HUDs, consent-gated
  automations). The default chrome and reflexes are themselves evolvable.
- **The genome** — the agent's entire evolvable capability set is a git repo
  of `defgene` S-expressions. Images are a *cache*; any generation is
  reproducible by compiling its genome.
- **The verification gauntlet** — every candidate gene passes safe read →
  structural checks → capability lint by a code walker → `compile-file`
  (zero errors/warnings) → generated + regression tests under a watchdog.
- **Hot-load + probation** — a verified gene is spliced into the live image
  with an O(1) revert record; its first uses auto-revert on any error.
- **The supervisor** (`bin/ourro`) — owns the generation ledger, builds each
  generation in a child SBCL via `save-lisp-and-die`, detects crash-loops,
  rolls back to the last good image, and execs seamless restarts with
  session handoff.
- **The evolution loop** — a frequent-episode miner over the event log, an
  LLM propose→repair loop fed compiler-grade diagnostics, and non-blocking
  ticker/inspector UI. Reflexes (trigger-driven automations) go through
  staged consent — nothing fires without a blessing.
- **Safety** — capability wrappers enforced at runtime *and* statically, a
  locked kernel genes cannot name, `/freeze`, `/disarm`, `/revert`, and a
  hardened path: kernel/verifier/supervisor changes can never be hot-loaded.
  `make verify-e2e` proves the supervised build + kernel gate headlessly
  against real generation images.

Architecture:

```
ourro-supervisor (bin/ourro)              ourro-agent (images/gen-NNNN)
  owns the terminal lifecycle             pure-Lisp ANSI TUI
  generation ledger (git + images)  ⇆     Vertex/Bedrock LLM client + tools
  child-process image builder             event log + frequent-episode miner
  crash-loop detection + rollback         evolution engine (propose→verify→
  seamless restart / handoff                hot-load→snapshot)
                                          safety kernel (verifier, caps,
                                            revert tables, probation)
```

## Configuration

Secrets and model choice live in the environment; everything else lives in
`$OURRO_HOME/config.sexp` (created by `make build`; `$OURRO_HOME` defaults to
`~/.ourro/` and holds the ledger, genome git repo, generation images,
sessions, and quarantine).

Set `OURRO_MODEL` to a **friendly alias** — the alias selects both the model
and the provider that serves it:

| `OURRO_MODEL` | Provider | Backend id |
|---|---|---|
| `gemini-3.1-pro` *(default when unset)* | Vertex | `gemini-3.1-pro-preview` |
| `gemini-3.5-flash` | Vertex | `gemini-3.5-flash` |
| `opus-4-6` *(or `opus`)* | Bedrock | `global.anthropic.claude-opus-4-6-v1:0` |
| `sonnet-4-6` *(or `sonnet`)* | Bedrock | `global.anthropic.claude-sonnet-4-6-v1:0` |

Provider auth (one of):

- **Vertex AI Gemini** — an API key (simplest; no gcloud, no project):
  `export OURRO_VERTEX_API_KEY=…` (or `GOOGLE_API_KEY` / `GEMINI_API_KEY`;
  for an AI Studio key also `export OURRO_GEMINI_API=studio`). Or gcloud
  Application Default Credentials plus
  `export OURRO_VERTEX_PROJECT=your-gcp-project`. An API key wins when set.
- **AWS Bedrock (Anthropic Claude)** — a Bedrock API key, no `aws` CLI:
  `export OURRO_BEDROCK_API_KEY=…` (or `AWS_BEARER_TOKEN_BEDROCK`).

Product environment variables:

| Var | Meaning |
|---|---|
| `OURRO_MODEL` | model alias (also picks the provider); a raw backend id works too |
| `OURRO_PROVIDER` | force `bedrock` or `vertex` when the alias isn't enough |
| `OURRO_VERTEX_API_KEY` / `GOOGLE_API_KEY` / `GEMINI_API_KEY` | Vertex/Gemini auth |
| `OURRO_VERTEX_PROJECT`, `OURRO_GEMINI_API` | Vertex ADC project / AI Studio flavor |
| `OURRO_BEDROCK_API_KEY` / `AWS_BEARER_TOKEN_BEDROCK` | Bedrock auth |
| `OURRO_HOME` | install/state root (default `~/.ourro/`) |
| `OURRO_WORKSPACE` | pin the agent's working directory (default: where you launch it) |
| `OURRO_SBCL` | SBCL binary used for generation builds |

If your account's exact Bedrock id differs, override per alias without
touching code: `export OURRO_MODEL_OPUS_4_6=us.anthropic.claude-opus-4-6-v1`.
The alias table lives in `src/llm/bedrock.lisp` (`*model-aliases*`).

## In the TUI

Type to chat. Slash commands:

| command | effect |
|---|---|
| `/genome` | list the current generation's genes |
| `/evolutions` | inspect proposed/applied candidates |
| `/out [n]` · `/out j<id>` · `/out b<n>` | tool-output pager · a job's log · an intern briefing |
| `/log` · `/jobs` | recent event stream · background jobs |
| `/travel <n>` | visit generation *n* read-only (`/travel hard <n>` to re-root) |
| `/onboard` | probe this repo's build/test/lint commands |
| `/freeze` · `/unfreeze` | pause / resume **new** evolution (learning) |
| `/disarm` · `/arm` | stop / resume installed **reflexes** firing (automation) |
| `/revert` | undo the most recent evolution |
| `/mouse` · `/quit` | toggle wheel scrolling · exit |

**Commands are manual overrides; automation is the product.** Mined tools and
reflexes arrive as tickers (`[y install]`), failed jobs arrive diagnosed, an
unknown repo nudges you to onboard. Two levers stay explicit: `/freeze` stops
learning, `/disarm` stops reflexes firing.

Cockpit keys: `Ctrl-E` evolution inspector · `Ctrl-O` tool-output pager ·
`Shift-↑/↓`/PageUp/Down scroll · `End` jump to live bottom · `Esc`/`Ctrl-C`
cancel a turn (`Ctrl-C Ctrl-C` quits) · ticker `e`/`u` explain/undo the
newest evolution · `↑`/`↓` history · Tab completes `/commands`.

## How a tool is grown

1. You repeat an action (e.g. read three files in a row); instrumentation
   logs every tool call to the session event log.
2. The miner spots the repeated n-gram and enqueues a pattern.
3. The evolver assembles a prompt from the *live image* (API surface,
   capabilities, `defgene` grammar, nearest genes) and asks the LLM for one
   `defgene`.
4. The candidate runs the gauntlet in a scratch package; compiler
   diagnostics drive up to three repair rounds.
5. The verified gene hot-loads on probation; the ticker shows
   *"learned: … → tool … · saves ~Ns/use"*.
6. The genome commit goes to the supervisor, which builds `gen N+1` and, at
   the next quiet boundary, restarts into it — conversation intact.

## Development

```sh
make test          # full FiveAM suite
make dev           # run from source, no supervisor (fast iteration)
make smoke         # source loads + genome compiles (CI gate)
make verify-e2e    # headless end-to-end: real build + kernel-path proof (no LLM)
```

To rebuild with the latest code while **keeping** the evolved genome and
generation ledger: `./bin/ourro init --source-dir . --rebuild` (that's
`make build` minus the genome re-seed). Contributor orientation lives in
`AGENTS.md` and `.claude/skills/ourro/SKILL.md`.

Layout:

```
src/kernel/     conditions, capabilities, safe-read, walker, transaction, revert, protocol, handoff
src/observe/    event log, frequent-episode miner, ledger, corrections
src/reflex/     trigger-driven automation: model, journal, compiler, runtime, effects, pilot
src/llm/        JSON helpers, Vertex/Gemini + Bedrock clients
src/tools/      tool protocol (instrumented metaclass + deftool), toolkit helpers
src/genome/     gene objects, defgene, load/hot-load, structural diff
src/verify/     the gauntlet, replay/determinism, verification coordinator
src/tui/        terminal control, ANSI renderer, CLOS component tree
src/evolve/     self-describing prompt, propose→repair→apply engine
src/agent.lisp  session, agentic loop, TUI runloop, supervisor wiring
src/supervisor.lisp   ledger, image builder, crash rollback, handoff
seed-genome/    manifest + 13 seed genes
scripts/        build scripts, dev-run, verify-e2e
tests/          FiveAM suites, grouped by module
qa/             agent-driven QA: operator CLI, missions, cloud loop (qa/README.md)
```

## QA

QA is agent-driven and live-only: an operator agent plays a real user
against a live `ourro` in a tmux sandbox, runs real-world missions, and files
findings as GitHub issues. It's entirely contained in `qa/` and gated behind
`OURRO_QA=1` — the product a real user sees is unchanged. See
[`qa/README.md`](qa/README.md).
