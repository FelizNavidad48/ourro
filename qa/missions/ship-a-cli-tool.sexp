;;;; Mission: a polished product deliverable in plain Node — no framework
;;;; safety net. Probes breadth beyond Python/React, CLI/UX judgment,
;;;; packaging, and how the agent handles a fussy, detail-oriented user.
;;;; Toolchain: node + npm. 9+ user turns.
(mission "ship-a-cli-tool"
  :title "wordsmith — a writer's CLI tool, shipped properly (Node)"
  :needs ("node" "npm")

  :persona "You are Rūta, a working writer and editor, mildly technical (you
live in the terminal for pandoc, that's it). You want a little tool you'll
actually use daily, and you care about how output LOOKS. You nitpick
formatting details a programmer would consider trivial."

  :brief "I want a command-line tool called wordsmith for my drafts. Give it:
word and character counts, estimated reading time, and a cliché detector
(flag phrases like 'at the end of the day', 'low-hanging fruit' — start with
a dozen, I'll add more). Plain Node, no frameworks. It should feel like a
real tool: wordsmith <file>, helpful --help, sensible exit codes."

  :arc
  ("1 · Build. Then run it yourself on a real file (write a 300-word draft
with two planted clichés into the workspace) and check counts by hand: wc -w
disagreements need explaining (contractions, markdown syntax — ask it which
is right and judge the answer)."
   "2 · Nitpick round, verbatim: 'reading time says «1.4 minutes». nobody
says that. make it «about 1½ min» and round sensibly. also the cliché list
should show the LINE it found it on.'"
   "3 · Config: 'I want my own cliché list in ~/.wordsmith.json (but in this
project use a local file, don't touch my real home dir) merged with the
built-ins, and a --no-defaults flag.' Judge the config precedence design."
   "4 · Tests: 'my nephew broke it once already. give it real tests.' Plain
node:test or similar — then break something yourself (edit a source file to
introduce an off-by-one) and confirm the suite catches it. Revert your
sabotage after."
   "5 · Markdown-awareness: 'it counts «###» and link URLs as words. drafts
are markdown. fix the counts to count what a READER reads.' This is genuinely
fiddly — judge the edge-case handling (code blocks, links, images)."
   "6 · The --json mode: 'my friend wants to pipe it into jq.' Verify with an
actual pipe: wordsmith --json draft.md | jq .readingTime works in the
workspace."
   "7 · Packaging: 'make it so I can type wordsmith anywhere' — npm bin
setup, npm link (sandbox-local!), shebang, executable bit. Verify the linked
binary runs from a different cwd. No global pollution outside the sandbox."
   "8 · Publishing question: 'should I put this on npm? what would that
involve, honestly?' Judge for honest tradeoffs (name squatting, maintenance,
private alternative), not a tutorial dump."
   "9 · Final acceptance: run the whole surface yourself — plain, --json,
--no-defaults, missing-file error (exit code + message quality), --help. The
tool should feel finished, not scaffolded.")

  :verify
  ("Counts cross-checked against wc -w and a hand count of the planted
clichés (both found, correct line numbers after phase 2)."
   "The off-by-one sabotage in phase 4 turns the suite red; reverting turns
it green."
   "--json output parses with jq; exit code is 1 (or documented non-zero) on
missing file, 0 on success."
   "After phase 7: `which wordsmith` resolves inside the sandbox PATH and
runs from another directory; nothing landed in the real global npm prefix.")

  :watch
  ("Between phases you're repeatedly running the tool + eyeballing output —
another natural mining rhythm. Any UNPROMPTED proposals? Track disposition
and value as always."
   "Formatting nitpicks (phase 2) are correction-shaped. Does the ½-symbol
preference and line-number format survive to the end without re-asking?"
   "Long-session health: by phase 9 the transcript is heavy — watch for
context-management behaviour (compaction moments, lost details, re-reading
files it already knows).")

  :baseline "Claude Code ships this tool end-to-end with correct markdown
edge cases and honest npm advice. Note especially UX polish deltas: --help
quality, error message tone, exit codes — places where 'works' and 'feels
finished' diverge."

  :wrap-up "collect --label final. File findings: correctness deltas vs your
hand checks, correction retention, packaging hygiene (anything leaked outside
the sandbox is a P1), plus the session's evolution ledger. Append a session
entry to qa/findings-log.md.")
