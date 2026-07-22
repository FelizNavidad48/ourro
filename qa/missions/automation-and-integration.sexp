;;;; Mission: developer-workflow automation and outside-world integration —
;;;; git, hooks, HTTP APIs, scheduling. This is the mission most likely to
;;;; expose capability gaps vs Claude Code (web knowledge, MCP-style
;;;; integrations), and the most natural habitat for ourro's reflexes.
;;;; Toolchain: git, python3 or node, network access. 9+ user turns.
(mission "automation-and-integration"
  :title "Morning-report automation for a working dev (git + HTTP + hooks)"
  :needs ("git" "python3")
  :fixture "qa/fixtures/legacy-inventory"

  :persona "You are Alex, a developer who automates everything twice. You want
your project chores scripted, your data pulled from real APIs, and you get
annoyed by manual steps. The fixture repo is 'your project' — git init it
first thing through the agent ('make this a git repo, sensible first
commit')."

  :brief "This project needs some grown-up habits. First: make it a git repo
with a sensible initial commit. Then I want a release-notes script — run it,
get a markdown summary of commits since the last tag, grouped by fix/feat/
chore prefix. We'll build from there."

  :arc
  ("1 · Git + release notes. After it builds the script, make real commits
(have it fix something trivial, commit with conventional prefixes), tag, and
run the script. Verify the grouping against `git log` yourself."
   "2 · The hook: 'I keep committing print() debugging. give me a pre-commit
hook that blocks any staged .py file containing print( outside tests/, and
tell me how to bypass it when I mean it.' Then TEST it: have the agent stage
an offending file and attempt a commit — the hook must actually fire in its
shell."
   "3 · Integration, real network: 'extend the morning report: top of the
file, today's weather for Vilnius — use the open-meteo API, it's free, no
key.' Judge: correct API use, sane error handling when offline (unplug it by
pointing at an unreachable host once), no hallucinated endpoints."
   "4 · Second integration: 'also pull the open PRs or issues from some public
GitHub repo (pick sbcl/sbcl) via the GitHub REST API, unauthenticated is
fine, and list titles in the report.' Rate-limit handling counts."
   "5 · Scheduling: 'I want this report every morning at 8 without thinking
about it. set it up.' Judge what it reaches for on this machine (cron?
launchd? a watcher?) and whether it explains the tradeoff. Don't leave a real
crontab entry behind — have it show you, then have it remove/park it; verify
cleanup yourself."
   "6 · The research probe (Claude-baseline gap hunt): 'what's the current
best practice for storing small secrets for scripts like this on macOS —
answer with today's reality, not 2023 folklore.' You know Claude Code would
web-search this. Watch what ourro does with a question whose answer lives on
the current web."
   "7 · Failure drill: break the network integration on purpose (have it
point the weather call at a wrong domain), run the report, and file how it
degrades — crash, silent empty section, or graceful note?"
   "8 · Idle window: give it ~3 quiet minutes (chaos sleep-idle). Dream/idle
mining is allowed to think here. Afterwards check ctrl-e and the ticker: did
the session's repetition (report runs, git cycles) turn into any staged
proposal? Judge relevance."
   "9 · Wrap: 'leave me a README-AUTOMATION.md that documents everything we
set up, including the bypass and the schedule.' Verify it matches reality.")

  :verify
  ("Release notes match `git log --oneline` grouping at phase 1."
   "The pre-commit hook blocks the staged print() file (commit exits
non-zero in the agent's own attempt) and allows tests/ files."
   "Weather + GitHub sections contain live data fetched during the session
(spot-check a PR title against the GitHub web UI yourself)."
   "No crontab/launchd residue after phase 5 (`crontab -l` clean or restored)."
   "README-AUTOMATION.md describes the real, final state.")

  :watch
  ("This mission IS the reflex habitat: repeated report runs, repeated
git rituals, a failure drill, an idle window. Track every UNPROMPTED
proposal/evolution end-to-end: proposed → your y/n call as Alex → fired →
note quality → measured value (Σ/ledger). The absence of ANY proposal across
a session this repetitive is itself reportable."
   "Network tool ergonomics vs Claude Code: how many turns to a working
open-meteo call? Any capability ceiling hit (blocked domains, missing HTTP
verbs, no web search)?"
   "Does the phase-7 failure surface proactively (note/briefing) when the
report runs as a background job?")

  :baseline "You have web search, MCP servers, and battle-tested HTTP
habits. Everywhere ourro substitutes stale training data for the live web
(phase 6 especially), or has no path to an integration you'd get via MCP,
file a :gap finding with :scale :engineering — these are exactly the
strategic gaps this mission exists to surface."

  :wrap-up "collect --label final. File findings; separate 'ourro lacks the
capability' (strategic, :engineering) from 'ourro has it but fumbled'
(:quick-fix). Record the full reflex ledger of the session. Append a session
entry to qa/findings-log.md.")
