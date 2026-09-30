#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT_APP="${ROOT_DIR}/tmp/Uso.app"
INSTALL_DIR="/Applications"
INSTALLED_APP="${INSTALL_DIR}/Uso.app"
LEGACY_APP="${INSTALL_DIR}/CodexUsageRings.app"
PREVIOUS_APP="${INSTALL_DIR}/Codex Halo.app"
LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
LAUNCH_AGENT_PATH="${LAUNCH_AGENT_DIR}/local.codex.usage-rings.plist"
DOMAIN="gui/$(id -u)"

"${ROOT_DIR}/tools/build.sh" "${BUILT_APP}"
mkdir -p "${INSTALL_DIR}" "${LAUNCH_AGENT_DIR}"

launchctl bootout "${DOMAIN}" "${LAUNCH_AGENT_PATH}" >/dev/null 2>&1 || true
rm -rf "${INSTALLED_APP}"
ditto "${BUILT_APP}" "${INSTALLED_APP}"
rm -rf "${LEGACY_APP}"
rm -rf "${PREVIOUS_APP}"

cat >"${LAUNCH_AGENT_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.codex.usage-rings</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALLED_APP}/Contents/MacOS/Uso</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "${LAUNCH_AGENT_PATH}" >/dev/null
launchctl bootstrap "${DOMAIN}" "${LAUNCH_AGENT_PATH}"
launchctl kickstart -k "${DOMAIN}/local.codex.usage-rings"

echo "Installed and started ${INSTALLED_APP}"
