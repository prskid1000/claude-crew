#!/usr/bin/env node
// Runs *.spec.ts / *.test.ts under plain node for web projects with no unit-test target (no Karma/Vitest/Jest/`test` script);
// dev.ps1 stack lists it as their test command, dev.ps1 check -Step test falls back to it (memory gate):
//   & <kit>/skills/dev-kit/dev.ps1 check -Dir <web module> -Step test -Tests "src/app/x.service.spec.ts"
//   node <kit>/skills/dev-kit/spec.mjs [--dir <project>] [--tsconfig <file>] [--real-angular] [<spec> ...]
// Bundled by the project's own esbuild + tsconfig (paths/baseUrl, experimentalDecorators). '@angular/core' -> stub
// (no-op decorators; EventEmitter/signal/computed work; inject() throws) unless --real-angular. TestBed,
// @angular/core/testing, fakeAsync, waitForAsync -> NOT RUN, never passed. DOM specs (document./window.) use the
// project's jsdom (no layout: sizes 0); no jsdom -> NOT RUN.
// <spec>: paths (relative to --dir, default cwd; space/comma-separated) or a path part ("price-calc"); none = all (slow).
// Exit codes: 0 all passed · 1 a failure / bundle error / NOT RUN spec · 2 no esbuild, no spec found or usage error.
import Module, { createRequire } from 'node:module'
import { existsSync, readFileSync, readdirSync, statSync, mkdirSync } from 'node:fs'
import { dirname, join, resolve, relative } from 'node:path'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { inspect } from 'node:util'

// --- kit paths (kit.example.json _paths): <runtime> = $CLAUDE_RUNTIME else <kit>/.runtime; durable under <kit>/.state
const __HERE = dirname(fileURLToPath(import.meta.url))
export const KIT = resolve(__HERE, '..', '..')
const MAP = JSON.parse(readFileSync(join(__HERE, 'kit.example.json'), 'utf8'))._paths
export const runtimeDir = () => process.env.CLAUDE_RUNTIME || join(KIT, MAP.runtimeDir)
export function kitPath(name, { create = false } = {}) {
 let rel, base
 if (name === 'runtime') { rel = '/'; base = runtimeDir() }
 else if (name in MAP.runtime) { rel = MAP.runtime[name]; base = runtimeDir() }
 else if (name in MAP.durable) { rel = MAP.durable[name]; base = join(KIT, MAP.stateDir) }
 else throw new Error(`kitPath: unknown name '${name}' (see skills/dev-kit/kit.example.json _paths)`)
 const p = rel === '/' ? base : join(base, rel.replace(/\/$/, ''))
 if (create) mkdirSync(rel.endsWith('/') ? p : dirname(p), { recursive: true })
 return p
}
// --- spec shim: jasmine/jest-style globals (library). install() puts them on globalThis; run() runs the registered specs.
// Pure logic only (no TestBed, DOM, fakeAsync). Matchers (all with .not): toBe, toEqual/StrictEqual, toBeTruthy/Falsy/
// Null/Undefined/Defined/CloseTo/InstanceOf, toContain, toThrow(Error), toMatch, toHaveLength/Property,
// toBeGreaterThan/LessThan(OrEqual), toHaveBeenCalled(Times/With); jasmine/expect .any/anything/objectContaining.
// Spies: spyOn(obj, m).and.returnValue/callFake/callThrough/throwError, jest .mockReturnValue/.mockImplementation,
// jasmine.createSpy(Obj), jest.fn.

const ASYM = Symbol('asymmetric')
const asym = (desc, test) => ({ [ASYM]: true, test, toString: () => desc, [inspect.custom]: () => desc })
const any = (C) => asym(`any(${C?.name ?? C})`, (v) => v != null && (Object(v) instanceof C || (C === Number && typeof v === 'number') || (C === String && typeof v === 'string') || (C === Boolean && typeof v === 'boolean') || (C === Function && typeof v === 'function')))
const anything = () => asym('anything()', (v) => v != null)
const objectContaining = (o) => asym(`objectContaining(${inspect(o)})`, (v) => v != null && Object.keys(o).every((k) => equals(v[k], o[k])))
const arrayContaining = (a) => asym(`arrayContaining(${inspect(a)})`, (v) => Array.isArray(v) && a.every((x) => v.some((y) => equals(y, x))))
const stringMatching = (r) => asym(`stringMatching(${r})`, (v) => typeof v === 'string' && new RegExp(r).test(v))

// deep equality: ignores undefined keys and class identity; Dates/RegExps/Maps/Sets by value
export function equals(a, b, seen = new WeakMap()) {
 if (b && b[ASYM]) return b.test(a)
 if (a && a[ASYM]) return a.test(b)
 if (Object.is(a, b)) return true
 if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false
 if (seen.get(a) === b) return true
 seen.set(a, b)
 if (a instanceof Date || b instanceof Date) return a instanceof Date && b instanceof Date && a.getTime() === b.getTime()
 if (a instanceof RegExp || b instanceof RegExp) return String(a) === String(b)
 if (Array.isArray(a) !== Array.isArray(b)) return false
 if (Array.isArray(a)) return a.length === b.length && a.every((x, i) => equals(x, b[i], seen))
 if (a instanceof Map || b instanceof Map) return a instanceof Map && b instanceof Map && a.size === b.size && [...a].every(([k, v]) => b.has(k) && equals(v, b.get(k), seen))
 if (a instanceof Set || b instanceof Set) return a instanceof Set && b instanceof Set && a.size === b.size && [...a].every((x) => [...b].some((y) => equals(x, y, seen)))
 const ka = Object.keys(a).filter((k) => a[k] !== undefined), kb = Object.keys(b).filter((k) => b[k] !== undefined)
 return ka.length === kb.length && ka.every((k) => Object.prototype.hasOwnProperty.call(b, k) && equals(a[k], b[k], seen))
}

const show = (v) => inspect(v, { depth: 4, breakLength: 120 })

function makeSpy(name = 'spy', orig) {
 let impl = orig ?? (() => undefined)
 const calls = []
 const spy = function (...args) { calls.push({ args, object: this }); return impl.apply(this, args) }
 spy.isSpy = true
 spy.spyName = name
 const set = (f) => { impl = f; return spy }
 spy.and = {
  returnValue: (v) => set(() => v),
  returnValues: (...vs) => { let i = 0; return set(() => vs[i++]) },
  callFake: (f) => set(f),
  callThrough: () => set(orig ?? (() => undefined)),
  throwError: (e) => set(() => { throw typeof e === 'string' ? new Error(e) : e }),
  resolveTo: (v) => set(() => Promise.resolve(v)),
  rejectWith: (e) => set(() => Promise.reject(e)),
  stub: () => set(() => undefined),
 }
 spy.calls = {
  count: () => calls.length,
  any: () => calls.length > 0,
  argsFor: (i) => calls[i]?.args ?? [],
  allArgs: () => calls.map((c) => c.args),
  all: () => calls,
  mostRecent: () => calls[calls.length - 1],
  first: () => calls[0],
  reset: () => { calls.length = 0 },
 }
 spy.mock = { get calls() { return calls.map((c) => c.args) } }
 spy.mockReturnValue = (v) => set(() => v)
 spy.mockResolvedValue = (v) => set(() => Promise.resolve(v))
 spy.mockRejectedValue = (e) => set(() => Promise.reject(e))
 spy.mockImplementation = (f) => set(f)
 spy.mockClear = () => { calls.length = 0; return spy }
 spy.mockReset = () => { calls.length = 0; impl = () => undefined; return spy }
 return spy
}
const restorers = []
function spyOn(obj, method) {
 if (obj == null) throw new Error(`spyOn: could not spy on ${method} of ${obj}`)
 const orig = obj[method]
 if (typeof orig !== 'function') throw new Error(`spyOn: ${method}() is not a function`)
 const s = makeSpy(method, orig.bind ? function (...a) { return orig.apply(this, a) } : orig)
 s.and.stub()   // jasmine: a spy does nothing until told (jest: .mockImplementation / callThrough)
 obj[method] = s
 restorers.push(() => { obj[method] = orig })
 s.mockRestore = () => { obj[method] = orig; return s }
 return s
}
function createSpyObj(name, methods, props) {
 if (typeof name !== 'string') { props = methods; methods = name; name = 'spyObj' }
 const o = {}
 if (Array.isArray(methods)) for (const m of methods) o[m] = makeSpy(m)
 else for (const [m, v] of Object.entries(methods ?? {})) o[m] = makeSpy(m).and.returnValue(v)
 if (props) Object.assign(o, props)
 return o
}

class Fail extends Error {}
function expect(actual) {
 const build = (neg) => {
  const check = (pass, msg) => { if (pass === neg) throw new Fail(`expected ${show(actual)} ${neg ? 'not ' : ''}${msg}`) }
  const called = () => { if (!actual?.isSpy) throw new Fail(`expected a spy, got ${show(actual)}`); return actual.calls.all().map((c) => c.args) }
  const thrown = () => { try { actual(); return { threw: false } } catch (e) { return { threw: true, e } } }
  return {
   toBe: (e) => check(Object.is(actual, e), `to be ${show(e)}`),
   toEqual: (e) => check(equals(actual, e), `to equal ${show(e)}`),
   toStrictEqual: (e) => check(equals(actual, e), `to equal ${show(e)}`),
   toBeTruthy: () => check(!!actual, 'to be truthy'),
   toBeFalsy: () => check(!actual, 'to be falsy'),
   toBeTrue: () => check(actual === true, 'to be true'),
   toBeFalse: () => check(actual === false, 'to be false'),
   toBeNull: () => check(actual === null, 'to be null'),
   toBeUndefined: () => check(actual === undefined, 'to be undefined'),
   toBeDefined: () => check(actual !== undefined, 'to be defined'),
   toBeNaN: () => check(Number.isNaN(actual), 'to be NaN'),
   toContain: (e) => check(typeof actual === 'string' ? actual.includes(e) : [...(actual ?? [])].some((x) => equals(x, e)), `to contain ${show(e)}`),
   toHaveLength: (n) => check(actual?.length === n, `to have length ${n}`),
   toHaveSize: (n) => check((actual?.length ?? actual?.size ?? Object.keys(actual ?? {}).length) === n, `to have size ${n}`),
   toBeGreaterThan: (n) => check(actual > n, `to be greater than ${n}`),
   toBeGreaterThanOrEqual: (n) => check(actual >= n, `to be >= ${n}`),
   toBeLessThan: (n) => check(actual < n, `to be less than ${n}`),
   toBeLessThanOrEqual: (n) => check(actual <= n, `to be <= ${n}`),
   toBeCloseTo: (n, d = 2) => check(Math.abs(actual - n) < 10 ** -d / 2, `to be close to ${n}`),
   toMatch: (r) => check(typeof actual === 'string' && (r instanceof RegExp ? r.test(actual) : actual.includes(r)), `to match ${r}`),
   toBeInstanceOf: (C) => check(actual instanceof C, `to be an instance of ${C?.name}`),
   toHaveProperty: (k, ...v) => { const has = actual != null && k in Object(actual); check(v.length ? has && equals(actual[k], v[0]) : has, `to have property ${k}${v.length ? ' = ' + show(v[0]) : ''}`) },
   toThrow: (want) => {
    const r = thrown(); const m = r.e?.message ?? String(r.e)
    const ok = r.threw && (want === undefined || (typeof want === 'string' ? m.includes(want) : want instanceof RegExp ? want.test(m) : typeof want === 'function' ? r.e instanceof want : want?.message === m))
    if (ok === neg) throw new Fail(`expected function ${neg ? 'not ' : ''}to throw${want !== undefined ? ' ' + show(want) : ''}${r.threw ? `, it threw ${show(m)}` : ', it did not throw'}`)
   },
   toThrowError: (a, b) => build(neg).toThrow(b !== undefined ? b : a),
   toHaveBeenCalled: () => check(called().length > 0, 'to have been called'),
   toHaveBeenCalledTimes: (n) => check(called().length === n, `to have been called ${n} times (was ${actual?.calls?.count?.()})`),
   toHaveBeenCalledWith: (...a) => check(called().some((c) => equals(c, a)), `to have been called with ${show(a)} (calls: ${show(actual?.calls?.allArgs?.())})`),
   toHaveBeenCalledOnceWith: (...a) => check(called().length === 1 && equals(called()[0], a), `to have been called once with ${show(a)}`),
  }
 }
 const m = build(false); m.not = build(true)
 m.resolves = new Proxy({}, { get: (_, k) => async (...a) => expect(await actual)[k](...a) })
 m.rejects = new Proxy({}, { get: (_, k) => async (...a) => { let e; try { await actual } catch (x) { e = x; return expect(() => { throw e })[k === 'toThrow' || k === 'toThrowError' ? k : 'toThrow'](...a) } throw new Fail('expected promise to reject') } })
 return m
}
expect.any = any; expect.anything = anything; expect.objectContaining = objectContaining; expect.arrayContaining = arrayContaining; expect.stringMatching = stringMatching

// ---- registry
const mkSuite = (name, parent, mode) => ({ name, parent, mode, children: [], before: [], after: [], beforeAll: [], afterAll: [] })
let root = mkSuite('', null, 'run'), cur = root, focused = false
const describe = (mode) => (name, fn) => { const s = mkSuite(name, cur, mode); if (mode === 'only') focused = true; cur.children.push(s); const p = cur; cur = s; try { fn() } finally { cur = p } }
const it = (mode) => (name, fn, timeout) => { if (mode === 'only') focused = true; cur.children.push({ test: true, name, fn, mode: fn ? mode : 'skip', timeout }) }

export function install(g = globalThis) {
 Object.assign(g, {
  describe: Object.assign(describe('run'), { only: describe('only'), skip: describe('skip') }),
  fdescribe: describe('only'), xdescribe: describe('skip'),
  it: Object.assign(it('run'), { only: it('only'), skip: it('skip'), todo: (n) => it('skip')(n) }),
  test: Object.assign(it('run'), { only: it('only'), skip: it('skip') }),
  fit: it('only'), xit: it('skip'),
  beforeEach: (f) => cur.before.push(f), afterEach: (f) => cur.after.push(f),
  beforeAll: (f) => cur.beforeAll.push(f), afterAll: (f) => cur.afterAll.push(f),
  expect, spyOn, pending: () => { throw new Fail('pending') }, fail: (m) => { throw new Fail(m ?? 'fail() called') },
  jasmine: { createSpy: (n, f) => makeSpy(n, f), createSpyObj, any, anything, objectContaining, arrayContaining, stringMatching },
  jest: { fn: (f) => makeSpy('jest.fn', f), spyOn: (o, m) => { const s = spyOn(o, m); return s.and.callThrough() }, clearAllMocks: () => {}, restoreAllMocks: () => { while (restorers.length) restorers.pop()() } },
 })
}

async function call(fn, timeout = 5000) {
 let timer
 const body = fn.length > 0
  ? new Promise((res, rej) => { const done = (e) => (e ? rej(e) : res()); done.fail = (e) => rej(new Fail(e ?? 'done.fail')); fn(done) })
  : Promise.resolve().then(() => fn())
 try { await Promise.race([body, new Promise((_, rej) => { timer = setTimeout(() => rej(new Fail(`timed out after ${timeout} ms`)), timeout) })]) }
 finally { clearTimeout(timer) }
}

// runs + resets the registry -> { passed, failed, skipped, failures: [{ name, error }] }
export async function run({ log = console.log } = {}) {
 const r = { passed: 0, failed: 0, skipped: 0, failures: [] }
 const chain = (s) => { const a = []; for (let x = s; x; x = x.parent) a.unshift(x); return a }
 const title = (s, n) => [...chain(s).map((x) => x.name).filter(Boolean), n].join(' > ')
 const inOnly = (s) => chain(s).some((x) => x.mode === 'only')
 const skipped = (s) => chain(s).some((x) => x.mode === 'skip')
 async function walk(s) {
  const tests = s.children
  try { for (const f of s.beforeAll) await call(f) } catch (e) { r.failed++; r.failures.push({ name: title(s, '(beforeAll)'), error: e }); log(`  FAIL ${title(s, '(beforeAll)')}`); return }
  for (const t of tests) {
   if (!t.test) { await walk(t); continue }
   const name = title(s, t.name)
   if (t.mode === 'skip' || skipped(s) || (focused && t.mode !== 'only' && !inOnly(s))) { r.skipped++; continue }
   let err = null
   try {
    for (const x of chain(s)) for (const f of x.before) await call(f)
    await call(t.fn, t.timeout)
   } catch (e) { err = e }
   for (const x of chain(s).reverse()) for (const f of x.after) { try { await call(f) } catch (e) { err ??= e } }
   while (restorers.length) restorers.pop()()
   if (err) { r.failed++; r.failures.push({ name, error: err }); log(`  FAIL ${name}\n       ${String(err instanceof Fail ? err.message : err?.stack ?? err).split('\n').slice(0, 6).join('\n       ')}`) }
   else { r.passed++; log(`  ok   ${name}`) }
  }
  for (const f of s.afterAll) { try { await call(f) } catch (e) { r.failed++; r.failures.push({ name: title(s, '(afterAll)'), error: e }) } }
 }
 await walk(root)
 root = mkSuite('', null, 'run'); cur = root; focused = false
 return r
}

// --- runner
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

// esbuild: the project's own (its or a parent's node_modules), never installed
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
// jsdom: the project's own (never installed), resolved on the first DOM spec
let jsdomMod, jsdomWhy = ''
function getJsdom() {
 if (jsdomMod !== undefined) return jsdomMod
 jsdomMod = null
 let path
 try { path = req.resolve('jsdom') } catch { jsdomWhy = `jsdom is not resolvable from ${dir}'s node_modules`; return null }
 try { jsdomMod = req(path) } catch {
  // a resolvable `canvas` without its native build breaks jsdom: reload jsdom with canvas hidden
  const orig = Module._resolveFilename
  Module._resolveFilename = function (r, ...rest) {
   if (r === 'canvas') { const e = new Error("Cannot find module 'canvas'"); e.code = 'MODULE_NOT_FOUND'; throw e }
   return orig.call(this, r, ...rest)
  }
  try {
   for (const k of Object.keys(req.cache)) if (/[\\/]jsdom[\\/]/.test(k)) delete req.cache[k]
   jsdomMod = req(path)
  } catch (e) { jsdomWhy = `jsdom failed to load (${String(e?.message ?? e).split('\n')[0]})` }
  finally { Module._resolveFilename = orig }
 }
 return jsdomMod
}
// fresh jsdom window globals -> globalThis; returns the undo
function domOn({ JSDOM }) {
 const win = new JSDOM('<!doctype html><html><head></head><body></body></html>', { url: 'http://localhost/', pretendToBeVisual: true }).window
 const saved = []
 const set = (k, v) => {
  try { saved.push([k, Object.getOwnPropertyDescriptor(globalThis, k)]); Object.defineProperty(globalThis, k, { value: v, configurable: true, writable: true }) }
  catch { saved.pop() }
 }
 set('window', win); set('document', win.document); set('navigator', win.navigator)
 for (const k of Object.getOwnPropertyNames(win)) {
  if (k.startsWith('_') || k in globalThis) continue
  let v; try { v = win[k] } catch { continue }
  set(k, v)
 }
 return () => {
  for (const [k, d] of saved.reverse()) { try { if (d) Object.defineProperty(globalThis, k, d); else delete globalThis[k] } catch {} }
  win.close()
 }
}
const total = { passed: 0, failed: 0, skipped: 0, notRun: 0, errors: 0 }
for (const spec of uniq) {
 const rel = relative(dir, spec).replace(/\\/g, '/')
 const src = readFileSync(spec, 'utf8')
 if (/\bTestBed\b|@angular\/core\/testing|\bfakeAsync\b|\bwaitForAsync\b/.test(src)) {
  total.notRun++
  say(`NOT RUN ${rel}: it uses TestBed / fakeAsync / waitForAsync, which node-spec cannot provide - test the pure logic, or ask for a test target`)
  continue
 }
 const usesDom = /\bdocument\.|\bwindow\./.test(src)
 if (usesDom && !getJsdom()) {
  total.notRun++
  say(`NOT RUN ${rel}: it uses the DOM and ${jsdomWhy} - test the pure logic, or ask for a test target`)
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
  const errs = e.errors ?? [e]   // capped: hundreds of stub "No matching export" lines bury the summary
  for (const m of errs.slice(0, 15)) console.log(`  ${m.location ? `${m.location.file}:${m.location.line}:${m.location.column} ` : ''}${m.text ?? m.message ?? m}`)
  if (errs.length > 15) console.log(`  ... +${errs.length - 15} more errors`)
  // the core stub lacks an export the spec needs (Injector, forms ...)
  const missing = [...new Set((e.errors ?? []).map((m) => /No matching export in "ng-stub:@angular\/core" for import "([^"]+)"/.exec(m.text ?? '')?.[1]).filter(Boolean))]
  if (missing.length && !realAngular) say(`hint: the @angular/core stub has no ${missing.slice(0, 5).join(', ')}${missing.length > 5 ? ` (+${missing.length - 5} more)` : ''}: re-run with dev.ps1 check -Step test -RealAngular (node-spec --real-angular); if that fails with a JIT/linker error, move the logic into a pure helper and spec that`)
  continue
 }
 console.log(`${rel}`)
 // DOM spec: the project's own jsdom provides window/document for this spec only (globals set before loading, removed after run)
 let domOff = null
 if (usesDom) {
  try { domOff = domOn(getJsdom()) } catch (e) { total.errors++; console.log(`  JSDOM ERROR ${String(e?.message ?? e)}`); continue }
  say(`DOM spec under jsdom (no layout: sizes are 0): ${rel}`)
 }
 try {
  try { delete req.cache[out]; req(out) }
  catch (e) {
   total.errors++; console.log(`  LOAD ERROR ${String(e?.stack ?? e).split('\n').slice(0, 6).join('\n    ')}`)
   if (realAngular && /JIT compiler|Angular Linker/.test(String(e?.message ?? e))) say('hint: the real @angular/core needs the Angular linker for this import chain (a partially compiled library): move the logic into a pure helper in a light module, spec that, and give the component wiring a live check')
   await run({ log: () => {} }); continue
  }
  const r = await run()
  total.passed += r.passed; total.failed += r.failed; total.skipped += r.skipped
 } finally { if (domOff) domOff() }
}
say(`${total.passed} passed, ${total.failed} failed, ${total.skipped} skipped, ${total.errors} bundle/load errors, ${total.notRun} not run (${uniq.length} file(s); bundles: ${outRoot})`)
const bad = total.failed + total.errors + total.notRun
if (!bad && !total.passed) say('no test ran (every test skipped or empty specs)')
process.exit(bad || !total.passed ? 1 : 0)
