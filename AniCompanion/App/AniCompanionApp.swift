import SwiftUI

@main
struct AniCompanionApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .onAppear { appState.initializeServices() }
        }
        .defaultSize(width: 1000, height: 650)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
