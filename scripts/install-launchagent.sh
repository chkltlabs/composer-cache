#!/usr/bin/env bash
# Install a macOS LaunchAgent so the pkg-cache proxy starts at login.
# Usage: install-launchagent.sh [install|uninstall]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.local.pkg-cache.proxy"
PLIST_PATH="$LAUNCH_AGENTS/${PLIST_LABEL}.plist"
NODE_PATH="$(command -v node 2>/dev/null || true)"
PROXY_SCRIPT="$REPO_ROOT/proxy/server.js"
LOG_FILE="${LOCAL_PACKAGE_CACHE_ROOT}/proxy-launchd.log"

action="${1:-install}"

case "$action" in
  uninstall)
    if launchctl list "$PLIST_LABEL" &>/dev/null; then
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
      echo "Unloaded $PLIST_LABEL"
    fi
    if [[ -f "$PLIST_PATH" ]]; then
      rm -f "$PLIST_PATH"
      echo "Removed $PLIST_PATH"
    fi
    echo "Proxy will no longer start at login."
    exit 0
    ;;
  install)
    ;;
  *)
    echo "Usage: $0 install | uninstall" >&2
    exit 1
    ;;
esac

if [[ -z "$NODE_PATH" ]]; then
  echo "Error: node not found in PATH. Install Node.js and ensure it is on your PATH (e.g. in .zshrc)." >&2
  exit 1
fi
if [[ ! -f "$PROXY_SCRIPT" ]]; then
  echo "Error: proxy not found at $PROXY_SCRIPT" >&2
  exit 1
fi

mkdir -p "$LAUNCH_AGENTS"
mkdir -p "$(dirname "$LOG_FILE")"

# Plist: run node proxy/server.js at login, with env and working dir
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_PATH}</string>
    <string>${PROXY_SCRIPT}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO_ROOT}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LOCAL_PACKAGE_CACHE_ROOT</key>
    <string>${LOCAL_PACKAGE_CACHE_ROOT}</string>
    <key>PKG_CACHE_PROXY_PORT</key>
    <string>${PKG_CACHE_PROXY_PORT}</string>
    <key>PKG_CACHE_PROXY_HOST</key>
    <string>${PKG_CACHE_PROXY_HOST}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
</dict>
</plist>
EOF

# Unload first if already loaded (so we pick up the new plist)
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Installed LaunchAgent: $PLIST_PATH"
echo "Proxy will start at login and is running now (if it was not already)."
echo "Log file: $LOG_FILE"
echo ""
echo "To stop and disable at login:  pkg-cache launchagent uninstall"
echo "To stop only for this session: launchctl unload $PLIST_PATH"
