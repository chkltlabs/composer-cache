#!/usr/bin/env bash
# Bootstrap/setup for local Composer and Node package cache.
# Idempotent: safe to run multiple times.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# Source shared config (LOCAL_PACKAGE_CACHE_ROOT, PKG_CACHE_PROXY_PORT, etc.)
# shellcheck source=scripts/config.sh
source "${REPO_ROOT}/scripts/config.sh"

# --- 1. Create cache root and layout ---
mkdir -p "${LOCAL_PACKAGE_CACHE_ROOT}/composer"
mkdir -p "${LOCAL_PACKAGE_CACHE_ROOT}/node"
if [[ ! -f "${LOCAL_PACKAGE_CACHE_ROOT}/cache.json" ]]; then
  echo '{"lastPopulate": null, "projects": [], "lockfileHashes": {}}' > "${LOCAL_PACKAGE_CACHE_ROOT}/cache.json"
fi
echo "Cache root: ${LOCAL_PACKAGE_CACHE_ROOT} (composer/ and node/ ready)"

# --- 2. Check for Composer and Node/npm ---
MISSING=()
if ! command -v composer &>/dev/null; then
  MISSING+=("Composer")
fi
if ! command -v node &>/dev/null; then
  MISSING+=("Node")
fi
if ! command -v npm &>/dev/null; then
  MISSING+=("npm")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "The following are not installed or not on PATH: ${MISSING[*]}"
  echo ""
  echo "Install instructions:"
  echo "  Composer: https://getcomposer.org/download/ (e.g. curl -sS https://getcomposer.org/installer | php && sudo mv composer.phar /usr/local/bin/composer)"
  echo "  Node/npm: https://nodejs.org/ (LTS), or via nvm: https://github.com/nvm-sh/nvm"
  echo ""
  echo "Re-run this script after installing."
  exit 1
fi

echo "Composer: $(composer --version 2>/dev/null || true)"
echo "Node:     $(node --version 2>/dev/null || true)"
echo "npm:      $(npm --version 2>/dev/null || true)"

# --- 3. Start proxy if it exists ---
PROXY_PID=""
PROXY_SCRIPT=""

if [[ -f "${REPO_ROOT}/proxy/server.js" ]] && command -v node &>/dev/null; then
  PROXY_SCRIPT="node ${REPO_ROOT}/proxy/server.js"
elif [[ -x "${REPO_ROOT}/bin/proxy" ]]; then
  PROXY_SCRIPT="${REPO_ROOT}/bin/proxy"
fi

if [[ -n "$PROXY_SCRIPT" ]]; then
  echo "Starting local proxy on ${PKG_CACHE_PROXY_HOST}:${PKG_CACHE_PROXY_PORT} ..."
  (
    cd "$REPO_ROOT"
    export LOCAL_PACKAGE_CACHE_ROOT PKG_CACHE_PROXY_PORT PKG_CACHE_PROXY_HOST
    nohup $PROXY_SCRIPT </dev/null >"${REPO_ROOT}/proxy.log" 2>&1 &
    echo $! > "${REPO_ROOT}/.proxy.pid"
  )
  PROXY_PID=$(cat "${REPO_ROOT}/.proxy.pid" 2>/dev/null || true)
  # Give proxy a moment to bind
  sleep 2
else
  echo "No proxy binary found (looked for proxy/server.js and bin/proxy)."
  echo "Start the proxy manually and ensure it listens on: ${PKG_CACHE_PROXY_HOST}:${PKG_CACHE_PROXY_PORT}"
  echo "Example: node proxy/server.js   # or  ./bin/proxy"
  echo ""
fi

# --- 4. Self-check ---
SELF_CHECK_URL="${PKG_CACHE_PROXY_URL}/"
HTTP_CODE=""
if command -v curl &>/dev/null; then
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$SELF_CHECK_URL" 2>/dev/null)" || true
fi

if [[ -n "$HTTP_CODE" ]]; then
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "404" ]]; then
    echo "Self-check OK: GET ${SELF_CHECK_URL} returned ${HTTP_CODE}"
  else
    echo "Self-check: GET ${SELF_CHECK_URL} returned ${HTTP_CODE} (expected 200 or 404). Is the proxy running?"
  fi
else
  echo "Self-check skipped (curl not found or proxy not responding). Ensure proxy is running on ${PKG_CACHE_PROXY_HOST}:${PKG_CACHE_PROXY_PORT}."
fi

if [[ -n "$PROXY_PID" ]]; then
  echo "Proxy started in background (PID $PROXY_PID). To stop: kill $PROXY_PID"
fi

echo "Setup complete."
