# api-auth
- What: `qa.ps1 api` auth types basic, query, cookie (+ CSRF), token, command (HMAC / SigV4 signer), client cert, refresh tokens.
Needed when (targets.local.json, checked by qa.ps1 api): `targets.*.auth.type` = `basic` | `query` | `cookie` | `token` | `command`
- Wiring: `skills/qa-kit/adapters/api_auth.ps1` defines `Invoke-ApiExtra` (the full api verb); core `Invoke-Api` hands such calls to it.
