# web-login-types
- What: `webLogin.type` sso-steps, script, storageState, and `{totp}` codes (users[as][2] = TOTP secret).
Needed when (targets.local.json, checked by browser.mjs): `targets.*.webLogin.type` = `sso-steps` | `script` | `storageState`
- Wiring: `skills/pokey/adapters/web-login.mjs` exports `login` and `totp`; browser.mjs passes its helpers.
