import SwiftUI

struct PromptsTab: View {
    @Bindable private var state = AppState.shared

    @State private var files: [String] = []
    @State private var selectedFile: String?
    @State private var editText: String = ""
    @State private var loadedText: String = ""

    private var promptsDir: String {
        let wd = state.workingDirectory.isEmpty ? AppState.defaultWorkingDirectory : state.workingDirectory
        return "\(wd)/prompts"
    }

    private var isDirty: Bool { editText != loadedText }

    var body: some View {
        HSplitView {
            // File list
            VStack(spacing: 0) {
                List(files, id: \.self, selection: selectionBinding) { name in
                    HStack {
                        Image(systemName: icon(for: name))
                            .foregroundStyle(.secondary)
                        Text(displayName(name))
                        Spacer()
                        if name == selectedFile && isDirty {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                        }
                    }
                    .tag(name)
                }
                Divider()
                HStack {
                    Button {
                        scanFiles()
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                    }
                    .help("Rescan prompts directory")
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

            // Editor
            if let file = selectedFile {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(displayName(file))
                            .font(.headline)
                        if isDirty {
                            Text("• unsaved")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()

                    TextEditor(text: $editText)
                        .font(.body.monospaced())
                        .padding(4)

                    Divider()

                    // Footer with edit controls
                    HStack {
                        Spacer()
                        Button("Revert") { editText = loadedText }
                            .disabled(!isDirty)
                        Button("Save") { saveCurrent() }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(!isDirty)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(8)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select a prompt file to edit")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            // Materialize default prompt files if the folder is missing or
            // empty. Safe to call even when the core isn't running — the C
            // function operates on the working directory directly.
            let wd = state.workingDirectory.isEmpty ? AppState.defaultWorkingDirectory : state.workingDirectory
            core_write_prompt_defaults(wd)
            scanFiles()
            if selectedFile == nil {
                selectedFile = files.first { $0 == "system_prompt.md" } ?? files.first
                loadSelected()
            }
        }
        .onChange(of: isDirty) { _, dirty in
            state.isEditing = dirty
        }
    }

    // MARK: - Helpers

    private func icon(for name: String) -> String {
        if name.hasSuffix(".md") { return "doc.text" }
        if name.hasSuffix(".txt") { return "doc.plaintext" }
        return "doc"
    }

    private func displayName(_ name: String) -> String {
        switch name {
        case "system_prompt.md":  return "System Prompt"
        case "daily_report.md":   return "Daily Report"
        case "meal_prep.md":      return "Meal Prep"
        case "overdue_chores.md": return "Overdue Chores"
        case "end_of_day.md":     return "End of Day"
        case "notes.txt":         return "Notes (reference)"
        default:                  return name
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selectedFile },
            set: { newVal in
                guard let newVal, newVal != selectedFile else { return }
                if isDirty {
                    state.showToast("Save or revert changes first", isError: true)
                    return
                }
                selectedFile = newVal
                loadSelected()
            }
        )
    }

    private func scanFiles() {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: promptsDir)) ?? []
        files = contents
            .filter { !$0.hasPrefix(".") }
            .sorted { displayName($0) < displayName($1) }
    }

    private func loadSelected() {
        guard let file = selectedFile else {
            editText = ""
            loadedText = ""
            return
        }
        let path = "\(promptsDir)/\(file)"
        if let data = try? String(contentsOfFile: path, encoding: .utf8) {
            loadedText = data
            editText = data
        } else {
            loadedText = ""
            editText = ""
            state.showToast("Failed to read \(file)", isError: true)
        }
    }

    private func saveCurrent() {
        guard let file = selectedFile else { return }
        let path = "\(promptsDir)/\(file)"
        do {
            try editText.write(toFile: path, atomically: true, encoding: .utf8)
            loadedText = editText
            state.showToast("\(displayName(file)) saved")
        } catch {
            state.showToast("Save failed: \(error.localizedDescription)", isError: true)
        }
    }
}
