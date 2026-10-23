# report-notion
- What: `reports.type: "notion"`: `devtools.py doc` publishes a Notion child page (headings, paragraphs, bullets, code; 100 blocks per call).
- Config: `reports.type`, `reports.parent` (a page shared with the integration); env `NOTION_TOKEN`.
Needed when: `reports.type` = `notion`
- Wiring: `skills/crafty/adapters/report_notion.py`, loaded by devtools.py's plugin registry. Test: `devtools.py selftest`.
