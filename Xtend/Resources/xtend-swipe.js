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
    const primary = doc.querySelector('[data-testid="primaryColumn"]');
    const win = doc.defaultView;
    if (!primary || !win) return null;

    // X reuses tablists on home, notifications, profiles and search.
    // Detect a real page tab bar rather than maintaining a pathname list.
    for (const list of doc.querySelectorAll('[role="tablist"]')) {
      if (!list.matches('[data-testid="ScrollSnap-List"]') &&
          !list.closest('[data-testid="primaryColumn"]')) continue;
      if (list.closest('[role="dialog"],[aria-modal="true"],article,[data-testid="cellInnerDiv"]')) continue;

      const bounds = list.getBoundingClientRect();
      if (bounds.width < 80 || bounds.height < 30 || bounds.bottom < -10 ||
          bounds.left > win.innerWidth / 2 || bounds.right < win.innerWidth / 2) continue;
      const tabs = Array.from(list.querySelectorAll('[role="tab"]'))
        .filter(tab => !tab.hasAttribute('disabled') && tab.getAttribute('aria-disabled') !== 'true');
      if (tabs.length < 2) continue;
      const index = tabs.findIndex(tab => tab.getAttribute('aria-selected') === 'true');
      const target = leftSwipe == null
        ? tabs[index + 1] ?? tabs[index - 1]
        : tabs[index + (leftSwipe ? 1 : -1)];
      if (index < 0 || !target) continue;

      // Do not move a profile header or the tab bar itself while dragging.
      const candidate = primary.querySelector('[data-xtend-swipe-surface]')
        ?? primary.querySelector('[data-testid="cellInnerDiv"]')?.parentElement
        ?? null;
      const surface = candidate?.contains(list) ? null : candidate;
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

  function rememberSurface(gesture, surface) {
    gesture.surface = surface;
    gesture.originalTransform = surface?.style.transform ?? '';
    gesture.originalTransition = surface?.style.transition ?? '';
    gesture.originalWillChange = surface?.style.willChange ?? '';
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
      rememberSurface(gesture, panel);
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

  function startSwipeNavigation(doc) {
    const browserWindow = doc.defaultView;
    if (!browserWindow) return;
    const win = browserWindow;
    let active = null;
    let settling = null;

    function cancelSettling() {
      if (!settling) return;
      const pending = settling;
      settling = null;
      win.clearTimeout(pending.timer);
      win.clearTimeout(pending.restoreTimer);
      pending.onCancel?.();
      restoreVisual(pending.gesture);
    }

    function animateTo(gesture, amount, then, restoreDelay = 0, onCancel = null) {
      const pending = { gesture, timer: 0, restoreTimer: 0, onCancel };
      settling = pending;
      const complete = () => {
        if (settling !== pending) return;
        if (win.location.pathname !== gesture.path) { cancelSettling(); return; }
        // Restore the old timeline before X processes the target tab click.
        // Otherwise a reused DOM surface can briefly inherit our drag transform.
        if (!restoreDelay) restoreVisual(gesture);
        then();
        if (restoreDelay) {
          pending.restoreTimer = win.setTimeout(() => {
            if (settling !== pending) return;
            restoreVisual(gesture);
            settling = null;
          }, restoreDelay);
        } else {
          settling = null;
        }
      };
      const surface = gesture.surface;
      if (!surface?.isConnected) { complete(); return; }
      surface.style.transition = 'transform ' + FINISH_MS + 'ms cubic-bezier(.2,.8,.2,1)';
      surface.style.transform = 'translate3d(' + amount + 'px,0,0)';
      pending.timer = win.setTimeout(complete, FINISH_MS);
    }

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
      cancelSettling();
      if (active) abort();
      if (event.touches.length !== 1 || !isElement(event.target)) return;
      const touch = event.touches[0];
      if (!touch) return;
      const target = event.target;
      const menu = findMenu(doc);
      const edge = touch.clientX <= EDGE_WIDTH;
      const historyEdge = win.location.pathname !== '/home' &&
        (edge || touch.clientX >= win.innerWidth - EDGE_WIDTH);
      let mode;
      let surface = null;
      let toggle = null;

      if (menu?.open && menu.menu?.contains(target) && !target.closest(MENU_INTERACTION_SELECTOR)) {
        mode = 'menu-close';
        surface = menu.menu;
        toggle = menu.toggle;
      } else if (edge && win.location.pathname === '/home' &&
                 menu && !menu.open && !target.closest(MENU_INTERACTION_SELECTOR) &&
                 (!isExcluded(target) ||
                  target.closest('button[data-testid="DashButton_ProfileIcon_Link"]'))) {
        mode = 'menu-open';
        toggle = menu.toggle;
      } else {
        if (edge || historyEdge || isExcluded(target)) return;
        if (!target.closest('[data-testid="primaryColumn"]')) return;
        // No direction yet: only need to know whether an adjacent tab exists.
        if (!getTabTarget(doc)) return;
        mode = 'tab';
      }

      active = {
        mode, axis: 'undecided', path: win.location.pathname,
        startX: touch.clientX, startY: touch.clientY,
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
      if (win.location.pathname !== gesture.path || event.touches.length !== 1) {
        abort();
        return;
      }
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
          rememberSurface(gesture, destination.surface);
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
      if (win.location.pathname !== gesture.path) { abort(); return; }
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
        // A fast flick may end before its scheduled animation frame executes.
        if (!gesture.openedDuringDrag) changeVisual(gesture, dx, win, doc);
        if (!gesture.openedDuringDrag) {
          restoreVisual(gesture);
          return;
        }
        const width = gesture.surface?.getBoundingClientRect().width ?? 280;
        animateTo(gesture, committed ? 0 : -width, () => {
          if (!committed && gesture.toggle?.getAttribute('aria-expanded') === 'true') {
            gesture.toggle.click();
          }
        }, committed ? 0 : 300, () => {
          if (!committed && gesture.toggle?.getAttribute('aria-expanded') === 'true') {
            gesture.toggle.click();
          }
        });
        if (committed && gesture.backdrop) {
          gesture.backdrop.style.backgroundColor = gesture.originalBackdropColor;
        }
        return;
      }

      if (gesture.mode === 'menu-close') {
        const width = gesture.surface?.getBoundingClientRect().width ?? 280;
        animateTo(gesture, committed ? -width : 0, () => {
          if (committed && gesture.toggle?.getAttribute('aria-expanded') === 'true') {
            gesture.toggle.click();
          }
        }, committed ? 300 : 0);
        return;
      }

      if (!committed) {
        animateTo(gesture, 0, () => {});
      } else {
        const next = gesture.tab;
        // X controls active tab, scroll position, and content loading.
        // Complete the outgoing motion before clicking the native tab.
        const outgoing = dx < 0 ? -win.innerWidth : win.innerWidth;
        animateTo(gesture, outgoing, () => {
          if (win.location.pathname === gesture.path && next?.isConnected) next.click();
        });
      }
    }

    function onCancel() { abort(); }
    function onVisibility() {
      if (doc.visibilityState === 'hidden') {
        abort();
        cancelSettling();
      }
    }

    doc.addEventListener('touchstart', onStart, { capture: true, passive: true });
    doc.addEventListener('touchmove', onMove, { capture: true, passive: false });
    doc.addEventListener('touchend', onEnd, { capture: true, passive: true });
    doc.addEventListener('touchcancel', onCancel, { capture: true, passive: true });
    doc.addEventListener('visibilitychange', onVisibility);

  }
  startSwipeNavigation(document);
})();
