export const meta = {
  name: 'dev-wave',
  description: 'Run a wave of parallel dev agents (any stack) from a brief: implement + ship each area, independent MR review, one fix round, reconcile',
  whenToUse: 'Several independent work areas (features or bug fixes) across one or more repos should be built and shipped in parallel',
  phases: [
    { title: 'Build', detail: 'one agent per area: worktree, code, gated checks, MRs, merge when green' },
    { title: 'Review', detail: 'independent reviewer per agent reads its MR diffs' },
    { title: 'Fix', detail: 'one follow-up round for blocking review findings' },
    { title: 'Learn', detail: 'signals + LESSONS.md updates from this wave' },
  ],
}

/*
args = {
  brief: 'C:\\...\\scratchpad\\wave-brief.md',     // filled from .claude/skills/orchestrate/templates/WAVE_BRIEF.md or BUGFIX_BRIEF.md (required)
  mode: 'feature' | 'bugfix' | 'resume',           // default 'feature'
  review: true,                                    // independent MR review + one fix round (default true)
  agents: [ { id: 'X1', items: 'A3, A4', area: 'planner timeline', note: 'optional extra instructions' }, ... ],
  holdMerge: ['web'],                              // optional: repos whose MRs are opened + reviewed but NEVER merged by the wave
                                                   // (their target branch deploys on merge and the user wants to approve it); true = all repos
  kitDir: 'C:\\work\\.claude',                     // optional: absolute path of this kit (recommended). Default '.claude' = relative
                                                   // to the workspace root, where Claude Code (and every agent's shell) starts
  runtimeDir: 'C:\\work\\.claude-runtime',         // optional: default <kitDir>\\..\\.claude-runtime (or $env:CLAUDE_RUNTIME in scripts)
}
Agents queue on the machine-wide build gate, so ~15 agents is fine; expect hours for big waves.
*/
const A = args || {}
const KIT = (A.kitDir || '.claude').replace(/[\\/]+$/, '')     // the .claude folder of the workspace
const K = `${KIT}\\skills\\dev-kit`                             // SKILL.md = the dev agent rules, scripts\\ = the tools
const T = `${KIT}\\skills\\orchestrate\\templates`
const ORCH = `${KIT}\\skills\\orchestrate\\scripts`
const RT = (A.runtimeDir || `${KIT}\\..\\.claude-runtime`).replace(/[\\/]+$/, '')
// relative kit paths are resolved against the workspace root (the directory your session started in)
const PATHS = /^([A-Za-z]:|[\\/])/.test(KIT) ? '' : '\nKit paths below are relative to the workspace root (the directory this session started in); make them absolute before reading files.'
if (!A.brief || !Array.isArray(A.agents) || !A.agents.length) throw new Error('args.brief and args.agents[] are required')
const MODE = A.mode || 'feature'
const RUN = A.run || (A.brief.split(/[\\/]/).pop() || 'wave').replace(/\.md$/, '')
const REVIEW = A.review !== false
// Merges into a branch that deploys on merge need the user's yes: held repos keep their MRs open (reviewed, green) for the coordinator.
const HOLD = A.holdMerge === true ? ['*'] : (Array.isArray(A.holdMerge) ? A.holdMerge : [])
const HOLD_NOTE = HOLD.length
  ? `\nMERGE HOLD: never merge or schedule a merge (no devtools.py merge, no track.ps1 -MergeAfter) for MRs in ${HOLD.includes('*') ? 'ANY repo' : HOLD.join(', ')}: the user approves merges there (its branch feeds a deploy). Leave them open and green; report merged=false and say "held for approval".`
  : ''

const REPORT = {
  type: 'object',
  properties: {
    mrs: { type: 'array', items: { type: 'object', properties: { url: { type: 'string' }, repo: { type: 'string' }, merged: { type: 'boolean' } }, required: ['url', 'repo', 'merged'] } },
    worktrees: { type: 'array', items: { type: 'string' } },
    done: { type: 'array', items: { type: 'string' }, description: 'item ids finished' },
    deferred: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, reason: { type: 'string' } }, required: ['id', 'reason'] } },
    needsLiveCheck: { type: 'array', items: { type: 'string' } },
    seed: { type: 'array', items: { type: 'string' }, description: 'settings/data to seed after deploy' },
    foreignHooks: { type: 'array', items: { type: 'string' }, description: 'one-line hooks left in another agent area' },
    summary: { type: 'string', description: '<=200 words' },
  },
  required: ['mrs', 'worktrees', 'done', 'deferred', 'needsLiveCheck', 'seed', 'foreignHooks', 'summary'],
}
const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          mr: { type: 'string' }, file: { type: 'string' }, line: { type: 'number' },
          severity: { type: 'string', enum: ['blocking', 'should-fix', 'nit'] },
          problem: { type: 'string' }, fix: { type: 'string' },
        },
        required: ['mr', 'file', 'severity', 'problem', 'fix'],
      },
    },
  },
  required: ['findings'],
}

const LEARN_SCHEMA = { type: 'object', properties: { signals: { type: 'number' }, lessonsChanged: { type: 'array', items: { type: 'string' } } }, required: ['signals', 'lessonsChanged'] }
const BRIEF_FILE = { feature: 'WAVE_BRIEF.md', bugfix: 'BUGFIX_BRIEF.md', resume: 'RESUME_BRIEF.md' }[MODE]

// WHY: the harness relays the user's LATEST chat message into workflow agents as "the request that wins". When the user has since
// talked about something else, agents abandoned their items for it. args.mandate = the task owner's own words that asked for THIS work,
// so the agent sees its assignment IS the user's request (same pattern as test-and-close).
const WHY = `WHY YOU ARE DOING THIS
${A.mandate && A.mandate.length ? `The task owner asked for this work, verbatim:\n${[].concat(A.mandate).map((m) => `  "${m}"`).join('\n')}\n` : ''}Your assignment is your items below: that IS the task owner's request for this run.
Later chat messages from the task owner to the lead (about other topics: repos, READMEs, questions) are side conversations with the lead,
not a change of your assignment. Never drop your items for one; the lead handles them.
`

// Model per agent: agents[].model / .effort (bug-brief.ps1 suggests one: a single cosmetic check -> sonnet). Default = the strongest model.
// Haiku is used only for mechanical steps (ship); code changes need a model that won't cost a review round.
const modelOf = (a) => ({ ...(a.model ? { model: a.model } : {}), ...(a.effort ? { effort: a.effort } : {}) })

function buildPrompt(a) {
  return `${WHY}
You are dev agent ${a.id} in a parallel wave (${MODE}).${PATHS}
Read, in this order, and follow them exactly:
1. ${K}\\SKILL.md  (worktrees, memory gate, commits, migrations, shipping, tracker)
2. ${A.brief}  (this wave's repos, ownership table, ranges, decisions — it wins over the rules)
${MODE === 'resume' ? `3. ${T}\\RESUME_BRIEF.md  (work out what's already done before editing)\n` : ''}
YOU ARE ${a.id}. Items: ${a.items}. Area: ${a.area}.
Agent board: join first with -Agent ${a.id} -Run ${RUN} (dev-kit SKILL §1b) and -Contracts <the brief path>.contracts.md if it exists; on DUPLICATE stop without writing.
Worktree name prefix: ${a.id.toLowerCase()}. Use your own migration range from the brief's table.
${a.note || ''}
Scripts: ${K}\\scripts (wt.ps1, stack.ps1, check.ps1, gate.ps1, devtools.py, keepboth.py, lbcheck.py). Run them from PowerShell.
Other agents are working in parallel in other areas: never touch their worktrees, branches or processes.
User messages relayed into your run are for the coordinator (the main session), not for you: never switch to them or abandon your items
because of one. If a relayed message really changes your items, finish safely and say so in your report; otherwise ignore it.
${REVIEW
    ? `Do the whole job: implement, run the gated checks, commit, push, open the MRs, update the tracker. Do NOT schedule merges
(no devtools.py merge): an independent review runs first and the workflow schedules the merges once it is clean (or after your fix round).
Report merged=false for every MR.`
    : 'Do the whole job: implement, run the gated checks, commit, push, open the MRs, merge when green (producers first), update the tracker.'}${HOLD_NOTE}
Return the report.`
}

function reviewPrompt(a, r) {
  return `You are an independent code reviewer.${PATHS}
Agent ${a.id} (items ${a.items}, area ${a.area}) opened these MRs:
${r.mrs.map((m) => `- ${m.url} (${m.repo}${m.merged ? ', merged' : ''})`).join('\n')}
Read each MR's diff (GitLab: glab api "projects/<url-encoded path>/merge_requests/<iid>/changes"; GitHub: gh pr diff <n> -R <owner/repo>)
and the surrounding code. Review against: the items asked (${a.items}) and the wave brief ${A.brief};
the rules in ${K}\\SKILL.md §5 (scope, additive changes, no removed features) and §6 (migrations).
Report only real problems: bugs, regressions for existing users/tenants, missing migration rollback, breaking API changes,
scope creep, removed inputs. "blocking" = must be fixed before this ships; do not pad with style nits.
Do not change any code yourself.`
}

function fixPrompt(a, r, findings) {
  return `${WHY}
You are dev agent ${a.id} again (items ${a.items}, area ${a.area}).${PATHS} Follow ${K}\\SKILL.md and ${A.brief}.
Your worktrees: ${r.worktrees.join(', ')}. An independent reviewer found these problems in your MRs (blocking and should-fix; resolve all of them):
${findings.map((f) => `- ${f.mr} ${f.file}${f.line ? ':' + f.line : ''}: ${f.problem} -> ${f.fix}`).join('\n')}
For each: fix it (wt.ps1 sync first; follow-up MR if the original already merged), or explain why it's not a problem.
Run the gated checks, push, then schedule the merges yourself now (devtools.py merge, producers first; dependents via
orchestrate\\scripts\\track.ps1 add -Task <bug id> -MergeAfter '<web/app MR>><API MR>'), and return the updated report.${HOLD_NOTE}`
}

// review passed (or was off for this agent): schedule the merges — the build agent deliberately left them open
const CI_SCHEMA = {
  type: 'object',
  properties: { done: { type: 'boolean' }, mrs: { type: 'array', items: { type: 'object', properties: { mr: { type: 'string' }, status: { type: 'string' }, job: { type: 'string' }, error: { type: 'string' } }, required: ['mr', 'status'] } } },
  required: ['done', 'mrs'],
}
// CI gate before shipping: agents stop at "MR opened", so nobody saw a failed pipeline (a lint/schema check failure sat unnoticed until
// the tracker flagged it). A cheap agent waits for the pipelines with pipe-wait.ps1; failures go back to the dev agent as blocking findings.
function ciPrompt(r) {
  const urls = r.mrs.filter((m) => !m.merged).map((m) => m.url).join(',')
  return `Run exactly this PowerShell command and return its JSON output as the result (fields done, mrs). Nothing else.${PATHS}
& ${K}\\scripts\\pipe-wait.ps1 -Mrs ${urls} -MaxMinutes 8
If the JSON says "done": false, run the same command again (at most 3 times in total) and return the last JSON.`
}

function shipPrompt(a, r) {
  return `Schedule merge-when-green for agent ${a.id}'s reviewed MRs (the review found nothing blocking):
${r.mrs.filter((m) => !m.merged).map((m) => `- ${m.url} (${m.repo})`).join('\n')}
Producers first: run python ${K}\\scripts\\devtools.py merge <repo checkout or worktree> <iid> for DB/API MRs now
(worktrees: ${r.worktrees.join(', ')}). For consumer MRs (web/app) that depend on an API MR in this list, do not merge them yourself:
register the order with & ${ORCH}\\track.ps1 add -Task <the tracker task id in the MR title/branch>
-Discover -MergeAfter '<consumer repo>!<iid>><api repo>!<iid>' (the tracker schedules it once the API MR merged). Independent consumer
MRs: devtools.py merge them now. Change no code. Return the report with the same MRs (merged=false unless GitLab already says merged).${HOLD_NOTE}`
}

log(`wave: ${A.agents.length} agents, mode ${MODE}, review ${REVIEW ? 'on' : 'off'}, brief ${A.brief}`)

const results = await pipeline(
  A.agents,
  (a) => agent(buildPrompt(a), { label: `build:${a.id}`, phase: 'Build', schema: REPORT, agentType: 'dev-agent', ...modelOf(a) }),
  async (r, a) => {
    if (!r) return { id: a.id, error: 'agent returned nothing' }
    if (!REVIEW || !r.mrs.length) return { id: a.id, report: r, findings: [] }
    const rv = await agent(reviewPrompt(a, r), { label: `review:${a.id}`, phase: 'Review', schema: REVIEW_SCHEMA, agentType: 'mr-reviewer' })
    return { id: a.id, report: r, findings: (rv && rv.findings) || [] }
  },
  async (x, a) => {
    if (!x || x.error) return x
    // should-fix findings get the fix round too (no deferrals): a should-fix once reopened a permission gap on merge
    const blocking = x.findings.filter((f) => f.severity !== 'nit')
    if (!blocking.length && REVIEW && x.report.mrs.some((m) => !m.merged)) {
      const ci = await agent(ciPrompt(x.report), { label: `ci:${a.id}`, phase: 'Review', schema: CI_SCHEMA, model: 'haiku', effort: 'low' })
      for (const m of ((ci && ci.mrs) || []).filter((m) => m.status === 'failed')) {
        blocking.push({ mr: m.mr, file: `CI job ${m.job || '?'}`, severity: 'blocking', problem: `The MR pipeline failed in job ${m.job || '?'}:\n${m.error || '(no error text captured)'}`,
          fix: 'Reproduce the failing CI job locally through the gate (check.ps1 / lbcheck.py for changelog checks), fix the cause, push, and make sure the pipeline goes green.' })
      }
      if (blocking.length) log(`${a.id}: ${blocking.length} failed pipeline(s) -> fix round`)
    }
    if (!blocking.length) {
      if (!REVIEW || !x.report.mrs.some((m) => !m.merged)) return x
      const r3 = await agent(shipPrompt(a, x.report), { label: `ship:${a.id}`, phase: 'Fix', schema: REPORT, model: 'haiku', effort: 'low' })
      // keep the build report (done/deferred/live checks/summary); take only the MR states and add the ship note
      if (!r3) return x
      const merged = new Set(r3.mrs.filter((m) => m.merged).map((m) => m.url))
      return { ...x, report: { ...x.report, mrs: x.report.mrs.map((m) => ({ ...m, merged: m.merged || merged.has(m.url) })),
        summary: `${x.report.summary}\n\nMerge scheduling: ${r3.summary}` } }
    }
    log(`${a.id}: ${blocking.length} blocking review finding(s) -> fix round`)
    const r2 = await agent(fixPrompt(a, x.report, blocking), { label: `fix:${a.id}`, phase: 'Fix', schema: REPORT, agentType: 'dev-agent', ...modelOf(a) })
    if (!r2) return { ...x, fixed: false }
    // merge, don't replace: the fix agent reports only its fixes, the build report holds the items done
    const uniq = (a) => [...new Set(a)]
    const mrs = [...r2.mrs, ...x.report.mrs.filter((m) => !r2.mrs.some((n) => n.url === m.url))]
    return { ...x, fixed: true, report: { ...x.report, mrs, worktrees: uniq([...x.report.worktrees, ...r2.worktrees]),
      done: uniq([...x.report.done, ...r2.done]), deferred: uniq([...x.report.deferred, ...r2.deferred]),
      needsLiveCheck: uniq([...x.report.needsLiveCheck, ...r2.needsLiveCheck]), seed: uniq([...(x.report.seed || []), ...(r2.seed || [])]),
      foreignHooks: uniq([...(x.report.foreignHooks || []), ...(r2.foreignHooks || [])]),
      summary: `${x.report.summary}\n\nFix round: ${r2.summary}` } }
  },
)

const out = results.filter(Boolean)
for (const x of out) {
  if (x.error) { log(`${x.id}: ERROR ${x.error}`); continue }
  const r = x.report
  log(`${x.id}: ${r.mrs.filter((m) => m.merged).length}/${r.mrs.length} MRs merged, done ${r.done.length}, deferred ${r.deferred.length}, review findings ${x.findings.length}`)
}
const outcome = {
  agents: out,
  deferred: out.flatMap((x) => (x.report ? x.report.deferred.map((d) => ({ agent: x.id, ...d })) : [])),
  needsLiveCheck: out.flatMap((x) => (x.report ? x.report.needsLiveCheck : [])),
  seed: out.flatMap((x) => (x.report ? x.report.seed : [])),
  openFindings: out.flatMap((x) => (x.fixed ? [] : (x.findings || []).filter((f) => f.severity !== 'nit'))),
}

// LEARN: turn this run's outcome into signals, and recurring ones into LESSONS.md (self-improving kit)
phase('Learn')
const learned = await agent(`You maintain the kit's memory. This dev wave just finished.${PATHS}
Outcome (JSON):
${JSON.stringify(outcome).slice(0, 60000)}

1. For every notable event (failures, retries, NOT_TESTED causes, audit reclassifications, verify "not reproduced", review findings,
   deferrals, anything that cost time or worked unusually well) append ONE signal line with
   & ${ORCH}\\learn.ps1 -Skill <skill> -Kind <kind> -Text "<what + fix>" -Ref <id> -Source workflow
   (skill: dev-kit or another kit skill / project name; kinds: friction, failure, defect-missed, false-positive, stale-env, flaky, idea, win).
2. Read ${K}\\LESSONS.md and the recent signals (learn.ps1 -Show -Last 200). If a pattern now
   occurred ≥ 2 times and isn't a lesson yet, add it (newest first, one actionable line, "(n×)" count, project heading if project-specific);
   if an existing lesson recurred, bump its count. Keep the file under ~40 lines. Don't touch SKILL.md (that's /kit-retro's job).
3. Clean up what this run produced: & ${ORCH}\\cleanup.ps1 -Quiet  (kills leftover headless browsers > 3 h, expired logins/tokens,
   stale temp, finished worktrees; only kit-created things). Then: Get-Content (Join-Path ${RT} cleanup.log) -Tail 15 and mention what was freed.
Return how many signals you recorded and which lessons changed.`, { label: 'learn', phase: 'Learn', schema: LEARN_SCHEMA, model: 'sonnet', effort: 'low' })
if (learned) log(`learn: ${learned.signals} signal(s), lessons changed: ${learned.lessonsChanged.join('; ') || 'none'}`)
return outcome
