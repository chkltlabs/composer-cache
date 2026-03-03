# Local read-through package cache proxy

Single HTTP server that proxies **Composer (Packagist)**, **npm (registry.npmjs.org)**, and **Python (PyPI)** with a local read-through cache. On each request it tries the cache first; on miss or read error it fetches from upstream, stores the response, and returns it. PyPI HTML/JSON responses are rewritten so package file URLs point at the proxy (pip/Poetry then fetch wheels through the cache).

## Routing (per-project URLs)

| Registry | Project config | Proxy path | Upstream |
|----------|----------------|------------|----------|
| **Composer** | Repo URL in **global** Composer config (not in composer.json): `http://127.0.0.1:<port>/composer/` | `/composer/*` | `https://repo.packagist.org` |
| **npm** | Registry in **user** `.npmrc`: `http://127.0.0.1:<port>/` | `/`, `/package-name`, `/@scope/pkg`, `/-/package/name-version.tgz` | `https://registry.npmjs.org` |
| **PyPI** | pip: **user** `~/.config/pip/pip.conf`. Poetry: source in `pyproject.toml`: `http://127.0.0.1:<port>/pypi/simple/` | `/pypi/simple/*`, `/pypi/pypi/*`, `/pypi/files/*` | `https://pypi.org`, `https://files.pythonhosted.org` |

- **Composer:** `composer config --global repo.packagist composer http://127.0.0.1:4873/composer/` (global config; pkg-cache setup-project does this for you)
- **npm:** In user `~/.npmrc`: `registry=http://127.0.0.1:4873/` (pkg-cache setup-project does this for you)
- **Python (pip):** In user `~/.config/pip/pip.conf`: `index-url = http://127.0.0.1:4873/pypi/simple/` (pkg-cache setup-project does this for you)
- **Python (Poetry):** In `pyproject.toml`: `[[tool.poetry.source]]` with `url = "http://127.0.0.1:4873/pypi/simple/"` and `default = true`

## Configuration (env)

- `LOCAL_PACKAGE_CACHE_ROOT` – cache root directory (default: `~/.local-package-cache`). Composer under `composer/`, npm under `node/`, Python under `python/`.
- `PKG_CACHE_PROXY_PORT` – port to listen on (default: `4873`).
- `PKG_CACHE_PROXY_HOST` – bind address (default: `127.0.0.1`).

You can source `../scripts/config.sh` to set these before starting the server.

## How to run

```bash
# Optional: set port and cache root
source scripts/config.sh   # or export LOCAL_PACKAGE_CACHE_ROOT, PKG_CACHE_PROXY_PORT

node proxy/server.js
```

Or from repo root:

```bash
node proxy/server.js
```

The server listens on `http://127.0.0.1:4873` (or your port). Composer, npm, and PyPI requests are routed by path as above; cache is read-through with failover to upstream on miss or error.
