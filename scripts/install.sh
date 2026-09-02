#!/bin/bash
# Build remtasks in release mode, install it to ~/.local/bin, ad-hoc sign it, and
# (optionally) install the launchd agent.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

echo "Building..."
swift build -c release 2>&1 | tail -3
cp .build/release/remtasks "$BIN_DIR/remtasks"
# A stable ad-hoc signature keeps the Reminders permission grant attached to the binary.
codesign --force --sign - --identifier net.gitman.remtasks "$BIN_DIR/remtasks"
echo "Installed $BIN_DIR/remtasks"

CONFIG_DIR="$HOME/.config/remtasks"
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.json" ]; then
  cp config.example.json "$CONFIG_DIR/config.json"
  echo "Wrote $CONFIG_DIR/config.json from config.example.json — edit it before syncing."
fi

if [ "${1:-}" = "--agent" ]; then
  "$BIN_DIR/remtasks" install-agent --interval "${INTERVAL:-300}"
else
  echo "Next: put your Google OAuth client at $CONFIG_DIR/google-client.json, then run"
  echo "  $BIN_DIR/remtasks auth personal   (and again for each account)"
  echo "  $BIN_DIR/remtasks sync --dry-run"
  echo "  $BIN_DIR/remtasks install-agent"
fi
