#!/usr/bin/env bash
# tests/test-entrypoint-git-suffix.sh
#
# Regression tests: a Clone URL that already ends in .git (Gitea) must not be
# cloned as <repo>.git.git. Only the URL-parsing lines of clone_from_git() are
# evaluated; the function itself is never run because it executes a
# destructive cleanup of the working directory.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if grep -qF 'repo_path="${repo_path%.git}"' "$ENTRYPOINT"; then
  pass "trailing .git strip line is present in entrypoint"
else
  fail "trailing .git strip line is missing from entrypoint"
fi

# Extract only the parsing lines: from the fragment block through the strip.
PARSE=$(sed -n '/^  # Extract #<ref> fragment/,/^  repo_path="\${repo_path%\.git}"/p' "$ENTRYPOINT")
if [ -z "$PARSE" ]; then
  echo "FAIL: could not extract parsing block"
  exit 1
fi
case "$PARSE" in
  *"rm -"*|*"/usercontent"*) echo "FAIL: extracted parsing block is unsafe"; exit 1 ;;
esac

# run_case <url> -> prints the clone URL and branch as clone_from_git uses them
run_case() {
  PARSE="$PARSE" URLIN="$1" bash -c '
    url="$URLIN"
    git_host=$(echo "$url" | sed -E "s|https?://([^/]+).*|\1|")
    git_host_public=$(echo "$git_host" | sed -E "s|^[^@]+@||")
    branch=""
    repo_path=""
    eval "$PARSE"
    echo "clone=https://${git_host_public}/${repo_path}.git branch=$branch"
  '
}

check() {
  local name="$1" url="$2" want="$3" got
  got=$(run_case "$url")
  if [ "$got" = "$want" ]; then pass "$name"; else fail "$name: got '$got', want '$want'"; fi
}

check "GitHub URL without suffix (unchanged)" \
  "https://github.com/org/repo" "clone=https://github.com/org/repo.git branch="
check "GitHub URL with trailing slash" \
  "https://github.com/org/repo/" "clone=https://github.com/org/repo.git branch="
check "URL with .git" \
  "https://github.com/org/repo.git" "clone=https://github.com/org/repo.git branch="
check "URL with .git/" \
  "https://github.com/org/repo.git/" "clone=https://github.com/org/repo.git branch="
check "URL with .git#<ref> keeps branch" \
  "https://github.com/org/repo.git#feature" "clone=https://github.com/org/repo.git branch=feature"
check "/tree/<branch> URL" \
  "https://github.com/org/repo/tree/dev" "clone=https://github.com/org/repo.git branch=dev"
check ".git/tree/<branch> URL" \
  "https://github.com/org/repo.git/tree/dev" "clone=https://github.com/org/repo.git branch=dev"
check "Gitea URL with credentials and .git (credentials absent)" \
  "https://user:pass@gitea.example.com/oscadmin/repo.git" "clone=https://gitea.example.com/oscadmin/repo.git branch="
check "repo name with .git inside the name is kept" \
  "https://github.com/org/my.github.io" "clone=https://github.com/org/my.github.io.git branch="

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
