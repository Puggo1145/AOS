#!/usr/bin/env bash
# Build the AOS.app bundle and launch it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

./Scripts/build-app.sh

# `open AOS.app` reuses an already-running LSUIElement process. For dev
# runs we need a real relaunch so rebuilt Swift code and Info.plist changes
# are loaded before testing OS Sense / TCC behavior.
pkill -x AOS 2>/dev/null || true
for _ in {1..20}; do
  if ! pgrep -x AOS >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

open AOS.app
