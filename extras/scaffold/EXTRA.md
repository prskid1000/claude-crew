# scaffold

`kittool.py new agent|skill|workflow|rule|event|config-key|adapter|adr`, `rename <kind> <old> <new>`, `remove <kind> <name>`: a part
with its _manifest entry, Router / Events row and a test stub, in one step.
Needed when: adding, renaming or removing a kit part by script instead of by hand.
Wiring: `kittool.py` loads `skills/orchestrate/kittool_scaffold.py` (commands new, rename, remove).
