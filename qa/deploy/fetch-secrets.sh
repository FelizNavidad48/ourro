#!/usr/bin/env bash
# Fetch the QA loop's secrets/config from AWS SSM Parameter Store into the
# env file docker-compose reads (qa/docs/plan-cloud-qa.md). Run from the
# EC2 instance (user-data at boot, or by hand after rotating a key). The
# instance's IAM role needs ssm:GetParameter on /ourro-loop/*.
#
#   qa/deploy/fetch-secrets.sh [/data/ourro-loop.env]
#
# Parameters (create with: aws ssm put-parameter --type SecureString \
#   --name /ourro-loop/<name> --value '…'):
#   /ourro-loop/bedrock-api-key     → OURRO_BEDROCK_API_KEY   (opus/sonnet)
#   /ourro-loop/vertex-api-key      → OURRO_VERTEX_API_KEY    (gemini)
#   /ourro-loop/model               → OURRO_LOOP_MODEL        (optional)
#   /ourro-loop/daily-usd           → OURRO_LOOP_DAILY_USD
#   /ourro-loop/gh-token            → GH_TOKEN               (findings→issues)
set -euo pipefail

OUT="${1:-/data/ourro-loop.env}"
PREFIX="/ourro-loop"

param() { # name env-var required?
  local value
  if value=$(aws ssm get-parameter --with-decryption \
               --name "$PREFIX/$1" --query Parameter.Value \
               --output text 2>/dev/null); then
    echo "$2=$value" >> "$OUT.tmp"
  elif [ "${3:-}" = required ]; then
    echo "missing required SSM parameter $PREFIX/$1" >&2
    exit 1
  fi
}

: > "$OUT.tmp"
param bedrock-api-key OURRO_BEDROCK_API_KEY
# Region is always eu-north-1 (product config, not env) — no bedrock-region param.
param vertex-api-key  OURRO_VERTEX_API_KEY
param model           OURRO_LOOP_MODEL
param daily-usd       OURRO_LOOP_DAILY_USD required
param gh-token        GH_TOKEN

chmod 600 "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "wrote $OUT ($(grep -c = "$OUT") vars)"
