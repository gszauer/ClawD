import SwiftUI
import UniformTypeIdentifiers

struct GeneralTab: View {
    @Bindable private var state = AppState.shared
    @Bindable private var core = CoreBridge.shared
    @Bindable private var discord = DiscordService.shared
    @State private var isDownloadingGemma = false
    @State private var gemmaDownloadLabel = ""
    @State private var isDownloadingWhisper = false
    @State private var whisperDownloadLabel = ""
    @State private var showAdvanced = false

    private var calendarJsonExists: Bool {
        FileManager.default.fileExists(atPath: "\(state.workingDirectory)/calendar.json")
    }

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

                // ── Two-column: Gemma + Audio ──
                HStack(alignment: .top, spacing: 16) {
                    card("Gemma") {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Model").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $state.gemmaModelPath) {
                                Text("None").tag("")
                                ForEach(state.availableGemmaModels, id: \.self) { file in
                                    Text(gemmaDisplayName(file)).tag(file)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: state.gemmaModelPath) { _, newVal in
                                state.gemmaMmprojPath = matchingMmproj(for: newVal)
                            }
                        }
                        HStack(spacing: 6) {
                            Text("Download:").font(.caption).foregroundStyle(.secondary)
                            Button("2B") { downloadGemma(size: "e2b") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(isDownloadingGemma || state.availableGemmaModels.contains("gemma-4-E2B-it-Q4_K_M.gguf"))
                            Button("4B") { downloadGemma(size: "e4b") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(isDownloadingGemma || state.availableGemmaModels.contains("gemma-4-E4B-it-Q4_K_M.gguf"))
                            Button("26B") { downloadGemma(size: "26b-a4b") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(isDownloadingGemma || state.availableGemmaModels.contains("gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"))
                            Button("Q3.5 9B") { downloadGemma(size: "qwen-9b") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(isDownloadingGemma || state.availableGemmaModels.contains("Qwen3.5-9B-Q4_K_M.gguf"))
                        }
                        downloadProgress(isDownloadingGemma, gemmaDownloadLabel)
                    }
                    .frame(maxHeight: .infinity)

                    card("Whisper") {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Whisper Model").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: whisperBinding) {
                                Text("Off").tag("")
                                ForEach(state.availableWhisperModels, id: \.self) { file in
                                    Text(whisperDisplayName(file)).tag(file)
                                }
                            }
                            .labelsHidden()
                        }
                        HStack(spacing: 6) {
                            Text("Download:").font(.caption).foregroundStyle(.secondary)
                            Button("Base") { downloadWhisperModel(size: "base") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(isDownloadingWhisper || state.availableWhisperModels.contains("whisper-ggml-base.en.bin"))
                            Button("Small") { downloadWhisperModel(size: "small") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(isDownloadingWhisper || state.availableWhisperModels.contains("whisper-ggml-small.en.bin"))
                            Button("Medium") { downloadWhisperModel(size: "medium") }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(isDownloadingWhisper || state.availableWhisperModels.contains("whisper-ggml-medium.en.bin"))
                        }
                        downloadProgress(isDownloadingWhisper, whisperDownloadLabel)
                    }
                    .frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

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
                    .frame(maxHeight: .infinity)

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
                    .frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

                // ── Notifications ──
                card("Notifications") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        notifCard("Daily Report", icon: "sun.max", enabled: $state.dailyReportEnabled, time: $state.dailyReportTime)
                        notifCard("Meal Prep", icon: "fork.knife", enabled: $state.mealPrepEnabled, time: $state.mealPrepTime)
                        notifCard("Overdue Chores", icon: "exclamationmark.circle", enabled: $state.overdueChoresEnabled, time: $state.overdueChoresTime)
                        notifCard("End of Day", icon: "moon.stars", enabled: $state.endOfDayEnabled, time: $state.endOfDayTime)
                        notifCardStepper("Calendar", icon: "calendar.badge.clock", enabled: $state.calendarHeadsUpEnabled,
                                         value: $state.calendarHeadsUpMinutes, range: 5...120, step: 5, unit: "min")
                        weatherCard
                        webSearchCard
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
                            stepperRow("Context Length",
                                       value: $state.gemmaNCtx,
                                       range: 0...131072,
                                       step: 4096,
                                       unit: state.gemmaNCtx == 0 ? "(model max)" : "tokens")
                            stepperRow("Chat History", value: $state.chatHistoryExchanges, range: 5...100, step: 5, unit: "exchanges")
                            stepperRow("Heartbeat", value: $state.heartbeatIntervalSeconds, range: 10...120, step: 5, unit: "seconds")
                            stepperRow("Note Results", value: $state.noteSearchResults, range: 1...20, step: 1, unit: "results")
                            stepperRow("Max Notes", value: $state.maxNotesInIndex, range: 1000...100000, step: 1000, unit: "")
                            HStack {
                                Toggle("Show Thinking", isOn: $state.showThinking)
                                    .font(.callout)
                                Spacer()
                            }
                        }
                        .padding(16)
                        .background(Color(.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(10)
                        .padding(.horizontal, 1)
                    }
                }


            }
            .padding(20)
        }
        .onAppear { state.scanAvailableModels() }
        .onChange(of: state.workingDirectory) { state.scanAvailableModels() }
    }

    // MARK: - Model Scanning

    /// The subdirectory inside the working directory where all model files live.
    private var modelsDirectory: String {
        let wd = state.workingDirectory.isEmpty ? AppState.defaultWorkingDirectory : state.workingDirectory
        return "\(wd)/models"
    }

    private func gemmaDisplayName(_ filename: String) -> String {
        // "gemma-4-12b-it-Q4_K_M.gguf" → "Gemma 4 12B (Q4_K_M)"
        var s = filename.replacingOccurrences(of: ".gguf", with: "")
        s = s.replacingOccurrences(of: "-", with: " ")
        return s
    }

    private func whisperDisplayName(_ filename: String) -> String {
        if filename.contains("medium") { return "Whisper Medium (EN)" }
        if filename.contains("small")  { return "Whisper Small (EN)" }
        if filename.contains("base")   { return "Whisper Base (EN)" }
        return filename
    }

    /// Known LM → mmproj pairings. We control the filenames via the download
    /// buttons, so this is just a simple lookup table.
    private static let mmprojForModel: [String: String] = [
        "gemma-4-E2B-it-Q4_K_M.gguf":        "mmproj-E2B-F16.gguf",
        "gemma-4-E4B-it-Q4_K_M.gguf":        "mmproj-E4B-F16.gguf",
        "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf": "mmproj-26B-A4B-F16.gguf",
        "Qwen3.5-9B-Q4_K_M.gguf":             "mmproj-Qwen3.5-9B-F16.gguf",
    ]

    private func matchingMmproj(for lmFile: String) -> String {
        Self.mmprojForModel[lmFile] ?? ""
    }

    /// Binding that maps whisper model selection ↔ audioBackend + whisperModelPath.
    private var whisperBinding: Binding<String> {
        Binding(
            get: {
                state.audioBackend == "whisper" ? state.whisperModelPath : ""
            },
            set: { newVal in
                if newVal.isEmpty {
                    state.audioBackend = "off"
                    state.whisperModelPath = ""
                } else {
                    state.audioBackend = "whisper"
                    state.whisperModelPath = newVal
                }
            }
        )
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

            Text(core.isRunning ? "Running" : "Stopped")
                .font(.title3).fontWeight(.semibold)

            Spacer()

            Button {
                state.saveConfig()
                AppState.shared.showToast("Config saved")
            } label: {
                Label("Save Config", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var weatherCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud.sun")
                .font(.callout)
                .foregroundStyle(state.weatherEnabled ? .primary : .secondary)
                .frame(width: 20)
            Toggle("Weather", isOn: $state.weatherEnabled)
                .font(.callout)
            Spacer()
            TextField("Zip", text: $state.weatherZip)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .disabled(!state.weatherEnabled)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            state.weatherEnabled ? Color.accentColor.opacity(0.06) : Color.clear
        ))
    }

    private var webSearchCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.callout)
                .foregroundStyle(state.webSearchEnabled ? .primary : .secondary)
                .frame(width: 20)
            Toggle("Web Search", isOn: $state.webSearchEnabled)
                .font(.callout)
            Spacer()
            Stepper("\(state.webSearchMaxResults) results",
                    value: $state.webSearchMaxResults, in: 1...10)
                .font(.caption)
                .disabled(!state.webSearchEnabled)
                .scaleEffect(0.85, anchor: .trailing)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            state.webSearchEnabled ? Color.accentColor.opacity(0.06) : Color.clear
        ))
    }

    // MARK: - Actions

    private func toggleCore() {
        if core.isRunning {
            discord.disconnect()
            core.stop()
            AppState.shared.showToast("Stopped")
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

            if !state.gemmaModelPath.isEmpty {
                let resolved = "\(wd)/models/\(state.gemmaModelPath)"
                if !FileManager.default.fileExists(atPath: resolved) {
                    AppState.shared.showToast("Gemma model file not found: \(state.gemmaModelPath)", isError: true)
                }
            }
            state.scanAvailableModels()

            if !state.discordBotToken.isEmpty {
                discord.connect(token: state.discordBotToken, channelId: state.discordChannelId)
            }
            AppState.shared.showToast("Running")
        }
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

    // MARK: - Downloads (with progress)

    /// Download a file from `url` into the working directory as `filename`.
    /// Updates `progressLabel` with MiB progress. Calls `onDone(success)` on
    /// the main thread when finished (success or failure with toast).
    private func downloadFile(url: URL, filename: String,
                              progressLabel: @escaping (String) -> Void,
                              onDone: @escaping (Bool) -> Void) {
        let dir = modelsDirectory

        // Ensure the models directory exists before the download starts.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let tracker = DownloadTracker()
        tracker.destPath = "\(dir)/\(filename)"
        tracker.progressLabel = progressLabel
        tracker.onComplete = { ok, error in
            // Already on main thread (dispatched by the tracker).
            if let error {
                AppState.shared.showToast("Failed: \(filename) — \(error.localizedDescription)", isError: true)
            }
            onDone(ok)
        }
        // The session retains the tracker as its delegate.
        let session = URLSession(configuration: .default, delegate: tracker, delegateQueue: nil)
        session.downloadTask(with: url).resume()
    }

    private func downloadGemma(size: String) {
        struct Variant {
            let repo: String       // HuggingFace repo ID
            let lmFile: String     // remote filename for the LM GGUF
            let mmprojRemote: String // remote filename for the mmproj
            let mmprojLocal: String  // local filename (renamed to avoid collisions)
        }
        // Real Gemma 4 repos on HuggingFace (unsloth community quants).
        let variants: [String: Variant] = [
            "e2b": Variant(
                repo: "unsloth/gemma-4-E2B-it-GGUF",
                lmFile: "gemma-4-E2B-it-Q4_K_M.gguf",
                mmprojRemote: "mmproj-F16.gguf",
                mmprojLocal: "mmproj-E2B-F16.gguf"),
            "e4b": Variant(
                repo: "unsloth/gemma-4-E4B-it-GGUF",
                lmFile: "gemma-4-E4B-it-Q4_K_M.gguf",
                mmprojRemote: "mmproj-F16.gguf",
                mmprojLocal: "mmproj-E4B-F16.gguf"),
            "26b-a4b": Variant(
                repo: "unsloth/gemma-4-26B-A4B-it-GGUF",
                lmFile: "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf",
                mmprojRemote: "mmproj-F16.gguf",
                mmprojLocal: "mmproj-26B-A4B-F16.gguf"),
            "qwen-9b": Variant(
                repo: "unsloth/Qwen3.5-9B-GGUF",
                lmFile: "Qwen3.5-9B-Q4_K_M.gguf",
                mmprojRemote: "mmproj-F16.gguf",
                mmprojLocal: "mmproj-Qwen3.5-9B-F16.gguf"),
        ]
        guard let v = variants[size] else { return }

        let fm = FileManager.default
        let hasMMproj = !v.mmprojRemote.isEmpty
        let lmExists = fm.fileExists(atPath: "\(modelsDirectory)/\(v.lmFile)")
        let mmExists = hasMMproj ? fm.fileExists(atPath: "\(modelsDirectory)/\(v.mmprojLocal)") : true

        if lmExists && mmExists {
            state.scanAvailableModels()
            state.gemmaModelPath = v.lmFile
            state.gemmaMmprojPath = v.mmprojLocal
            AppState.shared.showToast("\(size.uppercased()) already downloaded")
            return
        }

        guard let lmURL = URL(string: "https://huggingface.co/\(v.repo)/resolve/main/\(v.lmFile)") else {
            AppState.shared.showToast("Invalid download URL", isError: true)
            return
        }
        let mmURL = hasMMproj ? URL(string: "https://huggingface.co/\(v.repo)/resolve/main/\(v.mmprojRemote)") : nil

        isDownloadingGemma = true

        // After LM is done, optionally download mmproj, then finalize.
        let finalize = {
            if hasMMproj && !mmExists, let mmURL {
                downloadFile(url: mmURL, filename: v.mmprojLocal,
                             progressLabel: { p in gemmaDownloadLabel = "Vision projector... \(p)" },
                             onDone: { ok in
                    isDownloadingGemma = false
                    state.scanAvailableModels()
                    state.gemmaModelPath = v.lmFile
                    state.gemmaMmprojPath = ok ? v.mmprojLocal : ""
                    if ok {
                        AppState.shared.showToast("\(size.uppercased()) downloaded")
                    }
                })
            } else {
                isDownloadingGemma = false
                state.scanAvailableModels()
                state.gemmaModelPath = v.lmFile
                state.gemmaMmprojPath = v.mmprojLocal
                AppState.shared.showToast("\(size.uppercased()) downloaded")
            }
        }

        if lmExists {
            finalize()
        } else {
            downloadFile(url: lmURL, filename: v.lmFile,
                         progressLabel: { p in gemmaDownloadLabel = "\(size.uppercased())... \(p)" },
                         onDone: { ok in
                if ok { finalize() }
                else { isDownloadingGemma = false }
            })
        }
    }

    private func downloadWhisperModel(size: String) {
        let remoteFile = "ggml-\(size).en.bin"
        let localFile = "whisper-ggml-\(size).en.bin"
        guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(remoteFile)") else { return }

        let wd = state.workingDirectory.isEmpty ? AppState.defaultWorkingDirectory : state.workingDirectory
        if FileManager.default.fileExists(atPath: "\(modelsDirectory)/\(localFile)") {
            state.scanAvailableModels()
            state.audioBackend = "whisper"
            state.whisperModelPath = localFile
            AppState.shared.showToast("Already downloaded — selected")
            return
        }

        isDownloadingWhisper = true
        downloadFile(url: url, filename: localFile,
                     progressLabel: { p in whisperDownloadLabel = "Whisper \(size)... \(p)" },
                     onDone: { ok in
            isDownloadingWhisper = false
            if ok {
                state.scanAvailableModels()
                state.audioBackend = "whisper"
                state.whisperModelPath = localFile
                AppState.shared.showToast("Whisper \(size) downloaded")
            }
        })
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

// MARK: - Download delegate with progress reporting

private class DownloadTracker: NSObject, URLSessionDownloadDelegate {
    var progressLabel: ((String) -> Void)?
    var onComplete: ((Bool, Error?) -> Void)?
    var destPath: String = ""  // absolute path — file is moved here inside the callback

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let written = Double(totalBytesWritten) / 1_048_576 // MiB
        let total = Double(totalBytesExpectedToWrite) / 1_048_576
        let label = total > 0
            ? String(format: "%.0f / %.0f MiB", written, total)
            : String(format: "%.0f MiB", written)
        DispatchQueue.main.async { self.progressLabel?(label) }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted by the OS when this callback returns,
        // so we MUST move it synchronously here — not on the main thread.

        // Reject HTML error pages from HuggingFace (e.g. 404s).
        // Valid model files (GGUF, ggml) never start with '<'.
        if let handle = try? FileHandle(forReadingFrom: location) {
            let head = handle.readData(ofLength: 1)
            handle.closeFile()
            if head.first == 0x3C { // '<' — HTML
                let err = NSError(domain: "DownloadTracker", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Download returned an HTML error page, not a model file. The URL may be wrong."])
                DispatchQueue.main.async { self.onComplete?(false, err) }
                return
            }
        }

        let dest = URL(fileURLWithPath: destPath)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async { self.onComplete?(true, nil) }
        } catch {
            DispatchQueue.main.async { self.onComplete?(false, error) }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            DispatchQueue.main.async { self.onComplete?(false, error) }
        }
    }
}
