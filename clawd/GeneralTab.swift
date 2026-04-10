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
    @State private var showAdvanced = false

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
            VStack(spacing: 20) {

                // ── Status Banner ──
                statusBanner

                // ── Working Directory ──
                card("Working Directory") {
                    fieldRow("Path", text: $state.workingDirectory, placeholder: "./working",
                             trailing: { Button("Browse...") { browseDirectory() }.buttonStyle(.bordered).controlSize(.small) })
                }

                // ── AI & Models ──
                card("AI & Models") {
                    // Picker row
                    HStack(spacing: 16) {
                        pickerGroup("Backend", selection: $state.backend, options: backends, maxWidth: 280)
                            .onChange(of: state.backend) { _, newValue in
                                if let path = Self.defaultPaths[newValue] {
                                    state.backendCliPath = path
                                }
                            }
                        Spacer()
                        pickerGroup("Embedding", selection: $state.embeddingMode, options: embeddingModes, maxWidth: 150)
                        Spacer()
                        pickerGroup("Audio", selection: $state.audioBackend, options: audioBackends, maxWidth: 130)
                    }

                    Divider().padding(.vertical, 4)

                    // Backend config
                    if state.backend == "API" {
                        fieldRow("API URL", text: $state.backendApiUrl, placeholder: "http://localhost:1234/v1/chat/completions")
                        fieldRow("API Key", secure: true, text: $state.backendApiKey, placeholder: "sk-...")
                        fieldRow("Model", text: $state.backendApiModel, placeholder: "model name")
                    } else {
                        HStack {
                            fieldRow("CLI Path", text: $state.backendCliPath, placeholder: "/usr/local/bin/claude")
                            Button("Test") { testBackendCli() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }

                    // Embedding config
                    if state.embeddingMode == "API" {
                        fieldRow("Embedding URL", text: $state.embeddingUrl, placeholder: "http://localhost:1234/v1/embeddings")
                        fieldRow("Embedding Model", text: $state.embeddingModel, placeholder: "text-embedding-nomic-embed-text-v1.5")
                    } else if state.embeddingMode == "local" {
                        modelRow("Embedding Model", path: $state.embeddingModelPath, placeholder: "Path to .gguf file",
                                 browse: browseGgufModel) {
                            Button("Download") { downloadEmbeddingModel() }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(isDownloadingModel)
                        }
                        downloadProgress(isDownloadingModel, "Downloading nomic-embed-text-v1.5.f16.gguf (262 MB)...")
                    }

                    // Whisper config
                    if state.audioBackend == "whisper" {
                        modelRow("Whisper Model", path: $state.whisperModelPath, placeholder: "Path to whisper model",
                                 browse: browseWhisperModel) {
                            Button("Base") { downloadWhisperModel(size: "base") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(isDownloadingWhisper)
                            Button("Small") { downloadWhisperModel(size: "small") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(isDownloadingWhisper)
                        }
                        downloadProgress(isDownloadingWhisper, whisperDownloadLabel)
                    }
                }

                // ── Two-column: Discord + Calendar ──
                HStack(alignment: .top, spacing: 16) {

                    // Discord
                    card("Discord") {
                        HStack(spacing: 6) {
                            Circle().fill(discord.isConnected ? .green : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                            Text(discord.isConnected ? "Connected" : "Not connected")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        fieldRow("Bot Token", secure: true, text: $state.discordBotToken, placeholder: "Bot token")
                        fieldRow("Channel ID", text: $state.discordChannelId, placeholder: "Right-click channel > Copy ID")
                        HStack(spacing: 8) {
                            fieldRow("Name", text: $state.assistantName, placeholder: "ClawD")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Emoji").font(.caption).foregroundStyle(.secondary)
                                TextField("", text: $state.assistantEmoji)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 44)
                            }
                        }
                    }

                    // Calendar
                    card("Calendar") {
                        HStack(spacing: 6) {
                            Image(systemName: calendarJsonExists ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(calendarJsonExists ? .green : .secondary)
                                .font(.caption)
                            Text(calendarJsonExists ? "Service account loaded" : "No service account")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Browse...") { browseServiceAccount() }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                        fieldRow("Calendar ID", text: $state.calendarId, placeholder: "your.email@gmail.com")
                        if !CalendarAuth.shared.serviceAccountEmail.isEmpty {
                            HStack {
                                Text("Account").font(.caption).foregroundStyle(.secondary)
                                Text(CalendarAuth.shared.serviceAccountEmail)
                                    .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                                Spacer()
                            }
                        }
                        HStack {
                            Text("Sync every").font(.caption).foregroundStyle(.secondary)
                            Stepper("\(state.calendarSyncInterval) min",
                                    value: $state.calendarSyncInterval, in: 5...120, step: 5)
                                .font(.caption)
                        }
                    }
                }

                // ── Notifications ──
                card("Notifications") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        notifCard("Daily Report", icon: "sun.max", enabled: $state.dailyReportEnabled, time: $state.dailyReportTime)
                        notifCard("Meal Prep", icon: "fork.knife", enabled: $state.mealPrepEnabled, time: $state.mealPrepTime)
                        notifCard("Overdue Chores", icon: "exclamationmark.circle", enabled: $state.overdueChoresEnabled, time: $state.overdueChoresTime)
                        notifCard("End of Day", icon: "moon.stars", enabled: $state.endOfDayEnabled, time: $state.endOfDayTime)
                        notifCardStepper("Calendar", icon: "calendar.badge.clock", enabled: $state.calendarHeadsUpEnabled,
                                         value: $state.calendarHeadsUpMinutes, range: 5...120, step: 5, unit: "min")
                    }
                }

                // ── Advanced (collapsible) ──
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
                    } label: {
                        HStack {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                                .font(.caption)
                            Text("Advanced").font(.callout).fontWeight(.medium)
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    if showAdvanced {
                        VStack(spacing: 8) {
                            stepperRow("Chat History", value: $state.chatHistoryExchanges, range: 5...100, step: 5, unit: "exchanges")
                            stepperRow("Heartbeat", value: $state.heartbeatIntervalSeconds, range: 10...120, step: 5, unit: "seconds")
                            stepperRow("Note Results", value: $state.noteSearchResults, range: 1...20, step: 1, unit: "results")
                            stepperRow("Max Notes", value: $state.maxNotesInIndex, range: 1000...100000, step: 1000, unit: "")
                        }
                        .padding(16)
                        .background(Color(.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(10)
                        .padding(.horizontal, 1)
                    }
                }

                // ── Save ──
                HStack {
                    Spacer()
                    Button {
                        state.saveConfig()
                        statusMessage = "Config saved."
                    } label: {
                        Label("Save Config", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Status Banner

    private var statusBanner: some View {
        HStack(spacing: 16) {
            // Power button
            Button {
                toggleCore()
            } label: {
                Image(systemName: core.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(core.isRunning ? .red : .green)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(core.isRunning ? "Running" : "Stopped")
                    .font(.title3).fontWeight(.semibold)
                HStack(spacing: 12) {
                    statusPill("Core", active: core.isRunning)
                    statusPill("Discord", active: discord.isConnected)
                    statusPill(state.backend, active: core.isRunning, color: .blue)
                    if state.embeddingMode != "off" {
                        statusPill("Embedding", active: core.isRunning, color: .purple)
                    }
                    if state.audioBackend != "off" {
                        statusPill("Whisper", active: core.isRunning, color: .orange)
                    }
                }
            }

            Spacer()

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(core.isRunning
                      ? Color.green.opacity(0.08)
                      : Color(.controlBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - Reusable Components

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.controlBackgroundColor).opacity(0.5)))
    }

    private func pickerGroup(_ label: String, selection: Binding<String>, options: [String], maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: maxWidth)
        }
    }

    private func fieldRow(_ label: String, secure: Bool = false, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if secure {
                SecureField(placeholder, text: text).textFieldStyle(.roundedBorder)
            } else {
                TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func fieldRow<Trailing: View>(_ label: String, text: Binding<String>, placeholder: String,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
                trailing()
            }
        }
    }

    private func modelRow<Buttons: View>(_ label: String, path: Binding<String>, placeholder: String,
                                          browse: @escaping () -> Void, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(placeholder, text: path).textFieldStyle(.roundedBorder)
                Button("Browse...") { browse() }
                    .buttonStyle(.bordered).controlSize(.small)
                buttons()
            }
        }
    }

    @ViewBuilder
    private func downloadProgress(_ active: Bool, _ label: String) -> some View {
        if active {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func statusPill(_ label: String, active: Bool, color: Color = .green) -> some View {
        Text(label)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                Capsule().fill(active ? color.opacity(0.15) : Color.secondary.opacity(0.1))
            )
            .foregroundStyle(active ? color : .secondary)
    }

    private func stepperRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Stepper("\(value.wrappedValue) \(unit)", value: value, in: range, step: step)
                .font(.callout)
        }
    }

    private func notifCard(_ label: String, icon: String, enabled: Binding<Bool>, time: Binding<Date>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(enabled.wrappedValue ? .primary : .secondary)
                .frame(width: 20)
            Toggle(label, isOn: enabled)
                .font(.callout)
            Spacer()
            DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!enabled.wrappedValue)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            enabled.wrappedValue ? Color.accentColor.opacity(0.06) : Color.clear
        ))
    }

    private func notifCardStepper(_ label: String, icon: String, enabled: Binding<Bool>,
                                   value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(enabled.wrappedValue ? .primary : .secondary)
                .frame(width: 20)
            Toggle(label, isOn: enabled)
                .font(.callout)
            Spacer()
            Stepper("\(value.wrappedValue) \(unit)", value: value, in: range, step: step)
                .font(.caption)
                .disabled(!enabled.wrappedValue)
                .scaleEffect(0.85, anchor: .trailing)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            enabled.wrappedValue ? Color.accentColor.opacity(0.06) : Color.clear
        ))
    }

    // MARK: - Actions

    private func toggleCore() {
        if core.isRunning {
            discord.disconnect()
            core.stop()
            statusMessage = "Stopped."
        } else {
            if state.workingDirectory.isEmpty {
                state.workingDirectory = AppState.defaultWorkingDirectory
            }
            let wd = state.workingDirectory

            try? FileManager.default.createDirectory(
                atPath: wd, withIntermediateDirectories: true)

            state.saveConfig()
            core.start(configPath: state.configPath, workingDir: wd)
            print("[clawd] Working directory: \(wd)")
            print("[clawd] Config path: \(state.configPath)")
            state.refreshData()

            if state.embeddingMode == "API" {
                checkEmbeddingHealth()
            }

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
