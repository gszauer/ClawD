#include "config.h"
#include "cJSON.h"
#include <cstdio>
#include <cstdlib>
#include <string>

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

static std::string json_string(const cJSON* obj, const char* key, const char* def = "") {
    const cJSON* item = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (cJSON_IsString(item) && item->valuestring) return item->valuestring;
    return def;
}

static int json_int(const cJSON* obj, const char* key, int def = 0) {
    const cJSON* item = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (cJSON_IsNumber(item)) return item->valueint;
    return def;
}

static bool json_bool(const cJSON* obj, const char* key, bool def = false) {
    const cJSON* item = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (cJSON_IsBool(item)) return cJSON_IsTrue(item);
    return def;
}

static NotificationConfig parse_notification(const cJSON* obj) {
    NotificationConfig nc;
    nc.enabled = json_bool(obj, "enabled", false);
    nc.time = json_string(obj, "time", "");
    nc.minutes_before = json_int(obj, "minutes_before", 0);
    return nc;
}

bool Config::load(const std::string& path) {
    std::string data = read_file(path);
    if (data.empty()) return false;

    cJSON* root = cJSON_Parse(data.c_str());
    if (!root) return false;

    gemma_model_path             = json_string(root, "gemma_model_path");
    gemma_mmproj_path            = json_string(root, "gemma_mmproj_path");
    gemma_n_ctx                  = json_int(root, "gemma_n_ctx", 0);
    show_thinking                = json_bool(root, "show_thinking", false);
    audio_backend                = json_string(root, "audio_backend", "off");
    whisper_model_path           = json_string(root, "whisper_model_path");
    assistant_name               = json_string(root, "assistant_name", "ClawD");
    assistant_emoji              = json_string(root, "assistant_emoji");
    thinking_emoji               = json_string(root, "thinking_emoji");
    discord_bot_token            = json_string(root, "discord_bot_token");
    discord_channel_id           = json_string(root, "discord_channel_id");
    calendar_api_token           = json_string(root, "calendar_api_token");
    calendar_id                  = json_string(root, "calendar_id");
    calendar_sync_interval_minutes = json_int(root, "calendar_sync_interval_minutes", 20);
    working_directory            = json_string(root, "working_directory");

    weather_enabled              = json_bool(root, "weather_enabled", false);
    weather_zip                  = json_string(root, "weather_zip");
    weather_lat                  = cJSON_GetObjectItemCaseSensitive(root, "weather_lat") ?
                                   cJSON_GetObjectItemCaseSensitive(root, "weather_lat")->valuedouble : 0.0;
    weather_lon                  = cJSON_GetObjectItemCaseSensitive(root, "weather_lon") ?
                                   cJSON_GetObjectItemCaseSensitive(root, "weather_lon")->valuedouble : 0.0;
    weather_cached_zip           = json_string(root, "weather_cached_zip");

    chat_history_exchanges       = json_int(root, "chat_history_exchanges", 25);
    heartbeat_interval_seconds   = json_int(root, "heartbeat_interval_seconds", 30);
    note_search_results          = json_int(root, "note_search_results", 5);
    max_notes_in_index           = json_int(root, "max_notes_in_index", 10000);

    const cJSON* notifs = cJSON_GetObjectItemCaseSensitive(root, "notifications");
    if (notifs) {
        const cJSON* child = nullptr;
        cJSON_ArrayForEach(child, notifs) {
            if (child->string) {
                notifications[child->string] = parse_notification(child);
            }
        }
    }

    cJSON_Delete(root);
    return true;
}
