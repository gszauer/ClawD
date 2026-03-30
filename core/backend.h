#pragma once

#include <string>
#include <string_view>

struct Config;

class Backend {
public:
    // Execute prompt via CLI backend (claude, gemini, codex) using popen()
    static std::string execute_cli(std::string_view cli_path, std::string_view prompt);

    // Execute prompt via OpenAI-compatible API using HTTP POST
    static std::string execute_api(std::string_view api_url,
                                   std::string_view api_key,
                                   std::string_view model,
                                   std::string_view prompt);

    // Route to the appropriate executor based on config
    static std::string execute(const Config& config, std::string_view prompt);
};
