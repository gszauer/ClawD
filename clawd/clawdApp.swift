import SwiftUI

@main
struct clawdApp: App {
    init() {
        let state = AppState.shared
        if state.workingDirectory.isEmpty {
            state.workingDirectory = AppState.defaultWorkingDirectory
        }

        // Create working directory on first launch
        try? FileManager.default.createDirectory(
            atPath: state.workingDirectory, withIntermediateDirectories: true)

        // Auto-load config.json if it exists
        if FileManager.default.fileExists(atPath: state.configPath) {
            state.loadConfig()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 500)
        }
        .defaultSize(width: 900, height: 650)
    }
}
