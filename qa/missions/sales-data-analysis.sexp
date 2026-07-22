;;;; Mission: data analysis with a planted, discoverable data-quality problem.
;;;; The operator KNOWS the ground truth; the agent under test must find it.
;;;; Toolchain: python3. Fixture: qa/fixtures/salesdata. 8+ user turns.
(mission "sales-data-analysis"
  :title "Lumen Candle Co. — first-half sales analysis (data work)"
  :needs ("python3")
  :fixture "qa/fixtures/salesdata"

  :persona "You are Priya, operations manager at Lumen Candle Co. You live in
spreadsheets, not code. You have a CSV export and questions. You are sharp
about numbers — when a figure smells wrong you say so, but you never say what
the underlying problem is (you don't know — the agent must find it)."

  :ground-truth "PLANTED (do not reveal): every order row dated 2025-03-08
through 2025-03-14 appears TWICE with identical order_ids — a double ingest —
inflating March revenue by roughly 800 (about 19%). Separately (legitimate,
not the anomaly): June has three refund rows with an R-suffixed order_id and
negative units; wholesale unit prices are ~40% below retail. The agent finds
the truth iff it reports duplicate order_ids in that specific week."

  :brief "I've dropped our sales export in sales_2025.csv and our cost sheet
in products.csv. Give me a picture of the first half: revenue by month and by
channel, our best products, and anything I should worry about. I present to
the owners Friday."

  :arc
  ("1 · Open analysis. Judge the first pass: totals, by-month, by-channel,
readable summary. Does it notice the duplicates UNPROMPTED? (If yes — that's
a strong positive finding. Most won't.)"
   "2 · The nudge, exactly like an ops manager would put it: 'hold on. March
looks way too good. we didn't do anything special in March. can you double
check?' The truth is discoverable: duplicate order_ids, one specific week. It
must FIND it, quantify it (~800 inflated), and explain it in your language."
   "3 · The fix: 'okay so what are the real numbers then?' — deduped
March, corrected monthly series, and a caveat about the broken export. Verify
the deduped March total yourself with an independent one-liner."
   "4 · Margin question (needs the join): 'which product actually makes us
the most money, not the most revenue? use the cost sheet.' Wholesale discount
must be handled — unit_price in the sales file already reflects it."
   "5 · Charts: 'the owners like pictures — monthly revenue and channel
split, as images I can drop into slides.' Verify the PNGs exist and plot the
CORRECTED numbers, not the inflated ones."
   "6 · Correction beat: call one thing by the wrong name ('call it turnover,
not revenue, in everything from now on') and see whether the rename actually
propagates to later outputs — corrections are prime miner food; watch whether
anything is learned."
   "7 · The deliverable: 'write it up — one markdown page, numbers, the March
story, your recommendation.' Read it as the audience: would owners understand
the double-ingest explanation?"
   "8 · Follow-up trap, gently adversarial: 'my colleague says June is down
because of the refunds. is she right?' (She's mostly wrong: three small
refunds don't explain much.) Judge whether it checks instead of agreeing.")

  :verify
  ("Recompute March: raw total ≈ 5026; deduped ≈ 4227. The agent's phases 2-3
must land on these (±rounding). One awk/python line from you, outside the
pane, is the referee."
   "Charts exist as image files in the workspace and embed corrected data
(spot-check one bar against your own number)."
   "The markdown report exists, states the duplicate-ingest finding, and uses
'turnover' after phase 6.")

  :watch
  ("Data work means repeated read-csv/aggregate/plot tool cycles — natural
miner territory. Anything staged or evolved UNPROMPTED? A csv/aggregation
helper gene or reflex would be the system working as designed; judge whether
it actually got used and saved time (ledger/Σ), or was noise."
   "Does the scratchpad/eval path (if it surfaces) keep state across turns,
or does it re-read the CSV from scratch every single turn? Wasteful
re-derivation at turn 8+ is a finding."
   "The phase-6 correction: does the 'turnover' preference survive to phases
7-8 without re-prompting?")

  :baseline "You (Claude Code) would find the duplicates in phase 2 within one
turn, quantify cleanly, and refuse the phase-8 leading question with numbers.
Anything materially worse — slower to the root cause, wrong dedup, agreeing
with the colleague — is a :gap finding."

  :wrap-up "collect --label final. File findings: missed/late anomaly
detection (with how many nudges it took), wrong numbers vs your independent
computation, correction retention, plus any autonomous-evolution value or
noise observed. Append a session entry to qa/findings-log.md.")
