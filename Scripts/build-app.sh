#!/usr/bin/env bash
# Build AOS.app bundle from SwiftPM output.
#
# Per docs/plans/agents-md-notch-ui-crispy-horizon.md §B: build the AOSShell
# executable, lay out a standard .app skeleton, copy Info.plist, and bundle
# the Bun sidecar source under Contents/Resources/sidecar.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

swift build -c debug --product AOSShell

mkdir -p AOS.app/Contents/MacOS AOS.app/Contents/Resources
cp .build/debug/AOSShell AOS.app/Contents/MacOS/AOS
cp Sources/AOSShellResources/Info.plist AOS.app/Contents/Info.plist
rm -rf AOS.app/Contents/Resources/sidecar
cp -R sidecar AOS.app/Contents/Resources/sidecar

echo "Built AOS.app at $REPO_ROOT/AOS.app"
