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

## Environment and data setup
Every step a check depends on, in order (the dev agent fills it from its report's seed and needsLiveCheck; delete rows that do
not apply). A step you cannot do = NOT_TESTED (say which), not FAIL.

| Step | Why | How | Verify it took |
|---|---|---|---|
| APK commit (app checks) | the fix must be in the build the phone runs | <app build holding commit/MR, e.g. `deployed.ps1 -Mrs <repo>!<iid>`> | <commit shown by `phone.ps1 acquire` / the app's version> |
| Device clock or time step | <date / shift / day-boundary behaviour> | <set the device or server time to …, or wait until …> | <the date/time the screen shows> |
| Role and screen permissions | <a screen switched off for the test role hides the change (menu entry missing, 403)> | <role / screen switches to turn on for the test user, and where> | <the screen opens from the menu as the test user> |
| Seed records and profile flags | <the records and user/tenant flags the checks need> | <API calls or screens; prefix created data QA-<CODE>> | <ids / values read back> |
| Reindex / cache refresh | <search or cached data must include the seed> | <job, endpoint or command> | <the seed appears in search / the list> |

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
