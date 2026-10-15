#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/uso-renewal-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -parse-as-library \
  "$ROOT_DIR/Sources/UsageModels.swift" \
  "$ROOT_DIR/Sources/ClaudeCredentialStore.swift" \
  "$ROOT_DIR/Sources/ClaudeUsageClient.swift" \
  "$ROOT_DIR/tools/check-claude-renewal.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
