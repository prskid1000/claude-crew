# report-gdocs
- What: `reports.type: "gdocs"`: `devtools.py doc` uploads a Google Doc through the gws CLI (Markdown converted to HTML) and
  shares it (`reports.share`: anyone (default) | domain:<domain> | none); `devtools.py evidence` makes a Drive folder with one
  image src per file (qa.ps1 finalize evidence); the styled HTML QA report (colour chips, zebra tables, failure and screenshot
  galleries) that finalize writes as `report.html` and publishes for gdocs.
- Config: `reports.type: "gdocs"` (also the default while gws is on PATH and reports.type is unset); `driveParent` = the Drive
  folder or shared drive. CLI `gws`: resolve it with `shutil.which()` (Windows shim), check auth before use, never log in headlessly.
Needed when: `reports.type` = `gdocs` (unset with gws on PATH also means gdocs: set reports.type or add the extra)
- Wiring: `skills/dev-kit/adapters/report_gdocs.py`, loaded by devtools.py's plugin registry; `skills/qa-kit/adapters/report_html.ps1`
  (`Build-QaReport`, qa.ps1 loads adapters/). Tests: `tests.ps1` here.
