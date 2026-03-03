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
is_python=

[[ -f "$PROJECT_PATH/composer.json" ]] && is_composer=1
[[ -f "$PROJECT_PATH/package.json" ]] && [[ -f "$PROJECT_PATH/package-lock.json" || -f "$PROJECT_PATH/pnpm-lock.yaml" ]] && is_npm=1
# pip / pip-tools or Poetry
[[ -f "$PROJECT_PATH/requirements.txt" || -f "$PROJECT_PATH/requirements.in" ]] && is_python=1
[[ -f "$PROJECT_PATH/pyproject.toml" ]] && grep -q '\[tool\.poetry\]' "$PROJECT_PATH/pyproject.toml" 2>/dev/null && is_python=1

if [[ -z "$is_composer" && -z "$is_npm" && -z "$is_python" ]]; then
  echo "Error: no Composer, npm/pnpm, or Python project found at $PROJECT_PATH." >&2
  exit 1
fi

echo "Using proxy: $PKG_CACHE_PROXY_URL"
echo "Project:     $PROJECT_PATH"
echo ""

revert_composer=
revert_npm=
revert_python=

# --- Composer (global config: does not modify composer.json) ---
if [[ -n "$is_composer" ]]; then
  COMPOSER_HOME=$(composer config -g home 2>/dev/null) || true
  if [[ -z "$COMPOSER_HOME" || ! -d "$COMPOSER_HOME" ]]; then
    COMPOSER_HOME="${HOME}/.config/composer"
    [[ ! -d "$COMPOSER_HOME" ]] && COMPOSER_HOME="${HOME}/.composer"
  fi
  GLOBAL_CONFIG="${COMPOSER_HOME}/config.json"
  if [[ -f "$GLOBAL_CONFIG" ]]; then
    cp -a "$GLOBAL_CONFIG" "${GLOBAL_CONFIG}.pkg-cache-backup"
    echo "Composer: backed up global config to config.json.pkg-cache-backup"
  fi
  # Composer's config command writes repositories as an array (with "name" key), but
  # "composer config -g repo.packagist" only finds it when repositories.packagist is an object key.
  # So we set it via direct JSON edit (jq) so that repo.packagist is readable and installs use the proxy.
  COMPOSER_PACKAGIST_URL="${PKG_CACHE_PROXY_URL}/composer"
  # Composer blocks HTTP repos by default (secure-http). Proxy URL is http:// so we must allow it.
  if command -v jq &>/dev/null; then
    if [[ -f "$GLOBAL_CONFIG" ]]; then
      jq --arg url "$COMPOSER_PACKAGIST_URL" \
        '.config = ((.config // {}) | .["secure-http"] = false) | .repositories = ((.repositories // {}) | if type == "array" then {} else . end | . + {"packagist": {"type": "composer", "url": $url}})' \
        "$GLOBAL_CONFIG" > "$GLOBAL_CONFIG.new" && mv "$GLOBAL_CONFIG.new" "$GLOBAL_CONFIG"
    else
      mkdir -p "$(dirname "$GLOBAL_CONFIG")"
      jq -n --arg url "$COMPOSER_PACKAGIST_URL" \
        '.config = {"secure-http": false} | .repositories = {"packagist": {"type": "composer", "url": $url}}' \
        > "$GLOBAL_CONFIG"
    fi
  else
    composer config --global repo.packagist composer "$COMPOSER_PACKAGIST_URL"
    composer config --global secure-http false
  fi
  echo "Composer: set global repo.packagist to proxy (${PKG_CACHE_PROXY_URL}/composer)"
  # Migration: remove project-level proxy URL so global takes effect and repo stays clean
  cd "$PROJECT_PATH"
  if composer config repo.packagist &>/dev/null; then
    CURRENT=$(composer config repo.packagist --list 2>/dev/null | head -1)
    if [[ "$CURRENT" == *"${PKG_CACHE_PROXY_URL}"* ]]; then
      if [[ ! -f "$PROJECT_PATH/composer.json.pkg-cache-backup" ]]; then
        cp -a "$PROJECT_PATH/composer.json" "$PROJECT_PATH/composer.json.pkg-cache-backup"
        echo "Composer: backed up project composer.json (had proxy URL) to composer.json.pkg-cache-backup"
      fi
      composer config --unset repo.packagist
      echo "Composer: unset project-level repo.packagist so global config is used (commit composer.json to stop persisting proxy in repo)"
    fi
  fi
  cd - >/dev/null
  revert_composer="  composer config --global --unset repo.packagist   # affects all Composer projects on this machine"
fi

# --- npm / pnpm (user-level .npmrc: does not modify project files) ---
if [[ -n "$is_npm" ]]; then
  USER_NPMRC="${HOME}/.npmrc"
  if command -v npm &>/dev/null; then
    NPM_USERCONFIG=$(npm config get userconfig 2>/dev/null) || true
    [[ -n "$NPM_USERCONFIG" ]] && USER_NPMRC="$NPM_USERCONFIG"
  fi
  # Backup user-level .npmrc before modifying
  if [[ -f "$USER_NPMRC" ]]; then
    cp -a "$USER_NPMRC" "${USER_NPMRC}.pkg-cache-backup"
    echo "npm: backed up user config to $(basename "$USER_NPMRC").pkg-cache-backup"
  fi
  if [[ -f "$USER_NPMRC" ]] && grep -qE '^[[:space:]]*registry[[:space:]]*=' "$USER_NPMRC" 2>/dev/null; then
    tmp_npmrc=$(mktemp)
    grep -vE '^[[:space:]]*registry[[:space:]]*=' "$USER_NPMRC" > "$tmp_npmrc" || true
    cat "$tmp_npmrc" > "$USER_NPMRC"
    rm -f "$tmp_npmrc"
  fi
  echo "registry=${PKG_CACHE_PROXY_URL}/" >> "$USER_NPMRC"
  echo "npm/pnpm: set user-level registry to ${PKG_CACHE_PROXY_URL}/ (affects all npm/pnpm projects on this machine)"
  # Migration: remove project-level proxy registry so user-level is used and repo stays clean
  if [[ -f "$PROJECT_PATH/.npmrc" ]] && grep -qE "registry=${PKG_CACHE_PROXY_URL}" "$PROJECT_PATH/.npmrc" 2>/dev/null; then
    if [[ ! -f "$PROJECT_PATH/.npmrc.pkg-cache-backup" ]]; then
      cp -a "$PROJECT_PATH/.npmrc" "$PROJECT_PATH/.npmrc.pkg-cache-backup"
      echo "npm: backed up project .npmrc (had proxy registry) to .npmrc.pkg-cache-backup"
    fi
    tmp_pj=$(mktemp)
    grep -vE '^[[:space:]]*registry[[:space:]]*=' "$PROJECT_PATH/.npmrc" > "$tmp_pj" || true
    if [[ -s "$tmp_pj" ]]; then
      cat "$tmp_pj" > "$PROJECT_PATH/.npmrc"
    else
      rm -f "$PROJECT_PATH/.npmrc"
    fi
    rm -f "$tmp_pj"
    echo "npm: removed project-level registry so user-level config is used (commit to stop persisting proxy in repo)"
  fi
  revert_npm="  restore user .npmrc from .npmrc.pkg-cache-backup in your home (or run pkg-cache teardown-project)   # affects all npm/pnpm projects"
fi

# --- Python (pip / Poetry) ---
if [[ -n "$is_python" ]]; then
  PYPI_INDEX="${PKG_CACHE_PROXY_URL}/pypi/simple/"

  # pip: user-level config (does not modify project files)
  PIP_USER_CONFIG="${HOME}/.config/pip/pip.conf"
  if [[ ! -d "${HOME}/.config/pip" ]]; then
    mkdir -p "${HOME}/.config/pip"
  fi
  if [[ -f "$PIP_USER_CONFIG" ]]; then
    cp -a "$PIP_USER_CONFIG" "${PIP_USER_CONFIG}.pkg-cache-backup"
    echo "pip: backed up user config to pip.conf.pkg-cache-backup"
  fi
  if [[ -f "$PIP_USER_CONFIG" ]] && grep -qE '^[[:space:]]*index-url[[:space:]]*=' "$PIP_USER_CONFIG" 2>/dev/null; then
    tmp_pip=$(mktemp)
    grep -vE '^[[:space:]]*index-url[[:space:]]*=' "$PIP_USER_CONFIG" > "$tmp_pip" || true
    cat "$tmp_pip" > "$PIP_USER_CONFIG"
    rm -f "$tmp_pip"
  fi
  printf "[global]\nindex-url = %s\n" "$PYPI_INDEX" >> "$PIP_USER_CONFIG"
  echo "pip: set user-level index-url to ${PYPI_INDEX} (affects all pip installs on this machine)"
  # Migration: remove project-level proxy so user-level is used and repo stays clean
  PIP_PROJECT_CONF="$PROJECT_PATH/.pip/pip.conf"
  if [[ -f "$PIP_PROJECT_CONF" ]] && grep -q "${PKG_CACHE_PROXY_URL}" "$PIP_PROJECT_CONF" 2>/dev/null; then
    if [[ ! -f "${PIP_PROJECT_CONF}.pkg-cache-backup" ]]; then
      cp -a "$PIP_PROJECT_CONF" "${PIP_PROJECT_CONF}.pkg-cache-backup"
      echo "pip: backed up project .pip/pip.conf (had proxy) to .pip/pip.conf.pkg-cache-backup"
    fi
    tmp_pp=$(mktemp)
    grep -vE '^[[:space:]]*index-url[[:space:]]*=' "$PIP_PROJECT_CONF" > "$tmp_pp" || true
    if [[ -s "$tmp_pp" ]] && grep -qv '^[[:space:]]*$' "$tmp_pp" 2>/dev/null; then
      cat "$tmp_pp" > "$PIP_PROJECT_CONF"
    else
      rm -f "$PIP_PROJECT_CONF"
      rmdir "$PROJECT_PATH/.pip" 2>/dev/null || true
    fi
    rm -f "$tmp_pp"
    echo "pip: removed project-level index-url so user-level config is used (commit to stop persisting proxy in repo)"
  fi
  revert_python="  restore user pip config from ~/.config/pip/pip.conf.pkg-cache-backup (or run pkg-cache teardown-project)   # affects all pip installs"

  # Poetry: add repository and optional source in pyproject.toml
  if [[ -f "$PROJECT_PATH/pyproject.toml" ]] && grep -q '\[tool\.poetry\]' "$PROJECT_PATH/pyproject.toml" 2>/dev/null; then
    cd "$PROJECT_PATH"
    if command -v poetry &>/dev/null; then
      poetry config repositories.pkg-cache "$PYPI_INDEX" --local 2>/dev/null || true
      # Add default source to pyproject.toml so Poetry uses the proxy
      if ! grep -q 'pkg-cache\|pypi/simple' "$PROJECT_PATH/pyproject.toml" 2>/dev/null; then
        BACKUP_PYPROJECT="$PROJECT_PATH/pyproject.toml.pkg-cache-backup"
        cp -a "$PROJECT_PATH/pyproject.toml" "$BACKUP_PYPROJECT"
        {
          echo ""
          echo "# pkg-cache proxy (add by pkg-cache setup-project)"
          echo "[[tool.poetry.source]]"
          echo "name = \"pkg-cache\""
          echo "url = \"${PYPI_INDEX}\""
          echo "default = true"
        } >> "$PROJECT_PATH/pyproject.toml"
        echo "Poetry: added [[tool.poetry.source]] pkg-cache to pyproject.toml"
        revert_python="$revert_python ; Poetry: restore pyproject.toml from pyproject.toml.pkg-cache-backup or remove the [[tool.poetry.source]] block"
      else
        echo "Poetry: repository pkg-cache set (--local). Add [[tool.poetry.source]] with default = true in pyproject.toml if not already present."
      fi
    fi
    cd - >/dev/null
  fi
fi

echo ""
echo "--- Configured. To revert ---"
[[ -n "$revert_composer" ]] && echo "Composer: $revert_composer"
[[ -n "$revert_npm" ]] && echo "npm:      $revert_npm"
[[ -n "$revert_python" ]] && echo "Python:   $revert_python"
echo ""
echo "Ensure the proxy is running (e.g. pkg-cache setup or start proxy on port $PKG_CACHE_PROXY_PORT) before running installs."
