#!/usr/bin/env bash
# Populate the local package cache from one or more project paths.
# Projects must already be configured to use the proxy (run setup-project first).
# Usage: populate.sh [path ...]
# If no path given, uses current directory.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# Run composer install, preferring Laravel Sail when available on the host.
run_composer_install() {
  # Detect Laravel Sail on the host (not inside a container).
  if [[ -x "./vendor/bin/sail" && -S /var/run/docker.sock && ! -f "/.dockerenv" ]]; then
    echo "Detected Laravel Sail; running: ./vendor/bin/sail composer install --no-cache"
    ./vendor/bin/sail composer install --no-cache
  else
    echo "Running: composer install --no-cache"
    composer install --no-cache
  fi
}

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
    run_composer_install
  fi

  if [[ -f package-lock.json ]]; then
    echo "Running: npm ci"
    npm ci
  elif [[ -f pnpm-lock.yaml ]]; then
    echo "Running: pnpm install"
    pnpm install
  fi

  # Python: pip or pip-tools
  if [[ -f requirements.txt ]]; then
    if [[ -f .pip/pip.conf ]]; then
      export PIP_CONFIG_FILE="$PROJECT_PATH/.pip/pip.conf"
    fi
    if command -v pip-sync &>/dev/null && [[ -f requirements.txt ]]; then
      echo "Running: pip-sync requirements.txt"
      pip-sync requirements.txt 2>/dev/null || pip install -r requirements.txt
    else
      echo "Running: python -m pip install -r requirements.txt"
      python -m pip install -r requirements.txt
    fi
    unset PIP_CONFIG_FILE 2>/dev/null || true
  elif [[ -f requirements.in ]]; then
    if [[ -f .pip/pip.conf ]]; then
      export PIP_CONFIG_FILE="$PROJECT_PATH/.pip/pip.conf"
    fi
    if command -v pip-compile &>/dev/null; then
      echo "Running: pip-compile requirements.in"
      pip-compile requirements.in -o requirements.txt 2>/dev/null || true
    fi
    if [[ -f requirements.txt ]]; then
      echo "Running: pip install -r requirements.txt"
      pip install -r requirements.txt
    else
      echo "Running: pip install -r requirements.in"
      pip install -r requirements.in
    fi
    unset PIP_CONFIG_FILE 2>/dev/null || true
  fi

  # Poetry
  if [[ -f pyproject.toml ]] && grep -q '\[tool\.poetry\]' pyproject.toml 2>/dev/null && command -v poetry &>/dev/null; then
    echo "Running: poetry install"
    poetry install --no-interaction --no-ansi
  fi

  if [[ ! -f composer.lock && ! -f package-lock.json && ! -f pnpm-lock.yaml && ! -f requirements.txt && ! -f requirements.in ]]; then
    if ! { [[ -f pyproject.toml ]] && grep -q '\[tool\.poetry\]' pyproject.toml 2>/dev/null; }; then
      echo "No known lockfile or Python project found; skipping."
    fi
  fi

  cd - >/dev/null
  echo ""
done

echo "Done. Cache is populated via proxy at $PKG_CACHE_PROXY_URL."
