#!/usr/bin/env bash
# Print cache status: last update, disk usage, package counts per manager.
# Usage: cache-status.sh [--verbose]
# With --verbose, lists each cached package name and version.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

VERBOSE=false
for arg in "$@"; do
  if [[ "$arg" == "--verbose" || "$arg" == "-v" ]]; then
    VERBOSE=true
    break
  fi
done

export LOCAL_PACKAGE_CACHE_ROOT
# Probe proxy (same URL the proxy serves health on)
PROXY_RUNNING=false
if command -v curl &>/dev/null; then
  if curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 3 "${PKG_CACHE_PROXY_URL}/health" 2>/dev/null | grep -q '^200$'; then
    PROXY_RUNNING=true
  fi
elif command -v wget &>/dev/null; then
  if wget -q -O /dev/null --timeout=3 "${PKG_CACHE_PROXY_URL}/health" 2>/dev/null; then
    PROXY_RUNNING=true
  fi
fi
export PKG_CACHE_PROXY_URL
export PROXY_RUNNING

JSON="$("$SCRIPT_DIR/cache-status.js")"

if [[ -z "$JSON" ]]; then
  echo "Failed to read cache status." >&2
  exit 1
fi

export VERBOSE_ARG="$VERBOSE"
echo "$JSON" | node -e "
  var d = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
  var verbose = process.env.VERBOSE_ARG === 'true';
  var proxyUrl = process.env.PKG_CACHE_PROXY_URL || 'http://127.0.0.1:4873';
  var proxyRunning = process.env.PROXY_RUNNING === 'true';

  function formatBytes(n) {
    if (!n || n <= 0) return '0 B';
    if (n < 1024) return n + ' B';
    if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
    if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
    return (n / 1073741824).toFixed(1) + ' GB';
  }
  function formatDate(iso) {
    if (!iso || iso === 'null') return 'never';
    try {
      var dt = new Date(iso);
      return dt.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric', hour: '2-digit', minute: '2-digit' });
    } catch (e) { return iso; }
  }

  console.log('Proxy: ' + (proxyRunning ? 'running at ' + proxyUrl : 'not running (expected at ' + proxyUrl + ')'));
  console.log('Cache root: ' + d.cacheRoot);
  console.log('Last update: ' + formatDate(d.lastUpdate));
  console.log('Disk usage: ' + formatBytes(d.totalBytes));
  console.log('Total packages: ' + (d.totalPackages || 0));
  console.log('');
  console.log('Per package manager:');
  var by = d.byManager || {};
  ['composer','node','python'].forEach(function(m) {
    var s = by[m];
    if (!s) return;
    console.log('  ' + s.label + ': ' + formatBytes(s.bytes) + ', ' + (s.packageCount || 0) + ' packages, last update ' + formatDate(s.lastUpdate));
  });
  if (!proxyRunning) {
    console.log('');
    console.log('Tip: Start the proxy with: pkg-cache setup  or  node proxy/server.js');
  }
  if (verbose) {
    console.log('');
    console.log('Cached packages (name @ version):');
    ['composer','node','python'].forEach(function(m) {
      var s = by[m];
      if (!s || !s.packages || !s.packages.length) return;
      console.log('');
      console.log('  ' + s.label + ':');
      s.packages.forEach(function(p) {
        var v = (p.version ? ' @ ' + p.version : '');
        console.log('    ' + p.name + v);
      });
    });
  }
  if (by.composer && by.composer.packageCount === 0 && by.composer.bytes === 0) {
    console.log('');
    console.log('Tip: Composer cache stays empty until Composer uses the proxy. Run:');
    console.log('  pkg-cache setup-project <path>   # in each repo that uses Composer');
    console.log('  (ensure proxy is running: pkg-cache setup or node proxy/server.js)');
    console.log('  composer config -g repo.packagist   # should show your proxy URL');
  }
"
