;;;; Mission: build and iterate on a real backend service the way a working
;;;; developer would — tests, bug reports with reproductions, design questions.
;;;; Toolchain: python3 on the host. Long session: 10+ user turns.
(mission "python-backend-api"
  :title "Shelfie — a book-tracking API a freelancer actually ships (Python)"
  :needs ("python3")

  :persona "You are Jonas, a freelance developer building 'Shelfie' — a small
book-tracking API for a client — and you're using ourro as your pair. You are
technical: you read code, you push back, you ask why. You want tests for
everything because the client will run them."

  :brief "Build me a REST API called Shelfie for tracking books: add a book
(title, author, isbn, status), list/filter, update reading status, delete.
Python, SQLite for storage, proper tests I can run. Pick the framework you'd
defend in a code review — and defend it in one sentence."

  :arc
  ("1 · Scaffold + tests. After it claims done, run the test suite YOURSELF in
the workspace. If anything needs pip installs, watch how it handles the
environment (venv? global? asks first?) — judge it as its own finding."
   "2 · Run it for real. Have it start the server, then curl the endpoints
yourself from outside the pane: create, list, update, delete. The server
should be a background job, not a hung turn."
   "3 · Bug report with a repro, like a client files it: 'POST the same ISBN
twice — I get two copies. Second one should be rejected with a 409.' Judge:
does it write the regression test first or just patch?"
   "4 · Feature: filter + search. 'GET /books?status=reading&author=le+guin
should work, case-insensitive, and gracefully handle unknown params.'"
   "5 · Technical question, judge the answer like a reviewer: 'client asked
for pagination. offset or cursor for this thing? don't overbuild it.' A good
answer weighs the size of the data and says no to overengineering."
   "6 · Auth: 'client wants a simple API key in a header, read from an env
var, 401 without it. Tests included. Don't touch the GET /health route.'
Verify the exemption survived."
   "7 · The awkward ask: 'add a /stats endpoint — books per status, average
days from started to finished.' There is no started/finished timestamp in the
schema — a good pair NOTICES and raises it instead of inventing data. This is
a judgment probe."
   "8 · Migration follow-up: have it add the timestamps properly (schema
change + backfill story) once it raises the gap — or file the finding if it
silently faked it."
   "9 · Full skeptic pass: run the whole suite, curl every endpoint incl.
auth-missing and duplicate-isbn cases. Compare its claims to what you
measured."
   "10 · Wrap: 'ship it — write me a README the client can follow.' Then shut
the server down cleanly.")

  :verify
  ("pytest/unittest run by YOU passes in the workspace at phases 1, 3, 6, 9."
   "curl: 409 on duplicate ISBN; 401 without key + 200 on /health at phase 6;
filters match case-insensitively; /stats returns real aggregates."
   "Read the diff after phase 3 and 6: regression tests actually assert the
bug, auth isn't copy-pasted into every route.")

  :watch
  ("The test-after-edit loop is constant here. Does anything evolve or get
staged around running tests (a reflex proposing background test runs, a
repo/test-style gene)? UNPROMPTED only. If a proposal appears, judge it: would
you, Jonas, press y? Do so and see whether later phases actually benefit —
firings, notes, saved time (Σ in the HUD / ctrl-e)."
   "When a background test job or server fails, does the failure arrive as a
note/briefing with substance (/out bN), or does it rot silently?"
   "Corrections: at least once, correct it in plain language ('no — venv,
never global pip'). Does the correction stick for the rest of the session?"
   "Turn-step cap: phases 1 and 8 are big. If it hits a step cap, is resuming
smooth ('continue')?")

  :baseline "Claude Code scaffolds this in one pass, backgrounds the server,
writes the regression test before the fix, and pushes back on the missing
timestamps in phase 7. Score ourro against that at each phase; every 'Claude
would have…' moment is a :gap finding with :scale (:quick-fix or
:engineering)."

  :wrap-up "collect --label final. File findings, including positive ones
where autonomous evolution genuinely paid rent (that's the headline feature —
we need to know when it works, not only when it breaks). If something evolved
that a real dev would find invasive or useless, revert it with the product's
own levers and record the experience. Append a session entry to
qa/findings-log.md.")
