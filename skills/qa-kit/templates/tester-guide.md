# Tester guide: <feature / change>

| | |
|---|---|
| Tasks | <task links> |
| Environment | <test environment URL(s), tenant, build / MRs deployed> |
| Logins | <user keys from targets.local.json (never passwords here)> |
| Test data | <existing records to use, or how to create them> |

## What changed
<one paragraph in user terms; what is new, what must not change>

## Checks
Check ids are referenced by QA results and bug tasks: keep them stable.

### T1 — <screen / area>
**Steps:**
1. <step>
2. <step>

**Expected:** <exact result: values, messages, status codes>

### T2 — <screen / area>
**Steps:**
1. <step>

**Expected:** <result>

## Regression checks
- R1 — <existing behaviour that must still work>

## Out of scope
- <what not to test, and why>
