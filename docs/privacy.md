# Privacy

Uso reads the current user's Codex access token and selected account ID from
`~/.codex/auth.json` (or the configured `CODEX_HOME`). It sends that token
only as authorization to `https://chatgpt.com/backend-api/wham/usage`
and `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`
to request that account's usage limits and reset expiry dates. The account ID is
sent in the `ChatGPT-Account-Id` header to those same endpoints. It does not refresh Codex credentials.

When the live request fails, it opens `logs_2.sqlite` in the same Codex
directory read-only and reads the most recent compatible rate-limit event.
It keeps the last successful snapshot in memory while running.

Uso has no analytics, advertising, crash reporting, or developer-operated
server. It does not display or log credentials. Renewed Claude credentials are saved
back to the source store as described below. HTTP
requests use an ephemeral session without a persistent response cache.
No credentials or Codex history are bundled in the distributed app.

OpenAI processes the authenticated usage request under its own policies.
Uso is independent software, not affiliated with or endorsed by OpenAI.

For Claude, Uso reads the existing Claude Code OAuth access token from the
`Claude Code-credentials` macOS Keychain entry or
`~/.claude/.credentials.json`, selecting the valid credential document with the
latest expiry when both are present. It sends that token only to
`https://api.anthropic.com/api/oauth/usage` to read subscription usage.
When a token expires, Uso sends the existing refresh token only to
`https://platform.claude.com/v1/oauth/token`. It saves the renewed tokens
back to the same Keychain entry or credential file, preserving other fields.
Tokens travel to the system Keychain helper over stdin, not process arguments.
Anthropic processes these requests under its own policies. Ring visibility choices are saved locally
in UserDefaults.
