;;;; Mission: a real business landing page, built the way a real client asks
;;;; for one — vaguely, iteratively, with feedback and a bug report.
;;;; Toolchain: node + npm on the host. Long session: 10+ user turns.
(mission "react-landing-page"
  :title "Landing page for Driftwood Coffee Roasters (React)"
  :needs ("node" "npm")

  :persona "You are Maya, who runs Driftwood Coffee Roasters — a small-batch
coffee roastery in a coastal town. You are not a programmer. You describe what
you want in plain business language, you react to what you're shown, and you
change your mind once. You heard this tool can build you a website."

  :brief "I run a small coffee roastery called Driftwood Coffee Roasters and I
need a simple landing page. Something warm and modern — who we are, our
current roasts, where to find us. Can you build it in React and show me?"

  :arc
  ("1 · Scaffold. Give the brief and let it work. It should scaffold a React
app (Vite or similar), build hero/story/roasts/visit sections, and START THE
DEV SERVER so you can look at it. Note whether the dev server runs as a
background job (jN in the transcript, /jobs lists it) or wedges the chat —
a blocked chat here is a P1-grade workflow finding."
   "2 · Look at it like a client. Fetch the page yourself (curl the dev-server
URL from outside the pane) and react to the actual content: 'the top section
feels flat — I want our tagline «slow roasted by the sea» front and center,
warmer colors.'"
   "3 · Real data. Paste this as your roast list and ask for a menu section
driven by it, with sold-out handling: Ember (dark, notes of cocoa, 14€),
Driftline (medium, stone fruit, 13€), First Light (light, floral, 13€ — SOLD
OUT until March)."
   "4 · Bug report, vague on purpose: 'on my phone the menu at the top sits on
top of the words and I can't press anything.' Judge how it reproduces,
narrows, and fixes a mobile-nav overlap it cannot literally see."
   "5 · Change of mind: 'actually drop the newsletter box, my nephew says
nobody signs up. Put our instagram there instead.'"
   "6 · Add a contact/visit section with opening hours and a map link. You
don't know what 'a map link' means technically — let it decide and judge the
choice."
   "7 · Ask a real question: 'what would it cost me to put this online, and
where? I don't want to pay much.' Judge the answer as advice to a
non-technical business owner."
   "8 · Production build. 'okay make me the final version I can upload.' It
should run a production build, verify it, and tell you what to upload. Check
dist/ yourself."
   "9 · While it worked: did anything evolve, stage a reflex, or post a note?
Was any of it useful? See the :watch list — this is observed, never asked
for."
   "10 · Wrap: kill the dev server ('are we done? shut it all down') — the job
should be reaped cleanly, no orphan node processes in the sandbox.")

  :verify
  ("curl the dev server during phases 2-6: the content you asked for is
actually served (tagline text, roast names, SOLD OUT marker)."
   "After phase 8: dist/ exists in the workspace, index.html references built
assets, and `npx serve`/`python3 -m http.server` on dist/ serves the page."
   "grep the workspace for the instagram handle and the dropped newsletter
markup — confirm the change of mind was fully applied, not half-applied."
   "After wrap-up: `pgrep -f vite` (scoped to the sandbox path) finds
nothing.")

  :watch
  ("Does the dev server go through the background-job machinery (job start
note, /jobs, /out jN for its log) instead of blocking the turn?"
   "The edit→look→edit loop is this mission's natural rhythm. Does the miner
notice anything (staged proposals in the ticker, ctrl-e inspector)? Does a
reflex proposal appear UNPROMPTED — e.g. anything reacting to repeated edits
or a dying dev server? Judge value, not existence."
   "If the dev server dies mid-session (kill it yourself once if it never
happens naturally — that's a legitimate accident a real user has), does a note
or briefing surface proactively, or do you find out only when you next look?"
   "Prompt-cache/context behaviour on a long session: does the session stay
responsive at turn 12+, or degrade?")

  :baseline "At each phase ask: what would Claude Code have done here? It
scaffolds without blocking, backgrounds dev servers, reproduces mobile-nav
bugs from a description, and gives grounded deploy advice. Any place ourro
needed hand-holding Claude wouldn't need, or lacked a capability Claude has
(e.g. reading the rendered page, web knowledge for deploy pricing) → file a
:gap finding with :scale."

  :wrap-up "collect --label final. File findings for: chat blocked by any
long-running process; claims not matching the served page; evolution that
fired and helped (positive finding — note it); evolution/reflexes that fired
and wasted time (use u / the inspector to revert, and record how the revert
UX went); capabilities Claude Code has that ourro lacked. Append a session
entry to qa/findings-log.md.")
