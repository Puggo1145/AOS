#!/usr/bin/env bash
# Reset every piece of AOS user state on this machine: kill the running
# app, remove the on-disk config dir, and revoke the TCC grants. Useful
# for re-running the onboarding flow end-to-end during development.
#
# Wiped:
#   - ~/.aos/                          (config.json, auth/, workspaces, run/)
#   - TCC ScreenCapture for com.aos.shell + ad-hoc fallbacks
#   - TCC Accessibility for com.aos.shell + ad-hoc fallbacks
#
# Not touched:
#   - The AOS.app bundle itself
#   - The signing certificate in your Keychain
#   - System Settings panes (Apple's UI may still display a stale "AOS"
#     row for a moment after reset; it disappears once the app is
#     re-launched and TCC re-creates the entry)
set -euo pipefail

BUNDLE_ID="com.aos.shell"
AOS_HOME="${HOME}/.aos"

echo "==> Quitting AOS if running"
pkill -x AOS 2>/dev/null || true
# Give AppKit a beat to flush its state to disk before we nuke it.
sleep 0.4

echo "==> Removing ${AOS_HOME}"
if [ -d "${AOS_HOME}" ]; then
    rm -rf "${AOS_HOME}"
    echo "    removed"
else
    echo "    (already gone)"
fi

echo "==> Resetting AOS's TCC grants"
# tccutil exits non-zero if no record exists; that's fine for a reset.
# Targets ONLY AOS — never call `tccutil reset SERVICE` without a
# bundle id, that wipes every app's grant for the service. We list
# both the canonical id and the ad-hoc identifier ("AOSShell") that
# unsigned dev builds used to register under, in case stale records
# linger from earlier sessions.
for service in ScreenCapture Accessibility; do
    sudo tccutil reset "${service}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
    sudo tccutil reset "${service}" AOSShell      >/dev/null 2>&1 || true
    echo "    ${service}: cleared for AOS"
done

echo
echo "Done. Re-run ./Scripts/run.sh to re-enter onboarding from scratch."
