# Tester guide: <feature / change>

| | |
|---|---|
| Tasks | <task links> |
| Environment | <test environment URL(s), tenant, build / MRs deployed> |
| Logins | <user keys from targets.local.json (never passwords here)> |
| Test data | <existing records to use, or how to create them> |

## What changed
<one paragraph in user terms; what is new, what must not change>

## Before you start / Feature switches
Check every switch ON before testing (per tenant / account you test with). Restore anything you changed afterwards.
A gate you cannot switch yourself (environment config, licence, a role you cannot grant) = the checks behind it are NOT_TESTED, not FAIL.

| Setting or role | Where | Value now | How to switch it on | Restore after |
|---|---|---|---|---|
| <setting / role / feature flag> | <screen or endpoint, tenant> | <on/off> | <steps> | <yes/no> |

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
