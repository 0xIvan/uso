#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="2.10.0"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
DIRECTORY="${ROOT_DIR}/tmp/dependencies/Sparkle-${VERSION}"
ARCHIVE="${DIRECTORY}.tar.xz"
mkdir -p "$(dirname "${DIRECTORY}")"
if [[ ! -f "${ARCHIVE}" ]]; then
  DOWNLOAD="$(mktemp "${ARCHIVE}.XXXXXX")"
  trap 'rm -f "${DOWNLOAD}"' EXIT
  curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz" -o "${DOWNLOAD}"
  printf '%s  %s\n' "${SHA256}" "${DOWNLOAD}" | shasum -a 256 -c - >/dev/null
  mv "${DOWNLOAD}" "${ARCHIVE}"
fi
printf '%s  %s\n' "${SHA256}" "${ARCHIVE}" | shasum -a 256 -c - >/dev/null
if [[ ! -d "${DIRECTORY}/Sparkle.framework" ]]; then
  mkdir -p "${DIRECTORY}"
  tar -xf "${ARCHIVE}" -C "${DIRECTORY}"
fi
printf '%s\n' "${DIRECTORY}"
