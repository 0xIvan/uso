Restored automatic Claude access-token renewal with shared Claude Code refresh and storage locks, checks that preserve newer logins and logouts, and secure credential persistence. Uso also refreshes after waking from sleep. Temporary Claude failures no longer tell you to log in again.

Codex credentials remain read-only. Claude renewal updates the existing shared login store.

Uso is a native macOS menu bar utility showing remaining Codex and Claude subscription usage. Requires macOS 13 or newer; the download includes Apple Silicon and Intel binaries.

- Both providers refresh every five minutes, with a manual Refresh button.
- Weekly usage appears on the outer ring and five-hour usage on the inner ring.
- Claude access tokens renew automatically. Rejected refresh credentials require a new Claude Code login. Codex credentials remain read-only.
- Failed requests clear usage readings; no cached logs are used.

Download the DMG under Assets, drag Uso to Applications, eject the image, and open Uso. The app and DMG are Developer ID signed and notarized by Apple. Use Check for Updates… for future published updates; Sparkle downloads, installs, and relaunches Uso after you approve the update.

Claude monitoring is experimental. Permission for this usage-only integration under Anthropic's subscription credential policy has not been established; Provider changes may interrupt support. Uso is independent software, not affiliated with or endorsed by OpenAI or Anthropic.

The compiled app is free to use; source rights are retained. Installation instructions, privacy information, and distribution terms are included in the DMG.

Report problems at https://github.com/0xIvan/uso/issues. Do not attach credential files, tokens, passwords, or unredacted account details.

Intel and macOS 13 execution have not been tested on physical machines. A clean-Mac installation and live provider/lifecycle checks remain outstanding; this draft is for review before public release.
