import CryptoKit
import Foundation
import SQLite3

/// The common `chrome.storage` implementation used by every installed extension.
/// Values are opaque JSON to Xtend. WebKit's localStorage/IndexedDB are not intercepted.
@MainActor
final class ExtensionStorage {
    static let didChangeNotification = Notification.Name("XtendExtensionStorageDidChange")

    private let defaults: UserDefaults
    private let extensionID: String
    private let keyPrefix: String
    private let storageDirectory: URL
    private let filenamePrefix: String
    private nonisolated(unsafe) var connection: OpaquePointer?

    init(extensionID: String, defaults: UserDefaults = .standard, storageDirectory: URL? = nil) {
        self.extensionID = extensionID
        self.keyPrefix = "xtend.extension.storage.\(extensionID)."
        self.defaults = defaults
        self.storageDirectory = storageDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Xtend/ExtensionStorage", isDirectory: true)
        self.filenamePrefix = SHA256.hash(data: Data(extensionID.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    func get(area: String, keys: Any?) throws -> [String: Any] {
        try migrateIfNeeded(area: area)
        if keys == nil || keys is NSNull { return try namespace(area: area) }
        if let key = keys as? String {
            guard let value = try read(key: key, area: area) else { return [:] }
            return [key: value]
        }
        if let keyList = keys as? [String] {
            var result: [String: Any] = [:]
            for key in keyList { if let value = try read(key: key, area: area) { result[key] = value } }
            return result
        }
        if let defaultsByKey = keys as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, fallback) in defaultsByKey {
                result[key] = try read(key: key, area: area) ?? fallback
            }
            return result
        }
        throw StorageError.unsupportedKeys
    }

    @discardableResult
    func set(area: String, items: [String: Any]) throws -> [String: [String: Any]] {
        try migrateIfNeeded(area: area)
        var newData: [String: String] = [:]
        for (key, value) in items { newData[key] = try jsonString(value) }
        let changes: [String: [String: Any]] = try transaction {
            var updates: [String: [String: Any]] = [:]
            for (key, json) in newData {
                let old = try read(key: key, area: area)
                let newValue = items[key]!
                if jsonEquivalent(old, newValue) { continue }
                try execute("INSERT INTO values_store (extension_id, area, key, json) VALUES (?, ?, ?, ?) " +
                            "ON CONFLICT(extension_id, area, key) DO UPDATE SET json=excluded.json",
                            [extensionID, area, key, json])
                var change: [String: Any] = ["newValue": newValue]
                if let old { change["oldValue"] = old }
                updates[key] = change
            }
            return updates
        }
        if !changes.isEmpty { emitChanges(changes, area: area) }
        return changes
    }

    @discardableResult
    func remove(area: String, keys: Any?) throws -> [String: [String: Any]] {
        try migrateIfNeeded(area: area)
        let names: [String]
        if let key = keys as? String { names = [key] }
        else if let list = keys as? [String] { names = list }
        else { throw StorageError.unsupportedKeys }
        let changes: [String: [String: Any]] = try transaction {
            var updates: [String: [String: Any]] = [:]
            for key in Set(names) {
                guard let old = try read(key: key, area: area) else { continue }
                try execute("DELETE FROM values_store WHERE extension_id=? AND area=? AND key=?", [extensionID, area, key])
                updates[key] = ["oldValue": old]
            }
            return updates
        }
        if !changes.isEmpty { emitChanges(changes, area: area) }
        return changes
    }

    /// Called when a package is uninstalled. Keep migration tombstones so a
    /// late preference write cannot resurrect data after a reinstall.
    func eraseAll() throws {
        _ = try openDatabase()
        try transaction {
            try execute("DELETE FROM values_store WHERE extension_id=?", [extensionID])
            for area in ["local", "sync"] {
                try execute("INSERT OR IGNORE INTO migrated(extension_id, area) VALUES (?, ?)", [extensionID, area])
            }
        }
        for area in ["local", "sync"] { removeLegacy(area: area) }
    }

    private func migrateIfNeeded(area: String) throws {
        try validate(area: area)
        _ = try openDatabase()
        let marker = try statement("SELECT 1 FROM migrated WHERE extension_id=? AND area=?", [extensionID, area])
        let done = sqlite3_step(marker) == SQLITE_ROW
        sqlite3_finalize(marker)
        if done { removeLegacy(area: area); return }

        // Main-branch JSON and older UserDefaults may both exist when users
        // switch between development builds. Keep the union of their keys;
        // where both specify a key, retain the file-backed value, matching
        // the precedence used by the previous released implementation.
        let file = legacyFile(area: area)
        let fileExists = FileManager.default.fileExists(atPath: file.path)
        let fileData: Data?
        if fileExists {
            guard let data = try? Data(contentsOf: file) else { throw StorageError.ioFailure }
            fileData = data
        } else { fileData = nil }
        let preferencesData = defaults.data(forKey: keyPrefix + area)
        func decode(_ data: Data?) throws -> [String: Any] {
            guard let data else { return [:] }
            guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StorageError.corruptNamespace
            }
            return dictionary
        }
        var values = try decode(preferencesData)
        values.merge(try decode(fileData)) { _, fromFile in fromFile }

        try transaction {
            for (key, value) in values {
                try execute("INSERT INTO values_store (extension_id, area, key, json) VALUES (?, ?, ?, ?)",
                            [extensionID, area, key, try jsonString(value)])
            }
            try execute("INSERT INTO migrated(extension_id, area) VALUES (?, ?)", [extensionID, area])
        }
        // Only remove older copies after SQLite has committed every value.
        removeLegacy(area: area)
    }

    private func namespace(area: String) throws -> [String: Any] {
        let stmt = try statement("SELECT key, json FROM values_store WHERE extension_id=? AND area=?", [extensionID, area])
        defer { sqlite3_finalize(stmt) }
        var result: [String: Any] = [:]
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW,
                  let key = sqlite3_column_text(stmt, 0),
                  let json = sqlite3_column_text(stmt, 1) else { throw StorageError.ioFailure }
            result[String(cString: key)] = try parse(String(cString: json))
        }
    }

    private func read(key: String, area: String) throws -> Any? {
        let stmt = try statement("SELECT json FROM values_store WHERE extension_id=? AND area=? AND key=?", [extensionID, area, key])
        defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { throw StorageError.ioFailure }
        return try parse(String(cString: raw))
    }

    private func parse(_ text: String) throws -> Any {
        guard let data = text.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            throw StorageError.corruptNamespace
        }
        return result
    }

    private func jsonString(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(["value": value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { throw StorageError.nonJSONValue }
        return string
    }

    private func openDatabase() throws -> OpaquePointer {
        if let connection { return connection }
        do { try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true) }
        catch { throw StorageError.ioFailure }
        var db: OpaquePointer?
        let path = storageDirectory.appendingPathComponent("extension-storage.sqlite").path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw StorageError.ioFailure
        }
        connection = db
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS values_store (extension_id TEXT NOT NULL, " +
                        "area TEXT NOT NULL, key TEXT NOT NULL, json TEXT NOT NULL, " +
                        "PRIMARY KEY(extension_id, area, key))")
            try execute("CREATE TABLE IF NOT EXISTS migrated (extension_id TEXT NOT NULL, " +
                        "area TEXT NOT NULL, PRIMARY KEY(extension_id, area))")
        } catch {
            connection = nil
            sqlite3_close(db)
            throw error
        }
        return db
    }

    private func statement(_ sql: String, _ bindings: [String]) throws -> OpaquePointer {
        let db = try openDatabase()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StorageError.ioFailure
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let status = value.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, transient) }
            if status != SQLITE_OK { sqlite3_finalize(stmt); throw StorageError.ioFailure }
        }
        return stmt
    }

    private func execute(_ sql: String, _ bindings: [String] = []) throws {
        let stmt = try statement(sql, bindings)
        defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw StorageError.ioFailure
        }
    }

    private func transaction<T>(_ run: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try run()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func legacyFile(area: String) -> URL {
        storageDirectory.appendingPathComponent("\(filenamePrefix)-\(area).json")
    }

    private func removeLegacy(area: String) {
        defaults.removeObject(forKey: keyPrefix + area)
        try? FileManager.default.removeItem(at: legacyFile(area: area))
    }

    private func validate(area: String) throws {
        guard area == "local" || area == "sync" else { throw StorageError.unsupportedArea }
    }

    private func emitChanges(_ changes: [String: [String: Any]], area: String) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: ["extensionID": extensionID, "area": area, "changes": changes]
        )
    }

    private func jsonEquivalent(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let lhs else { return false }
        guard JSONSerialization.isValidJSONObject(["value": lhs]),
              JSONSerialization.isValidJSONObject(["value": rhs]) else { return false }
        let lhsData = try? JSONSerialization.data(withJSONObject: ["value": lhs], options: [.sortedKeys])
        let rhsData = try? JSONSerialization.data(withJSONObject: ["value": rhs], options: [.sortedKeys])
        return lhsData == rhsData
    }
}

enum StorageError: LocalizedError {
    case unsupportedArea
    case unsupportedKeys
    case corruptNamespace
    case nonJSONValue
    case ioFailure

    var errorDescription: String? {
        switch self {
        case .unsupportedArea: "Unsupported Chrome storage area"
        case .unsupportedKeys: "Unsupported chrome.storage key shape"
        case .corruptNamespace: "Stored extension namespace is corrupt"
        case .nonJSONValue: "Extension attempted to store a non-JSON value"
        case .ioFailure: "Extension storage is unavailable"
        }
    }
}
