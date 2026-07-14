import Foundation
import WebKit

// MARK: - VRMModelStore

/// Locates VRM model files across the two places they can live:
///   • the **read-only app bundle** (`Resources/VRMModel/`) — the shipped default (AvatarSample_A), and
///   • a **user-writable directory** (`~/Library/Application Support/AniCompanion/VRMModel/`) — models
///     the user imports ("Add your own VRM…") or downloads (e.g. Alicia).
///
/// The shipped `.app` bundle is read-only, so any model the user adds after install must live in the
/// writable directory; this store is the single place that knows about both.
@MainActor
final class VRMModelStore {

    static let shared = VRMModelStore()

    private let fm = FileManager.default

    /// `~/Library/Application Support/AniCompanion/VRMModel/`, created on first access.
    var userModelsDirectory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AniCompanion/VRMModel", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The bundle's built-in models directory.
    private var bundleModelsDirectory: URL? {
        Bundle.main.url(forResource: "VRMModel", withExtension: nil)
    }

    /// Resolve a model filename to a file URL. The user directory wins over the bundle, so an
    /// imported/downloaded model can shadow (or simply add to) the built-ins.
    func resolve(filename: String) -> URL? {
        let userURL = userModelsDirectory.appendingPathComponent(filename)
        if fm.fileExists(atPath: userURL.path) { return userURL }
        if let bundleURL = bundleModelsDirectory?.appendingPathComponent(filename),
           fm.fileExists(atPath: bundleURL.path) {
            return bundleURL
        }
        return nil
    }
}

// MARK: - VRMURLSchemeHandler

/// Serves VRM files to the WKWebView over a custom `vrm://` scheme, so the scene can load a model
/// from **anywhere on disk** — the read-only bundle *or* the user-writable directory — without being
/// constrained by `WKWebView`'s single `allowingReadAccessTo` file scope.
///
/// The JS scene requests `vrm://model/<filename>`; this resolves it via `VRMModelStore` and returns
/// the bytes. `Access-Control-Allow-Origin: *` lets the `file://` page fetch it.
final class VRMURLSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "vrm"

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        // `vrm://model/<filename>` → lastPathComponent (percent-decoded by URL).
        let filename = requestURL.lastPathComponent

        let fileURL = MainActor.assumeIsolated { VRMModelStore.shared.resolve(filename: filename) }
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            Log.character("[VRM] scheme handler: model not found for \(filename)")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }

        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
