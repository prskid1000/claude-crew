# report-gdocs
- What: `reports.type: "gdocs"`: `devtools.py doc` uploads a Google Doc through the gws CLI (Markdown converted to HTML) and
  shares it (`reports.share`: anyone (default) | domain:<domain> | none); `devtools.py evidence` makes a Drive folder with one
  image src per file (qa.ps1 finalize evidence).
- Config: `reports.type: "gdocs"` (also the default while gws is on PATH and reports.type is unset); `driveParent` = the Drive
  folder or shared drive.
Needed when: `reports.type` = `gdocs`
- Wiring: `skills/dev-kit/adapters/report_gdocs.py`, loaded by devtools.py's plugin registry. Tests: `tests.ps1` here.
