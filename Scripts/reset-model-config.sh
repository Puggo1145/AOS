#!/usr/bin/env bash
# Reset only model/provider state — leaves TCC grants intact so onboarding
# jumps straight past the permission cards into the model picker. Useful
# when iterating on the provider/onboard UI without re-granting Screen
# Recording + Accessibility every loop.
#
# Wiped:
#   - ~/.notch-agent/config.json              (selection, effort, hasCompletedOnboarding)
#   - ~/.notch-agent/auth/                    (chatgpt.json OAuth token)
#   - Keychain entries under service "com.notch-agent.apikey" (DeepSeek + future apiKey providers)
#
# Not touched:
#   - TCC ScreenCapture / Accessibility grants
#   - ~/.notch-agent/run/ and any workspaces
#   - The Notch Agent.app bundle, signing identity, anything else
set -euo pipefail

BUNDLE_ID="com.notch-agent.shell"
NOTCH_HOME="${HOME}/.notch-agent"
APIKEY_SERVICE="com.notch-agent.apikey"

echo "==> Quitting Notch Agent if running"
pkill -x "Notch Agent" 2>/dev/null || true
sleep 0.4

echo "==> Removing ${NOTCH_HOME}/config.json"
rm -f "${NOTCH_HOME}/config.json"

echo "==> Removing ${NOTCH_HOME}/auth/"
rm -rf "${NOTCH_HOME}/auth"

echo "==> Clearing Keychain API keys (service=${APIKEY_SERVICE})"
# `security delete-generic-password` removes one entry per call and exits
# non-zero when nothing matches — loop until empty so we catch every
# provider id stored under the same service.
while security delete-generic-password -s "${APIKEY_SERVICE}" >/dev/null 2>&1; do
    echo "    removed one"
done
echo "    done"

echo
echo "Done. TCC grants for ${BUNDLE_ID} were left in place."
echo "Re-run Scripts/run.sh to land directly in the provider picker."
