#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${ROOT_DIR}/tmp/Codex Halo.app}"
CONTENTS_PATH="${APP_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
RESOURCES_PATH="${CONTENTS_PATH}/Resources"
EXECUTABLE_PATH="${MACOS_PATH}/CodexHalo"

rm -rf "${APP_PATH}"
mkdir -p "${MACOS_PATH}" "${RESOURCES_PATH}"

xcrun swiftc \
  -parse-as-library \
  -O \
  -target arm64-apple-macosx13.0 \
  "${ROOT_DIR}"/Sources/*.swift \
  -o "${EXECUTABLE_PATH}" \
  -framework AppKit \
  -framework Foundation \
  -lsqlite3

cp "${ROOT_DIR}/Info.plist" "${CONTENTS_PATH}/Info.plist"
cp "${ROOT_DIR}/Resources/AppIcon.icns" "${RESOURCES_PATH}/AppIcon.icns"
cp "${ROOT_DIR}/Resources/AppIcon-light.png" "${RESOURCES_PATH}/AppIcon-light.png"
cp "${ROOT_DIR}/Resources/AppIcon-dark.png" "${RESOURCES_PATH}/AppIcon-dark.png"

xcrun actool \
  "${ROOT_DIR}/Resources/AppIcon.xcassets" \
  --compile "${RESOURCES_PATH}" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "${ROOT_DIR}/tmp/AppIcon-Info.plist" \
  --output-format human-readable-text \
  --warnings \
  --notices

codesign --force --deep --sign - "${APP_PATH}"

echo "Built ${APP_PATH}"
