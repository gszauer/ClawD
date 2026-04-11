import SwiftUI

struct LogsTab: View {
    @Bindable private var state = AppState.shared
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all, info, warning, error
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var filtered: [AppState.LogEntry] {
        guard filter != .all else { return state.logs }
        return state.logs.filter { $0.level.rawValue == filter.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                Spacer()

                Text("\(filtered.count) of \(state.logs.count)")
                    .font(.caption).foregroundStyle(.secondary)

                Button {
                    state.clearLogs()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.logs.isEmpty)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if filtered.isEmpty {
                            Text("No log entries.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        } else {
                            ForEach(filtered) { entry in
                                row(entry).id(entry.id)
                            }
                        }
                    }
                    .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.controlBackgroundColor).opacity(0.5)))
                .onChange(of: state.logs.count) { _, _ in
                    if let last = filtered.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: AppState.LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(for: entry.level))
                .foregroundStyle(color(for: entry.level))
                .font(.caption)
                .frame(width: 14)
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(entry.message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(color(for: entry.level).opacity(0.06)))
    }

    private func icon(for level: AppState.LogLevel) -> String {
        switch level {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    private func color(for level: AppState.LogLevel) -> Color {
        switch level {
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
