#pragma once

#include <string>
#include <string_view>
#include <map>

struct Document {
    std::map<std::string, std::string> meta;
    std::string body;
};

Document parse_document(std::string_view content);
std::string serialize_document(const std::map<std::string, std::string>& meta,
                               std::string_view body);

// Extract the first "# Heading" line from a markdown body
std::string extract_title(std::string_view body);
