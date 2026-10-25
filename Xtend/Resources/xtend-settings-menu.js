(() => {
  if (!['x.com', 'twitter.com'].includes(location.hostname)) return;
  const bridge = window.webkit?.messageHandlers?.xtendSettings;
  if (!bridge) return;
  const entryID = 'xtend-native-settings-entry';
  const tipID = 'xtend-settings-tip';
  const promoStyle = document.createElement('style');
  promoStyle.textContent = '[data-xtend-hidden-menu-promo],[data-xtend-hidden-page-promo]{display:none!important}';
  (document.head || document.documentElement).appendChild(promoStyle);
  let tipCompleted = !__xtendShowSettingsTip;
  const loginPaths = ['/i/flow/login', '/i/flow/signup', '/i/flow/password_reset', '/login', '/signup', '/account/access'];
  let lastLogin = null;
  let queued = false;


  function loginVisible() {
    const path = location.pathname;
    if (loginPaths.some(p => path === p || path.startsWith(p + '/'))) return true;
    // X can show a signed-out landing page without navigating to /login.
    return path === '/' &&
      !document.querySelector('button[data-testid="DashButton_ProfileIcon_Link"]') &&
      !!document.querySelector('a[href="/i/flow/login"], a[href="/login"], [data-testid="loginButton"]');
  }

  function findDrawer() {
    if (innerWidth > 600) return null;
    const toggle = document.querySelector('button[data-testid="DashButton_ProfileIcon_Link"][aria-expanded="true"]');
    if (!toggle || !toggle.getBoundingClientRect().width) return null;
    return [...document.querySelectorAll('[role="dialog"]')].find(panel => {
      const r = panel.getBoundingClientRect();
      return r.width > 160 && r.width < innerWidth && r.height >= innerHeight * .8 && r.left < 12 && !!panel.querySelector('a[href]');
    }) || null;
  }

  // Only remove the two promotional links from X's mobile navigation drawer.
  // Do not hide the same words in posts, profiles, or subscription controls.
  const hiddenPromoAttribute = 'data-xtend-hidden-menu-promo';
  const pagePromoAttribute = 'data-xtend-hidden-page-promo';
  const promoLabels = new Set(['get the app', 'subscribe']);

  function hideMenuPromotions(drawer) {
    for (const item of drawer.querySelectorAll('a[href], button, [role="link"], [role="button"]')) {
      const labels = [item.getAttribute('aria-label'), item.textContent]
        .filter(Boolean)
        .map(value => value.replace(/\s+/g, ' ').trim().toLowerCase());
      if (labels.some(label => promoLabels.has(label))) {
        item.setAttribute(hiddenPromoAttribute, '');
      } else {
        item.removeAttribute(hiddenPromoAttribute);
      }
    }
  }

  function hidePagePromotions() {
    // Keep header promotions separate from drawer items and actual post controls.
    for (const item of document.querySelectorAll('a[href], button, [role="link"], [role="button"]')) {
      const label = (item.getAttribute('aria-label') || item.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
      const premiumUpsell = label === 'subscribe' &&
        item.tagName === 'A' && item.getAttribute('href') === '/i/premium_sign_up';
      const appUpsell = label === 'get the app';
      if ((premiumUpsell || appUpsell) && !item.closest('article,[data-testid="tweet"]')) {
        const rect = item.getBoundingClientRect();
        if ((rect.width > 0 && rect.top >= 0 && rect.top < 150) ||
            item.hasAttribute(pagePromoAttribute)) {
          item.setAttribute(pagePromoAttribute, '');
          continue;
        }
      }
      item.removeAttribute(pagePromoAttribute);
    }
  }

  function insertSettings(drawer) {
    if (drawer.querySelector('#' + entryID)) return;
    const row = document.createElement('div');
    row.id = entryID;
    // Keep the footer on screen even when X's navigation links scroll.
    row.style.cssText = 'position:absolute;left:0;right:0;bottom:max(64px,env(safe-area-inset-bottom));z-index:10;border-top:1px solid rgba(128,128,128,.25);background:Canvas;color:CanvasText;';
    const button = document.createElement('button');
    button.type = 'button';
    button.setAttribute('aria-label', 'Xtendの設定');
    button.style.cssText = 'box-sizing:border-box;display:flex;align-items:center;gap:16px;width:100%;min-height:52px;padding:12px 16px;border:0;background:transparent;color:inherit;font:700 20px/1.3 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;text-align:left;cursor:pointer;';
    const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    icon.setAttribute('viewBox', '0 0 24 24');
    icon.setAttribute('width', '23');
    icon.setAttribute('height', '23');
    icon.setAttribute('fill', 'none');
    icon.setAttribute('stroke', 'currentColor');
    icon.setAttribute('stroke-width', '2');
    icon.setAttribute('stroke-linecap', 'round');
    icon.setAttribute('stroke-linejoin', 'round');
    for (const d of ['M4 7h16', 'M4 17h16', 'M8 4v6', 'M16 14v6']) {
      const line = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      line.setAttribute('d', d);
      icon.appendChild(line);
    }
    button.append(icon, document.createTextNode('Xtendの設定'));
    button.addEventListener('click', e => {
      e.preventDefault();
      e.stopPropagation();
      completeTip();
      bridge.postMessage({ action: 'open' });
    });
    row.appendChild(button);
    drawer.appendChild(row);
  }


  let hasShownMenuTarget = false;
  let lastDrawer = null;

  function completeTip() {
    if (tipCompleted) return;
    tipCompleted = true;
    document.getElementById(tipID)?.remove();
    bridge.postMessage({ action: 'walkthroughDone' });
  }

  function hideTip() {
    document.getElementById(tipID)?.remove();
  }

  function drawSpotlight(target, step) {
    const r = target.getBoundingClientRect();
    if (r.width < 20 || r.height < 20) { hideTip(); return; }
    let tip = document.getElementById(tipID);
    if (!tip) {
      tip = document.createElement('div');
      tip.id = tipID;
      tip.style.cssText = 'position:fixed;inset:0;z-index:2147483000;pointer-events:none;font:600 14px -apple-system,BlinkMacSystemFont,sans-serif;';
      const focus = document.createElement('div');
      focus.dataset.xtendFocus = '';
      focus.style.cssText = 'position:absolute;box-sizing:border-box;border:2px solid #6bd6ff;border-radius:14px;box-shadow:0 0 0 9999px rgba(0,0,0,.60),0 0 0 4px rgba(107,214,255,.22);pointer-events:none;';
      tip.appendChild(focus);
      document.body.appendChild(tip);
    }
    const focus = tip.querySelector('[data-xtend-focus]');
    const pad = step === 'menu' ? 3 : 5;
    focus.style.left = Math.max(2, r.left - pad) + 'px';
    focus.style.top = Math.max(2, r.top - pad) + 'px';
    focus.style.width = (r.width + pad * 2) + 'px';
    focus.style.height = (r.height + pad * 2) + 'px';
    focus.style.borderRadius = (step === 'menu' ? 12 : Math.ceil(r.height / 2 + pad)) + 'px';

    let note = tip.querySelector('[data-xtend-note]');
    if (step === 'avatar') {
      if (!note) {
        note = document.createElement('div');
        note.dataset.xtendNote = '';
        note.style.cssText = 'position:absolute;display:flex;align-items:center;gap:10px;border-radius:18px;padding:7px 8px 7px 12px;background:#fff;color:#111;box-shadow:0 3px 14px #0003;pointer-events:auto;';
        const text = document.createElement('span');
        text.textContent = '← 設定';
        const close = document.createElement('button');
        close.type = 'button';
        close.textContent = '×';
        close.setAttribute('aria-label', '案内を閉じる');
        close.style.cssText = 'background:transparent;border:0;color:#666;font:22px -apple-system,sans-serif;width:30px;height:30px;padding:0;cursor:pointer;';
        close.addEventListener('click', completeTip);
        note.append(text, close);
        tip.appendChild(note);
      }
      const left = Math.min(r.right + 12, innerWidth - 118);
      note.style.left = Math.max(8, left) + 'px';
      note.style.top = Math.max(8, r.top + r.height / 2 - 22) + 'px';
    } else {
      note?.remove();
    }
  }

  function updateTip(drawer) {
    if (tipCompleted) { hideTip(); return; }
    if (hasShownMenuTarget && !drawer) { completeTip(); return; }
    if (drawer) {
      const button = drawer.querySelector('#' + entryID + ' button');
      if (!button) { hideTip(); return; }
      hasShownMenuTarget = true;
      drawSpotlight(button, 'menu');
      return;
    }
    const toggle = document.querySelector('button[data-testid="DashButton_ProfileIcon_Link"]');
    const composer = [...document.querySelectorAll('[role="dialog"]')].some(el => {
      const rect = el.getBoundingClientRect();
      return rect.width > 100 && rect.height > 100;
    });
    const visible = location.pathname === '/home' && !composer &&
      !!toggle && toggle.getAttribute('aria-expanded') === 'false' &&
      toggle.getBoundingClientRect().width > 0;
    if (!visible) { hideTip(); return; }
    drawSpotlight(toggle, 'avatar');
  }

  function sync() {
    const visible = loginVisible();
    if (visible !== lastLogin) {
      lastLogin = visible;
      bridge.postMessage({ action: 'login', visible });
    }
    const drawer = findDrawer();
    if (drawer) {
      hideMenuPromotions(drawer);
      insertSettings(drawer);
    }
    // Reposition the highlight after X's drawer slide animation finishes.
    if (drawer && drawer !== lastDrawer && !tipCompleted) setTimeout(schedule, 350);
    lastDrawer = drawer;
    updateTip(drawer);
    hidePagePromotions();

  }
  function schedule() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; sync(); });
  }
  new MutationObserver(schedule).observe(document.documentElement, {
    childList: true, subtree: true, attributes: true, attributeFilter: ['aria-expanded']
  });
  schedule();
})();
