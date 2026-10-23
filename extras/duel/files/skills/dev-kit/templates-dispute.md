# Dispute template (extra duel; moved out of skills/dev-kit/templates.md)

## Dispute (`orch.ps1 board dispute`; one per disagreement)
Opened by the agent that disagrees; the other answers ONCE with its evidence; agreement -> both record it and continue; still split
after 2 rounds -> `decide ask` with both positions side by side (the owner judges; only that item waits); every verdict is a
learn signal (/tidy turns repeats into rules).
```markdown
## DISPUTE <id> (<from> vs <to>, item <item>)
Claim: <what is wrong, one line> · Evidence: <files, runs, numbers, file:line> · Proposed: <the outcome you want>
Answer (<to>): <agree | disagree> — <its evidence>
```
