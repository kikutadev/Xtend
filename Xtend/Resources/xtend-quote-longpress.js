// Xtend standard navigation: long-press a post's Repost button to see its quotes.
(() => {
  'use strict';
  if (location.hostname !== 'x.com' && location.hostname !== 'twitter.com') return;

  const HOLD_MS = 500;
  const MAX_MOVEMENT = 12;
  const REPOST_SELECTOR = '[data-testid="retweet"],[data-testid="unretweet"]';
  // iOS can show a native link preview before touchend. Disable the callout
  // only on X's Repost controls, keeping ordinary taps and scrolling native.
  const style = document.createElement('style');
  style.textContent = REPOST_SELECTOR + ', ' +
    REPOST_SELECTOR.split(',').map(selector => selector + ' *').join(', ') +
    ' {-webkit-touch-callout:none;}';
  (document.head || document.documentElement).appendChild(style);

  let press = null;
  let suppressClick = null;
  let suppressTimer = 0;

  // A quoted post may contain its own /status/ links. Only the outer post's
  // timestamp identifies the Repost button's actual owner.
  function quoteURLFor(button) {
    const article = button.closest('article[data-testid="tweet"]');
    if (!article) return null;

    const timestamp = Array.from(article.querySelectorAll('a[href]')).find(link =>
      link.querySelector('time') &&
      link.closest('article[data-testid="tweet"]') === article &&
      !link.closest('[data-testid="card.wrapper"],[data-testid="quoteTweet"]')
    );
    if (!timestamp) return null;
    const href = timestamp.getAttribute('href');
    if (!href) return null;
    let url;
    try { url = new URL(href, location.href); } catch { return null; }
    if (url.hostname !== 'x.com' && url.hostname !== 'twitter.com') return null;
    const match = /^\/[A-Za-z0-9_]{1,15}\/status\/([0-9]+)(?:\/.*)?$/.exec(url.pathname);
    if (!match) return null;

    // X's current native Post activity / Quotes route. Resolve the ID from
    // the selected post, never from an embedded quote or the current page.
    return location.origin + '/i/status/' + match[1] + '/quotes';
  }

  function repostButton(target) {
    const element = target instanceof Element ? target : target?.parentElement;
    return element?.closest(REPOST_SELECTOR) ?? null;
  }

  function cancelPress() {
    if (press) {
      clearTimeout(press.timer);
      press = null;
    }
  }

  function onStart(event) {
    cancelPress();
    if (event.touches.length !== 1) return;
    const button = repostButton(event.target);
    if (!button) return;
    const url = quoteURLFor(button);
    if (!url) return;
    const touch = event.touches[0];
    if (!touch) return;

    const candidate = {
      button, url, identifier: touch.identifier,
      x: touch.clientX, y: touch.clientY,
      pathname: location.pathname, recognized: false, timer: 0,
    };
    press = candidate;
    candidate.timer = setTimeout(() => {
      if (press !== candidate || !button.isConnected ||
          location.pathname !== candidate.pathname) return;
      candidate.recognized = true;
      suppressClick = button;
      clearTimeout(suppressTimer);
      suppressTimer = setTimeout(() => { suppressClick = null; }, 1200);
      // The quotes screen is an X SPA route. Reloading the document here
      // breaks the signed-in mobile view. Push a genuine history entry and
      // notify X's router, rather than changing the address bar alone.
      const state = history.state;
      history.pushState(state, '', candidate.url);
      window.dispatchEvent(new PopStateEvent('popstate', { state: history.state }));
    }, HOLD_MS);
  }

  function findTouch(touches, identifier) {
    return Array.from(touches).find(touch => touch.identifier === identifier);
  }

  function onMove(event) {
    if (!press) return;
    if (event.touches.length !== 1 || location.pathname !== press.pathname) {
      cancelPress();
      return;
    }
    const touch = findTouch(event.touches, press.identifier);
    if (!touch ||
        Math.hypot(touch.clientX - press.x, touch.clientY - press.y) > MAX_MOVEMENT) {
      cancelPress();
    }
  }

  function onEnd(event) {
    if (!press) return;
    const touch = findTouch(event.changedTouches, press.identifier);
    if (!touch) return;
    const candidate = press;
    cancelPress();
    if (!candidate.recognized) return;

    // The timer already navigated. Consume the trailing touch so X's native
    // Repost menu does not also open when the finger is lifted.
    if (event.cancelable) event.preventDefault();
    event.stopImmediatePropagation();
  }

  function onClick(event) {
    if (!suppressClick) return;
    if (repostButton(event.target) !== suppressClick) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    suppressClick = null;
    clearTimeout(suppressTimer);
  }

  function onContextMenu(event) {
    const button = repostButton(event.target);
    if (!button || (button !== press?.button && button !== suppressClick)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }

  document.addEventListener('touchstart', onStart, { capture: true, passive: true });
  document.addEventListener('touchmove', onMove, { capture: true, passive: true });
  document.addEventListener('touchend', onEnd, { capture: true, passive: false });
  document.addEventListener('touchcancel', cancelPress, { capture: true, passive: true });
  document.addEventListener('click', onClick, true);
  document.addEventListener('contextmenu', onContextMenu, true);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') cancelPress();
  });
})();