#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/uso-icons.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT
ICONSET="${BUILD_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET}"

xcrun swiftc -parse-as-library "${ROOT_DIR}/tools/GenerateUsoIcon.swift" \
  -o "${BUILD_DIR}/generate-icon" -framework AppKit -framework Foundation
for THEME in light dark; do
  "${BUILD_DIR}/generate-icon" "${ROOT_DIR}/Resources/AppIcon-${THEME}.png" "${THEME}"
done

for SIZE in 16 32 128 256 512; do
  for SCALE in 1 2; do
    SUFFIX=""
    if [[ "${SCALE}" == 2 ]]; then SUFFIX="@2x"; fi
    PIXELS=$((SIZE * SCALE))
    OUTPUT="${ICONSET}/icon_${SIZE}x${SIZE}${SUFFIX}.png"
    sips -z "${PIXELS}" "${PIXELS}" "${ROOT_DIR}/Resources/AppIcon-light.png" --out "${OUTPUT}" >/dev/null
    cp "${OUTPUT}" "${ROOT_DIR}/Resources/AppIcon.xcassets/AppIcon.appiconset/icon-${SIZE}${SUFFIX}-light.png"
  done
done
iconutil -c icns "${ICONSET}" -o "${ROOT_DIR}/Resources/AppIcon.icns"
