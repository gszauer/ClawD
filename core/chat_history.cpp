#include "chat_history.h"

#include <sys/stat.h>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <sstream>

ChatHistory::ChatHistory(const std::string& chat_dir) : chat_dir_(chat_dir) {
    mkdir(chat_dir_.c_str(), 0755);
}

std::string ChatHistory::today_str() const {
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char buf[16];
    strftime(buf, sizeof(buf), "%Y-%m-%d", &tm_buf);
    return buf;
}

std::string ChatHistory::yesterday_str() const {
    time_t now = time(nullptr) - 86400;
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char buf[16];
    strftime(buf, sizeof(buf), "%Y-%m-%d", &tm_buf);
    return buf;
}

std::string ChatHistory::current_time_str() const {
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char buf[8];
    strftime(buf, sizeof(buf), "%H:%M", &tm_buf);
    return buf;
}

std::string ChatHistory::file_for_date(std::string_view date) const {
    return chat_dir_ + "/" + std::string(date) + ".md";
}

void ChatHistory::append_entry(std::string_view heading, std::string_view content) {
    std::string path = file_for_date(today_str());
    std::ofstream out(path, std::ios::app);
    out << "## " << heading << " " << current_time_str() << "\n";
    out << content << "\n\n";
}

void ChatHistory::append_user(std::string_view user, std::string_view text) {
    std::string heading = user.empty() ? "User" : std::string(user);
    append_entry(heading, text);
}

void ChatHistory::append_assistant(std::string_view text) {
    append_entry("Assistant", text);
}

void ChatHistory::append_tool(std::string_view tool_call) {
    append_entry("Tool", tool_call);
}

static std::string read_file(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return {};
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::string buf(static_cast<size_t>(len), '\0');
    fread(buf.data(), 1, static_cast<size_t>(len), f);
    fclose(f);
    return buf;
}

// Get the last N exchanges from text (returns from the Nth-from-last "## User" onward)
static std::string tail_exchanges(const std::string& text, int max_exchanges) {
    // Find all "## User" or "## Assistant" or "## Tool" positions
    std::vector<size_t> exchange_starts;
    size_t pos = 0;
    while (pos < text.size()) {
        size_t found = text.find("\n## ", pos);
        if (found == std::string::npos) break;
        // Check if this starts with "User" to count as a new exchange
        size_t heading_start = found + 4;
        if (text.compare(heading_start, 4, "User") == 0) {
            exchange_starts.push_back(found + 1); // +1 to skip the \n
        }
        pos = found + 1;
    }
    // Also check if file starts with "## User"
    if (text.compare(0, 7, "## User") == 0) {
        if (exchange_starts.empty() || exchange_starts[0] != 0) {
            exchange_starts.insert(exchange_starts.begin(), 0);
        }
    }

    if (static_cast<int>(exchange_starts.size()) <= max_exchanges) {
        return text;
    }

    size_t start_idx = exchange_starts.size() - static_cast<size_t>(max_exchanges);
    return text.substr(exchange_starts[start_idx]);
}

std::string ChatHistory::load_recent(int max_exchanges) const {
    std::string result;

    // Load yesterday's file first (for cross-day context)
    std::string yesterday = read_file(file_for_date(yesterday_str()));
    std::string today = read_file(file_for_date(today_str()));

    std::string combined;
    if (!yesterday.empty()) {
        combined += yesterday;
        if (combined.back() != '\n') combined += '\n';
    }
    if (!today.empty()) {
        combined += today;
    }

    if (combined.empty()) return {};

    return tail_exchanges(combined, max_exchanges);
}
