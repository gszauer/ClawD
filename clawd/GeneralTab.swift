import SwiftUI
import UniformTypeIdentifiers

struct GeneralTab: View {
    @Bindable private var state = AppState.shared
    @Bindable private var core = CoreBridge.shared
    @Bindable private var discord = DiscordService.shared
    @State private var statusMessage = ""
    @State private var isDownloadingModel = false
    @State private var isDownloadingWhisper = false
    @State private var whisperDownloadLabel = ""

    private let backends = ["claude", "gemini", "codex", "API"]
    private let embeddingModes = ["API", "local", "off"]
    private let audioBackends = ["whisper", "off"]

    private var calendarJsonExists: Bool {
        FileManager.default.fileExists(atPath: "\(state.workingDirectory)/calendar.json")
    }

    private static let defaultPaths: [String: String] = [
        "claude": "/Users/user/.local/bin/claude",
        "gemini": "/opt/homebrew/bin/gemini",
        "codex": "/opt/homebrew/bin/codex",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // --- Status & Controls ---
                GroupBox("Status") {
                    HStack {
                        Circle()
                            .fill(core.isRunning ? .green : .red)
                            .frame(width: 10, height: 10)
                        Text(core.isRunning ? "Running" : "Stopped")

                        if discord.isConnected {
                            Text("  |  Discord: Connected")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(core.isRunning ? "Stop" : "Start") {
                            toggleCore()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(core.isRunning ? .red : .green)
                    }
                    .padding(.vertical, 4)

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // --- Paths ---
                GroupBox("Paths") {
                    LabeledContent("Working Directory") {
                        HStack {
                            TextField("./working", text: $state.workingDirectory)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") { browseDirectory() }
                        }
                    }
                }

                // --- Backend ---
                GroupBox("Backend") {
                    HStack {
                        Text("Backend")
                        Picker("", selection: $state.backend) {
                            ForEach(backends, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 300)
                        .onChange(of: state.backend) { _, newValue in
                            if let path = Self.defaultPaths[newValue] {
                                state.backendCliPath = path
                            }
                        }

                        Spacer()

                        Text("Embedding")
                        Picker("", selection: $state.embeddingMode) {
                            ForEach(embeddingModes, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 150)

                        Spacer()

                        Text("Audio")
                        Picker("", selection: $state.audioBackend) {
                            ForEach(audioBackends, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 150)
                    }

                    if state.backend == "API" {
                        LabeledContent("API URL") {
                            TextField("http://localhost:1234/v1/chat/completions",
                                      text: $state.backendApiUrl)
                            .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("API Key") {
                            SecureField("sk-... (optional for local)", text: $state.backendApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Model") {
                            TextField("model name", text: $state.backendApiModel)
                                .textFieldStyle(.roundedBorder)
                        }
                    } else {
                        LabeledContent("CLI Path") {
                            HStack {
                                TextField("/usr/local/bin/claude", text: $state.backendCliPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Test") { testBackendCli() }
                            }
                        }
                    }

                    if state.embeddingMode == "API" {
                        LabeledContent("Embedding URL") {
                            TextField("http://localhost:1234/v1/embeddings",
                                      text: $state.embeddingUrl)
                            .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Embedding Model") {
                            TextField("text-embedding-nomic-embed-text-v1.5",
                                      text: $state.embeddingModel)
                            .textFieldStyle(.roundedBorder)
                        }
                    } else if state.embeddingMode == "local" {
                        LabeledContent("Embedding Model") {
                            HStack {
                                TextField("Path to .gguf file", text: $state.embeddingModelPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse...") { browseGgufModel() }
                                Button("Download") { downloadEmbeddingModel() }
                                    .disabled(isDownloadingModel)
                            }
                        }
                        if isDownloadingModel {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Downloading nomic-embed-text-v1.5.f16.gguf (262 MB)...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if state.audioBackend == "whisper" {
                        LabeledContent("Whisper Model") {
                            HStack {
                                TextField("Path to whisper model", text: $state.whisperModelPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse...") { browseWhisperModel() }
                                Button("Base") { downloadWhisperModel(size: "base") }
                                    .disabled(isDownloadingWhisper)
                                Button("Small") { downloadWhisperModel(size: "small") }
                                    .disabled(isDownloadingWhisper)
                            }
                        }
                        if isDownloadingWhisper {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text(whisperDownloadLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // --- Discord ---
                GroupBox("Discord") {
                    LabeledContent("Bot Token") {
                        SecureField("Bot token", text: $state.discordBotToken)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Channel ID") {
                        TextField("Numeric ID (right-click channel > Copy ID)", text: $state.discordChannelId)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Assistant Name") {
                        HStack {
                            TextField("ClawD", text: $state.assistantName)
                                .textFieldStyle(.roundedBorder)
                            Spacer()
                            Text("Reaction")
                                .foregroundStyle(.secondary)
                            TextField("🦀", text: $state.assistantEmoji)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                        }
                    }
                }

                // --- Calendar ---
                GroupBox("Calendar") {
                    LabeledContent("Service Account") {
                        HStack {
                            if calendarJsonExists {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("calendar.json loaded")
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                                Text("No calendar.json")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Browse...") { browseServiceAccount() }
                        }
                    }

                    LabeledContent("Your Calendar ID") {
                        TextField("your.email@gmail.com", text: $state.calendarId)
                            .textFieldStyle(.roundedBorder)
                    }

                    if !CalendarAuth.shared.serviceAccountEmail.isEmpty {
                        LabeledContent("Account Email") {
                            HStack {
                                Text(CalendarAuth.shared.serviceAccountEmail)
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }

                    HStack {
                        Text("Sync Interval")
                        Spacer()
                        Stepper("\(state.calendarSyncInterval) min",
                                value: $state.calendarSyncInterval, in: 5...120, step: 5)
                    }
                }

                // --- Notifications ---
                GroupBox("Notifications") {
                    notificationRow("Daily Report", enabled: $state.dailyReportEnabled,
                                    time: $state.dailyReportTime)
                    notificationRow("Meal Prep Reminder", enabled: $state.mealPrepEnabled,
                                    time: $state.mealPrepTime)
                    notificationRow("Overdue Chores", enabled: $state.overdueChoresEnabled,
                                    time: $state.overdueChoresTime)
                    notificationRow("End of Day Summary", enabled: $state.endOfDayEnabled,
                                    time: $state.endOfDayTime)

                    HStack {
                        Toggle("Calendar Heads-Up", isOn: $state.calendarHeadsUpEnabled)
                        Spacer()
                        Stepper("\(state.calendarHeadsUpMinutes) min before",
                                value: $state.calendarHeadsUpMinutes, in: 5...120, step: 5)
                    }

                }

                // --- Advanced ---
                GroupBox("Advanced") {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Chat History")
                            Spacer()
                            Stepper("\(state.chatHistoryExchanges) exchanges",
                                    value: $state.chatHistoryExchanges, in: 5...100, step: 5)
                        }
                        HStack {
                            Text("Heartbeat Interval")
                            Spacer()
                            Stepper("\(state.heartbeatIntervalSeconds)s",
                                    value: $state.heartbeatIntervalSeconds, in: 10...120, step: 5)
                        }
                        HStack {
                            Text("Note Search Results")
                            Spacer()
                            Stepper("\(state.noteSearchResults) results",
                                    value: $state.noteSearchResults, in: 1...20)
                        }
                        HStack {
                            Text("Max Notes in Index")
                            Spacer()
                            Stepper("\(state.maxNotesInIndex)",
                                    value: $state.maxNotesInIndex, in: 1000...100000, step: 1000)
                        }
                    }
                }

                // --- Save ---
                HStack {
                    Spacer()
                    Button("Save Config") {
                        state.saveConfig()
                        statusMessage = "Config saved."
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    private func notificationRow(_ label: String, enabled: Binding<Bool>, time: Binding<Date>) -> some View {
        HStack {
            Toggle(label, isOn: enabled)
            Spacer()
            DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .disabled(!enabled.wrappedValue)
        }
    }

    private func toggleCore() {
        if core.isRunning {
            discord.disconnect()
            core.stop()
            statusMessage = "Stopped."
        } else {
            // Use absolute defaults if fields are empty
            if state.workingDirectory.isEmpty {
                state.workingDirectory = AppState.defaultWorkingDirectory
            }
            let wd = state.workingDirectory

            // Ensure working directory exists
            try? FileManager.default.createDirectory(
                atPath: wd, withIntermediateDirectories: true)

            state.saveConfig()
            core.start(configPath: state.configPath, workingDir: wd)
            print("[clawd] Working directory: \(wd)")
            print("[clawd] Config path: \(state.configPath)")
            state.refreshData()

            // Check embedding endpoint (only for remote mode)
            if state.embeddingMode == "API" {
                checkEmbeddingHealth()
            }

            // Connect Discord if token is set
            if !state.discordBotToken.isEmpty {
                discord.connect(token: state.discordBotToken, channelId: state.discordChannelId)
            }
            statusMessage = "Running."
        }
    }

    private func testBackendCli() {
        let path = state.backendCliPath
        guard !path.isEmpty else {
            AppState.shared.showToast("No CLI path set", isError: true)
            return
        }
        if FileManager.default.isExecutableFile(atPath: path) {
            AppState.shared.showToast("\(state.backend) found at \(path)")
        } else if FileManager.default.fileExists(atPath: path) {
            AppState.shared.showToast("\(path) exists but is not executable", isError: true)
        } else {
            AppState.shared.showToast("\(state.backend) not found at \(path)", isError: true)
        }
    }

    private func checkEmbeddingHealth() {
        let url = state.embeddingUrl.isEmpty ? "http://localhost:1234/v1/embeddings" : state.embeddingUrl
        let model = state.embeddingModel.isEmpty ? "text-embedding-embeddinggemma-300m" : state.embeddingModel

        guard let requestUrl = URL(string: url) else {
            AppState.shared.showToast("Embedding: invalid URL", isError: true)
            return
        }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        let body: [String: Any] = ["model": model, "input": "health check"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                AppState.shared.showToast("Embedding server unreachable: \(error.localizedDescription)", isError: true)
            } else if status != 200 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if body.contains("No models loaded") {
                    AppState.shared.showToast("Embedding: no model loaded in LM Studio", isError: true)
                } else {
                    AppState.shared.showToast("Embedding: server error (status \(status))", isError: true)
                }
            }
        }.resume()
    }

    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.workingDirectory = url.path
            // Auto-load config if it exists in the new directory
            if FileManager.default.fileExists(atPath: state.configPath) {
                state.loadConfig()
                AppState.shared.showToast("Config loaded from new directory")
            }
        }
    }

    private func browseGgufModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.message = "Select a GGUF embedding model"
        if panel.runModal() == .OK, let url = panel.url {
            state.embeddingModelPath = url.path
        }
    }

    private func downloadEmbeddingModel() {
        guard let url = URL(string: "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.f16.gguf") else { return }
        let destPath = "\(state.workingDirectory)/nomic-embed-text-v1.5.f16.gguf"

        // Skip if already downloaded
        if FileManager.default.fileExists(atPath: destPath) {
            state.embeddingModelPath = destPath
            AppState.shared.showToast("Model already exists — path set")
            return
        }

        isDownloadingModel = true
        let task = URLSession.shared.downloadTask(with: url) { tempUrl, response, error in
            DispatchQueue.main.async {
                isDownloadingModel = false
                if let error {
                    AppState.shared.showToast("Download failed: \(error.localizedDescription)", isError: true)
                    return
                }
                guard let tempUrl else { return }
                let dest = URL(fileURLWithPath: destPath)
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempUrl, to: dest)
                    state.embeddingModelPath = destPath
                    AppState.shared.showToast("Model downloaded to working directory")
                } catch {
                    AppState.shared.showToast("Failed to save model: \(error.localizedDescription)", isError: true)
                }
            }
        }
        task.resume()
    }

    private func browseWhisperModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.message = "Select a Whisper model file"
        if panel.runModal() == .OK, let url = panel.url {
            state.whisperModelPath = url.path
        }
    }

    private func downloadWhisperModel(size: String) {
        let remoteFile = "ggml-\(size).en.bin"
        let localFile = "whisper-ggml-\(size).en.bin"
        guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(remoteFile)") else { return }
        let destPath = "\(state.workingDirectory)/\(localFile)"

        if FileManager.default.fileExists(atPath: destPath) {
            state.whisperModelPath = destPath
            AppState.shared.showToast("Model already exists — path set")
            return
        }

        let sizeLabel = size == "base" ? "142 MB" : "466 MB"
        whisperDownloadLabel = "Downloading \(localFile) (\(sizeLabel))..."
        isDownloadingWhisper = true
        let task = URLSession.shared.downloadTask(with: url) { tempUrl, response, error in
            DispatchQueue.main.async {
                isDownloadingWhisper = false
                if let error {
                    AppState.shared.showToast("Download failed: \(error.localizedDescription)", isError: true)
                    return
                }
                guard let tempUrl else { return }
                let dest = URL(fileURLWithPath: destPath)
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempUrl, to: dest)
                    state.whisperModelPath = destPath
                    AppState.shared.showToast("Whisper \(size) model downloaded")
                } catch {
                    AppState.shared.showToast("Failed to save model: \(error.localizedDescription)", isError: true)
                }
            }
        }
        task.resume()
    }

    private func browseServiceAccount() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            // Copy to working/calendar.json
            let dest = "\(state.workingDirectory)/calendar.json"
            try? FileManager.default.removeItem(atPath: dest)
            do {
                try FileManager.default.copyItem(atPath: url.path, toPath: dest)
                if CalendarAuth.shared.load(from: dest) {
                    AppState.shared.showToast("Loaded: \(CalendarAuth.shared.serviceAccountEmail)")
                } else {
                    AppState.shared.showToast("Failed to parse service account JSON", isError: true)
                }
            } catch {
                AppState.shared.showToast("Failed to copy: \(error.localizedDescription)", isError: true)
            }
        }
    }
}
