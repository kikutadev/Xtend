import CryptoKit
import Foundation

@MainActor
final class ExtensionStorage {
    static let didChangeNotification = Notification.Name("XtendExtensionStorageDidChange")

    private let defaults: UserDefaults
    private let extensionID: String
    private let keyPrefix: String
    private let storageDirectory: URL

    init(extensionID: String, defaults: UserDefaults = .standard, storageDirectory: URL? = nil) {
        self.extensionID = extensionID
        self.keyPrefix = "xtend.extension.storage.\(extensionID)."
        self.defaults = defaults
        self.storageDirectory = storageDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Xtend/ExtensionStorage", isDirectory: true)
    }

    func get(area: String, keys: Any?) throws -> [String: Any] {
        let values = try namespace(area: area)

        if keys == nil || keys is NSNull {
            return values
        }

        if let key = keys as? String {
            guard let value = values[key] else { return [:] }
            return [key: value]
        }

        if let keyList = keys as? [String] {
            return keyList.reduce(into: [:]) { result, key in
                if let value = values[key] {
                    result[key] = value
                }
            }
        }

        // Chrome also accepts an object whose values act as defaults.
        if let defaultsByKey = keys as? [String: Any] {
            return defaultsByKey.reduce(into: [:]) { result, entry in
                result[entry.key] = values[entry.key] ?? entry.value
            }
        }

        throw StorageError.unsupportedKeys
    }

    @discardableResult
    func set(area: String, items: [String: Any]) throws -> [String: [String: Any]] {
        var values = try namespace(area: area)
        var changes: [String: [String: Any]] = [:]

        for (key, newValue) in items {
            let oldValue = values[key]
            if jsonEquivalent(oldValue, newValue) {
                continue
            }

            var change: [String: Any] = ["newValue": newValue]
            if let oldValue {
                change["oldValue"] = oldValue
            }
            changes[key] = change
            values[key] = newValue
        }

        guard !changes.isEmpty else { return [:] }
        try saveNamespace(values, area: area)
        emitChanges(changes, area: area)
        return changes
    }

    @discardableResult
    func remove(area: String, keys: Any?) throws -> [String: [String: Any]] {
        var values = try namespace(area: area)
        let keyList: [String]
        if let key = keys as? String {
            keyList = [key]
        } else if let keys = keys as? [String] {
            keyList = keys
        } else {
            throw StorageError.unsupportedKeys
        }

        var changes: [String: [String: Any]] = [:]
        for key in keyList {
            guard let oldValue = values.removeValue(forKey: key) else { continue }
            changes[key] = ["oldValue": oldValue]
        }

        guard !changes.isEmpty else { return [:] }
        try saveNamespace(values, area: area)
        emitChanges(changes, area: area)
        return changes
    }

    private func namespace(area: String) throws -> [String: Any] {
        try validate(area: area)
        let file = namespaceFile(for: area)
        // An existing file, including an empty dictionary, is authoritative.
        // Fall back only when upgrading an installation that used UserDefaults.
        let data: Data
        if FileManager.default.fileExists(atPath: file.path) {
            guard let stored = try? Data(contentsOf: file) else {
                throw StorageError.ioFailure
            }
            data = stored
        } else if let legacy = defaults.data(forKey: keyPrefix + area) {
            data = legacy
        } else {
            return [:]
        }
        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StorageError.corruptNamespace
        }
        return dictionary
    }

    private func saveNamespace(_ values: [String: Any], area: String) throws {
        try validate(area: area)
        guard JSONSerialization.isValidJSONObject(values) else {
            throw StorageError.nonJSONValue
        }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory, withIntermediateDirectories: true
            )
            // Only report success and broadcast changes after the atomic write.
            try data.write(to: namespaceFile(for: area), options: .atomic)
        } catch {
            // Do not return sandbox file paths to untrusted extension JavaScript.
            throw StorageError.ioFailure
        }
    }

    private func namespaceFile(for area: String) -> URL {
        // Extension IDs are not paths. Hashing prevents traversal and collisions
        // between different IDs and keeps each namespace under our own directory.
        let digest = SHA256.hash(data: Data(extensionID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return storageDirectory.appendingPathComponent("\(digest)-\(area).json")
    }

    private func validate(area: String) throws {
        guard area == "local" || area == "sync" else {
            throw StorageError.unsupportedArea
        }
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
              JSONSerialization.isValidJSONObject(["value": rhs]) else {
            return false
        }
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
        case .ioFailure: "Extension storage file is unavailable"
        }
    }
}