#!/usr/bin/env node
/**
 * Local read-through proxy for Composer (Packagist) and npm (registry.npmjs.org).
 *
 * ROUTING (for setup-project / per-project config):
 * - Composer: set repo URL to https://127.0.0.1:<port>/composer/
 *   → Requests to /composer/* are forwarded to https://repo.packagist.org (strip /composer prefix).
 * - npm: set registry to https://127.0.0.1:<port>/
 *   → All other paths (e.g. /lodash, /@scope/pkg, /-/package/pkg-1.0.0.tgz) go to https://registry.npmjs.org.
 *
 * Cache: LOCAL_PACKAGE_CACHE_ROOT (default ~/.local-package-cache)
 *   - cache/composer/ for Packagist responses
 *   - cache/node/ for npm responses
 * On cache miss or read error → fetch from upstream, store, return (failover).
 */

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const CACHE_ROOT = process.env.LOCAL_PACKAGE_CACHE_ROOT || path.join(process.env.HOME || '', '.local-package-cache');
const PORT = parseInt(process.env.PKG_CACHE_PROXY_PORT || '4873', 10);
const HOST = process.env.PKG_CACHE_PROXY_HOST || '127.0.0.1';

const COMPOSER_PREFIX = '/composer';
const COMPOSER_UPSTREAM = 'https://repo.packagist.org';
const NPM_UPSTREAM = 'https://registry.npmjs.org';

const COMPOSER_CACHE_DIR = path.join(CACHE_ROOT, 'composer');
const NPM_CACHE_DIR = path.join(CACHE_ROOT, 'node');

/**
 * Make a path+query safe for use as a filesystem path (single file).
 * Query string is appended as .query suffix (sanitized). Avoids path traversal.
 */
function safeCacheKey(urlPath, search) {
  const decoded = decodeURIComponent(urlPath);
  const safePath = decoded
    .replace(/^\/+/, '')
    .split('/')
    .map(seg => seg.replace(/[^a-zA-Z0-9._~-]/g, '_'))
    .filter(s => s && s !== '.' && s !== '..')
    .join(path.sep) || 'index';
  const base = path.normalize(safePath);
  const safe = path.isAbsolute(base) ? base.slice(1) : base;
  if (!search || search === '?') return safe;
  const q = search.slice(1).replace(/[^a-zA-Z0-9&=%._~-]/g, '_');
  return q ? `${safe}.q_${q}` : safe;
}

function ensureDir(dir) {
  try {
    fs.mkdirSync(dir, { recursive: true });
  } catch (e) {
    // ignore
  }
}

/**
 * Try to read from cache; return { hit: true, data, headers } or { hit: false }.
 */
function readFromCache(cacheDir, key, isBinary) {
  const filePath = path.join(cacheDir, key);
  try {
    const data = fs.readFileSync(filePath, isBinary ? undefined : 'utf8');
    const metaPath = filePath + '.meta.json';
    let headers = {};
    try {
      const raw = fs.readFileSync(metaPath, 'utf8');
      headers = JSON.parse(raw);
    } catch (_) {}
    return { hit: true, data, headers };
  } catch (e) {
    return { hit: false };
  }
}

/**
 * Write to cache and optional .meta.json for response headers we care about.
 */
function writeToCache(cacheDir, key, data, headers, isBinary) {
  ensureDir(path.dirname(path.join(cacheDir, key)));
  const filePath = path.join(cacheDir, key);
  try {
    fs.writeFileSync(filePath, data, isBinary ? undefined : 'utf8');
    const meta = {
      'content-type': headers['content-type'],
      'content-length': headers['content-length'],
    };
    fs.writeFileSync(filePath + '.meta.json', JSON.stringify(meta), 'utf8');
  } catch (e) {
    // best-effort; continue
  }
}

function fetchUpstream(url, isBinary, cb) {
  const u = new URL(url);
  const mod = u.protocol === 'https:' ? https : http;
  const opts = {
    hostname: u.hostname,
    port: u.port || (u.protocol === 'https:' ? 443 : 80),
    path: u.pathname + u.search,
    method: 'GET',
    headers: { 'User-Agent': 'pkg-cache-proxy/1.0' },
  };
  const req = mod.request(opts, (res) => {
    const chunks = [];
    res.on('data', (c) => chunks.push(c));
    res.on('end', () => {
      const data = Buffer.concat(chunks);
      const headers = {
        'content-type': res.headers['content-type'] || (isBinary ? 'application/octet-stream' : 'application/json'),
        'content-length': String(data.length),
      };
      cb(null, data, headers, res.statusCode);
    });
  });
  req.on('error', (err) => cb(err));
  req.end();
}

function serveFromCacheOrUpstream(res, cacheDir, key, upstreamUrl, isBinary, headOnly, onDone) {
  const send = (statusCode, data, headers) => {
    const ct = headers['content-type'] || (isBinary ? 'application/octet-stream' : 'application/json');
    const len = headers['content-length'] || (Buffer.isBuffer(data) ? data.length : Buffer.byteLength(data));
    res.setHeader('Content-Type', ct);
    res.setHeader('Content-Length', len);
    res.writeHead(statusCode);
    res.end(headOnly ? undefined : data);
    if (onDone) onDone();
  };

  const cached = readFromCache(cacheDir, key, isBinary);
  if (cached.hit) {
    send(200, cached.data, {
      'content-type': cached.headers['content-type'] || (isBinary ? 'application/octet-stream' : 'application/json'),
      'content-length': Buffer.isBuffer(cached.data) ? cached.data.length : Buffer.byteLength(cached.data),
    });
    return;
  }

  fetchUpstream(upstreamUrl, isBinary, (err, data, headers, statusCode) => {
    if (err) {
      res.writeHead(502, { 'Content-Type': 'text/plain' });
      res.end(headOnly ? undefined : 'Bad Gateway: ' + err.message);
      if (onDone) onDone();
      return;
    }
    writeToCache(cacheDir, key, data, headers, isBinary);
    send(statusCode || 200, data, headers);
  });
}

const server = http.createServer((req, res) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    res.end('Method Not Allowed');
    return;
  }

  const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  const pathname = url.pathname;
  const search = url.search || '';

  const headOnly = req.method === 'HEAD';

  // Health check: no upstream call, so setup self-check works offline
  if (pathname === '/health' || pathname === '/-/ping') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ok');
    return;
  }

  if (pathname.startsWith(COMPOSER_PREFIX + '/') || pathname === COMPOSER_PREFIX) {
    const upstreamPath = pathname === COMPOSER_PREFIX ? '/' : pathname.slice(COMPOSER_PREFIX.length) || '/';
    const upstreamUrl = COMPOSER_UPSTREAM + upstreamPath + search;
    const key = safeCacheKey(upstreamPath, search);
    serveFromCacheOrUpstream(res, COMPOSER_CACHE_DIR, key, upstreamUrl, false, headOnly, null);
    return;
  }

  // npm: everything else (/, /package-name, /@scope/pkg, /-/package/name-version.tgz)
  const npmPath = pathname === '' ? '/' : pathname;
  const npmUrl = NPM_UPSTREAM + npmPath + search;
  const npmKey = safeCacheKey(npmPath, search);
  const isTarball = npmPath.startsWith('/-/') && (npmPath.endsWith('.tgz') || npmPath.endsWith('.tar.gz'));
  serveFromCacheOrUpstream(res, NPM_CACHE_DIR, npmKey, npmUrl, isTarball, headOnly, null);
});

ensureDir(COMPOSER_CACHE_DIR);
ensureDir(NPM_CACHE_DIR);

server.listen(PORT, HOST, () => {
  console.error(`pkg-cache proxy listening on http://${HOST}:${PORT}`);
  console.error(`  Composer repo URL: http://${HOST}:${PORT}/composer/`);
  console.error(`  npm registry URL: http://${HOST}:${PORT}/`);
  console.error(`  Cache root: ${CACHE_ROOT}`);
});
