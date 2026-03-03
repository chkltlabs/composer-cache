#!/usr/bin/env node
/**
 * Compute cache status: size, last update, package counts, and optional verbose package list.
 * Reads LOCAL_PACKAGE_CACHE_ROOT (same as proxy). Outputs JSON to stdout.
 */

const fs = require('fs');
const path = require('path');

const CACHE_ROOT = process.env.LOCAL_PACKAGE_CACHE_ROOT || path.join(process.env.HOME || '', '.local-package-cache');
const COMPOSER_DIR = path.join(CACHE_ROOT, 'composer');
const NODE_DIR = path.join(CACHE_ROOT, 'node');
const PYTHON_DIR = path.join(CACHE_ROOT, 'python');

function safeWalk(dir, acc, prefix = '') {
  if (!fs.existsSync(dir)) return;
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const e of entries) {
      const rel = prefix ? path.join(prefix, e.name) : e.name;
      const full = path.join(dir, rel);
      if (e.isDirectory()) {
        safeWalk(full, acc, rel);
      } else if (e.isFile() && !e.name.endsWith('.meta.json')) {
        acc.files.push(rel);
        try {
          const st = fs.statSync(full);
          acc.bytes += st.size;
          if (st.mtimeMs > acc.mtimeMs) acc.mtimeMs = st.mtimeMs;
        } catch (_) {}
      }
    }
  } catch (_) {}
}

function composerPackages(dir) {
  const packages = [];
  if (!fs.existsSync(dir)) return packages;
  const p2 = path.join(dir, 'p2');
  if (!fs.existsSync(p2)) return packages;
  // Proxy stores p2 metadata at p2/vendor/package.json (nested). Walk recursively.
  function walk(innerDir, relPath) {
    const entries = fs.readdirSync(innerDir, { withFileTypes: true });
    for (const e of entries) {
      const rel = relPath ? path.join(relPath, e.name) : e.name;
      const full = path.join(innerDir, e.name);
      if (e.isDirectory()) {
        walk(full, rel);
      } else if (e.isFile() && e.name.endsWith('.json') && !e.name.endsWith('.meta.json')) {
        // rel is e.g. "ramsey/collection.json" -> name "ramsey/collection"
        const name = rel.replace(/\.json$/, '').replace(/\\/g, '/');
        // Only count vendor/package paths (exclude p2/list.json etc.)
        if (name.indexOf('/') !== -1) {
          let version = null;
          try {
            const raw = fs.readFileSync(full, 'utf8');
            const data = JSON.parse(raw);
            if (data && data.packages && data.packages[name]) {
              const versions = Object.keys(data.packages[name]);
              if (versions.length) version = versions[versions.length - 1];
            }
          } catch (_) {}
          packages.push({ name, version });
        }
      }
    }
  }
  try {
    walk(p2, '');
  } catch (_) {}
  return packages;
}

function nodePackages(dir) {
  const packages = [];
  if (!fs.existsSync(dir)) return packages;
  // npm tarball paths: package/-/package-version.tgz or @scope/pkg/-/pkg-version.tgz
  function walk(d, relPath) {
    const entries = fs.readdirSync(d, { withFileTypes: true });
    for (const e of entries) {
      const rel = relPath ? path.join(relPath, e.name) : e.name;
      const full = path.join(d, e.name);
      if (e.isDirectory()) {
        walk(full, rel);
      } else if (e.isFile() && (e.name.endsWith('.tgz') || e.name.endsWith('.tar.gz'))) {
        const sep = path.sep.replace(/\\/g, '\\\\');
        const match = rel.match(new RegExp(`^(.+)${sep}-${sep}(.+?)\\.(tgz|tar\\.gz)$`));
        if (match) {
          let pkgName = match[1].split(path.sep).join('/');
          if (pkgName.indexOf('/') > 0 && pkgName[0] === '_') pkgName = '@' + pkgName.slice(1);
          const base = match[2];
          const lastDash = base.lastIndexOf('-');
          const version = lastDash > 0 ? base.slice(lastDash + 1) : null;
          packages.push({ name: pkgName, version });
        }
      }
    }
  }
  try {
    walk(dir, '');
  } catch (_) {}
  return packages;
}

function pythonPackages(dir) {
  const byName = new Map();
  if (!fs.existsSync(dir)) return Array.from(byName.values());
  const simple = path.join(dir, 'simple');
  const pypi = path.join(dir, 'pypi');
  function add(name, version) {
    if (!byName.has(name)) byName.set(name, { name, version });
    else if (version && (!byName.get(name).version || version > byName.get(name).version))
      byName.set(name, { name, version });
  }
  try {
    if (fs.existsSync(simple)) {
      const names = fs.readdirSync(simple, { withFileTypes: true });
      for (const n of names) {
        if (n.isDirectory()) add(n.name, null);
      }
    }
  } catch (_) {}
  try {
    if (fs.existsSync(pypi)) {
      const names = fs.readdirSync(pypi, { withFileTypes: true });
      for (const n of names) {
        if (n.isDirectory()) {
          const jsonPath = path.join(pypi, n.name, 'json');
          if (fs.existsSync(jsonPath)) {
            try {
              const raw = fs.readFileSync(jsonPath, 'utf8');
              const data = JSON.parse(raw);
              let version = null;
              if (data && data.info && data.info.version) version = data.info.version;
              add(n.name, version);
            } catch (_) {
              add(n.name, null);
            }
          } else {
            add(n.name, null);
          }
        }
      }
    }
  } catch (_) {}
  // Also infer from dist-like filenames under python/ (files from files.pythonhosted.org)
  function walkForDist(d, basePath) {
    const entries = fs.readdirSync(d, { withFileTypes: true });
    for (const e of entries) {
      const rel = path.join(basePath, e.name);
      if (e.isDirectory()) walkForDist(path.join(d, e.name), rel);
      else if (e.isFile()) {
        const match = e.name.match(/^(.+?)-(\d+[.\w-]*)\.(whl|tar\.gz|zip)$/);
        if (match) {
          const name = match[1].replace(/_/g, '-');
          const version = match[2];
          add(name, version);
        }
      }
    }
  }
  try {
    walkForDist(dir, '');
  } catch (_) {}
  return Array.from(byName.values());
}

function statsForDir(dir, label, getPackages) {
  const acc = { files: [], bytes: 0, mtimeMs: 0 };
  safeWalk(dir, acc);
  const packages = getPackages ? getPackages(dir) : [];
  return {
    label,
    bytes: acc.bytes,
    fileCount: acc.files.length,
    packageCount: packages.length,
    lastUpdate: acc.mtimeMs ? new Date(acc.mtimeMs).toISOString() : null,
    packages,
  };
}

const composer = statsForDir(COMPOSER_DIR, 'Composer', composerPackages);
const node = statsForDir(NODE_DIR, 'Node/npm', nodePackages);
const python = statsForDir(PYTHON_DIR, 'Python', pythonPackages);

const totalBytes = composer.bytes + node.bytes + python.bytes;
let overallMtime = 0;
for (const s of [composer, node, python]) {
  if (s.lastUpdate) {
    const t = new Date(s.lastUpdate).getTime();
    if (t > overallMtime) overallMtime = t;
  }
}

const result = {
  cacheRoot: CACHE_ROOT,
  totalBytes,
  totalPackages: composer.packageCount + node.packageCount + python.packageCount,
  lastUpdate: overallMtime ? new Date(overallMtime).toISOString() : null,
  byManager: { composer, node, python },
};
console.log(JSON.stringify(result, null, 0));
