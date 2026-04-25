#!/usr/bin/env bash
# Build AOS.app bundle from SwiftPM output.
#
# Per docs/plans/agents-md-notch-ui-crispy-horizon.md §B: build the AOSShell
# executable, lay out a standard .app skeleton, copy Info.plist, and bundle
# the Bun sidecar source under Contents/Resources/sidecar.
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# Per-developer signing identity. Set this to the SHA-1 of an Apple
# Development cert in your login keychain (run `security find-identity
# -v -p codesigning` to list). Other developers should override this
# with their own hash — either by editing here, or by exporting
# `AOS_CODESIGN_IDENTITY` in their shell (env var wins).
DEV_CODESIGN_IDENTITY="B518A963A5D23C8F55618D3600DD092F786D4239"
# ──────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

swift build -c debug --product AOSShell

mkdir -p AOS.app/Contents/MacOS AOS.app/Contents/Resources
cp .build/debug/AOSShell AOS.app/Contents/MacOS/AOS
cp Sources/AOSShellResources/Info.plist AOS.app/Contents/Info.plist
rm -rf AOS.app/Contents/Resources/sidecar
cp -R sidecar AOS.app/Contents/Resources/sidecar

# Sign with a stable identity so TCC grants (Screen Recording, Accessibility)
# survive rebuilds. The linker's default ad-hoc signature changes cdhash on
# every rebuild, silently invalidating prior grants while System Settings
# still shows the toggle as ON. Env `AOS_CODESIGN_IDENTITY` overrides the
# top-of-file default; either path must resolve to a cert in the keychain.
CODESIGN_IDENTITY="${AOS_CODESIGN_IDENTITY:-$DEV_CODESIGN_IDENTITY}"
if [ -z "$CODESIGN_IDENTITY" ]; then
  echo "error: no signing identity configured." >&2
  echo "  Run: security find-identity -v -p codesigning" >&2
  echo "  Then either edit DEV_CODESIGN_IDENTITY at the top of this script," >&2
  echo "  or export AOS_CODESIGN_IDENTITY=<sha1-hash> in your shell." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "$CODESIGN_IDENTITY"; then
  echo "error: signing identity $CODESIGN_IDENTITY not found in keychain." >&2
  echo "  Available identities:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi
codesign --force --deep --options runtime \
  --sign "$CODESIGN_IDENTITY" \
  --identifier com.aos.shell \
  AOS.app

echo "Built AOS.app at $REPO_ROOT/AOS.app"
