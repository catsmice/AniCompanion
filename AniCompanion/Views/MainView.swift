import SwiftUI

// MARK: - MainView

/// The root container view for AniCompanion.
///
/// Arranges the VRM 3D character display on the left (~60% width) and the chat
/// interface on the right (~40% width) in a horizontal layout with a dark gradient
/// background. Reads `AppState` from the environment and passes dependencies
/// down to child views.
struct MainView: View {

    @EnvironmentObject private var appState: AppState

    /// Whether the settings sheet is presented.
    @State private var showSettings: Bool = false

    var body: some View {
        NavigationStack {
        HStack(spacing: 0) {
            // MARK: - Left: VRM Character Display

            ThreeVRMRenderView(
                characterManager: appState.characterManager
            )
                .frame(minWidth: 400)
                .layoutPriority(1)

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
        .preferredColorScheme(.dark)
        } // NavigationStack
    }
}

// MARK: - Preview

#Preview {
    MainView()
        .environmentObject(
            AppState()
        )
}
