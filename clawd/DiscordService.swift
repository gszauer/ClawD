import Foundation

/// Manages the Discord WebSocket gateway connection and REST API calls.
@Observable
final class DiscordService: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    static let shared = DiscordService()

    private(set) var isConnected = false
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeatInterval: Double = 41.25
    private var heartbeatTimer: Timer?
    private var lastSequence: Int?
    private var sessionId: String?
    private var resumeGatewayUrl: String?
    private var botToken: String = ""
    private var channelId: String = ""
    private var intentionalDisconnect = false
    private var internalDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var awaitingHeartbeatAck = false
    private var warnedAboutEmptyContent = false

    private let apiBase = "https://discord.com/api/v10"

    private override init() { super.init() }

    // MARK: - Connection

    func connect(token: String, channelId: String) {
        self.botToken = token
        self.channelId = channelId
        self.intentionalDisconnect = false
        self.internalDisconnect = false
        self.reconnectAttempts = 0

        guard !token.isEmpty else {
            print("[Discord] No bot token configured")
            return
        }

        startConnection()
    }

    private func startConnection() {
        // Clean up any existing connection first
        cleanupConnection()

        internalDisconnect = false
        print("[Discord] Connecting (attempt \(reconnectAttempts + 1)/\(maxReconnectAttempts + 1))...")

        // Get gateway URL
        var request = URLRequest(url: URL(string: "\(apiBase)/gateway")!)
        request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                print("[Discord] Gateway request failed: \(error.localizedDescription)")
                AppState.shared.showToast("Discord: \(error.localizedDescription)", isError: true)
                self.scheduleReconnect()
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let gatewayUrl = json["url"] as? String
            else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[Discord] Bad gateway response (status \(statusCode)): \(body)")
                AppState.shared.showToast("Discord: bad gateway response (status \(statusCode))", isError: true)
                self.scheduleReconnect()
                return
            }

            let wsUrl = "\(gatewayUrl)?v=10&encoding=json"
            print("[Discord] Gateway URL: \(wsUrl)")
            self.openWebSocket(urlString: wsUrl)
        }.resume()
    }

    func disconnect() {
        intentionalDisconnect = true
        cleanupConnection()
        DispatchQueue.main.async {
            self.isConnected = false
        }
        core_on_disconnected()
        print("[Discord] Disconnected")
    }

    private func cleanupConnection() {
        internalDisconnect = true
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func scheduleReconnect() {
        guard !intentionalDisconnect else { return }
        reconnectAttempts += 1

        if reconnectAttempts > maxReconnectAttempts {
            print("[Discord] Max reconnect attempts reached. Giving up.")
            AppState.shared.showToast("Discord: connection failed after \(maxReconnectAttempts) attempts", isError: true)
            DispatchQueue.main.async { self.isConnected = false }
            return
        }

        // Exponential backoff: 2s, 4s, 8s, 16s, 32s
        let delay = Double(1 << reconnectAttempts)
        print("[Discord] Reconnecting in \(Int(delay))s...")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect else { return }
            self.startConnection()
        }
    }

    // MARK: - WebSocket

    private func openWebSocket(urlString: String) {
        guard let url = URL(string: urlString) else { return }

        // Create session with self as delegate to get connection lifecycle events
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()
        receiveMessage()
    }

    // URLSessionWebSocketDelegate — connection opened
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        print("[Discord] WebSocket connected")
    }

    // URLSessionWebSocketDelegate — connection closed
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        let code = closeCode.rawValue
        print("[Discord] WebSocket closed (code: \(code))")
        DispatchQueue.main.async { self.isConnected = false }

        // We closed it ourselves (cleanup, op7, op9) — don't double-reconnect
        if internalDisconnect { return }

        // Fatal close codes — don't retry, it's a config problem
        switch code {
        case 4004:
            AppState.shared.showToast("Discord: invalid bot token", isError: true)
            return
        case 4014:
            AppState.shared.showToast("Discord: MESSAGE CONTENT INTENT not enabled in Developer Portal", isError: true)
            return
        case 4013:
            AppState.shared.showToast("Discord: invalid intents value", isError: true)
            return
        case 4010, 4011, 4012:
            AppState.shared.showToast("Discord: connection error (code \(code))", isError: true)
            return
        default:
            break
        }

        // Unexpected close by Discord — try to reconnect
        scheduleReconnect()
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleGatewayMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleGatewayMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()

            case .failure:
                // Don't reconnect here — didCloseWith handles it.
                // This fires alongside didClose; acting on both causes double reconnects.
                break
            }
        }
    }

    private func handleGatewayMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int
        else { return }

        if let s = json["s"] as? Int {
            lastSequence = s
        }

        switch op {
        case 10: // Hello
            if let d = json["d"] as? [String: Any],
               let interval = d["heartbeat_interval"] as? Double {
                heartbeatInterval = interval / 1000.0
                awaitingHeartbeatAck = false
                startHeartbeat()
                sendIdentify()
            }

        case 0: // Dispatch
            guard let t = json["t"] as? String,
                  let d = json["d"] as? [String: Any]
            else { return }

            switch t {
            case "READY":
                sessionId = d["session_id"] as? String
                resumeGatewayUrl = d["resume_gateway_url"] as? String
                reconnectAttempts = 0 // reset on successful connection
                DispatchQueue.main.async { self.isConnected = true }
                core_on_connected()
                print("[Discord] Connected and ready (session: \(sessionId ?? "?"))")
                AppState.shared.showToast("Discord connected")

            case "MESSAGE_CREATE":
                handleMessageCreate(d)

            default:
                break
            }

        case 7: // Reconnect requested by Discord
            print("[Discord] Server requested reconnect")
            cleanupConnection()
            scheduleReconnect()

        case 9: // Invalid Session
            print("[Discord] Invalid session")
            cleanupConnection()
            scheduleReconnect()

        case 11: // Heartbeat ACK
            awaitingHeartbeatAck = false

        default:
            break
        }
    }

    private func handleMessageCreate(_ d: [String: Any]) {
        if let author = d["author"] as? [String: Any],
           let bot = author["bot"] as? Bool, bot {
            return
        }

        guard let msgChannelId = d["channel_id"] as? String else { return }
        if !channelId.isEmpty && msgChannelId != channelId { return }

        var content = d["content"] as? String ?? ""
        let messageId = d["id"] as? String ?? ""
        let username = (d["author"] as? [String: Any])?["username"] as? String ?? "User"

        // Classify attachments into audio and image groups. Audio is handled
        // independently (transcription); image goes through the multimodal
        // prompt path.
        var audioAttachments: [(url: String, filename: String)] = []
        var imageAttachments: [(url: String, filename: String)] = []
        if let attachments = d["attachments"] as? [[String: Any]] {
            for attachment in attachments {
                guard let contentType = attachment["content_type"] as? String,
                      let urlStr = attachment["url"] as? String,
                      let filename = attachment["filename"] as? String
                else { continue }
                if contentType.hasPrefix("audio/") {
                    audioAttachments.append((urlStr, filename))
                } else if contentType.hasPrefix("image/") {
                    imageAttachments.append((urlStr, filename))
                }
            }
        }

        // Dispatch audio attachments — each gets transcribed independently.
        for audio in audioAttachments {
            print("[Discord] Audio attachment from \(username): \(audio.filename)")
            downloadAndTranscribe(url: audio.url, filename: audio.filename,
                                  messageId: messageId, channelId: msgChannelId,
                                  username: username)
        }

        // Dispatch the first image attachment (we only support one per message).
        // Append a notice to the message text if there were additional images
        // so the model knows the others were dropped.
        if let firstImage = imageAttachments.first {
            if imageAttachments.count > 1 {
                if !content.isEmpty { content += "\n\n" }
                content += "[Info] Only one image can be processed per message"
            }
            print("[Discord] Image attachment from \(username): \(firstImage.filename)")
            downloadAndProcessImage(url: firstImage.url, filename: firstImage.filename,
                                    messageId: messageId, channelId: msgChannelId,
                                    username: username, content: content)
            return
        }

        guard !content.isEmpty else {
            // Discord delivers MESSAGE_CREATE events with empty `content` when
            // the MESSAGE CONTENT intent isn't granted in the Developer Portal.
            // Warn once per session so the failure isn't silent.
            let hasAttachments = (d["attachments"] as? [[String: Any]])?.isEmpty == false
            if !hasAttachments && !warnedAboutEmptyContent {
                warnedAboutEmptyContent = true
                AppState.shared.showToast(
                    "Discord: message arrived with empty content. Enable MESSAGE CONTENT INTENT in the Developer Portal.",
                    isError: true)
            }
            return
        }

        print("[Discord] Message from \(username) (\(content.count) chars)")

        DispatchQueue.global(qos: .userInitiated).async {
            core_on_message_received(username, content, msgChannelId, messageId, "")
            DispatchQueue.main.async {
                AppState.shared.refreshData()
            }
        }
    }

    /// Download a Discord image attachment, pass it into the core's multimodal
    /// path alongside the message text, then clean up the temp file.
    private func downloadAndProcessImage(url urlStr: String, filename: String,
                                         messageId: String, channelId: String,
                                         username: String, content: String) {
        guard let url = URL(string: urlStr) else { return }
        let tmpDir = AppState.shared.tmpDirectory
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let destPath = "\(tmpDir)/\(messageId)_\(filename)"

        URLSession.shared.downloadTask(with: url) { tempUrl, _, error in
            if let error {
                print("[Discord] Image download failed: \(error.localizedDescription)")
                AppState.shared.showToast("Discord image download failed: \(error.localizedDescription)", isError: true)
                return
            }
            guard let tempUrl else { return }

            // Synchronous move inside the delegate callback — the OS deletes
            // the temp file once this closure returns.
            let dest = URL(fileURLWithPath: destPath)
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempUrl, to: dest)
                print("[Discord] Saved image: \(destPath)")
            } catch {
                print("[Discord] Failed to save image: \(error.localizedDescription)")
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                core_on_message_received(username, content, channelId, messageId, destPath)
                // Clean up the temp file after the core finishes with it.
                try? FileManager.default.removeItem(atPath: destPath)
                DispatchQueue.main.async {
                    AppState.shared.refreshData()
                }
            }
        }.resume()
    }

    private func downloadAndTranscribe(url urlStr: String, filename: String,
                                       messageId: String, channelId: String,
                                       username: String) {
        let audioBackend = AppState.shared.audioBackend
        guard audioBackend != "off" else {
            print("[Discord] Audio backend is off, ignoring attachment")
            return
        }

        guard let url = URL(string: urlStr) else { return }
        let tmpDir = AppState.shared.tmpDirectory
        let destPath = "\(tmpDir)/\(messageId)_\(filename)"

        URLSession.shared.downloadTask(with: url) { [weak self] tempUrl, response, error in
            if let error {
                print("[Discord] Attachment download failed: \(error.localizedDescription)")
                return
            }
            guard let tempUrl else { return }
            let dest = URL(fileURLWithPath: destPath)
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempUrl, to: dest)
                print("[Discord] Saved audio: \(destPath)")
            } catch {
                print("[Discord] Failed to save attachment: \(error.localizedDescription)")
                return
            }

            // Transcribe
            self?.transcribeAudio(filePath: destPath, messageId: messageId,
                                  channelId: channelId, username: username)
        }.resume()
    }

    private func transcribeAudio(filePath: String, messageId: String,
                                  channelId: String, username: String) {
        // Add ear emoji to acknowledge audio
        addReaction(channelId: channelId, messageId: messageId, emoji: "\u{1F442}") // 👂

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let cStr = core_transcribe_audio(filePath) else {
                print("[Discord] Transcription not available or failed")
                try? FileManager.default.removeItem(atPath: filePath)
                return
            }
            let transcript = String(cString: cStr)
            core_free_string(cStr)

            print("[Discord] Transcript (\(transcript.count) chars)")
            try? FileManager.default.removeItem(atPath: filePath)

            // Feed to the AI as a user message (blocks until LLM responds)
            let userMessage = "[Voice message transcript]: \(transcript)"
            core_on_message_received(username, userMessage, channelId, messageId, "")

            // Post transcript to Discord after the AI response
            self?.sendChannelMessage("Transcribed audio: \(transcript)", to: channelId)

            DispatchQueue.main.async {
                AppState.shared.refreshData()
            }
        }
    }

    // MARK: - Gateway Protocol

    private func sendIdentify() {
        let identify: [String: Any] = [
            "op": 2,
            "d": [
                "token": botToken,
                "intents": 37377,
                "properties": [
                    "os": "macos",
                    "browser": "clawd",
                    "device": "clawd"
                ],
                "presence": [
                    "status": "online",
                    "afk": false
                ]
            ]
        ]
        sendJSON(identify)
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        DispatchQueue.main.async {
            self.heartbeatTimer = Timer.scheduledTimer(
                withTimeInterval: self.heartbeatInterval,
                repeats: true
            ) { [weak self] _ in
                self?.sendHeartbeat()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + heartbeatInterval * Double.random(in: 0...1)) {
            self.sendHeartbeat()
        }
    }

    private func sendHeartbeat() {
        if awaitingHeartbeatAck {
            print("[Discord] No heartbeat ACK received — zombied connection, reconnecting")
            cleanupConnection()
            scheduleReconnect()
            return
        }
        awaitingHeartbeatAck = true
        let payload: [String: Any?] = [
            "op": 1,
            "d": lastSequence as Any
        ]
        sendJSON(payload as [String: Any])
    }

    // MARK: - Sending

    func send(_ text: String) {
        webSocket?.send(.string(text)) { error in
            if let error {
                print("[Discord] Send error: \(error.localizedDescription)")
            }
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        send(text)
    }

    func sendChannelMessage(_ content: String, to channel: String? = nil) {
        let targetChannel = channel ?? channelId
        guard !targetChannel.isEmpty else {
            print("[Discord] sendChannelMessage: no channel ID")
            return
        }
        guard !botToken.isEmpty else {
            print("[Discord] sendChannelMessage: no bot token")
            return
        }

        // Discord's max message length is 4000 chars. Split longer content
        // into chunks, preferring paragraph/line boundaries where possible.
        let chunks = splitForDiscord(content, limit: 3900) // leave headroom
        for chunk in chunks {
            postSingleMessage(chunk, to: targetChannel)
        }
    }

    private func postSingleMessage(_ content: String, to targetChannel: String) {
        let url = URL(string: "\(apiBase)/channels/\(targetChannel)/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["content": content]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                print("[Discord] Send message error: \(error.localizedDescription)")
                AppState.shared.showToast("Discord send error: \(error.localizedDescription)", isError: true)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status < 200 || status >= 300 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[Discord] Send message failed (status \(status)): \(body.prefix(300))")
                AppState.shared.showToast("Discord send failed (status \(status))", isError: true)
            }
        }.resume()
    }

    /// Split `text` into chunks no longer than `limit` characters, preferring
    /// to break at double newlines, then single newlines, then word boundaries.
    /// Never splits mid-word unless a single word exceeds the limit.
    private func splitForDiscord(_ text: String, limit: Int) -> [String] {
        if text.count <= limit { return [text] }
        var chunks: [String] = []
        var remaining = Substring(text)
        while remaining.count > limit {
            let window = remaining.prefix(limit)
            // Prefer double newline, then single newline, then space.
            let splitAt = window.range(of: "\n\n", options: .backwards)?.lowerBound
                ?? window.range(of: "\n", options: .backwards)?.lowerBound
                ?? window.range(of: " ", options: .backwards)?.lowerBound
                ?? window.endIndex
            let chunk = remaining[..<splitAt]
            chunks.append(String(chunk).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = remaining[splitAt...].drop { $0 == "\n" || $0 == " " }
        }
        if !remaining.isEmpty {
            chunks.append(String(remaining).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return chunks.filter { !$0.isEmpty }
    }

    // MARK: - Reactions

    func addReaction(channelId: String, messageId: String, emoji: String) {
        let encoded = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        let url = URL(string: "\(apiBase)/channels/\(channelId)/messages/\(messageId)/reactions/\(encoded)/@me")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    func removeReaction(channelId: String, messageId: String, emoji: String) {
        let encoded = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        let url = URL(string: "\(apiBase)/channels/\(channelId)/messages/\(messageId)/reactions/\(encoded)/@me")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
