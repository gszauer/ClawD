import Foundation

/// Validates and fixes frontmatter in a markdown file after editing.
/// Ensures required fields exist with defaults, and that the # title line is present.
enum EditHelpers {

    // MARK: - Required fields per type

    private static let noteDefaults: [String: String] = [
        "created": {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return df.string(from: Date())
        }(),
        "tags": "",
    ]

    private static let mealDefaults: [String: String] = [
        "type": "home",
        "days": "",
        "slot": "1",
    ]

    private static let choreDefaults: [String: String] = [
        "color": "green",
        "recurrence": "weekly",
        "completed_last": "",
    ]

    private static let reminderDefaults: [String: String] = [
        "datetime": "",
        "status": "pending",
        "recurrence": "once",
    ]

    /// Validate and fix a markdown file. Returns the (possibly corrected) content.
    static func validate(_ content: String, type: DataType) -> String {
        let defaults: [String: String]
        switch type {
        case .note: defaults = noteDefaults
        case .meal: defaults = mealDefaults
        case .chore: defaults = choreDefaults
        case .reminder: defaults = reminderDefaults
        }

        var lines = content.components(separatedBy: "\n")

        // Find frontmatter boundaries
        let hasFrontmatter = lines.first?.trimmingCharacters(in: .whitespaces) == "---"
        var fmStart = -1
        var fmEnd = -1

        if hasFrontmatter {
            fmStart = 0
            for i in 1..<lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    fmEnd = i
                    break
                }
            }
        }

        if fmStart >= 0 && fmEnd > fmStart {
            // Parse existing frontmatter keys
            var existingKeys = Set<String>()
            for i in (fmStart + 1)..<fmEnd {
                let line = lines[i]
                if let colonIdx = line.firstIndex(of: ":") {
                    let key = line[line.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { existingKeys.insert(key) }
                }
            }

            // Add missing required fields before the closing ---
            var insertLines: [String] = []
            for (key, defaultVal) in defaults {
                if !existingKeys.contains(key) {
                    insertLines.append("\(key): \(defaultVal)")
                }
            }
            if !insertLines.isEmpty {
                lines.insert(contentsOf: insertLines, at: fmEnd)
                fmEnd += insertLines.count
            }
        } else {
            // No frontmatter at all — prepend one
            var fm = ["---"]
            for (key, val) in defaults.sorted(by: { $0.key < $1.key }) {
                fm.append("\(key): \(val)")
            }
            fm.append("---")
            fm.append("")
            lines = fm + lines
        }

        // Ensure there's a # title line somewhere after frontmatter
        let bodyStart = (fmEnd >= 0) ? fmEnd + 1 : 0
        let hasTitle = lines[bodyStart...].contains(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ")
        })
        if !hasTitle {
            // Insert a placeholder title
            let insertAt = min(bodyStart + 1, lines.count)
            if insertAt < lines.count && lines[insertAt].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.insert("# Untitled", at: insertAt + 1)
            } else {
                lines.insert("# Untitled", at: insertAt)
            }
        }

        return lines.joined(separator: "\n")
    }

    enum DataType {
        case note, meal, chore, reminder
    }
}
