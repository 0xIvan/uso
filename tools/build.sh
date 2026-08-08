#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${ROOT_DIR}/tmp/CodexUsageRings.app}"
CONTENTS_PATH="${APP_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
EXECUTABLE_PATH="${MACOS_PATH}/CodexUsageRings"

rm -rf "${APP_PATH}"
mkdir -p "${MACOS_PATH}"

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
codesign --force --deep --sign - "${APP_PATH}"

echo "Built ${APP_PATH}"
