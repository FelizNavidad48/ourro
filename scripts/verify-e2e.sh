#!/usr/bin/env bash

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ourro-e2e.XXXXXX")"
export OURRO_HOME="$HOME_DIR"
PASS=0
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); say "  ✓ $1"; }
bad()  { FAIL=$((FAIL + 1)); say "  ✗ $1"; }

check() {
  if [ -f "$3" ] && grep -qF -- "$2" "$3"; then
    ok "$1"
  else
    bad "$1 — expected \"$2\""
  fi
}

cleanup() { rm -rf "$HOME_DIR"; }
trap cleanup EXIT

say "== M8 headless end-to-end verification =="
say "   OURRO_HOME=$OURRO_HOME"
say ""

say "[1] supervised build pipeline — make build"
if make build >"$HOME_DIR/init.log" 2>&1; then
  ok "make build succeeded (supervisor + base core + gen-0001)"
else
  bad "make build failed"; tail -25 "$HOME_DIR/init.log"
fi
[ -f "$OURRO_HOME/base.core" ] && ok "base.core built" || bad "base.core missing"
IMG="$OURRO_HOME/images/gen-0001"
[ -x "$IMG" ] && ok "gen-0001 executable image built" || bad "gen-0001 image missing"
check "ledger records gen-0001 :GOOD" ":STATUS :GOOD" "$OURRO_HOME/ledger.sexp"
check "ledger pins a genome git commit" ":COMMIT" "$OURRO_HOME/ledger.sexp"
[ -d "$OURRO_HOME/genome/.git" ] && ok "genome is a git repo (rebuildable truth)" \
  || bad "genome git repo missing"
say ""

say "[2] built image self-tests + locks the kernel at --smoke"
"$IMG" --smoke >"$HOME_DIR/smoke1.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "gen-0001 --smoke exited 0" || bad "gen-0001 --smoke exit $rc"
check "kernel selftest OK" "kernel selftest OK" "$HOME_DIR/smoke1.log"
check "OURRO.KERNEL is locked in the built image" "OURRO.KERNEL locked: T" "$HOME_DIR/smoke1.log"
check "OURRO.TXN is locked in the built image" "OURRO.TXN locked: T" "$HOME_DIR/smoke1.log"
check "OURRO.VERIFY is locked in the built image" "OURRO.VERIFY locked: T" "$HOME_DIR/smoke1.log"
check "verification coordinator is locked in the built image" "OURRO.VERIFY.COORDINATOR locked: T" "$HOME_DIR/smoke1.log"
check "automation effect package is locked in the built image" "OURRO.AUTOMATION locked: T" "$HOME_DIR/smoke1.log"
check "smoke reports the seed toolset" "SMOKE-OK: 15 tools, 13 genes" "$HOME_DIR/smoke1.log"
say ""

say "[3] kernel-path proof — kernel edit → staleness rebuild re-validates + re-locks"
touch src/kernel/conditions.lisp
if ./bin/ourro init --source-dir "$ROOT" >"$HOME_DIR/rebuild.log" 2>&1; then
  ok "init after a kernel-file touch succeeded"
else
  bad "init after kernel touch failed"; tail -25 "$HOME_DIR/rebuild.log"
fi
check "staleness detection rebuilt the base core (no --force)" "building base core (source changed)" "$HOME_DIR/rebuild.log"
check "the stale current image was rebuilt in place" "rebuilding gen-0001 image (source changed)" "$HOME_DIR/rebuild.log"
"$IMG" --smoke >"$HOME_DIR/smoke2.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "rebuilt gen-0001 --smoke exited 0" || bad "rebuilt --smoke exit $rc"
check "rebuilt image re-runs the kernel selftest" "kernel selftest OK" "$HOME_DIR/smoke2.log"
check "rebuilt image re-locks OURRO.KERNEL" "OURRO.KERNEL locked: T" "$HOME_DIR/smoke2.log"
check "rebuilt image re-locks OURRO.TXN" "OURRO.TXN locked: T" "$HOME_DIR/smoke2.log"
check "rebuilt image re-locks OURRO.VERIFY" "OURRO.VERIFY locked: T" "$HOME_DIR/smoke2.log"
check "rebuilt image re-locks the verification coordinator" "OURRO.VERIFY.COORDINATOR locked: T" "$HOME_DIR/smoke2.log"
check "rebuilt image re-locks the automation effect package" "OURRO.AUTOMATION locked: T" "$HOME_DIR/smoke2.log"
say ""

say "[3b] staleness detection discriminates — an untouched re-init rebuilds nothing"
./bin/ourro init --source-dir "$ROOT" >"$HOME_DIR/reinit.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "second init (no source change) succeeded" || bad "second init exit $rc"
if grep -qF -- "building base core" "$HOME_DIR/reinit.log"; then
  bad "base core rebuilt despite no source change — staleness detection is not discriminating"
else
  ok "no base-core rebuild when the source is unchanged"
fi
say ""

say "[4] replay machinery — the kernel gate's action-trace comparison"
printf '(:kind :tool-call :tool "list_files" :args (:pattern "*"))\n' \
  > "$HOME_DIR/events.sexp"
"$IMG" --replay "$HOME_DIR/events.sexp" >"$HOME_DIR/replay.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "--replay exited 0" || bad "--replay exit $rc"
check "replay emits the trace block open sentinel" "<<<OURRO-REPLAY" "$HOME_DIR/replay.log"
check "replay emits the trace block close sentinel" "OURRO-REPLAY>>>" "$HOME_DIR/replay.log"
check "replay produced a tool action trace" ':TOOL "list_files"' "$HOME_DIR/replay.log"

trace_of() { sed -n '/<<<OURRO-REPLAY/,/OURRO-REPLAY>>>/p' "$1"; }
printf '(:kind :tool-call :tool "read_file" :args (:path "README.md"))\n' > "$HOME_DIR/ev-a.sexp"
printf '(:kind :tool-call :tool "read_file" :args (:path "Makefile"))\n'  > "$HOME_DIR/ev-b.sexp"
"$IMG" --replay "$HOME_DIR/ev-a.sexp" >"$HOME_DIR/tr-a1.log" 2>&1
"$IMG" --replay "$HOME_DIR/ev-a.sexp" >"$HOME_DIR/tr-a2.log" 2>&1
"$IMG" --replay "$HOME_DIR/ev-b.sexp" >"$HOME_DIR/tr-b.log"  2>&1
if [ "$(trace_of "$HOME_DIR/tr-a1.log")" = "$(trace_of "$HOME_DIR/tr-a2.log")" ]; then
  ok "identical events replay to an identical trace block (deterministic baseline)"
else
  bad "same events produced different traces — replay is not deterministic"
fi
if [ "$(trace_of "$HOME_DIR/tr-a1.log")" != "$(trace_of "$HOME_DIR/tr-b.log")" ]; then
  ok "differing read-only output yields a differing trace (gate can catch divergence)"
else
  bad "different reads produced identical traces — the divergence gate would be blind"
fi
say ""

say "[5] out-of-process gauntlet — --verify-gene verdict (M12-3)"
GOOD_GENE="$ROOT/seed-genome/genes/tools/read-file.gene"
"$IMG" --verify-gene "$GOOD_GENE" >"$HOME_DIR/vg-good.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "--verify-gene (known-good) exited 0" || bad "--verify-gene good exit $rc"
check "verdict block open sentinel" "<<<OURRO-VERIFY" "$HOME_DIR/vg-good.log"
check "known-good gene verdict is :PASS" ":VERDICT :PASS" "$HOME_DIR/vg-good.log"
printf '(defgene tool/e2e-bad (:generation 1 :capabilities () :provenance (:seed t)) (:doc "bad") (:code (deftool e2e-bad () (:doc "d") (open "/etc/passwd"))))\n' \
  > "$HOME_DIR/bad.gene"
"$IMG" --verify-gene "$HOME_DIR/bad.gene" >"$HOME_DIR/vg-bad.log" 2>&1
check "known-bad gene verdict is :FAIL" ":VERDICT :FAIL" "$HOME_DIR/vg-bad.log"
AUTO_GENE="$ROOT/seed-genome/genes/auto/onboard-new-repo.gene"
"$IMG" --verify-gene "$AUTO_GENE" >"$HOME_DIR/vg-auto.log" 2>&1
check "read-only automation gene verdict is :PASS" ":VERDICT :PASS" "$HOME_DIR/vg-auto.log"
EFFECTFUL_AUTO_GENE="$ROOT/seed-genome/genes/auto/job-sentinel.gene"
"$IMG" --verify-gene "$EFFECTFUL_AUTO_GENE" >"$HOME_DIR/vg-effectful-auto.log" 2>&1
check "effectful automation fails closed at containment" ":STAGE :CONTAINMENT" "$HOME_DIR/vg-effectful-auto.log"
say ""

say "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
