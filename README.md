# Uso

App name: **Uso**. Repository name: `uso`.

A native macOS menu bar utility showing remaining Codex and Claude subscription usage. Choose Codex and Claude in Settings. Each provider has one icon with weekly usage on the outer ring and 5-hour usage on the inner ring. Only reported limits appear: accounts without a 5-hour limit show no inner ring. Enabled providers appear side by side. Independent software, not affiliated with OpenAI or Anthropic.

All rings use the same pace calculation: usage compared with the elapsed portion of its window. Green means on or under pace (with a 0.5-point tolerance), yellow warns up to 5 percentage points over pace, and red means more than 5 points over pace. When either usage limit reaches 0% remaining, that provider's rings become a red exclamation mark. Gray means pace is unavailable for a reported limit. With all rings disabled, a small “u” button keeps Settings accessible. Choices persist between launches.

Providers without a local subscription sign-in are hidden from the menu bar and usage menu. Settings keeps your visibility preferences for when you sign in again. Failed fetches keep signed-in providers visible but hide usage values and show “Log in again” with provider-specific instructions. If neither provider is signed in, a small Uso button keeps Settings and Refresh accessible. Claude five-hour usage at 0% without a reset timestamp is shown as “Window not started.”

## Install on another Mac

Open the DMG, drag **Uso** to **Applications**, eject the image, and open the app. No developer tools are required on the receiving Mac. The app appears in the menu bar with no Dock icon. Open Settings from its menu to choose rings.

Requires macOS 13+ on Apple Silicon or Intel, and a local Codex ChatGPT sign-in whose credentials are readable in `~/.codex/auth.json`. Keychain-only and API-key-only authentication are not supported. Uso does not sign in or renew Codex tokens itself. Claude usage requires a Claude Code subscription sign-in stored in the macOS Keychain or `~/.claude/.credentials.json`; API keys do not provide subscription limits.

See [installation and troubleshooting](docs/installation.txt) and [privacy](docs/privacy.md). Start at login is optional through macOS Login Items. After installing a Sparkle-enabled build, choose **Check for Updates…** in Uso’s Settings to download, install, and relaunch into a published update. Background checks and unattended installation are disabled. Older builds need one manual replacement to gain this feature.

## Build a shareable DMG

On the build Mac, install Xcode and select it with `xcode-select`. Run:

```bash
tools/package.sh --preview
```

This produces `dist/Uso-<version>-universal-preview.dmg` and a SHA-256 checksum. The package contains only the universal app, an Applications shortcut, and instructions. It does not contain your Codex credentials or history.

The preview is ad-hoc signed, not notarized. On the receiving Mac, macOS may block opening it. For a copy you trust, use System Settings > Privacy & Security > Open Anyway after attempting to open it. Do not disable Gatekeeper. The filename and included notice distinguish it from a notarized release.

## Development

```bash
tools/build.sh
"tmp/Uso.app/Contents/MacOS/Uso" --self-check
"tmp/Uso.app/Contents/MacOS/Uso" --preview tmp/menu-bar-preview.png
```

The build downloads checksum-pinned Sparkle 2.10.0 into ignored `tmp/dependencies`, embeds its framework and license, creates an arm64 + x86_64 app targeting macOS 13, and verifies its signature. CLI checks exit without launching the GUI. `--codex-home PATH` overrides the credential directory for verification.

Uso does not inspect `PATH` or execute the Codex or Claude CLI. It uses their
existing subscription sign-ins from the credential stores described below.
Signing defaults to ad-hoc; personal signing identities and notary profiles
are supplied through environment variables and are not embedded in the source.

`tools/install.sh` is the legacy developer installation path: it builds the app, installs it in Applications and creates a per-user LaunchAgent. `tools/uninstall.sh` removes that installation. DMG recipients should use the manual installation instructions instead.

## Public releases

The optional `tools/package.sh --release` path requires `CODE_SIGN_IDENTITY` set to a Developer ID Application certificate name and `NOTARY_PROFILE` set to an existing notarytool Keychain profile. It signs with hardened runtime, notarizes and staples the app and DMG, and checks Gatekeeper before placing the result in `dist`. It does not publish or upload to a download site. Notarization submits the built software to Apple.

See [release checks](docs/releasing.md) before using that path.

## Data sources

Uso requests `https://chatgpt.com/backend-api/wham/usage` every five minutes with the local access token and the account ID from `auth.json` in the `ChatGPT-Account-Id` header, so allowance is read for the same account selected in Codex. Requests use an ephemeral URL session. Failed fetches clear the displayed usage; local logs and previous readings are not used as fallback. These upstream interfaces can change.

When resets may be available, Uso also reads `/backend-api/wham/rate-limit-reset-credits` to show each available Codex reset's expiry in local time, soonest first. If that request fails, the usage summary still loads and expiry dates show as unavailable.

`UsageDecoder.swift` maps durations to five-hour and weekly buckets. `RingRenderer.swift` shares artwork between the menu bar and preview. `AppDelegate.swift` performs requests off the main thread and updates AppKit on the main thread.

Claude usage is read from `https://api.anthropic.com/api/oauth/usage` using the existing Claude Code OAuth access token. Claude refreshes every five minutes, when Refresh is clicked, and after the Mac wakes. Expiring or rejected access tokens are renewed automatically using the existing refresh token at `https://platform.claude.com/v1/oauth/token`. Uso coordinates through Claude Code's refresh and credential-write directory locks, re-reads credentials under the locks, and preserves a newer login or logout instead of overwriting it. Only the active credential store is updated; Keychain takes precedence over the legacy file. Codex credentials remain read-only. Tokens are never logged. Temporary network, lock contention, and rate-limit failures retry without instructing you to log in again; rejected refresh credentials require `claude auth login`. Rate-limited requests wait five minutes before retrying. These upstream interfaces may change.

## Claude integration status

Claude usage monitoring does not perform inference. Token renewal updates Claude
Code's shared login credentials. The lock protocol was checked against Claude
Code 2.1.296; it is an internal interface and future versions may change it.
Uso never steals an existing lock. After an unclean exit, Claude Code may need
to run to recover a stale lock before Uso can resume renewal.
Anthropic's [authentication and credential-use guidance](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)
restricts third-party use of subscription credentials. Permission for Uso's usage-only
integration has not been established. Claude support is experimental and can stop
working if the provider changes access.

## Support

Report problems at [GitHub Issues](https://github.com/0xIvan/uso/issues).
Include the Uso version, macOS version, provider, and steps to reproduce.
Do not attach credential files, tokens, passwords, or unredacted account details.

## Distribution terms

The compiled app is free to use for personal or commercial purposes. Source
rights are retained; this repository is not licensed as open-source software.
See [distribution terms](LICENSE).

## GitHub release workflow

Pushes to `main` run universal build checks, then automatically bump the patch
version and build number, push a release commit and tag, and start the release
workflow. It signs, notarizes, and verifies the DMG and Sparkle feed before
publishing a stable GitHub Release with the DMG, checksum, and `appcast.xml`.
Installed apps can then discover the update. Failed checks prevent publication.
Pull requests run checks only. Superseded pushes are skipped in favor of the
newest commit. The bot's version commit does not trigger another release.

Pull `main` before your next change because automation writes the version commit
back to it. For a minor, major, or explicit version, use `tools/release.sh minor`,
`tools/release.sh major`, or `tools/release.sh VERSION` from a clean, fully pushed
default branch. Tagged release commits do not receive another automatic bump.
Use `--dry-run` to preview. To retry a failed release, rerun its Release workflow
or dispatch `release.yml` on the existing tag; do not create another version.

See [release setup and checks](docs/releasing.md) for the required secrets and
instructions for retrying a release job.

## In-app updates

Sparkle checks `https://github.com/0xIvan/uso/releases/latest/download/appcast.xml`
when the user chooses **Check for Updates…** in Settings. GitHub resolves that URL to the
latest published stable release; drafts and prereleases are not offered.
The feed points to a version-specific DMG download. Both feed and archive are
verified with the public Ed25519 key embedded in `Info.plist`, in addition to
Apple code signing. No application credentials are included in update requests.
The first Sparkle-enabled release must be installed manually. Until that release
is published, the feed is unavailable and manual checks display an update error.

The Sparkle framework's third-party license is included in the app bundle at
`Contents/Resources/Sparkle-LICENSE.txt`.
