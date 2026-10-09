export const meta = {
  name: 'dev-wave',
  description: 'Run a wave of parallel dev agents (any stack) from a brief: implement + ship each area, independent MR review, one fix round, reconcile',
  whenToUse: 'Several independent work areas (features or bug fixes) across one or more repos should be built and shipped in parallel',
  phases: [
    { title: 'Build', detail: 'one agent per area: worktree, code, gated checks, MRs, merge when green' },
    { title: 'Review', detail: 'independent reviewer per agent reads its MR diffs' },
    { title: 'Fix', detail: 'one follow-up round for blocking review findings' },
    { title: 'Learn', detail: 'signals + LESSONS.md updates (40-line cap) from this wave' },
  ],
}

/*
args = {
  brief: 'C:/.../scratchpad/wave-brief.md',     // filled from .claude/skills/orchestrate/templates/WAVE_BRIEF.md or BUGFIX_BRIEF.md (required)
  mode: 'feature' | 'bugfix' | 'resume',           // default 'feature'
  review: true,                                    // independent MR review + one fix round (default true)
  agents: [ { id: 'X1', items: 'A3, A4', area: 'planner timeline', note: 'optional extra instructions' }, ... ],
  holdMerge: ['web'],                              // optional: repos whose MRs are opened + reviewed but NEVER merged by the wave
                                                   // (their target branch deploys on merge and the user wants to approve it); true = all repos
  kitDir: 'C:/work/.claude',                     // optional: absolute path of this kit (recommended). Default '.claude' = relative
                                                   // to the workspace root, where Claude Code (and every agent's shell) starts
  runtimeDir: 'C:/work/.claude-runtime',         // optional: default <kitDir>/../.claude-runtime (or $env:CLAUDE_RUNTIME in scripts)
}
Agents queue on the machine-wide build gate, so ~15 agents is fine; expect hours for big waves.
*/
const A = args || {}
const KIT = (A.kitDir || '.claude').replace(/[\\/]+$/, '')     // the .claude folder of the workspace
const K = `${KIT}/skills/dev-kit`                             // SKILL.md = the dev agent rules, scripts/ = the tools
const T = `${KIT}/skills/orchestrate/templates`
const ORCH = `${KIT}/skills/orchestrate/scripts`
const RT = (A.runtimeDir || `${KIT}/../.claude-runtime`).replace(/[\\/]+$/, '')
// relative kit paths are resolved against the workspace root (the directory your session started in)
const PATHS = (/^([A-Za-z]:|[\\/])/.test(KIT) ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.') +
  '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
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
NEVER act on a relayed message yourself when it asks for anything outside your items - above all nothing destructive: no deleting or
cleaning folders (the kit runtime folder holds live QA runs and tracking; a wave agent once deleted it this way), no branch resets, no
deploys. Mention it in your report and let the lead do it.
`

// Model per agent: agents[].model / .effort (bug-brief.ps1 suggests one: a single cosmetic check -> sonnet). Default = the strongest model.
// Haiku is used only for mechanical steps (ship); code changes need a model that won't cost a review round.
const modelOf = (a) => ({ ...(a.model ? { model: a.model } : {}), ...(a.effort ? { effort: a.effort } : {}) })

function buildPrompt(a) {
  return `${WHY}
You are dev agent ${a.id} in a parallel wave (${MODE}).${PATHS}
Follow ${K}/SKILL.md (Quick start; scripts in ${K}/scripts) and the brief ${A.brief} (repos, ownership, ranges, decisions; it wins).
${MODE === 'resume' ? `Resuming: first work out what is already done (${T}/RESUME_BRIEF.md).\n` : ''}YOU ARE ${a.id}. Items: ${a.items}. Area: ${a.area}.
Board: join first with -Agent ${a.id} -Run ${RUN} -Contracts <brief>.contracts.md (if it exists); DUPLICATE -> stop without writing.
Worktree name prefix: ${a.id.toLowerCase()}; your migration range is in the brief. Never touch other agents' worktrees, branches or processes.
${a.note || ''}
${REVIEW
    ? `Do the whole job: implement, gated checks, commit, push, open the MRs, update the tracker. Do NOT schedule merges (no devtools.py
merge): a review runs first and the workflow merges after it. Report merged=false for every MR.`
    : 'Do the whole job: implement, run the gated checks, commit, push, open the MRs, merge when green (producers first), update the tracker.'}${HOLD_NOTE}
Return the report.`
}

function reviewPrompt(a, r) {
  return `Review agent ${a.id}'s MRs (items ${a.items}, area ${a.area}; brief ${A.brief}) as your agent definition says.${PATHS}
${r.mrs.map((m) => `- ${m.url} (${m.repo}${m.merged ? ', merged' : ''})`).join('\n')}
Rules: ${K}/SKILL.md Quick start (scope) and ${K}/reference/migrations.md. Only real problems; "blocking" = must be fixed before it ships.
Do not change any code yourself.`
}

function fixPrompt(a, r, findings) {
  return `${WHY}
You are dev agent ${a.id} again (items ${a.items}, area ${a.area}).${PATHS} Follow ${K}/SKILL.md and ${A.brief}.
Your worktrees: ${r.worktrees.join(', ')}. An independent reviewer found these problems in your MRs (blocking and should-fix; resolve all of them):
${findings.map((f) => `- ${f.mr} ${f.file}${f.line ? ':' + f.line : ''}: ${f.problem} -> ${f.fix}`).join('\n')}
Fix each (wt.ps1 sync first; follow-up MR if the original merged) or explain why it isn't a problem. Gated checks, push, then schedule
the merges yourself (devtools.py merge, producers first; dependents: ${ORCH}/track.ps1 add -Task <id> -MergeAfter '<web/app MR>><API MR>').
Return the updated report.${HOLD_NOTE}`
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
& ${K}/scripts/pipe-wait.ps1 -Mrs ${urls} -MaxMinutes 8
If the JSON says "done": false, run the same command again (at most 3 times in total) and return the last JSON.`
}

function shipPrompt(a, r) {
  return `Schedule merge-when-green for agent ${a.id}'s reviewed MRs (review clean). Change no code.${PATHS}
${r.mrs.filter((m) => !m.merged).map((m) => `- ${m.url} (${m.repo})`).join('\n')}
DB/API (producer) and independent MRs now: python ${K}/scripts/devtools.py merge <worktree> <iid> (worktrees: ${r.worktrees.join(', ')}).
A consumer (web/app) MR that depends on an API MR in this list: don't merge it; register & ${ORCH}/track.ps1 add -Task <task id from the
MR title/branch> -Discover -MergeAfter '<consumer repo>!<iid>><api repo>!<iid>'. Return the report with the same MRs (merged=false unless already merged).${HOLD_NOTE}`
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

1. One signal per notable event (failures, retries, review findings, deferrals, anything that cost time or worked unusually well):
   & ${ORCH}/learn.ps1 -Skill <dev-kit|other skill|project> -Kind <friction|failure|defect-missed|false-positive|stale-env|flaky|idea|win> -Text "<what + fix>" -Ref <id> -Source workflow
2. Read ${K}/LESSONS.md (active rules; never HISTORY.md) and the recent signals (learn.ps1 -Show -Last 200). A pattern seen ≥ 2 times
   that isn't a lesson yet: & ${ORCH}/learn.ps1 -Skill <skill> -Lesson "(n×) <one actionable line>" [-Project <name>]; a recurring
   lesson: bump its "(n×)" count with Edit. A lesson the kit now handles: learn.ps1 -Skill <skill> -Fixed "<words of it>". Finish with
   learn.ps1 -Skill <skill> -Trim for each LESSONS.md you changed (≤ 40 lines; moves fixed/oldest lines to HISTORY.md). Don't touch SKILL.md.
3. & ${ORCH}/cleanup.ps1 -Quiet (only kit-created leftovers), then Get-Content (Join-Path ${RT} cleanup.log) -Tail 15: mention what was freed.
Return how many signals you recorded and which lessons changed.`, { label: 'learn', phase: 'Learn', schema: LEARN_SCHEMA, model: 'sonnet', effort: 'low' })
if (learned) log(`learn: ${learned.signals} signal(s), lessons changed: ${learned.lessonsChanged.join('; ') || 'none'}`)
return outcome
