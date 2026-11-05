import Foundation
import ZIPFoundation

/// Opt-in, locally bundled ZIPs are installed once using the same validator as manual imports.
/// Normal/public builds contain no ZIPs and do nothing.
enum BundledExtensionInstaller {
    static let directoryName = "PreinstalledExtensions"
    private static let markerPrefix = "xtend.bundledExtensionInstalled."

    @discardableResult
    static func installIfPresent(
        directory: URL? = Bundle.main.resourceURL?.appendingPathComponent(directoryName),
        store: CommunityExtensionStore = CommunityExtensionStore(),
        preferences: UserDefaults = .standard
    ) -> [String] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
              ) else { return [] }

        var failures: [String] = []
        for archive in files.filter({ $0.pathExtension.lowercased() == "zip" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let marker = markerPrefix + archive.lastPathComponent
            if preferences.bool(forKey: marker) { continue }

            do {
                let manifest = try packagedManifest(at: archive)
                let matching = store.installedRoots().values.compactMap {
                    try? CommunityExtensionStore.validateManifest(at: $0)
                }.first { $0.name == manifest.name }
                if let matching, matching.version.compare(manifest.version, options: .numeric) != .orderedAscending {
                    // Preserve an existing equal or newer version, including manual installs.
                    preferences.set(true, forKey: marker)
                    continue
                }
                _ = try store.installFromZIP(archive)
                preferences.set(true, forKey: marker)
            } catch {
                failures.append(archive.lastPathComponent)
                NSLog("Xtend: bundled extension could not be installed: %@ (%@)",
                      archive.lastPathComponent, error.localizedDescription)
            }
        }
        return failures
    }

    private static func packagedManifest(at url: URL) throws -> InstalledExtensionManifest {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["manifest.json"], entry.uncompressedSize <= 65536 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        return try JSONDecoder().decode(InstalledExtensionManifest.self, from: data)
    }
}
