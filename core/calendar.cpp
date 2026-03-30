#include "calendar.h"
#include "config.h"
#include "core.h"
#include "cJSON.h"

#include <mutex>
#include <condition_variable>
#include <fstream>
#include <iostream>
#include <cstring>
#include <random>
#include <sstream>

// --- Synchronous HTTP via platform callbacks ---

struct SyncHttpCtx {
    std::string response;
    int status = 0;
    bool done = false;
    std::mutex mtx;
    std::condition_variable cv;
};

static void sync_http_callback(const char* response, int status, void* ctx) {
    auto* sync = static_cast<SyncHttpCtx*>(ctx);
    std::lock_guard<std::mutex> lk(sync->mtx);
    sync->response = response ? response : "";
    sync->status = status;
    sync->done = true;
    sync->cv.notify_one();
}

CalendarManager::HttpResult CalendarManager::sync_request(
    const char* method, const std::string& url,
    const std::string& headers, const std::string& body) {

    if (!callbacks_ || !callbacks_->http_request) {
        return {"", -1};
    }

    SyncHttpCtx ctx;
    callbacks_->http_request(method, url.c_str(), headers.c_str(),
                             body.empty() ? nullptr : body.c_str(),
                             sync_http_callback, &ctx);

    std::unique_lock<std::mutex> lk(ctx.mtx);
    ctx.cv.wait(lk, [&] { return ctx.done; });
    return {ctx.response, ctx.status};
}

// --- OAuth ---

void CalendarManager::initialize(Config* config, PlatformCallbacks* callbacks) {
    config_ = config;
    callbacks_ = callbacks;
    cache_path_ = config->working_directory + "/calendar_cache.json";
    load_cache();
}

bool CalendarManager::has_google_credentials() const {
    return config_ && !config_->calendar_api_token.empty() && !config_->calendar_id.empty();
}

bool CalendarManager::ensure_access_token() {
    if (!config_) return false;

    // The Swift layer sets calendar_api_token via core_set_calendar_token
    if (!config_->calendar_api_token.empty()) {
        access_token_ = config_->calendar_api_token;
        return true;
    }

    std::cerr << "[Calendar] No access token available" << std::endl;
    return false;
}

std::string CalendarManager::calendar_url() const {
    // Use the configured calendar ID (user's email), fall back to "primary"
    std::string cal_id = config_->calendar_id;
    if (cal_id.empty()) cal_id = "primary";
    return "https://www.googleapis.com/calendar/v3/calendars/" + cal_id;
}

std::string CalendarManager::auth_header() const {
    return "Authorization: Bearer " + access_token_ + "\r\n";
}

// --- Sync ---

bool CalendarManager::sync(bool force) {
    if (!ensure_access_token()) {
        std::cerr << "[Calendar] No valid credentials" << std::endl;
        return false;
    }

    if (force) {
        sync_token_.clear();
    }

    std::string base_url = calendar_url() + "/events";

    // Build URL: events from 14 days ago to 14 days ahead
    time_t now = time(nullptr);
    struct tm tm_buf;

    time_t start = now - 14 * 86400;
    gmtime_r(&start, &tm_buf);
    char start_str[32];
    strftime(start_str, sizeof(start_str), "%Y-%m-%dT00:00:00Z", &tm_buf);

    time_t end_t = now + 14 * 86400;
    gmtime_r(&end_t, &tm_buf);
    char end_str[32];
    strftime(end_str, sizeof(end_str), "%Y-%m-%dT23:59:59Z", &tm_buf);

    std::string url = base_url +
                      "?timeMin=" + std::string(start_str) +
                      "&timeMax=" + std::string(end_str) +
                      "&singleEvents=true&orderBy=startTime&maxResults=250";

    if (!sync_token_.empty()) {
        url = base_url + "?syncToken=" + sync_token_;
    }

    std::cerr << "[Calendar] Requesting: " << url.substr(0, 120) << "..." << std::endl;

    auto result = sync_request("GET", url, auth_header());
    if (result.status != 200) {
        std::cerr << "[Calendar] Sync failed (status " << result.status << "): "
                  << result.body.substr(0, 300) << std::endl;
        if (result.status == 410 && !sync_token_.empty()) {
            sync_token_.clear();
            return sync(true);
        }
        return false;
    }

    cJSON* json = cJSON_Parse(result.body.c_str());
    if (!json) return false;

    // If this is a full sync (no sync token), replace all events
    if (sync_token_.empty()) {
        events_.clear();
    }

    const cJSON* items = cJSON_GetObjectItemCaseSensitive(json, "items");
    if (cJSON_IsArray(items)) {
        const cJSON* item = nullptr;
        cJSON_ArrayForEach(item, items) {
            const cJSON* id = cJSON_GetObjectItemCaseSensitive(item, "id");
            const cJSON* status = cJSON_GetObjectItemCaseSensitive(item, "status");
            const cJSON* summary = cJSON_GetObjectItemCaseSensitive(item, "summary");

            if (!cJSON_IsString(id)) continue;
            std::string event_id = id->valuestring;

            // Remove existing event with this ID (for incremental sync updates)
            events_.erase(
                std::remove_if(events_.begin(), events_.end(),
                    [&](const CalendarEvent& e) { return e.id == event_id; }),
                events_.end());

            // If cancelled, just remove (already done above)
            if (cJSON_IsString(status) && std::string(status->valuestring) == "cancelled") {
                continue;
            }

            CalendarEvent evt;
            evt.id = event_id;
            evt.summary = cJSON_IsString(summary) ? summary->valuestring : "";

            // Parse start time
            const cJSON* start_obj = cJSON_GetObjectItemCaseSensitive(item, "start");
            if (start_obj) {
                const cJSON* dt = cJSON_GetObjectItemCaseSensitive(start_obj, "dateTime");
                const cJSON* d = cJSON_GetObjectItemCaseSensitive(start_obj, "date");
                if (cJSON_IsString(dt)) evt.start_time = dt->valuestring;
                else if (cJSON_IsString(d)) evt.start_time = d->valuestring;
            }

            const cJSON* end_obj = cJSON_GetObjectItemCaseSensitive(item, "end");
            if (end_obj) {
                const cJSON* dt = cJSON_GetObjectItemCaseSensitive(end_obj, "dateTime");
                const cJSON* d = cJSON_GetObjectItemCaseSensitive(end_obj, "date");
                if (cJSON_IsString(dt)) evt.end_time = dt->valuestring;
                else if (cJSON_IsString(d)) evt.end_time = d->valuestring;
            }

            const cJSON* loc = cJSON_GetObjectItemCaseSensitive(item, "location");
            if (cJSON_IsString(loc)) evt.location = loc->valuestring;

            const cJSON* desc = cJSON_GetObjectItemCaseSensitive(item, "description");
            if (cJSON_IsString(desc)) evt.description = desc->valuestring;

            events_.push_back(std::move(evt));
        }
    }

    // Save next sync token
    const cJSON* nst = cJSON_GetObjectItemCaseSensitive(json, "nextSyncToken");
    if (cJSON_IsString(nst)) {
        sync_token_ = nst->valuestring;
    }

    cJSON_Delete(json);
    save_cache();

    std::cerr << "[Calendar] Synced " << events_.size() << " events" << std::endl;
    return true;
}

// --- CRUD ---

std::vector<CalendarEvent> CalendarManager::get_cached_events(
    const std::string& start_date, const std::string& end_date) const {

    std::vector<CalendarEvent> result;
    for (const auto& evt : events_) {
        if (!start_date.empty() && evt.start_time < start_date) continue;
        if (!end_date.empty() && evt.start_time > end_date + "T99:99:99") continue;
        result.push_back(evt);
    }
    return result;
}

std::vector<CalendarEvent> CalendarManager::query_events(
    const std::string& start_date, const std::string& end_date) {

    std::vector<CalendarEvent> result;

    // Fall back to cache if Google isn't connected
    if (!has_google_credentials()) {
        return get_cached_events(start_date, end_date);
    }

    if (!ensure_access_token()) {
        return get_cached_events(start_date, end_date);
    }

    std::string url = calendar_url() + "/events"
        "?timeMin=" + start_date + "T00:00:00Z"
        "&timeMax=" + end_date + "T23:59:59Z"
        "&singleEvents=true&orderBy=startTime&maxResults=250";

    std::cerr << "[Calendar] Live query: " << start_date << " to " << end_date << std::endl;

    auto resp = sync_request("GET", url, auth_header());
    if (resp.status != 200) {
        std::cerr << "[Calendar] Query failed (status " << resp.status << "): "
                  << resp.body.substr(0, 200) << std::endl;
        return result;
    }

    cJSON* json = cJSON_Parse(resp.body.c_str());
    if (!json) return result;

    const cJSON* items = cJSON_GetObjectItemCaseSensitive(json, "items");
    if (cJSON_IsArray(items)) {
        const cJSON* item = nullptr;
        cJSON_ArrayForEach(item, items) {
            const cJSON* id = cJSON_GetObjectItemCaseSensitive(item, "id");
            const cJSON* summary = cJSON_GetObjectItemCaseSensitive(item, "summary");
            const cJSON* status = cJSON_GetObjectItemCaseSensitive(item, "status");

            if (!cJSON_IsString(id)) continue;
            if (cJSON_IsString(status) && std::string(status->valuestring) == "cancelled") continue;

            CalendarEvent evt;
            evt.id = id->valuestring;
            evt.summary = cJSON_IsString(summary) ? summary->valuestring : "";

            const cJSON* start_obj = cJSON_GetObjectItemCaseSensitive(item, "start");
            if (start_obj) {
                const cJSON* dt = cJSON_GetObjectItemCaseSensitive(start_obj, "dateTime");
                const cJSON* d = cJSON_GetObjectItemCaseSensitive(start_obj, "date");
                if (cJSON_IsString(dt)) evt.start_time = dt->valuestring;
                else if (cJSON_IsString(d)) evt.start_time = d->valuestring;
            }

            const cJSON* end_obj = cJSON_GetObjectItemCaseSensitive(item, "end");
            if (end_obj) {
                const cJSON* dt = cJSON_GetObjectItemCaseSensitive(end_obj, "dateTime");
                const cJSON* d = cJSON_GetObjectItemCaseSensitive(end_obj, "date");
                if (cJSON_IsString(dt)) evt.end_time = dt->valuestring;
                else if (cJSON_IsString(d)) evt.end_time = d->valuestring;
            }

            const cJSON* loc = cJSON_GetObjectItemCaseSensitive(item, "location");
            if (cJSON_IsString(loc)) evt.location = loc->valuestring;

            result.push_back(std::move(evt));
        }
    }

    cJSON_Delete(json);
    std::cerr << "[Calendar] Live query returned " << result.size() << " events" << std::endl;
    return result;
}

// Helper: build ISO datetime with timezone offset from a local time string
static std::string make_iso_with_tz(const std::string& datetime, int offset_seconds = 0) {
    struct tm tm_buf{};
    tm_buf.tm_isdst = -1;
    strptime(datetime.c_str(), "%Y-%m-%dT%H:%M:%S", &tm_buf);
    time_t t = mktime(&tm_buf) + offset_seconds;

    char time_str[32];
    localtime_r(&t, &tm_buf);
    strftime(time_str, sizeof(time_str), "%Y-%m-%dT%H:%M:%S", &tm_buf);

    char tz_str[8];
    strftime(tz_str, sizeof(tz_str), "%z", &tm_buf);
    std::string tz = tz_str;
    if (tz.size() >= 5) tz.insert(3, ":");

    return std::string(time_str) + tz;
}

// Generate a random local event ID
static std::string make_local_id() {
    static std::mt19937 rng(std::random_device{}());
    std::uniform_int_distribution<uint32_t> dist(0, 0xFFFFFFFF);
    char buf[16];
    snprintf(buf, sizeof(buf), "local_%08x", dist(rng));
    return buf;
}

std::string CalendarManager::create_event(const std::string& title,
                                           const std::string& datetime,
                                           int duration_minutes,
                                           const std::string& recurrence) {
    // Local-only fallback when Google isn't connected
    if (!has_google_credentials() || !ensure_access_token()) {
        std::string start_iso = make_iso_with_tz(datetime);
        std::string end_iso = make_iso_with_tz(datetime, duration_minutes * 60);

        CalendarEvent evt;
        evt.id = make_local_id();
        evt.summary = title;
        evt.start_time = start_iso;
        evt.end_time = end_iso;
        evt.local_only = true;
        events_.push_back(std::move(evt));
        save_cache();
        return events_.back().id;
    }

    std::string start_iso = make_iso_with_tz(datetime);
    std::string end_iso = make_iso_with_tz(datetime, duration_minutes * 60);

    cJSON* body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "summary", title.c_str());

    cJSON* start_obj = cJSON_CreateObject();
    cJSON_AddStringToObject(start_obj, "dateTime", start_iso.c_str());
    cJSON_AddItemToObject(body, "start", start_obj);

    cJSON* end_obj = cJSON_CreateObject();
    cJSON_AddStringToObject(end_obj, "dateTime", end_iso.c_str());
    cJSON_AddItemToObject(body, "end", end_obj);

    // Add recurrence rule if specified
    if (!recurrence.empty()) {
        std::string freq = recurrence;
        // Normalize to uppercase
        for (auto& c : freq) c = static_cast<char>(toupper(static_cast<unsigned char>(c)));
        std::string rrule = "RRULE:FREQ=" + freq;
        cJSON* recur_arr = cJSON_CreateArray();
        cJSON_AddItemToArray(recur_arr, cJSON_CreateString(rrule.c_str()));
        cJSON_AddItemToObject(body, "recurrence", recur_arr);
    }

    char* json = cJSON_PrintUnformatted(body);
    std::string body_str = json;
    free(json);
    cJSON_Delete(body);

    std::string headers = auth_header() + "Content-Type: application/json\r\n";
    std::string create_url = calendar_url() + "/events";
    std::cerr << "[Calendar] Creating event: " << title << std::endl;
    auto result = sync_request("POST", create_url, headers, body_str);

    if (result.status < 200 || result.status >= 300) {
        std::cerr << "[Calendar] Create event failed (status " << result.status << ")" << std::endl;
        return "";
    }

    // Parse response to get event ID
    cJSON* resp = cJSON_Parse(result.body.c_str());
    std::string event_id;
    if (resp) {
        const cJSON* id = cJSON_GetObjectItemCaseSensitive(resp, "id");
        if (cJSON_IsString(id)) event_id = id->valuestring;
        cJSON_Delete(resp);
    }

    // Add to local cache
    if (!event_id.empty()) {
        CalendarEvent evt;
        evt.id = event_id;
        evt.summary = title;
        evt.start_time = start_iso;
        evt.end_time = end_iso;
        events_.push_back(std::move(evt));
        save_cache();
    }

    return event_id;
}

bool CalendarManager::edit_event(const std::string& event_id,
                                  const std::string& title,
                                  const std::string& datetime,
                                  int duration_minutes) {
    // Local-only edit
    if (!has_google_credentials() || !ensure_access_token()) {
        for (auto& evt : events_) {
            if (evt.id == event_id) {
                if (!title.empty()) evt.summary = title;
                if (!datetime.empty()) {
                    int dur = duration_minutes > 0 ? duration_minutes : 60;
                    evt.start_time = make_iso_with_tz(datetime);
                    evt.end_time = make_iso_with_tz(datetime, dur * 60);
                } else if (duration_minutes > 0 && !evt.start_time.empty()) {
                    evt.end_time = make_iso_with_tz(evt.start_time, duration_minutes * 60);
                }
                save_cache();
                return true;
            }
        }
        return false;
    }
    if (!ensure_access_token()) return false;

    // First, get the existing event to preserve fields we're not changing
    std::string get_url = calendar_url() + "/events/" + event_id;
    auto existing = sync_request("GET", get_url, auth_header());
    if (existing.status != 200) {
        std::cerr << "[Calendar] Failed to get event for edit (status " << existing.status << ")" << std::endl;
        return false;
    }

    cJSON* body = cJSON_Parse(existing.body.c_str());
    if (!body) return false;

    // Update title if provided
    if (!title.empty()) {
        cJSON_DeleteItemFromObjectCaseSensitive(body, "summary");
        cJSON_AddStringToObject(body, "summary", title.c_str());
    }

    // Update start/end times if provided
    if (!datetime.empty()) {
        int dur = duration_minutes > 0 ? duration_minutes : 60;

        // Try to preserve original duration if not specified
        if (duration_minutes <= 0) {
            // Read existing start/end to compute original duration
            const cJSON* s = cJSON_GetObjectItemCaseSensitive(body, "start");
            const cJSON* e = cJSON_GetObjectItemCaseSensitive(body, "end");
            if (s && e) {
                const cJSON* sdt = cJSON_GetObjectItemCaseSensitive(s, "dateTime");
                const cJSON* edt = cJSON_GetObjectItemCaseSensitive(e, "dateTime");
                if (cJSON_IsString(sdt) && cJSON_IsString(edt)) {
                    struct tm st{}, et{};
                    st.tm_isdst = -1; et.tm_isdst = -1;
                    strptime(sdt->valuestring, "%Y-%m-%dT%H:%M:%S", &st);
                    strptime(edt->valuestring, "%Y-%m-%dT%H:%M:%S", &et);
                    int orig_dur = static_cast<int>(difftime(mktime(&et), mktime(&st))) / 60;
                    if (orig_dur > 0) dur = orig_dur;
                }
            }
        }

        std::string start_iso = make_iso_with_tz(datetime);
        std::string end_iso = make_iso_with_tz(datetime, dur * 60);

        cJSON_DeleteItemFromObjectCaseSensitive(body, "start");
        cJSON_DeleteItemFromObjectCaseSensitive(body, "end");

        cJSON* start_obj = cJSON_CreateObject();
        cJSON_AddStringToObject(start_obj, "dateTime", start_iso.c_str());
        cJSON_AddItemToObject(body, "start", start_obj);

        cJSON* end_obj = cJSON_CreateObject();
        cJSON_AddStringToObject(end_obj, "dateTime", end_iso.c_str());
        cJSON_AddItemToObject(body, "end", end_obj);
    } else if (duration_minutes > 0) {
        // Duration changed but not time — adjust end time based on existing start
        const cJSON* s = cJSON_GetObjectItemCaseSensitive(body, "start");
        if (s) {
            const cJSON* sdt = cJSON_GetObjectItemCaseSensitive(s, "dateTime");
            if (cJSON_IsString(sdt)) {
                std::string end_iso = make_iso_with_tz(sdt->valuestring, duration_minutes * 60);
                cJSON_DeleteItemFromObjectCaseSensitive(body, "end");
                cJSON* end_obj = cJSON_CreateObject();
                cJSON_AddStringToObject(end_obj, "dateTime", end_iso.c_str());
                cJSON_AddItemToObject(body, "end", end_obj);
            }
        }
    }

    char* json = cJSON_PrintUnformatted(body);
    std::string body_str = json;
    free(json);
    cJSON_Delete(body);

    std::string headers = auth_header() + "Content-Type: application/json\r\n";
    std::string edit_url = calendar_url() + "/events/" + event_id;
    std::cerr << "[Calendar] Editing event: " << event_id << std::endl;
    auto result = sync_request("PUT", edit_url, headers, body_str);

    if (result.status < 200 || result.status >= 300) {
        std::cerr << "[Calendar] Edit event failed (status " << result.status << "): "
                  << result.body.substr(0, 200) << std::endl;
        return false;
    }

    // Refresh cache for this event
    sync(true);
    return true;
}

bool CalendarManager::delete_event(const std::string& event_id) {
    // Local-only delete
    if (!has_google_credentials() || !ensure_access_token()) {
        auto it = std::remove_if(events_.begin(), events_.end(),
            [&](const CalendarEvent& e) { return e.id == event_id; });
        if (it == events_.end()) return false;
        events_.erase(it, events_.end());
        save_cache();
        return true;
    }

    std::string del_url = calendar_url() + "/events/" + event_id;
    auto result = sync_request("DELETE", del_url, auth_header());

    if (result.status != 204 && result.status != 200) {
        std::cerr << "[Calendar] Delete event failed (status " << result.status << ")" << std::endl;
        return false;
    }

    events_.erase(
        std::remove_if(events_.begin(), events_.end(),
            [&](const CalendarEvent& e) { return e.id == event_id; }),
        events_.end());
    save_cache();
    return true;
}

// --- Cache persistence ---

void CalendarManager::save_cache() const {
    cJSON* root = cJSON_CreateObject();
    if (!sync_token_.empty()) {
        cJSON_AddStringToObject(root, "sync_token", sync_token_.c_str());
    }

    cJSON* arr = cJSON_CreateArray();
    for (const auto& evt : events_) {
        cJSON* obj = cJSON_CreateObject();
        cJSON_AddStringToObject(obj, "id", evt.id.c_str());
        cJSON_AddStringToObject(obj, "summary", evt.summary.c_str());
        cJSON_AddStringToObject(obj, "start", evt.start_time.c_str());
        cJSON_AddStringToObject(obj, "end", evt.end_time.c_str());
        if (!evt.location.empty())
            cJSON_AddStringToObject(obj, "location", evt.location.c_str());
        if (!evt.description.empty())
            cJSON_AddStringToObject(obj, "description", evt.description.c_str());
        if (evt.local_only)
            cJSON_AddTrueToObject(obj, "local_only");
        cJSON_AddItemToArray(arr, obj);
    }
    cJSON_AddItemToObject(root, "events", arr);

    char* json = cJSON_Print(root);
    std::ofstream out(cache_path_, std::ios::trunc);
    out << json;
    free(json);
    cJSON_Delete(root);
}

void CalendarManager::load_cache() {
    FILE* f = fopen(cache_path_.c_str(), "rb");
    if (!f) return;

    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::string data(static_cast<size_t>(len), '\0');
    fread(data.data(), 1, static_cast<size_t>(len), f);
    fclose(f);

    cJSON* root = cJSON_Parse(data.c_str());
    if (!root) return;

    const cJSON* st = cJSON_GetObjectItemCaseSensitive(root, "sync_token");
    if (cJSON_IsString(st)) sync_token_ = st->valuestring;

    events_.clear();
    const cJSON* arr = cJSON_GetObjectItemCaseSensitive(root, "events");
    if (cJSON_IsArray(arr)) {
        const cJSON* item = nullptr;
        cJSON_ArrayForEach(item, arr) {
            CalendarEvent evt;
            const cJSON* v;
            v = cJSON_GetObjectItemCaseSensitive(item, "id");
            if (cJSON_IsString(v)) evt.id = v->valuestring;
            v = cJSON_GetObjectItemCaseSensitive(item, "summary");
            if (cJSON_IsString(v)) evt.summary = v->valuestring;
            v = cJSON_GetObjectItemCaseSensitive(item, "start");
            if (cJSON_IsString(v)) evt.start_time = v->valuestring;
            v = cJSON_GetObjectItemCaseSensitive(item, "end");
            if (cJSON_IsString(v)) evt.end_time = v->valuestring;
            v = cJSON_GetObjectItemCaseSensitive(item, "location");
            if (cJSON_IsString(v)) evt.location = v->valuestring;
            v = cJSON_GetObjectItemCaseSensitive(item, "description");
            if (cJSON_IsString(v)) evt.description = v->valuestring;
            v = cJSON_GetObjectItemCaseSensitive(item, "local_only");
            if (cJSON_IsTrue(v)) evt.local_only = true;
            events_.push_back(std::move(evt));
        }
    }

    cJSON_Delete(root);
}
