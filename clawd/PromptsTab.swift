import SwiftUI

struct PromptsTab: View {
    @Bindable private var state = AppState.shared

    @State private var files: [PromptFile] = []
    @State private var selectedName: String?
    @State private var editText: String = ""
    @State private var loadedContent: String = ""

    private var isDirty: Bool { editText != loadedContent }

    var body: some View {
        HSplitView {
            // ── File list ──
            VStack(spacing: 0) {
                List(files, id: \.name, selection: selectionBinding) { file in
                    HStack {
                        Image(systemName: file.isNotes ? "doc.text" : "text.quote")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.displayName).fontWeight(.medium)
                            Text(file.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(file.name)
                }

                HStack {
                    Button {
                        guardAction { refreshFromDisk() }
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                    }
                    .help("Reload prompt files from disk")

                    Button {
                        guardAction { resetCurrentToDefault() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward").frame(width: 20, height: 20)
                    }
                    .disabled(selectedName == nil || !canResetCurrent)
                    .help("Reset selected prompt to default")

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

            // ── Editor ──
            if let name = selectedName {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.headline)
                        if isDirty {
                            Text("• unsaved")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Revert") {
                            editText = loadedContent
                        }
                        .disabled(!isDirty)

                        Button("Save") {
                            saveCurrent()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    TextEditor(text: $editText)
                        .font(.body.monospaced())
                        .padding(4)

                    if let help = helpText(for: name) {
                        Divider()
                        Text(help)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Select a prompt to edit")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            ensureDefaults()
            refreshFromDisk()
            if selectedName == nil {
                selectedName = files.first(where: { $0.name == "system_prompt.md" })?.name
                    ?? files.first?.name
                if let name = selectedName { loadFile(name) }
            }
        }
        .onChange(of: state.workingDirectory) { _, _ in
            ensureDefaults()
            refreshFromDisk()
        }
    }

    // MARK: - Selection

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selectedName },
            set: { newValue in
                guard let newValue else { return }
                if state.isEditing {
                    state.showToast("Finish editing first")
                    return
                }
                if isDirty {
                    state.showToast("Save or revert first")
                    return
                }
                selectedName = newValue
                loadFile(newValue)
            }
        )
    }

    private func guardAction(_ action: () -> Void) {
        if state.isEditing {
            state.showToast("Finish editing first")
            return
        }
        action()
    }

    // MARK: - File I/O

    private var promptsDir: String {
        "\(state.workingDirectory)/prompts"
    }

    private func refreshFromDisk() {
        let dir = promptsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let expected = PromptsTab.expectedFiles
        var found: [PromptFile] = []

        // Expected ones first (in canonical order)
        for name in expected {
            let path = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: path) {
                found.append(PromptFile(name: name))
            }
        }

        // Any extra files users dropped in (e.g. notes.txt or custom prompts)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for entry in entries.sorted() where !expected.contains(entry) {
                let lower = entry.lowercased()
                guard lower.hasSuffix(".md") || lower.hasSuffix(".txt") else { continue }
                if entry.hasPrefix(".") { continue }
                found.append(PromptFile(name: entry))
            }
        }

        files = found

        // Reload current selection if present
        if let name = selectedName {
            if files.contains(where: { $0.name == name }) {
                loadFile(name)
            } else {
                selectedName = nil
                loadedContent = ""
                editText = ""
            }
        }
    }

    private func loadFile(_ name: String) {
        let path = "\(promptsDir)/\(name)"
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        loadedContent = content
        editText = content
    }

    private func saveCurrent() {
        guard let name = selectedName else { return }
        let path = "\(promptsDir)/\(name)"
        do {
            try editText.write(toFile: path, atomically: true, encoding: .utf8)
            loadedContent = editText
            state.showToast("Saved \(name) — takes effect on next AI call")
        } catch {
            state.showToast("Save failed: \(error.localizedDescription)", isError: true)
        }
    }

    private var canResetCurrent: Bool {
        guard let name = selectedName else { return false }
        return PromptDefaults.content(for: name) != nil
    }

    private func resetCurrentToDefault() {
        guard let name = selectedName, let def = PromptDefaults.content(for: name) else { return }
        editText = def
    }

    // MARK: - Defaults

    static let expectedFiles: [String] = [
        "system_prompt.md",
        "daily_report.md",
        "end_of_day.md",
        "meal_prep.md",
        "overdue_chores.md",
        "notes.txt",
    ]

    /// Writes any missing prompt files so the folder always contains them.
    private func ensureDefaults() {
        let dir = promptsDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        for name in PromptsTab.expectedFiles {
            let path = "\(dir)/\(name)"
            if !FileManager.default.fileExists(atPath: path),
               let content = PromptDefaults.content(for: name) {
                try? content.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    private func helpText(for name: String) -> String? {
        switch name {
        case "system_prompt.md":
            return "Sent at the start of every AI call. Put the assistant's personality, tool rules, and any persistent user profile (dietary restrictions, wake time, chore meanings) here. Substitutions: {{assistant_name}}, {{datetime}}, {{date}}, {{day_of_week}}, {{tools}}."
        case "daily_report.md":
            return "Instruction the assistant gives itself for the morning briefing. {{weather_hint}} expands to a get_weather call when weather is enabled in Settings."
        case "end_of_day.md":
            return "Instruction for the end-of-day summary. {{weather_hint}} expands to tomorrow's weather when enabled."
        case "meal_prep.md":
            return "Instruction for the meal-prep reminder."
        case "overdue_chores.md":
            return "Instruction for the overdue-chores nag."
        case "notes.txt":
            return "Reference only — this file is never sent to the AI."
        default:
            return nil
        }
    }
}

// MARK: - Data types

private struct PromptFile {
    let name: String
    var displayName: String {
        let base = (name as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
        return base.prefix(1).uppercased() + base.dropFirst()
    }
    var isNotes: Bool { name == "notes.txt" }
}

// MARK: - Defaults (kept in sync with core/prompt_assembler.cpp)

private enum PromptDefaults {
    static func content(for name: String) -> String? {
        switch name {
        case "system_prompt.md":   return systemPrompt
        case "daily_report.md":    return dailyReport
        case "end_of_day.md":      return endOfDay
        case "meal_prep.md":       return mealPrep
        case "overdue_chores.md":  return overdueChores
        case "notes.txt":          return notes
        default:                   return nil
        }
    }

    static let systemPrompt = """
    You are {{assistant_name}}, my personal assistant. You are helpful, concise, and proactive.
    Current date and time: {{datetime}}
    Today is {{day_of_week}}.

    You have access to the following tools. When you want to use a tool,
    respond with the exact format:
    <<TOOL:tool_name(param1, param2, ...)>>

    Available tools:
    {{tools}}
    """

    static let dailyReport = "Generate my morning briefing for today. Include today's meals, calendar events, due chores, and upcoming reminders.{{weather_hint}}"

    static let endOfDay = "Generate my end-of-day summary. What got done today, what didn't, and a preview of tomorrow.{{weather_hint}}"

    static let mealPrep = "What's for dinner tonight? Give a brief meal prep reminder including any prep that should be started now."

    static let overdueChores = "List any overdue chores that need attention today."

    static let notes = """
    # Prompt Template Substitutions

    The following {{variables}} are replaced at runtime in the prompt files below:

      {{assistant_name}}  - The assistant's name from config (e.g. "Friday")
      {{datetime}}        - Current date and time (e.g. "2026-03-29 17:30:00")
      {{date}}            - Current date (e.g. "2026-03-29")
      {{day_of_week}}     - Current day name (e.g. "Sunday")
      {{tools}}           - The full list of available tool definitions
      {{weather_hint}}    - Expands to a "use the get_weather tool" instruction
                            when weather is enabled in settings, otherwise empty.
                            Only meaningful in daily_report.md and end_of_day.md.

    ## Files

      system_prompt.md    - Sent at the start of every AI call.
                            Defines the assistant's personality and tool instructions.
                            Put any user profile / preferences / persistent context
                            (dietary restrictions, wake time, chore meanings, etc.)
                            here as well.

      daily_report.md     - Instruction the assistant gives itself for the morning briefing.
      meal_prep.md        - Instruction for the meal-prep reminder.
      overdue_chores.md   - Instruction for the overdue-chores nag.
      end_of_day.md       - Instruction for the end-of-day summary.

      notes.txt           - This file. Reference only, not sent to the AI.

    ## Image Attachments (Claude Code backend)

    When the backend is "claude", image attachments on Discord are handled
    automatically — no template file controls it. The flow: the image is
    downloaded to working/tmp/, the path is appended to the current user
    message with an explicit "Use your Read tool on this path" instruction,
    Claude reads it, and the tmp file is deleted after the response.

    The image directive is NOT stored in chat history — only your caption
    text is persisted, so future prompts never reference deleted files.

    To change HOW the assistant describes images (e.g. "be terse about
    images", "always extract any visible text"), add that guidance to
    system_prompt.md. The directive itself is deliberately hardcoded so
    Claude reliably uses the Read tool.

    ## Editing

    Edit these files with any text editor (or via the Prompts tab in the app).
    Changes take effect on the next AI call — the files are re-read each time.
    Delete a file to regenerate its default on next launch.
    """
}
