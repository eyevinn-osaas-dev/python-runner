#!/bin/bash
set -e

# Check that we have a source URL
if [ -z "$SOURCE_URL" ] && [ -z "$GITHUB_URL" ]; then
  echo "Error: SOURCE_URL or GITHUB_URL environment variable is required"
  exit 1
fi

# Use SOURCE_URL if set, otherwise use GITHUB_URL
URL="${SOURCE_URL:-$GITHUB_URL}"

# Function to clone from a generic HTTPS git host (GitHub, GitLab, Gitea, etc.)
clone_from_git() {
  local url="$1"
  local branch=""
  local repo_path=""

  # Extract hostname dynamically from URL (may include user:pass@ for Gitea-style URLs)
  local git_host=$(echo "$url" | sed -E 's|https?://([^/]+).*|\1|')
  # Variant with any embedded credentials stripped — used for log lines and the
  # persisted remote URL so that PATs never leak into pod logs or .git/config.
  # When SOURCE_URL has no credentials, this is identical to git_host.
  local git_host_public=$(echo "$git_host" | sed -E 's|^[^@]+@||')

  # Extract #<ref> fragment if present, and strip it from the URL used for
  # further parsing. Must run before /tree/ handling so repo_path extraction
  # operates on the fragment-stripped URL.
  if [[ "$url" == *"#"* ]]; then
    branch="${url##*#}"
    url="${url%#*}"
  fi

  # Check if URL contains a branch reference (e.g., /tree/branch_name)
  if [[ "$url" == *"/tree/"* ]]; then
    # Extract branch name (everything after /tree/)
    branch=$(echo "$url" | sed -E 's|.*/tree/||')
    # Extract repo path (everything between host/ and /tree/)
    repo_path=$(echo "$url" | sed -E "s|https?://[^/]+/||" | sed -E 's|/tree/.*||')
  else
    # No branch specified, extract the repository path
    # Supports: https://host/org/repo or https://host/org/repo/
    repo_path=$(echo "$url" | sed -E "s|https?://[^/]+/||" | sed 's|/$||')
  fi

  if [ -n "$branch" ]; then
    echo "Cloning repository: $repo_path (branch: $branch) from $git_host_public"
  else
    echo "Cloning repository: $repo_path from $git_host_public"
  fi

  # Clear the usercontent directory
  rm -rf /usercontent/* /usercontent/.[!.]*

  # Clone the repository (with optional branch)
  local clone_opts=""
  if [ -n "$branch" ]; then
    clone_opts="-b $branch"
  fi

  # Support GIT_TOKEN with GITHUB_TOKEN as fallback for backward compatibility
  local git_token="${GIT_TOKEN:-$GITHUB_TOKEN}"

  # Credentials travel via a host-scoped HTTP Authorization header
  # (git -c http.https://<host>/.extraheader=...) instead of being embedded
  # in the clone URL — the same technique actions/checkout uses, ported from
  # Eyevinn/web-runner#56. A -c value passed to a single git invocation is
  # never persisted to .git/config and is not part of the URL string, so it
  # cannot appear in "fatal: ... for '<url>'"-style output that git itself
  # echoes to stderr on a failed clone, independent of anything this script
  # logs — embedding the token in the URL argument was the vulnerability.
  #
  # The header key is scoped to the exact host being cloned from
  # (http.https://<host>/.extraheader) rather than a bare http.extraheader,
  # so it is not attached to requests to a different host (e.g. a redirect).
  local -a GIT_AUTH_ARGS=()
  if [ -n "$git_token" ]; then
    local auth_b64
    auth_b64=$(printf 'token:%s' "$git_token" | base64 | tr -d '\n')
    GIT_AUTH_ARGS=(-c "http.https://${git_host_public}/.extraheader=AUTHORIZATION: basic ${auth_b64}")
  elif [ "$git_host" != "$git_host_public" ]; then
    # Gitea: SOURCE_URL pre-embeds user:pass@host — reuse it as the
    # Basic-Auth pair instead of putting it back into the URL. Split on the
    # FIRST "@" (matching the git_host_public derivation above) so this
    # stays consistent with the existing convention in this script.
    local creds="${git_host%%@*}"
    local auth_b64
    auth_b64=$(printf '%s' "$creds" | base64 | tr -d '\n')
    GIT_AUTH_ARGS=(-c "http.https://${git_host_public}/.extraheader=AUTHORIZATION: basic ${auth_b64}")
  fi

  # Defense in depth: redact any credential-shaped token from git's own
  # stderr, in case some other/future git diagnostic leaks something we
  # haven't anticipated. Process substitution (2> >(...)), not a pipe, so
  # $?/set -e for the wrapped command is unaffected.
  git_scrub_stderr() {
    "$@" 2> >(sed -r 's/gh[pso]_[A-Za-z0-9]{20,}/[REDACTED]/g; s/([Bb]asic )[A-Za-z0-9+\/=]{8,}/\1[REDACTED]/g' >&2)
  }

  echo "cloning https://${git_host_public}/${repo_path}.git"
  git_scrub_stderr git "${GIT_AUTH_ARGS[@]}" clone $clone_opts "https://${git_host_public}/${repo_path}.git" /usercontent

  # origin is already credential-free since the clone URL was — this
  # explicit scrub is kept as defense in depth (PR #8) and to normalize any
  # PVC-cached .git/config from before this fix.
  git -C /usercontent remote set-url origin "https://${git_host_public}/${repo_path}.git"
}

# Write commit metadata to a well-known file for platform visibility
write_commit_info() {
  local repo_dir="$1"
  if ! git -C "$repo_dir" rev-parse HEAD >/dev/null 2>&1; then return 0; fi
  local sha shortSha msg author date
  sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || return 0
  shortSha=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null) || return 0
  msg=$(git -C "$repo_dir" log -1 --format='%s' 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g') || return 0
  author=$(git -C "$repo_dir" log -1 --format='%an' 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g') || return 0
  date=$(git -C "$repo_dir" log -1 --format='%aI' 2>/dev/null) || return 0

  local recent="["
  local first=true
  while read -r c_sha; do
    [ -z "$c_sha" ] && continue
    local c_short c_msg c_author c_date
    c_short=$(git -C "$repo_dir" rev-parse --short "$c_sha" 2>/dev/null)
    c_msg=$(git -C "$repo_dir" log -1 --format='%s' "$c_sha" 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g')
    c_author=$(git -C "$repo_dir" log -1 --format='%an' "$c_sha" 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g')
    c_date=$(git -C "$repo_dir" log -1 --format='%aI' "$c_sha" 2>/dev/null)
    if [ "$first" = true ]; then first=false; else recent="$recent,"; fi
    recent="$recent{\"sha\":\"$c_sha\",\"shortSha\":\"$c_short\",\"message\":\"$c_msg\",\"author\":\"$c_author\",\"date\":\"$c_date\"}"
  done <<< "$(git -C "$repo_dir" log -5 --format='%H' 2>/dev/null)"
  recent="$recent]"

  printf '{"sha":"%s","shortSha":"%s","message":"%s","author":"%s","date":"%s","recentCommits":%s}\n' \
    "$sha" "$shortSha" "$msg" "$author" "$date" "$recent" \
    > "$repo_dir/.commit-info.json" 2>/dev/null || true
  # Exclude .commit-info.json from git status so build steps asserting a clean
  # tree are not broken by a file the platform wrote.
  if git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
    excl="$(git -C "$repo_dir" rev-parse --git-path info/exclude 2>/dev/null)"
    mkdir -p "$(dirname "$excl")"
    grep -qxF '.commit-info.json' "$excl" 2>/dev/null || echo '.commit-info.json' >> "$excl"
  fi
  echo "Commit info: $shortSha - $msg"
}

# Function to download from S3
download_from_s3() {
  local url="$1"

  echo "Downloading from S3: $url"

  # Clear the usercontent directory
  rm -rf /usercontent/*

  # Build aws s3 cp command
  local aws_cmd="aws s3 cp"
  if [ -n "$S3_ENDPOINT_URL" ]; then
    aws_cmd="$aws_cmd --endpoint-url $S3_ENDPOINT_URL"
  fi

  # Download the file
  $aws_cmd "$url" /tmp/source.zip

  # Extract the zip file
  unzip -o /tmp/source.zip -d /usercontent

  # Clean up
  rm /tmp/source.zip

  # Remove any existing venv or __pycache__ directories
  find /usercontent -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
  find /usercontent -type d -name ".venv" -exec rm -rf {} + 2>/dev/null || true
  find /usercontent -type d -name "venv" -exec rm -rf {} + 2>/dev/null || true
}

# Determine source type and fetch code
if [[ "$URL" == s3://* ]]; then
  download_from_s3 "$URL"
elif [[ "$URL" == https://* ]]; then
  clone_from_git "$URL"
  write_commit_info /usercontent
else
  echo "Error: Unsupported URL scheme. Use an HTTPS git URL or S3 URL (s3://...)"
  exit 1
fi

# Change to the usercontent directory
cd /usercontent

# SUB_PATH support — for monorepo deployments where the Python app lives
# in a subdirectory of the cloned repo.
if [ -n "${SUB_PATH:-}" ]; then
  WORK_DIR="/usercontent/$SUB_PATH"
  if [ ! -d "$WORK_DIR" ]; then
    echo "Error: SUB_PATH directory '$WORK_DIR' does not exist"
    exit 1
  fi
  echo "Using SUB_PATH: $SUB_PATH (working directory: $WORK_DIR)"
  cd "$WORK_DIR"
fi

# Load environment variables from config service if configured
if [ -n "${OSC_ACCESS_TOKEN:-}" ] && [ -n "${CONFIG_SVC:-}" ]; then
  # Derive OSC environment from OSC_MCP_URL if OSC_ENV is not set explicitly
  if [[ -z "${OSC_ENV:-}" && -n "${OSC_MCP_URL:-}" ]]; then
    _extracted=$(echo "$OSC_MCP_URL" | sed -n 's|.*\.svc\.\([a-z]*\)\.osaas\.io.*|\1|p')
    OSC_ENV=${_extracted:-prod}
  fi
  # Token refresh block (matching birme/claude-runner#14)
  REFRESH_RESULT=$(curl -sf -X POST \
    "https://token.svc.${OSC_ENV:-prod}.osaas.io/runner-token/refresh" \
    -H "x-pat-jwt: $OSC_ACCESS_TOKEN" 2>&1) && \
    OSC_ACCESS_TOKEN=$(echo "$REFRESH_RESULT" | jq -r '.token // empty') || true
  echo "[CONFIG] Loading environment variables from config service '$CONFIG_SVC'"
  # Guard against a hung/unresolvable CONFIG_SVC blocking boot forever.
  # The "&& config_exit=0 || config_exit=$?" form (rather than a plain
  # `cmd; config_exit=$?`) is required, not stylistic: under `set -e`, a
  # failing command substitution used as an assignment's RHS is a "simple
  # command" and is NOT exempt from -e, so a bare non-zero exit here would
  # kill the whole script immediately, before config_exit is ever read below
  # — silently skipping the explicit config_exit handling below (so no
  # [CONFIG] message), for a timeout exit (124) same as any other non-zero
  # exit from this call.
  # The same set -e rule applies to the grep below: `x=$(... | grep ...)`
  # exits the script silently when grep matches nothing, so it is guarded
  # with an explicit `|| valid_exports=""`.
  # A failure to load the config is fatal: continuing would start the app
  # without its environment variables. This runner has no loading server, so
  # (like the setup.sh timeout below) failure is a non-zero exit.
  config_err_file=$(mktemp)
  config_env_output=$(timeout 60s npx -y @osaas/cli@latest web config-to-env ${OSC_ENV:+--env "$OSC_ENV"} "$CONFIG_SVC" 2>"$config_err_file") && config_exit=0 || config_exit=$?
  config_err_output=$(cat "$config_err_file" 2>/dev/null || true)
  rm -f "$config_err_file"
  config_failed=0
  if [ $config_exit -ne 0 ]; then
    config_failed=1
    if [ $config_exit -eq 124 ]; then
      echo "[CONFIG] ERROR: Timed out loading config from config service '$CONFIG_SVC'" >&2
    else
      echo "[CONFIG] ERROR: Failed to load config (exit $config_exit): $config_env_output $config_err_output" >&2
    fi
    if echo "$config_env_output $config_err_output" | grep -qiE '401|403|unauthori[sz]ed|forbidden|expired'; then
      echo "[CONFIG] Hint: the access token may have expired. Run refresh-app-config to renew it." >&2
    fi
  elif [ -z "$(echo "$config_env_output" | tr -d '[:space:]')" ]; then
    # Empty store is not a failure
    echo "[CONFIG] Config service '$CONFIG_SVC' has no parameters"
  else
    valid_exports=$(echo "$config_env_output" | grep "^export [A-Za-z_][A-Za-z0-9_]*=") || valid_exports=""
    if [ -n "$valid_exports" ]; then
      eval "$valid_exports"
      var_count=$(echo "$valid_exports" | wc -l | tr -d ' ')
      echo "[CONFIG] Loaded $var_count environment variable(s)"
    else
      config_failed=1
      echo "[CONFIG] ERROR: Config service '$CONFIG_SVC' returned output with no valid export lines: $config_env_output" >&2
    fi
  fi
  if [ $config_failed -ne 0 ]; then
    if [ $config_exit -eq 124 ]; then
      exit 124
    elif [ $config_exit -ne 0 ]; then
      exit "$config_exit"
    fi
    exit 1
  fi
fi

# Install Python dependencies
echo "Installing Python dependencies..."

if [ -f "pyproject.toml" ]; then
  echo "Found pyproject.toml, installing with pip..."
  pip install --no-cache-dir .
elif [ -f "requirements.txt" ]; then
  echo "Found requirements.txt, installing dependencies..."
  pip install --no-cache-dir -r requirements.txt
elif [ -f "setup.py" ]; then
  echo "Found setup.py, installing package..."
  pip install --no-cache-dir .
else
  echo "Warning: No requirements.txt, pyproject.toml, or setup.py found"
fi

# Install development dependencies if they exist
if [ -f "requirements-dev.txt" ]; then
  echo "Installing development dependencies..."
  pip install --no-cache-dir -r requirements-dev.txt
fi

# Run any setup scripts if present
#
# Bounded with `timeout` so a hung setup.sh cannot block the build forever
# (previously: no timeout — a hang left the container starting up
# indefinitely with no terminal signal). This repo has no loading-server /
# error-page mechanism (unlike php-runner's sibling escape hatch); the
# existing terminal-failure pattern for build-step failures (e.g. a failed
# `pip install` above) is simply to let `set -e` propagate a non-zero exit,
# which terminates the container run. Both a timeout (exit 124) and any
# other non-zero exit from setup.sh are treated the same way here.
if [ -f "setup.sh" ]; then
  echo "Running setup.sh..."
  chmod +x setup.sh
  setup_exit=0
  timeout 300s ./setup.sh || setup_exit=$?
  if [ $setup_exit -eq 124 ]; then
    echo "Error: setup.sh timed out after 300s" >&2
    exit 124
  elif [ $setup_exit -ne 0 ]; then
    echo "Error: setup.sh failed (exit $setup_exit)" >&2
    exit $setup_exit
  fi
fi

# Function to check if a package is in requirements
has_package() {
  local package="$1"
  if [ -f "requirements.txt" ] && grep -qi "^${package}[=<>!\[]" requirements.txt 2>/dev/null; then
    return 0
  fi
  if [ -f "requirements.txt" ] && grep -qi "^${package}$" requirements.txt 2>/dev/null; then
    return 0
  fi
  if [ -f "pyproject.toml" ] && grep -qi "\"${package}[=<>!\[\"]\|'${package}[=<>!\[']" pyproject.toml 2>/dev/null; then
    return 0
  fi
  if [ -f "pyproject.toml" ] && grep -qi "\"${package}\"\|'${package}'" pyproject.toml 2>/dev/null; then
    return 0
  fi
  return 1
}

# Function to find the ASGI/WSGI app location
find_app_module() {
  local app_type="$1"  # "asgi" or "wsgi"

  # Check for explicit asgi.py or wsgi.py
  if [ "$app_type" = "asgi" ] && [ -f "asgi.py" ]; then
    echo "asgi:app"
    return 0
  fi
  if [ "$app_type" = "wsgi" ] && [ -f "wsgi.py" ]; then
    echo "wsgi:app"
    return 0
  fi

  # Common entry point files to check
  local files=("main.py" "app.py" "application.py" "server.py" "api.py")

  for file in "${files[@]}"; do
    if [ -f "$file" ]; then
      # Try to find the app variable name
      local module="${file%.py}"

      # Look for common app variable patterns
      if grep -qE "^app\s*=" "$file" 2>/dev/null; then
        echo "${module}:app"
        return 0
      fi
      if grep -qE "^application\s*=" "$file" 2>/dev/null; then
        echo "${module}:application"
        return 0
      fi
      # For Flask, also check create_app pattern
      if grep -qE "def create_app\(" "$file" 2>/dev/null; then
        echo "${module}:create_app()"
        return 0
      fi
    fi
  done

  # Default fallback
  echo "main:app"
  return 0
}

# Function to detect and start the appropriate server
detect_and_start() {
  local port="${PORT:-8080}"

  echo "Auto-detecting application type..."

  # Check for FastAPI or Starlette (ASGI)
  if has_package "fastapi" || has_package "starlette"; then
    local app_module=$(find_app_module "asgi")
    echo "Detected FastAPI/Starlette application"
    echo "Starting with: uvicorn ${app_module} --host 0.0.0.0 --port ${port}"
    exec python -m uvicorn "${app_module}" --host 0.0.0.0 --port "${port}"
  fi

  # Check for Flask (WSGI)
  if has_package "flask"; then
    local app_module=$(find_app_module "wsgi")
    local module="${app_module%%:*}"
    local app_var="${app_module##*:}"

    echo "Detected Flask application"

    # Prefer gunicorn if available, otherwise use Flask's built-in server
    if has_package "gunicorn"; then
      echo "Starting with: gunicorn ${app_module} --bind 0.0.0.0:${port}"
      exec python -m gunicorn "${app_module}" --bind "0.0.0.0:${port}"
    else
      echo "Starting with: flask run --host 0.0.0.0 --port ${port}"
      export FLASK_APP="${module}:${app_var}"
      exec python -m flask run --host 0.0.0.0 --port "${port}"
    fi
  fi

  # Check for standalone gunicorn with config
  if has_package "gunicorn"; then
    if [ -f "gunicorn.conf.py" ] || [ -f "gunicorn_config.py" ]; then
      local config_file="gunicorn.conf.py"
      [ -f "gunicorn_config.py" ] && config_file="gunicorn_config.py"
      local app_module=$(find_app_module "wsgi")
      echo "Detected Gunicorn with config"
      echo "Starting with: gunicorn -c ${config_file} ${app_module}"
      exec python -m gunicorn -c "${config_file}" "${app_module}"
    fi
  fi

  # Check for plain Python script
  if [ -f "main.py" ]; then
    echo "Detected plain Python script (main.py)"
    echo "Starting with: python main.py"
    exec python main.py
  fi

  if [ -f "app.py" ]; then
    echo "Detected plain Python script (app.py)"
    echo "Starting with: python app.py"
    exec python app.py
  fi

  # Check for package with __main__.py
  for dir in */; do
    if [ -f "${dir}__main__.py" ]; then
      local package="${dir%/}"
      echo "Detected Python package with __main__.py"
      echo "Starting with: python -m ${package}"
      exec python -m "${package}"
    fi
  done

  echo "Error: Could not detect application type. Please specify a command."
  echo "Supported frameworks: FastAPI, Starlette, Flask, Gunicorn"
  echo "Or provide a main.py or app.py script."
  exit 1
}

echo "Starting application..."

# If no arguments or "auto" is passed, detect and start automatically
if [ $# -eq 0 ] || [ "$1" = "auto" ]; then
  detect_and_start
fi

# Execute the CMD
exec "$@"
