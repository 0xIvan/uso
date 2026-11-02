Uso's provider-neutral app icon is rendered by `tools/generate-icons.sh` from
`tools/GenerateUsoIcon.swift`, including its light and dark variants.

The transparent Codex logo is the original `codex-app-ga-logo` PNG from the
installed Codex desktop app's webview assets. The transparent Claude logo uses
the original starburst SVG path and clay color from https://claude.com/download.
The Grok Bot badge is the bot shape cut from the installed Grok Bot app icon,
without its tile. The Cursor badge is the cube mark from Cursor's bundled
`out/vs/glass/browser/media/cursor-splash-logo-normal.png`, with the arrow cut
out. Both are single-color 104x104 template PNGs, so
Uso draws them in the menu bar's text color on light and dark menu bars.
No badge includes an app-icon tile or background.
