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

        let content = d["content"] as? String ?? ""
        let messageId = d["id"] as? String ?? ""
        let username = (d["author"] as? [String: Any])?["username"] as? String ?? "User"

        // Partition attachments into audio and image lists.
        var imageAttachments: [(url: String, filename: String)] = []
        if let attachments = d["attachments"] as? [[String: Any]] {
            for attachment in attachments {
                guard let contentType = attachment["content_type"] as? String,
                      let urlStr = attachment["url"] as? String,
                      let filename = attachment["filename"] as? String
                else { continue }

                if contentType.hasPrefix("audio/") {
                    print("[Discord] Audio attachment from \(username): \(filename)")
                    downloadAndTranscribe(url: urlStr, filename: filename,
                                          messageId: messageId, channelId: msgChannelId,
                                          username: username)
                } else if contentType.hasPrefix("image/") {
                    imageAttachments.append((url: urlStr, filename: filename))
                }
            }
        }

        // Nothing to send if there's no text AND no images.
        guard !content.isEmpty || !imageAttachments.isEmpty else { return }

        if !imageAttachments.isEmpty {
            print("[Discord] Message from \(username) (\(content.count) chars, \(imageAttachments.count) image(s))")
            downloadImagesAndDispatch(images: imageAttachments,
                                      content: content,
                                      messageId: messageId,
                                      channelId: msgChannelId,
                                      username: username)
            return
        }

        print("[Discord] Message from \(username) (\(content.count) chars)")

        DispatchQueue.global(qos: .userInitiated).async {
            core_on_message_received(username, content, msgChannelId, messageId, nil, 0)
            DispatchQueue.main.async {
                AppState.shared.refreshData()
            }
        }
    }

    private func downloadImagesAndDispatch(images: [(url: String, filename: String)],
                                           content: String,
                                           messageId: String,
                                           channelId: String,
                                           username: String) {
        let tmpDir = AppState.shared.tmpDirectory
        let group = DispatchGroup()
        let pathsLock = NSLock()
        var savedPaths: [String] = []

        for (urlStr, filename) in images {
            guard let url = URL(string: urlStr) else { continue }
            let destPath = "\(tmpDir)/\(messageId)_\(filename)"
            group.enter()
            URLSession.shared.downloadTask(with: url) { tempUrl, _, error in
                defer { group.leave() }
                if let error {
                    print("[Discord] Image download failed (\(filename)): \(error.localizedDescription)")
                    return
                }
                guard let tempUrl else { return }
                let dest = URL(fileURLWithPath: destPath)
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempUrl, to: dest)
                    print("[Discord] Saved image: \(destPath)")
                    pathsLock.lock()
                    savedPaths.append(destPath)
                    pathsLock.unlock()
                } catch {
                    print("[Discord] Failed to save image: \(error.localizedDescription)")
                }
            }.resume()
        }

        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            if savedPaths.isEmpty && content.isEmpty {
                print("[Discord] All image downloads failed and no text — dropping message")
                return
            }

            // Bridge [String] → const char* const* via strdup so each C string
            // stays alive for the duration of the call. strdup returns a mutable
            // pointer; C expects const, so rebind at the array level.
            let cPaths: [UnsafePointer<CChar>?] = savedPaths.map { str in
                guard let m = strdup(str) else { return nil }
                return UnsafePointer(m)
            }
            defer {
                cPaths.forEach { ptr in
                    if let ptr = ptr {
                        free(UnsafeMutableRawPointer(mutating: ptr))
                    }
                }
            }

            cPaths.withUnsafeBufferPointer { buf in
                core_on_message_received(username, content, channelId, messageId,
                                         buf.baseAddress, Int32(savedPaths.count))
            }

            DispatchQueue.main.async {
                AppState.shared.refreshData()
            }
        }
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
            core_on_message_received(username, userMessage, channelId, messageId, nil, 0)

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
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status < 200 || status >= 300 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[Discord] Send message failed (status \(status)): \(body.prefix(300))")
            }
        }.resume()
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
