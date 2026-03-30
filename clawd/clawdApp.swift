import SwiftUI

@main
struct clawdApp: App {
    init() {
        let state = AppState.shared
        if state.workingDirectory.isEmpty {
            state.workingDirectory = AppState.defaultWorkingDirectory
        }
        if state.configPath.isEmpty {
            state.configPath = "\(state.workingDirectory)/config.json"
        }

        // Auto-load config.json if it exists
        let cfgPath = state.configPath
        if FileManager.default.fileExists(atPath: cfgPath) {
            state.loadConfig(from: cfgPath)
            // Restore working directory if config didn't have one
            if state.workingDirectory.isEmpty {
                state.workingDirectory = AppState.defaultWorkingDirectory
            }
            if state.configPath.isEmpty {
                state.configPath = cfgPath
            }
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
