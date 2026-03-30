#pragma once

#include <string>
#include <vector>
#include <ctime>

struct CalendarEvent {
    std::string id;
    std::string summary;
    std::string start_time;  // ISO 8601
    std::string end_time;    // ISO 8601
    std::string location;
    std::string description;
    bool local_only = false;
};

struct Config;
struct PlatformCallbacks;

class CalendarManager {
public:
    void initialize(Config* config, PlatformCallbacks* callbacks);

    // Sync events from Google Calendar. Returns true on success.
    // force=true clears the sync token for a full re-fetch.
    bool sync(bool force = false);

    // Get cached events in a date range (for prompt context / UI)
    std::vector<CalendarEvent> get_cached_events(const std::string& start_date,
                                                  const std::string& end_date) const;

    // Query Google Calendar API live for any date range (for tool calls)
    std::vector<CalendarEvent> query_events(const std::string& start_date,
                                            const std::string& end_date);

    // Create an event. Returns the event ID or empty on failure.
    // recurrence: empty for one-time, or "DAILY", "WEEKLY", "MONTHLY", "YEARLY"
    std::string create_event(const std::string& title,
                             const std::string& datetime,
                             int duration_minutes,
                             const std::string& recurrence = "");

    // Edit an event. Empty strings = don't change. duration_minutes <= 0 = don't change.
    bool edit_event(const std::string& event_id,
                    const std::string& title,
                    const std::string& datetime,
                    int duration_minutes);

    // Delete an event by ID. Returns true on success.
    bool delete_event(const std::string& event_id);

    // Persist cache to disk
    void save_cache() const;
    void load_cache();

    const std::vector<CalendarEvent>& cached_events() const { return events_; }
    bool has_google_credentials() const;

private:
    Config* config_ = nullptr;
    PlatformCallbacks* callbacks_ = nullptr;
    std::vector<CalendarEvent> events_;
    std::string sync_token_;
    std::string cache_path_;

    std::string calendar_url() const;

    // Synchronous HTTPS request via platform callbacks
    struct HttpResult {
        std::string body;
        int status = 0;
    };
    HttpResult sync_request(const char* method, const std::string& url,
                            const std::string& headers, const std::string& body = "");

    // OAuth token refresh
    std::string access_token_;
    time_t token_expiry_ = 0;
    bool ensure_access_token();
    std::string auth_header() const;
};
