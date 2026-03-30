#include "frontmatter.h"
#include <sstream>

// Trim leading/trailing whitespace
static std::string_view trim(std::string_view s) {
    while (!s.empty() && (s.front() == ' ' || s.front() == '\t'))
        s.remove_prefix(1);
    while (!s.empty() && (s.back() == ' ' || s.back() == '\t' || s.back() == '\r'))
        s.remove_suffix(1);
    return s;
}

Document parse_document(std::string_view content) {
    Document doc;

    // Check for frontmatter delimiter
    std::string_view remaining = content;
    if (remaining.substr(0, 3) != "---") {
        doc.body = std::string(content);
        return doc;
    }

    // Skip the opening "---\n"
    remaining.remove_prefix(3);
    if (!remaining.empty() && remaining.front() == '\r') remaining.remove_prefix(1);
    if (!remaining.empty() && remaining.front() == '\n') remaining.remove_prefix(1);

    // Find closing "---"
    size_t close = remaining.find("\n---");
    if (close == std::string_view::npos) {
        // Malformed — treat entire content as body
        doc.body = std::string(content);
        return doc;
    }

    std::string_view fm_block = remaining.substr(0, close);
    remaining.remove_prefix(close + 4); // skip "\n---"
    // Skip any trailing \r\n after closing ---
    if (!remaining.empty() && remaining.front() == '\r') remaining.remove_prefix(1);
    if (!remaining.empty() && remaining.front() == '\n') remaining.remove_prefix(1);

    // Parse key: value lines from frontmatter block
    size_t line_start = 0;
    while (line_start < fm_block.size()) {
        size_t line_end = fm_block.find('\n', line_start);
        if (line_end == std::string_view::npos) line_end = fm_block.size();

        std::string_view line = fm_block.substr(line_start, line_end - line_start);
        line = trim(line);

        size_t colon = line.find(':');
        if (colon != std::string_view::npos) {
            std::string key(trim(line.substr(0, colon)));
            std::string_view val = trim(line.substr(colon + 1));

            // Handle array values: [item1, item2] -> stored as "item1, item2"
            if (!val.empty() && val.front() == '[' && val.back() == ']') {
                val.remove_prefix(1);
                val.remove_suffix(1);
                val = trim(val);
            }

            doc.meta[key] = std::string(val);
        }

        line_start = line_end + 1;
    }

    doc.body = std::string(remaining);
    return doc;
}

std::string serialize_document(const std::map<std::string, std::string>& meta,
                               std::string_view body) {
    std::ostringstream out;
    out << "---\n";
    for (const auto& [key, val] : meta) {
        // If the value looks like a list (contains commas and no newlines), wrap in []
        bool is_list = val.find(',') != std::string::npos &&
                       val.find('\n') == std::string::npos &&
                       (key == "days" || key == "tags");
        if (is_list) {
            out << key << ": [" << val << "]\n";
        } else {
            out << key << ": " << val << "\n";
        }
    }
    out << "---\n";
    if (!body.empty()) {
        // Ensure there's a blank line between frontmatter and body
        if (body.front() != '\n') out << '\n';
        out << body;
        if (body.back() != '\n') out << '\n';
    }
    return out.str();
}

std::string extract_title(std::string_view body) {
    size_t pos = 0;
    while (pos < body.size()) {
        size_t line_end = body.find('\n', pos);
        if (line_end == std::string_view::npos) line_end = body.size();

        std::string_view line = trim(body.substr(pos, line_end - pos));
        if (line.size() > 2 && line[0] == '#' && line[1] == ' ') {
            return std::string(trim(line.substr(2)));
        }
        pos = line_end + 1;
    }
    return {};
}
