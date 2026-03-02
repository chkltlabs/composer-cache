# Local read-through package cache proxy

Single HTTP server that proxies **Composer (Packagist)** and **npm (registry.npmjs.org)** with a local read-through cache. On each request it tries the cache first; on miss or read error it fetches from upstream, stores the response, and returns it.

## Routing (per-project URLs)

| Registry | Project config | Proxy path | Upstream |
|----------|----------------|------------|----------|
| **Composer** | Repo URL: `http://127.0.0.1:<port>/composer/` | `/composer/*` | `https://repo.packagist.org` |
| **npm** | Registry: `http://127.0.0.1:<port>/` | `/`, `/package-name`, `/@scope/pkg`, `/-/package/name-version.tgz` | `https://registry.npmjs.org` |

- **Composer:** Configure the Packagist repo to point at the proxy with the `/composer/` path, e.g.  
  `composer config repo.packagist composer http://127.0.0.1:4873/composer/`
- **npm:** Set registry to the proxy root, e.g. in `.npmrc`:  
  `registry=http://127.0.0.1:4873/`

## Configuration (env)

- `LOCAL_PACKAGE_CACHE_ROOT` – cache root directory (default: `~/.local-package-cache`). Composer data under `composer/`, npm under `node/`.
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

The server listens on `http://127.0.0.1:4873` (or your port). Composer and npm requests are routed by path as above; cache is read-through with failover to upstream on miss or error.
