#!/usr/bin/env bash
# Behavioural tests for the runner token exchange in scripts/docker-entrypoint.sh.
# Stage 1 contract: config-to-env authenticates with the fresh 1h PAT, the app
# keeps the original OSC_ACCESS_TOKEN and gains OSC_REFRESH_TOKEN. `jq` is NOT in
# the runner image, so a stub that exits 127 is on PATH ahead of /usr/bin.

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

ln -s "$(command -v node)" "$sandbox/bin/node"
printf '#!/bin/bash\nexit 127\n' > "$sandbox/bin/jq"

# curl stub: CURL_MODE selects status/body; records args and the body file.
cat > "$sandbox/bin/curl" <<'STUB'
#!/bin/bash
out=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    --data) data=${2#@}; shift ;;
  esac
  shift
done
[ -n "$data" ] && cp "$data" "$SANDBOX/sent-body"
case "$CURL_MODE" in
  ok) echo '{"token":"fresh-pat","expiresIn":3600}' > "$out"; printf 200 ;;
  ok_notoken) echo '{"expiresIn":3600}' > "$out"; printf 200 ;;
  ok_garbage) echo 'not json' > "$out"; printf 200 ;;
  expired) echo '{"code":"refresh_token_expired","message":"orig-token-secret"}' > "$out"; printf 401 ;;
  invalid) echo '{"code":"refresh_token_invalid"}' > "$out"; printf 401 ;;
  err500) echo 'oops' > "$out"; printf 500 ;;
  exit22) exit 22 ;;
  exit28) printf 000; exit 28 ;;
esac
STUB
cat > "$sandbox/bin/timeout" <<'STUB'
#!/bin/bash
shift
exec "$@"
STUB
cat > "$sandbox/bin/npx" <<'STUB'
#!/bin/bash
echo "$OSC_ACCESS_TOKEN" > "$SANDBOX/npx-token"
echo "export FOO=bar"
STUB
chmod +x "$sandbox/bin/"*

run_block() {
  local mode=$1; shift
  rm -f "$sandbox/npx-token" "$sandbox/sent-body"
  env -i PATH="$sandbox/bin:/usr/bin:/bin" SANDBOX="$sandbox" CURL_MODE="$mode" \
    OSC_ACCESS_TOKEN=orig-token-secret CONFIG_SVC=store OSAAS_CLI_VERSION=4.35.0 "$@" \
    bash -c 'set -e; '"$(cat "$sandbox/block.sh")"'; echo "REACHED_PIP APP_TOKEN=$OSC_ACCESS_TOKEN REFRESH=${OSC_REFRESH_TOKEN:-}"' \
    2>"$sandbox/stderr" >"$sandbox/stdout"
  echo $?
}

# Success path: config load uses the fresh token, app keeps the original
rc=$(run_block ok)
if [ "$rc" = "0" ] \
  && [ "$(cat "$sandbox/npx-token")" = "fresh-pat" ] \
  && grep -q 'REACHED_PIP APP_TOKEN=orig-token-secret REFRESH=orig-token-secret' "$sandbox/stdout" \
  && [ "$(cat "$sandbox/sent-body")" = '{"token":"orig-token-secret"}' ] \
  && ! grep -q WARNING "$sandbox/stderr"; then
  pass "success: config-to-env gets fresh PAT, app keeps original token and gains OSC_REFRESH_TOKEN"
else
  fail "success path (rc=$rc, npx token=$(cat "$sandbox/npx-token" 2>/dev/null))"
fi

# Pre-set OSC_REFRESH_TOKEN is the exchange input
rc=$(run_block ok OSC_REFRESH_TOKEN=preset-refresh)
if [ "$rc" = "0" ] && [ "$(cat "$sandbox/sent-body")" = '{"token":"preset-refresh"}' ] && grep -q 'REFRESH=preset-refresh' "$sandbox/stdout"; then
  pass "existing OSC_REFRESH_TOKEN is used and kept"
else
  fail "preset refresh token (rc=$rc)"
fi

# Failure paths: warning with status/code, original token used, block continues, no leak
for spec in "expired:401:refresh_token_expired" "invalid:401:refresh_token_invalid" "err500:500:none" "exit22:000:none" "exit28:000:none" "ok_notoken:200:none" "ok_garbage:200:none"; do
  mode=${spec%%:*}; rest=${spec#*:}; status=${rest%%:*}; code=${rest#*:}
  rc=$(run_block "$mode")
  if [ "$rc" = "0" ] \
    && [ "$(cat "$sandbox/npx-token")" = "orig-token-secret" ] \
    && grep -q 'REACHED_PIP APP_TOKEN=orig-token-secret' "$sandbox/stdout" \
    && grep -q "\[CONFIG\] WARNING: runner token exchange failed (HTTP $status, code=$code)" "$sandbox/stderr" \
    && ! grep -q 'orig-token-secret' "$sandbox/stderr"; then
    pass "failure ($mode): warning, original token used, continues, token not logged"
  else
    fail "failure $mode (rc=$rc)"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
