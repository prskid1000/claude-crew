#!/usr/bin/env node
// Runs *.spec.ts / *.test.ts files under plain node when the web project has no unit-test target (no Karma/Vitest/Jest, no
// `test` script). stack.ps1 gives it as the test command of such a stack and check.ps1 -Step test falls back to it, so it runs
// through the memory gate:
//   & <kit>/skills/dev-kit/scripts/check.ps1 -Dir <web module> -Step test -Tests "src/app/x.service.spec.ts"
//   node <kit>/skills/dev-kit/scripts/node-spec.mjs [--dir <project>] [--tsconfig <file>] [--real-angular] [<spec> ...]
// Each spec is bundled with the project's own esbuild (resolved from its node_modules; none -> "no esbuild", exit 2), with the
// project's tsconfig (paths/baseUrl aliases, experimentalDecorators), then run with the jasmine/jest-style globals of
// lib/spec-shim.mjs (describe/it/expect/beforeEach/spyOn ...). '@angular/core' is replaced by a small stub (decorators are no-ops,
// EventEmitter/signal/computed work, inject() throws) unless --real-angular. Pure-logic specs only: a spec that uses TestBed,
// fakeAsync or the DOM is reported NOT RUN (exit 1), never passed.
// <spec> = a path (relative to --dir, default the current folder), several separated by spaces or commas, or a part of a spec's
// path ("price-calc" finds src/app/x/price-calc.spec.ts). No spec given = every spec under --dir (slow on a big app).
// Exit: 0 all passed, 1 a failure / bundle error / NOT RUN spec, 2 no esbuild or no spec found.
import { createRequire } from 'node:module'
import { existsSync, readFileSync, readdirSync, statSync, mkdirSync } from 'node:fs'
import { join, resolve, relative } from 'node:path'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { kitPath } from './kitpaths.mjs'
import { install, run } from './lib/spec-shim.mjs'

const args = process.argv.slice(2)
let dir = process.cwd(), tsconfig = null, realAngular = false
const wanted = []
for (let i = 0; i < args.length; i++) {
  const a = args[i]
  if (a === '--dir') dir = resolve(args[++i])
  else if (a === '--tsconfig') tsconfig = args[++i]
  else if (a === '--real-angular') realAngular = true
  else if (a === '-h' || a === '--help') { console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').filter((l) => l.startsWith('//')).join('\n')); process.exit(0) }
  else wanted.push(...a.split(',').map((s) => s.trim()).filter(Boolean))
}
const say = (m) => console.log(`[node-spec] ${m}`)

// esbuild: only the project's own (its node_modules or a parent's); never installed by this script
let esbuild
try { esbuild = createRequire(join(dir, 'package.json'))('esbuild') }
catch {
  say(`no esbuild: it is not resolvable from ${dir}'s node_modules, so specs cannot be bundled here.`)
  say('Ask for esbuild in the project (or a unit-test target); do not install packages into a linked node_modules.')
  process.exit(2)
}

const SKIP_DIRS = new Set(['node_modules', 'dist', '.git', '.angular', 'coverage', 'build', 'out-tsc'])
const SPEC = /\.(spec|test)\.(ts|tsx|mts|js|mjs)$/
function walk(d, out = []) {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    if (e.isDirectory()) { if (!SKIP_DIRS.has(e.name) && !e.name.startsWith('.')) walk(join(d, e.name), out) }
    else if (SPEC.test(e.name)) out.push(join(d, e.name))
  }
  return out
}
let all = null
const specs = []
for (const w of wanted) {
  const p = resolve(dir, w)
  if (existsSync(p) && statSync(p).isFile()) { specs.push(p); continue }
  if (existsSync(p) && statSync(p).isDirectory()) { specs.push(...walk(p)); continue }
  all ??= walk(dir)
  const needle = w.replace(/\\/g, '/').toLowerCase()
  const hits = all.filter((f) => relative(dir, f).replace(/\\/g, '/').toLowerCase().includes(needle))
  if (!hits.length) say(`no spec matches '${w}'`)
  specs.push(...hits)
}
if (!wanted.length) specs.push(...walk(dir))
const uniq = [...new Set(specs)]
if (!uniq.length) { say(`no spec files found under ${dir}`); process.exit(2) }

if (!tsconfig) tsconfig = ['tsconfig.spec.json', 'tsconfig.json'].map((f) => join(dir, f)).find(existsSync) ?? null
else tsconfig = resolve(dir, tsconfig)

const NG_STUB = `
const deco = () => () => {}
export const Injectable = deco, Component = deco, Directive = deco, Pipe = deco, NgModule = deco, Input = deco, Output = deco,
  HostListener = deco, HostBinding = deco, ViewChild = deco, ViewChildren = deco, ContentChild = deco, ContentChildren = deco,
  Inject = deco, Optional = deco, Self = deco, SkipSelf = deco, Host = deco, Attribute = deco
export class EventEmitter {
  constructor() { this.subs = [] }
  emit(v) { for (const s of [...this.subs]) s(v) }
  next(v) { this.emit(v) }
  complete() {}
  subscribe(f) { const fn = typeof f === 'function' ? f : f && f.next ? f.next.bind(f) : null; if (fn) this.subs.push(fn); return { unsubscribe: () => { this.subs = this.subs.filter((x) => x !== fn) } } }
}
export class InjectionToken { constructor(desc, opts) { this.desc = desc; this.factory = opts && opts.factory } toString() { return 'InjectionToken ' + this.desc } }
export class ElementRef { constructor(n) { this.nativeElement = n } }
export class ChangeDetectorRef { markForCheck() {} detectChanges() {} detach() {} reattach() {} }
export class NgZone { run(f) { return f() } runOutsideAngular(f) { return f() } }
export class Renderer2 {}
export class DestroyRef { onDestroy() { return () => {} } }
export class TemplateRef {}
export class ViewContainerRef {}
export const ChangeDetectionStrategy = { OnPush: 0, Default: 1 }
export const ViewEncapsulation = { Emulated: 0, None: 2, ShadowDom: 3 }
export const CUSTOM_ELEMENTS_SCHEMA = { name: 'custom-elements' }
export const NO_ERRORS_SCHEMA = { name: 'no-errors-schema' }
export const forwardRef = (f) => f
export const isDevMode = () => true
export function signal(v) { const s = () => v; s.set = (n) => { v = n }; s.update = (f) => { v = f(v) }; s.asReadonly = () => () => v; return s }
export function computed(f) { return () => f() }
export function effect() { return { destroy() {} } }
export function untracked(f) { return f() }
export function input(v) { return () => v }
input.required = () => () => undefined
export function model(v) { return signal(v) }
export function output() { return new EventEmitter() }
export function inject(t) { throw new Error('node-spec: inject(' + ((t && t.name) || t) + ') needs Angular DI - pass dependencies to the constructor in the spec, or use a real test target') }
`
const ngStub = {
  name: 'angular-core-stub',
  setup(b) {
    b.onResolve({ filter: /^@angular\/core$/ }, () => ({ path: '@angular/core', namespace: 'ng-stub' }))
    b.onLoad({ filter: /.*/, namespace: 'ng-stub' }, () => ({ contents: NG_STUB, loader: 'js' }))
  },
}

const outRoot = join(kitPath('cache', { create: true }), 'node-spec', createHash('md5').update(dir.toLowerCase()).digest('hex').slice(0, 12))
mkdirSync(outRoot, { recursive: true })
say(`no unit-test target: running ${uniq.length} spec file(s) under node (esbuild ${esbuild.version}${tsconfig ? ', ' + relative(dir, tsconfig) : ''}${realAngular ? '' : ', @angular/core stubbed'})`)
install()
const req = createRequire(join(dir, 'package.json'))
const total = { passed: 0, failed: 0, skipped: 0, notRun: 0, errors: 0 }
for (const spec of uniq) {
  const rel = relative(dir, spec).replace(/\\/g, '/')
  const src = readFileSync(spec, 'utf8')
  if (/\bTestBed\b|@angular\/core\/testing|\bfakeAsync\b|\bwaitForAsync\b|\bdocument\.|\bwindow\./.test(src)) {
    total.notRun++
    say(`NOT RUN ${rel}: it uses TestBed / fakeAsync / the DOM, which node-spec cannot provide - test the pure logic, or ask for a test target`)
    continue
  }
  const out = join(outRoot, rel.replace(/[\\/:]/g, '__') + '.cjs')
  try {
    await esbuild.build({
      entryPoints: [spec], outfile: out, bundle: true, platform: 'node', format: 'cjs', target: `node${process.versions.node.split('.')[0]}`,
      sourcemap: 'inline', logLevel: 'silent', absWorkingDir: dir, ...(tsconfig ? { tsconfig } : {}),
      plugins: realAngular ? [] : [ngStub],
    })
  } catch (e) {
    total.errors++
    say(`BUNDLE ERROR ${rel}`)
    for (const m of e.errors ?? [e]) console.log(`  ${m.location ? `${m.location.file}:${m.location.line}:${m.location.column} ` : ''}${m.text ?? m.message ?? m}`)
    continue
  }
  console.log(`${rel}`)
  try { delete req.cache[out]; req(out) }
  catch (e) { total.errors++; console.log(`  LOAD ERROR ${String(e?.stack ?? e).split('\n').slice(0, 6).join('\n    ')}`); await run({ log: () => {} }); continue }
  const r = await run()
  total.passed += r.passed; total.failed += r.failed; total.skipped += r.skipped
}
say(`${total.passed} passed, ${total.failed} failed, ${total.skipped} skipped, ${total.errors} bundle/load errors, ${total.notRun} not run (${uniq.length} file(s); bundles: ${outRoot})`)
const bad = total.failed + total.errors + total.notRun
if (!bad && !total.passed) say('no test ran (every test skipped or empty specs)')
process.exit(bad || !total.passed ? 1 : 0)
