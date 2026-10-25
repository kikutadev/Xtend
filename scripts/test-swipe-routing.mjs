import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../Xtend/Resources/xtend-swipe.js', import.meta.url), 'utf8');

function createPage(pathname, withTabs = false) {
  const listeners = new Map();
  const timers = new Map();
  const frames = new Map();
  let sequence = 0;
  let menuOpens = 0;
  let tabClicks = 0;
  let prevented = 0;
  let now = 100;

  class Element {
    constructor(interactive = false) { this.interactive = interactive; }
    closest(selector) {
      if (selector === '[data-testid="primaryColumn"]') return withTabs ? primary : null;
      if (this.interactive && selector.includes('a[href]')) return this;
      return null;
    }
  }

  const surface = {
    isConnected: true,
    style: { transform: '', transition: '', willChange: '' },
    getBoundingClientRect: () => ({ width: 390 }),
    contains: () => false,
  };
  const tabs = [0, 1].map(index => ({
    isConnected: true,
    getAttribute: key => key === 'aria-selected' ? String(index === 0) : null,
    hasAttribute: () => false,
    click() { tabClicks++; },
  }));
  const tablist = {
    matches: selector => selector === '[data-testid="ScrollSnap-List"]',
    closest: () => null,
    getBoundingClientRect: () => ({ width: 390, height: 48, top: 70, bottom: 118, left: 0, right: 390 }),
    querySelectorAll: () => tabs,
  };
  const primary = {
    querySelector: selector => selector === '[data-xtend-swipe-surface]' ? surface : null,
  };
  const panel = {
    isConnected: true,
    style: { transform: '', transition: '', willChange: '' },
    parentElement: { isConnected: true, style: { backgroundColor: '' } },
    getBoundingClientRect: () => ({ width: 300, height: 830, left: 0 }),
    querySelector: () => ({}),
    contains: () => false,
  };
  const toggle = {
    isConnected: true,
    expanded: false,
    getAttribute(key) { return key === 'aria-expanded' ? String(this.expanded) : null; },
    getBoundingClientRect: () => ({ width: 44, height: 44 }),
    click() { this.expanded = !this.expanded; menuOpens++; },
  };
  const win = {
    location: { pathname },
    innerWidth: 390,
    innerHeight: 844,
    performance: { now: () => now },
    cancelAnimationFrame(id) { frames.delete(id); },
    requestAnimationFrame(fn) { const id = ++sequence; frames.set(id, fn); return id; },
    setTimeout(fn) { const id = ++sequence; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); },
  };
  const doc = {
    defaultView: win,
    visibilityState: 'visible',
    addEventListener(name, handler) { listeners.set(name, handler); },
    querySelector(selector) {
      if (selector.includes('DashButton_ProfileIcon_Link')) return toggle;
      if (selector === '[data-testid="primaryColumn"]') return withTabs ? primary : null;
      return null;
    },
    querySelectorAll(selector) {
      if (selector === '[role="dialog"]') return toggle.expanded ? [panel] : [];
      if (selector === '[role="tablist"]') return withTabs ? [tablist] : [];
      return [];
    },
  };
  runInNewContext(source, {
    document: doc,
    location: { hostname: 'x.com', pathname },
    Element,
  });
  function touch(type, x, y = 300, interactive = false) {
    const point = { clientX: x, clientY: y };
    const event = {
      target: new Element(interactive),
      touches: [point],
      changedTouches: [point],
      cancelable: true,
      preventDefault() { prevented++; },
    };
    listeners.get(type)(event);
  }
  function flushFrames() {
    for (const [id, fn] of [...frames]) { frames.delete(id); fn(); }
  }
  function flushTimers() {
    for (let i = 0; i < 5 && timers.size; i++) {
      const pending = [...timers];
      timers.clear();
      for (const [, fn] of pending) fn();
    }
  }
  return {
    win, doc, touch, flushFrames, flushTimers,
    get menuOpens() { return menuOpens; },
    get tabClicks() { return tabClicks; },
    get prevented() { return prevented; },
    get surface() { return surface; },
  };
}

// Only home owns the leading edge.
for (const path of ['/notifications', '/explore', '/someone/status/123', '/someone', '/i/flow/login']) {
  const page = createPage(path);
  page.touch('touchstart', 2);
  page.touch('touchmove', 150);
  page.touch('touchend', 150);
  page.flushFrames();
  page.flushTimers();
  assert.equal(page.menuOpens, 0, path);
  assert.equal(page.prevented, 0, path);
}
// On non-home pages, reserve both edges for WebKit history, not X tabs.
for (const route of ['/notifications', '/explore', '/someone']) {
  const page = createPage(route, true);
  page.touch('touchstart', 388);
  page.touch('touchmove', 100);
  page.touch('touchend', 100);
  page.flushTimers();
  assert.equal(page.tabClicks, 0, route);
  assert.equal(page.prevented, 0, route);
}

const home = createPage('/home');
home.touch('touchstart', 2);
home.touch('touchmove', 150);
home.touch('touchend', 150); // Fast flick before a paint frame.
home.flushTimers();
assert.equal(home.menuOpens, 1);
assert.equal(home.prevented, 1);
const linkOnHome = createPage('/home');
linkOnHome.touch('touchstart', 2, 300, true);
linkOnHome.touch('touchmove', 150);
linkOnHome.touch('touchend', 150);
assert.equal(linkOnHome.menuOpens, 0, 'An interactive link must not trigger the drawer');

// A route change while dragging must not operate on the previous screen.
const changed = createPage('/home');
changed.touch('touchstart', 2);
changed.win.location.pathname = '/someone/status/123';
changed.touch('touchmove', 150);
changed.touch('touchend', 150);
changed.flushTimers();
assert.equal(changed.menuOpens, 0);
assert.equal(changed.prevented, 0);

// Cancel a pending tab animation when another gesture starts. Its delayed click
// must never run, even if the second gesture is canceled or the page is hidden.
const tabs = createPage('/notifications', true);
tabs.touch('touchstart', 300);
tabs.touch('touchmove', 110);
tabs.flushFrames();
assert.notEqual(tabs.surface.style.transform, '');
tabs.touch('touchend', 110);
tabs.touch('touchstart', 300);
tabs.touch('touchcancel', 300);
tabs.flushTimers();
assert.equal(tabs.tabClicks, 0);
assert.equal(tabs.surface.style.transform, '');
assert.equal(tabs.surface.style.transition, '');
tabs.touch('touchstart', 300);
tabs.touch('touchmove', 110);
tabs.touch('touchend', 110);
tabs.flushTimers();
assert.equal(tabs.tabClicks, 1);

// Navigation while an animation is pending must not click a tab from the old route.
tabs.touch('touchstart', 300);
tabs.touch('touchmove', 110);
tabs.touch('touchend', 110);
tabs.win.location.pathname = '/someone/status/123';
tabs.flushTimers();
assert.equal(tabs.tabClicks, 1);
assert.equal(tabs.surface.style.transform, '');
tabs.win.location.pathname = '/notifications';

// Leaving the document also cancels a pending outgoing animation.
tabs.touch('touchstart', 300);
tabs.touch('touchmove', 110);
tabs.touch('touchend', 110);
tabs.doc.visibilityState = 'hidden';
tabs.touch('visibilitychange', 110);
tabs.flushTimers();
assert.equal(tabs.tabClicks, 1);
assert.equal(tabs.surface.style.transform, '');

console.log('X gesture routing, fast flicks, cancellation, stale route and timers: passed.');
