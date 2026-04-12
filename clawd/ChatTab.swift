import SwiftUI
import UniformTypeIdentifiers

struct ChatTab: View {
    enum MessageRole: String, CaseIterable {
        case user = "User"
        case assistant = "Assistant"
        case system = "System"
    }

    private static let imageTypes: [UTType] = [.png, .jpeg, .gif, .webP, .bmp, .tiff]
    private static let audioTypes: [UTType] = [.audio, .mp3, .wav, .aiff]
    private static let allowedTypes = imageTypes + audioTypes

    @Bindable private var state = AppState.shared
    @State private var messageText = ""
    @State private var isProcessing = false
    @State private var selectedRole: MessageRole = .user
    @State private var attachedFileURL: URL?
    @State private var showFilePicker = false

    private var attachmentIsAudio: Bool {
        guard let url = attachedFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        return ["mp3", "wav", "m4a", "aac", "ogg", "opus", "aiff", "flac"].contains(ext)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Chat log display
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(parseEntries(state.chatLog), id: \.id) { entry in
                            ChatBubble(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: state.chatLog) {
                    if let last = parseEntries(state.chatLog).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Attachment chip
            if let url = attachedFileURL {
                HStack(spacing: 4) {
                    Image(systemName: attachmentIsAudio ? "waveform" : "photo")
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                    Button { attachedFileURL = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 6)
            }

            // Input field
            HStack {
                TextField("Type a message...", text: $messageText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isProcessing || !CoreBridge.shared.isRunning)
                    .onSubmit { sendMessage() }

                // Attachment button
                Button { showFilePicker = true } label: {
                    Image(systemName: "paperclip")
                }
                .disabled(isProcessing || !CoreBridge.shared.isRunning || attachedFileURL != nil)
                .fileImporter(
                    isPresented: $showFilePicker,
                    allowedContentTypes: Self.allowedTypes,
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        attachedFileURL = url
                    }
                }

                Picker("", selection: $selectedRole) {
                    ForEach(MessageRole.allCases, id: \.self) { role in
                        Text(role.rawValue).tag(role)
                    }
                }
                .frame(width: 100)

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Send") { sendMessage() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            (messageText.isEmpty && attachedFileURL == nil)
                            || !CoreBridge.shared.isRunning
                        )
                }
            }
            .padding()
        }
        .onAppear { state.refreshData() }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = attachedFileURL
        guard !text.isEmpty || attachment != nil else { return }
        messageText = ""
        attachedFileURL = nil

        switch selectedRole {
        case .assistant:
            // Send directly as the assistant — no AI invocation
            if !text.isEmpty {
                CoreBridge.shared.appendAssistantMessage(text)
                DiscordService.shared.sendChannelMessage(text)
            }
            state.refreshData()
        case .user, .system:
            // Send as user or system — invoke AI
            isProcessing = true
            let role = selectedRole.rawValue
            let isAudio = attachmentIsAudio
            DispatchQueue.global(qos: .userInitiated).async {
                let tmpPath = copyToTmp(attachment)

                if let tmpPath, isAudio {
                    // Transcribe audio, then send transcript as the message
                    if let transcript = CoreBridge.shared.transcribeAudio(tmpPath) {
                        let msg = text.isEmpty
                            ? "[Voice message transcript]: \(transcript)"
                            : "\(text)\n[Voice message transcript]: \(transcript)"
                        CoreBridge.shared.sendMessage(user: role, text: msg)
                    } else {
                        let msg = text.isEmpty ? "[Audio transcription failed]" : text
                        CoreBridge.shared.sendMessage(user: role, text: msg)
                    }
                    try? FileManager.default.removeItem(atPath: tmpPath)
                } else if let tmpPath {
                    // Image attachment
                    CoreBridge.shared.sendMessage(user: role, text: text, imagePath: tmpPath)
                } else {
                    // Text only
                    CoreBridge.shared.sendMessage(user: role, text: text)
                }

                DispatchQueue.main.async {
                    state.refreshData()
                    if let last = parseEntries(state.chatLog).last,
                       last.role == "Assistant",
                       last.content.hasPrefix("[Error:") {
                        AppState.shared.showToast(last.content, isError: true)
                    }
                    isProcessing = false
                }
            }
        }
    }

    /// Copy the selected file into the working tmp directory so the core can access it.
    private func copyToTmp(_ url: URL?) -> String? {
        guard let url else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let tmpDir = AppState.shared.tmpDirectory
        let dest = "\(tmpDir)/local_\(UUID().uuidString)_\(url.lastPathComponent)"
        do {
            try FileManager.default.copyItem(atPath: url.path, toPath: dest)
            return dest
        } catch {
            print("[ChatTab] Failed to copy attachment: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Chat Parsing

    struct ChatEntry: Identifiable {
        let id: Int
        let role: String   // Username, "Assistant", "Tool", "System", etc.
        let time: String
        let content: String
        let isHuman: Bool  // true for any non-assistant, non-tool, non-system role
    }

    private func parseEntries(_ log: String) -> [ChatEntry] {
        var entries: [ChatEntry] = []
        let lines = log.components(separatedBy: "\n")
        var currentRole = ""
        var currentTime = ""
        var currentContent: [String] = []
        var entryId = 0

        for line in lines {
            if line.hasPrefix("## ") {
                if !currentRole.isEmpty {
                    let isHuman = currentRole != "Assistant" && currentRole != "Tool" && currentRole != "System"
                    entries.append(ChatEntry(
                        id: entryId, role: currentRole, time: currentTime,
                        content: currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                        isHuman: isHuman
                    ))
                    entryId += 1
                }

                let parts = String(line.dropFirst(3)).split(separator: " ", maxSplits: 1)
                currentRole = parts.count > 0 ? String(parts[0]) : ""
                currentTime = parts.count > 1 ? String(parts[1]) : ""
                currentContent = []
            } else {
                currentContent.append(line)
            }
        }

        if !currentRole.isEmpty {
            let isHuman = currentRole != "Assistant" && currentRole != "Tool" && currentRole != "System"
            entries.append(ChatEntry(
                id: entryId, role: currentRole, time: currentTime,
                content: currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                isHuman: isHuman
            ))
        }

        return entries
    }
}

struct ChatBubble: View {
    let entry: ChatTab.ChatEntry

    private var isTool: Bool { entry.role == "Tool" }

    var body: some View {
        HStack {
            if entry.isHuman { Spacer(minLength: 60) }

            VStack(alignment: entry.isHuman ? .trailing : .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.role)
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(entry.time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(entry.content)
                    .padding(8)
                    .background(
                        isTool ? Color.orange.opacity(0.15) :
                        entry.isHuman ? Color.blue.opacity(0.15) :
                        Color.secondary.opacity(0.1)
                    )
                    .cornerRadius(8)
                    .font(isTool ? .caption.monospaced() : .body)
            }

            if !entry.isHuman { Spacer(minLength: 60) }
        }
    }
}
