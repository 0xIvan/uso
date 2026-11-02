Grok Bot and Cursor badges in the menu bar are now plain marks without an app-icon tile, matching Codex and Claude. They follow the menu bar's text color on light and dark menu bars. The Cursor badge now uses Cursor's current cube logo.

Uso now shows Grok Bot and Cursor usage next to Codex and Claude. Turn each provider on or off in Settings. Grok Bot shows its weekly limit. Cursor shows its plan usage for the current billing cycle.

Grok Bot's sign-in is encrypted with a Keychain password, so macOS asks whether Uso may read "Grok Bot Safe Storage". Choose **Always Allow** so macOS does not ask again on each launch. If you deny the prompt or leave it unanswered, Uso stops asking until you click Refresh.

Limits that reset on a monthly billing cycle are now labeled **Monthly** instead of **Weekly**.

Providers you turn off in Settings are no longer read. Uso does not open their credentials, ask for Keychain access, or request their usage. Turning a provider back on loads it right away.

Some accounts get one unified allowance shared by Cursor and Grok Bot. Both providers then show that same allowance. To see it once, turn one of them off in Settings.

Usage bars now show how far behind pace you are (for example "12% behind pace") instead of the percentage used.

Claude usage keeps working when Claude Code's access token expires. Uso now runs a minimal Claude Code request (Haiku, no tools, no saved session, at most every 15 minutes) so Claude Code renews its own sign-in, instead of showing "sign-in expired" until you next use Claude Code in a terminal.

Uso no longer renews Claude sign-ins itself. Renewing alongside Claude Code invalidated Claude Code's own login and forced repeated `claude /login`.

Usage bar pace warnings now use `%` instead of `pt` or `pts`.

Uso now alerts you when Codex or Claude has more usage available, including unscheduled resets. It also notifies you when new redeemable Codex resets arrive. Alerts are detected on successful refreshes; the first reading stays quiet, and account-scoped notification history persists across restarts. Toggle **Limit reset alerts** in Settings.

Settings now groups Menu bar, Notifications, and General controls, with a Ring guide for reading the menu bar icons.

The usage menu now uses the freshest successful provider reading for its header, keeps provider errors inside their sections, and hides the normal Live badge. Exhausted limits show **Limit reached** and the reset time. Percentages use whole numbers, windows are named **5-hour** and **Weekly**, and pace warnings appear only when usage is ahead of pace. Signed-out users get a separate login command and Copy command button for each provider.

**One-time manual upgrade:** Uso now uses `com.ivan.uso`. In an older build, note whether Open at login is on, then turn it off. Quit Uso, download this release, and replace Uso in Applications. Restore Open at login if previously enabled, and allow notifications when macOS asks. Settings and reset-notification history migrate automatically; provider sign-ins are preserved. Future new-ID builds use a separate signed update feed, while old builds retain their final compatible update.

Uso is a native macOS menu bar utility showing remaining Codex, Claude, Grok Bot, and Cursor subscription usage. Requires macOS 13 or newer; the download includes Apple Silicon and Intel binaries.

- Turned-on providers refresh every five minutes, with a manual Refresh button.
- Weekly or monthly usage appears on the outer ring and five-hour usage on the inner ring.
- Uso no longer renews Claude tokens. Renewing them alongside Claude Code invalidated Claude Code's login; Claude Code renews them when Uso finds the sign-in expired. Uso reads every provider's credentials without modifying them.
- Failed requests clear usage readings; no cached logs are used.

Download the DMG under Assets, drag Uso to Applications, eject the image, and open Uso. The app and DMG are Developer ID signed and notarized by Apple. Use Check for Updates… for future published updates; Sparkle downloads, installs, and relaunches Uso after you approve the update.

Claude monitoring is experimental. Permission for this usage-only integration under Anthropic's subscription credential policy has not been established; Provider changes may interrupt support. Uso is independent software, not affiliated with or endorsed by OpenAI, Anthropic, xAI, or Anysphere (Cursor).

The compiled app is free to use; source rights are retained. Installation instructions, privacy information, and distribution terms are included in the DMG.

Report problems at https://github.com/0xIvan/uso/issues. Do not attach credential files, tokens, passwords, or unredacted account details.

Intel and macOS 13 execution have not been tested on physical machines. A clean-Mac installation, launch after signing in, and live provider/lifecycle checks remain outstanding.
