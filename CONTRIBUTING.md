# Contributing to ourro

Thanks for wanting to work on ourro. This page covers the mechanics: setup,
the test gates, and how a change gets merged.

## Setup

You need SBCL 2.6+ and [Quicklisp](https://www.quicklisp.org) installed at
`~/quicklisp/`. Then:

```sh
make test    # full FiveAM suite — must be green before and after your change
make dev     # run the agent from source, no supervisor (fast iteration)
make smoke   # source loads + seed genome compiles
```

`make` alone lists every target.

## Read this first

`AGENTS.md` and `.claude/skills/ourro/SKILL.md` are the contributor
orientation: the architecture map and the gotchas that cost the most time
(FiveAM test forms, the length-prefixed supervisor protocol, tool-symbol
interning, tty redirection, pty testing). Ten minutes there saves hours.

One distinction matters more than any other: **`src/` is the kernel,
`seed-genome/` is the agent's starting capability set.** Genes are `defgene`
S-expressions that live in `$OURRO_HOME/genome/` at runtime; the copies in
`seed-genome/` are only the seeds. If you are changing what the agent can
*do*, you are probably editing a gene. If you are changing how genes are
verified, loaded, or supervised, you are in `src/`, and the bar is higher:
the safety kernel, verifier, and supervisor are the parts that keep
self-modification honest.

## Making a change

1. Branch from `main`. Direct pushes to `main` are blocked.
2. Make the change, with tests. Every behavioural change needs a FiveAM test
   in `tests/` (suites are grouped by module, mirroring `src/`).
3. Run `make test` and `make smoke` locally. For anything touching the
   supervisor, image build, or kernel path, also run `make verify-e2e` — it
   proves the supervised build headlessly against real generation images,
   no LLM needed.
4. Open a pull request against `main`.

A PR merges when CI is green (`make test`, `make smoke`, `make verify-e2e`)
and a maintainer has approved it. Both are enforced by branch protection,
not convention.

Keep PRs focused: one change per PR, commit messages in the imperative
(`fix supervisor crash-loop detection`, not `fixed…`). Match the style of
the surrounding code — the codebase leans on docstrings and comments that
explain *why*, not *what*.

## Bugs and findings

File bugs as GitHub issues with a reproduction. QA findings from the
agent-driven QA system (see `qa/README.md`) also land as issues, labelled
`qa-finding` — that is the public defect record; nothing under
`qa/findings/` or `qa/reports/` is committed.

## A note on `docs/`

`docs/` is a gitignored local scratch area for plans and working notes. Do
not add files there expecting them to ship — anything contributors need
belongs in `README.md`, `AGENTS.md`, this file, or `qa/README.md`.

## License

ourro is MIT licensed. By contributing you agree that your contributions are
licensed under the same terms.
