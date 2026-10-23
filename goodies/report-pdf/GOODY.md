# report-pdf
- What: `reports.type: "pdf"`: `devtools.py doc` prints the HTML to a PDF with a headless Chrome / Chromium / Edge, kept like markdown.
- Config: `reports.type: "pdf"`; optional `reports.pdfCommand` (`{in}` `{out}`) instead of a browser.
Needed when: `reports.type` = `pdf`
- Wiring: `skills/crafty/adapters/report_pdf.py`, loaded by devtools.py's plugin registry. Test: `devtools.py selftest`.
