import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const script = readFileSync(new URL('../Xtend/Resources/xtend-quote-longpress.js', import.meta.url), 'utf8');
const POST = '/author/status/2091234567890123456';
const QUOTE = '/someone/status/2099999999999999999';

function fixture({ timestamp = true, quoteFirst = false, pathname = '/home', control = true } = {}) {
  const listeners = new Map();
  const timers = new Map();
  let nextTimer = 0;
  let navigated = null;
  let currentPath = pathname;
  let now = 0;

  class Element {
    constructor(kind, parent = null) {
      this.kind = kind;
      this.parentElement = parent;
      this.isConnected = true;
    }
    closest(selector) {
      if (selector.includes('[data-testid="retweet"]') ||
          selector.includes('[data-testid="unretweet"]')) {
        return this.kind === 'button' ? this : this.parentElement?.closest(selector) ?? null;
      }
      if (selector === 'article[data-testid="tweet"]') return article;
      if (selector.includes('card.wrapper')) return this.kind === 'quoted-link' ? this : null;
      return null;
    }
    querySelector(name) { return name === 'time' && this.kind !== 'non-time' ? {} : null; }
    getAttribute(name) {
      if (name !== 'href') return null;
      return this.kind === 'quoted-link' ? QUOTE : POST;
    }
    querySelectorAll() { return []; }
  }

  const article = new Element('article');
  const button = new Element('button', article);
  const icon = new Element('icon', button);
  const ownerLink = new Element('owner-link', article);
  const quotedLink = new Element('quoted-link', article);
  article.querySelectorAll = () => {
    const links = [timestamp ? ownerLink : new Element('non-time', article), quotedLink];
    return quoteFirst ? links.reverse() : links;
  };
  const location = {
    hostname: 'x.com',
    origin: 'https://x.com',
    get href() { return 'https://x.com' + currentPath; },
    get pathname() { return currentPath; },
    set pathname(value) { currentPath = value; },
    assign(value) { navigated = value; },
  };
  const document = {
    visibilityState: 'visible',
    addEventListener(name, fn) { listeners.set(name, fn); },
  };

  runInNewContext(script, {
    location, document, Element, URL, Math, Array,
    setTimeout(fn, ms) { const id = ++nextTimer; timers.set(id, { fn, deadline: now + ms }); return id; },
    clearTimeout(id) { timers.delete(id); },
  });

  function dispatch(name, { x = 200, y = 300, target = icon, identifier = 1, touches = 1 } = {}) {
    let prevented = false;
    let stopped = false;
    const point = { identifier, clientX: x, clientY: y };
    const event = {
      target: control ? target : new Element('other'),
      touches: Array.from({ length: touches }, (_, i) => ({ ...point, identifier: identifier + i })),
      changedTouches: [point],
      cancelable: true,
      preventDefault() { prevented = true; },
      stopImmediatePropagation() { stopped = true; },
    };
    listeners.get(name)(event);
    return { get prevented() { return prevented; }, get stopped() { return stopped; } };
  }

  function advance(ms) {
    now += ms;
    for (const [id, task] of [...timers]) {
      if (task.deadline <= now) { timers.delete(id); task.fn(); }
    }
  }

  return {
    dispatch, advance, location, article, button,
    get navigated() { return navigated; },
  };
}

{
  const page = fixture();
  page.dispatch('touchstart');
  page.advance(499);
  const end = page.dispatch('touchend');
  assert.equal(page.navigated, null);
  assert.equal(end.prevented, false, 'short tap should keep X repost menu');
  assert.equal(page.dispatch('click').prevented, false);
}
{
  const page = fixture();
  page.dispatch('touchstart');
  page.advance(500);
  const end = page.dispatch('touchend');
  assert.equal(page.navigated, 'https://x.com/i/status/2091234567890123456/quotes');
  assert.equal(end.prevented, true);
  assert.equal(end.stopped, true);
  const click = page.dispatch('click');
  assert.equal(click.prevented, true, 'repost menu must not also open');
  assert.equal(page.dispatch('click').prevented, false);
}
{
  const page = fixture();
  page.dispatch('touchstart');
  page.advance(500);
  page.dispatch('touchend');
  page.advance(1200);
  assert.equal(page.dispatch('click').prevented, false,
    'a canceled navigation must not suppress a later repost click');
}
{
  const page = fixture({ quoteFirst: true });
  page.dispatch('touchstart');
  page.advance(500);
  page.dispatch('touchend');
  assert.equal(page.navigated, 'https://x.com/i/status/2091234567890123456/quotes',
    'embedded quote must not replace the surrounding post');
}
for (const move of [[13, 0], [0, 13]]) {
  const page = fixture();
  page.dispatch('touchstart');
  page.dispatch('touchmove', { x: 200 + move[0], y: 300 + move[1] });
  page.advance(600);
  assert.equal(page.dispatch('touchend').prevented, false);
  assert.equal(page.navigated, null, 'swipe or scroll should cancel');
}
{
  const page = fixture();
  page.dispatch('touchstart');
  page.dispatch('touchcancel');
  page.advance(600);
  page.dispatch('touchend');
  assert.equal(page.navigated, null);
}
{
  const page = fixture();
  page.dispatch('touchstart');
  page.location.pathname = '/notifications';
  page.advance(600);
  page.dispatch('touchend');
  assert.equal(page.navigated, null, 'old route must not trigger navigation');
}
{
  const page = fixture({ timestamp: false });
  page.dispatch('touchstart');
  page.advance(600);
  page.dispatch('touchend');
  assert.equal(page.navigated, null, 'unknown post owner must not navigate');
}
{
  const page = fixture({ control: false });
  page.dispatch('touchstart');
  page.advance(600);
  page.dispatch('touchend');
  assert.equal(page.navigated, null, 'other buttons must be unaffected');
}
{
  const page = fixture();
  page.dispatch('touchstart', { touches: 2 });
  page.advance(600);
  page.dispatch('touchend');
  assert.equal(page.navigated, null, 'multitouch must not trigger');
}
console.log('Quote long-press: short tap, navigation, quoted post, gesture cancel, stale route, missing post, and multitouch passed.');
