# Fully asynchronous evolution — design note

Status: **thinking only, deliberately not implemented** (QA feedback 2026-07:
"evolution should not interrupt user flow — be asynchronous from the rest of
the process, but maybe hold off for now").

## What is already asynchronous

The evolution pipeline mostly stays off the user's path today:

- **Mining** runs on the UI thread but is a cheap in-memory pass over recent
  events (`maybe-mine`, every 20s) — not user-visible.
- **Propose → verify → hot-load** runs on the `ourro-evolver` worker thread
  (`spawn-evolver`), including the new LLM duplicate-tool gate. The user can
  keep typing and running turns throughout.
- **Snapshot builds** (the minutes-long image build) run `:async` on the
  `ourro-snapshot` thread.
- **Dream mode** only runs after 120s of idleness and only stages candidates.

## Where the user flow IS still interrupted

1. **The seamless generation restart (the big one).** After a snapshot builds,
   `ui-loop` waits for a quiet boundary (idle ≥10s, empty input, not busy) and
   then execs into the new generation. Even "seamless", it:
   - drops keystrokes typed during the ~1–3s gap;
   - previously blanked the screen / lost the ❯ prompt (now mitigated:
     `*keep-screen-on-exit*` leaves the last frame up through the gap);
   - resets in-image transients (tool-output ring, etc.).

2. **Verifier CPU contention.** The gauntlet compiles and runs tests in-process
   on the worker thread; on a big gene it can make the UI thread's paints/turns
   noticeably jankier (shared image, shared GC).

3. **Deliberate evolution (`propose_gene`)** blocks the model's turn by design
   — the model wants to use the tool on its next step. This one *should* stay
   synchronous.

## Options, in increasing order of ambition

- **A. Defer restarts harder (cheap, do first).** The hot-loaded gene is
  already live in-image; the restart only exists to re-root on a durable
  image. So: restart only on much stronger quiet signals (e.g. 5+ min idle, or
  at `/quit`, or overnight in dream mode), and batch several evolutions into
  one restart. Risk: a crash before the deferred restart loses nothing durable
  (the genome commit exists; the image is a cache) — so this is nearly free.

- **B. Out-of-process verification.** Run the gauntlet in a child SBCL (the
  supervisor already knows how to build images in children) and only hot-load
  the verified source in the live image. Removes GC/CPU contention entirely;
  costs child-startup latency per candidate, which is fine on a background
  path.

- **C. No restarts at all.** Treat the running image as permanently live and
  let the supervisor keep building images purely as crash-recovery caches,
  never exec'ing into them while a session is open. The generation counter
  then ticks without a process swap. This is the true "never interrupt"
  design; it needs confidence that hot-load state == rebuilt-image state
  (the replay gate already checks exactly this equivalence, so C is mostly a
  policy change plus a lot of QA).

## Recommendation

A → C over time; B if verifier jank is ever measured to matter. A alone
(batching + stronger quiet detection) removes ~all user-visible interruption
for the cost of a config knob and is the natural next step when this is
picked up.
