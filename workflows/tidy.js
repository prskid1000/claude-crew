export const meta = {
 name: 'tidy',
 description: 'Kit upkeep by kitty (kind retro) in 2-5 min: one script step (bossy.ps1 tidy prep: digest of signals, task outcomes, guard blocks, script errors, builds, runs, lint, params + the upkeep, standing-rule asks: param learn, cleanup, worktree prune, signal counting), then one kitty judges the digest: lessons, rule edits, script proposals',
 whenToUse: 'A /buildy or /testy finished (any outcome), the session-start nudge says signals piled up, or the owner asks for a kit retrospective',
 phases: [
  { title: 'Prep', detail: 'one STEP: launch record + bossy.ps1 tidy prep (no LLM work)' },
  { title: 'Judge', detail: 'one kitty: lesson wording, rule edits, script proposals, retro report, tidy done' },
 ],
}

// Sections: L12 args · L28 prep · L54 judge
// ---- args: all optional
/* args (all optional): {
 applyScripts: false,  // true: also apply script/default edits
 kitDir: 'C:/work/.claude',  // absolute (recommended); default '.claude' under workspace root
 runtimeDir: 'C:/work/.claude/.runtime',  // default <kitDir>/.runtime
 mandate: ['<the owner words, verbatim>'],  // as for every workflow (bossy step 3): the judge reads it as WHY
 model: '<model>',  // every step on it (a live models.override: supervise names it); default haiku / sonnet
} */
const A = args || {}
const badArgs = Object.keys(A).filter((k) => !['applyScripts', 'kitDir', 'runtimeDir', 'mandate', 'model'].includes(k))   // refused, never dropped
if (badArgs.length) throw new Error(`tidy.js args refused: unknown ${badArgs.join(', ')}`)
const C = (A.kitDir || '.claude').replace(/[\\/]+$/, '')
const RT = (A.runtimeDir || `${C}/.runtime`).replace(/[\\/]+$/, '')
// kit paths by name: the same names and values as skills/crafty/kit.example.json _paths (kit-lint RUNTIME-MAP keeps them equal)
const KP = {"runtime": {"retros": "logs/retros/", "launches": "work/launches/"}, "durable": {}}
const rp = (n) => (n in KP.durable ? `${C}/.state/${KP.durable[n]}` : `${RT}/${KP.runtime[n]}`).replace(/\/$/, '')
// ---- prep: the launch record (a resume needs the args byte-exact) + the script step
const PATHS = (/^([A-Za-z]:|[\\/])/.test(C) ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.') +
 '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 } return h.toString(16).padStart(8, '0') }
const AJ = JSON.stringify(A), AF = `${rp('launches')}/args-tidy-tidy.json`
const STEP = { type: 'object', properties: { ok: { type: 'boolean' }, record: { type: 'string' }, prep: { type: 'string' }, run: { type: 'string' } }, required: ['ok', 'record', 'prep', 'run'] }
phase('Prep')
let P = null, RUN = 'tidy'   // N3 run id from the prep step (legacy: 'tidy')
for (const [label, model] of [['prep', A.model || 'haiku'], ['prep-retry', A.model || 'sonnet']]) {
 const r = await agent(`STEP: record this workflow's launch args, then run the tidy script step. Do exactly this, nothing else:${PATHS}
1. Write the line between the markers to ${AF} with the Write tool, byte for byte (one line of JSON; no markers, nothing added):
<<<ARGS
${AJ}
ARGS>>>
2. run = the line python -X utf8 ${C}/skills/bossy/kitbag.py naming next name tidy prints (tidy; a tie tidy-2). Run in PowerShell: & ${C}/skills/bossy/bossy.ps1 launch -Self -Script tidy.js -Run '<run>' -ArgsFile '${AF}' -Fnv ${fnv(AJ)} -Plan 'step/${A.model || 'haiku'}:1,kitty/:1'
 (MISMATCH = the file differs: write it again once, re-run.) record = its full output.
3. Run in PowerShell (takes up to 2 min): & ${C}/skills/bossy/bossy.ps1 tidy prep -Json
 prep = its last output line (one line of JSON), verbatim.
Return ok=true when step 3 printed the JSON line.`, { label, phase: 'Prep', schema: STEP, agentType: 'steppy', ...(label !== 'prep' && { agentType: 'kitty' }), model, effort: 'low' })   // retry: kitty (a session without steppy)
 try { P = JSON.parse((r && r.prep) || ''); RUN = /^tidy(?:-[a-z0-9]+)*$/.test(r.run) ? r.run : 'tidy'; break } catch (e) { P = null }
}
if (!P) return { applied: [], proposedForApproval: [], rejected: [], report: 'tidy prep failed twice: run bossy.ps1 tidy prep by hand' }
log(`tidy prep: ${P.work} item(s), ${P.groups} group(s) of 2+, ${P.sec} s: ${(P.steps || []).join(', ')}`)
const PN = [].concat(P.parity || []).map((c) => `parity next: ${c}`)   // script-ranked (kitbag.py parity next); a parity kitty closes them
if (!P.work) return { applied: [], proposedForApproval: PN, rejected: [], report: P.digest, stamped: P.stamped }

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
const JP = `Kind retro (judge): you maintain the kit (${C}). The script step did the counting and the upkeep; you only judge.${PATHS}${A.mandate && [].concat(A.mandate).length ? `\nWHY: the owner asked, verbatim:\n${[].concat(A.mandate).map((m) => `  "${m}"`).join('\n')}` : ''}
Time box: ${P.minutes || 3} min. Read ${P.digest} (nothing else unless a line needs its source to decide).

0. Worktree (${C} is the live clone: a changed tracked file there blocks the coordinator's pull): & ${C}/skills/crafty/crafty.ps1 wt new -Repo ${C} -Branch kit/${RUN} -Target main -Name ${RUN}; W = its dir. Steps 1-3 and 5 use W's copies (W/skills/bossy/bossy.ps1 learn, W/skills/bossy/kitbag.py, edits in W), never ${C}'s.
1. Lessons (& W/skills/bossy/bossy.ps1 learn): a "Signal groups" line with "-> lesson" = -Skill <s> -Bump "<words of that lesson>";
 a group without one = -Skill <s> -When "<situation>" -Do "<how to avoid it>" -Why "<the cost seen>" (one line <= 50 words) (org-, project- or vendor-specific (names a product, host, tracker, DB or tool our config picks): add -Project <name>, it goes to LESSONS.local.md);
 a single signal only when it is a clear win or a hard failure; a "seen again" line = a regression: list it as a script-change proposal.
 Then -Skill <s> -Trim for every skill you touched (never delete lessons by hand), then python -X utf8 W/skills/bossy/kitbag.py forget --target over-cap --apply
 (forget on cap: content is cut and archived; a BATCH line = features: run its decide ask once, never remove them yourself).
2. Rules: a lesson at (3×) or more and still true -> a short rule in its SKILL.md or rules/*.md, then learn -Skill <s> -Fixed "<words>".
 "Outcomes" lines (results, not friction): a repeat cause or an area / agent with most fix rounds -> a lesson (-Skill of the step that failed) or a rule edit for the brief or check that would have caught it.
 A "waste:" signal (ref waste:<role>:<kind>, its fix kind in the text) is never left open: apply that fix in step 3 with the commit trailer "Waste-Fix: <its ref>" (Waste panel: fixed once no later run shows it), or close it: learn -Skill <role> -Kind false-positive -Text "<why not>" -Ref <its ref> (Waste panel: ignored, that reason).
 "Standing rules proposed": the script already asked the owner (one decide ask); never apply one. An approved rule that holds for any org -> propose it as a kit rule edit.
3. Scripts, defaults, templates (guard blocks, script errors, slow builds, failed upkeep steps): ${A.applyScripts ? 'apply the smallest fix, re-parse every changed .ps1 ([System.Management.Automation.Language.Parser]::ParseFile) and node --check every changed .js/.mjs; revert one that breaks.' : 'list each with the exact edit (file, function, new value); do not apply.'}
4. The report is rendered, never hand-written: write retro.json { "date", "applied": [{ "change", "file", "count" }], "proposed":
 [{ "proposal", "edit" }], "rejected": [{ "signal", "why" }], "lint" } (ids, paths, commands in backticks), then python -X utf8
 ${C}/skills/crafty/devtools.py render retro retro.json ${rp('retros')}/${RUN}.md.
5. python -X utf8 W/skills/bossy/kitbag.py lint: fix what your edits broke; list the rest in the report. Ship W: & ${C}/skills/crafty/crafty.ps1 wt commit -Dir W, git -C W rebase origin/main, git -C W push origin HEAD:main (fast-forward only), & ${C}/skills/crafty/crafty.ps1 wt remove -Dir W; a refused push goes in the report, never into ${C}.
6. & ${C}/skills/bossy/bossy.ps1 tidy done -At '${P.at}' (marks these signals reviewed).
Return the lists and the report path.`
let res = await agent(JP, { label: 'apply', phase: 'Judge', schema: RESULT, agentType: 'kitty', model: A.model || 'sonnet' })   // kitty kind retro: sonnet (bossy K1)
// no result (2026-11-25 login race): one retry after a wait that checks what is done first: never a second worktree, edit or push
if (!res) { log('apply: redo'); if (typeof setTimeout === 'function') await new Promise((ok) => setTimeout(ok, 20000))
 res = await agent(`No report came back: first find what is done: ${rp('retros')}/${RUN}.md exists -> return its lists, edit nothing, run step 6 if its signals are not marked reviewed; a kit/${RUN} worktree (git -C ${C} worktree list) -> continue in it, never a second; a pushed commit is never redone.\n${JP}`, { label: 'apply@redo', phase: 'Judge', schema: RESULT, agentType: 'kitty', model: A.model || 'sonnet' }) }

if (res) res.proposedForApproval = [].concat(res.proposedForApproval || [], PN)
log(`applied ${res ? res.applied.length : 0}, awaiting approval ${res ? res.proposedForApproval.length : 0}`)
return res || { applied: [], proposedForApproval: PN, rejected: [], report: `judge returned nothing: digest ${P.digest}, last retro not stamped` }
