// Xtend standard navigation: long-press a post's Repost button to see its quotes.
(() => {
  'use strict';
  if (location.hostname !== 'x.com' && location.hostname !== 'twitter.com') return;

  const HOLD_MS = 500;
  const MAX_MOVEMENT = 12;
  const REPOST_SELECTOR = '[data-testid="retweet"],[data-testid="unretweet"]';
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
    const match = /^\/(?:[A-Za-z0-9_]{1,15}|i)\/status\/([0-9]+)(?:\/.*)?$/.exec(url.pathname);
    if (!match) return null;

    // X's own Post activity / Quotes route. Do not depend on the author's
    // display name or use its private API.
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
      if (press === candidate && button.isConnected &&
          location.pathname === candidate.pathname) candidate.recognized = true;
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
    if (!candidate.recognized || !candidate.button.isConnected ||
        location.pathname !== candidate.pathname ||
        Math.hypot(touch.clientX - candidate.x, touch.clientY - candidate.y) > MAX_MOVEMENT) return;

    // Prevent the normal Repost/Quote menu from also opening on touch release.
    if (event.cancelable) event.preventDefault();
    event.stopImmediatePropagation();
    suppressClick = candidate.button;
    clearTimeout(suppressTimer);
    suppressTimer = setTimeout(() => { suppressClick = null; }, 1200);
    // Let the browser navigate to X's real route. pushState/popstate alone
    // changes the URL without guaranteeing that X renders that screen.
    location.assign(candidate.url);
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
    if (!press?.recognized || repostButton(event.target) !== press.button) return;
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