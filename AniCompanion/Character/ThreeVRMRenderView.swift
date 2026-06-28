import SwiftUI
import WebKit

// MARK: - ThreeVRMRenderView

/// SwiftUI view that renders a VRM character via three-vrm in a WKWebView.
///
/// Loads `vrm_scene.html` from the app bundle, which sets up a Three.js + three-vrm
/// WebGL scene. The Swift side communicates with JavaScript through `evaluateJavaScript()`
/// calls on the `ThreeVRMCharacterManager` and receives events via `WKScriptMessageHandler`.
struct ThreeVRMRenderView: View {

    @ObservedObject var characterManager: ThreeVRMCharacterManager

    /// Camera coordinate display string, updated after each camera move.
    @State private var cameraInfo: String = "X:0.0  Y:0.9  Z:4.7  LookY:0.7"

    /// Whether the debug overlays are visible. Toggle with ` key.
    @State private var showDebugOverlay: Bool = false

    var body: some View {
        ZStack {
            // MARK: - Background

            RoundedRectangle(cornerRadius: 0)
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color(nsColor: NSColor(red: 0.15, green: 0.12, blue: 0.22, alpha: 1.0)),
                            Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1.0))
                        ]),
                        center: .center,
                        startRadius: 50,
                        endRadius: 400
                    )
                )

            // MARK: - WebView

            ThreeVRMWebView(characterManager: characterManager)

            // MARK: - Loading Overlay

            if !characterManager.isModelLoaded {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading character...")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            // MARK: - Debug Overlay (hidden by default, toggle with ` key)

            if showDebugOverlay {
                VStack {
                    cameraOverlay
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    Spacer()

                    debugOverlay
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
                .transition(.opacity)
            }
        }
        .focusable()
        // Camera controls
        .onKeyPress(.init("w")) { moveCamera("moveCameraUp"); return .handled }
        .onKeyPress(.init("s")) { moveCamera("moveCameraDown"); return .handled }
        .onKeyPress(.init("a")) { moveCamera("moveCameraLeft"); return .handled }
        .onKeyPress(.init("d")) { moveCamera("moveCameraRight"); return .handled }
        .onKeyPress(.init("q")) { moveCamera("moveCameraIn"); return .handled }
        .onKeyPress(.init("e")) { moveCamera("moveCameraOut"); return .handled }
        .onKeyPress(.init("r")) { moveCamera("cameraLookUp"); return .handled }
        .onKeyPress(.init("f")) { moveCamera("cameraLookDown"); return .handled }
        // Animation debug triggers
        .onKeyPress(.init("1")) { characterManager.playAnimation(named: "wave"); return .handled }
        .onKeyPress(.init("2")) { characterManager.playAnimation(named: "nod"); return .handled }
        .onKeyPress(.init("3")) { characterManager.playAnimation(named: "talk_gesture"); return .handled }
        .onKeyPress(.init("4")) { characterManager.playAnimation(named: "think"); return .handled }
        .onKeyPress(.init("5")) { characterManager.playAnimation(named: "idle"); return .handled }
        .onKeyPress(.init("0")) { characterManager.stopAnimation(); return .handled }
        // Toggle debug overlay
        .onKeyPress(.init("`")) { showDebugOverlay.toggle(); return .handled }
    }

    // MARK: - Camera Control

    private func moveCamera(_ jsFunction: String) {
        let js = "window.\(jsFunction)(); window.getCameraState();"
        characterManager.webView?.evaluateJavaScript(js) { result, error in
            if let jsonString = result as? String,
               let data = jsonString.data(using: .utf8),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let x = state["x"] as? Double,
               let y = state["y"] as? Double,
               let z = state["z"] as? Double,
               let lookAtY = state["lookAtY"] as? Double {
                Task { @MainActor in
                    cameraInfo = String(format: "X:%.1f  Y:%.1f  Z:%.1f  LookY:%.1f", x, y, z, lookAtY)
                }
            }
        }
    }

    // MARK: - Camera Overlay

    private var cameraOverlay: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Text(verbatim: "Camera")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.8))
                Text(cameraInfo)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
            }
            HStack {
                Text(verbatim: "W/S:up/down  A/D:left/right  Q/E:near/far  R/F:look up/down")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            }
            HStack {
                Text(verbatim: "1:wave  2:nod  3:talk  4:think  5:idle  0:stop")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.5))
        )
    }

    // MARK: - Debug Overlay

    private var debugOverlay: some View {
        VStack(spacing: 6) {
            // Mouth indicator
            HStack(spacing: 6) {
                Image(systemName: "mouth.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.pink.opacity(0.7))
                Text(verbatim: "Mouth")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", characterManager.mouthOpenValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.pink.opacity(0.6), .pink.opacity(0.9)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: max(0, geometry.size.width * CGFloat(characterManager.mouthOpenValue)),
                            height: 8
                        )
                        .animation(.linear(duration: 0.05), value: characterManager.mouthOpenValue)
                }
            }
            .frame(height: 8)

            // Emotion indicator
            HStack(spacing: 6) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 12))
                    .foregroundStyle(.yellow.opacity(0.7))
                Text(verbatim: "Emotion")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(characterManager.currentEmotion.displayName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Animation indicator
            HStack(spacing: 6) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 12))
                    .foregroundStyle(.green.opacity(0.7))
                Text(verbatim: "Anim")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(characterManager.currentClipName ?? "idle")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(characterManager.isModelLoaded ? .green : .red)
                    .frame(width: 6, height: 6)

                Text(verbatim: characterManager.isModelLoaded ? "VRM Model Loaded" : "No Model")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(verbatim: "three-vrm WebGL")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
    }
}

// MARK: - ThreeVRMWebView (NSViewRepresentable)

/// Wraps a WKWebView that hosts the three-vrm WebGL scene.
struct ThreeVRMWebView: NSViewRepresentable {

    @ObservedObject var characterManager: ThreeVRMCharacterManager

    func makeNSView(context: Context) -> WKWebView {
        // Configure WKWebView
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(characterManager, name: "bridge")
        config.userContentController = contentController

        // Allow file access for loading VRM model from bundle
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Transparent background so SwiftUI gradient shows through
        webView.setValue(false, forKey: "drawsBackground")

        // Enable Safari Web Inspector for debugging
        webView.isInspectable = true

        characterManager.webView = webView

        // Load the HTML file from the bundle
        if let htmlURL = Bundle.main.url(
            forResource: "vrm_scene",
            withExtension: "html",
            subdirectory: "ThreeVRM"
        ) {
            // Grant read access to the entire bundle so JS can load VRM model files
            let bundleResourceURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
            webView.loadFileURL(htmlURL, allowingReadAccessTo: bundleResourceURL)
        } else {
            Log.render("[ThreeVRM] vrm_scene.html not found in bundle")
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No dynamic updates needed — all communication is via evaluateJavaScript
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(characterManager: characterManager)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let characterManager: ThreeVRMCharacterManager

        init(characterManager: ThreeVRMCharacterManager) {
            self.characterManager = characterManager
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Log.render("[ThreeVRM] WebView finished loading HTML")
            // Small delay to ensure JS module has initialized
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.characterManager.onWebViewReady()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Log.render("[ThreeVRM] WebView navigation failed: \(error)")
        }
    }
}
