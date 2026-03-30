#pragma once

#include <string>
#include <string_view>

class ChatHistory {
public:
    explicit ChatHistory(const std::string& chat_dir);

    void append_user(std::string_view user, std::string_view text);
    void append_assistant(std::string_view text);
    void append_tool(std::string_view tool_call);

    // Load recent exchanges from today and yesterday for prompt context
    std::string load_recent(int max_exchanges = 25) const;

private:
    std::string chat_dir_;

    std::string file_for_date(std::string_view date) const;
    std::string today_str() const;
    std::string yesterday_str() const;
    std::string current_time_str() const;
    void append_entry(std::string_view heading, std::string_view content);
};
