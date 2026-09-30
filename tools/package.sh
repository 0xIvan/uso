#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
if [[ $# -ne 1 || ( "${MODE}" != "--preview" && "${MODE}" != "--release" ) ]]; then
  echo "Usage: tools/package.sh --preview | --release" >&2
  echo "Release requires CODE_SIGN_IDENTITY and NOTARY_PROFILE (notarytool Keychain profile)." >&2
  exit 1
fi
if [[ "${MODE}" == "--release" ]]; then
  if [[ "${CODE_SIGN_IDENTITY:-}" != "Developer ID Application: "* || -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Release requires a Developer ID Application identity and NOTARY_PROFILE." >&2
    exit 1
  fi
else
  export CODE_SIGN_IDENTITY="-"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT_DIR}/Info.plist")"
if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Bundle version must use major.minor.patch." >&2
  exit 1
fi
mkdir -p "${ROOT_DIR}/dist" "${ROOT_DIR}/tmp"
STAGING="$(mktemp -d "${ROOT_DIR}/tmp/package.XXXXXX")"
trap 'rm -rf "${STAGING}"' EXIT
PAYLOAD="${STAGING}/payload"
APP_PATH="${PAYLOAD}/Uso.app"
mkdir -p "${PAYLOAD}"
"${ROOT_DIR}/tools/build.sh" "${APP_PATH}"
"${APP_PATH}/Contents/MacOS/Uso" --self-check
for ARCH in arm64 x86_64; do
  xcrun lipo "${APP_PATH}/Contents/MacOS/Uso" -verify_arch "${ARCH}"
done

if [[ "${MODE}" == "--release" ]]; then
  # Staple the app before packaging so its ticket survives copying off the DMG.
  ditto -c -k --keepParent "${APP_PATH}" "${STAGING}/notarize.zip"
  xcrun notarytool submit "${STAGING}/notarize.zip" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${APP_PATH}"
  xcrun stapler validate "${APP_PATH}"
  spctl --assess --type execute --verbose=2 "${APP_PATH}"
  BASENAME="Uso-${VERSION}-universal"
else
  BASENAME="Uso-${VERSION}-universal-preview"
  printf '%s\n' 'LOCAL PREVIEW — NOT FOR PUBLIC DISTRIBUTION' 'This build is ad-hoc signed and has not been notarized by Apple.' > "${PAYLOAD}/PREVIEW.txt"
fi

ln -s /Applications "${PAYLOAD}/Applications"
cp "${ROOT_DIR}/docs/installation.txt" "${PAYLOAD}/Installation.txt"
cp "${ROOT_DIR}/docs/privacy.md" "${PAYLOAD}/Privacy.md"
DMG_PATH="${STAGING}/${BASENAME}.dmg"
hdiutil create -volname "Uso" -srcfolder "${PAYLOAD}" -format UDZO -ov "${DMG_PATH}"
if [[ "${MODE}" == "--release" ]]; then
  codesign --timestamp --sign "${CODE_SIGN_IDENTITY}" "${DMG_PATH}"
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler validate "${DMG_PATH}"
  spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
fi
hdiutil verify "${DMG_PATH}"
mv "${DMG_PATH}" "${ROOT_DIR}/dist/${BASENAME}.dmg"
(cd "${ROOT_DIR}/dist" && shasum -a 256 "${BASENAME}.dmg" > "${BASENAME}.dmg.sha256")
echo "Packaged ${ROOT_DIR}/dist/${BASENAME}.dmg"
