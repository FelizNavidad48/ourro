#!/usr/bin/env bash
# Container entrypoint for the cloud QA loop (qa/docs/plan-cloud-qa.md).
#
# Modes:
#   run     — the nonstop loop (default)
#   once    — one cycle, then exit (smoke a fresh deployment)
#   status  — print loop state + today's spend and exit
#   shell   — a bash shell for debugging (tmux attach -r -t <session> to
#             watch a live instance)
#
# Secrets/config come from the environment (compose/SSM inject them):
#   OURRO_LOOP_MODEL          model alias for all roles (default sonnet-4-6)
#   OURRO_BEDROCK_API_KEY     required for Bedrock-routed models
#   OURRO_VERTEX_API_KEY      required for Vertex-routed models
#   OURRO_LOOP_DAILY_USD      daily spend cap (pause till UTC midnight)
set -euo pipefail

MODE="${1:-run}"

mkdir -p "${OURRO_LOOP_ROOT:-/data/ourro-loop}"

# One tmux server for every instance the conductor spawns. -x/-y sizes are
# per-session; the server just needs to exist and outlive spawn/kill churn.
tmux start-server 2>/dev/null || true

case "$MODE" in
  run|once|status)
    exec qa/bin/ourro-loop "$MODE"
    ;;
  shell)
    exec bash
    ;;
  *)
    echo "usage: entrypoint.sh run|once|status|shell" >&2
    exit 1
    ;;
esac
