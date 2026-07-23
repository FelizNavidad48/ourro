# ourro

A self-evolving Common Lisp coding agent. It runs as a living SBCL image
that watches how you work, writes new tools for itself as S-expressions,
verifies them with the compiler, hot-loads them into the running session,
and restarts into a new generation of itself with the conversation intact.

> Other agents take notes about you. ourro grows organs.

What it learns is compiled, tested code, not Markdown notes. A learned
behaviour costs zero tokens at runtime, is verified before it ever runs, and
can always be reverted.

## Install

You need SBCL 2.6+, [Quicklisp](https://www.quicklisp.org), and an API key
(see below).

```sh
make build       # build bin/ourro and a fresh agent image
./bin/ourro      # run it in the current repo
```

To use it from any repository:

```sh
make install     # symlink ourro into ~/.local/bin
cd ~/code/some-other-repo
ourro
```

`./bin/ourro` keeps the image you have, including everything the agent has
learned. `make build` starts over from source and re-seeds the genome.
`make` alone lists every target.

## Configuration

Pick a model and set its key; the model name selects the provider:

```sh
export OURRO_MODEL=sonnet-4-6       # or opus-4-6, gemini-3.1-pro, gemini-3.5-flash
export OURRO_BEDROCK_API_KEY=…      # Claude models (AWS Bedrock)
export OURRO_VERTEX_API_KEY=…       # Gemini models (Vertex AI)
```

`OURRO_MODEL` defaults to `gemini-3.1-pro`. `AWS_BEARER_TOKEN_BEDROCK`,
`GOOGLE_API_KEY`, and `GEMINI_API_KEY` work as fallbacks, and Vertex can
also authenticate through gcloud ADC if you set
`OURRO_VERTEX_PROJECT=<your-gcp-project>`.

Everything else lives in `$OURRO_HOME/config.sexp`. `$OURRO_HOME` defaults
to `~/.ourro/` and holds the genome, generation images, and sessions. Other
variables you may want: `OURRO_WORKSPACE` (pin the agent's working
directory), `OURRO_PROVIDER` (force `bedrock` or `vertex`), and `OURRO_SBCL`
(the SBCL used for generation builds).

## How it works

- The agent's entire capability set is a git repo of `defgene`
  S-expressions: the genome. Images are a cache; any generation can be
  rebuilt from its genome.
- Every tool call is logged. A pattern miner spots repeated work and asks
  the LLM for one new gene.
- Each candidate passes a gauntlet: safe read, structural checks, a
  capability lint by a code walker, `compile-file` with zero warnings, then
  generated and regression tests under a watchdog.
- Verified genes hot-load on probation with an O(1) revert record; an error
  during first uses reverts them automatically.
- A supervisor (`bin/ourro`) owns the generation ledger, builds each
  generation in a child SBCL, detects crash loops, rolls back to the last
  good image, and restarts seamlessly.
- Reflexes (trigger-driven automations) fire only after you bless them.
  Kernel, verifier, and supervisor changes can never be hot-loaded.

## In the TUI

Type to chat. Tab completes the full `/command` list; the ones you'll reach
for:

| command | effect |
|---|---|
| `/genome` · `/evolutions` | what the agent has learned / is proposing |
| `/freeze` · `/unfreeze` | pause / resume learning |
| `/disarm` · `/arm` | stop / resume reflexes firing |
| `/revert` | undo the most recent evolution |
| `/onboard` | probe this repo's build/test/lint commands |
| `/theme light` · `/theme dark` | switch the warm-paper / dark TUI palette |
| `/quit` | exit |

Learned tools and reflexes arrive as ticker prompts (`[y install]`); press
`y`/`n` to accept or dismiss, `e`/`u` to explain or undo the newest one.
`Ctrl-E` opens the evolution inspector, `Ctrl-O` the tool-output pager.

## Development

```sh
make test          # full FiveAM suite
make dev           # run from source, no supervisor (fast loop)
make smoke         # source loads + genome compiles
make verify-e2e    # headless supervised build proof, no LLM
```

Contributor orientation lives in [`CONTRIBUTING.md`](CONTRIBUTING.md) and
`AGENTS.md`. QA is agent-driven and live-only: an operator agent plays a
real user against a live ourro and files findings as GitHub issues; see
[`qa/README.md`](qa/README.md).

## License

[MIT](LICENSE).
