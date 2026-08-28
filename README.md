# Codex Halo

Codex Halo is a native, menu-bar-only macOS utility whose only job is to show remaining Codex usage. The outer ring is the weekly limit and the inner ring is the 5-hour limit. Buckets are classified by their actual durations rather than API slot order.

## Build and verify

```bash
tools/build.sh
"tmp/Codex Halo.app/Contents/MacOS/CodexHalo" --self-check
"tmp/Codex Halo.app/Contents/MacOS/CodexHalo" --preview tmp/menu-bar-preview.png
```

The build script produces `tmp/Codex Halo.app`, targets the current arm64 Mac, and ad-hoc signs the app. The preview is a 44×44-pixel PNG of the real 22-point menu-bar artwork at 2× scale. CLI modes exit without starting the GUI.

## Install

```bash
tools/install.sh
```

This installs `/Applications/Codex Halo.app`, removes the old `/Applications/CodexUsageRings.app` bundle, creates the existing user LaunchAgent `local.codex.usage-rings`, launches it at login, and starts it immediately.

## Uninstall

```bash
tools/uninstall.sh
```

## Architecture and data sources

- `Sources/UsageDecoder.swift` confines API `primary`/`secondary` names to decoding, then maps known durations to semantic `fiveHour` and `weekly` values.
- `Sources/UsageClient.swift` reads only the access token from `${CODEX_HOME:-~/.codex}/auth.json`, requests `https://chatgpt.com/backend-api/wham/usage`, and falls back to the newest `codex.rate_limits` event in `logs_2.sqlite`.
- `Sources/RingRenderer.swift` is shared by the status item and PNG preview so duration semantics, colors, arc direction, and proportions stay aligned.
- `Sources/AppDelegate.swift` refreshes on launch, every 60 seconds, and on demand using a background queue. AppKit state changes stay on the main thread, and the last valid snapshot remains visible as cached data after failures.
- `Sources/MenuContentViewController.swift` provides the custom view inside the native status-item menu, including base limits, additional model-specific limits, freshness, error states, Refresh, and Quit.

The app is an `LSUIElement` accessory with no Dock icon, ordinary window, analytics, or network traffic beyond the Codex usage endpoint. Tokens are never displayed, logged, persisted, or included in errors.
