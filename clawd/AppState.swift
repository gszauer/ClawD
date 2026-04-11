import Foundation
import SwiftUI

/// Shared observable state for the app UI. Bridges the C core's data into SwiftUI.
@Observable
final class AppState {
    static let shared = AppState()

    var workingDirectory: String = ""

    var configPath: String {
        let wd = workingDirectory.isEmpty ? AppState.defaultWorkingDirectory : workingDirectory
        return wd + "/config.json"
    }

    var tmpDirectory: String {
        let wd = workingDirectory.isEmpty ? AppState.defaultWorkingDirectory : workingDirectory
        return wd + "/tmp"
    }

    // Editing state — blocks tab switching and other actions
    var isEditing = false

    // Non-blocking error/status toast
    var toastMessage: String = ""
    var toastIsError: Bool = false
    private var toastTimer: Timer?

    // Session log (in-memory only, never persisted)
    enum LogLevel: String { case info, warning, error }
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let message: String
    }
    var logs: [LogEntry] = []
    private let maxLogs = 500

    func appendLog(_ message: String, level: LogLevel) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        DispatchQueue.main.async {
            self.logs.append(entry)
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst(self.logs.count - self.maxLogs)
            }
        }
    }

    func clearLogs() {
        DispatchQueue.main.async { self.logs.removeAll() }
    }

    func showToast(_ message: String, isError: Bool = false) {
        print("[Toast] \(isError ? "ERROR: " : "")\(message)")
        appendLog(message, level: isError ? .error : .info)
        DispatchQueue.main.async {
            self.toastMessage = message
            self.toastIsError = isError
            self.toastTimer?.invalidate()
            self.toastTimer = Timer.scheduledTimer(withTimeInterval: isError ? 10 : 7, repeats: false) { _ in
                self.toastMessage = ""
            }
        }
    }

    func showWarning(_ message: String) {
        print("[Warning] \(message)")
        appendLog(message, level: .warning)
        DispatchQueue.main.async {
            self.toastMessage = message
            self.toastIsError = false
            self.toastTimer?.invalidate()
            self.toastTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
                self.toastMessage = ""
            }
        }
    }

    /// Absolute path next to the app bundle. Computed once at launch.
    static let defaultWorkingDirectory: String = {
        if let bundlePath = Bundle.main.bundlePath as NSString? {
            let parent = bundlePath.deletingLastPathComponent
            return (parent as NSString).appendingPathComponent("working")
        }
        return NSHomeDirectory() + "/clawd/working"
    }()

    // Config fields
    var backend: String = "claude"
    var backendCliPath: String = "/Users/user/.local/bin/claude"
    var backendApiUrl: String = ""
    var backendApiKey: String = ""
    var backendApiModel: String = ""
    var embeddingMode: String = "API"
    var embeddingUrl: String = "http://localhost:1234/v1/embeddings"
    var embeddingModel: String = "text-embedding-embeddinggemma-300m"
    var embeddingModelPath: String = ""
    var audioBackend: String = "off"
    var whisperModelPath: String = ""
    var assistantName: String = "ClawD"
    var assistantEmoji: String = "🦀"
    var discordBotToken: String = ""
    var discordChannelId: String = ""
    var calendarId: String = ""
    var calendarSyncInterval: Int = 20

    // Tuning
    var chatHistoryExchanges: Int = 25
    var heartbeatIntervalSeconds: Int = 30
    var noteSearchResults: Int = 5
    var maxNotesInIndex: Int = 10000

    // Notification toggles
    var dailyReportEnabled: Bool = false
    var dailyReportTime: Date = AppState.timeFromHHMM("07:00")
    var calendarHeadsUpEnabled: Bool = false
    var calendarHeadsUpMinutes: Int = 30
    var mealPrepEnabled: Bool = false
    var mealPrepTime: Date = AppState.timeFromHHMM("15:00")
    var overdueChoresEnabled: Bool = false
    var overdueChoresTime: Date = AppState.timeFromHHMM("10:00")
    var endOfDayEnabled: Bool = false
    var endOfDayTime: Date = AppState.timeFromHHMM("21:00")
    var weatherEnabled: Bool = false
    var weatherZipCode: String = ""

    // Data arrays for UI
    var meals: [[String: Any]] = []
    var chores: [[String: Any]] = []
    var reminders: [[String: Any]] = []
    var notes: [[String: Any]] = []
    var calendarEvents: [CalEvent] = []
    var chatLog: String = ""

    private init() {}

    // MARK: - Config I/O

    func loadConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let validBackends = Set(["claude", "gemini", "codex", "API"])
        let validEmbedding = Set(["API", "local", "off"])
        let validAudio = Set(["whisper", "off"])

        backend = validBackends.contains(json["backend"] as? String ?? "") ? json["backend"] as! String : "claude"
        backendCliPath = json["backend_cli_path"] as? String ?? ""
        backendApiUrl = json["backend_api_url"] as? String ?? ""
        backendApiKey = json["backend_api_key"] as? String ?? ""
        backendApiModel = json["backend_api_model"] as? String ?? ""
        embeddingMode = validEmbedding.contains(json["embedding_mode"] as? String ?? "") ? json["embedding_mode"] as! String : "API"
        embeddingUrl = json["embedding_url"] as? String ?? ""
        embeddingModel = json["embedding_model"] as? String ?? ""
        embeddingModelPath = json["embedding_model_path"] as? String ?? ""
        audioBackend = validAudio.contains(json["audio_backend"] as? String ?? "") ? json["audio_backend"] as! String : "off"
        whisperModelPath = json["whisper_model_path"] as? String ?? ""
        assistantName = json["assistant_name"] as? String ?? "ClawD"
        assistantEmoji = json["assistant_emoji"] as? String ?? "🦀"
        discordBotToken = json["discord_bot_token"] as? String ?? ""
        discordChannelId = json["discord_channel_id"] as? String ?? ""
        calendarId = json["calendar_id"] as? String ?? ""
        calendarSyncInterval = json["calendar_sync_interval_minutes"] as? Int ?? 20

        chatHistoryExchanges = json["chat_history_exchanges"] as? Int ?? 25
        heartbeatIntervalSeconds = json["heartbeat_interval_seconds"] as? Int ?? 30
        noteSearchResults = json["note_search_results"] as? Int ?? 5
        maxNotesInIndex = json["max_notes_in_index"] as? Int ?? 10000

        if let notifs = json["notifications"] as? [String: [String: Any]] {
            if let dr = notifs["daily_report"] {
                dailyReportEnabled = dr["enabled"] as? Bool ?? false
                if let t = dr["time"] as? String { dailyReportTime = AppState.timeFromHHMM(t) }
            }
            if let ch = notifs["calendar_heads_up"] {
                calendarHeadsUpEnabled = ch["enabled"] as? Bool ?? false
                calendarHeadsUpMinutes = ch["minutes_before"] as? Int ?? 30
            }
            if let mp = notifs["meal_prep_reminder"] {
                mealPrepEnabled = mp["enabled"] as? Bool ?? false
                if let t = mp["time"] as? String { mealPrepTime = AppState.timeFromHHMM(t) }
            }
            if let oc = notifs["overdue_chores"] {
                overdueChoresEnabled = oc["enabled"] as? Bool ?? false
                if let t = oc["time"] as? String { overdueChoresTime = AppState.timeFromHHMM(t) }
            }
            if let ed = notifs["end_of_day_summary"] {
                endOfDayEnabled = ed["enabled"] as? Bool ?? false
                if let t = ed["time"] as? String { endOfDayTime = AppState.timeFromHHMM(t) }
            }
            if let w = notifs["weather"] {
                weatherEnabled = w["enabled"] as? Bool ?? false
                weatherZipCode = w["zip_code"] as? String ?? ""
            }
        }
    }

    func saveConfig() {
        let json: [String: Any] = [
            "backend": backend,
            "backend_cli_path": backendCliPath,
            "backend_api_url": backendApiUrl,
            "backend_api_key": backendApiKey,
            "backend_api_model": backendApiModel,
            "embedding_mode": embeddingMode,
            "embedding_url": embeddingUrl,
            "embedding_model": embeddingModel,
            "embedding_model_path": embeddingModelPath,
            "audio_backend": audioBackend,
            "whisper_model_path": whisperModelPath,
            "assistant_name": assistantName,
            "assistant_emoji": assistantEmoji,
            "discord_bot_token": discordBotToken,
            "discord_channel_id": discordChannelId,
            "calendar_id": calendarId,
            "calendar_sync_interval_minutes": calendarSyncInterval,
            "chat_history_exchanges": chatHistoryExchanges,
            "heartbeat_interval_seconds": heartbeatIntervalSeconds,
            "note_search_results": noteSearchResults,
            "max_notes_in_index": maxNotesInIndex,
            "notifications": [
                "daily_report": [
                    "enabled": dailyReportEnabled,
                    "time": Self.hhmmFromDate(dailyReportTime)
                ],
                "calendar_heads_up": [
                    "enabled": calendarHeadsUpEnabled,
                    "minutes_before": calendarHeadsUpMinutes
                ],
                "meal_prep_reminder": [
                    "enabled": mealPrepEnabled,
                    "time": Self.hhmmFromDate(mealPrepTime)
                ],
                "overdue_chores": [
                    "enabled": overdueChoresEnabled,
                    "time": Self.hhmmFromDate(overdueChoresTime)
                ],
                "end_of_day_summary": [
                    "enabled": endOfDayEnabled,
                    "time": Self.hhmmFromDate(endOfDayTime)
                ],
                "weather": [
                    "enabled": weatherEnabled,
                    "zip_code": weatherZipCode
                ]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
        else { return }

        try? data.write(to: URL(fileURLWithPath: configPath))

        // Notify core of config change
        if CoreBridge.shared.isRunning {
            CoreBridge.shared.reloadConfig()
        }
    }

    func refreshData() {
        guard CoreBridge.shared.isRunning else { return }
        meals = CoreBridge.shared.getMeals()
        chores = CoreBridge.shared.getChores()
        reminders = CoreBridge.shared.getReminders()
        notes = CoreBridge.shared.getNotes()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: Date())
        let log = CoreBridge.shared.getChatHistory(date: dateStr)
        chatLog = log

        // Reload calendar cache
        let cachePath = "\(workingDirectory)/calendar_cache.json"
        if let cacheData = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
           let cacheJson = try? JSONSerialization.jsonObject(with: cacheData) as? [String: Any],
           let evts = cacheJson["events"] as? [[String: Any]] {
            calendarEvents = evts.map { CalEvent(dict: $0) }.sorted { $0.startRaw < $1.startRaw }
        } else {
            calendarEvents = []
        }
    }

    // MARK: - Time Helpers

    static func timeFromHHMM(_ str: String) -> Date {
        let parts = str.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1])
        else { return Date() }

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = h
        comps.minute = m
        return Calendar.current.date(from: comps) ?? Date()
    }

    static func hhmmFromDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}
