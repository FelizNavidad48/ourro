# M8 — Live-Gemini shoot runbook

The end-to-end **supervised build + kernel-path proof** is automated and headless
— run `make verify-e2e` (see `scripts/verify-e2e.sh`); it needs no network. This
runbook covers the other half of M8: the **live-Gemini demo beats** (PRD §12),
which need a real Vertex/Gemini connection and are interactive by design. Assert
every beat from `events.sexp` and the logs — **never** by screen-scraping the alt
screen (the TUI owns the tty; a stray read corrupts the frame).

## Prerequisites

Authenticate one of two ways — an **API key** (simplest; no gcloud, no project)
or **gcloud ADC**.

**API key (recommended):**

```sh
export OURRO_VERTEX_API_KEY=<your-vertex-api-key>   # also GOOGLE_API_KEY / GEMINI_API_KEY
```

The key wins whenever it's set: requests go to Vertex's global publisher
endpoint with an `x-goog-api-key` header, so no project or gcloud login is
needed. If the key is an **AI Studio** (Gemini Developer API) key rather than a
Vertex one, also `export OURRO_GEMINI_API=studio` to route to
`generativelanguage.googleapis.com`. Confirm it reaches Gemini before the shoot:

```sh
make dev   # then in the agent, send one message and watch a reply stream back
```

**gcloud ADC (alternative):**

```sh
gcloud auth application-default login          # interactive; opens a browser
export OURRO_VERTEX_PROJECT=<your-gcp-project>  # or rely on `gcloud config`
gcloud auth application-default print-access-token >/dev/null && echo ADC-OK
```

## Setup

Use a throwaway home so nothing touches `~/.ourro`:

```sh
export OURRO_HOME=/tmp/oh-live
rm -rf "$OURRO_HOME"
OURRO_HOME=/tmp/oh-live make build     # supervisor + base core + gen-0001
OURRO_HOME=/tmp/oh-live ./bin/ourro     # the supervised, self-evolving agent
```

### Where to look (assert here, not on screen)

| Path | What |
|---|---|
| `$OURRO_HOME/sessions/<id>/events.sexp` | the observation stream, one sexp/line |
| `$OURRO_HOME/state/supervisor.log` | supervisor: builds, restarts, restore budget |
| `$OURRO_HOME/state/agent-output.log` | agent stdout/stderr while the TUI is up |
| `$OURRO_HOME/ledger.sexp` | generation records (`:id :status :commit :image`) |

Handy watchers in a second terminal:

```sh
tail -f "$OURRO_HOME/state/supervisor.log"
tail -f "$OURRO_HOME"/sessions/*/events.sexp
```

---

## The six PRD §12 beats

### 1 · Watch it grow an organ (deliberate + mined evolution)

- **Do:** ask the agent for a new capability ("add a tool that reads three files
  at once"), or repeat a tool pattern (read three files) three times so the miner
  fires. On the 4th, the ticker announces `learned: … → tool … · est. …`.
- **Assert:**
  - `events.sexp` contains a `:kind :evolution-hot-load` (the engine's hot-load
    event) and a subsequent `:kind :tool-call :gene "tool/…"` using the new tool
    the same turn.
  - `ledger.sexp` grows a `gen-0002` with `:STATUS :GOOD` and a fresh `:COMMIT`
    (the supervisor built and registered it, then handed off).
  - **Evolution HUD (M7-3):** the status-bar cell reads `"8 genes · watching"`
    before any measured payback, then flips to `"Σ <dur> saved · N genes"` after
    the evolved gene has been used enough for the utility ledger to measure it
    (`$OURRO_HOME/state/utility.sexp` gains a `:baseline-ms` + `:uses` for it).

### 2 · Try to kill it (probation revert + `kill -9` recovery)

- **Do (probation):** force a bad gene — `propose_gene` a tool whose body errors
  on use (e.g. divides by zero), then call it. It must revert on first use, and
  the turn completes with the previous definition.
  - **Assert:** `events.sexp` has `:kind :probation-revert :gene …`; an amber
    ticker fired; the tool still works afterward.
- **Do (crash):** `kill -9 $(cat "$OURRO_HOME/state/supervisor.pid")` (or the agent
  pid) mid-conversation.
  - **Assert:** `supervisor.log` shows the crash branch resuming
    `state/checkpoint.sexp` with `--resume`, and a
    `session restored in N.NNs (budget 2s: ok)` line (**PR-5 restore budget**).
    The reborn agent's transcript still has the prior conversation (the checkpoint
    is consumed at most once; a re-crash renames it `-poisoned`).

### 3 · The agent redecorates (UI evolution — "add a clock widget")

- **Do:** ask "add a clock widget to your status bar" (or ask three times "what's
  the diff?" to trigger a diff pane). The agent writes a `:ui`-capability gene
  through the gauntlet and hot-loads it; the widget appears mid-session (no
  restart) via `UPDATE-INSTANCE-FOR-REDEFINED-CLASS`.
- **Assert:** `events.sexp` shows the gene hot-loaded with `:capabilities (… :ui)`;
  `list_genes` (or `/genome`) lists it; the widget's cell appears in the status
  bar (confirm via the gene's own registration, not a screen grab).

### 4 · Time travel to a **pruned** generation (forces M5-1 rebuild-on-demand)

- **Setup:** evolve forward several generations (repeat beat 1) until image GC has
  pruned an early one — `ls "$OURRO_HOME/images/"` should be missing e.g.
  `gen-0002` while the ledger still lists it (GC keeps current + 3 newest good +
  quarantine parents).
- **Do:** `/travel 2` (a pruned generation).
- **Assert:** `supervisor.log` shows `rebuilding gen-0002 image from commit …`
  (M5-1 rebuild-on-demand via a throwaway `state/worktrees/<id>/` git worktree),
  then a clean boot into the visiting session; `/travel hard` back re-roots.

### 5 · Cold onboarding (`/onboard` on a scratch npm repo)

- **Setup:** in another dir, `mkdir /tmp/npm-demo && cd /tmp/npm-demo && npm init -y`
  and add a trivial `test`/`lint` script to `package.json`; start the agent with
  its workspace at that repo.
- **Do:** `/onboard`.
- **Assert:** `events.sexp` shows the probe run for each build/test/lint command
  and a grown `repo/<role>` gene per green command; `/genome` lists them; the
  toolchain summary is added to the conversation.

### 6 · While you were away (dream mode staging + inspector `a` apply)

- **Do:** leave the agent idle > `*dream-idle-seconds*` (120s) after a session with
  some friction (repeated patterns / a correction). Dream mode mines and stages
  candidates **without applying** them.
- **Assert:** the return ticker reads `dream mode: built N candidate(s) … (staged,
  not applied)`; `events.sexp` has the staged candidates; open the inspector
  (`F2`), select a `◐ staged` candidate, press `a` — it now hot-loads and a
  `gen-N` snapshot builds. (Dream **stages**; only `a` applies — never auto-apply.)

---

## Kernel-path verdict (the live half of the kernel gate)

The headless harness proves the always-on half (selftest + lock + rebuild). The
**replay verdict** fires only on a *kernel-touching generation build*:

- **Do:** stop the agent, `touch src/kernel/conditions.lisp`, run `./bin/ourro` again so
  the supervisor rebuilds base.core (`supervisor.log`: `building base core`), then
  trigger any generation build (evolve a gene).
- **Assert:** `supervisor.log` shows the replay verdict for that build. A clean
  build prints `[ourro] replay: 0 divergences across M session(s).` (the kernel
  change didn't alter read-only tool behavior); a *real* divergence does **not**
  print a count — it fails the build with a `read-only tool traces diverged …`
  report and deletes the staging image. When there's no `--replay`-capable
  baseline you'll instead see `[ourro] replay gate: … skipped.`. The staging smoke
  boot's `kernel selftest OK` / `OURRO.KERNEL locked: T` output is captured by the
  build (surfaced only in the failure report if it fails); to see it directly,
  run `<image> --smoke` — this is exactly what `make verify-e2e` automates.

---

## M7 cockpit beats (confirm the UX landed live)

While a turn is streaming and afterward:

- **Cancel:** press `Esc` (or `Ctrl-C` once) mid-stream → partial text kept, a dim
  `⏹ (cancelled)` line, and the **next** turn works (proves the synthesized
  functionResponses — `events.sexp` has `:kind :turn-cancelled`). `Ctrl-C Ctrl-C`
  (or `Ctrl-C` while idle) quits.
- **Scroll:** mouse wheel / `Shift-↑↓` / PageUp-Down scroll; the status bar shows
  `· ↑N`; `End` jumps back to the live bottom.
- **Pager:** `Ctrl-O` (or `/out [n]`) opens the tool-output pager; `[`/`]` walk
  entries; `j/k`/wheel scroll; `q` closes.
- **Width:** paste a line with emoji/CJK (e.g. `中文 ⚡`) — columns stay aligned
  (wcwidth, M7-2).
- **Markdown:** a streamed reply with a heading / `**bold**` / ``` fence renders
  as markdown live, and the finalized message is identical (no pop-in).
- **Primer:** a genuinely cold boot (empty transcript) shows the 4-line primer +
  `try: /onboard …`; a resumed session skips it.

---

## After the shoot

Flip the honesty notes in `README.md` / `docs/ROADMAP.md` from "runbook ready,
live shoot pending gcloud ADC" to "proven live" for each beat that passed — or
file the defects found, exactly as any other milestone.
