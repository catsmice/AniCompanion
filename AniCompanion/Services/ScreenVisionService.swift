import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit

// MARK: - ScreenVisionScope

/// What 小光 captures when screen vision is enabled.
///
/// `focusedWindow` is the privacy-preserving default — it captures only the frontmost window
/// of the app you're actually working in (never AniCompanion itself), so other windows,
/// notifications, and the menu bar stay out of frame. `entireScreen` grabs the whole display
/// (still excluding AniCompanion's own overlay).
enum ScreenVisionScope: String, CaseIterable, Identifiable, Sendable {
    case focusedWindow
    case entireScreen

    var id: String { rawValue }

    static let storageKey = "screen_vision_scope"

    var displayName: LocalizedStringKey {
        switch self {
        case .focusedWindow: return "Focused window"
        case .entireScreen: return "Entire screen"
        }
    }

    var hint: LocalizedStringKey {
        switch self {
        case .focusedWindow:
            return "Only the window of the app you're working in — never AniCompanion, and not your other windows."
        case .entireScreen:
            return "The whole screen (AniCompanion's own overlay is excluded)."
        }
    }
}

// MARK: - ScreenVisionError

enum ScreenVisionError: LocalizedError {
    case notAuthorized
    case noCaptureTarget
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return String(localized: "Screen Recording permission isn't granted. Enable it in System Settings → Privacy & Security → Screen Recording.")
        case .noCaptureTarget:
            return String(localized: "Nothing to look at yet — open the app you're working in first.")
        case .captureFailed(let detail):
            return String(localized: "Screen capture failed: \(detail)")
        }
    }
}

// MARK: - ScreenVisionService

/// Captures what the user is working on so 小光 can "see the screen."
///
/// Design: capture is **on-demand per turn**, never a continuous stream — the caller asks for a
/// single frame when she's about to speak. Two scopes:
/// the frontmost window of the user's active app (default) or the whole display. In both cases
/// **AniCompanion's own windows are excluded** so she never captures herself.
///
/// The "focused window" is derived from the **last activated non-self application** (tracked via
/// `NSWorkspace` activation notifications), not the literal frontmost app: when you turn to talk to
/// 小光 you momentarily make *her* frontmost, but the thing you were working on is what she should
/// see — so we remember the last app that wasn't us.
///
/// Uses `ScreenCaptureKit` (`SCScreenshotManager`, macOS 14+); output is downscaled JPEG `Data`
/// ready to drop into an OpenAI-style `image_url` content part.
@MainActor
final class ScreenVisionService {

    // MARK: - Configuration

    /// Which region to capture. Mutable so Settings changes take effect without rebuilding the service.
    var scope: ScreenVisionScope

    /// Longest edge (in pixels) of the emitted image; larger captures are downscaled to bound
    /// vision-token cost and upload size.
    private let maxPixelDimension: CGFloat

    /// JPEG compression quality (0…1).
    private let jpegQuality: CGFloat

    // MARK: - Private State

    /// Our own process id, so we can exclude AniCompanion's windows from every capture.
    private let selfPID: pid_t = NSRunningApplication.current.processIdentifier

    /// PID of the most recently activated application that wasn't us — the "work" the user is on.
    private var lastWorkAppPID: pid_t?

    // MARK: - Initialization

    init(
        scope: ScreenVisionScope = .focusedWindow,
        maxPixelDimension: CGFloat = 1280,
        jpegQuality: CGFloat = 0.7
    ) {
        self.scope = scope
        self.maxPixelDimension = maxPixelDimension
        self.jpegQuality = jpegQuality

        // Seed with the current frontmost app if it isn't us.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != selfPID {
            lastWorkAppPID = front.processIdentifier
        }

        // Track subsequent app activations so we always know the user's real work context.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Records the last non-self app the user switched to. `NSWorkspace` posts these on the main
    /// thread, matching this class's `@MainActor` isolation.
    @objc private func applicationActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.processIdentifier != selfPID else { return }
        lastWorkAppPID = app.processIdentifier
    }

    // MARK: - Permission

    /// Whether Screen Recording permission is currently granted (does not prompt).
    var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Requests Screen Recording permission, prompting the system dialog the first time.
    /// Returns the resulting authorization state. Grant/revoke takes effect on next app launch
    /// for the OS, but `SCShareableContent` reflects the live state.
    @discardableResult
    func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Capture

    /// Capture a single frame of the user's current work as downscaled JPEG data.
    ///
    /// - Returns: JPEG `Data` suitable for a `data:image/jpeg;base64,…` URL.
    /// - Throws: `ScreenVisionError` if permission is missing, there's nothing to capture, or
    ///   encoding fails.
    func captureCurrentWork() async throws -> Data {
        guard hasAccess else { throw ScreenVisionError.notAuthorized }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // A revoked permission surfaces here as a capture error.
            throw ScreenVisionError.notAuthorized
        }

        let filter = try makeFilter(from: content)
        let config = makeConfiguration(for: filter)

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenVisionError.captureFailed(error.localizedDescription)
        }

        guard let data = Self.jpegData(from: cgImage, quality: jpegQuality) else {
            throw ScreenVisionError.captureFailed("Could not encode the screenshot.")
        }
        Log.pipeline("[Vision] Captured \(cgImage.width)x\(cgImage.height) → \(data.count / 1024) KB JPEG (scope=\(scope.rawValue))")
        return data
    }

    // MARK: - Filter

    private func makeFilter(from content: SCShareableContent) throws -> SCContentFilter {
        switch scope {
        case .focusedWindow:
            guard let window = focusedWorkWindow(in: content) else {
                throw ScreenVisionError.noCaptureTarget
            }
            return SCContentFilter(desktopIndependentWindow: window)

        case .entireScreen:
            let display = displayForTarget(in: content)
            guard let display else { throw ScreenVisionError.noCaptureTarget }
            // Exclude our own windows so the pet overlay isn't in the shot she analyzes.
            let ourWindows = content.windows.filter { $0.owningApplication?.processID == selfPID }
            return SCContentFilter(display: display, excludingWindows: ourWindows)
        }
    }

    /// The frontmost on-screen normal window of the user's current work app.
    ///
    /// `SCShareableContent.windows` is ordered front-to-back, so the first match is the frontmost.
    /// We match on the last-activated non-self app (falling back to the current frontmost non-self
    /// app), skip our own windows, and skip non-normal layers (menus, panels) and tiny helper windows.
    private func focusedWorkWindow(in content: SCShareableContent) -> SCWindow? {
        let targetPID = lastWorkAppPID ?? currentNonSelfFrontmostPID()
        guard let targetPID, targetPID != selfPID else { return nil }

        return content.windows.first { window in
            window.owningApplication?.processID == targetPID
                && window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width > 100 && window.frame.height > 100
        }
    }

    /// Pick the display to capture for `entireScreen`: the one hosting the work window if we can
    /// find it, otherwise the main display.
    private func displayForTarget(in content: SCShareableContent) -> SCDisplay? {
        if let window = focusedWorkWindow(in: content) {
            if let hosting = content.displays.first(where: { $0.frame.intersects(window.frame) }) {
                return hosting
            }
        }
        return content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
    }

    private func currentNonSelfFrontmostPID() -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != selfPID else { return nil }
        return front.processIdentifier
    }

    // MARK: - Output configuration

    /// Build a screenshot configuration downscaled so the longest edge is at most `maxPixelDimension`.
    private func makeConfiguration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        let scale = CGFloat(filter.pointPixelScale)
        let pixelSize = CGSize(
            width: filter.contentRect.width * scale,
            height: filter.contentRect.height * scale
        )
        let longest = max(pixelSize.width, pixelSize.height)
        let factor = longest > maxPixelDimension ? maxPixelDimension / longest : 1

        config.width = max(1, Int((pixelSize.width * factor).rounded()))
        config.height = max(1, Int((pixelSize.height * factor).rounded()))
        return config
    }

    // MARK: - Encoding

    private static func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
