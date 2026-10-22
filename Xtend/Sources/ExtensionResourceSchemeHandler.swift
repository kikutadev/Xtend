import Foundation
import UniformTypeIdentifiers
import WebKit

/// xtend-extension://<extension-id>/... から各拡張機能のリソースだけを配信する。
@MainActor
final class ExtensionResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "xtend-extension"

    private let rootsByID: [String: URL]

    init(rootsByID: [String: URL]) {
        self.rootsByID = rootsByID.mapValues { $0.standardizedFileURL }
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == Self.scheme,
              let file = fileURL(for: url) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }
        do {
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            let response = URLResponse(
                url: url,
                mimeType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                expectedContentLength: data.count,
                textEncodingName: ["html", "css", "js", "json"].contains(file.pathExtension.lowercased()) ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func fileURL(for url: URL) -> URL? {
        guard let id = url.host,
              let root = rootsByID[id] else { return nil }
        let decoded = url.path.removingPercentEncoding ?? url.path
        let relative = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty, !relative.split(separator: "/").contains(".."),
              !relative.contains("\\") else { return nil }
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return file
    }
}
