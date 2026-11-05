# ui-checks
- What: `browser.mjs` `layoutIssues(page)` (controls another element covers, overlapping text, text cut by an overflow box) and
  `contrast(page, selector)` (WCAG ratio, min 4.5 text / 3 non-text) for any web UI, selector-free; run per `qa.matrix` variant.
Needed when: `qa.matrix.viewports` = `*`
- Wiring: `skills/pokey/adapters/ui_checks.mjs` exports both; `browser.mjs` re-exports them (else the stop line).
