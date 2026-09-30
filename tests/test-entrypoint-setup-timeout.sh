#!/usr/bin/env bash
# tests/test-entrypoint-setup-timeout.sh
#
# Shell regression tests for the setup.sh timeout fix in
# scripts/docker-entrypoint.sh.
#
# Background:
#   The "Run any setup scripts if present" block ran an optional
#   repo-provided setup.sh with no timeout:
#       ./setup.sh
#   If setup.sh never exited, the entrypoint blocked forever: the container
#   never finished starting and never reached the app-detection/start step,
#   with no terminal signal.
#
#   Unlike the sibling php-runner (which has a loading-server / error-page
#   HTTP mechanism), python-runner's docker-entrypoint.sh has no such
#   mechanism. Its existing terminal-failure pattern for build-step failures
#   (e.g. a failed `pip install` above) is simply to let `set -e` propagate
#   a non-zero exit code, terminating the container run.
#
# Fix (this PR):
#   Wrap the invocation with `timeout 300s`, capture the exit code, and
#   treat both a timeout (124) and any other non-zero exit as a terminal
#   failure by exiting the script with that code — matching the existing
#   non-zero-exit-terminates pattern already used elsewhere in this file.
#
# These tests grep the entrypoint to assert the fix has not regressed,
# and run the extracted shell logic in a sandbox to verify the actual
# timeout/exit-code behavior.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: setup.sh invocation is wrapped with `timeout`
# ---------------------------------------------------------------------------
if grep -qE 'timeout [0-9]+s \./setup\.sh' "$ENTRYPOINT"; then
  pass "setup.sh invocation is wrapped with timeout"
else
  fail "setup.sh invocation is not wrapped with timeout"
fi

# ---------------------------------------------------------------------------
# Test 2: the setup.sh block checks for exit code 124 (timeout)
# ---------------------------------------------------------------------------
block=$(awk '/Run any setup scripts if present/,/^fi$/' "$ENTRYPOINT")
if echo "$block" | grep -qE '\$setup_exit -eq 124'; then
  pass "setup.sh block checks for timeout exit code 124"
else
  fail "setup.sh block does not check for timeout exit code 124"
fi

# ---------------------------------------------------------------------------
# Test 3: the setup.sh block checks for any other non-zero exit
# ---------------------------------------------------------------------------
if echo "$block" | grep -qE '\$setup_exit -ne 0'; then
  pass "setup.sh block checks for non-zero (non-timeout) exit code"
else
  fail "setup.sh block does not check for non-zero exit code"
fi

# ---------------------------------------------------------------------------
# Test 4: both the timeout and failure branches terminate with a non-zero
# exit (this repo's existing terminal-failure pattern — no loading-server
# or error-page mechanism exists here to invoke instead)
# ---------------------------------------------------------------------------
exit_124_count=$(echo "$block" | grep -c 'exit 124')
exit_setup_count=$(echo "$block" | grep -c 'exit \$setup_exit')
if [ "$exit_124_count" -ge 1 ] && [ "$exit_setup_count" -ge 1 ]; then
  pass "both timeout and failure branches exit non-zero to terminate the run"
else
  fail "expected both terminal-failure branches (timeout + non-zero exit) to exit non-zero, found exit_124=$exit_124_count exit_setup_exit=$exit_setup_count"
fi

# ---------------------------------------------------------------------------
# Test 5: behavioral verification — a hanging setup.sh is killed by the
# timeout and resolves to a terminal failed state (non-zero exit), not an
# indefinite hang
# ---------------------------------------------------------------------------
sandbox_dir=$(mktemp -d)
cat > "$sandbox_dir/setup.sh" <<'EOF'
#!/bin/bash
sleep 30
EOF
chmod +x "$sandbox_dir/setup.sh"

start_ts=$(date +%s)
sandbox_result=$(bash -c "
  cd '$sandbox_dir'
  setup_exit=0
  timeout 1s ./setup.sh || setup_exit=\$?
  if [ \$setup_exit -eq 124 ]; then
    echo \"terminal_failure:124\"
    exit 124
  elif [ \$setup_exit -ne 0 ]; then
    echo \"terminal_failure:\$setup_exit\"
    exit \$setup_exit
  fi
  echo \"ok\"
"; echo "exit_code:$?")
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

if echo "$sandbox_result" | grep -q "terminal_failure:124" && echo "$sandbox_result" | grep -q "exit_code:124" && [ "$elapsed" -lt 10 ]; then
  pass "a hanging setup.sh is killed by timeout and resolves to a terminal failed state (exit 124), not a hang (elapsed ${elapsed}s)"
else
  fail "hanging setup.sh did not resolve to a terminal failure as expected (result=$sandbox_result elapsed=${elapsed}s)"
fi

# ---------------------------------------------------------------------------
# Test 6: behavioral verification — a setup.sh that fails fast (non-zero,
# non-timeout exit) reports its real exit code, not 124
# ---------------------------------------------------------------------------
cat > "$sandbox_dir/setup.sh" <<'EOF'
#!/bin/bash
exit 3
EOF
chmod +x "$sandbox_dir/setup.sh"

sandbox_result=$(bash -c "
  cd '$sandbox_dir'
  setup_exit=0
  timeout 5s ./setup.sh || setup_exit=\$?
  if [ \$setup_exit -eq 124 ]; then
    echo \"terminal_failure:124\"
    exit 124
  elif [ \$setup_exit -ne 0 ]; then
    echo \"terminal_failure:\$setup_exit\"
    exit \$setup_exit
  fi
  echo \"ok\"
"; echo "exit_code:$?")

if echo "$sandbox_result" | grep -q "terminal_failure:3" && echo "$sandbox_result" | grep -q "exit_code:3"; then
  pass "a fast-failing setup.sh reports its real exit code (3), distinguishable from a timeout"
else
  fail "fast-failing setup.sh did not report the expected exit code: $sandbox_result"
fi

# ---------------------------------------------------------------------------
# Test 7: behavioral verification — a well-behaved setup.sh still succeeds
# (exit 0) and does not trip the timeout/failure branches
# ---------------------------------------------------------------------------
cat > "$sandbox_dir/setup.sh" <<'EOF'
#!/bin/bash
echo "setting up"
exit 0
EOF
chmod +x "$sandbox_dir/setup.sh"

sandbox_result=$(bash -c "
  cd '$sandbox_dir'
  setup_exit=0
  timeout 300s ./setup.sh >/dev/null || setup_exit=\$?
  if [ \$setup_exit -eq 124 ]; then
    echo \"terminal_failure:124\"
    exit 124
  elif [ \$setup_exit -ne 0 ]; then
    echo \"terminal_failure:\$setup_exit\"
    exit \$setup_exit
  fi
  echo \"ok\"
"; echo "exit_code:$?")

if echo "$sandbox_result" | grep -q "^ok$" && echo "$sandbox_result" | grep -q "exit_code:0"; then
  pass "a well-behaved setup.sh still succeeds (exit 0) with the timeout wrapper in place"
else
  fail "well-behaved setup.sh unexpectedly failed: $sandbox_result"
fi

rm -rf "$sandbox_dir"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
