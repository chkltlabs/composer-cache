#!/usr/bin/env bash
# Populate the local package cache from one or more project paths.
# Projects must already be configured to use the proxy (run setup-project first).
# Usage: populate.sh [path ...]
# If no path given, uses current directory.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

if [[ $# -eq 0 ]]; then
  PATHS=(.)
else
  PATHS=("$@")
fi

for PROJECT_PATH in "${PATHS[@]}"; do
  PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"
  echo "--- $PROJECT_PATH ---"
  if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Error: not a directory: $PROJECT_PATH" >&2
    exit 1
  fi

  cd "$PROJECT_PATH"

  if [[ -f composer.lock ]]; then
    echo "Running: composer install"
    composer install
  fi

  if [[ -f package-lock.json ]]; then
    echo "Running: npm ci"
    npm ci
  elif [[ -f pnpm-lock.yaml ]]; then
    echo "Running: pnpm install"
    pnpm install
  fi

  if [[ ! -f composer.lock && ! -f package-lock.json && ! -f pnpm-lock.yaml ]]; then
    echo "No composer.lock, package-lock.json, or pnpm-lock.yaml found; skipping."
  fi

  cd - >/dev/null
  echo ""
done

echo "Done. Cache is populated via proxy at $PKG_CACHE_PROXY_URL."
