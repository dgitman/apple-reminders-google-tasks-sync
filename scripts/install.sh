#!/bin/bash
# Build remtasks in release mode, install it to ~/.local/bin, ad-hoc sign it, and
# (optionally) install the launchd agent.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
# The real binary lives here under a readable name: macOS shows a bare executable's file name
# in Full Disk Access and Background Items. ~/.local/bin/remtasks is a symlink to it.
APP_NAME="${APP_NAME:-Apple Reminders & Google Tasks Sync}"
APP_DIR="$HOME/Library/Application Support/remtasks"
mkdir -p "$BIN_DIR" "$APP_DIR"

echo "Building..."
swift build -c release 2>&1 | tail -3
cp .build/release/remtasks "$APP_DIR/$APP_NAME"
# Prefer a stable signing identity (scripts/make-signing-identity.sh) so macOS permission
# grants survive rebuilds; fall back to an ad-hoc signature, which changes every build.
IDENTITY="${SIGNING_IDENTITY:-remtasks Code Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier net.gitman.remtasks --timestamp=none "$APP_DIR/$APP_NAME"
  echo "Signed with \"$IDENTITY\" (permission grants persist across rebuilds)."
else
  codesign --force --sign - --identifier net.gitman.remtasks "$APP_DIR/$APP_NAME"
  echo "Ad-hoc signed. Run scripts/make-signing-identity.sh once so Full Disk Access survives rebuilds."
fi
ln -sfn "$APP_DIR/$APP_NAME" "$BIN_DIR/remtasks"
echo "Installed \"$APP_DIR/$APP_NAME\" (command: $BIN_DIR/remtasks)"

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
