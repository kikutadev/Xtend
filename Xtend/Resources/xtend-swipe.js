// Xtend's built-in X navigation, adapted from MIT-licensed X Swipe Navigation.
// No WXT runtime or Chrome APIs.
// X owns its tab/menu state; this script only translates touch gestures
// into existing X UI clicks and temporary drag transforms.
(() => {
  'use strict';
  if (location.hostname !== 'x.com' && location.hostname !== 'twitter.com') return;

  const HORIZONTAL_INTENT = 12;
  const AXIS_RATIO = 1.4;
  const EDGE_WIDTH = 28;
  const MIN_SWIPE = 64;
  const MAX_DRAG_RATIO = 0.75;
  const FINISH_MS = 160;
  const MENU_INTERACTION_SELECTOR =
    'input, textarea, select, video, [contenteditable=true], [role=slider]';

  function isElement(target) {
    return target instanceof Element;
  }

  function isExcluded(target) {
    return Boolean(target.closest([
      'input', 'textarea', 'select', '[contenteditable="true"]',
      'button', 'a[href]', '[role="button"]', '[role="slider"]',
      '[role="tab"]', '[role="textbox"]', '[role="dialog"]',
      '[data-testid="tweetPhoto"]', '[data-testid="videoPlayer"]',
      'video', 'audio', 'canvas', '[data-xtend-no-swipe]',
    ].join(',')));
  }

  function getTabTarget(doc, leftSwipe) {
    if (doc.defaultView?.location.pathname !== '/home') return null;
    const primary = doc.querySelector('[data-testid="primaryColumn"]');
    if (!primary) return null;

    // In mobile X the sticky home tab bar is sometimes outside primaryColumn.
    // Select the visible ScrollSnap home tab bar without matching composer tabs.
    for (const list of doc.querySelectorAll('[data-testid="ScrollSnap-List"][role="tablist"]')) {
      const bounds = list.getBoundingClientRect();
      if (bounds.width < 80 || bounds.height < 30 || bounds.top < -10 || bounds.top > 160) continue;
      const tabs = Array.from(list.querySelectorAll('[role="tab"]'))
        .filter(tab => !tab.hasAttribute('disabled') && tab.getAttribute('aria-disabled') !== 'true');
      const index = tabs.findIndex(tab => tab.getAttribute('aria-selected') === 'true');
      const target = tabs[index + (leftSwipe ? 1 : -1)];
      if (index < 0 || !target) continue;

      // X virtualizes the timeline. Do not transform the entire page, its
      // scrolling container, or its sticky header. Skip drag if no surface.
      const surface = primary.querySelector('[data-xtend-swipe-surface]')
        ?? primary.querySelector('[data-testid="cellInnerDiv"]')?.parentElement
        ?? null;
      return { tab: target, surface };
    }
    return null;
  }

  function findMenu(doc) {
    // Observed mobile X: a profile toggle without aria-controls,
    // with a left drawer rendered as role=dialog.
    const win = doc.defaultView;
    if (!win || win.innerWidth > 600) return null;
    const toggle = doc.querySelector(
      'button[data-testid="DashButton_ProfileIcon_Link"][aria-expanded]'
    );
    if (toggle) {
      const expanded = toggle.getAttribute('aria-expanded');
      const rect = toggle.getBoundingClientRect();
      if ((expanded === 'true' || expanded === 'false') && rect.width > 0 && rect.height > 0) {
        const panel = Array.from(doc.querySelectorAll('[role="dialog"]')).find(el => {
          const bounds = el.getBoundingClientRect();
          return bounds.width > 160 && bounds.width < win.innerWidth &&
            bounds.height >= win.innerHeight * 0.8 && bounds.left < 12 &&
            el.querySelector('a[href]') != null;
        }) ?? null;
        if (expanded === 'false' || panel) return { toggle, menu: panel, open: expanded === 'true' };
      }
    }
    // Fallback for variants with an explicit ARIA-controlled drawer.
    for (const button of doc.querySelectorAll('button[aria-controls][aria-expanded]')) {
      const id = button.getAttribute('aria-controls');
      const expanded = button.getAttribute('aria-expanded');
      if (!id || (expanded !== 'true' && expanded !== 'false')) continue;
      const panel = doc.getElementById(id);
      if (!panel?.matches('nav, aside, [role="navigation"], [role="dialog"]')) continue;
      if (!panel.querySelector('a[href]')) continue;
      return { toggle: button, menu: panel, open: expanded === 'true' };
    }
    return null;
  }

  function changeVisual(gesture, dx, win, doc) {
    if (gesture.mode === 'menu-open' && !gesture.openedDuringDrag) {
      // X mounts the real drawer on profile-button click. Mount it only after
      // horizontal intent is established, then follow the same touch stream.
      if (!gesture.toggle?.isConnected || gesture.toggle.getAttribute('aria-expanded') !== 'false') return;
      gesture.toggle.click();
      gesture.openedDuringDrag = true;
    }
    if (gesture.mode === 'menu-open' && !gesture.surface) {
      const panel = findMenu(doc)?.menu;
      if (!panel) return;
      gesture.surface = panel;
      gesture.originalTransform = panel.style.transform;
      gesture.originalTransition = panel.style.transition;
      gesture.originalWillChange = panel.style.willChange;
      gesture.backdrop = panel.parentElement;
      gesture.originalBackdropColor = gesture.backdrop?.style.backgroundColor ?? '';
    }

    const surface = gesture.surface;
    if (!surface?.isConnected) return;
    const width = surface.getBoundingClientRect().width;
    let amount;
    if (gesture.mode === 'tab') {
      // Do not scale the entire X page or its sticky header; translate only the
      // virtualized timeline's content, up to 75% of the viewport.
      amount = Math.max(-win.innerWidth * MAX_DRAG_RATIO,
        Math.min(win.innerWidth * MAX_DRAG_RATIO, dx));
    } else if (gesture.mode === 'menu-open') {
      amount = Math.max(-width, Math.min(0, -width + Math.max(0, dx)));
    } else {
      amount = Math.max(-width, Math.min(0, dx));
    }
    surface.style.willChange = 'transform';
    surface.style.transition = 'none';
    surface.style.transform = 'translate3d(' + amount + 'px,0,0)';
    if (gesture.mode === 'menu-open' && gesture.backdrop) {
      const alpha = Math.max(0, Math.min(0.4, 0.4 * (1 + amount / width)));
      gesture.backdrop.style.backgroundColor = 'rgba(0,0,0,' + alpha + ')';
    }
  }

  function restoreVisual(gesture) {
    const surface = gesture.surface;
    if (surface?.isConnected) {
      surface.style.transform = gesture.originalTransform;
      surface.style.transition = gesture.originalTransition;
      surface.style.willChange = gesture.originalWillChange;
    }
    if (gesture.backdrop?.isConnected) {
      gesture.backdrop.style.backgroundColor = gesture.originalBackdropColor;
    }
  }

  function animateTo(gesture, amount, win, then) {
    const surface = gesture.surface;
    if (!surface?.isConnected) { then(); return; }
    surface.style.transition = 'transform ' + FINISH_MS + 'ms cubic-bezier(.2,.8,.2,1)';
    surface.style.transform = 'translate3d(' + amount + 'px,0,0)';
    win.setTimeout(then, FINISH_MS);
  }

  // Switch X's own tab as soon as the gesture is committed. WebKit keeps
  // the outgoing frame alive while the next timeline starts loading.
  // Never duplicate the X DOM or issue a speculative X API request.
  function switchTabAheadOfAnimation(doc, win, gesture, next, dx) {
    if (win.location.pathname !== gesture.path || !next?.isConnected) {
      restoreVisual(gesture);
      return null;
    }
    const surface = gesture.surface;
    const bounds = surface?.getBoundingClientRect();
    if (!surface?.isConnected || typeof doc.startViewTransition !== 'function' ||
        win.matchMedia?.('(prefers-reduced-motion: reduce)').matches ||
        !bounds || bounds.height > win.innerHeight * 3) {
      restoreVisual(gesture);
      next.click();
      return null;
    }

    const previousName = surface.style.viewTransitionName;
    const style = doc.createElement('style');
    const direction = dx < 0 ? '-' : '';
    style.textContent = `
      @keyframes xtend-swipe-exit { to { transform: translateX(${direction}100vw); } }
      ::view-transition-old(root), ::view-transition-new(root) { animation: none; }
      ::view-transition-old(xtend-timeline) {
        animation: ${FINISH_MS}ms cubic-bezier(.2,.8,.2,1) both xtend-swipe-exit;
      }
      ::view-transition-new(xtend-timeline) { animation: none; }
    `;
    (doc.head || doc.documentElement).appendChild(style);
    surface.style.viewTransitionName = 'xtend-timeline';
    let cleaned = false;
    let applied = false;
    const cleanup = () => {
      if (cleaned) return;
      cleaned = true;
      surface.style.viewTransitionName = previousName;
      style.remove();
    };
    const applyTabChange = () => {
      if (applied) return;
      applied = true;
      restoreVisual(gesture);
      if (win.location.pathname === gesture.path && next.isConnected) next.click();
    };
    try {
      const transition = doc.startViewTransition(applyTabChange);
      // A skipped or rejected transition must not leave any styles behind.
      transition.finished.then(cleanup, cleanup);
      return {
        finished: transition.finished,
        abort() {
          // Even if the user touches again before WebKit takes its snapshot,
          // the previous committed swipe must still select its destination.
          applyTabChange();
          cleanup();
          transition.skipTransition();
        },
      };
    } catch (_) {
      cleanup();
      applyTabChange();
      return null;
    }
  }

  // The beta preloader only redirects gestures when the other fully hydrated
  // WKWebView is ready. With the flag off, X's native tabs work as before.
  function requestWarmTab(doc, next) {
    const win = doc.defaultView;
    if (win?.__xtendBetaTabReady !== true || win.location.pathname !== '/home' || !next) return false;
    const list = next.closest('[data-testid="ScrollSnap-List"][role="tablist"]');
    const tabs = list && Array.from(list.querySelectorAll('[role="tab"]'));
    if (!tabs || tabs.length < 2 || ![tabs[0], tabs[1]].includes(next)) return false;
    const index = tabs.indexOf(next);
    const target = getTabTarget(doc, index === 1)?.tab;
    if (target !== next) return false;
    const bridge = win.webkit?.messageHandlers?.xtendBetaTab;
    if (!bridge) return false;
    bridge.postMessage({ action: 'switch', target: index });
    return true;
  }

  function startSwipeNavigation(doc) {
    const browserWindow = doc.defaultView;
    if (!browserWindow) return;
    const win = browserWindow;
    let active = null;
    let tabTransition = null;

    function abort() {
      if (!active) return;
      const prior = active;
      win.cancelAnimationFrame(prior.frame);
      if (prior.mode === 'menu-open' && prior.openedDuringDrag) {
        if (prior.toggle?.getAttribute('aria-expanded') === 'true') prior.toggle.click();
      }
      restoreVisual(prior);
      active = null;
    }

    function onStart(event) {
      if (tabTransition) {
        tabTransition.abort();
        tabTransition = null;
      }
      if (active) abort();
      if (event.touches.length !== 1 || !isElement(event.target)) return;
      const touch = event.touches[0];
      if (!touch) return;
      const target = event.target;
      const menu = findMenu(doc);
      const edge = touch.clientX <= EDGE_WIDTH;
      let mode;
      let surface = null;
      let toggle = null;

      if (menu?.open && menu.menu?.contains(target) && !target.closest(MENU_INTERACTION_SELECTOR)) {
        mode = 'menu-close';
        surface = menu.menu;
        toggle = menu.toggle;
      } else if (edge && menu && !menu.open && !target.closest(MENU_INTERACTION_SELECTOR)) {
        mode = 'menu-open';
        toggle = menu.toggle;
      } else {
        if (edge || isExcluded(target)) return;
        if (!target.closest('[data-testid="primaryColumn"]')) return;
        if (!getTabTarget(doc, true) && !getTabTarget(doc, false)) return;
        mode = 'tab';
      }

      active = {
        mode, path: win.location.pathname, axis: 'undecided', startX: touch.clientX, startY: touch.clientY,
        x: touch.clientX, startAt: win.performance.now(),
        surface, originalTransform: surface?.style.transform ?? '',
        originalTransition: surface?.style.transition ?? '',
        originalWillChange: surface?.style.willChange ?? '',
        tab: null, toggle, frame: 0, openedDuringDrag: false,
        backdrop: null, originalBackdropColor: '',
      };
    }

    function onMove(event) {
      const gesture = active;
      if (!gesture) return;
      if (event.touches.length !== 1) { abort(); return; }
      const touch = event.touches[0];
      if (!touch) return;
      const dx = touch.clientX - gesture.startX;
      const dy = touch.clientY - gesture.startY;
      if (gesture.axis === 'undecided') {
        if (Math.hypot(dx, dy) < HORIZONTAL_INTENT) return;
        if (Math.abs(dy) > Math.abs(dx) / AXIS_RATIO) {
          gesture.axis = 'vertical';
          return;
        }
        if (Math.abs(dx) <= Math.abs(dy) * AXIS_RATIO) return;
        if (gesture.mode === 'tab') {
          const destination = getTabTarget(doc, dx < 0);
          if (!destination) { abort(); return; }
          gesture.tab = destination.tab;
          gesture.surface = destination.surface;
          gesture.originalTransform = destination.surface?.style.transform ?? '';
          gesture.originalTransition = destination.surface?.style.transition ?? '';
          gesture.originalWillChange = destination.surface?.style.willChange ?? '';
        } else if (gesture.mode === 'menu-open' && dx <= 0) {
          abort(); return;
        } else if (gesture.mode === 'menu-close' && dx >= 0) {
          abort(); return;
        }
        gesture.axis = 'horizontal';
      }
      if (gesture.axis !== 'horizontal') return;
      if (event.cancelable) event.preventDefault();
      gesture.x = touch.clientX;
      win.cancelAnimationFrame(gesture.frame);
      gesture.frame = win.requestAnimationFrame(() => changeVisual(gesture, dx, win, doc));
    }

    function onEnd(event) {
      const gesture = active;
      if (!gesture) return;
      active = null;
      win.cancelAnimationFrame(gesture.frame);
      if (gesture.axis !== 'horizontal') {
        restoreVisual(gesture);
        return;
      }
      const touch = event.changedTouches[0];
      const dx = (touch?.clientX ?? gesture.x) - gesture.startX;
      const distance = Math.abs(dx);
      const age = Math.max(1, win.performance.now() - gesture.startAt);
      const fastFlick = age <= 350 && distance >= 42 && distance / age >= 0.55;
      const committed = distance >= Math.max(MIN_SWIPE, win.innerWidth * 0.17) || fastFlick;

      if (gesture.mode === 'menu-open') {
        if (!gesture.openedDuringDrag) {
          restoreVisual(gesture);
          return;
        }
        const width = gesture.surface?.getBoundingClientRect().width ?? 280;
        animateTo(gesture, committed ? 0 : -width, win, () => {
          if (!committed && gesture.toggle?.getAttribute('aria-expanded') === 'true') {
            gesture.toggle.click();
          }
          // X owns the native 250ms drawer animation after close.
          win.setTimeout(() => restoreVisual(gesture), committed ? 0 : 300);
        });
        if (committed && gesture.backdrop) {
          gesture.backdrop.style.backgroundColor = gesture.originalBackdropColor;
        }
        return;
      }

      if (gesture.mode === 'menu-close') {
        const width = gesture.surface?.getBoundingClientRect().width ?? 280;
        animateTo(gesture, committed ? -width : 0, win, () => {
          if (committed && gesture.toggle?.getAttribute('aria-expanded') === 'true') gesture.toggle.click();
          win.setTimeout(() => restoreVisual(gesture), committed ? 300 : 0);
        });
        return;
      }

      if (!committed) {
        animateTo(gesture, 0, win, () => restoreVisual(gesture));
      } else {
        const next = gesture.tab;
        if (requestWarmTab(doc, next)) {
          restoreVisual(gesture);
          return;
        }
        // Start the next timeline while the outgoing visual is animating,
        // instead of holding X's tab click for FINISH_MS.
        const transition = switchTabAheadOfAnimation(doc, win, gesture, next, dx);
        tabTransition = transition;
        transition?.finished.then(
          () => { if (tabTransition === transition) tabTransition = null; },
          () => { if (tabTransition === transition) tabTransition = null; }
        );
      }
    }

    function onCancel() { abort(); }
    function onVisibility() {
      if (doc.visibilityState !== 'hidden') return;
      abort();
      if (tabTransition) {
        tabTransition.abort();
        tabTransition = null;
      }
    }

    function onTabClick(event) {
      if (!event.isTrusted || !isElement(event.target)) return;
      const tab = event.target.closest('[role="tab"]');
      if (!tab || !requestWarmTab(doc, tab)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
    }
    doc.addEventListener('click', onTabClick, { capture: true });

    doc.addEventListener('touchstart', onStart, { capture: true, passive: true });
    doc.addEventListener('touchmove', onMove, { capture: true, passive: false });
    doc.addEventListener('touchend', onEnd, { capture: true, passive: true });
    doc.addEventListener('touchcancel', onCancel, { capture: true, passive: true });
    doc.addEventListener('visibilitychange', onVisibility);

  }
  startSwipeNavigation(document);
})();
