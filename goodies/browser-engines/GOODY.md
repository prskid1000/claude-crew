# browser-engines
- What: `browser.engine` chromium | firefox | webkit (or `KIT_BROWSER_ENGINE`) through Playwright, a browser per process.
Needed when (targets.local.json, checked by browser.mjs): `browser.engine` = `chromium` | `firefox` | `webkit`
- Wiring: `skills/pokey/adapters/engine-playwright.mjs` exports `pwPage`; `npm i playwright-core` in skills/pokey.
