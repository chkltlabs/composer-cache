# Shared config for pkg-cache (local package cache)
# Source this or use from scripts. Defaults can be overridden by env.

export LOCAL_PACKAGE_CACHE_ROOT="${LOCAL_PACKAGE_CACHE_ROOT:-$HOME/.local-package-cache}"
export PKG_CACHE_PROXY_PORT="${PKG_CACHE_PROXY_PORT:-4873}"
export PKG_CACHE_PROXY_HOST="${PKG_CACHE_PROXY_HOST:-127.0.0.1}"

# Proxy base URL (no trailing slash for npm registry compatibility)
export PKG_CACHE_PROXY_URL="http://${PKG_CACHE_PROXY_HOST}:${PKG_CACHE_PROXY_PORT}"
