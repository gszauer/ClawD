#include "tool_parser.h"
#include <cctype>

// Parse a single parameter (handles quoted strings and bare values)
static std::string parse_param(std::string_view text, size_t& pos) {
    // Skip whitespace
    while (pos < text.size() && (text[pos] == ' ' || text[pos] == '\t'))
        ++pos;

    if (pos >= text.size()) return {};

    std::string result;

    if (text[pos] == '"') {
        // Quoted string
        ++pos;
        while (pos < text.size() && text[pos] != '"') {
            if (text[pos] == '\\' && pos + 1 < text.size()) {
                ++pos;
                switch (text[pos]) {
                    case '"':  result += '"';  break;
                    case '\\': result += '\\'; break;
                    case 'n':  result += '\n'; break;
                    case 't':  result += '\t'; break;
                    default:   result += '\\'; result += text[pos]; break;
                }
            } else {
                result += text[pos];
            }
            ++pos;
        }
        if (pos < text.size()) ++pos; // skip closing quote
    } else {
        // Bare value (number, identifier, etc.)
        while (pos < text.size() && text[pos] != ',' && text[pos] != ')') {
            result += text[pos];
            ++pos;
        }
        // Trim trailing whitespace
        while (!result.empty() && (result.back() == ' ' || result.back() == '\t'))
            result.pop_back();
    }

    return result;
}

std::vector<ToolCall> parse_tool_calls(std::string_view text) {
    std::vector<ToolCall> calls;
    const std::string_view marker_open = "<<TOOL:";
    const std::string_view marker_close = ">>";

    size_t search_pos = 0;
    while (search_pos < text.size()) {
        size_t start = text.find(marker_open, search_pos);
        if (start == std::string_view::npos) break;

        size_t end = text.find(marker_close, start + marker_open.size());
        if (end == std::string_view::npos) break;

        std::string_view inner = text.substr(start + marker_open.size(),
                                             end - start - marker_open.size());

        ToolCall call;
        call.start_pos = start;
        call.end_pos = end + marker_close.size();

        // Parse "name(param1, param2, ...)"
        size_t paren = inner.find('(');
        if (paren == std::string_view::npos) {
            // No params — just a bare name
            call.name = std::string(inner);
        } else {
            call.name = std::string(inner.substr(0, paren));

            // Find the matching closing paren
            size_t close_paren = inner.rfind(')');
            if (close_paren != std::string_view::npos && close_paren > paren) {
                std::string_view params_str = inner.substr(paren + 1,
                                                           close_paren - paren - 1);

                // Parse comma-separated parameters
                size_t p = 0;
                while (p < params_str.size()) {
                    // Skip whitespace and commas
                    while (p < params_str.size() &&
                           (params_str[p] == ' ' || params_str[p] == ',' ||
                            params_str[p] == '\t'))
                        ++p;
                    if (p >= params_str.size()) break;

                    // Strip keyword prefixes like "date=" or "name=" that
                    // small models often produce (e.g. get_weather(date="2026-04-09"))
                    size_t kw_scan = p;
                    while (kw_scan < params_str.size() &&
                           params_str[kw_scan] != '=' && params_str[kw_scan] != ',' &&
                           params_str[kw_scan] != ')' && params_str[kw_scan] != '"')
                        ++kw_scan;
                    if (kw_scan < params_str.size() && params_str[kw_scan] == '=') {
                        p = kw_scan + 1; // skip past the '='
                        // Skip whitespace after '='
                        while (p < params_str.size() && (params_str[p] == ' ' || params_str[p] == '\t'))
                            ++p;
                    }

                    if (p >= params_str.size()) break;

                    std::string param = parse_param(params_str, p);
                    if (!param.empty()) {
                        // Also strip keyword prefixes inside quoted strings.
                        // Small models write "date=2026-04-09" instead of "2026-04-09".
                        auto eq = param.find('=');
                        if (eq != std::string::npos && eq < param.size() - 1) {
                            // Only strip if the part before '=' looks like an identifier
                            bool is_kw = true;
                            for (size_t i = 0; i < eq; ++i) {
                                char c = param[i];
                                if (!std::isalnum(static_cast<unsigned char>(c)) && c != '_') {
                                    is_kw = false;
                                    break;
                                }
                            }
                            if (is_kw) param = param.substr(eq + 1);
                        }
                        call.params.push_back(std::move(param));
                    }
                }
            }
        }

        // Trim name whitespace
        while (!call.name.empty() && call.name.back() == ' ')
            call.name.pop_back();
        while (!call.name.empty() && call.name.front() == ' ')
            call.name.erase(call.name.begin());

        calls.push_back(std::move(call));
        search_pos = end + marker_close.size();
    }

    return calls;
}

std::string strip_tool_calls(std::string_view text) {
    auto calls = parse_tool_calls(text);
    if (calls.empty()) return std::string(text);

    std::string result;
    size_t pos = 0;
    for (const auto& call : calls) {
        result.append(text.data() + pos, call.start_pos - pos);
        pos = call.end_pos;
    }
    result.append(text.data() + pos, text.size() - pos);

    // Trim trailing whitespace from the result
    while (!result.empty() && (result.back() == ' ' || result.back() == '\n' ||
                                result.back() == '\r' || result.back() == '\t'))
        result.pop_back();

    return result;
}
