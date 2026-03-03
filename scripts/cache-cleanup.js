#!/usr/bin/env node
/**
 * Cache cleanup: either remove packages older than the newest version (prune)
 * or clear the entire cache (--annihilate).
 * Uses same cache layout as proxy and cache-status.js.
 */

const fs = require('fs');
const path = require('path');

const CACHE_ROOT = process.env.LOCAL_PACKAGE_CACHE_ROOT || path.join(process.env.HOME || '', '.local-package-cache');
const COMPOSER_DIR = path.join(CACHE_ROOT, 'composer');
const NODE_DIR = path.join(CACHE_ROOT, 'node');
const PYTHON_DIR = path.join(CACHE_ROOT, 'python');

const annihilate = process.argv.includes('--annihilate');

function rmFile(filePath) {
  try {
    fs.unlinkSync(filePath);
    return true;
  } catch (e) {
    return false;
  }
}

function clearDir(dir) {
  if (!fs.existsSync(dir)) return { removed: 0 };
  let removed = 0;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      removed += clearDir(full);
      try {
        fs.rmdirSync(full);
        removed++;
      } catch (_) {}
    } else {
      if (rmFile(full)) removed++;
    }
  }
  return removed;
}

function annihilateAll() {
  let total = 0;
  for (const dir of [COMPOSER_DIR, NODE_DIR, PYTHON_DIR]) {
    if (fs.existsSync(dir)) {
      total += clearDir(dir);
    }
  }
  const cacheJson = path.join(CACHE_ROOT, 'cache.json');
  if (fs.existsSync(cacheJson)) {
    try {
      fs.writeFileSync(cacheJson, JSON.stringify({ lastPopulate: null, projects: [], lockfileHashes: {} }, null, 2), 'utf8');
      total++;
    } catch (_) {}
  }
  return total;
}

// Compare version strings (simplified semver: split by . and compare numerically)
function compareVersions(a, b) {
  if (!a || !b) return 0;
  const pa = a.split('.').map(function (x) { const n = parseInt(x, 10); return isNaN(n) ? 0 : n; });
  const pb = b.split('.').map(function (x) { const n = parseInt(x, 10); return isNaN(n) ? 0 : n; });
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const va = pa[i] || 0;
    const vb = pb[i] || 0;
    if (va !== vb) return va > vb ? 1 : -1;
  }
  return 0;
}

function pruneNode() {
  let removed = 0;
  if (!fs.existsSync(NODE_DIR)) return removed;
  // npm tarballs: path like package/-/package-version.tgz or @scope/pkg/-/pkg-version.tgz
  const byPkg = new Map(); // packageName -> [{ version, relPath, fullPath }]
  function walk(d, relPath) {
    const entries = fs.readdirSync(d, { withFileTypes: true });
    for (const e of entries) {
      const rel = relPath ? path.join(relPath, e.name) : e.name;
      const full = path.join(d, e.name);
      if (e.isDirectory()) {
        walk(full, rel);
      } else if (e.isFile() && (e.name.endsWith('.tgz') || e.name.endsWith('.tar.gz'))) {
        const sep = path.sep.replace(/\\/g, '\\\\');
        const match = rel.match(new RegExp('^(.+)' + sep + '-' + sep + '(.+?)\\.(tgz|tar\\.gz)$'));
        if (match) {
          const pkgName = match[1].split(path.sep).join('/');
          const base = match[2];
          const lastDash = base.lastIndexOf('-');
          const version = lastDash > 0 ? base.slice(lastDash + 1) : '';
          if (!byPkg.has(pkgName)) byPkg.set(pkgName, []);
          byPkg.get(pkgName).push({ version, rel, full });
        }
      }
    }
  }
  walk(NODE_DIR, '');
  byPkg.forEach(function (entries) {
    if (entries.length <= 1) return;
    entries.sort(function (a, b) { return -compareVersions(a.version, b.version); });
    const keep = entries[0];
    for (let i = 1; i < entries.length; i++) {
      const meta = path.join(entries[i].full + '.meta.json');
      if (rmFile(entries[i].full)) removed++;
      if (fs.existsSync(meta)) rmFile(meta);
    }
  });
  return removed;
}

function prunePython() {
  let removed = 0;
  if (!fs.existsSync(PYTHON_DIR)) return removed;
  const byPkg = new Map(); // packageName -> [{ version, fullPath }]
  function walk(d) {
    const entries = fs.readdirSync(d, { withFileTypes: true });
    for (const e of entries) {
      const full = path.join(d, e.name);
      if (e.isDirectory()) {
        walk(full);
      } else if (e.isFile()) {
        const match = e.name.match(/^(.+?)-(\d+[.\w-]*)\.(whl|tar\.gz|zip)$/);
        if (match) {
          const name = match[1].replace(/_/g, '-');
          const version = match[2];
          if (!byPkg.has(name)) byPkg.set(name, []);
          byPkg.get(name).push({ version, full });
        }
      }
    }
  }
  walk(PYTHON_DIR);
  byPkg.forEach(function (entries) {
    if (entries.length <= 1) return;
    entries.sort(function (a, b) { return -compareVersions(a.version, b.version); });
    for (let i = 1; i < entries.length; i++) {
      const meta = entries[i].full + '.meta.json';
      if (rmFile(entries[i].full)) removed++;
      if (fs.existsSync(meta)) rmFile(meta);
    }
  });
  return removed;
}

function prune() {
  const nodeRemoved = pruneNode();
  const pythonRemoved = prunePython();
  return { node: nodeRemoved, python: pythonRemoved, total: nodeRemoved + pythonRemoved };
}

if (annihilate) {
  const total = annihilateAll();
  console.log(JSON.stringify({ mode: 'annihilate', removed: total }));
} else {
  const result = prune();
  console.log(JSON.stringify({ mode: 'prune', ...result }));
}
