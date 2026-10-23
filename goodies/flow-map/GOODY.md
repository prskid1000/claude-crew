# flow-map

The interactive kit-flow page (`kitbag.py flow [--open] [--public] [--out <file>]`) and the FLOW-* lint checks (unbounded loops,
unresolved commands, unhandled outcomes, dead ends).
Needed when: you want the page, or the flow checks gating kit commits; the GitHub Pages workflow installs it itself.
Wiring: `kitbag.py` loads `skills/bossy/kitbag_flow.py` (command `flow`, a lint hook); the page goes to `<runtime>/cache/kit-flow.html`.
