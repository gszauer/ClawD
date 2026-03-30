#pragma once

#include <string>
#include <string_view>
#include <vector>
#include <cstddef>

struct ToolCall {
    std::string name;
    std::vector<std::string> params;
    size_t start_pos = 0;
    size_t end_pos = 0;
};

// Extract all <<TOOL:name(param1, param2, ...)>> calls from AI response text.
std::vector<ToolCall> parse_tool_calls(std::string_view text);

// Return the text with all <<TOOL:...>> markers removed.
std::string strip_tool_calls(std::string_view text);
