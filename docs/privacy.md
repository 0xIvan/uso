# Privacy

Uso reads the current user's Codex access token and selected account ID from
`~/.codex/auth.json` (or the configured `CODEX_HOME`). It sends that token
only as authorization to `https://chatgpt.com/backend-api/wham/usage`
and `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`
to request that account's usage limits and reset expiry dates. The account ID is
sent in the `ChatGPT-Account-Id` header to those same endpoints. It does not refresh Codex credentials.

When a usage request fails, Uso clears the displayed usage and asks you to
log in again. It does not read Codex logs or show previous usage as a fallback.

Uso has no analytics, advertising, crash reporting, or developer-operated
server. It does not display, log, renew, or modify credentials. HTTP
requests use an ephemeral session without a persistent response cache.
No credentials or Codex history are bundled in the distributed app.

OpenAI processes the authenticated usage request under its own policies.
Uso is independent software, not affiliated with or endorsed by OpenAI.

For Claude, Uso reads the existing Claude Code OAuth access token from the
`Claude Code-credentials` macOS Keychain entry or
`~/.claude/.credentials.json`, selecting the valid credential document with the
latest expiry when both are present. It sends that token only to
`https://api.anthropic.com/api/oauth/usage` to read subscription usage.
When a token expires, Uso asks you to sign in through Claude Code again.
It does not send refresh tokens, renew tokens, or write to Claude Code's Keychain
entry or credential file. Anthropic processes usage requests under its own policies.
Ring visibility choices are saved locally in UserDefaults.

When you choose Check for Updates…, Sparkle requests the signed update feed and,
if you choose to install, the update archive from GitHub's release asset service.
Requests may follow GitHub's redirects to its asset CDN. GitHub receives normal
network request information such as your IP address and Uso's version/User-Agent.
Codex and Claude credentials are never sent with update requests. Background
update checks, unattended installation, and Sparkle system profiling are disabled.
Sparkle stores downloaded update data temporarily and verifies the signed feed,
archive signature, and application signature before installation.
