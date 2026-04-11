import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ChatTab: View {
    @Bindable private var state = AppState.shared
    @Bindable private var core = CoreBridge.shared
    @State private var messageText = ""
    @State private var isProcessing = false
    @State private var sendRole: SendRole = .user
    @State private var attachedImagePath: String? = nil

    private enum SendRole: String, CaseIterable {
        case user = "User"
        case assistant = "Assistant"
        case system = "System"
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

            // Attached image preview (shown above the input row when present)
            if let path = attachedImagePath {
                HStack(spacing: 8) {
                    if let nsImage = NSImage(contentsOfFile: path) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 48)
                            .cornerRadius(4)
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .frame(height: 48)
                    }
                    Text((path as NSString).lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        attachedImagePath = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove image")
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }

            // Input field
            HStack {
                Button {
                    pickImage()
                } label: {
                    Image(systemName: attachedImagePath == nil ? "paperclip" : "paperclip.circle.fill")
                        .font(.title3)
                        .foregroundStyle(core.hasVision ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isProcessing || !core.isRunning || !core.hasVision)
                .help(core.hasVision ? "Attach image" : "Vision projector not loaded")

                TextField("Type a message...", text: $messageText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isProcessing || !core.isRunning)
                    .onSubmit { sendMessage() }

                Picker("", selection: $sendRole) {
                    ForEach(SendRole.allCases, id: \.self) { role in
                        Text(role.rawValue).tag(role)
                    }
                }
                .frame(width: 110)

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Send") { sendMessage() }
                        .buttonStyle(.borderedProminent)
                        .disabled((messageText.isEmpty && attachedImagePath == nil) || !core.isRunning)
                }
            }
            .padding()
        }
        .onAppear { state.refreshData() }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Select an image to attach"
        if panel.runModal() == .OK, let url = panel.url {
            attachedImagePath = url.path
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imagePath = attachedImagePath
        guard !text.isEmpty || imagePath != nil else { return }
        messageText = ""
        attachedImagePath = nil

        switch sendRole {
        case .assistant:
            // Log directly as assistant — no AI invocation
            CoreBridge.shared.appendAssistantMessage(text)
            DiscordService.shared.sendChannelMessage(text)
            state.refreshData()

        case .user, .system:
            // Both user and system messages invoke the AI for a response
            isProcessing = true
            let role = sendRole.rawValue
            DispatchQueue.global(qos: .userInitiated).async {
                if let imagePath {
                    CoreBridge.shared.sendMessageWithImage(user: role, text: text, imagePath: imagePath)
                } else {
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
