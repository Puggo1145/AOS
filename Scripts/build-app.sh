#!/usr/bin/env bash
# Build Notch Agent.app bundle from SwiftPM output.
#
# Per docs/plans/agents-md-notch-ui-crispy-horizon.md §B: build the Shell
# executable, lay out a standard .app skeleton, copy Info.plist, and bundle
# the Bun sidecar (source + bun binary + dependencies) under
# Contents/Resources/sidecar.
#
# Output: Notch Agent.app at the repo root. Bundle is signed with hardened runtime
# + entitlements that allow Bun's JIT to run.
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# Per-developer signing identity. Set this to the SHA-1 of an Apple
# Development cert in your login keychain (run `security find-identity
# -v -p codesigning` to list). Other developers should override this
# with their own hash — either by editing here, or by exporting
# `NOTCH_CODESIGN_IDENTITY` in their shell (env var wins).
DEV_CODESIGN_IDENTITY="B518A963A5D23C8F55618D3600DD092F786D4239"
# ──────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
APP_BUNDLE="Notch Agent.app"
APP_EXECUTABLE="Notch Agent"

BUILD_CONFIG="${NOTCH_BUILD_CONFIG:-debug}"
BUILD_DIR="$(swift build -c "$BUILD_CONFIG" --show-bin-path)"
swift build -c "$BUILD_CONFIG" --product Shell

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR"/Shell "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"
find "$BUILD_DIR" -maxdepth 1 -type d -name '*.bundle' -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;

# ----- Info.plist (with version injection) ------------------------------
# Single source of truth for the app version is sidecar/package.json so
# Shell + Sidecar always report the same MAJOR.MINOR.PATCH. CFBundleVersion
# (build number) is the abbreviated git rev so a rebuild from the same
# source tree produces an identical bundle, but a code change bumps the
# build number — TCC keys off cdhash, not version, so this is purely for
# diagnostic legibility.
cp Sources/ShellResources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Sources/ShellResources/NotchAgent.icns "$APP_BUNDLE/Contents/Resources/NotchAgent.icns"
APP_VERSION="$(node -e "console.log(require('./sidecar/package.json').version)" 2>/dev/null \
  || python3 -c "import json; print(json.load(open('sidecar/package.json'))['version'])" 2>/dev/null \
  || echo "0.0.0")"
BUILD_NUMBER="$(git rev-parse --short HEAD 2>/dev/null || echo "0")"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"

# ----- Sidecar source ---------------------------------------------------
rm -rf "$APP_BUNDLE/Contents/Resources/sidecar"
mkdir -p "$APP_BUNDLE/Contents/Resources/sidecar"
cp -R sidecar/src "$APP_BUNDLE/Contents/Resources/sidecar/src"
cp sidecar/package.json "$APP_BUNDLE/Contents/Resources/sidecar/package.json"
# Lockfile is the source of truth. Bun 1.1+ writes text-format
# `bun.lock`; older binary `bun.lockb` is supported for legacy checkouts.
# Either form is honoured; the install step below requires at least one.
if [ -f sidecar/bun.lock ]; then
  cp sidecar/bun.lock "$APP_BUNDLE/Contents/Resources/sidecar/bun.lock"
fi
if [ -f sidecar/bun.lockb ]; then
  cp sidecar/bun.lockb "$APP_BUNDLE/Contents/Resources/sidecar/bun.lockb"
fi
if [ -f sidecar/tsconfig.json ]; then
  cp sidecar/tsconfig.json "$APP_BUNDLE/Contents/Resources/sidecar/tsconfig.json"
fi

# ----- Sidecar dependencies (frozen) ------------------------------------
# Resolve a bun binary up front. This same binary is reused for `bun
# install` below and bundled into the .app for runtime.
HOST_BUN="$(command -v bun 2>/dev/null || true)"
if [ -z "$HOST_BUN" ]; then
  for c in /opt/homebrew/bin/bun /usr/local/bin/bun; do
    if [ -x "$c" ]; then HOST_BUN="$c"; break; fi
  done
fi
if [ -z "$HOST_BUN" ]; then
  echo "error: 'bun' binary not found on this host." >&2
  echo "  Install with: brew install oven-sh/bun/bun" >&2
  exit 1
fi

# Frozen install: lockfile is the source of truth, no resolution drift
# at build time. We REQUIRE a lockfile here — packaging a release with
# floating dependency versions silently breaks supply-chain reproducibility
# (the prior fallback to `bun install --production` would hit the network
# at build time and resolve different versions per build host). Bun 1.1+
# writes `bun.lock`; older checkouts may still carry `bun.lockb`. Either
# form satisfies the gate.
pushd "$APP_BUNDLE/Contents/Resources/sidecar" > /dev/null
if [ -f bun.lock ] || [ -f bun.lockb ]; then
  "$HOST_BUN" install --frozen-lockfile --production
else
  echo "error: no bun.lock or bun.lockb in sidecar/ — refusing to package" >&2
  echo "  Generate one with: (cd sidecar && bun install)" >&2
  popd > /dev/null
  exit 1
fi
popd > /dev/null

# ----- Bundle the bun binary --------------------------------------------
# Self-contained .app: ship the bun binary alongside the sidecar so the
# end user doesn't need Homebrew. SidecarProcess.resolveBunBinary checks
# Resources/sidecar/bin/bun first.
mkdir -p "$APP_BUNDLE/Contents/Resources/sidecar/bin"
cp "$HOST_BUN" "$APP_BUNDLE/Contents/Resources/sidecar/bin/bun"
chmod +x "$APP_BUNDLE/Contents/Resources/sidecar/bin/bun"

# ----- Codesign ---------------------------------------------------------
# Sign with a stable identity so TCC grants (Screen Recording, Accessibility)
# survive rebuilds. The linker's default ad-hoc signature changes cdhash on
# every rebuild, silently invalidating prior grants while System Settings
# still shows the toggle as ON. Env `NOTCH_CODESIGN_IDENTITY` overrides the
# top-of-file default; either path must resolve to a cert in the keychain.
CODESIGN_IDENTITY="${NOTCH_CODESIGN_IDENTITY:-$DEV_CODESIGN_IDENTITY}"
if [ -z "$CODESIGN_IDENTITY" ]; then
  echo "error: no signing identity configured." >&2
  echo "  Run: security find-identity -v -p codesigning" >&2
  echo "  Then either edit DEV_CODESIGN_IDENTITY at the top of this script," >&2
  echo "  or export NOTCH_CODESIGN_IDENTITY=<sha1-hash> in your shell." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "$CODESIGN_IDENTITY"; then
  echo "error: signing identity $CODESIGN_IDENTITY not found in keychain." >&2
  echo "  Available identities:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

ENTITLEMENTS="$REPO_ROOT/Sources/ShellResources/NotchAgent.entitlements"

# Sign the bundled bun binary first. `--deep` on the outer codesign would
# re-sign nested executables but with the outer entitlements file, which
# is what we want here — but signing inner binaries explicitly first
# guarantees the ordering is right (notarisation requires nested signing
# in dependency order).
codesign --force --options runtime \
  --sign "$CODESIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$APP_BUNDLE/Contents/Resources/sidecar/bin/bun"

# Outer bundle.
codesign --force --options runtime \
  --sign "$CODESIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --identifier com.notch-agent.shell \
  "$APP_BUNDLE"

echo "Built $APP_BUNDLE at $REPO_ROOT/$APP_BUNDLE (version $APP_VERSION build $BUILD_NUMBER)"
