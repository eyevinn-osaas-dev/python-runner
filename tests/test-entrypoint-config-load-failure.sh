#!/usr/bin/env bash
# Behavioural tests for the CONFIG_SVC load block in scripts/docker-entrypoint.sh.
# The real block is extracted from the entrypoint and run under `set -e` with
# stub `npx`, `curl` and `timeout` on PATH.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir "$sandbox/bin"

awk '/^# Load environment variables from config service if configured/{f=1} /^# Install Python dependencies/{f=0} f' "$ENTRYPOINT" > "$sandbox/block.sh"
if [ ! -s "$sandbox/block.sh" ]; then
  fail "could not extract config block from entrypoint"
  exit 1
fi

cat > "$sandbox/bin/curl" <<'STUB'
#!/bin/bash
exit 22
STUB
# timeout stub: STUB_MODE=timeout simulates exit 124, otherwise run the command
cat > "$sandbox/bin/timeout" <<'STUB'
#!/bin/bash
if [ "$STUB_MODE" = "timeout" ]; then exit 124; fi
shift
exec "$@"
STUB
cat > "$sandbox/bin/npx" <<'STUB'
#!/bin/bash
case "$STUB_MODE" in
  fail) echo "boom 401 unauthorized" >&2; exit 2 ;;
  empty) exit 0 ;;
  garbled) echo "npm notice something"; echo "export my-key=1"; exit 0 ;;
  stderr_only) echo "npm warn noise" >&2; exit 0 ;;
  ok) echo "export FOO=bar"; echo "export BAZ=qux"; exit 0 ;;
esac
STUB
chmod +x "$sandbox/bin/"*

run_block() {
  # $1 = mode; remaining args are env assignments
  local mode=$1; shift
  env -i PATH="$sandbox/bin:/usr/bin:/bin" STUB_MODE="$mode" "$@" \
    bash -c 'set -e; '"$(cat "$sandbox/block.sh")"'; echo "REACHED_PIP FOO=${FOO:-}"' 2>"$sandbox/stderr" >"$sandbox/stdout"
  echo $?
}

ENVV=(OSC_ACCESS_TOKEN=tok CONFIG_SVC=store)

# Failure paths: non-zero exit and never reach the next phase
rc=$(run_block timeout "${ENVV[@]}")
if [ "$rc" = "124" ] && ! grep -q REACHED_PIP "$sandbox/stdout" && grep -q '\[CONFIG\] ERROR' "$sandbox/stderr"; then pass "timeout exits 124 before pip install"; else fail "timeout (rc=$rc)"; fi

rc=$(run_block fail "${ENVV[@]}")
if [ "$rc" = "2" ] && ! grep -q REACHED_PIP "$sandbox/stdout" && grep -q '\[CONFIG\] ERROR' "$sandbox/stderr" && grep -q refresh-app-config "$sandbox/stderr"; then pass "non-zero exit propagates and prints refresh hint"; else fail "non-zero exit (rc=$rc)"; fi

rc=$(run_block garbled "${ENVV[@]}")
if [ "$rc" != "0" ] && ! grep -q REACHED_PIP "$sandbox/stdout" && grep -q '\[CONFIG\] ERROR' "$sandbox/stderr"; then pass "non-empty output with no valid exports exits non-zero"; else fail "garbled output (rc=$rc)"; fi

# Passing paths
rc=$(run_block empty "${ENVV[@]}")
if [ "$rc" = "0" ] && grep -q "REACHED_PIP" "$sandbox/stdout" && grep -q "has no parameters" "$sandbox/stdout"; then pass "empty store logs and continues"; else fail "empty store (rc=$rc)"; fi

rc=$(run_block stderr_only "${ENVV[@]}")
if [ "$rc" = "0" ] && grep -q "REACHED_PIP" "$sandbox/stdout"; then pass "stderr noise with empty stdout still continues"; else fail "stderr only (rc=$rc)"; fi

rc=$(run_block ok "${ENVV[@]}")
if [ "$rc" = "0" ] && grep -q "REACHED_PIP FOO=bar" "$sandbox/stdout" && grep -q "Loaded 2 environment variable" "$sandbox/stdout"; then pass "valid exports are evaluated"; else fail "success path (rc=$rc)"; fi

rc=$(run_block fail OSC_ACCESS_TOKEN=tok)
if [ "$rc" = "0" ] && grep -q "REACHED_PIP" "$sandbox/stdout"; then pass "no CONFIG_SVC: block skipped"; else fail "no CONFIG_SVC (rc=$rc)"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
