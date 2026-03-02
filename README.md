# Local Package Cache (pkg-cache)

Machine-wide local cache for **Composer** (Packagist) and **Node/npm** (and pnpm) so you can run `composer install` and `npm install` offline after seeding the cache. Uses a local read-through proxy with automatic failover to upstream when the cache is missing or corrupted.

## Quick start (new machine)

1. **One-time bootstrap** (creates cache layout, starts proxy, checks deps):

   ```bash
   cd /path/to/composer-cache
   ./setup.sh
   ```

   Or via the CLI:

   ```bash
   export PATH="/path/to/composer-cache/bin:$PATH"
   pkg-cache setup
   ```

2. **Per project**: point the project at the local proxy (no env vars needed after this):

   ```bash
   pkg-cache setup-project /path/to/your/project
   # or from inside the project:
   pkg-cache setup-project
   ```

3. **Use as usual**: run `composer install` and `npm install` (or `pnpm install`) in the project. The proxy serves from cache or fetches from packagist/npm and caches the response.

4. **Optional – seed cache before going offline**:

   ```bash
   pkg-cache populate /path/to/project1 /path/to/project2
   ```

   Then you can work offline; the proxy serves from the local cache.

## Requirements

- **Composer** – [getcomposer.org](https://getcomposer.org/)
- **Node.js** and **npm** (or pnpm) – [nodejs.org](https://nodejs.org/) or nvm
- Bash (macOS/Linux)

## Configuration

| Env var | Default | Description |
|--------|---------|-------------|
| `LOCAL_PACKAGE_CACHE_ROOT` | `~/.local-package-cache` | Cache root (composer/ and node/ under it). |
| `PKG_CACHE_PROXY_PORT` | `4873` | Port the proxy listens on. |
| `PKG_CACHE_PROXY_HOST` | `127.0.0.1` | Bind address for the proxy. |

Source `scripts/config.sh` to set these, or export them before running `setup.sh` or the proxy.

## Commands

- **`pkg-cache setup`** – Run bootstrap (setup.sh): create cache root, check Composer/Node/npm, start proxy, self-check.
- **`pkg-cache setup-project [path]`** – Configure a project to use the local proxy (Composer repo + .npmrc). Default path is current directory.
- **`pkg-cache populate [paths...]`** – Run composer install / npm ci (or pnpm install) in the given projects so the proxy fills the cache. Projects must already use the proxy (run setup-project first). No paths = current directory.

## Reverting per-project config

- **Composer:** `composer config --unset repo.packagist` in the project. Restore from `composer.json.pkg-cache-backup` if you backed up.
- **npm:** Restore `.npmrc` from `.npmrc.pkg-cache-backup`, or remove the `registry=` line.

## Failover

If the cache is corrupted or the proxy is down, the proxy **fails over to upstream** (packagist.org, registry.npmjs.org) so installs still work. If the proxy process is not running, run `./setup.sh` again to start it, or start it manually: `node proxy/server.js`.

## Layout

- **docs/ARCHITECTURE.md** – Architecture and design.
- **scripts/config.sh** – Shared config (cache root, port, proxy URL).
- **setup.sh** – Bootstrap for a new machine.
- **proxy/server.js** – Read-through proxy (Composer + npm).
- **bin/pkg-cache** – CLI entry (setup, setup-project, populate).
- **scripts/setup-project.sh** – Per-project proxy config.
- **scripts/populate.sh** – Populate cache from project(s).
