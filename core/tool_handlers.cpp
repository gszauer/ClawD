#include "tool_handlers.h"
#include "config.h"
#include "core.h"
#include "calendar.h"
#include "data_store.h"
#include "note_search.h"
#include "task_queue.h"
#include "http_client.h"
#include "cJSON.h"

#include <sstream>
#include <mutex>
#include <condition_variable>
#include <iostream>
#include <ctime>
#include <algorithm>
#include <cstdlib>

// --- Utility ---

static std::string today_date_str() {
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char buf[16];
    strftime(buf, sizeof(buf), "%Y-%m-%d", &tm_buf);
    return buf;
}

// Parse ISO 8601 datetime string to time_t
static time_t parse_datetime(const std::string& dt) {
    struct tm tm_buf{};
    tm_buf.tm_isdst = -1; // let mktime figure out DST
    // Try "YYYY-MM-DDTHH:MM:SS"
    if (strptime(dt.c_str(), "%Y-%m-%dT%H:%M:%S", &tm_buf)) {
        return mktime(&tm_buf);
    }
    tm_buf.tm_isdst = -1;
    // Try "YYYY-MM-DDTHH:MM"
    if (strptime(dt.c_str(), "%Y-%m-%dT%H:%M", &tm_buf)) {
        return mktime(&tm_buf);
    }
    tm_buf.tm_isdst = -1;
    // Try "YYYY-MM-DD"
    if (strptime(dt.c_str(), "%Y-%m-%d", &tm_buf)) {
        return mktime(&tm_buf);
    }
    return 0;
}

// Parse a day-of-month from a date string (YYYY-MM-DD)
static int day_of_month_from_date(const std::string& date) {
    struct tm tm_buf{};
    if (strptime(date.c_str(), "%Y-%m-%d", &tm_buf)) {
        return tm_buf.tm_mday;
    }
    return 0;
}

// --- Reminder Handlers ---

std::string SetReminderHandler::execute(const std::vector<std::string>& params) {
    if (params.size() < 2) return "Error: set_reminder requires message and datetime";

    const std::string& message = params[0];
    const std::string& datetime = params[1];
    std::string recurrence = params.size() > 2 && !params[2].empty() ? params[2] : "once";

    std::map<std::string, std::string> meta;
    meta["datetime"] = datetime;
    meta["recurrence"] = recurrence;
    meta["status"] = "pending";

    DataItem& item = ctx_->reminders->add(message, meta, "");

    // Schedule the reminder in the task queue
    time_t fire = parse_datetime(datetime);
    if (fire > 0 && ctx_->task_queue) {
        double now = static_cast<double>(time(nullptr));
        double delay = static_cast<double>(fire) - now;
        std::cerr << "[Reminder] Scheduled \"" << message << "\" fire_time="
                  << fire << " now=" << static_cast<time_t>(now)
                  << " delay=" << delay << "s" << std::endl;

        ScheduledTask task;
        task.fire_time = static_cast<double>(fire);
        task.type = TaskType::REMINDER;
        task.task_id = item.id;
        ctx_->task_queue->insert(std::move(task));
    } else {
        std::cerr << "[Reminder] Failed to parse datetime: " << datetime << std::endl;
    }

    std::string recur_info = (recurrence != "once") ? " (recurring: " + recurrence + ")" : "";
    return "Reminder set: \"" + message + "\" at " + datetime + recur_info + " [id: " + item.id + "]";
}

std::string ListRemindersHandler::execute(const std::vector<std::string>& params) {
    int count = 10;
    if (!params.empty()) {
        try { count = std::stoi(params[0]); } catch (...) {}
    }

    auto pending = ctx_->reminders->filter([](const DataItem& item) {
        auto it = item.meta.find("status");
        return it != item.meta.end() && it->second == "pending";
    });

    if (pending.empty()) return "No upcoming reminders.";

    std::ostringstream ss;
    ss << "Upcoming reminders:\n";
    int shown = 0;
    for (const auto* item : pending) {
        if (shown++ >= count) break;
        auto dt_it = item->meta.find("datetime");
        ss << "- " << item->title;
        if (dt_it != item->meta.end()) ss << " (at " << dt_it->second << ")";
        ss << " [id: " << item->id << "]\n";
    }
    return ss.str();
}

std::string DeleteReminderHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: delete_reminder requires an id";

    const std::string& id = params[0];
    const DataItem* item = ctx_->reminders->find(id);
    if (!item) return "Error: reminder not found: " + id;

    // Remove from task queue
    if (ctx_->task_queue) ctx_->task_queue->remove_by_id(id);

    std::string title = item->title;
    ctx_->reminders->remove(id);
    return "Deleted reminder: \"" + title + "\"";
}

std::string EditReminderHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: edit_reminder requires an id";

    const std::string& id = params[0];
    const DataItem* item = ctx_->reminders->find(id);
    if (!item) return "Error: reminder not found: " + id;

    auto meta = item->meta;
    std::string body = item->body;
    std::string title = item->title;

    // Update message (title) if provided
    if (params.size() > 1 && !params[1].empty()) {
        title = params[1];
        body = "# " + title + "\n";
    }
    // Update datetime if provided
    if (params.size() > 2 && !params[2].empty()) {
        meta["datetime"] = params[2];

        // Reschedule in task queue
        if (ctx_->task_queue) {
            ctx_->task_queue->remove_by_id(id);
            time_t fire = parse_datetime(params[2]);
            if (fire > 0) {
                ScheduledTask task;
                task.fire_time = static_cast<double>(fire);
                task.type = TaskType::REMINDER;
                task.task_id = id;
                ctx_->task_queue->insert(std::move(task));
            }
        }
    }

    // Update recurrence if provided
    if (params.size() > 3 && !params[3].empty()) {
        meta["recurrence"] = params[3];
    }

    ctx_->reminders->update(id, meta, body);
    return "Updated reminder: \"" + title + "\" [id: " + id + "]";
}

// --- Meal Handlers ---

// Get all meals sorted by id (filename). Numeric prefix in filename controls order.
static std::vector<const DataItem*> sorted_meals(DataStore* meals) {
    std::vector<const DataItem*> result;
    for (const auto& item : meals->items()) result.push_back(&item);
    std::sort(result.begin(), result.end(),
              [](const DataItem* a, const DataItem* b) { return a->id < b->id; });
    return result;
}

// Get the meal index for a given date: day_of_year % num_meals
static int meal_index_for_date(const std::string& date, int num_meals) {
    if (num_meals <= 0) return -1;
    struct tm tm_buf = {};
    strptime(date.c_str(), "%Y-%m-%d", &tm_buf);
    int day_of_year = tm_buf.tm_yday; // 0-based
    return day_of_year % num_meals;
}

std::string AddMealHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: add_meal requires at least a name";

    const std::string& name = params[0];
    std::string type = params.size() > 1 ? params[1] : "home";
    std::string content = params.size() > 2 ? params[2] : "";

    std::map<std::string, std::string> meta;
    meta["type"] = type;

    DataItem& item = ctx_->meals->add(name, meta, content);
    return "Added meal: \"" + name + "\" (" + type + ") [id: " + item.id + "]";
}

std::string EditMealHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: edit_meal requires an id";

    const std::string& id = params[0];
    const DataItem* item = ctx_->meals->find(id);
    if (!item) return "Error: meal not found: " + id;

    auto meta = item->meta;
    std::string body = item->body;

    if (params.size() > 1 && !params[1].empty()) {
        std::string old_body = body;
        size_t nl = old_body.find('\n');
        std::string rest = (nl != std::string::npos) ? old_body.substr(nl) : "";
        body = "# " + params[1] + rest;
    }
    if (params.size() > 2 && !params[2].empty()) meta["type"] = params[2];
    if (params.size() > 3 && !params[3].empty()) {
        size_t nl = body.find('\n');
        std::string heading = (nl != std::string::npos) ? body.substr(0, nl) : body;
        body = heading + "\n\n" + params[3] + "\n";
    }

    ctx_->meals->update(id, meta, body);
    return "Updated meal [id: " + id + "]";
}

std::string DeleteMealHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: delete_meal requires an id";

    const DataItem* item = ctx_->meals->find(params[0]);
    if (!item) return "Error: meal not found: " + params[0];

    std::string title = item->title;
    ctx_->meals->remove(params[0]);
    return "Deleted meal: \"" + title + "\"";
}

std::string GetMealsHandler::execute(const std::vector<std::string>& params) {
    std::string date = params.empty() ? today_date_str() : params[0];
    auto meals = sorted_meals(ctx_->meals);
    if (meals.empty()) return "No meals in the rotation.";

    int idx = meal_index_for_date(date, static_cast<int>(meals.size()));
    const DataItem* today = (idx >= 0) ? meals[idx] : nullptr;

    std::ostringstream ss;
    if (today) {
        ss << "Today's meal (" << date << ", #" << (idx + 1) << " of " << meals.size() << "): ";
        ss << today->title;
        auto type_it = today->meta.find("type");
        if (type_it != today->meta.end()) ss << " (" << type_it->second << ")";
        ss << " [id: " << today->id << "]\n\n";
    }

    ss << "Full rotation (" << meals.size() << " meals):\n";
    for (size_t i = 0; i < meals.size(); i++) {
        ss << (i + 1) << ". " << meals[i]->title;
        auto type_it = meals[i]->meta.find("type");
        if (type_it != meals[i]->meta.end()) ss << " (" << type_it->second << ")";
        ss << " [id: " << meals[i]->id << "]\n";
    }
    return ss.str();
}

std::string GetMealDetailsHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: get_meal_details requires an id";

    const DataItem* item = ctx_->meals->find(params[0]);
    if (!item) return "Error: meal not found: " + params[0];

    std::ostringstream ss;
    ss << item->title << "\n";
    auto type_it = item->meta.find("type");
    if (type_it != item->meta.end()) ss << "Type: " << type_it->second << "\n";
    ss << "\n";

    std::string_view body = item->body;
    size_t nl = body.find('\n');
    if (nl != std::string_view::npos) {
        body = body.substr(nl + 1);
        while (!body.empty() && body.front() == '\n') body.remove_prefix(1);
    }
    ss << body;
    return ss.str();
}

std::string SwapMealHandler::execute(const std::vector<std::string>& params) {
    std::string date = params.empty() ? today_date_str() : params[0];
    auto meals = sorted_meals(ctx_->meals);
    if (meals.empty()) return "No meals in the rotation.";

    int idx = meal_index_for_date(date, static_cast<int>(meals.size()));
    int next_idx = (idx + 1) % static_cast<int>(meals.size());

    return "Skipped \"" + meals[idx]->title + "\", "
           "today's meal is now: " + meals[next_idx]->title +
           " [id: " + meals[next_idx]->id + "]";
}

// --- Chore Handlers ---

std::string AddChoreHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: add_chore requires at least a name";

    const std::string& name = params[0];
    std::string color = params.size() > 1 ? params[1] : "";
    std::string recurrence = params.size() > 2 ? params[2] : "weekly";
    std::string day = params.size() > 3 ? params[3] : "";
    std::string details = params.size() > 4 ? params[4] : "";

    std::map<std::string, std::string> meta;
    if (!color.empty()) meta["color"] = color;
    meta["recurrence"] = recurrence;
    if (!day.empty()) meta["day"] = day;
    meta["completed_last"] = "";

    DataItem& item = ctx_->chores->add(name, meta, details);
    return "Added chore: \"" + name + "\" [id: " + item.id + "]";
}

std::string CompleteChoreHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: complete_chore requires an id";

    const std::string& id = params[0];
    const DataItem* item = ctx_->chores->find(id);
    if (!item) return "Error: chore not found: " + id;

    auto meta = item->meta;
    auto rec_it = meta.find("recurrence");
    std::string recurrence = (rec_it != meta.end()) ? rec_it->second : "";
    std::string title = item->title;

    if (recurrence == "one-shot") {
        ctx_->chores->remove(id);
        return "Completed and removed one-shot chore: \"" + title + "\"";
    }

    meta["completed_last"] = today_date_str();
    ctx_->chores->update(id, meta, item->body);
    return "Marked chore as completed: \"" + title + "\"";
}

std::string ListChoresHandler::execute(const std::vector<std::string>& params) {
    std::string date = params.empty() ? today_date_str() : params[0];

    // Parse day of week from date
    struct tm tm_buf{};
    std::string day_name;
    if (strptime(date.c_str(), "%Y-%m-%d", &tm_buf)) {
        mktime(&tm_buf); // normalize
        const char* days[] = {"sunday", "monday", "tuesday", "wednesday",
                              "thursday", "friday", "saturday"};
        day_name = days[tm_buf.tm_wday];
    }

    auto chores = ctx_->chores->filter([&day_name](const DataItem& item) {
        auto day_it = item.meta.find("day");
        if (day_it == item.meta.end()) return true; // no specific day = always show
        std::string item_day = day_it->second;
        for (auto& c : item_day) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
        return item_day == day_name;
    });

    if (chores.empty()) return "No chores due on " + date + ".";

    std::ostringstream ss;
    ss << "Chores for " << date << ":\n";
    for (const auto* item : chores) {
        ss << "- " << item->title;
        auto comp_it = item->meta.find("completed_last");
        if (comp_it != item->meta.end() && !comp_it->second.empty()) {
            ss << " [last completed: " << comp_it->second << "]";
        }
        ss << " [id: " << item->id << "]\n";
    }
    return ss.str();
}

std::string EditChoreHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: edit_chore requires an id";

    const std::string& id = params[0];
    const DataItem* item = ctx_->chores->find(id);
    if (!item) return "Error: chore not found: " + id;

    auto meta = item->meta;
    std::string body = item->body;

    if (params.size() > 1 && !params[1].empty()) {
        size_t nl = body.find('\n');
        std::string rest = (nl != std::string::npos) ? body.substr(nl) : "";
        body = "# " + params[1] + rest;
    }
    if (params.size() > 2 && !params[2].empty()) meta["color"] = params[2];
    if (params.size() > 3 && !params[3].empty()) meta["recurrence"] = params[3];
    if (params.size() > 4 && !params[4].empty()) meta["day"] = params[4];
    if (params.size() > 5 && !params[5].empty()) {
        size_t nl = body.find('\n');
        std::string heading = (nl != std::string::npos) ? body.substr(0, nl) : body;
        body = heading + "\n\n" + params[5] + "\n";
    }

    ctx_->chores->update(id, meta, body);
    return "Updated chore [id: " + id + "]";
}

std::string GetChoreDetailsHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: get_chore_details requires an id";

    const DataItem* item = ctx_->chores->find(params[0]);
    if (!item) return "Error: chore not found: " + params[0];

    std::ostringstream ss;
    ss << item->title << "\n";
    auto rec_it = item->meta.find("recurrence");
    if (rec_it != item->meta.end()) ss << "Recurrence: " << rec_it->second << "\n";
    auto day_it = item->meta.find("day");
    if (day_it != item->meta.end()) ss << "Day: " << day_it->second << "\n";
    auto color_it = item->meta.find("color");
    if (color_it != item->meta.end()) ss << "Color: " << color_it->second << "\n";
    ss << "\n";

    std::string_view body = item->body;
    size_t nl = body.find('\n');
    if (nl != std::string_view::npos) {
        body = body.substr(nl + 1);
        while (!body.empty() && body.front() == '\n') body.remove_prefix(1);
    }
    ss << body;
    return ss.str();
}

std::string DeleteChoreHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: delete_chore requires an id";

    const DataItem* item = ctx_->chores->find(params[0]);
    if (!item) return "Error: chore not found: " + params[0];

    std::string title = item->title;
    ctx_->chores->remove(params[0]);
    return "Deleted chore: \"" + title + "\"";
}

// --- Note Handlers ---

std::string SaveNoteHandler::execute(const std::vector<std::string>& params) {
    if (params.size() < 2) return "Error: save_note requires title and content";

    const std::string& title = params[0];
    const std::string& content = params[1];
    std::string tags = params.size() > 2 ? params[2] : "";

    // Get current datetime
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char datetime[32];
    strftime(datetime, sizeof(datetime), "%Y-%m-%dT%H:%M:%S", &tm_buf);

    std::map<std::string, std::string> meta;
    meta["created"] = datetime;
    if (!tags.empty()) meta["tags"] = tags;

    DataItem& item = ctx_->notes->add(title, meta, content);

    // Generate embedding and add to search index
    if (ctx_->note_search && ctx_->embed_fn) {
        std::string text_to_embed = title + " " + content;
        auto embedding = ctx_->embed_fn(text_to_embed);
        if (!embedding.empty()) {
            ctx_->note_search->add(item.id, embedding);
            ctx_->note_search->save();
        }
    }

    return "Saved note: \"" + title + "\" [id: " + item.id + "]";
}

std::string EditNoteHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: edit_note requires an id";

    const std::string& id = params[0];
    const DataItem* item = ctx_->notes->find(id);
    if (!item) return "Error: note not found: " + id;

    auto meta = item->meta;
    std::string body = item->body;
    std::string title = item->title;

    if (params.size() > 1 && !params[1].empty()) {
        title = params[1];
        size_t nl = body.find('\n');
        std::string rest = (nl != std::string::npos) ? body.substr(nl) : "";
        body = "# " + title + rest;
    }
    if (params.size() > 2 && !params[2].empty()) {
        // Replace content, keep heading
        body = "# " + title + "\n\n" + params[2] + "\n";
    }
    if (params.size() > 3 && !params[3].empty()) {
        meta["tags"] = params[3];
    }

    ctx_->notes->update(id, meta, body);

    // Re-index embedding
    if (ctx_->note_search && ctx_->embed_fn) {
        std::string text_to_embed = title + " " + (params.size() > 2 ? params[2] : "");
        auto embedding = ctx_->embed_fn(text_to_embed);
        if (!embedding.empty()) {
            ctx_->note_search->add(id, embedding);
            ctx_->note_search->save();
        }
    }

    return "Updated note: \"" + title + "\" [id: " + id + "]";
}

std::string SearchNotesHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: search_notes requires a query";

    if (!ctx_->note_search || !ctx_->note_search->is_initialized() || !ctx_->config) {
        // Fall back to title-based search
        std::string query = params[0];
        for (auto& c : query) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));

        std::ostringstream ss;
        ss << "Search results (title match):\n";
        bool found = false;
        for (const auto& item : ctx_->notes->items()) {
            std::string lower_title = item.title;
            for (auto& c : lower_title)
                c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
            if (lower_title.find(query) != std::string::npos) {
                ss << "- " << item.title << " [id: " << item.id << "]\n";
                found = true;
            }
        }
        if (!found) ss << "(no matches)";
        return ss.str();
    }

    // Semantic search via embeddings
    if (!ctx_->embed_fn) return "Error: embedding backend not available";
    auto embedding = ctx_->embed_fn(params[0]);
    if (embedding.empty()) return "Error: failed to generate embedding for query";

    auto results = ctx_->note_search->search(embedding, 5);
    if (results.empty()) return "No matching notes found.";

    std::ostringstream ss;
    ss << "Search results:\n";
    for (const auto& id : results) {
        const DataItem* item = ctx_->notes->find(id);
        if (item) {
            ss << "- " << item->title << " [id: " << item->id << "]\n";
        }
    }
    return ss.str();
}

std::string ListNotesHandler::execute(const std::vector<std::string>& /*params*/) {
    if (ctx_->notes->items().empty()) return "No notes saved.";

    std::ostringstream ss;
    ss << "All notes:\n";
    for (const auto& item : ctx_->notes->items()) {
        ss << "- " << item.title;
        auto tags_it = item.meta.find("tags");
        if (tags_it != item.meta.end() && !tags_it->second.empty()) {
            ss << " [tags: " << tags_it->second << "]";
        }
        ss << " [id: " << item.id << "]\n";
    }
    return ss.str();
}

std::string DeleteNoteHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: delete_note requires an id";

    const DataItem* item = ctx_->notes->find(params[0]);
    if (!item) return "Error: note not found: " + params[0];

    std::string title = item->title;

    // Remove from search index
    if (ctx_->note_search) {
        ctx_->note_search->remove(params[0]);
        ctx_->note_search->save();
    }

    ctx_->notes->remove(params[0]);
    return "Deleted note: \"" + title + "\"";
}

// --- Calendar Handlers (stubbed for Phase 1 — requires HTTPS) ---

std::string GetCalendarHandler::execute(const std::vector<std::string>& params) {
    if (!ctx_->calendar) return "Error: calendar not initialized";

    std::string start = params.size() > 0 && !params[0].empty() ? params[0] : today_date_str();
    std::string end = params.size() > 1 && !params[1].empty() ? params[1] : "";

    // If no end date, default to 14 days from start
    if (end.empty()) {
        struct tm tm_buf{};
        tm_buf.tm_isdst = -1;
        if (strptime(start.c_str(), "%Y-%m-%d", &tm_buf)) {
            tm_buf.tm_mday += 14;
            mktime(&tm_buf);
            char buf[16];
            strftime(buf, sizeof(buf), "%Y-%m-%d", &tm_buf);
            end = buf;
        }
    }

    auto events = ctx_->calendar->query_events(start, end);
    if (events.empty()) return "No calendar events from " + start + " to " + end + ".";

    std::ostringstream ss;
    ss << "Calendar events (" << start << " to " << end << "):\n";
    for (const auto& evt : events) {
        ss << "- " << evt.summary << " (" << evt.start_time;
        if (!evt.end_time.empty()) ss << " to " << evt.end_time;
        ss << ")";
        if (!evt.location.empty()) ss << " at " << evt.location;
        ss << " [id: " << evt.id << "]";
        if (!evt.description.empty()) ss << "\n  Description: " << evt.description;
        ss << "\n";
    }
    return ss.str();
}

std::string CreateCalendarEventHandler::execute(const std::vector<std::string>& params) {
    if (params.size() < 2) return "Error: create_calendar_event requires title and datetime";
    if (!ctx_->calendar) return "Error: calendar not initialized";

    int duration = params.size() > 2 && !params[2].empty() ? std::atoi(params[2].c_str()) : 60;
    if (duration <= 0) duration = 60;
    std::string recurrence = params.size() > 3 ? params[3] : "";

    std::string event_id = ctx_->calendar->create_event(params[0], params[1], duration, recurrence);
    if (event_id.empty()) return "Error: failed to create calendar event";

    bool is_local = event_id.find("local_") == 0;
    std::string result = "Created event: \"" + params[0] + "\" at " + params[1] +
           " (" + std::to_string(duration) + " min)";
    if (!recurrence.empty()) result += " [recurring: " + recurrence + "]";
    result += " [id: " + event_id + "]";
    if (is_local) result += "\nNote: Google Calendar is not connected. This event is stored locally only.";
    return result;
}

std::string EditCalendarEventHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: edit_calendar_event requires an id";
    if (!ctx_->calendar) return "Error: calendar not initialized";

    const std::string& id = params[0];
    std::string title = params.size() > 1 ? params[1] : "";
    std::string datetime = params.size() > 2 ? params[2] : "";
    int duration = params.size() > 3 && !params[3].empty() ? std::atoi(params[3].c_str()) : 0;

    bool ok = ctx_->calendar->edit_event(id, title, datetime, duration);
    if (!ok) return "Error: failed to edit calendar event: " + id;

    std::string result = "Updated calendar event [id: " + id + "]";
    if (!title.empty()) result += " title: \"" + title + "\"";
    if (!datetime.empty()) result += " time: " + datetime;
    return result;
}

std::string DeleteCalendarEventHandler::execute(const std::vector<std::string>& params) {
    if (params.empty()) return "Error: delete_calendar_event requires an id";
    if (!ctx_->calendar) return "Error: calendar not initialized";

    bool ok = ctx_->calendar->delete_event(params[0]);
    if (!ok) return "Error: failed to delete calendar event: " + params[0];

    return "Deleted calendar event: " + params[0];
}

// --- Weather Handler ---

// Synchronous HTTP via platform callbacks (same pattern as calendar.cpp)
struct WeatherSyncCtx {
    std::string response;
    int status = 0;
    bool done = false;
    std::mutex mtx;
    std::condition_variable cv;
};

static void weather_http_callback(const char* response, int status, void* ctx) {
    auto* sync = static_cast<WeatherSyncCtx*>(ctx);
    std::lock_guard<std::mutex> lk(sync->mtx);
    sync->response = response ? response : "";
    sync->status = status;
    sync->done = true;
    sync->cv.notify_one();
}

static std::string weather_http_get(PlatformCallbacks* cb, const std::string& url) {
    if (!cb || !cb->http_request) return "";
    WeatherSyncCtx ctx;
    cb->http_request("GET", url.c_str(), "", nullptr, weather_http_callback, &ctx);
    std::unique_lock<std::mutex> lk(ctx.mtx);
    ctx.cv.wait(lk, [&] { return ctx.done; });
    if (ctx.status < 200 || ctx.status >= 300) return "";
    return ctx.response;
}

// WMO weather code → human-readable description
static const char* wmo_description(int code) {
    switch (code) {
        case 0:  return "Clear sky";
        case 1:  return "Mainly clear";
        case 2:  return "Partly cloudy";
        case 3:  return "Overcast";
        case 45: case 48: return "Foggy";
        case 51: case 53: case 55: return "Drizzle";
        case 61: case 63: case 65: return "Rain";
        case 66: case 67: return "Freezing rain";
        case 71: case 73: case 75: return "Snow";
        case 77: return "Snow grains";
        case 80: case 81: case 82: return "Rain showers";
        case 85: case 86: return "Snow showers";
        case 95: return "Thunderstorm";
        case 96: case 99: return "Thunderstorm with hail";
        default: return "Unknown";
    }
}

std::string GetWeatherHandler::execute(const std::vector<std::string>& params) {
    if (!ctx_ || !ctx_->config || !ctx_->callbacks) return "Error: weather not available";
    if (!ctx_->config->weather_enabled) return "Error: weather is not enabled";
    if (ctx_->config->weather_lat == 0.0 && ctx_->config->weather_lon == 0.0)
        return "Error: weather location not configured (set zip code)";

    std::string date = params.empty() ? "" : params[0];
    if (date.empty()) {
        // Default to today
        time_t now = time(nullptr);
        struct tm tm_buf;
        localtime_r(&now, &tm_buf);
        char buf[16];
        strftime(buf, sizeof(buf), "%Y-%m-%d", &tm_buf);
        date = buf;
    }

    std::ostringstream url;
    url << "https://api.open-meteo.com/v1/forecast"
        << "?latitude=" << ctx_->config->weather_lat
        << "&longitude=" << ctx_->config->weather_lon
        << "&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,weathercode"
        << "&temperature_unit=fahrenheit"
        << "&timezone=auto"
        << "&start_date=" << date
        << "&end_date=" << date;

    std::string body = weather_http_get(ctx_->callbacks, url.str());
    if (body.empty()) return "Error: failed to fetch weather data";

    cJSON* root = cJSON_Parse(body.c_str());
    if (!root) return "Error: failed to parse weather response";

    std::string result;
    const cJSON* daily = cJSON_GetObjectItemCaseSensitive(root, "daily");
    if (daily) {
        const cJSON* temps_max = cJSON_GetObjectItemCaseSensitive(daily, "temperature_2m_max");
        const cJSON* temps_min = cJSON_GetObjectItemCaseSensitive(daily, "temperature_2m_min");
        const cJSON* precip = cJSON_GetObjectItemCaseSensitive(daily, "precipitation_sum");
        const cJSON* codes = cJSON_GetObjectItemCaseSensitive(daily, "weathercode");

        if (cJSON_IsArray(temps_max) && cJSON_GetArraySize(temps_max) > 0) {
            double hi = cJSON_GetArrayItem(temps_max, 0)->valuedouble;
            double lo = cJSON_GetArrayItem(temps_min, 0)->valuedouble;
            double rain = cJSON_IsArray(precip) ? cJSON_GetArrayItem(precip, 0)->valuedouble : 0;
            int code = cJSON_IsArray(codes) ? cJSON_GetArrayItem(codes, 0)->valueint : -1;

            std::ostringstream ss;
            ss << "Weather for " << date << ": "
               << wmo_description(code)
               << ". High: " << static_cast<int>(hi) << "\u00B0F"
               << ", Low: " << static_cast<int>(lo) << "\u00B0F";
            if (rain > 0.1) ss << ", Precipitation: " << rain << " mm";
            result = ss.str();
        } else {
            result = "No weather data available for " + date;
        }
    } else {
        result = "No daily forecast returned for " + date;
    }

    cJSON_Delete(root);
    return result;
}

// --- Registration ---

void register_all_tools(ToolRegistry& registry) {
    registry.register_handler(std::make_unique<SetReminderHandler>());
    registry.register_handler(std::make_unique<ListRemindersHandler>());
    registry.register_handler(std::make_unique<EditReminderHandler>());
    registry.register_handler(std::make_unique<DeleteReminderHandler>());
    registry.register_handler(std::make_unique<AddMealHandler>());
    registry.register_handler(std::make_unique<GetMealsHandler>());
    registry.register_handler(std::make_unique<GetMealDetailsHandler>());
    registry.register_handler(std::make_unique<EditMealHandler>());
    registry.register_handler(std::make_unique<DeleteMealHandler>());
    registry.register_handler(std::make_unique<SwapMealHandler>());
    registry.register_handler(std::make_unique<AddChoreHandler>());
    registry.register_handler(std::make_unique<EditChoreHandler>());
    registry.register_handler(std::make_unique<CompleteChoreHandler>());
    registry.register_handler(std::make_unique<ListChoresHandler>());
    registry.register_handler(std::make_unique<GetChoreDetailsHandler>());
    registry.register_handler(std::make_unique<DeleteChoreHandler>());
    registry.register_handler(std::make_unique<SaveNoteHandler>());
    registry.register_handler(std::make_unique<EditNoteHandler>());
    registry.register_handler(std::make_unique<SearchNotesHandler>());
    registry.register_handler(std::make_unique<ListNotesHandler>());
    registry.register_handler(std::make_unique<DeleteNoteHandler>());
    registry.register_handler(std::make_unique<GetCalendarHandler>());
    registry.register_handler(std::make_unique<CreateCalendarEventHandler>());
    registry.register_handler(std::make_unique<EditCalendarEventHandler>());
    registry.register_handler(std::make_unique<DeleteCalendarEventHandler>());
}
