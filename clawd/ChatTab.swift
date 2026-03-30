import SwiftUI

struct ChatTab: View {
    @Bindable private var state = AppState.shared
    @State private var messageText = ""
    @State private var isProcessing = false
    @State private var sendAsAssistant = false

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

            // Input field
            HStack {
                TextField("Type a message...", text: $messageText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isProcessing || !CoreBridge.shared.isRunning)
                    .onSubmit { sendMessage() }

                Picker("", selection: $sendAsAssistant) {
                    Text("User").tag(false)
                    Text("Assistant").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Send") { sendMessage() }
                        .buttonStyle(.borderedProminent)
                        .disabled(messageText.isEmpty || !CoreBridge.shared.isRunning)
                }
            }
            .padding()
        }
        .onAppear { state.refreshData() }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""

        if sendAsAssistant {
            // Send directly as the assistant — no AI invocation
            // Log to chat history
            CoreBridge.shared.appendAssistantMessage(text)
            // Send to Discord
            DiscordService.shared.sendChannelMessage(text)
            state.refreshData()
        } else {
            // Send as user — invoke AI
            isProcessing = true
            DispatchQueue.global(qos: .userInitiated).async {
                CoreBridge.shared.sendMessage(user: "User", text: text)
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
