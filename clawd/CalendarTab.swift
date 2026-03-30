import SwiftUI

struct CalendarTab: View {
    @Bindable private var state = AppState.shared
    @State private var lastSyncTime: String = "Never"
    @State private var isSyncing = false

    private var daysToShow: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private func eventsForDate(_ date: Date) -> [CalEvent] {
        let cal = Calendar.current
        return state.calendarEvents.filter { evt in
            guard let evtDate = evt.startDate else { return false }
            return cal.isDate(evtDate, inSameDayAs: date)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Calendar")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Text("Last sync: \(lastSyncTime)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Sync Now") { syncCalendar() }
                        .disabled(!CoreBridge.shared.isRunning)
                }
            }
            .padding()

            Divider()

            if !CoreBridge.shared.isRunning {
                placeholder("Start the app to view calendar")
            } else if !hasCredentials {
                placeholder("Add a service account JSON in the General tab")
            } else if state.calendarEvents.isEmpty && !isSyncing {
                placeholder("No events. Click Sync Now to fetch from Google Calendar.")
            } else {
                List {
                    ForEach(daysToShow, id: \.self) { date in
                        let dayEvents = eventsForDate(date)
                        Section {
                            if dayEvents.isEmpty {
                                Text("No events")
                                    .foregroundStyle(.tertiary)
                                    .font(.caption)
                            } else {
                                ForEach(dayEvents) { evt in
                                    HStack(alignment: .top, spacing: 8) {
                                        VStack(alignment: .trailing) {
                                            Text(evt.startTimeFormatted)
                                                .font(.caption.monospacedDigit())
                                                .fontWeight(.medium)
                                            if !evt.endTimeFormatted.isEmpty {
                                                Text(evt.endTimeFormatted)
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(width: 50, alignment: .trailing)

                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(evt.localOnly ? Color.orange : Color.blue)
                                            .frame(width: 3)

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 4) {
                                                Text(evt.summary)
                                                    .fontWeight(.medium)
                                                if evt.localOnly {
                                                    Text("local")
                                                        .font(.caption2)
                                                        .padding(.horizontal, 4)
                                                        .padding(.vertical, 1)
                                                        .background(Color.orange.opacity(0.2))
                                                        .cornerRadius(3)
                                                        .foregroundStyle(.orange)
                                                }
                                            }
                                            if !evt.location.isEmpty {
                                                Label(evt.location, systemImage: "mappin")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(dayHeader(date))
                                    .fontWeight(Calendar.current.isDateInToday(date) ? .bold : .regular)
                                if Calendar.current.isDateInToday(date) {
                                    Text("Today")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { state.refreshData() }
    }

    private var hasCredentials: Bool {
        FileManager.default.fileExists(atPath: "\(state.workingDirectory)/calendar.json")
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func syncCalendar() {
        isSyncing = true
        DispatchQueue.global(qos: .userInitiated).async {
            if let token = CalendarAuth.shared.getAccessToken() {
                core_set_calendar_token(token)
            }
            let ok = core_calendar_sync()
            DispatchQueue.main.async {
                isSyncing = false
                let df = DateFormatter()
                df.dateFormat = "HH:mm:ss"
                lastSyncTime = df.string(from: Date())
                state.refreshData()

                if ok == 0 {
                    AppState.shared.showToast("Calendar sync failed — check logs", isError: true)
                } else {
                    AppState.shared.showToast("Calendar synced")
                }
            }
        }
    }

    private func dayHeader(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d"
        return df.string(from: date)
    }
}

// MARK: - CalEvent model

struct CalEvent: Identifiable {
    let id: String
    let summary: String
    let startRaw: String
    let endRaw: String
    let location: String
    let localOnly: Bool

    init(dict: [String: Any]) {
        id = dict["id"] as? String ?? UUID().uuidString
        summary = dict["summary"] as? String ?? "(no title)"
        startRaw = dict["start"] as? String ?? ""
        endRaw = dict["end"] as? String ?? ""
        location = dict["location"] as? String ?? ""
        localOnly = dict["local_only"] as? Bool ?? false
    }

    var startDate: Date? { Self.parseISO(startRaw) }
    var startTimeFormatted: String { Self.formatTime(startRaw) }
    var endTimeFormatted: String { Self.formatTime(endRaw) }

    private static func parseISO(_ str: String) -> Date? {
        let formatters: [DateFormatter] = {
            let f1 = DateFormatter()
            f1.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            let f2 = DateFormatter()
            f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let f3 = DateFormatter()
            f3.dateFormat = "yyyy-MM-dd"
            return [f1, f2, f3]
        }()
        for f in formatters { if let d = f.date(from: str) { return d } }
        return nil
    }

    private static func formatTime(_ str: String) -> String {
        guard let date = parseISO(str) else { return "" }
        if !str.contains("T") { return "all day" }
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: date)
    }
}
