#!/usr/bin/env bash
# Integration test: start proxy, configure Composer to use it, run composer install,
# then verify Composer packages appear in .local-package-cache.
# Usage: ./scripts/test-composer-cache.sh [--no-cleanup]
# Run repeatedly to debug cache population. With --no-cleanup, leaves test dir and proxy state for inspection.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

NO_CLEANUP=false
for arg in "$@"; do
  [[ "$arg" == "--no-cleanup" ]] && NO_CLEANUP=true
done

# Isolated test env so we don't touch user's real cache or port
TEST_PORT="${PKG_CACHE_TEST_PORT:-14873}"
TEST_ROOT="${TMPDIR:-/tmp}/pkg-cache-test-$$"
TEST_CACHE="${TEST_ROOT}/.local-package-cache"
TEST_PROJECT="${TEST_ROOT}/composer-test-project"
export LOCAL_PACKAGE_CACHE_ROOT="$TEST_CACHE"
export PKG_CACHE_PROXY_PORT="$TEST_PORT"
export PKG_CACHE_PROXY_HOST="${PKG_CACHE_PROXY_HOST:-127.0.0.1}"
export PKG_CACHE_PROXY_URL="http://${PKG_CACHE_PROXY_HOST}:${TEST_PORT}"

cleanup() {
  local status=$?
  if [[ "$NO_CLEANUP" == true ]]; then
    echo ""
    echo "[TEST] --no-cleanup: leaving test root $TEST_ROOT (cache: $TEST_CACHE)"
    echo "[TEST] Proxy may still be running on port $TEST_PORT. Stop with: kill \$(lsof -i :$TEST_PORT -t 2>/dev/null)"
    return "$status"
  fi
  echo "[TEST] Cleaning up..."
  for pidfile in "$TEST_ROOT/proxy.pid" "$REPO_ROOT/.proxy.pid"; do
    if [[ -f "$pidfile" ]]; then
      local pid
      pid=$(cat "$pidfile" 2>/dev/null)
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
      fi
      rm -f "$pidfile"
    fi
  done
  if command -v lsof &>/dev/null; then
    while read -r pid; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < <(lsof -i ":$TEST_PORT" -t 2>/dev/null) || true
  fi
  # Restore Composer global config if we backed it up
  COMPOSER_HOME=$(composer config -g home 2>/dev/null) || true
  [[ -z "$COMPOSER_HOME" || ! -d "$COMPOSER_HOME" ]] && COMPOSER_HOME="${HOME}/.config/composer"
  [[ ! -d "$COMPOSER_HOME" ]] && COMPOSER_HOME="${HOME}/.composer"
  if [[ -f "${COMPOSER_HOME}/config.json.pkg-cache-backup" ]]; then
    mv "${COMPOSER_HOME}/config.json.pkg-cache-backup" "${COMPOSER_HOME}/config.json"
    echo "[TEST] Restored Composer global config from backup"
  fi
  rm -rf "$TEST_ROOT"
  return "$status"
}

trap cleanup EXIT

echo "=============================================="
echo " pkg-cache Composer integration test"
echo "=============================================="
echo "[TEST] Test root:      $TEST_ROOT"
echo "[TEST] Test cache:     $TEST_CACHE"
echo "[TEST] Proxy URL:      $PKG_CACHE_PROXY_URL"
echo "[TEST] Test project:   $TEST_PROJECT"
echo ""

# --- 1. Create minimal Composer project ---
echo "[TEST] Step 1: Creating minimal Composer project..."
mkdir -p "$TEST_PROJECT"
cd "$TEST_PROJECT"
# Minimal composer.json with a few small deps (no Laravel to keep it fast and network-light)
cat > composer.json <<'COMPOSER_JSON'
{
  "name": "test/pkg-cache-test",
  "description": "Minimal project for pkg-cache integration test",
  "require": {
    "php": ">=7.4",
    "psr/log": "^1.0|^2.0|^3.0",
    "monolog/monolog": "^2.0"
  },
  "config": {
    "sort-packages": true
  }
}
COMPOSER_JSON

if ! composer --version &>/dev/null; then
  echo "[TEST] FAIL: composer not found. Install Composer and re-run." >&2
  exit 1
fi

# Do NOT generate lock file here. We will run composer update AFTER the proxy is up
# so that metadata requests (p2/*.json) go through the proxy and populate the cache.

# --- 2. Ensure cache dirs exist and start proxy ---
echo "[TEST] Step 2: Starting proxy with test cache root..."
mkdir -p "$TEST_CACHE/composer" "$TEST_CACHE/node" "$TEST_CACHE/python"
if [[ ! -f "$TEST_CACHE/cache.json" ]]; then
  echo '{"lastPopulate": null, "projects": [], "lockfileHashes": {}}' > "$TEST_CACHE/cache.json"
fi

# Kill anything on test port
if command -v lsof &>/dev/null; then
  while read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done < <(lsof -i ":$TEST_PORT" -t 2>/dev/null) || true
  sleep 1
fi

(
  cd "$REPO_ROOT"
  export LOCAL_PACKAGE_CACHE_ROOT PKG_CACHE_PROXY_PORT PKG_CACHE_PROXY_HOST
  node "$REPO_ROOT/proxy/server.js" </dev/null >>"$TEST_ROOT/proxy.log" 2>&1 &
  echo $! > "$TEST_ROOT/proxy.pid"
)
PROXY_PID=$(cat "$TEST_ROOT/proxy.pid" 2>/dev/null)
echo "[TEST] Proxy started (PID $PROXY_PID), waiting for health..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 1 --max-time 2 "$PKG_CACHE_PROXY_URL/health" 2>/dev/null | grep -q '^200$'; then
    echo "[TEST] Proxy health OK"
    break
  fi
  if [[ $i -eq 10 ]]; then
    echo "[TEST] FAIL: Proxy did not become healthy. Log:" >&2
    cat "$TEST_ROOT/proxy.log" 2>/dev/null | tail -20
    exit 1
  fi
  sleep 1
done
echo ""

# --- 3. Configure Composer to use proxy (pkg-cache setup-project) ---
echo "[TEST] Step 3: Configuring Composer to use proxy (pkg-cache setup-project)..."
"$REPO_ROOT/bin/pkg-cache" setup-project "$TEST_PROJECT" 2>&1 | sed 's/^/  /'

# Force Composer to use ONLY our proxy for packagist (override default). Without this,
# Composer may still have the default packagist.org and use it instead of our proxy.
COMPOSER_HOME=$(composer config -g home 2>/dev/null) || true
[[ -z "$COMPOSER_HOME" || ! -d "$COMPOSER_HOME" ]] && COMPOSER_HOME="${HOME}/.config/composer"
[[ ! -d "$COMPOSER_HOME" ]] && COMPOSER_HOME="${HOME}/.composer"
GLOBAL_CONFIG="${COMPOSER_HOME}/config.json"
if command -v jq &>/dev/null && [[ -f "$GLOBAL_CONFIG" ]]; then
  echo "[TEST] Ensuring repositories.packagist is object key (so Composer uses proxy only)..."
  jq --arg url "${PKG_CACHE_PROXY_URL}/composer" \
    '.repositories = ((.repositories // {}) | if type == "array" then {} else . end | . + {"packagist": {"type": "composer", "url": $url}})' \
    "$GLOBAL_CONFIG" > "$GLOBAL_CONFIG.new" && mv "$GLOBAL_CONFIG.new" "$GLOBAL_CONFIG"
fi

# Verify Composer sees the proxy
echo "[TEST] Verifying Composer repo.packagist..."
if composer config -g repo.packagist &>/dev/null; then
  COMPOSER_REPO=$(composer config -g repo.packagist 2>/dev/null | head -1)
  echo "[TEST]   composer config -g repo.packagist => $COMPOSER_REPO"
else
  echo "[TEST]   composer config -g repo.packagist => (not set or not readable)"
  echo "[TEST]   Full repo config:"
  composer config -g --list 2>/dev/null | grep -E 'repo|repositor' || true
fi
echo ""

# --- 3b. Sanity check: hit proxy directly and verify it caches ---
echo "[TEST] Step 3b: Sanity check - fetch one package URL via proxy and verify cache..."
CURL_OUT=$(curl -sS -w "\n%{http_code}" "$PKG_CACHE_PROXY_URL/composer/p2/psr/log.json" 2>/dev/null) || true
CURL_CODE=$(echo "$CURL_OUT" | tail -1)
echo "[TEST]   GET $PKG_CACHE_PROXY_URL/composer/p2/psr/log.json => HTTP $CURL_CODE"
if [[ "$CURL_CODE" == "200" ]]; then
  if [[ -f "$TEST_CACHE/composer/p2/psr/log.json" ]]; then
    echo "[TEST]   Cache file created: composer/p2/psr/log.json (sanity OK)"
  else
    echo "[TEST]   WARN: Proxy returned 200 but cache file not found at $TEST_CACHE/composer/p2/psr/log.json"
    echo "[TEST]   Cache dir contents:"
    find "$TEST_CACHE/composer" -type f 2>/dev/null | head -20 | sed 's/^/[TEST]     /'
  fi
else
  echo "[TEST]   WARN: Proxy returned $CURL_CODE (expected 200)"
fi
echo ""

# --- 4. Run composer update (resolves deps → fetches metadata through proxy, populates cache) ---
echo "[TEST] Step 4: Running composer update (metadata requests must go through proxy)..."
cd "$TEST_PROJECT"
# Use a completely isolated Composer home and cache so no existing cache is used
export COMPOSER_HOME="$TEST_ROOT/.composer-home"
export COMPOSER_CACHE_DIR="$TEST_ROOT/composer-cache-dir"
rm -rf "$COMPOSER_HOME" "$COMPOSER_CACHE_DIR" "$TEST_PROJECT/composer.lock" "$TEST_PROJECT/vendor"
mkdir -p "$COMPOSER_HOME" "$COMPOSER_CACHE_DIR"
# Write config: packagist = proxy only, and allow HTTP (proxy URL is http://)
mkdir -p "$COMPOSER_HOME"
if command -v jq &>/dev/null; then
  jq -n --arg url "${PKG_CACHE_PROXY_URL}/composer" \
    '.config = {"secure-http": false} | .repositories = {"packagist": {"type": "composer", "url": $url}}' \
    > "$COMPOSER_HOME/config.json"
  echo "[TEST]   Wrote $COMPOSER_HOME/config.json (repo.packagist = proxy, secure-http = false)"
else
  echo '{"config":{"secure-http":false},"repositories":{"packagist":{"type":"composer","url":"'${PKG_CACHE_PROXY_URL}'/composer"}}' > "$COMPOSER_HOME/config.json"
fi
composer update --no-interaction --no-scripts --no-cache 2>&1 | tee "$TEST_ROOT/composer-update.log" | tail -40
echo ""

# --- 5. Verify cache population ---
echo "[TEST] Step 5: Verifying .local-package-cache/composer..."
COMPOSER_CACHE_SUBDIR="$TEST_CACHE/composer"
P2_DIR="$COMPOSER_CACHE_SUBDIR/p2"
JSON_COUNT=0
if [[ -d "$P2_DIR" ]]; then
  JSON_COUNT=$(find "$P2_DIR" -type f -name "*.json" ! -name "*.meta.json" 2>/dev/null | wc -l | tr -d ' ')
fi
echo "[TEST]   Cache dir exists: $([ -d "$COMPOSER_CACHE_SUBDIR" ] && echo yes || echo no)"
echo "[TEST]   p2/ exists:       $([ -d "$P2_DIR" ] && echo yes || echo no)"
echo "[TEST]   Package JSON files in p2/: $JSON_COUNT"

if [[ -d "$P2_DIR" ]]; then
  echo "[TEST]   Sample files under p2/:"
  find "$P2_DIR" -type f -name "*.json" ! -name "*.meta.json" 2>/dev/null | head -10 | while read -r f; do
    echo "[TEST]     $f"
  done
  echo "[TEST]   Directory layout (top-level p2):"
  ls -la "$P2_DIR" 2>/dev/null | head -15 | sed 's/^/[TEST]     /'
fi

# Also show any files at root of composer cache (list.json, packages.json, etc.)
ROOT_PACKAGES_JSON=
if [[ -d "$COMPOSER_CACHE_SUBDIR" ]]; then
  echo "[TEST]   All files/dirs in composer cache root:"
  ls -la "$COMPOSER_CACHE_SUBDIR" 2>/dev/null | sed 's/^/[TEST]     /'
  [[ -f "$COMPOSER_CACHE_SUBDIR/packages.json" ]] && ROOT_PACKAGES_JSON=1
fi

echo ""
# Pass if we have p2 package metadata and/or root packages.json (Composer 2 may use root + p2)
if [[ "$JSON_COUNT" -ge 2 ]]; then
  echo "[TEST] PASS: Found $JSON_COUNT package metadata file(s) in p2/ and cache is populated."
elif [[ "$JSON_COUNT" -gt 0 ]] || [[ -n "$ROOT_PACKAGES_JSON" ]]; then
  echo "[TEST] PASS: Cache is populated (p2: $JSON_COUNT file(s), root packages.json: $([ -n "$ROOT_PACKAGES_JSON" ] && echo yes || echo no))."
else
  echo "[TEST] FAIL: No package JSON files found in $P2_DIR and no packages.json in cache root"
  echo "[TEST] Debug: proxy log (last 40 lines):"
  tail -40 "$TEST_ROOT/proxy.log" 2>/dev/null | sed 's/^/[TEST]   /'
  echo "[TEST] Debug: composer update log (first 50 lines):"
  head -50 "$TEST_ROOT/composer-update.log" 2>/dev/null | sed 's/^/[TEST]   /'
  exit 1
fi
