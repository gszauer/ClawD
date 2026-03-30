import SwiftUI

struct MealsTab: View {
    @Bindable private var state = AppState.shared
    @State private var selectedId: String?
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newType = "home"
    @State private var newContent = ""
    @State private var editText = ""

    private let mealTypes = ["home", "delivery"]
    private var isEditing: Bool { state.isEditing }

    var body: some View {
        HSplitView {
            // List
            VStack {
                List(state.meals, id: \.mealId, selection: selectionBinding) { meal in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(meal.mealTitle).fontWeight(.medium)
                            Text(meal["type"] as? String ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let slot = meal["slot"] as? String {
                            Text("Slot \(slot)")
                                .font(.caption2)
                                .padding(4)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(4)
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
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)

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
                                if let meal = state.meals.first(where: { $0.mealId == id }) {
                                    Text(meal.mealTitle)
                                        .font(.title2)
                                        .fontWeight(.bold)

                                    HStack {
                                        if let type = meal["type"] as? String {
                                            Label(type, systemImage: "fork.knife")
                                                .font(.caption)
                                        }
                                        if let days = meal["days"] as? String {
                                            Label("Days: \(days)", systemImage: "calendar")
                                                .font(.caption)
                                        }
                                    }
                                    .foregroundStyle(.secondary)

                                    Divider()
                                }

                                Text(itemBody(id: id, subdir: "meals"))
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
                            Button("Save") { saveEdit(id: id, subdir: "meals") }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Edit") { startEdit(id: id, subdir: "meals") }
                        }
                    }
                    .padding(8)
                }
            } else {
                Text("Select a meal")
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

    private func startEdit(id: String, subdir: String) {
        let path = "\(state.workingDirectory)/\(subdir)/\(id).md"
        editText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        state.isEditing = true
    }

    private func cancelEdit() {
        state.isEditing = false
        editText = ""
    }

    private func saveEdit(id: String, subdir: String) {
        let path = "\(state.workingDirectory)/\(subdir)/\(id).md"
        let validated = EditHelpers.validate(editText, type: .meal)
        try? validated.write(toFile: path, atomically: true, encoding: .utf8)
        state.isEditing = false
        editText = ""
        core_reload_data()
        state.refreshData()
    }

    private func itemBody(id: String, subdir: String) -> String {
        let path = "\(state.workingDirectory)/\(subdir)/\(id).md"
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private var addSheet: some View {
        VStack(spacing: 12) {
            Text("New Meal").font(.headline)

            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)

            Picker("Type", selection: $newType) {
                ForEach(mealTypes, id: \.self) { Text($0) }
            }

            TextEditor(text: $newContent)
                .frame(minHeight: 100)
                .border(Color.secondary.opacity(0.3))

            HStack {
                Button("Cancel") { showingAdd = false }
                Spacer()
                Button("Add") { addMeal() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func addMeal() {
        guard CoreBridge.shared.isRunning else { return }
        CoreBridge.shared.executeTool("add_meal", params: [newName, newType, newContent, ""])
        newName = ""
        newContent = ""
        showingAdd = false
        state.refreshData()
    }

    private func deleteSelected() {
        guard let id = selectedId, CoreBridge.shared.isRunning else { return }
        CoreBridge.shared.executeTool("delete_meal", params: [id])
        selectedId = nil
        state.refreshData()
    }
}

extension Dictionary where Key == String, Value == Any {
    var mealId: String { self["id"] as? String ?? "" }
    var mealTitle: String { self["title"] as? String ?? "(untitled)" }
}
