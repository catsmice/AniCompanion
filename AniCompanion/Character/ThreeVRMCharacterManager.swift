import Foundation
import Combine
import WebKit

// MARK: - ThreeVRMCharacterManager

/// Bridges Swift commands to a three-vrm WebGL scene running in a WKWebView.
///
/// Implements `CharacterControllerProtocol` so the conversation pipeline can drive
/// expressions, lip sync, and skeletal animations.
/// All rendering happens in JavaScript; this class only sends commands and receives events.
@MainActor
final class ThreeVRMCharacterManager: NSObject, ObservableObject, CharacterControllerProtocol {

    // MARK: - Published State

    /// Whether a VRM model has been loaded and is ready for rendering.
    @Published private(set) var isModelLoaded: Bool = false

    /// The current emotion being displayed.
    @Published private(set) var currentEmotion: Emotion = .neutral

    /// Current mouth-open value (0.0-1.0) for debug display.
    @Published private(set) var mouthOpenValue: Float = 0.0

    /// Name of the currently playing animation clip (for debug overlay).
    @Published private(set) var currentClipName: String?

    // MARK: - WebView

    /// The WKWebView instance, set by ThreeVRMRenderView after creation.
    var webView: WKWebView?

    /// Whether the three-vrm HTML/JS scene has finished loading.
    private var isWebViewReady = false

    // MARK: - Animation Data

    /// Raw JSON data for each animation clip, keyed by name.
    /// Loaded from the bundle once at model load time; sent to JS on demand.
    private var animationClipData: [String: Data] = [:]

    /// Track which blend shape names were active for the previous emotion.
    private var activeEmotionNames: [String] = []

    // MARK: - Inactivity Timer

    /// Seconds of inactivity before auto-playing the idle animation clip.
    private static let inactivityTimeout: TimeInterval = 10.0

    /// Timer that fires after inactivity timeout.
    private var inactivityTimer: Timer?

    /// Reset the inactivity timer. Called on every interaction.
    private func resetInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = Timer.scheduledTimer(
            withTimeInterval: Self.inactivityTimeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onInactivityTimeout()
            }
        }
    }

    /// Called when the inactivity timer fires.
    private func onInactivityTimeout() {
        guard isModelLoaded else { return }
        // Only auto-play idle if nothing is currently playing
        guard currentClipName == nil else { return }
        Log.character("[ThreeVRM] Inactivity timeout — playing idle animation")
        playAnimation(named: "idle")
    }

    // MARK: - Lip Sync

    private static let smoothingFactor: Float = 0.3
    private static let silenceThreshold: Float = 0.05
    private static let amplitudeScale: Float = 2.0
    private var previousSmoothedMouth: Float = 0.0

    // MARK: - Model Loading

    /// Load a VRM model. Finds the VRM file in the bundle and tells JS to load it.
    /// Also preloads animation clip JSON data from the Animations folder.
    func loadModel(named filename: String) {
        Log.character("[ThreeVRM] Loading model: \(filename)")
        isModelLoaded = false

        // Preload animation clip data from the bundle.
        preloadAnimationData()

        // Store the filename for initial WebView startup and later settings changes.
        pendingModelFilename = filename
        loadPendingModelIfPossible()
    }

    /// The filename to load once the webView is ready.
    private var pendingModelFilename: String?

    /// Called by ThreeVRMRenderView once the HTML page has finished loading.
    func onWebViewReady() {
        isWebViewReady = true
        loadPendingModelIfPossible()
    }

    private func loadPendingModelIfPossible() {
        guard isWebViewReady else { return }
        guard webView != nil else { return }
        guard let filename = pendingModelFilename else { return }

        // Construct a file URL that the WKWebView can access.
        guard let url = Bundle.main.url(
            forResource: filename,
            withExtension: nil,
            subdirectory: "VRMModel"
        ) else {
            Log.character("[ThreeVRM] Model file not found in bundle: VRMModel/\(filename)")
            return
        }

        let urlString = url.absoluteString
        let js = "window.loadVRM('\(urlString)');"
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                Log.character("[ThreeVRM] JS loadVRM error: \(error)")
            }
        }
    }

    // MARK: - Animation Data Preloading

    private func preloadAnimationData() {
        guard let animationsURL = Bundle.main.url(
            forResource: "Animations",
            withExtension: nil
        ) else {
            Log.character("[ThreeVRM] Animations folder not found in bundle")
            return
        }

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: animationsURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }

            for fileURL in fileURLs {
                let data = try Data(contentsOf: fileURL)
                let name = fileURL.deletingPathExtension().lastPathComponent
                animationClipData[name] = data
            }
        } catch {
            Log.character("[ThreeVRM] Failed to load animation data: \(error)")
        }

        Log.character("[ThreeVRM] Preloaded \(animationClipData.count) animation clip(s)")
    }

    // MARK: - CharacterControllerProtocol

    func setExpression(_ emotion: Emotion, blendDuration: TimeInterval) {
        resetInactivityTimer()
        currentEmotion = emotion

        // Build expression mappings from the Emotion's blend shape names.
        let mappings = emotion.threeVRMExpressionMappings

        // JSON-encode and send to JS.
        guard let data = try? JSONSerialization.data(withJSONObject: mappings),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        let js = "window.setExpression(\(jsonString));"
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                Log.character("[ThreeVRM] setExpression error: \(error)")
            }
        }
    }

    func setMouthOpen(_ value: Float) {
        // Apply EMA smoothing.
        let thresholded = value < Self.silenceThreshold ? 0.0 : value
        let scaled = thresholded * Self.amplitudeScale
        let smoothed = previousSmoothedMouth * Self.smoothingFactor
                     + scaled * (1.0 - Self.smoothingFactor)
        previousSmoothedMouth = smoothed
        let clamped = min(max(smoothed, 0.0), 1.0)
        mouthOpenValue = clamped

        let js = "window.setMouthOpen(\(clamped));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func playIdleAnimation() {
        previousSmoothedMouth = 0.0
        mouthOpenValue = 0.0
        currentClipName = nil

        let js = "window.playIdleAnimation();"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func playAnimation(named name: String) {
        resetInactivityTimer()
        guard let data = animationClipData[name],
              let jsonString = String(data: data, encoding: .utf8) else {
            Log.character("[ThreeVRM] Animation clip not found: '\(name)'")
            return
        }

        currentClipName = name
        Log.character("[ThreeVRM] Playing animation: '\(name)'")

        let js = "window.playAnimation(\(jsonString));"
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                Log.character("[ThreeVRM] playAnimation error: \(error)")
            }
        }
    }

    func stopAnimation() {
        resetInactivityTimer()
        if currentClipName != nil {
            Log.character("[ThreeVRM] Stopping animation: '\(currentClipName ?? "")'")
            currentClipName = nil
        }

        let js = "window.stopAnimation();"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - WKScriptMessageHandler

extension ThreeVRMCharacterManager: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            handleBridgeMessage(message)
        }
    }

    private func handleBridgeMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let event = body["event"] as? String else { return }

        switch event {
        case "modelLoaded":
            let success = body["success"] as? Bool ?? false
            if success {
                isModelLoaded = true
                resetInactivityTimer()
                Log.character("[ThreeVRM] Model loaded successfully (via bridge)")
            } else {
                Log.character("[ThreeVRM] Model load failed (via bridge)")
            }

        case "animationEnded":
            let name = body["name"] as? String ?? ""
            currentClipName = nil
            resetInactivityTimer()
            Log.character("[ThreeVRM] Animation ended: '\(name)'")

        default:
            Log.character("[ThreeVRM] Unknown bridge event: \(event)")
        }
    }
}

// MARK: - Emotion Extension

extension Emotion {

    /// Expression mappings for three-vrm: array of {name, value} dictionaries.
    ///
    /// These use the standard VRM expression presets that three-vrm normalizes from
    /// any VRM 0.x / 1.0 model (`happy`, `angry`, `sad`, `relaxed`, plus `neutral`).
    /// The default model (Alicia Solid) only ships these four emotion presets — it has
    /// no `surprised` expression — so the 16 emotions are bucketed onto them. Swap in a
    /// model with richer expressions and you can give each emotion a distinct preset.
    var threeVRMExpressionMappings: [[String: Any]] {
        switch self {
        case .neutral:    return []
        case .happy:      return [["name": "happy", "value": 1.0]]
        case .sad:        return [["name": "sad", "value": 1.0]]
        case .angry:      return [["name": "angry", "value": 1.0]]
        case .surprised:  return [["name": "happy", "value": 1.0]]
        case .curious:    return [["name": "relaxed", "value": 1.0]]
        case .excited:    return [["name": "happy", "value": 1.0]]
        case .shy:        return [["name": "relaxed", "value": 1.0]]
        case .love:       return [["name": "happy", "value": 1.0]]
        case .smirk:      return [["name": "relaxed", "value": 1.0]]
        case .sleepy:     return [["name": "relaxed", "value": 1.0]]
        case .proud:      return [["name": "happy", "value": 1.0]]
        case .disgusted:  return [["name": "angry", "value": 1.0]]
        case .pain:       return [["name": "sad", "value": 1.0]]
        case .laugh:      return [["name": "happy", "value": 1.0]]
        case .bored:      return [["name": "relaxed", "value": 1.0]]
        }
    }
}
