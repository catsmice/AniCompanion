import SwiftUI

// MARK: - MainView

/// The windowed UI: the VRM 3D character on the left (~60% width) and the chat interface on
/// the right (~40% width). Desktop Pet mode is handled entirely in AppKit (`AppDelegate`):
/// it swaps the window to a borderless transparent panel showing the bare WebView, so this
/// view is only ever shown in the normal window. The 🐾 toolbar button (and ⌘⇧D) flips
/// `appState.petMode`, which `AppDelegate` observes.
struct MainView: View {

    @EnvironmentObject private var appState: AppState

    /// Whether the settings sheet is presented.
    @State private var showSettings: Bool = false

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                // MARK: - Left: VRM Character Display
                ThreeVRMRenderView(characterManager: appState.characterManager)
                    .frame(minWidth: 400)
                    .layoutPriority(1)
                    .overlay(alignment: .bottom) {
                        LiveCaptionOverlay(controller: appState.liveTranscription)
                    }

                Divider()
                    .background(Color.white.opacity(0.1))

                // MARK: - Right: Chat Interface
                if let controller = appState.conversationController {
                    ChatView(
                        conversationController: controller,
                        conversationHistory: appState.conversationHistory
                    )
                    .frame(minWidth: 300, idealWidth: 360)
                } else {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Initializing...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 300, idealWidth: 360)
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)),
                        Color(nsColor: NSColor(red: 0.12, green: 0.10, blue: 0.18, alpha: 1.0)),
                        Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1.0))
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        appState.petMode.toggle()
                    } label: {
                        Image(systemName: "pawprint.fill")
                    }
                    .help("Desktop Pet Mode (⌘⇧D)")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .overlay(alignment: .topTrailing) {
                                Circle()
                                    .fill(appState.isConnected ? Color.green : Color.red)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 2, y: -2)
                            }
                    }
                    .help(appState.isConnected ? "Connected — Settings" : "Disconnected — Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(appState)
            }
            .navigationTitle(Text("AI Agent | Xiaoguang", comment: "Window title — character name"))
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - LiveCaptionOverlay

/// Caption bar over the character while live transcription runs: a persistent "listening to
/// your Mac's audio" indicator (privacy — system audio is being captured) plus the rolling
/// caption. In pet mode the captions render in the speech bubble instead.
private struct LiveCaptionOverlay: View {

    @ObservedObject var controller: LiveTranscriptionController

    var body: some View {
        // Visible for every enabled state — running, still downloading the model (isRunning is
        // false until the one-time download completes), or failed — so the feature is never
        // silently "on but showing nothing."
        if controller.isEnabled {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    if controller.lastError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.yellow.opacity(0.9))
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    if let error = controller.lastError {
                        Text(error.localizedDescription)
                            .font(.system(size: 10, weight: .medium))
                    } else if let progress = controller.modelDownloadProgress {
                        Text("Downloading speech model… \(Int(progress * 100))%")
                            .font(.system(size: 10, weight: .medium))
                    } else if controller.isRunning {
                        Text("Listening to your Mac's audio")
                            .font(.system(size: 10, weight: .medium))
                    } else {
                        Text("Starting live captions…")
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)

                if !controller.captionText.isEmpty || (controller.isTranslating && !controller.originalText.isEmpty) {
                    VStack(spacing: 3) {
                        // Translate mode: the live original runs in a smaller dimmed line while
                        // each finished sentence lands below as the translated caption.
                        if controller.isTranslating && !controller.originalText.isEmpty {
                            Text(controller.originalText)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.55))
                                .multilineTextAlignment(.center)
                        }
                        if !controller.captionText.isEmpty {
                            Text(controller.captionText)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.6))
                    )
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 18)
            .animation(.easeInOut(duration: 0.18), value: controller.captionText.isEmpty)
        }
    }
}

// MARK: - Preview

#Preview {
    MainView()
        .environmentObject(AppState())
}
