# report-confluence
- What: `reports.type: "confluence"`: `devtools.py doc` publishes a Confluence page (storage format) under `reports.parent`.
- Config: `reports.type`, `reports.space`, `reports.parent`; env `CONFLUENCE_URL`, `CONFLUENCE_TOKEN` (+ `CONFLUENCE_EMAIL` = basic auth).
Needed when: `reports.type` = `confluence`
- Wiring: `skills/crafty/adapters/report_confluence.py`, loaded by devtools.py's plugin registry. Test: `devtools.py selftest`.
