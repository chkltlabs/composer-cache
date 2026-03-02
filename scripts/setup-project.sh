#!/usr/bin/env bash
# Per-project setup: configure a project to use the local package-cache proxy.
# Usage: setup-project.sh [path]
# Default path is current directory. Sources scripts/config.sh for proxy URL/port.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

PROJECT_PATH="${1:-.}"
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Error: not a directory: $PROJECT_PATH" >&2
  exit 1
fi

is_composer=
is_npm=

[[ -f "$PROJECT_PATH/composer.json" ]] && is_composer=1
[[ -f "$PROJECT_PATH/package.json" ]] && [[ -f "$PROJECT_PATH/package-lock.json" || -f "$PROJECT_PATH/pnpm-lock.yaml" ]] && is_npm=1

if [[ -z "$is_composer" && -z "$is_npm" ]]; then
  echo "Error: no Composer or npm/pnpm project found at $PROJECT_PATH (need composer.json or package.json + lockfile)." >&2
  exit 1
fi

echo "Using proxy: $PKG_CACHE_PROXY_URL"
echo "Project:     $PROJECT_PATH"
echo ""

revert_composer=
revert_npm=

# --- Composer ---
if [[ -n "$is_composer" ]]; then
  cd "$PROJECT_PATH"
  if composer config repo.packagist &>/dev/null; then
    BACKUP_FILE="$PROJECT_PATH/composer.json.pkg-cache-backup"
    cp -a composer.json "$BACKUP_FILE"
    echo "Composer: backed up existing repo.packagist config to composer.json.pkg-cache-backup"
  fi
  composer config repo.packagist composer "${PKG_CACHE_PROXY_URL}/composer"
  echo "Composer: set repo.packagist to proxy (${PKG_CACHE_PROXY_URL}/composer)"
  revert_composer="  composer config --unset repo.packagist"
  [[ -f "$BACKUP_FILE" ]] && revert_composer="$revert_composer   # then restore composer.json from composer.json.pkg-cache-backup if desired"
  cd - >/dev/null
fi

# --- npm / pnpm (.npmrc) ---
if [[ -n "$is_npm" ]]; then
  NPMRC="$PROJECT_PATH/.npmrc"
  if [[ -f "$NPMRC" ]] && grep -qE '^[[:space:]]*registry[[:space:]]*=' "$NPMRC" 2>/dev/null; then
    BACKUP_NPMRC="$PROJECT_PATH/.npmrc.pkg-cache-backup"
    cp -a "$NPMRC" "$BACKUP_NPMRC"
    echo "npm: backed up existing .npmrc to .npmrc.pkg-cache-backup"
  fi
  if [[ -f "$NPMRC" ]]; then
    # Remove existing registry line(s), then ensure one registry line (portable sed)
    if grep -qE '^[[:space:]]*registry[[:space:]]*=' "$NPMRC" 2>/dev/null; then
      tmp_npmrc=$(mktemp)
      grep -vE '^[[:space:]]*registry[[:space:]]*=' "$NPMRC" > "$tmp_npmrc" || true
      cat "$tmp_npmrc" > "$NPMRC"
      rm -f "$tmp_npmrc"
    fi
    echo "registry=${PKG_CACHE_PROXY_URL}/" >> "$NPMRC"
  else
    echo "registry=${PKG_CACHE_PROXY_URL}/" > "$NPMRC"
  fi
  echo "npm/pnpm: set registry in .npmrc to ${PKG_CACHE_PROXY_URL}/"
  revert_npm="  restore .npmrc from .npmrc.pkg-cache-backup (if present), or remove the 'registry=' line from .npmrc"
fi

echo ""
echo "--- Configured. To revert ---"
[[ -n "$revert_composer" ]] && echo "Composer: $revert_composer"
[[ -n "$revert_npm" ]] && echo "npm:      $revert_npm"
echo ""
echo "Ensure the proxy is running (e.g. pkg-cache setup or start proxy on port $PKG_CACHE_PROXY_PORT) before running composer install / npm install."
