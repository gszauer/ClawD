import SwiftUI
import UniformTypeIdentifiers

struct GeneralTab: View {
    @Bindable private var state = AppState.shared
    @Bindable private var core = CoreBridge.shared
    @Bindable private var discord = DiscordService.shared
    @State private var statusMessage = ""

    private let backends = ["claude", "gemini", "codex", "local"]

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
                    LabeledContent("Config File") {
                        HStack {
                            TextField("config.json", text: $state.configPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Load") { loadConfig() }
                        }
                    }
                }

                // --- Backend ---
                GroupBox("Backend") {
                    LabeledContent("Backend") {
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
                    }

                    if state.backend == "local" {
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
                        Text("Share your Google Calendar with this email to grant access.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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
            let cfg = state.configPath.isEmpty ? "\(wd)/config.json" : state.configPath
            state.configPath = cfg

            // Ensure working directory exists
            try? FileManager.default.createDirectory(
                atPath: wd, withIntermediateDirectories: true)

            state.saveConfig()
            core.start(configPath: cfg, workingDir: wd)
            print("[clawd] Working directory: \(wd)")
            print("[clawd] Config path: \(cfg)")
            state.refreshData()

            // Check embedding endpoint
            checkEmbeddingHealth()

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

    private func loadConfig() {
        let path = state.configPath.isEmpty ? "config.json" : state.configPath
        state.loadConfig(from: path)
        statusMessage = "Config loaded from \(path)"
    }

    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.workingDirectory = url.path
        }
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
