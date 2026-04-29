#!/usr/bin/env bash
# Build AOS.app bundle from SwiftPM output.
#
# Per docs/plans/agents-md-notch-ui-crispy-horizon.md §B: build the AOSShell
# executable, lay out a standard .app skeleton, copy Info.plist, and bundle
# the Bun sidecar (source + bun binary + dependencies) under
# Contents/Resources/sidecar.
#
# Output: AOS.app at the repo root. Bundle is signed with hardened runtime
# + entitlements that allow Bun's JIT to run.
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

BUILD_CONFIG="${AOS_BUILD_CONFIG:-debug}"
swift build -c "$BUILD_CONFIG" --product AOSShell

mkdir -p AOS.app/Contents/MacOS AOS.app/Contents/Resources
cp .build/"$BUILD_CONFIG"/AOSShell AOS.app/Contents/MacOS/AOS

# ----- Info.plist (with version injection) ------------------------------
# Single source of truth for the app version is sidecar/package.json so
# Shell + Sidecar always report the same MAJOR.MINOR.PATCH. CFBundleVersion
# (build number) is the abbreviated git rev so a rebuild from the same
# source tree produces an identical bundle, but a code change bumps the
# build number — TCC keys off cdhash, not version, so this is purely for
# diagnostic legibility.
cp Sources/AOSShellResources/Info.plist AOS.app/Contents/Info.plist
APP_VERSION="$(node -e "console.log(require('./sidecar/package.json').version)" 2>/dev/null \
  || python3 -c "import json; print(json.load(open('sidecar/package.json'))['version'])" 2>/dev/null \
  || echo "0.0.0")"
BUILD_NUMBER="$(git rev-parse --short HEAD 2>/dev/null || echo "0")"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" AOS.app/Contents/Info.plist
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" AOS.app/Contents/Info.plist

# ----- Sidecar source ---------------------------------------------------
rm -rf AOS.app/Contents/Resources/sidecar
mkdir -p AOS.app/Contents/Resources/sidecar
cp -R sidecar/src AOS.app/Contents/Resources/sidecar/src
cp sidecar/package.json AOS.app/Contents/Resources/sidecar/package.json
# Lockfile is the source of truth. Bun 1.1+ writes text-format
# `bun.lock`; older binary `bun.lockb` is supported for legacy checkouts.
# Either form is honoured; the install step below requires at least one.
if [ -f sidecar/bun.lock ]; then
  cp sidecar/bun.lock AOS.app/Contents/Resources/sidecar/bun.lock
fi
if [ -f sidecar/bun.lockb ]; then
  cp sidecar/bun.lockb AOS.app/Contents/Resources/sidecar/bun.lockb
fi
if [ -f sidecar/tsconfig.json ]; then
  cp sidecar/tsconfig.json AOS.app/Contents/Resources/sidecar/tsconfig.json
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
pushd AOS.app/Contents/Resources/sidecar > /dev/null
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
mkdir -p AOS.app/Contents/Resources/sidecar/bin
cp "$HOST_BUN" AOS.app/Contents/Resources/sidecar/bin/bun
chmod +x AOS.app/Contents/Resources/sidecar/bin/bun

# ----- Codesign ---------------------------------------------------------
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

ENTITLEMENTS="$REPO_ROOT/Sources/AOSShellResources/AOS.entitlements"

# Sign the bundled bun binary first. `--deep` on the outer codesign would
# re-sign nested executables but with the outer entitlements file, which
# is what we want here — but signing inner binaries explicitly first
# guarantees the ordering is right (notarisation requires nested signing
# in dependency order).
codesign --force --options runtime \
  --sign "$CODESIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  AOS.app/Contents/Resources/sidecar/bin/bun

# Outer bundle.
codesign --force --options runtime \
  --sign "$CODESIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --identifier com.aos.shell \
  AOS.app

echo "Built AOS.app at $REPO_ROOT/AOS.app (version $APP_VERSION build $BUILD_NUMBER)"
