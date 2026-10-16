export const meta = {
  name: 'tidy',
  description: 'Kit upkeep by kitty (kind retro): learning signals -> lessons + rule updates, cleanup, the weekly audit kick-off; self-improvement pass for the multi-agent kit: mine learning signals, guard blocks, gate history and recent QA/dev runs; update LESSONS.md, promote stable lessons into rules, propose script/default changes',
  whenToUse: 'A /buildy or /testy finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective',
  phases: [
    { title: 'Analyse', detail: '4 parallel kitty analysts: dev, QA, speed/infra, docs/evidence' },
    { title: 'Apply', detail: 'one kitty dedupes, applies lesson + rule changes, writes the retro report, says when the audit is due' },
  ],
}

/* args (all optional): {
  applyScripts: false,  // true: also apply script/default edits
  kitDir: 'C:/work/.claude',  // absolute (recommended); default '.claude' under workspace root
  runtimeDir: 'C:/work/.claude/.runtime',  // default <kitDir>/.runtime
  models: { analyse: 'sonnet', apply: '' },  // default: session model
} */
const A = args || {}
const C = (A.kitDir || '.claude').replace(/[\\/]+$/, '')
const pick = (stage) => ((A.models || {})[stage] ? { model: A.models[stage] } : {})
const RT = (A.runtimeDir || `${C}/.runtime`).replace(/[\\/]+$/, '')
// kit paths by name: the same names and values as skills/dev-kit/kit.example.json _paths (kit-lint RUNTIME-MAP keeps them equal)
const KP = {"runtime": {"guard-log": "logs/guard.log", "qa-runs": "work/qa-runs/", "audits": "work/audits/", "retros": "logs/retros/", "launches": "work/launches/"}, "durable": {"signals": "learning.jsonl", "last-retro": "learning.stamp"}}
const rp = (n) => (n in KP.durable ? `${C}/.state/${KP.durable[n]}` : `${RT}/${KP.runtime[n]}`).replace(/\/$/, '')
const PATHS = (/^([A-Za-z]:|[\\/])/.test(C) ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.') +
  '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
const SOURCES = `${PATHS}
Data sources (read what exists; missing files just mean no data yet):
- ${rp('signals')} — raw signals {at, skill, kind, text, ref, source} (durable, git-ignored); only those after the time in ${rp('last-retro')} are new
  (print them with: & ${C}/skills/orchestrate/orch.ps1 learn -Show -Last 500 ; counts: -Stats)
- ${rp('guard-log')} — commands the guard hook blocked (time, session, reason, command): repeated blocks = agents don't know a rule
- <OS temp folder>/claude-build-gate/history.json ([IO.Path]::GetTempPath(): %TEMP% on Windows, $TMPDIR or /tmp elsewhere) — per build kind: peak GB, seconds, ok — slow or failing kinds, estimates drifting
- ${rp('qa-runs')}/*/ — run.json, <code>/results.json, finalize.json, lead-notes.md: failedTesting causes, NOT_TESTED reasons, audit reclassifications, verify "not reproduced" rates
- ${rp('audits')}/ — module audit findings (revy, kind module) and review outcomes, if any
- Kit structure problems: python -X utf8 ${C}/skills/orchestrate/kittool.py lint --warn --no-flow (unrouted parts, unlisted files, fuzzy triggers, dangling paths)
- Current kit: ${C}/skills/*/SKILL.md, ${C}/LESSONS.md and ${C}/LESSONS.local.md (## <skill> sections of active rules; .local = org/project lessons); retired (fixed / trimmed) lessons: & ${C}/skills/orchestrate/orch.ps1 learn -History [-Grep <words>]: read them only to spot a fixed problem that came back, ${C}/skills/dev-kit/projects/*.local.md, ${C}/rules/*.md, ${C}/agents/*.md, ${C}/workflows/*.js`

const PROPOSALS = {
  type: 'object',
  properties: {
    proposals: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string', description: 'absolute path of the file to change' },
          change: { type: 'string', enum: ['add-lesson', 'update-lesson', 'remove-lesson', 'promote-to-rule', 'script-change', 'default-change', 'template-change'] },
          text: { type: 'string', description: 'the exact lesson/rule text, or a precise description of the code change' },
          evidence: { type: 'string', description: 'which signals / runs / log lines support it, with counts' },
          occurrences: { type: 'number' },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
        required: ['file', 'change', 'text', 'evidence', 'occurrences', 'confidence'],
      },
    },
  },
  required: ['proposals'],
}
const RESULT = {
  type: 'object',
  properties: {
    applied: { type: 'array', items: { type: 'string' } },
    proposedForApproval: { type: 'array', items: { type: 'string' } },
    rejected: { type: 'array', items: { type: 'string' } },
    report: { type: 'string', description: 'path of the retro report written' },
  },
  required: ['applied', 'proposedForApproval', 'rejected', 'report'],
}

const LENSES = [
  { key: 'dev', focus: 'dev agents: worktrees, builds/tests, commits/hooks, migrations, MR/merge flow, guard blocks, review findings from /buildy' },
  { key: 'qa', focus: 'QA and the local test loop: verdict quality (notes reclassified, verify "not reproduced" rate), failedTesting and NOT_TESTED causes, local-test rounds, stronger fix rounds, ENV-FIX requests (local env: what the agents could not unblock themselves) and blocked items, flaky selectors/UI gotchas, evidence problems, unpublished items' },
  { key: 'speed', focus: 'speed and resources: gate waits and build durations per kind, memory estimates vs peaks, slow steps, permission prompts, things agents repeat that a script should do' },
  { key: 'docs', focus: 'documents and evidence: report/guide/MR/comment formats, evidence naming warnings, templates agents ignored or misused, unclear instructions in SKILL.md/agents' },
]

phase('Analyse')
// launch record (orch.ps1 launch -Self, FNV-1a): a resume needs the args byte-exact
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 } return h.toString(16).padStart(8, '0') }
const AJ = JSON.stringify(A), AF = `${rp('launches')}/args-tidy-tidy.json`
for (const [label, model] of [['record-args', 'haiku'], ['record-args-retry', 'sonnet']]) {
  const r = await agent(`STEP: record this workflow's launch args (crash recovery). Do exactly this, nothing else:${PATHS}
1. Write the line between the markers to ${AF} with the Write tool, byte for byte (one line of JSON; no markers, nothing added):
<<<ARGS
${AJ}
ARGS>>>
2. Run in PowerShell: & ${C}/skills/orchestrate/orch.ps1 launch -Self -Script tidy.js -Run 'tidy' -ArgsFile '${AF}' -Fnv ${fnv(AJ)}
Return ok=true when it prints RECORDED, else ok=false with its output (MISMATCH = the file differs: write it again once, re-run).`,
    { label, phase: 'Analyse', schema: { type: 'object', properties: { ok: { type: 'boolean' }, output: { type: 'string' } }, required: ['ok', 'output'] }, agentType: 'kitty', model, effort: 'low' })
  if (r && r.ok) break
}
await agent(`STEP: write the current local time (ISO, e.g. 2026-10-01T10:15:00) to ${rp('last-retro')}.start (create the folder), nothing else. Return ok=true.`,
  { label: 'stamp-start', phase: 'Analyse', agentType: 'kitty', model: 'haiku', effort: 'low' })
const found = await parallel(LENSES.map((l) => () => agent(`Kind retro (analyst): you analyse the multi-agent dev/QA kit. Lens: ${l.focus}.
${SOURCES}

Find RECURRING patterns (≥ 2 occurrences) and clear wins. For each, propose the smallest durable improvement:
- add-lesson / update-lesson (increment the (n×) count) / remove-lesson (obsolete or contradicted) in the right ## <skill> section of LESSONS.md
  (project-specific lessons: orch.ps1 learn -Project <name>, which writes LESSONS.local.md, never the published file; audit false-positive lessons go to the project profile, skills/dev-kit/projects/<project>.local.md);
- promote-to-rule: a lesson seen ≥ 3× and still true → a short rule in the relevant SKILL.md or rules/*.md (and remove it from LESSONS.md);
- script-change / default-change / template-change: describe precisely what to change and why (file, function, new value).
Every proposal needs evidence with counts. Do not edit anything. Prefer fewer, sharper proposals.`, { label: `analyse:${l.key}`, phase: 'Analyse', schema: PROPOSALS, agentType: 'kitty', ...pick('analyse') })))

// script/default/template edits need applyScripts; low confidence needs >= 2 counted occurrences
const APPLY_NOW = { 'add-lesson': true, 'update-lesson': true, 'remove-lesson': true, 'promote-to-rule': true,
  'script-change': !!A.applyScripts, 'default-change': !!A.applyScripts, 'template-change': !!A.applyScripts }
const KEEP = { 'high': () => true, 'medium': () => true, 'low': (p) => (p.occurrences || 0) >= 2 && !!String(p.evidence || '').trim() }
const all = found.filter(Boolean).flatMap((f) => f.proposals).filter((p) => (KEEP[p.confidence] || KEEP.low)(p))
const now = all.filter((p) => APPLY_NOW[p.change]), later = all.filter((p) => !APPLY_NOW[p.change])
const dead = found.filter((f) => !f).length
log(`analysts proposed ${all.length} change(s)${dead ? ` - WARNING ${dead} analyst(s) returned nothing` : ''}`)
if (!all.length) {
  // stamp so the nudge skips reviewed signals, unless analysts failed
  if (!dead) await agent(`STEP: copy the content of ${rp('last-retro')}.start to ${rp('last-retro')} (the time this retro started), nothing else. Return ok=true.`,
    { label: 'stamp', phase: 'Apply', agentType: 'kitty', model: 'haiku', effort: 'low' })
  return { applied: [], proposedForApproval: [], rejected: [], report: dead ? `no proposals; ${dead} analyst(s) failed - re-run the retro` : 'nothing to change' }
}

phase('Apply')
const res = await agent(`Kind retro (apply): you maintain the kit (${C}). Apply this retrospective.${PATHS}

Proposals from 4 analysts (may overlap or conflict), to APPLY now:
${JSON.stringify(now)}
To LIST for approval with the exact edit (do not apply):
${JSON.stringify(later)}

Steps:
1. Dedupe and resolve conflicts; drop low-confidence proposals without evidence.
2. APPLY directly: add/update/remove-lesson and promote-to-rule changes (LESSONS.md, SKILL.md, rules/*.md, project profiles).
   LESSONS.md holds only active rules per ## <skill> section, newest first, one line each (<= 50 words, <= 300 chars: dev-kit/templates.md "Writing standards", kind lesson; kittool.py lint PROSE), merged duplicates. Use ${C}/skills/orchestrate/orch.ps1 learn:
   -Skill <s> -Lesson "(n×) <line>" [-Project <p>] to add, -Fixed "<words>" for a lesson the kit now handles or that was promoted/obsolete
   (retired: learn -History lists it), then -Skill <s> -Trim for every skill you touched (enforces ≤ 40 lines; never delete lessons by hand).
3. ${A.applyScripts ? 'ALSO APPLY script-change / default-change / template-change proposals, then re-parse every changed .ps1 ([System.Management.Automation.Language.Parser]::ParseFile) and node --check-style check every changed .js/.mjs; revert any change that breaks parsing.' : 'Do NOT apply script-change / default-change / template-change: list them for approval with the exact edit.'}
4. Write the report to ${rp('retros')}/retro-<yyyy-MM-dd-HHmm>.md (create the folder): what changed and why (with evidence), what awaits approval, what was rejected.
5. Run python -X utf8 ${C}/skills/orchestrate/kittool.py lint (it also regenerates <runtime>/cache/kit-flow.html): fix every problem your changes
   caused (see ${C}/README.md "Extending") and list the rest in the report. Then & ${C}/skills/orchestrate/orch.ps1 cleanup -Quiet; include the freed space in the report.
6. ${dead ? `Do NOT write ${rp('last-retro')}: ${dead} analyst(s) failed, their signals are not reviewed yet.` : `Copy the content of ${rp('last-retro')}.start (the time this retro started) to ${rp('last-retro')} so the next retro and the session nudge count only signals after it.`}
Return the lists and the report path.`, { label: 'apply', phase: 'Apply', schema: RESULT, agentType: 'kitty', ...pick('apply') })

log(`applied ${res ? res.applied.length : 0}, awaiting approval ${res ? res.proposedForApproval.length : 0}`)
return res
