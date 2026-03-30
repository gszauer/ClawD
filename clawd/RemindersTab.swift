import SwiftUI

struct RemindersTab: View {
    @Bindable private var state = AppState.shared
    @State private var selectedId: String?
    @State private var showingAdd = false
    @State private var newMessage = ""
    @State private var newDate = Date().addingTimeInterval(3600)
    @State private var editText = ""

    private var isEditing: Bool { state.isEditing }

    private var pendingReminders: [[String: Any]] {
        state.reminders.filter { ($0["status"] as? String) == "pending" }
    }

    private var pastReminders: [[String: Any]] {
        state.reminders.filter { ($0["status"] as? String) != "pending" }
    }

    var body: some View {
        HSplitView {
            // List
            VStack(alignment: .leading) {
                List(selection: selectionBinding) {
                    if !pendingReminders.isEmpty {
                        Section("Pending") {
                            ForEach(pendingReminders, id: \.reminderId) { rem in
                                reminderRow(rem, isPending: true)
                            }
                        }
                    }

                    if !pastReminders.isEmpty {
                        Section("Past") {
                            ForEach(pastReminders, id: \.reminderId) { rem in
                                reminderRow(rem, isPending: false)
                            }
                        }
                    }
                }

                HStack {
                    Button { guardAction { showingAdd = true } } label: {
                        Image(systemName: "plus").frame(width: 20, height: 20)
                    }
                    Button { guardAction { deleteSelected() } } label: {
                        Image(systemName: "minus").frame(width: 20, height: 20)
                    }
                    .disabled(selectedId == nil)
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 300)

            // Detail
            if let id = selectedId, let rem = state.reminders.first(where: { $0.reminderId == id }) {
                VStack(alignment: .leading, spacing: 0) {
                    if isEditing {
                        TextEditor(text: $editText)
                            .font(.body.monospaced())
                            .padding(4)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(rem.reminderTitle)
                                    .font(.title2)
                                    .fontWeight(.bold)

                                if let dt = rem["datetime"] as? String {
                                    Label(dt, systemImage: "clock")
                                        .font(.callout)
                                }

                                if let status = rem["status"] as? String {
                                    Label(status.capitalized, systemImage: status == "pending" ? "circle" : "checkmark.circle.fill")
                                        .foregroundStyle(status == "pending" ? .orange : .green)
                                }

                                if let rec = rem["recurrence"] as? String, rec != "once", !rec.isEmpty {
                                    Label("Recurring: \(rec)", systemImage: "repeat")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }

                                Divider()

                                Text(reminderBody(id: id))
                                    .textSelection(.enabled)

                                Spacer()
                            }
                            .padding()
                        }
                    }

                    Divider()

                    HStack {
                        Spacer()
                        if isEditing {
                            Button("Cancel") { cancelEdit() }
                            Button("Save") { saveEdit(id: id) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Edit") { startEdit(id: id) }
                        }
                    }
                    .padding(8)
                }
            } else {
                Text("Select a reminder")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingAdd) { addSheet }
        .onAppear { state.refreshData() }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selectedId },
            set: { newVal in
                if isEditing { state.showToast("Finish editing first") }
                else { selectedId = newVal }
            }
        )
    }

    private func guardAction(_ action: () -> Void) {
        if isEditing { state.showToast("Finish editing first") }
        else { action() }
    }

    private func startEdit(id: String) {
        let path = "\(state.workingDirectory)/reminders/\(id).md"
        editText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        state.isEditing = true
    }

    private func cancelEdit() {
        state.isEditing = false
        editText = ""
    }

    private func saveEdit(id: String) {
        let path = "\(state.workingDirectory)/reminders/\(id).md"
        let validated = EditHelpers.validate(editText, type: .reminder)
        try? validated.write(toFile: path, atomically: true, encoding: .utf8)
        state.isEditing = false
        editText = ""
        core_reload_data()
        state.refreshData()
    }

    private func reminderRow(_ rem: [String: Any], isPending: Bool) -> some View {
        HStack {
            Image(systemName: isPending ? "bell" : "bell.slash")
                .foregroundStyle(isPending ? .orange : .secondary)

            VStack(alignment: .leading) {
                Text(rem.reminderTitle).fontWeight(.medium)
                if let dt = rem["datetime"] as? String {
                    Text(dt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tag(rem.reminderId)
    }

    private var addSheet: some View {
        VStack(spacing: 12) {
            Text("New Reminder").font(.headline)

            TextField("Message", text: $newMessage)
                .textFieldStyle(.roundedBorder)

            DatePicker("When", selection: $newDate, displayedComponents: [.date, .hourAndMinute])

            HStack {
                Button("Cancel") { showingAdd = false }
                Spacer()
                Button("Set") { addReminder() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newMessage.isEmpty)
            }
        }
        .padding()
        .frame(width: 350)
    }

    private func addReminder() {
        guard CoreBridge.shared.isRunning else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let dt = formatter.string(from: newDate)

        CoreBridge.shared.executeTool("set_reminder", params: [newMessage, dt])
        newMessage = ""
        showingAdd = false
        state.refreshData()
    }

    private func deleteSelected() {
        guard let id = selectedId, CoreBridge.shared.isRunning else { return }
        CoreBridge.shared.executeTool("delete_reminder", params: [id])
        selectedId = nil
        state.refreshData()
    }

    private func reminderBody(id: String) -> String {
        let wd = state.workingDirectory
        return (try? String(contentsOfFile: "\(wd)/reminders/\(id).md", encoding: .utf8)) ?? ""
    }
}

extension Dictionary where Key == String, Value == Any {
    var reminderId: String { self["id"] as? String ?? "" }
    var reminderTitle: String { self["title"] as? String ?? "(untitled)" }
}
