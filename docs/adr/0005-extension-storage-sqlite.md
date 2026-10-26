# ADR 0005: Store Chrome-compatible extension data in SQLite

Status: Accepted (2026-10-26)

## Context

Xtend runs Chrome extensions inside WKWebView with a shared `chrome.storage` shim. The active development branch has persisted namespaced JSON in `UserDefaults`; the current main branch stores per-extension/per-area JSON files with UserDefaults fallback. Both representations read and rewrite the entire namespace for a single-key update. Long-running FF history and high-frequency activity updates are inefficient. The browser's native `localStorage` and IndexedDB already exist and have different origin semantics.

## Decision

Keep `chrome.storage.local` and Xtend's device-local `chrome.storage.sync` APIs unchanged, with extension ID and area isolation. Replace only the native `ExtensionStorage` backend with SQLite (one row per extension ID / area / key). Migrate both legacy JSON-file and UserDefaults namespace representations atomically per area on first access; both legacy sources are combined, with JSON-file values taking precedence on overlapping keys. Mark migration complete within the same transaction so stale preferences cannot resurrect deleted records after a crash. Remove legacy storage only after a successful committed migration. Uninstall removes SQLite rows and legacy namespaces. Preserve `storage.onChanged` semantics and prevent notifications on failed/unchanged writes.

## Not chosen

- Leave the full-JSON backend: real simulator performance under 8 MiB data showed roughly 45ms per update, versus sub-millisecond SQLite row updates.
- Route all storage through native WebKit IndexedDB: it works for extension settings pages, but a content script on x.com cannot directly open the extension page's origin. It would require another dedicated RPC/runtime and duplicate the existing Chrome-compatible bridge.
- Rewrite `localStorage` or IndexedDB: they are WebKit APIs, are not the `chrome.storage` shim, and overriding their origin/sync/transaction semantics risks breaking extensions and site data.

## Acceptance

- Existing FF snapshots, extension settings, and ring histories remain readable across migration and process relaunch.
- Isolation by extension ID and `local`/`sync`; keys/JSON types/`get` variants, update/remove, onChanged events, and uninstall/reset all work.
- Corruption or failed migration never silently loses records, never falls back to stale data, and never emits a successful change notification.
- Performance and data size regression compared with full-namespace JSON is measured using isolated test stores; no user content is logged.

## Simulator validation (2026-10-26)

- iPhone 17 Pro Simulator / iOS 26.4: 13 `ExtensionStorageTests` passed, covering UserDefaults migration, JSON-file migration, both legacy sources holding different keys, unknown JSON values up to 12 MiB, isolation, persistence, change notifications, uninstall, corruption and failure rollback.
- The simulator's installed X FF Analyzer settings screen reopened after the SQLite-backed app launched and displayed previously saved **follower** partial history. Its previous **following** snapshot was not displayed in that run. Do **not** represent that historical following data as verified in this app build. The test using this specific preconfigured Simulator installation is kept as local evidence only, not a committed suite test that would fail on clean installs.
- The separate legacy-source merge unit test explicitly demonstrates old follower and newer following keys are both preserved when a file-based namespace and UserDefaults namespace coexist.
- This branch updates only Xtend's common extension storage backend and uninstall cleanup, not the X FF Analyzer extension or WebKit localStorage/IndexedDB.

- The shipped SQLite-backed `ExtensionStorage` itself was benchmarked on the same iPhone 17 Pro Simulator with an 8 MiB synthetic namespace: 80 activity writes had median 1.063ms (p95 1.367ms); individual keyed reads had median 0.883ms. The prior full-JSON UserDefaults implementation measured roughly 45.5ms write / 21.1ms read under the same synthetic namespace in its earlier isolated experiment. Hardware and test-run differences may affect results.
