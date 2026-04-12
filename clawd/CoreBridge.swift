import Foundation

/// Swift wrapper around the C++ core API.
/// Manages initialization, callbacks, and message dispatch.
@Observable
final class CoreBridge: @unchecked Sendable {
    static let shared = CoreBridge()

    private(set) var isRunning = false
    private var heartbeatTimer: Timer?
    private var configPath: String = ""

    /// Called when the core produces a response (for chat UI)
    var onResponse: ((String) -> Void)?
    /// Called when a notification should fire
    var onNotification: ((String, String) -> Void)?

    private init() {}

    // MARK: - Lifecycle

    func start(configPath: String, workingDir: String? = nil) {
        guard !isRunning else { return }
        self.configPath = configPath

        var callbacks = PlatformCallbacks()
        callbacks.http_request = nativeHttpRequest
        callbacks.websocket_send = nativeWebSocketSend
        callbacks.send_notification = nativeSendNotification
        callbacks.schedule_timer = nativeScheduleTimer
        callbacks.cancel_timer = nativeCancelTimer
        callbacks.add_reaction = nativeAddReaction
        callbacks.remove_reaction = nativeRemoveReaction

        core_initialize(configPath, callbacks, workingDir)

        // Set up response callback so AI responses get sent to Discord
        core_set_response_callback { channelId, response in
            guard let channelId, let response else {
                print("[clawd] Response callback: nil params")
                return
            }
            let channel = String(cString: channelId)
            let text = String(cString: response)
            guard !channel.isEmpty, !text.isEmpty else {
                print("[clawd] Response callback: empty channel or text")
                return
            }
            print("[clawd] Sending response to Discord (\(text.count) chars)")
            DiscordService.shared.sendChannelMessage(text, to: channel)
        }

        isRunning = true

        // Load service account credentials from working/calendar.json if present
        let saPath = "\(AppState.shared.workingDirectory)/calendar.json"
        if FileManager.default.fileExists(atPath: saPath) && CalendarAuth.shared.load(from: saPath) {
            // Pre-fetch a token so calendar sync works immediately
            DispatchQueue.global(qos: .utility).async {
                if let token = CalendarAuth.shared.getAccessToken() {
                    core_set_calendar_token(token)
                }
            }
        }

        // Start heartbeat timer on main run loop
        let interval = Double(AppState.shared.heartbeatIntervalSeconds)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            // Refresh calendar token if needed (service account)
            if !CalendarAuth.shared.serviceAccountEmail.isEmpty {
                DispatchQueue.global(qos: .utility).async {
                    if let token = CalendarAuth.shared.getAccessToken() {
                        core_set_calendar_token(token)
                    }
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                core_check_tasks()
                DispatchQueue.main.async {
                    AppState.shared.refreshData()
                }
            }
        }
        // Run an immediate check for any overdue tasks
        core_check_tasks()
    }

    func stop() {
        guard isRunning else { return }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        core_shutdown()
        isRunning = false
    }

    /// Execute a tool directly, bypassing the AI. Returns the result string.
    @discardableResult
    func executeTool(_ name: String, params: [String]) -> String {
        guard isRunning else { return "" }
        let json = try? JSONSerialization.data(withJSONObject: params)
        let jsonStr = json.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        guard let result = core_execute_tool(name, jsonStr) else { return "" }
        let str = String(cString: result)
        core_free_string(result)
        return str
    }

    func reloadConfig() {
        core_on_config_changed()
    }

    // MARK: - Message Handling

    func sendMessage(user: String, text: String, channelId: String = "", messageId: String = "") {
        guard isRunning else { return }
        core_on_message_received(user, text, channelId, messageId, nil, 0)
    }

    /// Append a message as the assistant (no AI call) and log to chat history.
    func appendAssistantMessage(_ text: String) {
        guard isRunning else { return }
        core_append_assistant(text)
    }

    // MARK: - Data Queries

    func getMeals() -> [[String: Any]] { guard isRunning else { return [] }; return parseJSON(core_get_meals()) }
    func getChores() -> [[String: Any]] { guard isRunning else { return [] }; return parseJSON(core_get_chores()) }
    func getReminders() -> [[String: Any]] { guard isRunning else { return [] }; return parseJSON(core_get_reminders()) }
    func getNotes() -> [[String: Any]] { guard isRunning else { return [] }; return parseJSON(core_get_notes()) }

    func getChatHistory(date: String) -> String {
        guard isRunning, let cStr = core_get_chat_history(date) else { return "" }
        return String(cString: cStr)
    }

    // MARK: - Helpers

    private func parseJSON(_ cStr: UnsafePointer<CChar>?) -> [[String: Any]] {
        guard let cStr else { return [] }
        let str = String(cString: cStr)
        guard let data = str.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr
    }
}

// MARK: - C Callback Implementations

// These are free functions matching the PlatformCallbacks signatures.
// They bridge to Swift's networking/notification APIs.

private func nativeHttpRequest(
    _ method: UnsafePointer<CChar>?,
    _ url: UnsafePointer<CChar>?,
    _ headers: UnsafePointer<CChar>?,
    _ body: UnsafePointer<CChar>?,
    _ onComplete: (@convention(c) (UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Void)?,
    _ ctx: UnsafeMutableRawPointer?
) {
    guard let url, let method else {
        onComplete?(nil, -1, ctx)
        return
    }

    let urlStr = String(cString: url)
    let methodStr = String(cString: method)
    let bodyStr = body.map { String(cString: $0) }
    let headersStr = headers.map { String(cString: $0) }

    guard let requestUrl = URL(string: urlStr) else {
        onComplete?(nil, -1, ctx)
        return
    }

    var request = URLRequest(url: requestUrl)
    request.httpMethod = methodStr
    request.timeoutInterval = 30

    if let headersStr, !headersStr.isEmpty {
        // Parse "Key: Value\r\n" headers
        for line in headersStr.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                request.setValue(parts[1].trimmingCharacters(in: .whitespaces),
                                forHTTPHeaderField: String(parts[0]))
            }
        }
    }

    if let bodyStr, !bodyStr.isEmpty {
        request.httpBody = bodyStr.data(using: .utf8)
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }

    // Retain context across async boundary
    let retainedCtx = ctx

    URLSession.shared.dataTask(with: request) { data, response, error in
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let data, let str = String(data: data, encoding: .utf8) {
            str.withCString { cStr in
                onComplete?(cStr, Int32(status), retainedCtx)
            }
        } else {
            let errStr = error?.localizedDescription ?? "unknown error"
            errStr.withCString { cStr in
                onComplete?(cStr, Int32(status), retainedCtx)
            }
        }
    }.resume()
}

private func nativeWebSocketSend(_ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let str = String(cString: message)
    DiscordService.shared.send(str)
}

private func nativeSendNotification(_ title: UnsafePointer<CChar>?, _ body: UnsafePointer<CChar>?) {
    let t = title.map { String(cString: $0) } ?? ""
    let b = body.map { String(cString: $0) } ?? ""
    NotificationService.shared.send(title: t, body: b)
}

private func nativeScheduleTimer(_ seconds: Double, _ timerId: Int32) {
    TimerService.shared.schedule(seconds: seconds, id: timerId)
}

private func nativeCancelTimer(_ timerId: Int32) {
    TimerService.shared.cancel(id: timerId)
}

private func nativeAddReaction(
    _ channelId: UnsafePointer<CChar>?,
    _ messageId: UnsafePointer<CChar>?,
    _ emoji: UnsafePointer<CChar>?
) {
    guard let channelId, let messageId, let emoji else { return }
    let c = String(cString: channelId)
    let m = String(cString: messageId)
    let e = String(cString: emoji)
    DiscordService.shared.addReaction(channelId: c, messageId: m, emoji: e)
}

private func nativeRemoveReaction(
    _ channelId: UnsafePointer<CChar>?,
    _ messageId: UnsafePointer<CChar>?,
    _ emoji: UnsafePointer<CChar>?
) {
    guard let channelId, let messageId, let emoji else { return }
    let c = String(cString: channelId)
    let m = String(cString: messageId)
    let e = String(cString: emoji)
    DiscordService.shared.removeReaction(channelId: c, messageId: m, emoji: e)
}
