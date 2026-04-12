#pragma once

#include <string>
#include <map>

struct NotificationConfig {
    bool enabled = false;
    std::string time;           // "HH:MM" format
    int minutes_before = 0;     // for calendar_heads_up
};

struct Config {
    // Self-hosted Gemma 4 backend (llama.cpp + mtmd, Metal-accelerated).
    // Both chat generation and note-search embeddings use this one model.
    std::string gemma_model_path;           // path to the Gemma LM GGUF
    std::string gemma_mmproj_path;          // path to the vision projector GGUF (optional)
    int         gemma_n_ctx = 0;            // context length; 0 = use model's trained max
    bool        show_thinking = false;      // if true, leave <think>...</think> blocks in responses
    std::string audio_backend = "off";      // "whisper" or "off"
    std::string whisper_model_path;
    std::string assistant_name = "ClawD";
    std::string assistant_emoji = "\xF0\x9F\xA6\x80"; // crab
    std::string thinking_emoji;
    std::string discord_bot_token;
    std::string discord_channel_id;
    std::string calendar_api_token;       // access token (set by service account auth)
    std::string calendar_id;              // target calendar (user's email address)
    int calendar_sync_interval_minutes = 20;
    std::string working_directory;

    // Weather (Open-Meteo, no API key needed)
    bool        weather_enabled = false;
    std::string weather_zip;             // user's zip code
    double      weather_lat = 0.0;       // cached latitude from geocoding
    double      weather_lon = 0.0;       // cached longitude from geocoding
    std::string weather_cached_zip;      // the zip that lat/lon was derived from

    // Web Search (DuckDuckGo Lite, no API key needed)
    bool web_search_enabled = true;
    int  web_search_max_results = 5;     // number of pages to fetch and summarize

    // Tuning
    int chat_history_exchanges = 25;
    int heartbeat_interval_seconds = 30;
    int note_search_results = 5;
    int max_notes_in_index = 10000;

    std::map<std::string, NotificationConfig> notifications;

    bool load(const std::string& path);
};
