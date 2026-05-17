#!/usr/bin/env bash
# Reset every piece of Notch Agent user state on this machine: kill the running
# app, remove the on-disk config dir, and revoke the TCC grants. Useful
# for re-running the onboarding flow end-to-end during development.
#
# Wiped:
#   - ~/.notch-agent/                          (config.json, auth/, workspaces, run/)
#   - Notch Agent UserDefaults domain           (permission onboarding latches, UI prefs)
#   - Keychain service com.notch-agent.apikey   (DeepSeek + future apiKey providers)
#   - TCC ScreenCapture for com.notch-agent.shell + ad-hoc fallbacks
#   - TCC Accessibility for com.notch-agent.shell + ad-hoc fallbacks
#   - TCC AppleEvents for com.notch-agent.shell + ad-hoc fallbacks
#
# Not touched:
#   - The Notch Agent.app bundle itself
#   - The signing certificate in your Keychain
#   - System Settings panes (Apple's UI may still display a stale "Notch Agent"
#     row for a moment after reset; it disappears once the app is
#     re-launched and TCC re-creates the entry)
set -euo pipefail

BUNDLE_ID="com.notch-agent.shell"
NOTCH_HOME="${HOME}/.notch-agent"
APIKEY_SERVICE="com.notch-agent.apikey"

delete_keychain_items() {
    local output status removed
    removed=0

    while output=$(security delete-generic-password -s "${APIKEY_SERVICE}" 2>&1); do
        removed=$((removed + 1))
        echo "    removed one"
    done
    status=$?

    if [ "${status}" -eq 44 ] && [[ "${output}" == *"could not be found"* ]]; then
        if [ "${removed}" -eq 0 ]; then
            echo "    (already empty)"
        fi
        echo "    done"
        return
    fi

    echo "    failed to clear Keychain service ${APIKEY_SERVICE}" >&2
    echo "    ${output}" >&2
    return "${status}"
}

reset_tcc_service() {
    local service bundle output status
    service="$1"
    bundle="$2"

    if output=$(tccutil reset "${service}" "${bundle}" 2>&1); then
        echo "    ${service}: cleared for ${bundle}"
        return
    fi
    status=$?

    if [ "${status}" -eq 64 ] && [[ "${output}" == *"No such bundle identifier"* ]]; then
        echo "    ${service}: no registered bundle ${bundle}; nothing to clear"
        return
    fi

    echo "    failed to reset ${service} for ${bundle}" >&2
    echo "    ${output}" >&2
    return "${status}"
}

echo "==> Quitting Notch Agent if running"
pkill -x "Notch Agent" 2>/dev/null || true
pkill -x Shell 2>/dev/null || true
# Give AppKit a beat to flush its state to disk before we nuke it.
sleep 0.4

echo "==> Removing ${NOTCH_HOME}"
if [ -d "${NOTCH_HOME}" ]; then
    rm -rf "${NOTCH_HOME}"
    echo "    removed"
else
    echo "    (already gone)"
fi

echo "==> Clearing Notch Agent UserDefaults"
defaults delete "${BUNDLE_ID}" >/dev/null 2>&1 || true
defaults delete Shell       >/dev/null 2>&1 || true
echo "    cleared"

echo "==> Clearing Keychain API keys (service=${APIKEY_SERVICE})"
# `security delete-generic-password` removes one entry per call. Keep
# looping until the Keychain reports "not found", but fail loudly for real
# Keychain errors instead of treating them as a successful reset.
delete_keychain_items

echo "==> Resetting Notch Agent's TCC grants"
# Targets ONLY Notch Agent — never call `tccutil reset SERVICE` without a
# bundle id, that wipes every app's grant for the service. We list
# both the canonical id and the ad-hoc identifier ("Shell") that
# unsigned dev builds used to register under, in case stale records
# linger from earlier sessions.
for service in ScreenCapture Accessibility AppleEvents; do
    reset_tcc_service "${service}" "${BUNDLE_ID}"
    reset_tcc_service "${service}" Shell
done

echo
echo "Done. Re-run ./Scripts/run.sh to re-enter onboarding from scratch."
