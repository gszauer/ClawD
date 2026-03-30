import SwiftUI

struct ChoresTab: View {
    @Bindable private var state = AppState.shared
    @State private var selectedId: String?
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newColor = "green"
    @State private var newRecurrence = "weekly"
    @State private var newDay = "monday"
    @State private var newContent = ""
    @State private var editText = ""

    private let colors = ["green", "blue", "pink"]
    private let recurrences = ["weekly", "biweekly", "monthly", "one-shot"]
    private let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    private var isEditing: Bool { state.isEditing }

    var body: some View {
        HSplitView {
            // List
            VStack {
                List(state.chores, id: \.choreId, selection: selectionBinding) { chore in
                    HStack {
                        Circle()
                            .fill(colorForName(chore["color"] as? String ?? "green"))
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading) {
                            Text(chore.choreTitle).fontWeight(.medium)
                            HStack(spacing: 4) {
                                Text(chore["recurrence"] as? String ?? "")
                                if let day = chore["day"] as? String {
                                    Text("- \(day)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if let last = chore["completed_last"] as? String, !last.isEmpty {
                            Text(last)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button { guardAction { showingAdd = true } } label: {
                        Image(systemName: "plus").frame(width: 20, height: 20)
                    }
                    Button { guardAction { completeSelected() } } label: {
                        Image(systemName: "checkmark").frame(width: 20, height: 20)
                    }
                    .disabled(selectedId == nil)
                    .help("Mark complete")
                    Button { guardAction { deleteSelected() } } label: {
                        Image(systemName: "minus").frame(width: 20, height: 20)
                    }
                    .disabled(selectedId == nil)
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 180, idealWidth: 230, maxWidth: 300)

            // Detail
            if let id = selectedId {
                VStack(alignment: .leading, spacing: 0) {
                    if isEditing {
                        TextEditor(text: $editText)
                            .font(.body.monospaced())
                            .padding(4)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if let chore = state.chores.first(where: { $0.choreId == id }) {
                                    Text(chore.choreTitle)
                                        .font(.title2)
                                        .fontWeight(.bold)

                                    HStack {
                                        Circle()
                                            .fill(colorForName(chore["color"] as? String ?? "green"))
                                            .frame(width: 12, height: 12)
                                        Text(chore["recurrence"] as? String ?? "")
                                        if let day = chore["day"] as? String {
                                            Text("- \(day)")
                                        }
                                    }
                                    .font(.callout)
                                    .foregroundStyle(.secondary)

                                    if let last = chore["completed_last"] as? String, !last.isEmpty {
                                        Text("Last completed: \(last)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Divider()
                                }

                                Text(itemBody(id: id))
                                    .textSelection(.enabled)
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
                Text("Select a chore")
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
        let path = "\(state.workingDirectory)/chores/\(id).md"
        editText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        state.isEditing = true
    }

    private func cancelEdit() {
        state.isEditing = false
        editText = ""
    }

    private func saveEdit(id: String) {
        let path = "\(state.workingDirectory)/chores/\(id).md"
        let validated = EditHelpers.validate(editText, type: .chore)
        try? validated.write(toFile: path, atomically: true, encoding: .utf8)
        state.isEditing = false
        editText = ""
        core_reload_data()
        state.refreshData()
    }

    private func itemBody(id: String) -> String {
        let path = "\(state.workingDirectory)/chores/\(id).md"
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private var addSheet: some View {
        VStack(spacing: 12) {
            Text("New Chore").font(.headline)

            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Picker("Color", selection: $newColor) {
                    ForEach(colors, id: \.self) { c in
                        HStack {
                            Circle().fill(colorForName(c)).frame(width: 8, height: 8)
                            Text(c)
                        }
                    }
                }

                Picker("Recurrence", selection: $newRecurrence) {
                    ForEach(recurrences, id: \.self) { Text($0) }
                }
            }

            if newRecurrence == "weekly" || newRecurrence == "biweekly" {
                Picker("Day", selection: $newDay) {
                    ForEach(days, id: \.self) { Text($0.capitalized) }
                }
            }

            TextEditor(text: $newContent)
                .frame(minHeight: 80)
                .border(Color.secondary.opacity(0.3))

            HStack {
                Button("Cancel") { showingAdd = false }
                Spacer()
                Button("Add") { addChore() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func addChore() {
        guard CoreBridge.shared.isRunning else { return }
        let day = (newRecurrence == "weekly" || newRecurrence == "biweekly") ? newDay : ""
        CoreBridge.shared.executeTool("add_chore", params: [newName, newColor, newRecurrence, day])
        newName = ""
        newContent = ""
        showingAdd = false
        state.refreshData()
    }

    private func completeSelected() {
        guard let id = selectedId, CoreBridge.shared.isRunning else { return }
        CoreBridge.shared.executeTool("complete_chore", params: [id])
        state.refreshData()
    }

    private func deleteSelected() {
        guard let id = selectedId, CoreBridge.shared.isRunning else { return }
        CoreBridge.shared.executeTool("delete_chore", params: [id])
        selectedId = nil
        state.refreshData()
    }

    private func colorForName(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "blue": return .blue
        case "pink": return .pink
        default: return .green
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    var choreId: String { self["id"] as? String ?? "" }
    var choreTitle: String { self["title"] as? String ?? "(untitled)" }
}
