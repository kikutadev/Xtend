import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../Xtend/Resources/xtend-settings-menu.js', import.meta.url), 'utf8');
const marker = 'data-xtend-hidden-menu-promo';
const pageMarker = 'data-xtend-hidden-page-promo';

function item(text, ariaLabel = null, href = null) {
  const attrs = new Map(ariaLabel ? [['aria-label', ariaLabel]] : []);
  if (href !== null) attrs.set('href', href);
  return {
    textContent: text,
    tagName: 'A',
    getAttribute: name => attrs.get(name) ?? null,
    setAttribute: (name, value) => attrs.set(name, value),
    removeAttribute: name => attrs.delete(name),
    hasAttribute: name => attrs.has(name),
    getBoundingClientRect: () => ({ width: 100, top: 12 }),
    closest: () => null,
  };
}

function loadMenu(entries) {
  let observer;
  let expanded = true;
  const outsideSubscribe = item('Subscribe', null, '/i/premium_sign_up');
  const headerGetApp = item('Get the app');
  const postGetApp = item('Get the app');
  postGetApp.closest = () => ({ id: 'tweet' });
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
      if (selector === '[role="dialog"]') return [drawer];
      if (selector === 'a[href="/i/premium_sign_up"]') return [outsideSubscribe];
      if (selector.startsWith('a[href], button,')) return [outsideSubscribe, headerGetApp, postGetApp];
      return [];
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
    headerGetApp,
    postGetApp,
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
assert.equal(menu.outsideSubscribe.hasAttribute(pageMarker), true, 'Top Premium Subscribe link is hidden');
assert.equal(menu.headerGetApp.hasAttribute(pageMarker), true, 'Top Get the app link is hidden');
assert.equal(menu.postGetApp.hasAttribute(pageMarker), false, 'A normal post remains untouched');
assert.match(menu.injectedStyles[0].textContent, /display:none!important/);

entries[1].textContent = 'Messages';
entries[6].setAttribute('aria-label', 'Bookmarks');
menu.rescan();
assert.equal(entries[1].hasAttribute(marker), false, 'Reused items are restored');
assert.equal(entries[6].hasAttribute(marker), false);
menu.headerGetApp.textContent = 'Messages';
menu.outsideSubscribe.textContent = 'Manage subscriptions';
menu.rescan();
assert.equal(menu.headerGetApp.hasAttribute(pageMarker), false, 'Reused header app CTA must be restored');
assert.equal(menu.outsideSubscribe.hasAttribute(pageMarker), false, 'Reused Premium CTA must be restored');

menu.close();
entries[1].textContent = 'Subscribe';
menu.rescan();
assert.equal(entries[1].hasAttribute(marker), false, 'Closed drawer is not changed');
menu.open();
assert.equal(entries[1].hasAttribute(marker), true, 'Reopened drawer is filtered');

console.log('Xtend mobile menu promo filtering: PASS');
