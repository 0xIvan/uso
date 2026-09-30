#!/usr/bin/env bash
set -euo pipefail

INSTALLED_APP="/Applications/Uso.app"
LEGACY_APP="/Applications/CodexUsageRings.app"
LAUNCH_AGENT_PATH="${HOME}/Library/LaunchAgents/local.codex.usage-rings.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "${DOMAIN}" "${LAUNCH_AGENT_PATH}" >/dev/null 2>&1 || true
rm -f "${LAUNCH_AGENT_PATH}"
rm -rf "${INSTALLED_APP}"
rm -rf "${LEGACY_APP}"
rm -rf "/Applications/Codex Halo.app"

echo "Removed Uso"
