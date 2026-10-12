#!/usr/bin/env python3
"""Render the kit's trigger flow as one self-contained HTML page (no external libraries, works from file://).

  python kit-flow.py [<kit .claude dir>] [--out <file.html>] [--watch] [--open]

Default kit dir: the .claude folder this script lives in. Default output: <runtime>/kit-flow.html, where runtime is
$CLAUDE_RUNTIME or <workspace>/.claude-runtime (the folder next to .claude). --watch regenerates whenever a kit file is
added, removed or changed (poll every 2 s); the page's "Live" toggle reloads it and keeps the selection.

Columns: Entry (CLAUDE.md, rules, settings) -> Triggers (skills, workflows, agent types, hook scripts) -> Step docs
(reference, templates, lessons, config examples) -> Scripts. Edge types: route (always-loaded instructions name a
skill/workflow/agent), scoped (path-scoped rule), hook (settings.json runs a script), spawn (workflow starts an agent
type), index (a SKILL.md names one of its own files), loads (a file names another skill), calls (script -> script),
mention (any other mention). Structural reach = reach over every type except mention; files reached only through
mentions are flagged, because nothing in the flow actually sends an agent there.
"""
import json, os, re, subprocess, sys, time
from collections import defaultdict, deque

SKIP_DIRS = {'node_modules', '__pycache__', '.git'}
TEXT_EXT = ('.md', '.ps1', '.psm1', '.py', '.js', '.mjs', '.json', '.html', '.txt', '.sh', '.yml', '.yaml', '.ini')
JUNK_EXT = ('.apk', '.aab', '.log', '.zip', '.tmp')
RESERVED = {'nul', 'con', 'prn', 'aux'}


def args():
    a = sys.argv[1:]
    kit = next((x for x in a if not x.startswith('--') and (a.index(x) == 0 or a[a.index(x) - 1] != '--out')), None)
    kit = os.path.abspath(kit or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
    out = a[a.index('--out') + 1] if '--out' in a else None
    if not out:
        rt = os.environ.get('CLAUDE_RUNTIME') or os.path.join(os.path.dirname(kit), '.claude-runtime')
        out = os.path.join(rt, 'kit-flow.html')
    return kit, os.path.abspath(out), '--watch' in a, '--open' in a


def walk(kit):
    files, junk = [], []
    for d, dirs, fs in os.walk(kit):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for f in fs:
            p = os.path.join(d, f)
            if f.lower() in RESERVED:
                junk.append(('reserved-name file', os.path.relpath(p, kit).replace('\\', '/')))
                continue
            rel = os.path.relpath(p, kit).replace('\\', '/')
            if f.lower().endswith(JUNK_EXT):
                junk.append(('runtime output inside .claude', rel))
                continue
            files.append(rel)
    return sorted(files), junk


def read(kit, f):
    try:
        return open(os.path.join(kit, f), encoding='utf-8', errors='replace').read()
    except OSError:
        return ''


def frontmatter(text):
    m = re.match(r'^---\s*\n(.*?)\n---', text, re.S)
    fm, key = {}, None
    if not m:
        return fm
    for line in m.group(1).splitlines():
        mm = re.match(r'^([\w-]+):\s*(.*)$', line)
        if mm:
            key, val = mm.group(1), mm.group(2).strip()
            fm[key] = '' if val in ('>-', '>', '|', '|-') else val.strip('"\'')
        elif key and line.startswith((' ', '\t')):
            fm[key] = (fm[key] + ' ' + line.strip().strip('"\'')).strip()
    return fm


def local_only(kit):
    try:
        cfg = json.load(open(os.path.join(kit, 'skills', 'dev-kit', 'kit.local.json'), encoding='utf-8'))
        return [p.replace('\\', '/').rstrip('/') for p in cfg.get('localOnly', [])]
    except (OSError, ValueError):
        return []


def build(kit):
    files, junk = walk(kit)
    fileset = set(files)
    by_base = defaultdict(list)
    for f in files:
        by_base[os.path.basename(f).lower()].append(f)
    skills = sorted({f.split('/')[1] for f in files if f.startswith('skills/') and f.endswith('/SKILL.md') and f.count('/') == 2})
    agents = {os.path.basename(f)[:-3]: f for f in files if f.startswith('agents/') and f.endswith('.md')}
    workflows = {os.path.basename(f)[:-3]: f for f in files if f.startswith('workflows/') and f.endswith('.js')}
    locals_ = local_only(kit)
    texts = {f: read(kit, f) for f in files if f.lower().endswith(TEXT_EXT)}

    def skill_of(f):
        return f.split('/')[1] if f.startswith('skills/') and f.count('/') >= 2 else None

    def is_local(f):
        b = os.path.basename(f)
        return '.local.' in b or b == 'settings.local.json' or any(f == p or f.startswith(p + '/') for p in locals_)

    # ---- node kinds and columns
    hook_targets = {}
    try:
        sj = json.loads(texts.get('settings.json', '{}') or '{}')
        for event, blocks in (sj.get('hooks') or {}).items():
            for b in blocks:
                for h in b.get('hooks', []):
                    blob = ' '.join([h.get('command', '')] + list(h.get('args', [])))
                    m = re.search(r'\.claude[\\/]([\w./\\-]+\.(?:ps1|py|js|sh))', blob)
                    if m and m.group(1).replace('\\', '/') in fileset:
                        tgt = m.group(1).replace('\\', '/')
                        hook_targets.setdefault(tgt, []).append(event + (f" ({b['matcher']})" if b.get('matcher') else ''))
    except ValueError:
        pass

    def kind(f):
        b = os.path.basename(f)
        if f == 'CLAUDE.md':
            return 'root'
        if f.startswith('rules/'):
            return 'rule-scoped' if 'paths' in frontmatter(texts.get(f, '')) else 'rule'
        if b.startswith('settings') and b.endswith('.json') and '/' not in f:
            return 'settings'
        if f.startswith('agents/'):
            return 'agent'
        if f.startswith('workflows/'):
            return 'workflow'
        if b == 'SKILL.md':
            return 'skill'
        if f in hook_targets:
            return 'hook'
        if b == 'LESSONS.md':
            return 'lessons'
        if b == 'HISTORY.md':
            return 'history'
        if '/reference/' in f:
            return 'reference'
        if '/templates/' in f:
            return 'template'
        if '.example.' in b or b.endswith('.local.json') or b in ('swarm.config.json', 'swarm.json'):
            return 'config'
        if f.endswith(('.ps1', '.psm1', '.py', '.js', '.mjs', '.sh')):
            return 'script'
        return 'other'

    COL = {'root': 0, 'rule': 0, 'rule-scoped': 0, 'settings': 0, 'skill': 1, 'workflow': 1, 'agent': 1, 'hook': 1,
           'reference': 2, 'template': 2, 'lessons': 2, 'history': 2, 'config': 2, 'other': 2, 'script': 3}

    def trigger(f, k):
        t = texts.get(f, '')
        fm = frontmatter(t)
        if k in ('skill', 'agent'):
            return fm.get('description', '')
        if k == 'rule-scoped':
            fmm = re.match(r'^---\s*\n(.*?)\n---', t, re.S)
            paths = re.findall(r'^\s*-\s*"?([^"\n]+)"?', fmm.group(1), re.M) if fmm else []
            return 'Loaded when a file matching ' + ', '.join(paths) + ' is opened'
        if k == 'rule':
            return 'Always loaded into every session'
        if k == 'root':
            return 'Always loaded: the project CLAUDE.md'
        if k == 'workflow':
            d = re.search(r"description:\s*'((?:[^'\\]|\\.)*)'", t)
            w = re.search(r"whenToUse:\s*'((?:[^'\\]|\\.)*)'", t)
            return ((d.group(1) if d else '') + ('\nWhen: ' + w.group(1) if w else '\nWhen: (no whenToUse)')).strip()
        if k == 'hook':
            return 'Run by the harness on ' + ', '.join(hook_targets[f])
        if k == 'settings':
            return 'Harness settings: permissions and hooks'
        first = next((l.strip('# ').strip() for l in t.splitlines() if l.strip() and not l.startswith(('---', '#!', '<#', '"""', 'import', '$', 'param', 'export const meta'))), '')
        return first[:220]

    nodes = {}
    for f in files:
        k = kind(f)
        nodes[f] = {'id': f, 'label': os.path.basename(f) if f.count('/') else f, 'kind': k, 'col': COL[k],
                    'group': skill_of(f) or ('agents' if k == 'agent' else 'workflows' if k == 'workflow' else 'kit'),
                    'local': is_local(f), 'trigger': trigger(f, k)}
        if k == 'skill':
            nodes[f]['label'] = skill_of(f)
        if k in ('agent', 'workflow'):
            nodes[f]['label'] = os.path.basename(f).rsplit('.', 1)[0]

    # ---- edges
    PATH_RE = re.compile(r'[\w./\\<>*{}$-]*?([\w.-]+\.(?:md|ps1|psm1|py|js|mjs|json|html|txt|sh|ini))\b')
    always = {f for f, n in nodes.items() if n['kind'] in ('root', 'rule')}
    edges, dangling = {}, defaultdict(set)
    IGNORE_DANGLING = {'package.json', 'angular.json', 'tsconfig.json', 'settings.json', 'run.json', 'results.json', 'held.json',
                       'history.json', 'journal.jsonl', 'body.md', 'claude.md', 'skill.md', 'lessons.md', 'history.md', 'readme.md',
                       'pom.xml', 'requirements.txt', 'pyproject.toml'}

    def etype(src, dst):
        ks, kd = nodes[src]['kind'], nodes[dst]['kind']
        if ks == 'settings' and kd == 'hook':
            return 'hook'
        if src in always and kd in ('skill', 'workflow', 'agent'):
            return 'route'
        if ks == 'rule-scoped' and kd in ('skill', 'workflow', 'agent', 'reference', 'script'):
            return 'scoped'
        if ks == 'workflow' and kd == 'agent':
            return 'spawn'
        if ks in ('lessons', 'history'):
            return 'mention'
        if ks == 'skill' and skill_of(dst) == skill_of(src):
            return 'index'
        if kd == 'skill':
            return 'loads'
        if ks in ('script', 'hook') and kd in ('script', 'hook'):
            return 'calls'
        if ks in ('reference', 'template') and skill_of(src) == skill_of(dst) and kd in ('reference', 'template', 'script'):
            return 'index'
        return 'mention'

    def add(src, dst):
        if src != dst and dst in nodes:
            edges.setdefault((src, dst), etype(src, dst))

    for src, t in texts.items():
        sdir = os.path.dirname(src)
        for m in PATH_RE.finditer(t):
            full = m.group(0).replace('\\', '/').strip('`\'"()[],:;')
            base = m.group(1)
            hit = None
            for cand in (os.path.normpath(os.path.join(sdir, full)).replace('\\', '/'), re.sub(r'^.*?\.claude/', '', full),
                         ('skills/' + full.split('skills/', 1)[1]) if 'skills/' in full else None):
                if cand and cand in fileset:
                    hit = cand
                    break
            if not hit:
                hits = by_base.get(base.lower(), [])
                same = [h for h in hits if skill_of(h) and skill_of(h) == skill_of(src)]
                hit = (same or hits or [None])[0] if (len(hits) == 1 or same) else None
            if hit:
                add(src, hit)
            elif not re.search(r'[<>*{}$]', full) and base.lower() not in IGNORE_DANGLING and '.local.' not in base \
                    and not full.startswith(('http', '//')) and nodes.get(src, {}).get('kind') not in ('history', 'lessons'):
                # only kit-looking paths count (example file names, runtime outputs and personal tools are not kit links)
                kitlike = re.match(r'^(?:\./|\.\./)*(?:\.claude/)?(?:skills|scripts|reference|templates|agents|workflows|rules|docs)/', full)
                if kitlike and '/.../' not in full and base.lower() not in by_base and src.endswith(('.md', '.js')):
                    dangling[src].add(full)
        for s in skills:
            if re.search(r'(?<![\w-])' + re.escape(s) + r'(?![\w-])', t):
                add(src, f'skills/{s}/SKILL.md')
        for n, f in agents.items():
            if re.search(r'(?<![\w-])' + re.escape(n) + r'(?![\w-])', t):
                add(src, f)
        for n, f in workflows.items():
            if re.search(r'(?<![\w-])/?' + re.escape(n) + r'(?![\w-])', t):
                add(src, f)
    for tgt in hook_targets:
        for s in ('settings.json',):
            if s in nodes:
                edges[(s, tgt)] = 'hook'

    # ---- reach: entries -> structural edges (no mentions)
    entries = [f for f, n in nodes.items() if n['kind'] in ('root', 'rule', 'rule-scoped', 'settings', 'skill', 'agent', 'workflow')]
    out = defaultdict(list)
    for (a, b), t in edges.items():
        out[a].append((b, t))
    prev = {e: None for e in entries}
    q = deque(entries)
    while q:
        cur = q.popleft()
        for nxt, t in out[cur]:
            if t != 'mention' and nxt not in prev:
                prev[nxt] = cur
                q.append(nxt)
    any_reach = set(prev)
    q = deque(any_reach)
    while q:
        cur = q.popleft()
        for nxt, _ in out[cur]:
            if nxt not in any_reach:
                any_reach.add(nxt)
                q.append(nxt)
    for f, n in nodes.items():
        chain, c = [], f
        while c is not None and c in prev:
            chain.append(c)
            c = prev[c]
        n['chain'] = list(reversed(chain)) if f in prev else []
        n['reach'] = 'entry' if f in entries else 'structural' if f in prev else 'mention-only' if f in any_reach else 'none'

    issues = []
    skip_reach = ('history', 'other')
    for f, n in sorted(nodes.items()):
        if n['reach'] == 'none' and n['kind'] not in skip_reach and not f.startswith('.git'):
            issues.append({'type': 'unreached', 'id': f, 'text': 'nothing in the kit points here'})
        elif n['reach'] == 'mention-only' and n['kind'] not in skip_reach:
            issues.append({'type': 'accidental', 'id': f, 'text': 'reached only through a mention (no route/index/call leads here)'})
        if n['kind'] == 'skill' and not re.search(r'Load when', n['trigger'] or '', re.I):
            issues.append({'type': 'fuzzy trigger', 'id': f, 'text': 'description has no "Load when:" condition'})
        if n['kind'] == 'agent' and not re.search(r'spawn', n['trigger'] or '', re.I):
            issues.append({'type': 'fuzzy trigger', 'id': f, 'text': 'description does not say who spawns it'})
        if n['kind'] == 'workflow' and '(no whenToUse)' in n['trigger']:
            issues.append({'type': 'fuzzy trigger', 'id': f, 'text': 'workflow meta has no whenToUse'})
    for src, ds in sorted(dangling.items()):
        for d in sorted(ds):
            issues.append({'type': 'dangling', 'id': src, 'text': f'mentions {d}, which is not a kit file'})
    for why, f in junk:
        issues.append({'type': 'junk', 'id': None, 'text': f'{f}: {why}'})

    return {'kit': kit, 'generated': time.strftime('%Y-%m-%d %H:%M:%S'),
            'nodes': list(nodes.values()), 'edges': [{'s': a, 't': b, 'type': t} for (a, b), t in sorted(edges.items())],
            'issues': issues,
            'counts': {'files': len(files), 'edges': len(edges), 'structural': sum(1 for n in nodes.values() if n['reach'] in ('entry', 'structural')),
                       'issues': len(issues)}}


PAGE = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kit Trigger Flow</title>
<style>
:root{--bg:#f6f7f9;--panel:#fff;--ink:#1d2330;--muted:#667085;--line:#d0d5dd;--chip:#eef1f5;--hi:#ffb020;
--route:#2f6fed;--scoped:#7a5af8;--hook:#e5484d;--spawn:#12a594;--index:#8b95a5;--loads:#d97706;--calls:#0e9f6e;--mention:#c3c9d4;
--k-root:#1d2330;--k-rule:#3b4a6b;--k-skill:#2f6fed;--k-workflow:#12a594;--k-agent:#7a5af8;--k-hook:#e5484d;--k-ref:#d97706;--k-script:#0e9f6e;--k-other:#8b95a5}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#0f1218;--panel:#171b23;--ink:#e6e9ef;--muted:#98a2b3;--line:#2a303c;--chip:#222836;
--k-root:#e6e9ef;--k-rule:#a9b4cc;--mention:#3a4252;--index:#6b7486}}
:root[data-theme=dark]{--bg:#0f1218;--panel:#171b23;--ink:#e6e9ef;--muted:#98a2b3;--line:#2a303c;--chip:#222836;--k-root:#e6e9ef;--k-rule:#a9b4cc;--mention:#3a4252;--index:#6b7486}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:13px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center;padding:10px 16px;background:var(--panel);border-bottom:1px solid var(--line)}
h1{font-size:15px;margin:0 8px 0 0}.meta{color:var(--muted);font-size:12px}
input[type=search]{padding:6px 10px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--ink);min-width:200px}
.toggles{display:flex;flex-wrap:wrap;gap:6px}.tg{display:inline-flex;align-items:center;gap:5px;padding:3px 8px;border-radius:999px;background:var(--chip);cursor:pointer;user-select:none;font-size:12px}
.tg i{width:10px;height:3px;border-radius:2px;display:inline-block}.tg.off{opacity:.35}
button{border:1px solid var(--line);background:var(--chip);color:var(--ink);border-radius:8px;padding:5px 10px;cursor:pointer;font:inherit}
button.warn{background:#e5484d;color:#fff;border-color:#e5484d}
main{display:flex;min-height:calc(100vh - 56px)}#wrap{flex:1;overflow:auto;position:relative}
#canvas{position:relative}svg{position:absolute;left:0;top:0;pointer-events:none}
.colhead{position:absolute;top:8px;font-weight:600;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;font-size:11px}
.grp{position:absolute;font-size:11px;color:var(--muted);font-weight:600}
.n{position:absolute;height:24px;display:flex;align-items:center;gap:6px;padding:0 8px;border-radius:7px;background:var(--panel);border:1px solid var(--line);cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:12px;transition:opacity .12s}
.n b{width:8px;height:8px;border-radius:50%;flex:none}.n.local{border-style:dashed}.n.bad{box-shadow:inset 3px 0 0 #e5484d}.n.acc{box-shadow:inset 3px 0 0 #f5a524}
.n.big{height:30px;font-weight:600;font-size:13px}.dim .n:not(.on){opacity:.18}.n.sel{outline:2px solid var(--hi)}.n.match{outline:2px dashed var(--hi)}
path{fill:none;stroke-width:1.3;opacity:.75}.dim path:not(.on){opacity:.06}path.on{stroke-width:2.2;opacity:1}
aside{width:380px;max-width:42vw;border-left:1px solid var(--line);background:var(--panel);padding:14px 16px;overflow:auto;position:sticky;top:56px;height:calc(100vh - 56px)}
aside h2{font-size:14px;margin:0 0 4px}aside .path{font-family:ui-monospace,Consolas,monospace;font-size:11.5px;color:var(--muted);word-break:break-all}
.kind{display:inline-block;padding:1px 8px;border-radius:999px;background:var(--chip);font-size:11px;margin:6px 6px 6px 0}
.trig{white-space:pre-wrap;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:8px 10px;margin:8px 0;font-size:12.5px}
.chain{display:flex;flex-wrap:wrap;gap:4px;align-items:center;margin:6px 0}.chain a,.lst a{color:var(--route);cursor:pointer;text-decoration:none}
.lst{margin:4px 0 10px;padding:0;list-style:none}.lst li{padding:2px 0;font-size:12.5px}.et{display:inline-block;min-width:58px;font-size:11px;color:var(--muted)}
.iss{padding:6px 0;border-bottom:1px solid var(--line);font-size:12.5px}.iss em{font-style:normal;font-weight:600;color:#e5484d}.iss.accidental em{color:#d97706}
.legend{display:grid;grid-template-columns:auto 1fr;gap:4px 10px;font-size:12px;color:var(--muted);margin-top:10px}
@media (max-width:760px){main{flex-direction:column}aside{width:auto;max-width:none;position:static;height:auto;border-left:0;border-top:1px solid var(--line)}}
</style></head><body>
<header><h1>Kit trigger flow</h1><span class="meta" id="meta"></span>
<input type="search" id="q" placeholder="Search files, triggers…">
<div class="toggles" id="tgs"></div>
<button id="issuesBtn"></button><label class="tg" title="Reload every 5 s (run kit-flow.py --watch)"><input type="checkbox" id="live"> Live</label>
<button id="theme" title="Theme">◐</button></header>
<main><div id="wrap"><div id="canvas"><svg id="svg"></svg></div></div><aside id="side"></aside></main>
<script>
const D = __DATA__;
const ET = {route:'Route (always-loaded → trigger)',scoped:'Scoped rule',hook:'Hook (harness runs it)',spawn:'Spawn (workflow → agent)',index:'Index (skill → its file)',loads:'Loads another skill',calls:'Calls script',mention:'Mention only'};
const KC = {root:'--k-root',rule:'--k-rule','rule-scoped':'--k-rule',settings:'--k-rule',skill:'--k-skill',workflow:'--k-workflow',agent:'--k-agent',hook:'--k-hook',reference:'--k-ref',template:'--k-ref',lessons:'--k-ref',history:'--k-other',config:'--k-other',script:'--k-script',other:'--k-other'};
const store = {get(k,d){try{const v=localStorage.getItem('kitflow.'+k);return v===null?d:JSON.parse(v)}catch(e){return d}},set(k,v){try{localStorage.setItem('kitflow.'+k,JSON.stringify(v))}catch(e){}}};
const byId = Object.fromEntries(D.nodes.map(n=>[n.id,n]));
const shown = store.get('types',{route:1,scoped:1,hook:1,spawn:1,index:1,loads:1,calls:1,mention:0});
let sel = store.get('sel',null); if(sel && !byId[sel]) sel=null;
document.getElementById('meta').textContent = `${D.counts.files} files · ${D.counts.edges} edges · ${D.counts.structural} reached structurally · generated ${D.generated}`;
const ib = document.getElementById('issuesBtn'); ib.textContent = `${D.issues.length} issues`; if(D.issues.length) ib.className='warn';
// ---- layout
const COLX=[16,300,600,900], W=[250,270,270,250], COLN=['Entry (always / scoped / hooks)','Triggers (skills, workflows, agents, hooks)','Step docs (reference, templates, lessons)','Scripts'];
const order = {root:0,rule:1,'rule-scoped':2,settings:3,skill:0,workflow:1,agent:2,hook:3,reference:0,template:1,lessons:2,config:3,history:4,other:5,script:0};
const grpOrder = g => g==='kit'?'0':g==='workflows'?'1':g==='agents'?'2':'3'+g;
const pos={}, canvas=document.getElementById('canvas'), svg=document.getElementById('svg');
let maxY=0;
for(let c=0;c<4;c++){
  const h=document.createElement('div');h.className='colhead';h.style.left=COLX[c]+'px';h.textContent=COLN[c];canvas.appendChild(h);
  const ns=D.nodes.filter(n=>n.col===c).sort((a,b)=>grpOrder(a.group).localeCompare(grpOrder(b.group))||order[a.kind]-order[b.kind]||a.label.localeCompare(b.label));
  let y=34, g=null;
  for(const n of ns){
    if(c>=1 && n.group!==g){ g=n.group; y+= (y>34?12:0); const gh=document.createElement('div');gh.className='grp';gh.style.left=COLX[c]+'px';gh.style.top=y+'px';gh.textContent=g;canvas.appendChild(gh); y+=18;}
    const big = c<=1; const hgt = big?30:24;
    pos[n.id]={x:COLX[c],y,w:W[c],h:hgt};
    const el=document.createElement('div'); el.className='n'+(big?' big':'')+(n.local?' local':'')+(n.reach==='none'&&n.kind!=='history'?' bad':n.reach==='mention-only'?' acc':'');
    el.style.left=COLX[c]+'px';el.style.top=y+'px';el.style.width=W[c]+'px';el.dataset.id=n.id;el.title=n.id;
    el.innerHTML=`<b style="background:var(${KC[n.kind]||'--k-other'})"></b>${esc(n.label)}`;
    el.onclick=()=>select(n.id); el.onmouseenter=()=>hover(n.id); el.onmouseleave=()=>hover(null);
    canvas.appendChild(el); n.el=el; y+=hgt+6;
  }
  maxY=Math.max(maxY,y);
}
canvas.style.width=(COLX[3]+W[3]+30)+'px'; canvas.style.height=(maxY+30)+'px'; svg.setAttribute('width',COLX[3]+W[3]+30); svg.setAttribute('height',maxY+30);
function esc(s){return String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
// ---- edges
const paths=[];
for(const e of D.edges){
  const a=pos[e.s], b=pos[e.t]; if(!a||!b) continue;
  let d;
  if(b.x>a.x){const x1=a.x+a.w,y1=a.y+a.h/2,x2=b.x,y2=b.y+b.h/2,m=(x2-x1)/2;d=`M${x1},${y1} C${x1+m},${y1} ${x2-m},${y2} ${x2},${y2}`}
  else{const x1=a.x+a.w,y1=a.y+a.h/2,x2=b.x+b.w,y2=b.y+b.h/2,o=40+Math.min(120,Math.abs(y2-y1)/6);d=`M${x1},${y1} C${x1+o},${y1} ${x2+o},${y2} ${x2},${y2}`}
  const p=document.createElementNS('http://www.w3.org/2000/svg','path');p.setAttribute('d',d);p.setAttribute('stroke',`var(--${e.type})`);
  if(e.type==='mention')p.setAttribute('stroke-dasharray','3 3');
  svg.appendChild(p); paths.push({p,e});
}
function applyTypes(){for(const {p,e} of paths)p.style.display=shown[e.type]?'':'none'}
const tgs=document.getElementById('tgs');
for(const t of Object.keys(ET)){const s=document.createElement('span');s.className='tg'+(shown[t]?'':' off');s.innerHTML=`<i style="background:var(--${t})"></i>${t}`;s.title=ET[t];
  s.onclick=()=>{shown[t]=shown[t]?0:1;s.classList.toggle('off',!shown[t]);store.set('types',shown);applyTypes();focus(sel)};tgs.appendChild(s)}
applyTypes();
// ---- highlight
function focus(id){
  canvas.classList.toggle('dim',!!id);
  for(const n of D.nodes)n.el.classList.remove('on','sel');
  for(const {p} of paths)p.classList.remove('on');
  if(!id)return;
  byId[id].el.classList.add('on','sel');
  for(const {p,e} of paths){if(!shown[e.type])continue;if(e.s===id||e.t===id){p.classList.add('on');byId[e.s].el.classList.add('on');byId[e.t].el.classList.add('on')}}
  const ch=byId[id].chain||[];for(let i=0;i<ch.length;i++){byId[ch[i]].el.classList.add('on');for(const {p,e} of paths)if(i&&e.s===ch[i-1]&&e.t===ch[i])p.classList.add('on')}
}
function hover(id){focus(id||sel)}
function select(id){sel=id;store.set('sel',id);focus(id);side(id)}
// ---- side panel
const sideEl=document.getElementById('side');
function link(id){const n=byId[id];return n?`<a data-go="${esc(id)}">${esc(n.label)}</a>`:esc(id)}
function side(id){
  if(!id){sideEl.innerHTML=overview();wire();return}
  const n=byId[id], inn=D.edges.filter(e=>e.t===id), out=D.edges.filter(e=>e.s===id);
  const reachTxt={entry:'Entry point: the harness or the router reaches it directly',structural:'Reached through the flow',
    'mention-only':'Only mentioned somewhere: no route, index or call leads here','none':'Unreached: nothing in the kit points here'}[n.reach];
  sideEl.innerHTML=`<h2>${esc(n.label)}</h2><div class="path">${esc(n.id)}</div>
  <span class="kind">${esc(n.kind)}</span>${n.local?'<span class="kind">local overlay</span>':''}<span class="kind">${esc(n.reach)}</span>
  ${n.trigger?`<div class="trig">${esc(n.trigger)}</div>`:''}
  <div class="meta">${reachTxt}</div>
  ${n.chain&&n.chain.length>1?`<h3 style="font-size:12px;margin:12px 0 2px">How an agent gets here</h3><div class="chain">${n.chain.map(link).join(' → ')}</div>`:''}
  <h3 style="font-size:12px;margin:12px 0 2px">Reached from (${inn.length})</h3><ul class="lst">${inn.map(e=>`<li><span class="et">${e.type}</span>${link(e.s)}</li>`).join('')||'<li class="meta">nothing</li>'}</ul>
  <h3 style="font-size:12px;margin:12px 0 2px">Leads to (${out.length})</h3><ul class="lst">${out.map(e=>`<li><span class="et">${e.type}</span>${link(e.t)}</li>`).join('')||'<li class="meta">nothing</li>'}</ul>
  ${D.issues.filter(i=>i.id===id).map(i=>`<div class="iss ${i.type}"><em>${esc(i.type)}</em> ${esc(i.text)}</div>`).join('')}`;
  wire();
}
function overview(){
  const by={};for(const i of D.issues)(by[i.type]=by[i.type]||[]).push(i);
  return `<h2>How to read this</h2><div class="meta">Click a node to see its trigger, how an agent reaches it, and what it leads to. Hover to preview. Toggle edge types above.</div>
  <div class="legend">${Object.entries(ET).map(([t,l])=>`<i style="width:22px;height:3px;background:var(--${t});align-self:center"></i><span>${l}</span>`).join('')}
  <span style="border-left:3px solid #e5484d;padding-left:6px">red bar</span><span>unreached</span><span style="border-left:3px solid #f5a524;padding-left:6px">amber bar</span><span>mention-only (accidental) reach</span><span style="border:1px dashed var(--line);padding:0 6px">dashed</span><span>local overlay (not published)</span></div>
  <h2 style="margin-top:16px">Issues (${D.issues.length})</h2>${Object.entries(by).map(([t,is])=>`<h3 style="font-size:12px;margin:10px 0 2px">${esc(t)} (${is.length})</h3>${is.map(i=>`<div class="iss ${i.type}">${i.id?link(i.id)+' — ':''}${esc(i.text)}</div>`).join('')}`).join('')||'<div class="meta">none</div>'}`;
}
function wire(){sideEl.querySelectorAll('[data-go]').forEach(a=>a.onclick=()=>{select(a.dataset.go);const p=pos[a.dataset.go];document.getElementById('wrap').scrollTo({top:p.y-120,left:Math.max(0,p.x-200),behavior:'smooth'})})}
ib.onclick=()=>select(null);
// ---- search
document.getElementById('q').oninput=e=>{const q=e.target.value.trim().toLowerCase();for(const n of D.nodes)n.el.classList.toggle('match',!!q&&(n.id.toLowerCase().includes(q)||(n.trigger||'').toLowerCase().includes(q)))};
// ---- theme + live reload
const root=document.documentElement;root.dataset.theme=store.get('theme','')||'';document.getElementById('theme').onclick=()=>{const t=root.dataset.theme==='dark'?'light':root.dataset.theme==='light'?'':'dark';root.dataset.theme=t;store.set('theme',t)};
const live=document.getElementById('live');live.checked=!!store.get('live',0);let tm=null;
function arm(){clearTimeout(tm);if(live.checked)tm=setTimeout(()=>{store.set('scroll',[wrapEl.scrollLeft,wrapEl.scrollTop]);location.reload()},5000)}
live.onchange=()=>{store.set('live',live.checked?1:0);arm()};
const wrapEl=document.getElementById('wrap');const sc=store.get('scroll',null);if(sc)wrapEl.scrollTo(sc[0],sc[1]);arm();
select(sel);
</script></body></html>'''


def render(kit, out):
    data = build(kit)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    blob = json.dumps(data, ensure_ascii=False).replace('</', '<\\/')
    open(out, 'w', encoding='utf-8').write(PAGE.replace('__DATA__', blob))
    c = data['counts']
    print(f"kit-flow: {out}  ({c['files']} files, {c['edges']} edges, {c['structural']} reached structurally, {c['issues']} issues)")
    return data


def signature(kit):
    sig = []
    for d, dirs, fs in os.walk(kit):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for f in fs:
            try:
                st = os.stat(os.path.join(d, f))
                sig.append((d, f, st.st_mtime_ns, st.st_size))
            except OSError:
                pass
    return hash(tuple(sorted(sig)))


if __name__ == '__main__':
    kit, out, watch, open_it = args()
    if not os.path.isdir(kit):
        sys.exit(f'kit-flow: no such folder {kit}')
    render(kit, out)
    if open_it:
        if sys.platform.startswith('win'):
            os.startfile(out)  # noqa
        else:
            subprocess.run(['open' if sys.platform == 'darwin' else 'xdg-open', out], check=False)
    if watch:
        print('kit-flow: watching for changes (Ctrl+C to stop)')
        last = signature(kit)
        while True:
            time.sleep(2)
            cur = signature(kit)
            if cur != last:
                last = cur
                try:
                    render(kit, out)
                except Exception as e:  # keep watching through a half-written file
                    print('kit-flow: render failed, will retry:', e)
