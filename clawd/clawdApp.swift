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

        // Clear and recreate tmp directory
        let tmpDir = state.tmpDirectory
        try? FileManager.default.removeItem(atPath: tmpDir)
        try? FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)

        // Auto-load config.json if it exists
        if FileManager.default.fileExists(atPath: state.configPath) {
            state.loadConfig()
        }
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("ClawD", id: "main") {
            ContentView()
                .frame(minWidth: 700, minHeight: 500)
        }
        .defaultSize(width: 900, height: 650)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Shut down the core before exit so llama.cpp's Metal residency sets
        // are freed cleanly — prevents a crash in ggml_metal_device_free.
        CoreBridge.shared.stop()
    }
}
