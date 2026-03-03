#!/usr/bin/env bash
# Undo per-project setup: revert to online-only, no cache (default Packagist, npm, PyPI).
# Usage: unsetup-project.sh [path]
# Default path is current directory. Idempotent; safe to run if project was never set up.

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

echo "Reverting to online-only (no cache). Project: $PROJECT_PATH"
echo ""

# --- Composer (global config) ---
COMPOSER_HOME=$(composer config -g home 2>/dev/null) || true
if [[ -z "$COMPOSER_HOME" || ! -d "$COMPOSER_HOME" ]]; then
  COMPOSER_HOME="${HOME}/.config/composer"
  [[ ! -d "$COMPOSER_HOME" ]] && COMPOSER_HOME="${HOME}/.composer"
fi
GLOBAL_CONFIG="${COMPOSER_HOME}/config.json"
GLOBAL_BACKUP="${GLOBAL_CONFIG}.pkg-cache-backup"
if composer config --global repo.packagist &>/dev/null; then
  CURRENT=$(composer config --global repo.packagist --list 2>/dev/null | head -1)
  if [[ "$CURRENT" == *"${PKG_CACHE_PROXY_URL}"* ]]; then
    composer config --global --unset repo.packagist
    echo "Composer: unset global repo.packagist (using packagist.org again; affects all Composer projects on this machine)"
  fi
fi
if [[ -f "$GLOBAL_BACKUP" ]]; then
  cp -a "$GLOBAL_BACKUP" "$GLOBAL_CONFIG"
  rm -f "$GLOBAL_BACKUP"
  echo "Composer: restored global config from config.json.pkg-cache-backup"
fi
# Optional project cleanup: remove proxy URL from project composer.json (e.g. from old paradigm)
if [[ -f "$PROJECT_PATH/composer.json" ]]; then
  cd "$PROJECT_PATH"
  if composer config repo.packagist &>/dev/null; then
    CURRENT=$(composer config repo.packagist --list 2>/dev/null | head -1)
    if [[ "$CURRENT" == *"${PKG_CACHE_PROXY_URL}"* ]]; then
      composer config --unset repo.packagist
      echo "Composer: unset project-level repo.packagist in this project"
    fi
  fi
  if [[ -f "$PROJECT_PATH/composer.json.pkg-cache-backup" ]]; then
    cp -a "$PROJECT_PATH/composer.json.pkg-cache-backup" "$PROJECT_PATH/composer.json"
    rm -f "$PROJECT_PATH/composer.json.pkg-cache-backup"
    echo "Composer: restored project composer.json from composer.json.pkg-cache-backup"
  fi
  cd - >/dev/null
fi

# --- npm / pnpm (user-level .npmrc) ---
USER_NPMRC="${HOME}/.npmrc"
if command -v npm &>/dev/null; then
  NPM_USERCONFIG=$(npm config get userconfig 2>/dev/null) || true
  [[ -n "$NPM_USERCONFIG" ]] && USER_NPMRC="$NPM_USERCONFIG"
fi
if [[ -f "${USER_NPMRC}.pkg-cache-backup" ]]; then
  cp -a "${USER_NPMRC}.pkg-cache-backup" "$USER_NPMRC"
  rm -f "${USER_NPMRC}.pkg-cache-backup"
  echo "npm: restored user .npmrc from .npmrc.pkg-cache-backup (affects all npm/pnpm projects on this machine)"
elif [[ -f "$USER_NPMRC" ]] && grep -qE "registry=${PKG_CACHE_PROXY_URL}" "$USER_NPMRC" 2>/dev/null; then
  tmp_npmrc=$(mktemp)
  grep -vE '^[[:space:]]*registry[[:space:]]*=' "$USER_NPMRC" > "$tmp_npmrc" || true
  if [[ -s "$tmp_npmrc" ]]; then
    cat "$tmp_npmrc" > "$USER_NPMRC"
  else
    rm -f "$USER_NPMRC"
  fi
  rm -f "$tmp_npmrc"
  echo "npm: removed proxy registry from user .npmrc (using registry.npmjs.org again)"
fi
# Optional project cleanup: remove proxy from project .npmrc (e.g. from old paradigm)
if [[ -f "$PROJECT_PATH/.npmrc.pkg-cache-backup" ]]; then
  cp -a "$PROJECT_PATH/.npmrc.pkg-cache-backup" "$PROJECT_PATH/.npmrc"
  rm -f "$PROJECT_PATH/.npmrc.pkg-cache-backup"
  echo "npm: restored project .npmrc from .npmrc.pkg-cache-backup"
elif [[ -f "$PROJECT_PATH/.npmrc" ]] && grep -qE "registry=${PKG_CACHE_PROXY_URL}" "$PROJECT_PATH/.npmrc" 2>/dev/null; then
  tmp_pj=$(mktemp)
  grep -vE '^[[:space:]]*registry[[:space:]]*=' "$PROJECT_PATH/.npmrc" > "$tmp_pj" || true
  if [[ -s "$tmp_pj" ]]; then
    cat "$tmp_pj" > "$PROJECT_PATH/.npmrc"
  else
    rm -f "$PROJECT_PATH/.npmrc"
  fi
  rm -f "$tmp_pj"
  echo "npm: removed proxy registry from project .npmrc"
fi

# --- Python (pip, user-level config) ---
PIP_USER_CONFIG="${HOME}/.config/pip/pip.conf"
PIP_USER_BACKUP="${PIP_USER_CONFIG}.pkg-cache-backup"
if [[ -f "$PIP_USER_BACKUP" ]]; then
  cp -a "$PIP_USER_BACKUP" "$PIP_USER_CONFIG"
  rm -f "$PIP_USER_BACKUP"
  echo "pip: restored user config from pip.conf.pkg-cache-backup (affects all pip installs on this machine)"
elif [[ -f "$PIP_USER_CONFIG" ]] && grep -q "${PKG_CACHE_PROXY_URL}" "$PIP_USER_CONFIG" 2>/dev/null; then
  tmp_pip=$(mktemp)
  grep -vE '^[[:space:]]*index-url[[:space:]]*=' "$PIP_USER_CONFIG" > "$tmp_pip" || true
  if [[ -s "$tmp_pip" ]] && grep -qv '^[[:space:]]*$' "$tmp_pip" 2>/dev/null; then
    cat "$tmp_pip" > "$PIP_USER_CONFIG"
  else
    rm -f "$PIP_USER_CONFIG"
    rmdir "$(dirname "$PIP_USER_CONFIG")" 2>/dev/null || true
  fi
  rm -f "$tmp_pip"
  echo "pip: removed proxy index from user config (using pypi.org again)"
fi
# Optional project cleanup: remove proxy from project .pip/pip.conf (e.g. from old paradigm)
PIP_PROJECT_CONF="$PROJECT_PATH/.pip/pip.conf"
if [[ -f "${PIP_PROJECT_CONF}.pkg-cache-backup" ]]; then
  cp -a "${PIP_PROJECT_CONF}.pkg-cache-backup" "$PIP_PROJECT_CONF"
  rm -f "${PIP_PROJECT_CONF}.pkg-cache-backup"
  echo "pip: restored project .pip/pip.conf from backup"
elif [[ -f "$PIP_PROJECT_CONF" ]] && grep -q "${PKG_CACHE_PROXY_URL}" "$PIP_PROJECT_CONF" 2>/dev/null; then
  tmp_pp=$(mktemp)
  grep -vE '^[[:space:]]*index-url[[:space:]]*=' "$PIP_PROJECT_CONF" > "$tmp_pp" || true
  if [[ -s "$tmp_pp" ]] && grep -qv '^[[:space:]]*$' "$tmp_pp" 2>/dev/null; then
    cat "$tmp_pp" > "$PIP_PROJECT_CONF"
  else
    rm -f "$PIP_PROJECT_CONF"
    rmdir "$PROJECT_PATH/.pip" 2>/dev/null || true
  fi
  rm -f "$tmp_pp"
  echo "pip: removed proxy index from project .pip/pip.conf"
fi

# --- Poetry ---
if [[ -f "$PROJECT_PATH/pyproject.toml" ]] && grep -q '\[tool\.poetry\]' "$PROJECT_PATH/pyproject.toml" 2>/dev/null; then
  cd "$PROJECT_PATH"
  if command -v poetry &>/dev/null; then
    if poetry config repositories.pkg-cache &>/dev/null; then
      poetry config --unset repositories.pkg-cache --local 2>/dev/null || true
      echo "Poetry: unset repositories.pkg-cache (--local)"
    fi
  fi
  if [[ -f "$PROJECT_PATH/pyproject.toml.pkg-cache-backup" ]]; then
    cp -a "$PROJECT_PATH/pyproject.toml.pkg-cache-backup" "$PROJECT_PATH/pyproject.toml"
    rm -f "$PROJECT_PATH/pyproject.toml.pkg-cache-backup"
    echo "Poetry: restored pyproject.toml from pyproject.toml.pkg-cache-backup"
  elif grep -q 'pkg-cache\|pypi/simple' "$PROJECT_PATH/pyproject.toml" 2>/dev/null; then
    # Remove the [[tool.poetry.source]] block we added (portable bash)
    pyproject_tmp=$(mktemp)
    in_block=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^\[\[tool\.poetry\.source\]\] ]]; then
        in_block=1
        continue
      fi
      if [[ $in_block -eq 1 ]]; then
        if [[ "$line" =~ ^[[:space:]]*default[[:space:]]*= ]]; then
          in_block=0
        fi
        continue
      fi
      if [[ "$line" =~ pkg-cache ]]; then
        continue
      fi
      printf '%s\n' "$line" >> "$pyproject_tmp"
    done < "$PROJECT_PATH/pyproject.toml"
    mv "$pyproject_tmp" "$PROJECT_PATH/pyproject.toml"
    echo "Poetry: removed pkg-cache source from pyproject.toml (using PyPI again)"
  fi
  cd - >/dev/null
fi

echo ""
echo "Done. Project now uses online-only (no local cache proxy)."
