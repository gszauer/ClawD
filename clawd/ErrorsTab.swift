import SwiftUI

struct ErrorsTab: View {
    @Bindable private var state = AppState.shared

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Errors")
                    .font(.headline)
                Spacer()
                Text("\(state.errorLog.count) logged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    state.errorLog.removeAll()
                }
                .disabled(state.errorLog.isEmpty)
            }
            .padding(12)
            Divider()

            if state.errorLog.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No errors logged")
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Newest first
                        ForEach(state.errorLog.reversed()) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.message)
                                        .font(.body.monospaced())
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(Self.timeFormatter.string(from: entry.timestamp))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}
