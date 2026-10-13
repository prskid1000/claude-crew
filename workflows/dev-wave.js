export const meta = {
  name: 'dev-wave',
  description: 'Run a wave of parallel dev agents (any stack) from a brief: implement + ship each area, independent MR review, one fix round, reconcile',
  whenToUse: 'Coding with more than 2 work items or tasks, one item spanning 2+ repos, or one large item (new feature or epic, migrations, many screens)',
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
  review: true,                                    // independent MR review + one fix round (default true); false = none;
                                                   // 'auto' = skip it for an agent whose MRs change < 40 lines in total and touch no
                                                   // migration / security-sensitive file (the build agent reports changedLines + changedFiles)
  learn: true,                                     // learn step (signals + lessons) at the end (default true); 'auto' = only when the
                                                   // wave had errors, deferrals, review findings or fix rounds (else just a cheap cleanup)
  agents: [ { id: 'X1', items: 'A3, A4', area: 'planner timeline', note: 'optional extra instructions',
              complex: true,               // optional: build/fix on the strongest model (default: sonnet); or list ids in args.complex
              model: 'opus', effort: 'high' } ],   // optional: explicit build/fix model/effort (wins over complex)
  complex: ['X1'],                                 // optional: agent ids whose items the brief marks complex
  models: { build: 'sonnet', review: 'sonnet', ci: 'haiku', ship: 'haiku', learn: 'haiku', complex: '' },  // optional stage overrides
                                                   // ('' = no model option = the session's default, i.e. the strongest)
  holdMerge: ['web'],                              // optional: repos whose MRs are opened + reviewed but NEVER merged by the wave
                                                   // (their target branch deploys on merge and the user wants to approve it); true = all repos
  kitDir: 'C:/work/.claude',                     // optional: absolute path of this kit (recommended). Default '.claude' = relative
                                                   // to the workspace root, where Claude Code (and every agent's shell) starts
  runtimeDir: 'C:/work/.claude/.claude-runtime', // optional: default <kitDir>/.claude-runtime (scripts: Get-KitPath)
}
Agents queue on the machine-wide build gate, so ~15 agents is fine; expect hours for big waves.
*/
const A = args || {}
const KIT = (A.kitDir || '.claude').replace(/[\\/]+$/, '')     // the .claude folder of the workspace
const K = `${KIT}/skills/dev-kit`                             // SKILL.md = the dev agent rules, scripts/ = the tools
const T = `${KIT}/skills/orchestrate/templates`
const ORCH = `${KIT}/skills/orchestrate/scripts`
const RT = (A.runtimeDir || `${KIT}/.claude-runtime`).replace(/[\\/]+$/, '')
// kit paths by name: the same names and values as skills/dev-kit/scripts/kitpaths.json (kit-lint RUNTIME-MAP keeps them equal)
const KP = {"runtime": {"cleanup-log": "logs/cleanup.log"}, "durable": {}}
const rp = (n) => (n in KP.durable ? `${KIT}/${KP.durable[n]}` : `${RT}/${KP.runtime[n]}`).replace(/\/$/, '')
// relative kit paths are resolved against the workspace root (the directory your session started in)
const PATHS = (/^([A-Za-z]:|[\\/])/.test(KIT) ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.') +
  '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
if (!A.brief || !Array.isArray(A.agents) || !A.agents.length) throw new Error('args.brief and args.agents[] are required')
const MODE = A.mode || 'feature'
if (!A.mandate || !A.mandate.length) log('WARNING: no args.mandate (the task owner words): agents may drop their items for the latest chat message. Pass mandate next time (orchestrate step 3).')
const RUN = A.run || (A.brief.split(/[\\/]/).pop() || 'wave').replace(/\.md$/, '')
const REVIEW = A.review !== false
const REVIEW_AUTO = A.review === 'auto'
const LEARN = A.learn === undefined ? true : A.learn
// review: 'auto' skips the review only for small, low-risk changes; a missing diff report always gets reviewed
const SENSITIVE = /(^|[\\/])(db|migrations?|changelog|liquibase|flyway|alembic)([\\/.]|$)|\.sql$|auth|security|permission|role|acl|passw|secret|token|crypto|oauth|login|session|policy|csrf|cors/i
const smallChange = (r) => Number.isFinite(r.changedLines) && r.changedLines < 40 && Array.isArray(r.changedFiles) && r.changedFiles.length > 0 &&
  !r.changedFiles.some((p) => SENSITIVE.test(p))
// Merges into a branch that deploys on merge need the user's yes: held repos keep their MRs open (reviewed, green) for the coordinator.
const HOLD = A.holdMerge === true ? ['*'] : (Array.isArray(A.holdMerge) ? A.holdMerge : [])
const HOLD_NOTE = HOLD.length
  ? `\nMERGE HOLD: never merge or schedule a merge (no devtools.py merge, no track.ps1 -MergeAfter) for MRs in ${HOLD.includes('*') ? 'ANY repo' : HOLD.join(', ')}: the user approves merges there (its branch feeds a deploy). Leave them open and green; report merged=false and say "held for approval".`
  : ''
// devtools.py merge ends with one status word read back from the host; an agent's own "merged" guess once promoted unmerged work
const MERGE_WORD_NOTE = `Merge results: the LAST line of each devtools.py merge run is one word: MERGED / SCHEDULED / WAIT / CONFLICT / PIPELINE_FAILED /
NOT_MERGED. Report it as that MR's mergeState and set merged=true ONLY for MERGED. WAIT: run the same merge again about 2 minutes
later (at most 3 runs in total), then report the last word - except "waiting for producer <ref>": the producer MR is not merged yet,
do not re-run, report WAIT (track.ps1 merges it after its producer). CONFLICT / PIPELINE_FAILED / NOT_MERGED: do not retry, say why in the summary.`

// the build/memory gate (gate.ps1) queues work under $env:CLAUDE_AGENT; without it the owner is guessed from the worktree name
const AGENT_ENV = (name) => `
AGENT NAME: start every shell command with  $env:CLAUDE_AGENT='${name}';  (Bash: export CLAUDE_AGENT='${name}';) - the build gate
queues your builds under this owner name (shell state does not persist between commands).`

const REPORT = {
  type: 'object',
  properties: {
    mrs: { type: 'array', items: { type: 'object', properties: { url: { type: 'string' }, repo: { type: 'string' },
      merged: { type: 'boolean', description: 'true ONLY on a confirmed merge: devtools.py merge printed MERGED as its last line, or the host (glab mr view / gh pr view) says merged now' },
      mergeState: { type: 'string', enum: ['MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED', 'NOT_MERGED', 'OPEN'], description: 'the last-line status word of devtools.py merge; OPEN when no merge was attempted (review pending, held)' } },
      required: ['url', 'repo', 'merged'] } },
    worktrees: { type: 'array', items: { type: 'string' } },
    done: { type: 'array', items: { type: 'string' }, description: 'item ids finished' },
    deferred: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, reason: { type: 'string' } }, required: ['id', 'reason'] } },
    needsLiveCheck: { type: 'array', items: { type: 'string' } },
    testerGuide: { type: 'string', description: 'testing instructions for the tester: link to the published tester guide (complex change) or to the tracker comment with the how-to-test steps (simple change); "none: <reason>" only for changes with nothing to test (docs, kit, refactor without behaviour change)' },
    seed: { type: 'array', items: { type: 'string' }, description: 'settings/data to seed after deploy' },
    foreignHooks: { type: 'array', items: { type: 'string' }, description: 'one-line hooks left in another agent area' },
    summary: { type: 'string', description: '<=200 words' },
    changedLines: { type: 'number', description: 'added + removed lines over all your MRs (git diff --numstat origin/<target>...HEAD)' },
    changedFiles: { type: 'array', items: { type: 'string' }, description: 'repo-relative paths changed by your MRs' },
  },
  required: ['mrs', 'worktrees', 'done', 'deferred', 'needsLiveCheck', 'seed', 'foreignHooks', 'summary', 'testerGuide'],
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
cleaning folders (the kit runtime's work/ folder holds live QA runs and wave state; a wave agent once deleted the runtime this way), no branch resets, no
deploys. Mention it in your report and let the lead do it.
`

// Model by stage (args.models overrides any stage): build/fix = sonnet unless the item is marked complex (agents[].complex or
// args.complex: the strongest model, i.e. no model option); review = sonnet; mechanical steps (ci, ship, learn) = haiku.
// agents[].model / .effort win for that agent's build and fix (bug-brief.ps1 marks complex bugs).
const MODELS = { build: 'sonnet', review: 'sonnet', ci: 'haiku', ship: 'haiku', learn: 'haiku', complex: '', ...(A.models || {}) }
const pick = (stage) => (MODELS[stage] ? { model: MODELS[stage] } : {})
const isComplex = (a) => a.complex === true || [].concat(A.complex || []).includes(a.id)
const modelOf = (a) => ({ ...(a.model ? { model: a.model } : pick(isComplex(a) ? 'complex' : 'build')), ...(a.effort ? { effort: a.effort } : {}) })

function buildPrompt(a) {
  return `${WHY}
You are dev agent ${a.id} in a parallel wave (${MODE}).${PATHS}${AGENT_ENV(a.id)}
Follow ${K}/SKILL.md (its steps and Rules; scripts in ${K}/scripts) and the brief ${A.brief} (repos, ownership, ranges, decisions; it wins).
${MODE === 'resume' ? `Resuming: first work out what is already done (${T}/RESUME_BRIEF.md).\n` : ''}YOU ARE ${a.id}. Items: ${a.items}. Area: ${a.area}.
Board: join first with -Agent ${a.id} -Run ${RUN} -Contracts <brief>.contracts.md (if it exists); DUPLICATE -> stop without writing.
Worktree name prefix: ${a.id.toLowerCase()}; your migration range is in the brief. Never touch other agents' worktrees, branches or processes.
${a.note || ''}
${REVIEW
    ? `Do the whole job: implement, gated checks, commit, push, open the MRs, update the tracker. Do NOT schedule merges (no devtools.py
merge): a review runs first and the workflow merges after it - this wins over any "merge when green" in the brief.
Report merged=false and mergeState OPEN for every MR.${REVIEW_AUTO ? `
Also report changedLines (added + removed over all your MRs) and changedFiles (paths): small low-risk changes skip the review.` : ''}`
    : `Do the whole job: implement, run the gated checks, commit, push, open the MRs, merge when green (producers first), update the tracker.
${MERGE_WORD_NOTE}`}${HOLD_NOTE}
Testing instructions are part of the job (dev-kit step 7b): run devtools.py guide-mode first; "always" = every change gets the
published tester guide below (with screenshots). Otherwise a simple change gets a how-to-test comment on the task; a complex one (several screens or flows, more than one repo, migrations, roles) gets a tester guide from
${KIT}/skills/qa-kit/templates/tester-guide.html (check ids, concrete Expected per check, environment, accounts, data to prepare)
published with devtools.py doc and linked on the task and in the MR. Report its link as testerGuide.
Return the report.`
}

function reviewPrompt(a, r) {
  return `Review agent ${a.id}'s MRs (items ${a.items}, area ${a.area}; brief ${A.brief}) as your agent definition says.${PATHS}${AGENT_ENV(`review-${a.id}`)}
${r.mrs.map((m) => `- ${m.url} (${m.repo}${m.merged ? ', merged' : ''})`).join('\n')}
Rules: ${K}/SKILL.md Rules (scope) and ${K}/reference/migrations.md. Only real problems; "blocking" = must be fixed before it ships.
Do not change any code yourself.`
}

function fixPrompt(a, r, findings) {
  return `${WHY}
You are dev agent ${a.id} again (items ${a.items}, area ${a.area}).${PATHS}${AGENT_ENV(a.id)}
Follow ${K}/SKILL.md and ${A.brief}.
Your worktrees: ${r.worktrees.join(', ')}. An independent reviewer found these problems in your MRs (blocking and should-fix; resolve all of them):
${findings.map((f) => `- ${f.mr} ${f.file}${f.line ? ':' + f.line : ''}: ${f.problem} -> ${f.fix}`).join('\n')}
Fix each or explain why it isn't a problem. Before you push, check each MR's state (glab mr view / gh pr view): pushing to the
branch of an already-merged MR changes nothing on the target, so for a merged MR put the fix on a new branch from the target
(wt.ps1 new) and open a follow-up MR; otherwise wt.ps1 sync and push to the same branch. Gated checks, push. Do NOT schedule merges:
the workflow waits for the pipelines and merges after you. Return the updated report with every MR (follow-ups included), merged=false
unless it is already merged.${HOLD_NOTE}`
}

// review passed (or was off for this agent): schedule the merges — the build agent deliberately left them open
const CI_SCHEMA = {
  type: 'object',
  properties: { done: { type: 'boolean' }, mrs: { type: 'array', items: { type: 'object', properties: { mr: { type: 'string' }, status: { type: 'string' }, job: { type: 'string' }, error: { type: 'string' } }, required: ['mr', 'status'] } } },
  required: ['done', 'mrs'],
}
// CI gate before shipping: agents stop at "MR opened", so nobody saw a failed pipeline (a lint/schema check failure sat unnoticed until
// the tracker flagged it). A cheap agent waits for the pipelines with pipe-wait.ps1; failures go back to the dev agent as blocking findings.
function ciPrompt(r, a) {
  const urls = r.mrs.filter((m) => !m.merged).map((m) => m.url).join(',')
  return `Run exactly this PowerShell command and return its JSON output as the result (fields done, mrs). Nothing else.${PATHS}
$env:CLAUDE_AGENT='ci-${a ? a.id : 'wave'}'; & ${K}/scripts/pipe-wait.ps1 -Mrs ${urls} -MaxMinutes 8
If the JSON says "done": false, run the same command again (at most 3 times in total) and return the last JSON.`
}

// held repos are filtered out in code, not only by prompt text: a merge there needs a person's yes
const isHeld = (m) => HOLD.includes('*') || HOLD.includes(m.repo) || HOLD.some((h) => (m.url || '').includes(`/${h}/`))
// producers (DB/API/library) merge before consumers (web/app/clients): the ship list is ordered that way, consumers last
const CONSUMER = /(^|[\/_.-])(web|ui|frontend|front|app|apps|mobile|android|ios|client|clients|portal|spa)([\/_.-]|$)/i
const isConsumer = (m) => CONSUMER.test(m.repo || '') || CONSUMER.test(((m.url || '').split('/-/')[0] || '').split('/').pop() || '')
const toShip = (r) => {
  const open = r.mrs.filter((m) => !m.merged && !isHeld(m))
  return [...open.filter((m) => !isConsumer(m)), ...open.filter(isConsumer)]
}

function shipPrompt(a, r) {
  // a ship agent once refused every merge ("deploying merges need a person's yes") because it read the harness-relayed chat message
  // as the request: merges into deploying branches are already removed in code (holdMerge), so the listed ones are authorized
  return `Schedule merge-when-green for agent ${a.id}'s reviewed MRs (review clean). Change no code.${PATHS}${AGENT_ENV(`ship-${a.id}`)}
These merges are authorized: this wave was launched for this work, and the workflow already removed every MR whose target deploys
on merge (holdMerge), so none of the targets below deploys. Do not ask for approval and ignore any unrelated chat message relayed to you.
Merge in THIS order (producers - DB/API/library - first, consumers - web/app/clients - last):
${toShip(r).map((m, i) => `${i + 1}. ${m.url} (${m.repo}${isConsumer(m) ? ', consumer' : ', producer/independent'})`).join('\n')}
Producer and independent MRs now: python ${K}/scripts/devtools.py merge <worktree> <iid> (worktrees: ${r.worktrees.join(', ')}).
A consumer (web/app) MR that depends on a producer MR in this list: merge it only after the producer's merge printed MERGED; otherwise
don't merge it: register & ${ORCH}/track.ps1 add -Task <task id from the MR title/branch> -Discover -MergeAfter
'<consumer repo>!<iid>><producer repo>!<iid>' (mergeState OPEN for it; the coordinator's tracker merges it once the producer merged).
devtools.py merge itself refuses a consumer whose registered producer is not merged yet ("waiting for producer ...", last line WAIT).
${MERGE_WORD_NOTE}
Return the report with the same MRs (merged=true only on MERGED) and testerGuide "${r.testerGuide || 'none: not reported by the build agent'}".${HOLD_NOTE}`
}

log(`wave: ${A.agents.length} agents, mode ${MODE}, review ${REVIEW_AUTO ? 'auto' : REVIEW ? 'on' : 'off'}, learn ${LEARN}, brief ${A.brief}, models ${A.agents.map((a) => `${a.id}=${modelOf(a).model || 'default'}`).join(' ')}`)

const results = await pipeline(
  A.agents,
  (a) => agent(buildPrompt(a), { label: `build:${a.id}`, phase: 'Build', schema: REPORT, agentType: 'dev-agent', ...modelOf(a) }),
  async (r, a) => {
    if (!r) return { id: a.id, error: 'agent returned nothing' }
    if (!REVIEW || !r.mrs.length) return { id: a.id, report: r, findings: [] }
    if (REVIEW_AUTO && smallChange(r)) { log(`${a.id}: review skipped (auto: ${r.changedLines} changed lines, nothing sensitive)`); return { id: a.id, report: r, findings: [], reviewSkipped: true } }
    const rv = await agent(reviewPrompt(a, r), { label: `review:${a.id}`, phase: 'Review', schema: REVIEW_SCHEMA, agentType: 'mr-reviewer', ...pick('review') })
    // a reviewer that returned nothing is NOT a clean review: never ship unreviewed MRs
    if (!rv) return { id: a.id, report: r, findings: [{ mr: r.mrs.map((m) => m.url).join(', '), file: '-', severity: 'blocking',
      problem: 'The review agent returned nothing (failed or stopped), so these MRs are unreviewed and were not merged.', fix: 'Re-run the review (one-off mr-reviewer, router R7), then merge.' }], reviewFailed: true }
    return { id: a.id, report: r, findings: rv.findings || [] }
  },
  async (x, a) => {
    if (!x || x.error) return x
    if (x.reviewFailed) { log(`${a.id}: review agent returned nothing - MRs left open, unreviewed`); return x }
    // should-fix findings get the fix round too (no deferrals): a should-fix once reopened a permission gap on merge
    const blocking = x.findings.filter((f) => f.severity !== 'nit')
    if (!blocking.length) {
      const failures = await ciGate(a, x.report)
      if (failures.length) { log(`${a.id}: ${failures.length} failed pipeline(s) -> fix round`); blocking.push(...failures) }
    }
    if (!blocking.length) return ship(a, x)
    log(`${a.id}: ${blocking.length} blocking finding(s) -> fix round`)
    const r2 = await agent(fixPrompt(a, x.report, blocking), { label: `fix:${a.id}`, phase: 'Fix', schema: REPORT, agentType: 'dev-agent', ...modelOf(a) })
    // CI failures count as findings too, so the coordinator sees them when the fix round fails
    if (!r2) return { ...x, findings: [...x.findings.filter((f) => f.severity === 'nit'), ...blocking], fixed: false, stopped: true }
    // merge, don't replace: the fix agent reports only its fixes, the build report holds the items done
    const uniq = (a) => [...new Set(a)]
    const byId = (a) => [...new Map(a.map((d) => [d.id, d])).values()]
    const mrs = [...r2.mrs, ...x.report.mrs.filter((m) => !r2.mrs.some((n) => n.url === m.url))]
    const fixedX = { ...x, findings: [...x.findings.filter((f) => f.severity === 'nit'), ...blocking], fixed: true, report: { ...x.report, mrs, worktrees: uniq([...x.report.worktrees, ...r2.worktrees]),
      done: uniq([...x.report.done, ...r2.done]), deferred: byId([...x.report.deferred, ...r2.deferred]),
      needsLiveCheck: uniq([...x.report.needsLiveCheck, ...r2.needsLiveCheck]), seed: uniq([...(x.report.seed || []), ...(r2.seed || [])]),
      foreignHooks: uniq([...(x.report.foreignHooks || []), ...(r2.foreignHooks || [])]),
      testerGuide: r2.testerGuide && !/^none/i.test(r2.testerGuide) ? r2.testerGuide : x.report.testerGuide,
      summary: `${x.report.summary}\n\nFix round: ${r2.summary}` } }
    // the fix round is not proof: pipelines must be green again before anything merges
    const failures = await ciGate(a, fixedX.report)
    if (failures.length) { log(`${a.id}: pipelines still failing after the fix round - left open`); return { ...fixedX, fixed: false, findings: [...fixedX.findings, ...failures] } }
    return ship(a, fixedX)
  },
  // every agent with MRs gets its tracker task registered, whatever happened above (merged, held, fix round failed): the
  // tracker promotes it once all its MRs merge - also when a person merges them later. (Agents in a reviewed wave never
  // reach dev-kit step 8b, and the ship step only registered consumer MRs, so tasks sat in review after their MRs merged.)
  async (x, a) => {
    if (!x || x.error || !x.report || !x.report.mrs.length) return x
    const refs = x.report.mrs.map((m) => m.url).join(', ')
    // not registered while work is missing: the tracker promotes a task once its known MRs merge, so an agent that deferred items
    // or was stopped (fix round returned nothing) would get its task promoted with the rest still to do. The coordinator registers it.
    const deferred = x.report.deferred || []
    if (deferred.length || x.stopped) {
      log(`${a.id}: tracker task NOT registered (${deferred.length ? `deferred ${deferred.map((d) => d.id).join(', ')}` : 'agent stopped'}) - once the rest is done: track.ps1 add -Task <id> -Discover -Mrs ${refs}`)
      return { ...x, trackHeld: deferred.length ? 'deferred items' : 'agent stopped' }
    }
    const tr = await agent(`Register agent ${a.id}'s tracker task for its MRs. Change no code, merge nothing.${PATHS}${AGENT_ENV(`track-${a.id}`)}
MRs: ${refs}
1. Find the task id: it is in each MR's title or source branch after the tracker tag (e.g. CU-<id>); glab mr view / gh pr view <url> if needed.
   One agent can have several tasks: group the MRs by task.
2. Per task: & ${ORCH}/track.ps1 add -Task <task id> -Discover -Mrs '<repo>!<iid>','<repo>!<iid>' (all of that task's MRs, merged or not;
   -Discover also picks up the task's MRs opened later, e.g. a follow-up).
Return ok=true and the track.ps1 output lines.`, { label: `track:${a.id}`, phase: 'Fix', schema: { type: 'object', properties: { ok: { type: 'boolean' }, output: { type: 'string' } }, required: ['ok', 'output'] }, ...pick('ship'), effort: 'low' })
    if (!tr || !tr.ok) log(`${a.id}: WARNING tracker task not registered (${tr ? tr.output : 'agent returned nothing'}) - run track.ps1 add -Task <id> -Mrs ${refs}`)
    return x
  },
)

// CI gate: failed pipelines become blocking findings; a CI agent that returned nothing is logged, not treated as green-and-silent
async function ciGate(a, r) {
  if (!REVIEW || !r.mrs.some((m) => !m.merged)) return []
  const ci = await agent(ciPrompt(r, a), { label: `ci:${a.id}`, phase: 'Review', schema: CI_SCHEMA, ...pick('ci'), effort: 'low' })
  if (!ci) { log(`${a.id}: WARNING CI gate agent returned nothing; merge-when-green still waits for the pipelines`); return [] }
  return (ci.mrs || []).filter((m) => m.status === 'failed').map((m) => ({ mr: m.mr, file: `CI job ${m.job || '?'}`, severity: 'blocking',
    problem: `The MR pipeline failed in job ${m.job || '?'}:\n${m.error || '(no error text captured)'}`,
    fix: 'Reproduce the failing CI job locally through the gate (check.ps1 / lbcheck.py for changelog checks), fix the cause, push, and make sure the pipeline goes green.' }))
}

// review passed (or was off): schedule the merges - the build and fix agents deliberately left them open
async function ship(a, x) {
  if (!REVIEW) return x
  const held = x.report.mrs.filter((m) => !m.merged && isHeld(m))
  if (held.length) log(`${a.id}: ${held.length} MR(s) held for approval (holdMerge): ${held.map((m) => m.url).join(', ')}`)
  if (!toShip(x.report).length) return x
  const r3 = await agent(shipPrompt(a, x.report), { label: `ship:${a.id}`, phase: 'Fix', schema: REPORT, ...pick('ship'), effort: 'low' })
  // keep the build report (done/deferred/live checks/summary); take only the MR states and add the ship note
  if (!r3) { log(`${a.id}: WARNING ship agent returned nothing - MRs not scheduled`); return x }
  // merged only on a confirmed MERGED (devtools.py's last status word); an agent's merged=true without a word is not proof
  const state = new Map(r3.mrs.map((m) => [m.url, m.mergeState || (m.merged ? 'NOT_MERGED' : 'OPEN')]))
  return { ...x, report: { ...x.report, mrs: x.report.mrs.map((m) => {
    const s = m.merged ? 'MERGED' : (state.get(m.url) || m.mergeState || 'OPEN')
    return { ...m, mergeState: s, merged: s === 'MERGED' }
  }),
    summary: `${x.report.summary}\n\nMerge scheduling: ${r3.summary}` } }
}

const out = results.filter(Boolean)
for (const x of out) {
  if (x.error) { log(`${x.id}: ERROR ${x.error}`); continue }
  const r = x.report
  const notMerged = r.mrs.filter((m) => !m.merged && m.mergeState && m.mergeState !== 'OPEN').map((m) => `${m.mergeState} ${m.url}`)
  log(`${x.id}: ${r.mrs.filter((m) => m.merged).length}/${r.mrs.length} MRs merged, scheduled ${r.mrs.filter((m) => m.mergeState === 'SCHEDULED').length}, done ${r.done.length}, deferred ${r.deferred.length}, review findings ${x.findings.length}${x.trackHeld ? `, tracker NOT registered (${x.trackHeld})` : ''}${notMerged.length ? ` | ${notMerged.join(', ')}` : ''}`)
}
const outcome = {
  agents: out,
  deferred: out.flatMap((x) => (x.report ? x.report.deferred.map((d) => ({ agent: x.id, ...d })) : [])),
  needsLiveCheck: out.flatMap((x) => (x.report ? x.report.needsLiveCheck : [])),
  seed: out.flatMap((x) => (x.report ? x.report.seed : [])),
  openFindings: out.flatMap((x) => (x.fixed ? [] : (x.findings || []).filter((f) => f.severity !== 'nit'))),
  testerGuides: out.filter((x) => x.report).map((x) => ({ agent: x.id, guide: x.report.testerGuide || 'MISSING' })),
}
for (const g of outcome.testerGuides) if (!g.guide || g.guide === 'MISSING' || /^none/i.test(g.guide)) log(`${g.agent}: no tester guide (${g.guide}) - the coordinator writes or requests one before QA`)

// LEARN: turn this run's outcome into signals, and recurring ones into LESSONS.md (self-improving kit).
// learn: 'auto' runs it only when something happened worth learning from; a clean wave just gets the cleanup.
phase('Learn')
// every finished run ends with a kit retro (orchestrate E14): the coordinator launches it once no other workflow of the session runs
const retroDue = (o) => { log('RETRO DUE: run /kit-retro (orchestrate E14) once no other workflow of this session runs'); return { ...o, retroDue: true, next: '/kit-retro (orchestrate E14)' } }
const eventful = out.some((x) => x.error || x.fixed !== undefined || (x.findings || []).length || (x.report && x.report.deferred.length)) || outcome.openFindings.length > 0
if (LEARN === false || (LEARN === 'auto' && !eventful)) {
  await agent(`Run exactly this in PowerShell and report its last output line, nothing else:${PATHS}
& ${ORCH}/cleanup.ps1 -Quiet -WorktreeIdleHours 0`, { label: 'cleanup', phase: 'Learn', model: 'haiku', effort: 'low' })
  log(`learn: skipped (${LEARN === false ? 'learn: false' : 'auto: clean wave'}); cleanup ran`)
  return retroDue(outcome)
}
const learned = await agent(`You maintain the kit's memory. This dev wave just finished.${PATHS}
Outcome (JSON):
${JSON.stringify(outcome).slice(0, 60000)}

1. One signal per notable event (failures, retries, review findings, deferrals, anything that cost time or worked unusually well):
   & ${ORCH}/learn.ps1 -Skill <dev-kit|other skill|project> -Kind <friction|failure|defect-missed|false-positive|stale-env|flaky|idea|win> -Text "<what + fix>" -Ref <id> -Source workflow
2. Read ${K}/LESSONS.md (active rules; never HISTORY.md) and the recent signals (learn.ps1 -Show -Last 200). A pattern seen ≥ 2 times
   that isn't a lesson yet: & ${ORCH}/learn.ps1 -Skill <skill> -Lesson "(n×) <one actionable line>" [-Project <name>]; a recurring
   lesson: learn.ps1 -Skill <skill> -Bump "<words of it>" [-Append "<new clause>"]; merge or condense near-duplicate lessons with Edit. A lesson the kit now handles: learn.ps1 -Skill <skill> -Fixed "<words of it>". Finish with
   learn.ps1 -Skill <skill> -Trim for each LESSONS.md you changed (≤ 40 lines; moves fixed/oldest lines to HISTORY.md). Don't touch SKILL.md.
3. & ${ORCH}/cleanup.ps1 -Quiet -WorktreeIdleHours 0 (only kit-created leftovers; merged worktrees go at once, open MRs are kept), then Get-Content ${rp('cleanup-log')} -Tail 15: mention what was freed.
Return how many signals you recorded and which lessons changed.`, { label: 'learn', phase: 'Learn', schema: LEARN_SCHEMA, ...pick('learn'), effort: 'low' })
if (learned) log(`learn: ${learned.signals} signal(s), lessons changed: ${learned.lessonsChanged.join('; ') || 'none'}`)
return retroDue(outcome)
