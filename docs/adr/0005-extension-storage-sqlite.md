# ADR 0005: Store Chrome-compatible extension data in SQLite

Status: Accepted for implementation, pending simulator acceptance (2026-10-26)

## Context

Xtend runs Chrome extensions inside WKWebView with a shared `chrome.storage` shim. The active development branch has persisted namespaced JSON in `UserDefaults`; the current main branch stores per-extension/per-area JSON files with UserDefaults fallback. Both representations read and rewrite the entire namespace for a single-key update. Long-running FF history and high-frequency activity updates are inefficient. The browser's native `localStorage` and IndexedDB already exist and have different origin semantics.

## Decision

Keep `chrome.storage.local` and Xtend's device-local `chrome.storage.sync` APIs unchanged, with extension ID and area isolation. Replace only the native `ExtensionStorage` backend with SQLite (one row per extension ID / area / key). Migrate both legacy JSON-file and UserDefaults namespace representations atomically per area on first access; legacy files take precedence if present. Mark migration complete within the same transaction so stale preferences cannot resurrect deleted records after a crash. Remove legacy storage only after a successful committed migration. Uninstall removes SQLite rows and legacy namespaces. Preserve `storage.onChanged` semantics and prevent notifications on failed/unchanged writes.

## Not chosen

- Leave the full-JSON backend: real simulator performance under 8 MiB data showed roughly 45ms per update, versus sub-millisecond SQLite row updates.
- Route all storage through native WebKit IndexedDB: it works for extension settings pages, but a content script on x.com cannot directly open the extension page's origin. It would require another dedicated RPC/runtime and duplicate the existing Chrome-compatible bridge.
- Rewrite `localStorage` or IndexedDB: they are WebKit APIs, are not the `chrome.storage` shim, and overriding their origin/sync/transaction semantics risks breaking extensions and site data.

## Acceptance

- Existing FF snapshots, extension settings, and ring histories remain readable across migration and process relaunch.
- Isolation by extension ID and `local`/`sync`; keys/JSON types/`get` variants, update/remove, onChanged events, and uninstall/reset all work.
- Corruption or failed migration never silently loses records, never falls back to stale data, and never emits a successful change notification.
- Performance and data size regression compared with full-namespace JSON is measured using isolated test stores; no user content is logged.
