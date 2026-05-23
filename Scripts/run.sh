#!/usr/bin/env bash
# Build the dev Notch Agent bundle and launch it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEV_APP_NAME="notch-agent-dev"
DEV_BUNDLE_PATH="$REPO_ROOT/${DEV_APP_NAME}.app"
DEV_BUNDLE_ID="com.notch-agent.shell.dev"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

NOTCH_APP_BUNDLE_PATH="$DEV_BUNDLE_PATH" \
NOTCH_APP_NAME="$DEV_APP_NAME" \
NOTCH_APP_EXECUTABLE="$DEV_APP_NAME" \
NOTCH_BUNDLE_ID="$DEV_BUNDLE_ID" \
./Scripts/build-app.sh

# `open "$DEV_BUNDLE_PATH"` reuses an already-running LSUIElement process. For dev
# runs we need a real relaunch so rebuilt Swift code and Info.plist changes
# are loaded before testing OS Sense / TCC behavior.
pkill -x "$DEV_APP_NAME" 2>/dev/null || true
for _ in {1..20}; do
  if ! pgrep -x "$DEV_APP_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

"$LSREGISTER" -f "$DEV_BUNDLE_PATH"
open "$DEV_BUNDLE_PATH"
