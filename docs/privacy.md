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
server. It does not display or log credentials. Codex credentials are never modified. HTTP
requests use an ephemeral session without a persistent response cache.
No credentials or Codex history are bundled in the distributed app.

OpenAI processes the authenticated usage request under its own policies.
Uso is independent software, not affiliated with or endorsed by OpenAI.

For Claude, Uso reads the existing Claude Code OAuth access token
from the `Claude Code-credentials` macOS Keychain entry, or from
`~/.claude/.credentials.json` when there is no Keychain entry. An inaccessible
Keychain is treated as temporarily unavailable rather than using a stale file.
It sends the access token to `https://api.anthropic.com/api/oauth/usage` to read
subscription usage. It never renews tokens or writes to the credential store.
When the access token has expired or is rejected, Uso runs Claude Code once
(`claude -p` with Haiku, no tools, no saved session) so Claude Code renews its
own login; this is a minimal inference request on your subscription, made at
most every 15 minutes and only while the token is expired. Anthropic processes
these requests under its own policies.
Ring visibility choices are saved locally in UserDefaults.
The reset-notification preference and last successful reading for each provider
are also saved locally in UserDefaults. Claude account/organization identifiers
are read from `~/.claude.json` to keep its baseline stable across token renewals;
when unavailable, a hash of the current access token scopes the baseline instead.
The reading contains a hashed account identifier, plan, remaining allowance,
Codex reset-credit IDs/count, and observation time, solely to detect changes
without repeating alerts across launches. It is not used to display cached
usage. Notifications contain changed allowance or the number of newly available
reset credits; credentials and account identifiers are never included.

When you choose Check for Updates…, Sparkle requests the signed update feed and,
if you choose to install, the update archive from GitHub's release asset service.
Requests may follow GitHub's redirects to its asset CDN. GitHub receives normal
network request information such as your IP address and Uso's version/User-Agent.
Codex and Claude credentials are never sent with update requests. Background
update checks, unattended installation, and Sparkle system profiling are disabled.
Sparkle stores downloaded update data temporarily and verifies the signed feed,
archive signature, and application signature before installation.
