export const meta = {
  name: 'kit-retro',
  description: 'Self-improvement pass for the multi-agent kit: mine learning signals, guard blocks, gate history and recent QA/dev runs; update LESSONS.md, promote stable lessons into rules, propose script/default changes',
  whenToUse: 'After a wave or QA run, weekly, or when the session-start nudge says signals have piled up',
  phases: [
    { title: 'Analyse', detail: '4 parallel analysts: dev, QA, speed/infra, docs/evidence' },
    { title: 'Apply', detail: 'one synthesizer dedupes, applies lesson + rule changes, writes the retro report' },
  ],
}

/*
args (all optional): {
  applyScripts: false,                 // true = also apply proposed script/default edits (otherwise listed for approval)
  kitDir: 'C:\\work\\.claude',         // absolute path of this kit (recommended); default '.claude' relative to the workspace root
  runtimeDir: 'C:\\work\\.claude-runtime',   // default <kitDir>\\..\\.claude-runtime
}
*/
const A = args || {}
const C = (A.kitDir || '.claude').replace(/[\\/]+$/, '')
const RT = (A.runtimeDir || `${C}\\..\\.claude-runtime`).replace(/[\\/]+$/, '')
const PATHS = /^([A-Za-z]:|[\\/])/.test(C) ? '' : '\nKit paths below are relative to the workspace root (the directory this session started in); make them absolute before reading files.'
const SOURCES = `${PATHS}
Data sources (read what exists; missing files just mean no data yet):
- ${RT}\\learning\\signals.jsonl — raw signals {at, skill, kind, text, ref, source}; only those after ${RT}\\learning\\last-retro.txt are new
  (print them with: & ${C}\\skills\\orchestrate\\scripts\\learn.ps1 -Show -Last 500 ; counts: -Stats)
- ${RT}\\guard.log — commands the guard hook blocked (time, session, reason, command): repeated blocks = agents don't know a rule
- %TEMP%\\claude-build-gate\\history.json — per build kind: peak GB, seconds, ok — slow or failing kinds, estimates drifting
- ${RT}\\qa-runs\\*\\ — run.json, <code>\\results.json, finalize.json, autoclose.log: NOT_TESTED reasons, audit reclassifications, verify "not reproduced" rates
- ${RT}\\audits\\ — tech-audit findings and review outcomes, if any
- Current kit: ${C}\\skills\\*\\SKILL.md, ${C}\\skills\\*\\LESSONS.md, ${C}\\skills\\tech-audit\\reference\\projects\\*.md, ${C}\\rules\\*.md, ${C}\\agents\\*.md, ${C}\\workflows\\*.js`

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
  { key: 'dev', focus: 'dev agents: worktrees, builds/tests, commits/hooks, migrations, MR/merge flow, guard blocks, review findings from /dev-wave' },
  { key: 'qa', focus: 'QA: verdict quality (notes reclassified by the audit, verify "not reproduced" rate), NOT_TESTED causes, flaky selectors/UI gotchas per project, evidence problems, finalize/autoclose failures' },
  { key: 'speed', focus: 'speed and resources: gate waits and build durations per kind, memory estimates vs peaks, slow steps, permission prompts, things agents repeat that a script should do' },
  { key: 'docs', focus: 'documents and evidence: report/guide/MR/comment formats, evidence naming warnings, templates agents ignored or misused, unclear instructions in SKILL.md/agents' },
]

phase('Analyse')
const found = await parallel(LENSES.map((l) => () => agent(`You are a retrospective analyst for a multi-agent dev/QA kit. Lens: ${l.focus}.
${SOURCES}

Find RECURRING patterns (≥ 2 occurrences) and clear wins. For each, propose the smallest durable improvement:
- add-lesson / update-lesson (increment the (n×) count) / remove-lesson (obsolete or contradicted) in the right LESSONS.md
  (project-specific lessons go under that project's heading; audit false-positive lessons go to the project profile in tech-audit);
- promote-to-rule: a lesson seen ≥ 3× and still true → a short rule in the relevant SKILL.md or rules\\*.md (and remove it from LESSONS.md);
- script-change / default-change / template-change: describe precisely what to change and why (file, function, new value).
Every proposal needs evidence with counts. Do not edit anything. Prefer fewer, sharper proposals.`, { label: `analyse:${l.key}`, phase: 'Analyse', schema: PROPOSALS })))

const all = found.filter(Boolean).flatMap((f) => f.proposals)
log(`analysts proposed ${all.length} change(s)`)
if (!all.length) return { applied: [], proposedForApproval: [], rejected: [], report: 'nothing to change' }

phase('Apply')
const res = await agent(`You are the kit maintainer (kit: ${C}). Apply this retrospective.${PATHS}

Proposals from 4 analysts (may overlap or conflict):
${JSON.stringify(all, null, 1)}

Steps:
1. Dedupe and resolve conflicts; drop low-confidence proposals without evidence.
2. APPLY directly: add/update/remove-lesson and promote-to-rule changes (LESSONS.md, SKILL.md, rules\\*.md, tech-audit project profiles).
   Keep LESSONS.md under ~40 lines each: newest first, merge duplicates, drop lessons that were promoted or are obsolete.
3. ${A.applyScripts ? 'ALSO APPLY script-change / default-change / template-change proposals, then re-parse every changed .ps1 ([System.Management.Automation.Language.Parser]::ParseFile) and node --check-style check every changed .js/.mjs; revert any change that breaks parsing.' : 'Do NOT apply script-change / default-change / template-change: list them for approval with the exact edit.'}
4. Write the report to ${RT}\\learning\\retro-<yyyy-MM-dd-HHmm>.md: what changed and why (with evidence), what awaits approval, what was rejected.
5. Run ${C}\\skills\\orchestrate\\scripts\\cleanup.ps1 -Quiet and include the freed space in the report.
6. Write the current local time (ISO, e.g. 2026-10-01T10:15:00) to ${RT}\\learning\\last-retro.txt so the next retro and the session nudge count only new signals.
Return the lists and the report path.`, { label: 'apply', phase: 'Apply', schema: RESULT })

log(`applied ${res ? res.applied.length : 0}, awaiting approval ${res ? res.proposedForApproval.length : 0}`)
return res
