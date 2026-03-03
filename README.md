# Local Package Cache (pkg-cache)

Machine-wide local cache for **Composer** (Packagist), **Node/npm** (and pnpm), and **Python** (pip, pip-tools, Poetry) so you can run `composer install`, `npm install`, and `pip install` / `poetry install` offline after seeding the cache. Uses a local read-through proxy with automatic failover to upstream when the cache is missing or corrupted.

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

2. **Per project**: point the project at the local proxy (no env vars needed after this). Composer, npm, and pip use **global/user-level** config (composer.json, .npmrc, and project .pip are not modified), so the repo is never changed for those tools; only Poetry may add a source to `pyproject.toml`.

   ```bash
   pkg-cache setup-project /path/to/your/project
   # or from inside the project:
   pkg-cache setup-project
   ```

3. **Use as usual**: run `composer install`, `npm install` (or `pnpm install`), and for Python `pip install -r requirements.txt` or `poetry install` in the project. The proxy serves from cache or fetches from packagist, npm, or PyPI and caches the response.

4. **Optional – seed cache before going offline**:

   ```bash
   pkg-cache populate /path/to/project1 /path/to/project2
   ```

   Then you can work offline; the proxy serves from the local cache.

5. **Optional – run proxy at login (macOS):**

   ```bash
   pkg-cache launchagent install
   ```

   Installs a LaunchAgent so the proxy starts when you log in. Logs go to `~/.local-package-cache/proxy-launchd.log`. To disable: `pkg-cache launchagent uninstall`.

## Requirements

- **Composer** – [getcomposer.org](https://getcomposer.org/)
- **Node.js** and **npm** (or pnpm) – [nodejs.org](https://nodejs.org/) or nvm
- **Python** – for pip/Poetry projects: [python.org](https://www.python.org/), pip, and optionally [Poetry](https://python-poetry.org/) or pip-tools
- Bash (macOS/Linux)

## Configuration

| Env var | Default | Description |
|--------|---------|-------------|
| `LOCAL_PACKAGE_CACHE_ROOT` | `~/.local-package-cache` | Cache root (composer/, node/, python/ under it). |
| `PKG_CACHE_PROXY_PORT` | `4873` | Port the proxy listens on. |
| `PKG_CACHE_PROXY_HOST` | `127.0.0.1` | Bind address for the proxy. |

Source `scripts/config.sh` to set these, or export them before running `setup.sh` or the proxy.

## Commands

- **`pkg-cache setup`** – Run bootstrap (setup.sh): create cache root, check Composer/Node/npm, start proxy, self-check.
- **`pkg-cache setup-project [path]`** – Configure a project to use the local proxy. Composer, npm, and pip use **global/user-level** config (no project files modified for those); only Poetry may add a source to `pyproject.toml`. Default path is current directory.
- **`pkg-cache teardown-project [path]`** – Revert to online-only (no cache): unsets proxy config and restores from backups. Composer, npm, and pip configs are **global/user-level**, so teardown affects **all** projects on this machine for those tools; Poetry is reverted per-project. Default path is current directory.
- **`pkg-cache populate [paths...]`** – Run composer install, npm ci (or pnpm install), and pip/poetry install in the given projects so the proxy fills the cache. Projects must already use the proxy (run setup-project first). No paths = current directory.
- **`pkg-cache launchagent install`** – (macOS) Install a LaunchAgent so the proxy starts at login. Uses `scripts/config.sh` for port and cache root.
- **`pkg-cache launchagent uninstall`** – (macOS) Remove the LaunchAgent and stop the proxy from starting at login.
- **`pkg-cache status [--verbose]`** – Show cache summary: last update date, disk usage, and total packages cached, broken down per package manager (Composer, Node/npm, Python). With `--verbose`, list each cached package name and version.
- **`pkg-cache cleanup [--annihilate]`** – **Prune** (default): remove cached packages older than the newest version (keeps only the latest version per package for Node/npm and Python; Composer is not pruned). **`--annihilate`**: clear the entire cache (all three managers).

## Reverting to online-only (no cache)

Run **`pkg-cache teardown-project [path]`** (or `./scripts/unsetup-project.sh [path]`). This unsets the proxy for Composer/npm/pip/Poetry and restores from backups. **Composer, npm, and pip** use global/user config, so teardown affects **all** projects on this machine for those tools; Poetry is reverted per-project. Manual fallbacks: Composer: `composer config --global --unset repo.packagist`; npm: restore user `~/.npmrc` from `~/.npmrc.pkg-cache-backup`; pip: restore `~/.config/pip/pip.conf` from `pip.conf.pkg-cache-backup`; Poetry: restore `pyproject.toml` from `pyproject.toml.pkg-cache-backup` or remove the `[[tool.poetry.source]]` block for pkg-cache.

## Python (pip / Poetry)

After `pkg-cache setup-project`, pip uses the proxy via **user-level** config at `~/.config/pip/pip.conf` (index URL `http://127.0.0.1:<port>/pypi/simple/`); no project files are modified for pip. Poetry is configured with a `[[tool.poetry.source]]` entry in `pyproject.toml` so `poetry install` uses the proxy (Poetry remains per-project).

## Troubleshooting: "No packages cached" / "Last update never" (Composer)

The cache is only filled when installs go **through the proxy**. If `pkg-cache status` shows 0 Composer packages and "last update never", check:

1. **Composer is pointed at the proxy**  
   Run: `composer config -g repo.packagist`  
   It should show a URL like `http://127.0.0.1:4873/composer`. If it shows `https://repo.packagist.org` or "There is no packagist repository defined", run `pkg-cache setup-project` again in a Composer project. The setup script uses **jq** (if available) to write the global Composer config in a form Composer can display; without jq, installs may still use the proxy but `composer config -g repo.packagist` may not show it—install jq and re-run `pkg-cache setup-project` to fix.

2. **Proxy is running**  
   The proxy must be running when you run `composer install`. Start it with `pkg-cache setup` or `node proxy/server.js` (from the repo), or install the LaunchAgent: `pkg-cache launchagent install`.

3. **Composer "does not allow connections to http://..."**  
   The proxy URL is HTTP. Composer blocks non-HTTPS repos by default. `pkg-cache setup-project` sets global `secure-http: false` so Composer allows the proxy. If you configured the proxy manually, run `composer config --global secure-http false`.

5. **Same cache root everywhere**  
   The proxy and `pkg-cache status` both use `LOCAL_PACKAGE_CACHE_ROOT` (default `~/.local-package-cache`). If you start the proxy with a different env (e.g. from the repo with `LOCAL_PACKAGE_CACHE_ROOT=.local-package-cache`), then run status without that env, status will look at a different directory. Use the same value in both places or rely on the default.

After fixing the above, run `composer install` (or `composer update`) in a project that uses the proxy; then `pkg-cache status` should show Composer cache.

**Integration test:** Run `./scripts/test-composer-cache.sh` to start the proxy, configure Composer, run a minimal `composer update`, and verify the cache is populated. Use `--no-cleanup` to leave the test directory and proxy running for inspection.

## Failover

If the cache is corrupted or the proxy is down, the proxy **fails over to upstream** (packagist.org, registry.npmjs.org, pypi.org) so installs still work. If the proxy process is not running, run `./setup.sh` again to start it, start it manually (`node proxy/server.js`), or use `pkg-cache launchagent install` so it starts at login (macOS).

## Layout

- **docs/ARCHITECTURE.md** – Architecture and design.
- **scripts/config.sh** – Shared config (cache root, port, proxy URL).
- **setup.sh** – Bootstrap for a new machine.
- **proxy/server.js** – Read-through proxy (Composer, npm, PyPI).
- **bin/pkg-cache** – CLI entry (setup, setup-project, teardown-project, populate, launchagent, status, cleanup).
- **scripts/setup-project.sh** – Per-project proxy config.
- **scripts/unsetup-project.sh** – Revert project to online-only (teardown-project).
- **scripts/populate.sh** – Populate cache from project(s).
- **scripts/install-launchagent.sh** – macOS LaunchAgent install/uninstall (run proxy at login).
- **scripts/cache-status.sh**, **scripts/cache-status.js** – Cache status (summary and optional verbose package list).
- **scripts/cache-cleanup.sh**, **scripts/cache-cleanup.js** – Cache cleanup (prune old versions or annihilate).
- **scripts/test-composer-cache.sh** – Integration test: proxy + Composer config + composer update, then verify cache.
