#!/usr/bin/env bash
# Reset only model/provider state for either the dev or release app identity.
# Leaves TCC grants intact so onboarding jumps straight past the permission
# cards into the model picker. Useful when iterating on the provider/onboard UI
# without re-granting Screen Recording + Accessibility every loop.
#
# Usage:
#   Scripts/reset-model-config.sh dev
#   Scripts/reset-model-config.sh release
#
# Default target: dev
#
# Wiped:
#   - ~/.notch-agent/config.json              (selection, effort, hasCompletedOnboarding)
#   - ~/.notch-agent/auth/                    (chatgpt.json OAuth token)
#   - Keychain entries under service "com.notch-agent.apikey" (DeepSeek + future apiKey providers)
#
# Not touched:
#   - TCC ScreenCapture / Accessibility grants
#   - ~/.notch-agent/run/ and any workspaces
#   - The selected .app bundle, signing identity, anything else
set -euo pipefail

TARGET="${1:-dev}"
case "${TARGET}" in
    dev)
        APP_LABEL="notch-agent-dev"
        BUNDLE_ID="com.notch-agent.shell.dev"
        ;;
    release)
        APP_LABEL="Notch Agent"
        BUNDLE_ID="com.notch-agent.shell"
        ;;
    -h|--help|help)
        echo "Usage: $0 [dev|release]" >&2
        exit 0
        ;;
    *)
        echo "error: unknown reset target '${TARGET}'" >&2
        echo "Usage: $0 [dev|release]" >&2
        exit 64
        ;;
esac

NOTCH_HOME="${HOME}/.notch-agent"
APIKEY_SERVICE="com.notch-agent.apikey"

echo "==> Quitting ${APP_LABEL} if running"
pkill -x "${APP_LABEL}" 2>/dev/null || true
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
if [ "${TARGET}" = "dev" ]; then
    echo "Re-run Scripts/run.sh to land directly in the dev provider picker."
else
    echo "Re-launch Notch Agent.app to land directly in the release provider picker."
fi
