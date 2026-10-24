import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../Xtend/Resources/xtend-swipe.js', import.meta.url), 'utf8');

function simulateEdgeSwipe(pathname) {
  const listeners = new Map();
  let menuOpens = 0;
  class Element {
    closest() { return null; }
  }
  const toggle = {
    isConnected: true,
    expanded: false,
    getAttribute(name) { return name === 'aria-expanded' ? String(this.expanded) : null; },
    getBoundingClientRect() { return { width: 44, height: 44 }; },
    click() { this.expanded = !this.expanded; menuOpens += 1; },
  };
  const win = {
    location: { pathname },
    innerWidth: 390,
    innerHeight: 844,
    performance: { now: () => 200 },
    cancelAnimationFrame() {},
    requestAnimationFrame(callback) { callback(); return 1; },
  };
  const doc = {
    defaultView: win,
    addEventListener(name, handler) { listeners.set(name, handler); },
    querySelector(selector) {
      return selector.includes('DashButton_ProfileIcon_Link') ? toggle : null;
    },
    querySelectorAll() { return []; },
  };
  runInNewContext(source, {
    document: doc,
    location: { hostname: 'x.com', pathname },
    Element,
  });
  const target = new Element();
  listeners.get('touchstart')({
    target,
    touches: [{ clientX: 2, clientY: 300 }],
  });
  let prevented = false;
  listeners.get('touchmove')({
    touches: [{ clientX: 150, clientY: 300 }],
    cancelable: true,
    preventDefault() { prevented = true; },
  });
  return { menuOpens, prevented };
}

assert.deepEqual(simulateEdgeSwipe('/home'), { menuOpens: 1, prevented: true });
for (const path of ['/notifications', '/explore', '/someone/status/123', '/someone', '/i/flow/login']) {
  assert.deepEqual(simulateEdgeSwipe(path), { menuOpens: 0, prevented: false }, path);
}
console.log('X edge routing: home opens drawer; other routes leave edge swipes to WebKit.');
