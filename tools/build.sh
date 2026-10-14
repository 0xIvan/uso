#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${ROOT_DIR}/tmp/Uso.app}"
CONTENTS_PATH="${APP_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
RESOURCES_PATH="${CONTENTS_PATH}/Resources"
EXECUTABLE_PATH="${MACOS_PATH}/Uso"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
SPARKLE_DIR="$("${ROOT_DIR}/tools/sparkle.sh")"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/uso-build.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT

# Refuse arbitrary deletion when a caller supplies an output path.
if [[ "${APP_PATH}" != *.app || -L "${APP_PATH}" ]]; then
  echo "Output must be an app bundle path, not a symlink." >&2
  exit 1
fi
rm -rf "${APP_PATH}"
mkdir -p "${MACOS_PATH}" "${RESOURCES_PATH}"

for ARCH in arm64 x86_64; do
  xcrun swiftc \
    -parse-as-library -O \
    -target "${ARCH}-apple-macosx13.0" \
    "${ROOT_DIR}"/Sources/*.swift \
    -o "${BUILD_DIR}/Uso-${ARCH}" \
    -framework AppKit -framework Foundation \
    -F "${SPARKLE_DIR}" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
done
xcrun lipo -create "${BUILD_DIR}/Uso-arm64" "${BUILD_DIR}/Uso-x86_64" -output "${EXECUTABLE_PATH}"

cp "${ROOT_DIR}/Info.plist" "${CONTENTS_PATH}/Info.plist"
cp "${ROOT_DIR}/Resources/AppIcon.icns" "${RESOURCES_PATH}/AppIcon.icns"
cp "${ROOT_DIR}/Resources/CodexLogo.png" "${RESOURCES_PATH}/CodexLogo.png"
cp "${ROOT_DIR}/Resources/ClaudeLogo.svg" "${RESOURCES_PATH}/ClaudeLogo.svg"
cp "${ROOT_DIR}/Resources/AppIcon-light.png" "${RESOURCES_PATH}/AppIcon-light.png"
cp "${ROOT_DIR}/Resources/AppIcon-dark.png" "${RESOURCES_PATH}/AppIcon-dark.png"
xcrun actool "${ROOT_DIR}/Resources/AppIcon.xcassets" \
  --compile "${RESOURCES_PATH}" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "${BUILD_DIR}/AppIcon-Info.plist" \
  --output-format human-readable-text --warnings --notices

mkdir -p "${CONTENTS_PATH}/Frameworks"
ditto "${SPARKLE_DIR}/Sparkle.framework" "${CONTENTS_PATH}/Frameworks/Sparkle.framework"
cp "${SPARKLE_DIR}/LICENSE" "${RESOURCES_PATH}/Sparkle-LICENSE.txt"

SIGNING_OPTIONS=(--force --sign "${SIGNING_IDENTITY}")
if [[ "${SIGNING_IDENTITY}" != "-" ]]; then
  SIGNING_OPTIONS+=(--options runtime --timestamp)
fi
# Sign nested helpers before their enclosing framework and app; retain XPC entitlements.
SPARKLE_FRAMEWORK="${CONTENTS_PATH}/Frameworks/Sparkle.framework"
for COMPONENT in \
  "Versions/B/XPCServices/Downloader.xpc" \
  "Versions/B/XPCServices/Installer.xpc" \
  "Versions/B/Autoupdate" \
  "Versions/B/Updater.app"; do
  codesign "${SIGNING_OPTIONS[@]}" --preserve-metadata=identifier,entitlements "${SPARKLE_FRAMEWORK}/${COMPONENT}"
done
codesign "${SIGNING_OPTIONS[@]}" "${SPARKLE_FRAMEWORK}"
codesign "${SIGNING_OPTIONS[@]}" "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"
echo "Built ${APP_PATH}"
