// Lightweight regression for X's page-level tabs. Runs with Node, no browser setup.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../Xtend/Resources/xtend-swipe.js', import.meta.url), 'utf8');
const entry = '  startSwipeNavigation(document);';
assert.equal(source.split(entry).length, 2, 'Expected a single Xtend navigation entrypoint');
const context = { location: { hostname: 'x.com' }, document: {} };
runInNewContext(source.replace(entry, '  globalThis.findTargetForTest = getTabTarget;'), context);
const findTarget = context.findTargetForTest;

function page({ labels = ['Posts', 'Replies', 'Media'], active = 0,
                pageTab = true, inPrimary = true, modal = false,
                insidePost = false, top = 500, width = 390, selectedVisible = true } = {}) {
  const tabs = labels.map((id, i) => ({
    id,
    hasAttribute: () => false,
    getAttribute: name => name === 'aria-selected'
      ? (i === active && selectedVisible ? 'true' : 'false') : null,
  }));
  const surface = { contains: () => false };
  const list = {
    matches: selector => pageTab && selector === '[data-testid="ScrollSnap-List"]',
    closest: selector => {
      if (selector === '[data-testid="primaryColumn"]') return inPrimary ? primary : null;
      if (selector.includes('role="dialog"') || selector.includes('aria-modal')) {
        return modal || insidePost ? {} : null;
      }
      return null;
    },
    getBoundingClientRect: () => ({ left: 0, right: width, top, bottom: top + 52, width, height: 52 }),
    querySelectorAll: () => tabs,
  };
  const primary = {
    querySelector: selector => selector === '[data-xtend-swipe-surface]' ? surface : null,
  };
  return {
    defaultView: { innerWidth: 390 },
    querySelector: selector => selector === '[data-testid="primaryColumn"]' ? primary : null,
    querySelectorAll: () => [list],
  };
}

const check = (label, fn) => { fn(); console.log('PASS', label); };

check('home next and previous tab', () => {
  assert.equal(findTarget(page({ labels: ['For you', 'Following'], top: 65 }), true).tab.id, 'Following');
  assert.equal(findTarget(page({ labels: ['For you', 'Following'], active: 1, top: 65 }), false).tab.id, 'For you');
});
check('notifications tabs regardless of URL', () => {
  assert.equal(findTarget(page({ labels: ['All', 'Verified', 'Mentions'] }), true).tab.id, 'Verified');
});
check('profile tablist may be below its header', () => {
  assert.equal(findTarget(page({ pageTab: false, labels: ['Posts', 'Replies', 'Media'], top: 600 }), true).tab.id, 'Replies');
});
check('gesture start recognizes either neighbor without double-scanning tabs', () => {
  assert.equal(findTarget(page({ labels: ['Posts', 'Replies', 'Media'], active: 0 })).tab.id, 'Replies');
  assert.equal(findTarget(page({ labels: ['Posts', 'Replies', 'Media'], active: 2 })).tab.id, 'Replies');
});

check('no tab beyond the last tab', () => {
  assert.equal(findTarget(page({ active: 2 }), true), null);
});
check('modal or post-level tabs are excluded', () => {
  assert.equal(findTarget(page({ modal: true }), true), null);
  assert.equal(findTarget(page({ insidePost: true }), true), null);
});
check('hidden or narrow tabs are excluded', () => {
  assert.equal(findTarget(page({ width: 0 }), true), null);
  assert.equal(findTarget(page({ selectedVisible: false }), true), null);
});
check('no page tabs means no navigation', () => {
  assert.equal(findTarget({ defaultView: { innerWidth: 390 }, querySelector: () => null }, true), null);
});
