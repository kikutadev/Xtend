import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../Xtend/Resources/xtend-settings-menu.js', import.meta.url), 'utf8');
const marker = 'data-xtend-hidden-menu-promo';

function item(text, ariaLabel = null) {
  const attrs = new Map(ariaLabel ? [['aria-label', ariaLabel]] : []);
  return {
    textContent: text,
    getAttribute: name => attrs.get(name) ?? null,
    setAttribute: (name, value) => attrs.set(name, value),
    removeAttribute: name => attrs.delete(name),
    hasAttribute: name => attrs.has(name),
  };
}

function loadMenu(entries) {
  let observer;
  let expanded = true;
  const outsideSubscribe = item('Subscribe');
  const injectedStyles = [];
  const drawer = {
    querySelector(selector) {
      if (selector === 'a[href]') return entries[0] || null;
      if (selector === '#xtend-native-settings-entry') return {};
      return null;
    },
    querySelectorAll() { return entries; },
    getBoundingClientRect: () => ({ width: 290, height: 800, left: 0 }),
  };
  const toggle = { getBoundingClientRect: () => ({ width: 42 }) };
  const document = {
    head: { appendChild: element => injectedStyles.push(element) },
    documentElement: {},
    createElement: () => ({ textContent: '' }),
    getElementById: () => null,
    querySelector(selector) {
      return selector.startsWith('button[data-testid="DashButton_ProfileIcon_Link"][aria-expanded')
        ? (expanded ? toggle : null)
        : null;
    },
    querySelectorAll(selector) {
      return selector === '[role="dialog"]' ? [drawer] : [];
    },
  };
  const context = {
    window: { webkit: { messageHandlers: { xtendSettings: { postMessage() {} } } } },
    document,
    location: { hostname: 'x.com', pathname: '/home' },
    innerWidth: 390,
    innerHeight: 844,
    __xtendShowSettingsTip: false,
    requestAnimationFrame: callback => callback(),
    MutationObserver: class {
      constructor(callback) { observer = callback; }
      observe() {}
    },
  };
  runInNewContext(source, context);
  return {
    rescan: () => observer(),
    close: () => { expanded = false; observer(); },
    open: () => { expanded = true; observer(); },
    outsideSubscribe,
    injectedStyles,
  };
}

const entries = [
  item('Get the app'),
  item('Subscribe'),
  item('  subscribe  '),
  item('Premium'),
  item('Subscriptions'),
  item('Subscribe to this creator'),
  item('Bookmarks', 'Subscribe'), // Accessible name is also checked.
];
const menu = loadMenu(entries);
assert.deepEqual(entries.map(entry => entry.hasAttribute(marker)),
  [true, true, true, false, false, false, true]);
assert.equal(menu.outsideSubscribe.hasAttribute(marker), false, 'Outside the drawer is untouched');
assert.match(menu.injectedStyles[0].textContent, /display:none!important/);

entries[1].textContent = 'Messages';
entries[6].setAttribute('aria-label', 'Bookmarks');
menu.rescan();
assert.equal(entries[1].hasAttribute(marker), false, 'Reused items are restored');
assert.equal(entries[6].hasAttribute(marker), false);

menu.close();
entries[1].textContent = 'Subscribe';
menu.rescan();
assert.equal(entries[1].hasAttribute(marker), false, 'Closed drawer is not changed');
menu.open();
assert.equal(entries[1].hasAttribute(marker), true, 'Reopened drawer is filtered');

console.log('Xtend mobile menu promo filtering: PASS');
