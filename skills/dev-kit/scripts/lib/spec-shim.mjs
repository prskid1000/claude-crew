// Minimal jasmine/jest-style test globals for node-spec.mjs (library; never run by hand).
// install() puts describe/it/expect/beforeEach/spyOn/jasmine/jest on globalThis; run() executes what the spec files registered.
// Covers pure-logic specs only: no TestBed, no DOM, no fakeAsync. Matchers: toBe, toEqual/toStrictEqual, toBeTruthy/Falsy,
// toBeNull/Undefined/Defined, toContain, toThrow/toThrowError, toHaveLength, toBeGreaterThan(OrEqual)/LessThan(OrEqual),
// toBeCloseTo, toMatch, toBeInstanceOf, toHaveProperty, toHaveBeenCalled/CalledTimes/CalledWith, all with .not; asymmetric
// jasmine.any/anything/objectContaining (also expect.any ...). Spies: spyOn(obj, m) with .and.returnValue/callFake/callThrough/
// throwError and jest .mockReturnValue/.mockImplementation; jasmine.createSpy, jasmine.createSpyObj, jest.fn.
import { inspect } from 'node:util'

const ASYM = Symbol('asymmetric')
const asym = (desc, test) => ({ [ASYM]: true, test, toString: () => desc, [inspect.custom]: () => desc })
const any = (C) => asym(`any(${C?.name ?? C})`, (v) => v != null && (Object(v) instanceof C || (C === Number && typeof v === 'number') || (C === String && typeof v === 'string') || (C === Boolean && typeof v === 'boolean') || (C === Function && typeof v === 'function')))
const anything = () => asym('anything()', (v) => v != null)
const objectContaining = (o) => asym(`objectContaining(${inspect(o)})`, (v) => v != null && Object.keys(o).every((k) => equals(v[k], o[k])))
const arrayContaining = (a) => asym(`arrayContaining(${inspect(a)})`, (v) => Array.isArray(v) && a.every((x) => v.some((y) => equals(y, x))))
const stringMatching = (r) => asym(`stringMatching(${r})`, (v) => typeof v === 'string' && new RegExp(r).test(v))

// jest/jasmine-like deep equality: ignores undefined-valued keys and class identity, compares Dates/RegExps/Maps/Sets by value
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
  s.and.stub()   // jasmine: a spy does nothing until told; jest users call .mockImplementation / callThrough
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

// Runs and resets the registry. Returns { passed, failed, skipped, failures: [{ name, error }] }.
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
