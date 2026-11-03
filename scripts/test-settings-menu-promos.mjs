import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../Xtend/Sources/BrowserViewController.swift', import.meta.url), 'utf8').split('private static let settingsMenuScript = #\"\"\"')[1]?.split('\"\"\"#')[0];
assert.ok(source, 'Embedded Xtend settings JavaScript is available');
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

function loadMenu(entries, { notificationPrompt = false, notificationBanner = false } = {}) {
  let observer;
  let expanded = true;
  const outsideSubscribe = item('Subscribe', null, '/i/premium_sign_up');
  const headerGetApp = item('Get the app');
  const postGetApp = item('Get the app');
  postGetApp.closest = () => ({ id: 'tweet' });
  const offscreenSubscribe = item('Subscribe', null, '/i/premium_sign_up');
  offscreenSubscribe.getBoundingClientRect = () => ({ width: 100, top: 500 });
  const promptHeading = {
    textContent: 'Never miss what’s happening.',
    closest: () => null,
  };
  const unrelatedPostHeading = {
    textContent: 'Never miss what’s happening.',
    closest: () => ({ id: 'tweet' }),
  };
  const bannerContainer = {
    attrs: new Map(), textContent: 'Never miss what’s happening. Turn on notifications',
    parentElement: null,
    querySelector: selector => selector === 'button,[role="button"]' ? {} : null,
    getBoundingClientRect: () => ({ width: 320, height: 170 }),
    setAttribute(name, value) { this.attrs.set(name, value); },
    removeAttribute(name) { this.attrs.delete(name); },
    hasAttribute(name) { return this.attrs.has(name); },
    closest: () => null,
    querySelectorAll: selector => selector.includes('h1') ? [bannerHeading] : [],
  };
  const bannerHeading = {
    textContent: 'Never miss what’s happening.', parentElement: bannerContainer,
    closest: () => null,
  };
  const dialogMask = {};
  const promptOverlay = {
    attrs: new Map(), parentElement: null,
    closest: () => null,
    querySelectorAll: selector => selector.includes('span') ? [promptHeading] : [],
    querySelector: selector => selector === '[data-testid="mask"]' ? dialogMask :
      selector === '[role="dialog"]' ? promptDialog : null,
    setAttribute(name, value) { this.attrs.set(name, value); },
    removeAttribute(name) { this.attrs.delete(name); },
    hasAttribute(name) { return this.attrs.has(name); },
  };
  const promptDialog = {
    parentElement: promptOverlay,
    closest: () => null,
    querySelectorAll: selector => selector.includes('span') ? [promptHeading] : [],
    setAttribute: () => { throw new Error('Should hide the backdrop as well as the dialog'); },
  };
  const unrelatedPostDialog = {
    parentElement: null,
    closest: () => null,
    querySelectorAll: selector => selector.includes('span') ? [unrelatedPostHeading] : [],
    setAttribute: () => { throw new Error('Must not hide post content'); },
  };
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
      if (selector === '[role="dialog"],[role="alertdialog"]') {
        return notificationPrompt ? [promptDialog, unrelatedPostDialog] : [];
      }
      if (selector === 'h1,h2,h3,[role="heading"]') return notificationBanner ? [bannerHeading] : [];
      if (selector === '[data-xtend-hidden-notification-promo]') {
        return [promptOverlay, bannerContainer]
          .filter(node => node.hasAttribute('data-xtend-hidden-notification-promo'));
      }
      if (selector === 'a[href="/i/premium_sign_up"]') return [outsideSubscribe];
      if (selector.startsWith('a[href], button,')) {
        return [outsideSubscribe, headerGetApp, postGetApp, offscreenSubscribe];
      }
      if (selector === '[' + pageMarker + ']') {
        return [outsideSubscribe, headerGetApp, postGetApp, offscreenSubscribe]
          .filter(node => node.hasAttribute(pageMarker));
      }
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
    __xtendPromoSettings: { enabled: true, getApp: true, subscribe: true, notifications: true },
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
    offscreenSubscribe,
    promptOverlay,
    bannerContainer,
    injectedStyles,
    updatePreferences: state => context.__xtendSetPromoSettings(state),
  };
}

const entries = [
  item('Get the app'),
  item('Subscribe'),
  item('  subscribe  '),
  item(' Get   the  app '),
  item('Premium'),
  item('Subscriptions'),
  item('Subscribe to this creator'),
  item('Bookmarks', 'Subscribe'), // Accessible name is also checked.
];
const menu = loadMenu(entries);
assert.deepEqual(entries.map(entry => entry.hasAttribute(marker)),
  [true, true, true, true, false, false, false, true]);
assert.equal(menu.outsideSubscribe.hasAttribute(pageMarker), true, 'Top Premium Subscribe link is hidden');
assert.equal(menu.headerGetApp.hasAttribute(pageMarker), true, 'Top Get the app link is hidden');
assert.equal(menu.postGetApp.hasAttribute(pageMarker), false, 'A normal post remains untouched');
assert.equal(menu.offscreenSubscribe.hasAttribute(pageMarker), false, 'Offscreen Subscribe is untouched');
assert.match(menu.injectedStyles[0].textContent, /display:none!important/);

entries[1].textContent = 'Messages';
entries[7].setAttribute('aria-label', 'Bookmarks');
menu.rescan();
assert.equal(entries[1].hasAttribute(marker), false, 'Reused items are restored');
assert.equal(entries[7].hasAttribute(marker), false);
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

// Global off restores both controls without resetting the individual settings.
menu.updatePreferences({ enabled: false, getApp: true, subscribe: true });
assert.equal(entries[0].hasAttribute(marker), false);
assert.equal(entries[1].hasAttribute(marker), false);
assert.equal(menu.headerGetApp.hasAttribute(pageMarker), false);
assert.equal(menu.outsideSubscribe.hasAttribute(pageMarker), false);

// Individual switches remain independent under the global master switch.
entries[0].textContent = 'Get the app';
entries[1].textContent = 'Subscribe';
menu.headerGetApp.textContent = 'Get the app';
menu.outsideSubscribe.textContent = 'Subscribe';
menu.updatePreferences({ enabled: true, getApp: false, subscribe: true });
assert.equal(entries[0].hasAttribute(marker), false, 'Get the app restored independently');
assert.equal(entries[1].hasAttribute(marker), true, 'Subscribe still hidden');
assert.equal(menu.headerGetApp.hasAttribute(pageMarker), false);
assert.equal(menu.outsideSubscribe.hasAttribute(pageMarker), true);

menu.updatePreferences({ enabled: true, getApp: true, subscribe: false });
assert.equal(entries[0].hasAttribute(marker), true);
assert.equal(entries[1].hasAttribute(marker), false, 'Subscribe restored independently');
assert.equal(menu.headerGetApp.hasAttribute(pageMarker), true);
assert.equal(menu.outsideSubscribe.hasAttribute(pageMarker), false);

// The master switch must immediately restore already-hidden real header nodes.
// They may have a zero-width rect because CSS has already hidden them.
const restored = loadMenu([item('Get the app'), item('Subscribe')]);
assert.equal(restored.outsideSubscribe.hasAttribute(pageMarker), true);
restored.outsideSubscribe.getBoundingClientRect = () => ({ width: 0, top: 0 });
restored.updatePreferences({ enabled: false, getApp: true, subscribe: true });
assert.equal(restored.outsideSubscribe.hasAttribute(pageMarker), false);
assert.equal(restored.headerGetApp.hasAttribute(pageMarker), false);

// Notification promo suppression also hides its backdrop, without hiding a post
// that quotes the same words. It must restore the dialog on toggle off.
const notification = loadMenu([item('Bookmarks')], { notificationPrompt: true });
const notificationMarker = 'data-xtend-hidden-notification-promo';
assert.equal(notification.promptOverlay.hasAttribute(notificationMarker), true,
  'The entire push-notification prompt and backdrop must be hidden');
notification.updatePreferences({ enabled: true, getApp: true, subscribe: true, notifications: false });
assert.equal(notification.promptOverlay.hasAttribute(notificationMarker), false,
  'Turning off only the notification filter restores the prompt');
notification.updatePreferences({ enabled: true, getApp: true, subscribe: true, notifications: true });
assert.equal(notification.promptOverlay.hasAttribute(notificationMarker), true);
notification.updatePreferences({ enabled: false, getApp: true, subscribe: true, notifications: true });
assert.equal(notification.promptOverlay.hasAttribute(notificationMarker), false,
  'The master switch restores the notification prompt');

const banner = loadMenu([item('Bookmarks')], { notificationBanner: true });
assert.equal(banner.bannerContainer.hasAttribute(notificationMarker), true,
  'The compact notification banner is hidden instead of just its heading');
banner.updatePreferences({ enabled: true, getApp: true, subscribe: true, notifications: false });
assert.equal(banner.bannerContainer.hasAttribute(notificationMarker), false,
  'The notification banner is restored on individual toggle off');

console.log('Xtend menu promo preferences and live updates: PASS');
