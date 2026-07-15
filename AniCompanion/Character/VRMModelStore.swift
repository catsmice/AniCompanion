import Foundation
import WebKit

// MARK: - VRMModelInfo

/// A VRM model discovered on disk, ready to show in the picker.
struct VRMModelInfo: Identifiable, Hashable {
    /// The on-disk filename (also the picker's selection value / the stored `vrm_model_filename`).
    let filename: String
    /// Friendly name to show — the embedded VRM title if present, else the filename stem.
    let displayName: String
    /// Whether it lives in the read-only bundle or the user-writable directory.
    let isBuiltIn: Bool

    var id: String { filename }
}

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

    /// The filename of the default shipped model — shown as "小光" in the picker.
    static let defaultModelFilename = "AvatarSample_A.vrm"

    // MARK: - Discovery

    /// Every `.vrm` across the bundle + user directory, deduped by filename (user wins), sorted
    /// with the default first, then alphabetically by display name.
    func availableModels() -> [VRMModelInfo] {
        var byName: [String: VRMModelInfo] = [:]

        // Bundle first so user-dir entries overwrite (win) on filename collision.
        if let bundleDir = bundleModelsDirectory {
            for url in vrmFiles(in: bundleDir) {
                byName[url.lastPathComponent] = makeInfo(url: url, isBuiltIn: true)
            }
        }
        for url in vrmFiles(in: userModelsDirectory) {
            byName[url.lastPathComponent] = makeInfo(url: url, isBuiltIn: false)
        }

        let sorted = byName.values.sorted { a, b in
            if a.filename == Self.defaultModelFilename { return true }
            if b.filename == Self.defaultModelFilename { return false }
            let byDisplay = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
            if byDisplay != .orderedSame { return byDisplay == .orderedAscending }
            return a.filename.localizedCaseInsensitiveCompare(b.filename) == .orderedAscending
        }

        // Disambiguate identical display names (e.g. the same model imported twice, both carrying
        // the embedded title "Alicia Solid") by appending the filename to every duplicate after
        // the first — so the first stays clean and the rest read "Alicia Solid (AliciaSolid 2.vrm)".
        var seenDisplayNames: Set<String> = []
        return sorted.map { info in
            guard seenDisplayNames.contains(info.displayName) else {
                seenDisplayNames.insert(info.displayName)
                return info
            }
            return VRMModelInfo(
                filename: info.filename,
                displayName: "\(info.displayName) (\(info.filename))",
                isBuiltIn: info.isBuiltIn
            )
        }
    }

    private func vrmFiles(in dir: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "vrm" } ?? []
    }

    private func makeInfo(url: URL, isBuiltIn: Bool) -> VRMModelInfo {
        let filename = url.lastPathComponent
        let display: String
        if filename == Self.defaultModelFilename {
            display = "小光"
        } else {
            display = Self.embeddedTitle(of: url) ?? url.deletingPathExtension().lastPathComponent
        }
        return VRMModelInfo(filename: filename, displayName: display, isBuiltIn: isBuiltIn)
    }

    // MARK: - Import

    /// Copy a user-picked `.vrm` into the writable models directory, returning the stored filename.
    /// On a name collision with an existing user model, a numeric suffix is appended.
    @discardableResult
    func importModel(from source: URL) throws -> String {
        let dir = userModelsDirectory
        var dest = dir.appendingPathComponent(source.lastPathComponent)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        }
        try fm.copyItem(at: source, to: dest)
        return dest.lastPathComponent
    }

    // MARK: - Embedded VRM title (GLB parse)

    /// Read the embedded model title from a `.vrm` (a glTF-Binary container) without a full parse:
    /// pull the JSON chunk and read `extensions.VRM.meta.title` (VRM 0.x) or
    /// `extensions.VRMC_vrm.meta.name` (VRM 1.0). Returns nil on any malformation.
    static func embeddedTitle(of url: URL) -> String? {
        // Read only enough of the file to cover the header + JSON chunk (cap at 2 MB).
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2_000_000), head.count > 20 else { return nil }

        return head.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            func u32(_ offset: Int) -> UInt32 {
                raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
            // GLB header: magic "glTF" (0x46546C67), version, total length.
            guard u32(0) == 0x4654_6C67 else { return nil }
            let jsonLen = Int(u32(12))          // first chunk length
            let jsonType = u32(16)              // first chunk type — must be "JSON" (0x4E4F534A)
            guard jsonType == 0x4E4F_534A, 20 + jsonLen <= head.count else { return nil }
            let jsonData = Data(bytes: raw.baseAddress!.advanced(by: 20), count: jsonLen)

            guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let ext = obj["extensions"] as? [String: Any] else { return nil }

            if let vrm0 = ext["VRM"] as? [String: Any],
               let meta = vrm0["meta"] as? [String: Any],
               let title = (meta["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return title
            }
            if let vrm1 = ext["VRMC_vrm"] as? [String: Any],
               let meta = vrm1["meta"] as? [String: Any],
               let name = (meta["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            return nil
        }
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
