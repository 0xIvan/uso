# Uso

App name: **Uso**. Repository name: `uso`.

A native macOS menu bar utility showing remaining Codex and Claude subscription usage. Choose Codex and Claude in Settings. Each provider has one icon with weekly usage on the outer ring and 5-hour usage on the inner ring. Enabled providers appear side by side. Independent software, not affiliated with OpenAI or Anthropic.

All rings use the same pace calculation: usage compared with the elapsed portion of its window. Green means on or under pace (with a 0.5-point tolerance), yellow warns up to 5 percentage points over pace, and red means more than 5 points over pace or exhausted. Gray means usage or pace is unavailable. With all rings disabled, a small “u” button keeps Settings accessible. Choices persist between launches.

## Install on another Mac

Open the DMG, drag **Uso** to **Applications**, eject the image, and open the app. No developer tools are required on the receiving Mac. The app appears in the menu bar with no Dock icon. Open Settings from its menu to choose rings.

Requires macOS 13+ on Apple Silicon or Intel, and a local Codex ChatGPT sign-in whose credentials are readable in `~/.codex/auth.json`. Keychain-only and API-key-only authentication are not supported. Uso does not sign in or renew Codex tokens itself. Claude usage requires a Claude Code subscription sign-in stored in the macOS Keychain or `~/.claude/.credentials.json`; API keys do not provide subscription limits.

See [installation and troubleshooting](docs/installation.txt) and [privacy](docs/privacy.md). Start at login is optional through macOS Login Items. Updates are installed by quitting and replacing the app.

## Build a shareable DMG

On the build Mac, install Xcode and select it with `xcode-select`. Run:

```bash
tools/package.sh --preview
```

This produces `dist/Uso-0.2.1-universal-preview.dmg` and a SHA-256 checksum. The package contains only the universal app, an Applications shortcut, and instructions. It does not contain your Codex credentials or history.

The preview is ad-hoc signed, not notarized. On the receiving Mac, macOS may block opening it. For a copy you trust, use System Settings > Privacy & Security > Open Anyway after attempting to open it. Do not disable Gatekeeper. The filename and included notice distinguish it from a future notarized release.

## Development

```bash
tools/build.sh
"tmp/Uso.app/Contents/MacOS/Uso" --self-check
"tmp/Uso.app/Contents/MacOS/Uso" --preview tmp/menu-bar-preview.png
```

The build creates an arm64 + x86_64 app targeting macOS 13 and verifies its signature. CLI checks exit without launching the GUI. `--codex-home PATH` overrides the credential directory for verification.

Uso does not inspect `PATH` or execute the Codex or Claude CLI. It uses their
existing subscription sign-ins from the credential stores described below.
Signing defaults to ad-hoc; personal signing identities and notary profiles
are supplied through environment variables and are not embedded in the source.

`tools/install.sh` is the legacy developer installation path: it builds the app, installs it in Applications and creates a per-user LaunchAgent. `tools/uninstall.sh` removes that installation. DMG recipients should use the manual installation instructions instead.

## Future public releases

The optional `tools/package.sh --release` path requires `CODE_SIGN_IDENTITY` set to a Developer ID Application certificate name and `NOTARY_PROFILE` set to an existing notarytool Keychain profile. It signs with hardened runtime, notarizes and staples the app and DMG, and checks Gatekeeper before placing the result in `dist`. It does not publish or upload to a download site. Notarization submits the built software to Apple.

See [release checks](docs/releasing.md) before using that path.

## Data sources

Uso requests `https://chatgpt.com/backend-api/wham/usage` every 60 seconds with the local access token and the account ID from `auth.json` in the `ChatGPT-Account-Id` header, so allowance is read for the same account selected in Codex. Requests use an ephemeral URL session. If unavailable, it reads the newest compatible `codex.rate_limits` event in `logs_2.sqlite` and can retain the last snapshot in memory. These upstream interfaces can change. Cached values do not confirm the current allowance.

When resets may be available, Uso also reads `/backend-api/wham/rate-limit-reset-credits` to show each available Codex reset's expiry in local time, soonest first. If that request fails, the usage summary still loads and expiry dates show as unavailable.

`UsageDecoder.swift` maps durations to five-hour and weekly buckets. `RingRenderer.swift` shares artwork between the menu bar and preview. `AppDelegate.swift` performs requests off the main thread and updates AppKit on the main thread.

Claude usage is read from `https://api.anthropic.com/api/oauth/usage` using the existing Claude Code OAuth access token. Claude refreshes every five minutes or when Refresh is clicked. Failed requests retain the last successful reading in memory and label it cached. Expired Claude tokens are renewed using the existing refresh token at `https://platform.claude.com/v1/oauth/token`; rotated credentials are saved back to their original Keychain entry or credential file. Tokens are never logged. Rate-limited requests wait five minutes before retrying. Both usage endpoints are upstream interfaces that may change. The stable `local.codex.usage-rings` bundle and launch-agent identifier is retained for installation continuity.
