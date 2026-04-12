#include "core.h"
#include "config.h"
#include "data_store.h"
#include "chat_history.h"
#include "tool_parser.h"
#include "tool_handler.h"
#include "tool_handlers.h"
#include "note_search.h"
#include "prompt_assembler.h"
#include "backend.h"
#include "task_queue.h"
#include "calendar.h"
#include "http_client.h"
#include "local_gemma.h"
#include "whisper_transcribe.h"
#include "cJSON.h"

#include <memory>
#include <string>
#include <cstdio>
#include <ctime>
#include <iostream>
#include <fstream>
#include <sstream>
#include <mutex>
#include <condition_variable>
#include <sys/stat.h>

// --- Globals (single instance) ---

static Config g_config;
static PlatformCallbacks g_callbacks{};
static ResponseCallback g_response_callback = nullptr;

static std::unique_ptr<DataStore> g_meals;
static std::unique_ptr<DataStore> g_chores;
static std::unique_ptr<DataStore> g_reminders;
static std::unique_ptr<DataStore> g_notes;
static std::unique_ptr<ChatHistory> g_chat;
static std::unique_ptr<NoteSearch> g_note_search;
static std::unique_ptr<TaskQueue> g_task_queue;
static std::unique_ptr<ToolRegistry> g_tools;
static std::unique_ptr<PromptAssembler> g_prompt;
static std::unique_ptr<CalendarManager> g_calendar;
static CoreContext g_ctx;

static std::string g_config_path;

// Buffers for returning C strings from query functions
static std::string g_query_buffer;

// Timer IDs
static const int HEARTBEAT_TIMER = 1;

// --- Helpers ---

static std::vector<float> embed_text(const std::string& text) {
    return local_gemma_embed(text);
}

// After stripping tool calls the model sometimes leaves nothing behind —
// it "forgot" to actually reply. Detect that and ask it once more for a
// plain natural-language response.
static bool is_blank(const std::string& s) {
    return s.find_first_not_of(" \n\r\t") == std::string::npos;
}

static void ensure_reply(const std::string& followup,
                         std::string& response,
                         std::string& clean_response) {
    if (!is_blank(clean_response)) return;
    std::string retry = followup +
        "\n\n## Assistant's Previous Response\n" + response +
        "\n\nYou did not reply to the user. Write a direct natural-language "
        "response now. Do not emit any tool calls.";
    response = Backend::execute(g_config, retry);
    clean_response = strip_tool_calls(response);
    if (is_blank(clean_response)) {
        clean_response = "[Error: model produced no reply after tool use]";
    }
}

static double time_for_today(const std::string& hhmm) {
    if (hhmm.size() < 5) return 0;
    int hour = std::atoi(hhmm.substr(0, 2).c_str());
    int min = std::atoi(hhmm.substr(3, 2).c_str());

    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    tm_buf.tm_hour = hour;
    tm_buf.tm_min = min;
    tm_buf.tm_sec = 0;
    return static_cast<double>(mktime(&tm_buf));
}

static double time_for_tomorrow(const std::string& hhmm) {
    return time_for_today(hhmm) + 86400.0;
}

static void populate_scheduled_tasks() {
    double now = static_cast<double>(time(nullptr));

    // Schedule enabled notifications
    for (const auto& [name, nc] : g_config.notifications) {
        if (!nc.enabled) continue;

        TaskType type;
        if (name == "daily_report") type = TaskType::DAILY_REPORT;
        else if (name == "calendar_heads_up") type = TaskType::CALENDAR_HEADS_UP;
        else if (name == "meal_prep_reminder") type = TaskType::MEAL_PREP_REMINDER;
        else if (name == "overdue_chores") type = TaskType::OVERDUE_CHORES;
        else if (name == "end_of_day_summary") type = TaskType::END_OF_DAY_SUMMARY;
        else continue;

        if (!nc.time.empty()) {
            double fire = time_for_today(nc.time);
            if (fire <= now) fire = time_for_tomorrow(nc.time);

            ScheduledTask task;
            task.fire_time = fire;
            task.type = type;
            task.task_id = name;
            g_task_queue->insert(std::move(task));
        }
    }

    // Schedule pending reminders
    for (const auto& item : g_reminders->items()) {
        auto status_it = item.meta.find("status");
        if (status_it == item.meta.end() || status_it->second != "pending") continue;

        auto dt_it = item.meta.find("datetime");
        if (dt_it == item.meta.end()) continue;

        struct tm tm_buf{};
        tm_buf.tm_isdst = -1;
        if (strptime(dt_it->second.c_str(), "%Y-%m-%dT%H:%M:%S", &tm_buf) ||
            strptime(dt_it->second.c_str(), "%Y-%m-%dT%H:%M", &tm_buf)) {
            double fire = static_cast<double>(mktime(&tm_buf));
            ScheduledTask task;
            task.fire_time = fire;
            task.type = TaskType::REMINDER;
            task.task_id = item.id;
            g_task_queue->insert(std::move(task));
        }
    }

    // Calendar sync
    if (g_config.calendar_sync_interval_minutes > 0) {
        ScheduledTask task;
        task.fire_time = now + g_config.calendar_sync_interval_minutes * 60.0;
        task.type = TaskType::CALENDAR_SYNC;
        task.task_id = "calendar_sync";
        g_task_queue->insert(std::move(task));
    }
}

// Run a proactive prompt through the backend, log to chat history, and notify.
// Works with or without Discord — the response lands in the chat log either way.
static void run_proactive(const char* label, std::string_view instruction) {
    std::string prompt = g_prompt->assemble_proactive(instruction, g_tools->get_definitions());
    std::string response = Backend::execute(g_config, prompt);

    // Parse and execute tool calls (same as message path)
    auto tool_calls = parse_tool_calls(response);
    std::string followup;
    bool had_tool_calls = !tool_calls.empty();
    // Log the triggering system instruction up front so proactive runs are
    // visible in chat history even if generation/tool calls later fail.
    g_chat->append_user("System", instruction);

    if (had_tool_calls) {
        std::string tool_results;
        for (const auto& call : tool_calls) {
            ToolHandler* handler = g_tools->find(call.name);
            std::string result;
            if (handler) {
                result = handler->execute(call.params);
                tool_results += "Tool " + call.name + " result: " + result + "\n";
            } else {
                result = "unknown tool";
                tool_results += "Tool " + call.name + ": unknown tool\n";
            }
            std::string params_joined;
            for (size_t i = 0; i < call.params.size(); ++i) {
                if (i > 0) params_joined += ", ";
                params_joined += "\"" + call.params[i] + "\"";
            }
            g_chat->append_tool(call.name + "(" + params_joined + ") -> " + result);
        }

        followup = prompt +
            "\n\n## Assistant's Previous Response\n" + response +
            "\n\n## Tool Results\n" + tool_results +
            "\n\nIncorporate the tool results into your response to the user. "
            "Do not use any more tools.";
        response = Backend::execute(g_config, followup);
    }

    std::string clean_response = strip_tool_calls(response);
    if (had_tool_calls) ensure_reply(followup, response, clean_response);
    bool is_error = clean_response.find("[Error:") == 0;

    g_chat->append_assistant(clean_response);

    // Send to Discord
    if (g_response_callback && !g_config.discord_channel_id.empty()) {
        g_response_callback(g_config.discord_channel_id.c_str(), clean_response.c_str());
    } else if (!is_error) {
        std::cout << "\n[" << label << "]\n" << clean_response << std::endl;
    }

    // Desktop notification
    if (!is_error && g_callbacks.send_notification) {
        std::string notif_body = clean_response.substr(0, 200);
        if (clean_response.size() > 200) notif_body += "...";
        g_callbacks.send_notification(label, notif_body.c_str());
    }
}

static void reschedule_notification(const char* name, TaskType type) {
    auto nc_it = g_config.notifications.find(name);
    if (nc_it != g_config.notifications.end() && nc_it->second.enabled) {
        ScheduledTask next;
        next.fire_time = time_for_tomorrow(nc_it->second.time);
        next.type = type;
        next.task_id = name;
        g_task_queue->insert(std::move(next));
    }
}

// Compute next fire time for a recurring reminder
static double next_recurrence(double last_fire, const std::string& recurrence) {
    time_t base = static_cast<time_t>(last_fire);
    struct tm tm_buf;
    localtime_r(&base, &tm_buf);
    tm_buf.tm_isdst = -1;

    if (recurrence == "daily") {
        tm_buf.tm_mday += 1;
    } else if (recurrence == "weekly") {
        tm_buf.tm_mday += 7;
    } else if (recurrence == "monthly") {
        tm_buf.tm_mon += 1;
    } else {
        return 0; // "once" or unknown — don't reschedule
    }

    time_t next = mktime(&tm_buf);
    return static_cast<double>(next);
}

static void execute_scheduled_task(const ScheduledTask& task) {
    double now = static_cast<double>(time(nullptr));

    switch (task.type) {
        case TaskType::REMINDER: {
            std::cerr << "[Reminder] Firing: " << task.task_id
                      << " fire_time=" << task.fire_time
                      << " now=" << now << std::endl;
            const DataItem* item = g_reminders->find(task.task_id);
            if (item) {
                std::string msg = "Reminder: " + item->title;
                std::string body = item->body;
                // Strip the # heading from body for the message
                size_t nl = body.find('\n');
                std::string detail = (nl != std::string::npos) ? body.substr(nl + 1) : "";
                while (!detail.empty() && (detail.front() == '\n' || detail.front() == '\r'))
                    detail.erase(detail.begin());

                std::string full_msg = msg;
                if (!detail.empty()) full_msg += "\n" + detail;

                // Log to chat history
                g_chat->append_assistant(full_msg);

                // Send to Discord
                if (g_response_callback && !g_config.discord_channel_id.empty()) {
                    g_response_callback(g_config.discord_channel_id.c_str(), full_msg.c_str());
                }

                // Desktop notification
                if (g_callbacks.send_notification) {
                    g_callbacks.send_notification("Reminder", item->title.c_str());
                }

                std::cout << "\n[REMINDER] " << full_msg << std::endl;

                auto meta = item->meta;
                auto rec_it = meta.find("recurrence");
                std::string recurrence = (rec_it != meta.end()) ? rec_it->second : "once";

                if (recurrence != "once" && !recurrence.empty()) {
                    // Recurring — reschedule for next occurrence
                    double next_fire = next_recurrence(task.fire_time, recurrence);
                    if (next_fire > 0) {
                        // Update the stored datetime to the next fire time
                        time_t next_t = static_cast<time_t>(next_fire);
                        struct tm tm_buf;
                        localtime_r(&next_t, &tm_buf);
                        char dt_buf[32];
                        strftime(dt_buf, sizeof(dt_buf), "%Y-%m-%dT%H:%M:%S", &tm_buf);
                        meta["datetime"] = dt_buf;
                        g_reminders->update(task.task_id, meta, item->body);

                        ScheduledTask next_task;
                        next_task.fire_time = next_fire;
                        next_task.type = TaskType::REMINDER;
                        next_task.task_id = task.task_id;
                        g_task_queue->insert(std::move(next_task));

                        std::cerr << "[Reminder] Rescheduled (" << recurrence
                                  << ") next: " << dt_buf << std::endl;
                    }
                } else {
                    // One-time — delete the reminder file
                    g_reminders->remove(task.task_id);
                }
            }
            break;
        }

        case TaskType::DAILY_REPORT:
            run_proactive("Daily Report", g_prompt->load_proactive_instruction("daily_report"));
            reschedule_notification("daily_report", TaskType::DAILY_REPORT);
            break;

        case TaskType::MEAL_PREP_REMINDER:
            run_proactive("Meal Prep", g_prompt->load_proactive_instruction("meal_prep"));
            reschedule_notification("meal_prep_reminder", TaskType::MEAL_PREP_REMINDER);
            break;

        case TaskType::OVERDUE_CHORES:
            run_proactive("Overdue Chores", g_prompt->load_proactive_instruction("overdue_chores"));
            reschedule_notification("overdue_chores", TaskType::OVERDUE_CHORES);
            break;

        case TaskType::END_OF_DAY_SUMMARY:
            run_proactive("End of Day", g_prompt->load_proactive_instruction("end_of_day"));
            reschedule_notification("end_of_day_summary", TaskType::END_OF_DAY_SUMMARY);
            break;

        case TaskType::CALENDAR_SYNC: {
            if (g_calendar) {
                g_calendar->sync();
            }
            // Reschedule
            ScheduledTask next;
            next.fire_time = now + g_config.calendar_sync_interval_minutes * 60.0;
            next.type = TaskType::CALENDAR_SYNC;
            next.task_id = "calendar_sync";
            g_task_queue->insert(std::move(next));
            break;
        }

        case TaskType::CALENDAR_HEADS_UP:
        case TaskType::HEARTBEAT:
            break;
    }
}

// --- Public API ---

void core_initialize(const char* config_path, PlatformCallbacks callbacks,
                     const char* working_dir_override) {
    g_config_path = config_path;
    g_callbacks = callbacks;

    // Load config
    if (!g_config.load(config_path)) {
        std::cerr << "Warning: could not load config from " << config_path << std::endl;
    }

    // Working directory priority: CLI flag > config > default "./working"
    std::string wd;
    if (working_dir_override && working_dir_override[0]) {
        wd = working_dir_override;
    } else if (!g_config.working_directory.empty()) {
        wd = g_config.working_directory;
    } else {
        wd = "./working";
    }
    g_config.working_directory = wd;
    mkdir(wd.c_str(), 0755);

    // Initialize data stores
    g_meals = std::make_unique<DataStore>(wd + "/meals");
    g_chores = std::make_unique<DataStore>(wd + "/chores");
    g_reminders = std::make_unique<DataStore>(wd + "/reminders");
    g_notes = std::make_unique<DataStore>(wd + "/notes");

    g_meals->load();
    g_chores->load();
    g_reminders->load();
    g_notes->load();

    // Chat history
    g_chat = std::make_unique<ChatHistory>(wd + "/chat");

    // Resolve relative model filenames to absolute paths (config stores just
    // filenames; models live in the working directory).
    auto resolve_path = [&wd](const std::string& filename) -> std::string {
        if (filename.empty() || filename[0] == '/') return filename;
        return wd + "/models/" + filename;
    };

    // Self-hosted Gemma (serves both chat generation and embeddings).
    // If this fails, the app keeps running; calls to Backend::execute will
    // return an error and the UI will surface it.
    if (!g_config.gemma_model_path.empty()) {
        local_gemma_init(resolve_path(g_config.gemma_model_path),
                         resolve_path(g_config.gemma_mmproj_path),
                         g_config.gemma_n_ctx);
    } else {
        std::cerr << "[Core] No Gemma model path configured — chat is disabled." << std::endl;
    }
    local_gemma_set_show_thinking(g_config.show_thinking);

    // Whisper transcription
    if (g_config.audio_backend == "whisper" && !g_config.whisper_model_path.empty()) {
        whisper_transcribe_init(resolve_path(g_config.whisper_model_path));
    }

    // Note search. Detect dimension mismatches from a prior model (e.g. the
    // old nomic-embed 768-dim index vs. Gemma's embed dim) via a sidecar
    // file that records the last-known dimension. If it differs, blow away
    // the stale index so NoteSearch can rebuild at the new dim.
    const int gemma_dim = local_gemma_embed_dim();
    const std::string dim_marker_path = wd + "/.embed_dim";
    if (gemma_dim > 0) {
        int prev_dim = 0;
        if (FILE* f = std::fopen(dim_marker_path.c_str(), "r")) {
            int v = 0;
            if (std::fscanf(f, "%d", &v) == 1) prev_dim = v;
            std::fclose(f);
        }
        if (prev_dim != 0 && prev_dim != gemma_dim) {
            std::remove((wd + "/notes.index").c_str());
            std::remove((wd + "/index_map.json").c_str());
            std::cerr << "[Core] Embedding dim changed (" << prev_dim << " -> "
                      << gemma_dim << "). Cleared note index; use reindex." << std::endl;
        }
        if (FILE* f = std::fopen(dim_marker_path.c_str(), "w")) {
            std::fprintf(f, "%d\n", gemma_dim);
            std::fclose(f);
        }
    }

    g_note_search = std::make_unique<NoteSearch>();
    g_note_search->initialize(wd, gemma_dim, g_config.max_notes_in_index);

    // Task queue
    g_task_queue = std::make_unique<TaskQueue>();

    // Tool registry
    g_tools = std::make_unique<ToolRegistry>();
    register_all_tools(*g_tools);

    // Geocode the weather zip if it changed since last cache.
    if (g_config.weather_enabled && !g_config.weather_zip.empty() &&
        g_config.weather_zip != g_config.weather_cached_zip) {
        std::string geo_url = "https://geocoding-api.open-meteo.com/v1/search?name="
            + g_config.weather_zip + "&count=1&language=en&format=json";
        // Use a simple sync HTTP via the platform callback (same pattern as calendar).
        struct GeoCtx { std::string resp; int status = 0; bool done = false;
                        std::mutex mtx; std::condition_variable cv; };
        GeoCtx geo;
        auto geo_cb = [](const char* r, int s, void* p) {
            auto* g = static_cast<GeoCtx*>(p);
            std::lock_guard<std::mutex> lk(g->mtx);
            g->resp = r ? r : ""; g->status = s; g->done = true; g->cv.notify_one();
        };
        if (g_callbacks.http_request) {
            g_callbacks.http_request("GET", geo_url.c_str(), "", nullptr, geo_cb, &geo);
            std::unique_lock<std::mutex> lk(geo.mtx);
            geo.cv.wait(lk, [&] { return geo.done; });
            if (geo.status >= 200 && geo.status < 300) {
                cJSON* root = cJSON_Parse(geo.resp.c_str());
                if (root) {
                    const cJSON* results = cJSON_GetObjectItemCaseSensitive(root, "results");
                    if (cJSON_IsArray(results) && cJSON_GetArraySize(results) > 0) {
                        const cJSON* first = cJSON_GetArrayItem(results, 0);
                        const cJSON* lat = cJSON_GetObjectItemCaseSensitive(first, "latitude");
                        const cJSON* lon = cJSON_GetObjectItemCaseSensitive(first, "longitude");
                        if (lat && lon) {
                            g_config.weather_lat = lat->valuedouble;
                            g_config.weather_lon = lon->valuedouble;
                            g_config.weather_cached_zip = g_config.weather_zip;
                            // Persist the cached lat/lon back to config.json.
                            // (The Swift side will pick it up on next loadConfig.)
                            std::string config_body;
                            {
                                std::ifstream in(g_config_path);
                                std::ostringstream ss;
                                ss << in.rdbuf();
                                config_body = ss.str();
                            }
                            cJSON* cfg = cJSON_Parse(config_body.c_str());
                            if (cfg) {
                                cJSON_DeleteItemFromObject(cfg, "weather_lat");
                                cJSON_DeleteItemFromObject(cfg, "weather_lon");
                                cJSON_DeleteItemFromObject(cfg, "weather_cached_zip");
                                cJSON_AddNumberToObject(cfg, "weather_lat", g_config.weather_lat);
                                cJSON_AddNumberToObject(cfg, "weather_lon", g_config.weather_lon);
                                cJSON_AddStringToObject(cfg, "weather_cached_zip",
                                                        g_config.weather_cached_zip.c_str());
                                char* json = cJSON_PrintUnformatted(cfg);
                                std::ofstream out(g_config_path, std::ios::trunc);
                                out << json;
                                free(json);
                                cJSON_Delete(cfg);
                            }
                            std::cerr << "[Weather] Geocoded zip " << g_config.weather_zip
                                      << " -> lat=" << g_config.weather_lat
                                      << " lon=" << g_config.weather_lon << std::endl;
                        }
                    }
                    cJSON_Delete(root);
                }
            }
        }
    }

    // Conditionally register the weather tool only if weather is enabled.
    if (g_config.weather_enabled && !g_config.weather_zip.empty()) {
        g_tools->register_handler(std::make_unique<GetWeatherHandler>());
    }

    // Conditionally register the web_search tool.
    if (g_config.web_search_enabled) {
        g_tools->register_handler(std::make_unique<WebSearchHandler>());
    }

    // Set up context
    g_ctx.config = &g_config;
    g_ctx.callbacks = &g_callbacks;
    g_ctx.meals = g_meals.get();
    g_ctx.chores = g_chores.get();
    g_ctx.reminders = g_reminders.get();
    g_ctx.notes = g_notes.get();
    g_ctx.note_search = g_note_search.get();
    g_ctx.task_queue = g_task_queue.get();
    g_ctx.embed_fn = [](const std::string& text) { return local_gemma_embed(text); };

    // Calendar
    g_calendar = std::make_unique<CalendarManager>();
    g_calendar->initialize(&g_config, &g_callbacks);
    g_ctx.calendar = g_calendar.get();

    g_tools->set_context(&g_ctx);

    // Prompt assembler
    g_prompt = std::make_unique<PromptAssembler>(
        g_config, *g_meals, *g_chores, *g_reminders, *g_notes, *g_chat,
        g_calendar.get());
    PromptAssembler::write_defaults(g_config.working_directory);

    // Populate scheduled tasks
    populate_scheduled_tasks();

    std::cerr << "Core initialized. Working directory: " << wd << std::endl;
    std::cerr << "Loaded: " << g_meals->items().size() << " meals, "
              << g_chores->items().size() << " chores, "
              << g_reminders->items().size() << " reminders, "
              << g_notes->items().size() << " notes" << std::endl;
}

void core_shutdown() {
    whisper_transcribe_shutdown();
    local_gemma_shutdown();
    if (g_note_search) g_note_search->save();
    g_prompt.reset();
    g_tools.reset();
    g_calendar.reset();
    g_task_queue.reset();
    g_note_search.reset();
    g_chat.reset();
    g_notes.reset();
    g_reminders.reset();
    g_chores.reset();
    g_meals.reset();
}

// Shared implementation for chat messages (from Discord or the local Chat tab).
// channel_id / message_id are optional (empty for local chat). image_path is
// optional and only used for local chat with a loaded vision projector.
static void handle_message_impl(const std::string& user_str,
                                const std::string& text_str,
                                const std::string& image_path,
                                const std::string& channel_id_in,
                                const std::string& message_id) {
    std::string chan_str = channel_id_in;
    const std::string& msg_str = message_id;

    // If no channel specified, use the configured Discord channel
    if (chan_str.empty()) {
        chan_str = g_config.discord_channel_id;
    }

    if (text_str.empty() && image_path.empty()) return;

    // Add acknowledgment reaction (crab emoji by default)
    if (g_callbacks.add_reaction && !chan_str.empty() && !msg_str.empty()
        && !g_config.assistant_emoji.empty()) {
        g_callbacks.add_reaction(chan_str.c_str(), msg_str.c_str(),
                                g_config.assistant_emoji.c_str());
    }

    // Append to chat history
    g_chat->append_user(user_str, text_str.empty() ? "(image)" : text_str);

    // Get embedding for note search (text only — images don't embed)
    std::vector<std::string> relevant_note_ids;
    if (!text_str.empty()) {
        auto query_embedding = embed_text(text_str);
        if (!query_embedding.empty() && g_note_search->is_initialized()) {
            relevant_note_ids = g_note_search->search(query_embedding, g_config.note_search_results);
        }
    }

    // Assemble prompt
    // Use "Local" for messages from the desktop UI, otherwise the Discord username
    std::string display_name = (user_str == "User") ? "Local" : user_str;
    std::string prompt = g_prompt->assemble(text_str, display_name, relevant_note_ids,
                                            g_tools->get_definitions());

    // Execute backend (with optional image)
    std::string response = Backend::execute(g_config, prompt, image_path);

    // Parse tool calls
    auto tool_calls = parse_tool_calls(response);

    // If tool calls found, execute them and do a follow-up
    std::vector<std::string> tool_emojis;
    std::string followup;
    bool had_tool_calls = !tool_calls.empty();
    if (had_tool_calls) {
        std::string tool_results;
        for (const auto& call : tool_calls) {
            ToolHandler* handler = g_tools->find(call.name);
            if (handler) {
                std::string result = handler->execute(call.params);
                tool_results += "Tool " + call.name + " result: " + result + "\n";
                g_chat->append_tool(call.name + "(" +
                    [&]() {
                        std::string p;
                        for (size_t i = 0; i < call.params.size(); ++i) {
                            if (i > 0) p += ", ";
                            p += "\"" + call.params[i] + "\"";
                        }
                        return p;
                    }() + ") -> " + result);

                // Map tool to emoji
                if (call.name == "set_reminder" || call.name == "list_reminders" || call.name == "edit_reminder" || call.name == "delete_reminder")
                    tool_emojis.push_back("\xF0\x9F\x94\x94"); // 🔔
                else if (call.name == "add_chore" || call.name == "edit_chore" || call.name == "complete_chore" || call.name == "list_chores" || call.name == "delete_chore")
                    tool_emojis.push_back("\xF0\x9F\x92\xAF"); // 💯
                else if (call.name == "save_note" || call.name == "edit_note" || call.name == "search_notes" || call.name == "list_notes" || call.name == "delete_note")
                    tool_emojis.push_back("\xF0\x9F\x93\x9D"); // 📝
                else if (call.name == "add_meal" || call.name == "edit_meal" || call.name == "delete_meal" || call.name == "get_meals" || call.name == "get_meal_details" || call.name == "swap_meal")
                    tool_emojis.push_back("\xF0\x9F\x8D\x96"); // 🍖
                else if (call.name == "get_calendar" || call.name == "create_calendar_event" || call.name == "edit_calendar_event" || call.name == "delete_calendar_event")
                    tool_emojis.push_back("\xF0\x9F\x93\x85"); // 📅
                else if (call.name == "web_search")
                    tool_emojis.push_back("\xF0\x9F\x8C\x90"); // 🌐
            } else {
                tool_results += "Tool " + call.name + ": unknown tool\n";
            }
        }

        // Follow-up prompt with tool results — text-only (no need to re-feed the image)
        followup = prompt +
            "\n\n## Assistant's Previous Response\n" + response +
            "\n\n## Tool Results\n" + tool_results +
            "\n\nIncorporate the tool results into your response to the user. "
            "Do not use any more tools.";

        response = Backend::execute(g_config, followup);
    }

    // Strip any remaining tool calls from final response
    std::string clean_response = strip_tool_calls(response);
    if (had_tool_calls) ensure_reply(followup, response, clean_response);

    bool is_error = clean_response.find("[Error:") == 0;

    // Always log to chat history so the local UI can display errors.
    g_chat->append_assistant(clean_response);

    // Send to Discord (errors are useful feedback there)
    if (g_response_callback && !chan_str.empty()) {
        g_response_callback(chan_str.c_str(), clean_response.c_str());
    } else {
        std::cout << clean_response << std::endl;
    }

    // Add tool-specific emoji reactions (these stay permanently)
    if (g_callbacks.add_reaction && !chan_str.empty() && !msg_str.empty()) {
        for (const auto& emoji : tool_emojis) {
            g_callbacks.add_reaction(chan_str.c_str(), msg_str.c_str(), emoji.c_str());
        }
    }

    // Remove acknowledgment reaction once response is ready
    if (g_callbacks.remove_reaction && !chan_str.empty() && !msg_str.empty()
        && !g_config.assistant_emoji.empty()) {
        g_callbacks.remove_reaction(chan_str.c_str(), msg_str.c_str(),
                                   g_config.assistant_emoji.c_str());
    }
}

void core_on_message_received(const char* user, const char* text,
                              const char* channel_id, const char* message_id,
                              const char* image_path) {
    handle_message_impl(
        user    ? user    : "User",
        text    ? text    : "",
        image_path ? image_path : "",
        channel_id ? channel_id : "",
        message_id ? message_id : "");
}

void core_send_message_with_image(const char* user, const char* text,
                                  const char* image_path) {
    handle_message_impl(
        user       ? user       : "User",
        text       ? text       : "",
        image_path ? image_path : "",
        /*channel_id=*/"",
        /*message_id=*/"");
}

int core_is_gemma_loaded(void) {
    return local_gemma_is_loaded() ? 1 : 0;
}

int core_has_vision(void) {
    return local_gemma_has_vision() ? 1 : 0;
}

void core_on_connected() {
    std::cerr << "Connected." << std::endl;
}

void core_on_disconnected() {
    std::cerr << "Disconnected." << std::endl;
}

void core_on_timer_fired(int timer_id) {
    if (timer_id == HEARTBEAT_TIMER) {
        double now = static_cast<double>(time(nullptr));
        while (g_task_queue && g_task_queue->has_pending(now)) {
            auto task = g_task_queue->pop_next();
            execute_scheduled_task(task);
        }
    }
}

void core_on_config_changed() {
    std::string old_model_path  = g_config.gemma_model_path;
    std::string old_mmproj_path = g_config.gemma_mmproj_path;
    int         old_n_ctx       = g_config.gemma_n_ctx;

    g_config.load(g_config_path);

    // Resolve relative filenames to absolute paths.
    std::string wd = g_config.working_directory;
    auto resolve_path = [&wd](const std::string& filename) -> std::string {
        if (filename.empty() || filename[0] == '/') return filename;
        return wd + "/models/" + filename;
    };

    // Re-init Gemma if any of the model-related fields changed.
    if (g_config.gemma_model_path  != old_model_path  ||
        g_config.gemma_mmproj_path != old_mmproj_path ||
        g_config.gemma_n_ctx       != old_n_ctx) {
        local_gemma_shutdown();
        if (!g_config.gemma_model_path.empty()) {
            local_gemma_init(resolve_path(g_config.gemma_model_path),
                             resolve_path(g_config.gemma_mmproj_path),
                             g_config.gemma_n_ctx);
        }
    }
    local_gemma_set_show_thinking(g_config.show_thinking);

    // Re-populate scheduled tasks
    if (g_task_queue) {
        g_task_queue->remove_by_type(TaskType::DAILY_REPORT);
        g_task_queue->remove_by_type(TaskType::MEAL_PREP_REMINDER);
        g_task_queue->remove_by_type(TaskType::OVERDUE_CHORES);
        g_task_queue->remove_by_type(TaskType::END_OF_DAY_SUMMARY);
        g_task_queue->remove_by_type(TaskType::CALENDAR_SYNC);
        populate_scheduled_tasks();
    }
}

// --- UI Query Functions ---

static std::string items_to_json(const DataStore& store) {
    cJSON* arr = cJSON_CreateArray();
    for (const auto& item : store.items()) {
        cJSON* obj = cJSON_CreateObject();
        cJSON_AddStringToObject(obj, "id", item.id.c_str());
        cJSON_AddStringToObject(obj, "title", item.title.c_str());
        for (const auto& [key, val] : item.meta) {
            cJSON_AddStringToObject(obj, key.c_str(), val.c_str());
        }
        cJSON_AddItemToArray(arr, obj);
    }
    char* json = cJSON_PrintUnformatted(arr);
    std::string result = json;
    free(json);
    cJSON_Delete(arr);
    return result;
}

const char* core_get_meals() {
    g_query_buffer = items_to_json(*g_meals);
    return g_query_buffer.c_str();
}

const char* core_get_chores() {
    g_query_buffer = items_to_json(*g_chores);
    return g_query_buffer.c_str();
}

const char* core_get_reminders() {
    g_query_buffer = items_to_json(*g_reminders);
    return g_query_buffer.c_str();
}

const char* core_get_notes() {
    g_query_buffer = items_to_json(*g_notes);
    return g_query_buffer.c_str();
}

const char* core_get_chat_history(const char* date) {
    if (!date) return "";
    std::string path = g_config.working_directory + "/chat/" + std::string(date) + ".md";
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) { g_query_buffer.clear(); return g_query_buffer.c_str(); }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    g_query_buffer.resize(static_cast<size_t>(len));
    fread(g_query_buffer.data(), 1, static_cast<size_t>(len), f);
    fclose(f);
    return g_query_buffer.c_str();
}

// --- Phase 1: Check heartbeat from main loop ---

extern "C" void core_check_tasks() {
    core_on_timer_fired(HEARTBEAT_TIMER);
}

extern "C" void core_set_calendar_token(const char* token) {
    if (token) {
        g_config.calendar_api_token = token;
    }
}

extern "C" int core_calendar_sync() {
    if (!g_calendar) return 0;
    return g_calendar->sync(true) ? 1 : 0;  // force full sync
}

extern "C" void core_reload_data() {
    if (g_meals) g_meals->load();
    if (g_chores) g_chores->load();
    if (g_reminders) g_reminders->load();
    if (g_notes) g_notes->load();
}

extern "C" void core_write_prompt_defaults(const char* working_dir) {
    if (!working_dir || !*working_dir) return;
    PromptAssembler::write_defaults(working_dir);
}

extern "C" void core_append_assistant(const char* text) {
    if (!g_chat || !text) return;
    g_chat->append_assistant(text);
}

extern "C" void core_reindex_note(const char* note_id) {
    if (!note_id || !g_notes || !g_note_search) return;

    // Reload the data store to pick up file changes
    g_notes->load();

    const DataItem* item = g_notes->find(note_id);
    if (!item) return;

    // Re-embed and update index
    std::string text_to_embed = item->title + " " + item->body;
    auto embedding = embed_text(text_to_embed);
    if (!embedding.empty()) {
        g_note_search->add(std::string(note_id), embedding);
        g_note_search->save();
        std::cerr << "[Embedding] Re-indexed note: " << note_id << std::endl;
    }
}

extern "C" void core_set_response_callback(ResponseCallback callback) {
    g_response_callback = callback;
    std::cerr << "[Core] Response callback " << (callback ? "set" : "cleared") << std::endl;
}

extern "C" const char* core_execute_tool(const char* tool_name, const char* params_json) {
    if (!tool_name || !g_tools) return nullptr;

    ToolHandler* handler = g_tools->find(tool_name);
    if (!handler) return nullptr;

    // Parse params_json as a JSON array of strings: ["param1", "param2", ...]
    std::vector<std::string> params;
    if (params_json) {
        cJSON* arr = cJSON_Parse(params_json);
        if (arr && cJSON_IsArray(arr)) {
            const cJSON* item = nullptr;
            cJSON_ArrayForEach(item, arr) {
                if (cJSON_IsString(item) && item->valuestring) {
                    params.push_back(item->valuestring);
                }
            }
        }
        cJSON_Delete(arr);
    }

    std::string result = handler->execute(params);

    // Return a heap-allocated copy the caller frees with core_free_string
    char* copy = static_cast<char*>(malloc(result.size() + 1));
    memcpy(copy, result.c_str(), result.size() + 1);
    return copy;
}

extern "C" const char* core_transcribe_audio(const char* file_path) {
    if (!file_path) return nullptr;
    if (g_config.audio_backend != "whisper" || !whisper_transcribe_is_loaded()) return nullptr;

    std::string result = whisper_transcribe_audio(file_path);
    if (result.empty()) return nullptr;

    char* copy = static_cast<char*>(malloc(result.size() + 1));
    memcpy(copy, result.c_str(), result.size() + 1);
    return copy;
}

extern "C" void core_free_string(const char* str) {
    free(const_cast<char*>(str));
}
