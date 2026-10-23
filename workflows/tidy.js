export const meta = {
 name: 'tidy',
 description: 'Kit upkeep by kitty (kind retro) in 2-5 min: one script step (orch.ps1 tidy prep: digest of signals, guard blocks, script errors, builds, runs, lint, extras, params + the upkeep: extras sync / prune, param learn, cleanup, worktree prune, signal counting), then one kitty judges the digest: lessons, rule edits, script proposals',
 whenToUse: 'A /buildy or /testy finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective',
 phases: [
  { title: 'Prep', detail: 'one STEP: launch record + orch.ps1 tidy prep (no LLM work)' },
  { title: 'Judge', detail: 'one kitty: lesson wording, rule edits, script proposals, retro report, tidy done' },
 ],
}

// Sections: L12 args · L24 prep · L49 judge
// ---- args: all optional
/* args (all optional): {
 applyScripts: false,  // true: also apply script/default edits
 kitDir: 'C:/work/.claude',  // absolute (recommended); default '.claude' under workspace root
 runtimeDir: 'C:/work/.claude/.runtime',  // default <kitDir>/.runtime
} */
const A = args || {}
const C = (A.kitDir || '.claude').replace(/[\\/]+$/, '')
const RT = (A.runtimeDir || `${C}/.runtime`).replace(/[\\/]+$/, '')
// kit paths by name: the same names and values as skills/dev-kit/kit.example.json _paths (kit-lint RUNTIME-MAP keeps them equal)
const KP = {"runtime": {"retros": "logs/retros/", "launches": "work/launches/"}, "durable": {}}
const rp = (n) => (n in KP.durable ? `${C}/.state/${KP.durable[n]}` : `${RT}/${KP.runtime[n]}`).replace(/\/$/, '')
// ---- prep: the launch record (a resume needs the args byte-exact) + the script step
const PATHS = (/^([A-Za-z]:|[\\/])/.test(C) ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.') +
 '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 } return h.toString(16).padStart(8, '0') }
const AJ = JSON.stringify(A), AF = `${rp('launches')}/args-tidy-tidy.json`
const STEP = { type: 'object', properties: { ok: { type: 'boolean' }, record: { type: 'string' }, prep: { type: 'string' } }, required: ['ok', 'record', 'prep'] }
phase('Prep')
let P = null
for (const [label, model] of [['prep', 'haiku'], ['prep-retry', 'sonnet']]) {
 const r = await agent(`STEP: record this workflow's launch args, then run the tidy script step. Do exactly this, nothing else:${PATHS}
1. Write the line between the markers to ${AF} with the Write tool, byte for byte (one line of JSON; no markers, nothing added):
<<<ARGS
${AJ}
ARGS>>>
2. Run in PowerShell: & ${C}/skills/orchestrate/orch.ps1 launch -Self -Script tidy.js -Run 'tidy' -ArgsFile '${AF}' -Fnv ${fnv(AJ)} -Plan 'step/haiku:1,kitty/:1'
 (MISMATCH = the file differs: write it again once, re-run.) record = its full output.
3. Run in PowerShell (takes up to 2 min): & ${C}/skills/orchestrate/orch.ps1 tidy prep -Json
 prep = its last output line (one line of JSON), verbatim.
Return ok=true when step 3 printed the JSON line.`, { label, phase: 'Prep', schema: STEP, agentType: 'kitty', model, effort: 'low' })
 try { P = JSON.parse((r && r.prep) || ''); break } catch (e) { P = null }
}
if (!P) return { applied: [], proposedForApproval: [], rejected: [], report: 'tidy prep failed twice: run orch.ps1 tidy prep by hand' }
log(`tidy prep: ${P.work} item(s), ${P.groups} group(s) of 2+, ${P.sec} s: ${(P.steps || []).join(', ')}`)
if (!P.work) return { applied: [], proposedForApproval: [], rejected: [], report: P.digest, stamped: P.stamped }

// ---- judge: one kitty on the digest
phase('Judge')
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
const res = await agent(`Kind retro (judge): you maintain the kit (${C}). The script step did the counting and the upkeep; you only judge.${PATHS}
Time box: ${P.minutes || 3} min. Read ${P.digest} (nothing else unless a line needs its source to decide).

1. Lessons (& ${C}/skills/orchestrate/orch.ps1 learn): a "Signal groups" line with "-> lesson" = -Skill <s> -Bump "<words of that lesson>";
 a group without one = -Skill <s> -Lesson "<one line, <= 50 words, how to avoid it> (n×)" (org- or project-specific: add -Project <name>, it goes to LESSONS.local.md);
 a single signal only when it is a clear win or a hard failure; a "seen again" line = a regression: list it as a script-change proposal.
 Then -Skill <s> -Trim for every skill you touched (never delete lessons by hand).
2. Rules: a lesson at (3×) or more and still true -> a short rule in its SKILL.md or rules/*.md, then learn -Skill <s> -Fixed "<words>".
3. Scripts, defaults, templates (guard blocks, script errors, slow builds, failed upkeep steps): ${A.applyScripts ? 'apply the smallest fix, re-parse every changed .ps1 ([System.Management.Automation.Language.Parser]::ParseFile) and node --check every changed .js/.mjs; revert one that breaks.' : 'list each with the exact edit (file, function, new value); do not apply.'}
4. Write the report to ${rp('retros')}/retro-<yyyy-MM-dd-HHmm>.md: changed (with the digest counts), awaiting approval, rejected.
5. python -X utf8 ${C}/skills/orchestrate/kittool.py lint: fix what your edits broke; list the rest in the report.
6. & ${C}/skills/orchestrate/orch.ps1 tidy done -At '${P.at}' (marks these signals reviewed).
Return the lists and the report path.`, { label: 'apply', phase: 'Judge', schema: RESULT, agentType: 'kitty' })

log(`applied ${res ? res.applied.length : 0}, awaiting approval ${res ? res.proposedForApproval.length : 0}`)
return res || { applied: [], proposedForApproval: [], rejected: [], report: `judge returned nothing: digest ${P.digest}, last retro not stamped` }
