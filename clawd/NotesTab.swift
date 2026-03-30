import SwiftUI

struct NotesTab: View {
    @Bindable private var state = AppState.shared
    @State private var selectedId: String?
    @State private var showingAdd = false
    @State private var newTitle = ""
    @State private var newContent = ""
    @State private var newTags = ""
    @State private var editText = ""

    private var isEditing: Bool { state.isEditing }

    var body: some View {
        HSplitView {
            // List
            VStack {
                List(state.notes, id: \.noteId, selection: selectionBinding) { note in
                    VStack(alignment: .leading) {
                        Text(note.noteTitle).fontWeight(.medium)
                        if let tags = note["tags"] as? String, !tags.isEmpty {
                            Text(tags)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                    Button { guardAction { reindexAll() } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath").frame(width: 20, height: 20)
                    }
                    .help("Reindex all note embeddings")
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)

            // Detail
            if let id = selectedId, let note = state.notes.first(where: { $0.noteId == id }) {
                VStack(alignment: .leading, spacing: 0) {
                    if isEditing {
                        TextEditor(text: $editText)
                            .font(.body.monospaced())
                            .padding(4)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(note.noteTitle)
                                    .font(.title2)
                                    .fontWeight(.bold)

                                if let tags = note["tags"] as? String, !tags.isEmpty {
                                    Text("Tags: \(tags)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if let created = note["created"] as? String {
                                    Text("Created: \(created)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Divider()

                                Text(noteBody(id: id))
                                    .textSelection(.enabled)
                            }
                            .padding()
                        }
                    }

                    Divider()

                    // Footer with edit controls
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
                Text("Select a note")
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
                if isEditing {
                    state.showToast("Finish editing first")
                } else {
                    selectedId = newVal
                }
            }
        )
    }

    private func guardAction(_ action: () -> Void) {
        if isEditing {
            state.showToast("Finish editing first")
        } else {
            action()
        }
    }

    private func startEdit(id: String) {
        let wd = state.workingDirectory
        let path = "\(wd)/notes/\(id).md"
        editText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        state.isEditing = true
    }

    private func cancelEdit() {
        state.isEditing = false
        editText = ""
    }

    private func saveEdit(id: String) {
        let wd = state.workingDirectory
        let path = "\(wd)/notes/\(id).md"
        let validated = EditHelpers.validate(editText, type: .note)
        try? validated.write(toFile: path, atomically: true, encoding: .utf8)
        state.isEditing = false
        editText = ""
        core_reload_data()
        core_reindex_note(id)
        state.refreshData()
    }

    private func reindexAll() {
        guard CoreBridge.shared.isRunning else { return }
        AppState.shared.showToast("Reindexing all notes...")
        DispatchQueue.global(qos: .userInitiated).async {
            for note in state.notes {
                if let id = note["id"] as? String {
                    core_reindex_note(id)
                }
            }
            DispatchQueue.main.async {
                AppState.shared.showToast("Reindexed \(state.notes.count) notes")
            }
        }
    }

    private var addSheet: some View {
        VStack(spacing: 12) {
            Text("New Note").font(.headline)

            TextField("Title", text: $newTitle)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $newContent)
                .frame(minHeight: 100)
                .border(Color.secondary.opacity(0.3))

            TextField("Tags (comma separated)", text: $newTags)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { showingAdd = false }
                Spacer()
                Button("Save") { addNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTitle.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func addNote() {
        guard CoreBridge.shared.isRunning else { return }
        CoreBridge.shared.executeTool("save_note", params: [newTitle, newContent, newTags])
        newTitle = ""
        newContent = ""
        newTags = ""
        showingAdd = false
        state.refreshData()
    }

    private func deleteSelected() {
        guard let id = selectedId, CoreBridge.shared.isRunning else { return }
        CoreBridge.shared.executeTool("delete_note", params: [id])
        selectedId = nil
        state.refreshData()
    }

    private func noteBody(id: String) -> String {
        let wd = state.workingDirectory
        let path = "\(wd)/notes/\(id).md"
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}

extension Dictionary where Key == String, Value == Any {
    var noteId: String { self["id"] as? String ?? "" }
    var noteTitle: String { self["title"] as? String ?? "(untitled)" }
}
