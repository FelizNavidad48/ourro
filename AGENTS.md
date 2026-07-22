# ourro

A self-evolving Common Lisp (SBCL) coding agent: supervisor + living agent
image, git-backed genome of `defgene` S-expressions, compiler-backed
verification gauntlet, hot-load with revert/probation, seamless generation
restarts.

## Commands

- `make test` — full FiveAM suite
- `make dev` — run from source, no supervisor (fast loop)
- `make build && ./bin/ourro` — clean-slate build, then run the full supervised loop
  (`OURRO_HOME=/tmp/oh …` for a scratch home)
- `make smoke` — load + genome compile + boot check

## Before editing

**Read `.claude/skills/ourro/SKILL.md` first** — architecture map and the
gotchas (FiveAM forms, length-prefixed protocol, tool-symbol interning, tty
redirection, pty testing). Genes live in `$OURRO_HOME/genome/`, not `src/`;
seed copies in `seed-genome/`. Status + next steps: `docs/ROADMAP.md`;
product requirements: `docs/greenfield-lisp-self-evolving-agent.md`.
