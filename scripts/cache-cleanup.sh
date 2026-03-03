#!/usr/bin/env bash
# Clean the package cache: remove older package versions (keep newest per package)
# or clear the entire cache with --annihilate.
# Usage: cache-cleanup.sh [--annihilate]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

export LOCAL_PACKAGE_CACHE_ROOT

if [[ "$1" == "--annihilate" ]]; then
  OUT="$("$SCRIPT_DIR/cache-cleanup.js" --annihilate)"
  if [[ -n "$OUT" ]]; then
    echo "$OUT" | node -e "
      var d = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
      console.log('Cache cleared (' + d.removed + ' items removed).');
    "
  else
    echo "Cache cleared." 
  fi
else
  OUT="$("$SCRIPT_DIR/cache-cleanup.js")"
  if [[ -n "$OUT" ]]; then
    echo "$OUT" | node -e "
      var d = JSON.parse(require('fs').readFileSync('/dev/stdin', 'utf8'));
      if (d.mode === 'prune') {
        console.log('Pruned older package versions:');
        console.log('  Node/npm: ' + (d.node || 0) + ' tarball(s) removed');
        console.log('  Python:   ' + (d.python || 0) + ' dist file(s) removed');
        console.log('  Composer: (prune not supported; use --annihilate to clear)');
        console.log('  Total:    ' + (d.total || 0) + ' file(s) removed');
      }
    "
  else
    echo "Prune complete (no older versions to remove)."
  fi
fi
