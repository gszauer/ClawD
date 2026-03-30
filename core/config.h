#pragma once

#include <string>
#include <map>

struct NotificationConfig {
    bool enabled = false;
    std::string time;           // "HH:MM" format
    int minutes_before = 0;     // for calendar_heads_up
};

struct Config {
    std::string backend = "claude";
    std::string backend_cli_path = "/Users/user/.local/bin/claude";
    std::string backend_api_url;
    std::string backend_api_key;
    std::string backend_api_model;
    std::string embedding_url = "http://localhost:1234/v1/embeddings";
    std::string embedding_model = "text-embedding-embeddinggemma-300m";
    std::string assistant_name = "ClawD";
    std::string assistant_emoji = "\xF0\x9F\xA6\x80"; // crab
    std::string thinking_emoji;
    std::string discord_bot_token;
    std::string discord_channel_id;
    std::string calendar_api_token;       // access token (set by service account auth)
    std::string calendar_id;              // target calendar (user's email address)
    int calendar_sync_interval_minutes = 20;
    std::string working_directory;

    // Tuning
    int chat_history_exchanges = 25;
    int heartbeat_interval_seconds = 30;
    int note_search_results = 5;
    int max_notes_in_index = 10000;

    std::map<std::string, NotificationConfig> notifications;

    bool load(const std::string& path);
};
