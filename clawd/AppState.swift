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

    // Non-blocking error/status toast with simple queue so rapid toasts
    // don't silently overwrite each other.
    var toastMessage: String = ""
    var toastIsError: Bool = false
    private var toastTimer: Timer?
    private var toastQueue: [(message: String, isError: Bool)] = []

    // Error log — populated whenever showToast is called with isError = true.
    // Persists in memory for the session so users can review what went wrong
    // after the toast has disappeared.
    struct LoggedError: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }
    var errorLog: [LoggedError] = []

    func showToast(_ message: String, isError: Bool = false) {
        print("[Toast] \(isError ? "ERROR: " : "")\(message)")
        DispatchQueue.main.async {
            if isError {
                self.errorLog.append(LoggedError(timestamp: Date(), message: message))
                // Cap to prevent unbounded growth in long sessions.
                if self.errorLog.count > 500 {
                    self.errorLog.removeFirst(self.errorLog.count - 500)
                }
            }
            if self.toastMessage.isEmpty {
                self.presentToast(message, isError: isError)
            } else {
                self.toastQueue.append((message, isError))
            }
        }
    }

    private func presentToast(_ message: String, isError: Bool) {
        toastMessage = message
        toastIsError = isError
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: isError ? 10 : 4, repeats: false) { _ in
            self.toastMessage = ""
            // Show next queued toast after a brief pause so the user sees
            // the transition.
            if !self.toastQueue.isEmpty {
                let next = self.toastQueue.removeFirst()
                Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                    self.presentToast(next.message, isError: next.isError)
                }
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
    var gemmaModelPath: String = ""
    var gemmaMmprojPath: String = ""
    var gemmaNCtx: Int = 0           // 0 = use model's trained maximum
    var showThinking: Bool = false   // leave <think>...</think> blocks in responses
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

    // Weather
    var weatherEnabled: Bool = false
    var weatherZip: String = ""

    // Web Search (DuckDuckGo Lite, no API key)
    var webSearchEnabled: Bool = true
    var webSearchMaxResults: Int = 5

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

    // Available model files (scanned from working/models/)
    var availableGemmaModels: [String] = []
    var availableWhisperModels: [String] = []

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

        let validAudio = Set(["whisper", "off"])

        gemmaModelPath = json["gemma_model_path"] as? String ?? ""
        gemmaMmprojPath = json["gemma_mmproj_path"] as? String ?? ""
        gemmaNCtx = json["gemma_n_ctx"] as? Int ?? 0
        showThinking = json["show_thinking"] as? Bool ?? false
        audioBackend = validAudio.contains(json["audio_backend"] as? String ?? "") ? json["audio_backend"] as! String : "off"
        whisperModelPath = json["whisper_model_path"] as? String ?? ""
        weatherEnabled = json["weather_enabled"] as? Bool ?? false
        weatherZip = json["weather_zip"] as? String ?? ""
        webSearchEnabled = json["web_search_enabled"] as? Bool ?? false
        webSearchMaxResults = json["web_search_max_results"] as? Int ?? 5

        scanAvailableModels()
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
        }
    }

    func saveConfig() {
        let json: [String: Any] = [
            "gemma_model_path": gemmaModelPath,
            "gemma_mmproj_path": gemmaMmprojPath,
            "gemma_n_ctx": gemmaNCtx,
            "show_thinking": showThinking,
            "audio_backend": audioBackend,
            "weather_enabled": weatherEnabled,
            "weather_zip": weatherZip,
            "web_search_enabled": webSearchEnabled,
            "web_search_max_results": webSearchMaxResults,
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

    func scanAvailableModels() {
        let wd = workingDirectory.isEmpty ? AppState.defaultWorkingDirectory : workingDirectory
        let modelsDir = "\(wd)/models"
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir)) ?? []

        availableGemmaModels = contents
            .filter { $0.hasSuffix(".gguf") && !$0.contains("mmproj") }
            .sorted()

        availableWhisperModels = contents
            .filter { $0.hasPrefix("whisper-") && $0.hasSuffix(".bin") }
            .sorted()

        // Clear selections that point at files no longer on disk.
        if !gemmaModelPath.isEmpty && !availableGemmaModels.contains(gemmaModelPath) {
            gemmaModelPath = ""
            gemmaMmprojPath = ""
        }
        if !whisperModelPath.isEmpty && !availableWhisperModels.contains(whisperModelPath) {
            whisperModelPath = ""
            audioBackend = "off"
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
