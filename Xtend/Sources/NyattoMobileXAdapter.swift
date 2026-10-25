/// Isolated compatibility adapter for Nyatto on mobile X.
/// No Chrome API or extension storage implementation belongs here.
enum NyattoMobileXAdapter {
    /// X's mobile drawer has no AppTabBar_Profile_Link, while desktop-oriented
    /// extensions use that link to scope data to the signed-in account.
    /// Only expose a link after a handle was confirmed in the account drawer.
    /// Never infer it from tweet/notification authors or page URLs.
    static let javascript = #"""
    (() => {
      'use strict';
      // WKUserScript may start before loadHTMLString resolves its base URL.
      const matchesHost = () => ['x.com', 'twitter.com'].includes(location.hostname);
      const storageKey = 'xtend:mobile-confirmed-viewer';
      const linkID = 'xtend-mobile-current-viewer';
      const originalSelector = 'a[data-testid="AppTabBar_Profile_Link"]';
      const profileButton = 'button[data-testid="DashButton_ProfileIcon_Link"]';
      const reserved = new Set(['home', 'explore', 'notifications', 'messages', 'settings',
        'search', 'compose', 'login', 'logout', 'signup', 'i', 'premium', 'lists']);
      const valid = value => typeof value === 'string' && /^[a-z0-9_]{1,15}$/.test(value) && !reserved.has(value);
      let confirmed = null;
      let invalidated = false;
      let scheduled = false;

      function removeLink() {
        document.getElementById(linkID)?.remove();
      }
      function invalidate() {
        confirmed = null;
        invalidated = true;
        removeLink();
        chrome.storage.local.remove(storageKey);
      }
      function signedOut() {
        return /^\/(login|logout|signup)(\/|$)|^\/i\/flow\/(login|signup)(\/|$)/.test(location.pathname) ||
          (location.pathname === '/' && !document.querySelector(profileButton));
      }
      function drawer() {
        const toggle = document.querySelector(profileButton + '[aria-expanded="true"]');
        if (!toggle || !toggle.getBoundingClientRect().width) return null;
        return [...document.querySelectorAll('[role="dialog"]')].find(panel => {
          const rect = panel.getBoundingClientRect();
          return rect.width > 160 && rect.width < innerWidth &&
            rect.height >= innerHeight * .8 && rect.left < 12;
        }) || null;
      }
      function drawerHandle(panel) {
        // Only one distinct account profile in the actual X account drawer.
        // Notification/timeline profile URLs are never consulted.
        const candidates = [...panel.querySelectorAll('a[href]')]
          .map(link => (link.getAttribute('href') || '').match(/^\/([a-zA-Z0-9_]{1,15})\/?$/)?.[1]?.toLowerCase())
          .filter(valid);
        const unique = new Set(candidates);
        if (candidates.length < 2 || unique.size !== 1) return null;
        const candidate = candidates[0];
        // Check the account label, not merely links that may point at another user.
        const matchesLabel = [...panel.querySelectorAll('span')].some(span =>
          span.textContent?.trim().toLowerCase() === '@' + candidate);
        return matchesLabel ? candidate : null;
      }
      function expose() {
        if (!confirmed || !document.body || signedOut()) { removeLink(); return; }
        if (document.querySelector(originalSelector + ':not(#' + linkID + ')')) {
          removeLink(); return;
        }
        let link = document.getElementById(linkID);
        if (!link) {
          link = document.createElement('a');
          link.id = linkID;
          link.dataset.testid = 'AppTabBar_Profile_Link';
          link.setAttribute('aria-hidden', 'true');
          link.style.cssText = 'display:none!important';
          document.body.appendChild(link);
        }
        if (link.getAttribute('href') !== '/' + confirmed) {
          link.setAttribute('href', '/' + confirmed);
        }
      }
      function sync() {
        if (!matchesHost() || innerWidth > 600) { removeLink(); return; }
        if (signedOut()) { if (confirmed) invalidate(); else removeLink(); return; }
        const panel = drawer();
        if (panel) {
          const fromDrawer = drawerHandle(panel);
          // The visible account drawer takes precedence over a saved hint.
          // A mismatched or unverified drawer must not retain another viewer.
          if (!fromDrawer && confirmed) invalidate();
          if (fromDrawer) {
            if (confirmed !== fromDrawer) {
              confirmed = fromDrawer;
              chrome.storage.local.set({ [storageKey]: fromDrawer });
            }
            invalidated = false;
          }
        }
        expose();
      }
      function schedule() {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => { scheduled = false; sync(); });
      }
      document.addEventListener('click', event => {
        // Account switching and sign-out can change the viewer without navigation.
        if (event.target.closest('[data-testid="SideNav_AccountSwitcher_Button"], [data-testid^="AccountSwitcher_"]')) {
          invalidate();
        }
      }, true);
      function start() {
        // On loadHTMLString the base URL can become available only after the
        // early user script fires. Do not initialize storage on other hosts.
        if (!matchesHost() || !document.documentElement) {
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start, { once: true });
          }
          return;
        }
        const observer = new MutationObserver(schedule);
        observer.observe(document.documentElement, {
          childList: true, subtree: true, attributes: true,
          attributeFilter: ['aria-expanded', 'href']
        });
        chrome.storage.local.get(storageKey, values => {
          const saved = values?.[storageKey];
          if (!invalidated && valid(saved)) confirmed = saved;
          schedule();
        });
        schedule();
      }
      start();
    })();
    """#
}
