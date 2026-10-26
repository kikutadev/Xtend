// Deterministic X-shaped DOM fixture: measures gesture completion to native-tab click.
// Example: node scripts/measure-tab-switch.mjs [path-to-swipe-script]
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(process.argv[2] ?? new URL('../Xtend/Resources/xtend-swipe.js', import.meta.url), 'utf8');

function page({ viewTransition = true, path = '/home', keepTab = true } = {}) {
  let now = 0;
  let clicks = [];
  let selected = 0;
  let sequence = 0;
  const listeners = new Map();
  const timers = new Map();
  const frames = new Map();
  const children = [];
  class Element {
    closest(selector) { return selector === '[data-testid="primaryColumn"]' ? primary : null; }
  }
  const surface = {
    isConnected: true,
    style: { transform: '', transition: '', willChange: '', viewTransitionName: '' },
    getBoundingClientRect() { return { width: 390 }; },
    contains: () => false,
  };
  const tabs = [0, 1].map(i => ({
    isConnected: true,
    hasAttribute: () => false,
    getAttribute(key) { return key === 'aria-selected' ? String(selected === i) : null; },
    click() { clicks.push(now); selected = i; },
  }));
  const primary = {
    querySelector(selector) {
      if (selector === '[data-xtend-swipe-surface]') return surface;
      return null;
    },
  };
  const tablist = {
    getBoundingClientRect: () => ({ width: 390, height: 50, top: 60 }),
    querySelectorAll: () => keepTab ? tabs : [],
  };
  const win = {
    innerWidth: 390,
    innerHeight: 844,
    location: { pathname: path },
    performance: { now: () => now },
    setTimeout(fn, delay) { const id = ++sequence; timers.set(id, { fn, at: now + delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    requestAnimationFrame(fn) { const id = ++sequence; frames.set(id, fn); return id; },
    cancelAnimationFrame(id) { frames.delete(id); },
  };
  const doc = {
    defaultView: win,
    visibilityState: 'visible',
    head: { appendChild(node) { children.push(node); } },
    createElement() { return { style: {}, textContent: '', remove() { const i = children.indexOf(this); if (i >= 0) children.splice(i, 1); } }; },
    querySelector(s) { return s === '[data-testid="primaryColumn"]' ? primary : null; },
    querySelectorAll(s) { return s === '[data-testid="ScrollSnap-List"][role="tablist"]' && keepTab ? [tablist] : []; },
    addEventListener(name, callback) { listeners.set(name, callback); },
  };
  if (viewTransition) doc.startViewTransition = (fn) => {
    win.setTimeout(fn, 16); // an actual browser takes the outgoing snapshot first
    return { finished: new Promise(() => {}), skipTransition() {} };
  };
  runInNewContext(source, { location: { hostname: 'x.com' }, document: doc, Element });
  const touch = (type, x, y = 320) => {
    const point = { clientX: x, clientY: y };
    listeners.get(type)({
      target: new Element(), touches: [point], changedTouches: [point], cancelable: true,
      preventDefault() {},
    });
  };
  const flush = (until = now) => {
    for (const [id, fn] of [...frames]) { frames.delete(id); fn(); }
    while (true) {
      const pending = [...timers].sort((a, b) => a[1].at - b[1].at).find(([, v]) => v.at <= until);
      if (!pending) break;
      const [id, { fn, at }] = pending;
      timers.delete(id);
      now = at;
      fn();
    }
    now = until;
  };
  const swipe = ({ end = 45, cancel = false } = {}) => {
    touch('touchstart', 185);
    touch('touchmove', end);
    flush();
    if (cancel) touch('touchcancel', end);
    else touch('touchend', end);
  };
  return { swipe, flush, clicks, tabs, win, doc, children, surface };
}

for (const viewTransition of [false, true]) {
  const test = page({ viewTransition });
  test.swipe();
  const selectedBefore = test.clicks.length;
  test.flush(20);
  const after20 = test.clicks[0] ?? null;
  test.flush(200);
  assert.equal(test.clicks.length, 1, 'only one X tab click per committed swipe');
  assert.equal(test.surface.style.transform, '', 'X surface must be restored');
  if (source.includes('switchTabAheadOfAnimation')) {
    assert.notEqual(after20, null, 'X starts next tab without waiting 160ms');
    assert.ok(after20 <= 20);
  }
  console.log(JSON.stringify({ fixture: 'home swipe to following', viewTransition,
    nativeTabClickAfterTouchEndMs: test.clicks[0], selectedBefore }));
}

for (const [name, config, type] of [
  ['cancel', {}, 'cancel'],
  ['too short', {}, 'short'],
  ['not home', { path: '/notifications' }, 'swipe'],
  ['no tabs', { keepTab: false }, 'swipe'],
]) {
  const test = page(config);
  if (type === 'cancel') test.swipe({ cancel: true });
  else if (type === 'short') test.swipe({ end: 160 });
  else test.swipe();
  test.flush(500);
  assert.equal(test.clicks.length, 0, name);
  console.log('PASS', name);
}
