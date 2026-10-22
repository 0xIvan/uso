#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${1:-${ROOT_DIR}/dist}"
SPARKLE_DIR="$("${ROOT_DIR}/tools/sparkle.sh")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT_DIR}/Info.plist")"
ARCHIVE="Uso-${VERSION}-universal.dmg"
[[ -f "${DIST_DIR}/${ARCHIVE}" ]] || { echo "Missing release DMG: ${DIST_DIR}/${ARCHIVE}" >&2; exit 1; }
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/uso-appcast.XXXXXX")"
trap 'rm -rf "${STAGING}"' EXIT
cp "${DIST_DIR}/${ARCHIVE}" "${STAGING}/${ARCHIVE}"
cp "${ROOT_DIR}/docs/release-notes.md" "${STAGING}/${ARCHIVE%.dmg}.md"
OPTIONS=(--maximum-deltas 0 --embed-release-notes
  --download-url-prefix "https://github.com/0xIvan/uso/releases/download/v${VERSION}/"
  --link "https://github.com/0xIvan/uso")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "${SPARKLE_PRIVATE_KEY}" | "${SPARKLE_DIR}/bin/generate_appcast" \
    --ed-key-file - "${OPTIONS[@]}" "${STAGING}"
else
  "${SPARKLE_DIR}/bin/generate_appcast" --account uso-sparkle "${OPTIONS[@]}" "${STAGING}"
fi
[[ -s "${STAGING}/appcast.xml" ]] || { echo "Sparkle did not generate appcast.xml." >&2; exit 1; }
swift "${ROOT_DIR}/tools/verify-appcast.swift" "${ROOT_DIR}/Info.plist" "${STAGING}/appcast.xml" "${STAGING}/${ARCHIVE}"
cp "${STAGING}/appcast.xml" "${DIST_DIR}/appcast-com.ivan.uso.xml"
# Old bundle IDs cannot install new-ID bundles through Sparkle. Keep their final signed feed intact.
curl --fail --silent --show-error --location \
  "https://github.com/0xIvan/uso/releases/download/v0.2.10/appcast.xml" -o "${STAGING}/legacy-appcast.xml"
LEGACY_FEED_SHA256="fa05cc8ea8b036af90b54a8057ae77f5f7444dd5ed7eabc46abd031e48ec4474"
[[ "$(shasum -a 256 "${STAGING}/legacy-appcast.xml" | awk '{print $1}')" == "${LEGACY_FEED_SHA256}" ]] || {
  echo "Legacy Sparkle feed checksum mismatch." >&2; exit 1;
}
cp "${STAGING}/legacy-appcast.xml" "${DIST_DIR}/appcast.xml"
echo "Generated ${DIST_DIR}/appcast-com.ivan.uso.xml and retained the legacy feed"
