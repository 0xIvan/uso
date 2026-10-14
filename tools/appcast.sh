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
cp "${STAGING}/appcast.xml" "${DIST_DIR}/appcast.xml"
echo "Generated ${DIST_DIR}/appcast.xml"
