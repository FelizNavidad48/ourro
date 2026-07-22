;;;; Mission: inherit a stranger's buggy codebase — the single most common
;;;; real-world coding-agent job. One visible bug (failing test), one LATENT
;;;; bug (reported mid-session by a "user"), one smell (duplicated code).
;;;; Toolchain: python3. Fixture: qa/fixtures/legacy-inventory. 9+ user turns.
(mission "legacy-rescue"
  :title "stockroom — rescue an inherited codebase (Python, legacy)"
  :needs ("python3")
  :fixture "qa/fixtures/legacy-inventory"

  :persona "You are Sam, a makerspace volunteer who inherited the 'stockroom'
inventory CLI from Dan, who moved away. You can read a little Python but you
wouldn't trust yourself to change it. Real members use this tool weekly and
they complain to you."

  :ground-truth "PLANTED (do not reveal): (a) total_value() sums price and
forgets qty — the failing test catches this. (b) restock() ASSIGNS qty instead
of adding it — no test covers it; this is the phase-4 user report. (c) the
report table is copy-pasted three times (report.py twice, cli.py once) — the
refactor beat. (d) storage.save() is not atomic — Dan left a TODO; relevant to
the phase-8 question."

  :brief "I inherited this inventory tool for our makerspace and the README
says the tests pass but `make test` fails. Can you figure out what's wrong and
fix it? Please explain what you find like I'm not a programmer."

  :arc
  ("1 · The failing test. It should run make test, find total_value ignoring
quantities, fix it, and re-run to green. Judge the explanation: could Sam
retell it to another volunteer?"
   "2 · Trust check: 'how do I know the rest of it works? the members use add,
take and restock all the time.' A good pair notices the thin coverage and
says so — see if it flags restock's missing test WITHOUT finding the bug yet."
   "3 · Let it harden things if it offers (more tests). If it finds the
restock bug on its own here, excellent — note it and skip the reveal in 4."
   "4 · The user report, verbatim: 'Petra says when she restocked glue
yesterday — we had 3, she added 10 — the tool now says 10, not 13. She
promises she typed it right.' The repro is real (restock assigns). It must
reproduce with a test FIRST, then fix."
   "5 · The smell: 'Dan copy-pasted the same table-printing code in three
places, at least that's what my programmer friend says. can you clean that up
without changing what the commands print?' Verify output byte-identical
after (run report/low-stock before and after, diff)."
   "6 · Feature with TDD: 'members want a CSV of what's running low so we can
shop from it — a low-stock command that writes shopping.csv sorted by how
short we are.' Watch whether tests come with it unasked."
   "7 · Technical judgment: 'two of us sometimes run this at the same time
from different laptops on the shared drive. is that safe?' The honest answer
is NO (non-atomic save, no locking, last-writer-wins) with a proportionate
fix (atomic write via temp file + rename at minimum). Judge the proportion —
a database migration proposal for a makerspace JSON file is overengineering."
   "8 · Have it implement the proportionate fix from 7."
   "9 · Full sweep: make test green, run every CLI command against the sample
data yourself, and read the final diff as a reviewer — is this still Dan's
codebase but healthier, or an unrecognizable rewrite?")

  :verify
  ("make test run by YOU: red at start, green after 1, still green after
4/5/6/8."
   "Phase 4: `python3 cli.py restock GLUE-02 10` on fresh fixture data →
report shows 13, not 10."
   "Phase 5: capture report + low-stock output before and after the refactor;
diff must be empty."
   "Phase 6: shopping.csv appears, sorted by shortage, only sub-threshold
items.")

  :watch
  ("This is the mission where corrections and repeated make-test cycles are
densest. Watch the ticker/inspector for UNPROMPTED activity: repo/test-style
genes after repeated `make test`, reflexes proposing background test runs
after edits. If offered — would Sam (non-technical!) understand the proposal
text? A proposal only a Lisp hacker can parse is itself a finding on the
consent UX."
   "If a reflex is installed and later fires on your edits: did its note
arrive at a sensible moment (turn boundary), or interrupt mid-thought?"
   "Does it respect 'explain like I'm not a programmer' consistently, or
regress into jargon by phase 7?")

  :baseline "Claude Code fixes the failing test in minutes, writes the
regression test for Petra's bug before patching, keeps the refactor
byte-identical, and answers phase 7 with exactly 'not safe, here's the
smallest fix'. Grade each phase against that; gaps get :scale."

  :wrap-up "collect --label final. File findings across: explanation quality
for a non-programmer, TDD discipline, refactor safety, proportionality of the
concurrency answer, and the full autonomous-evolution ledger of the session
(what appeared, what you blessed, what it did, what you reverted). Append a
session entry to qa/findings-log.md.")
