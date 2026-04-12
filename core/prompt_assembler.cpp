#include "prompt_assembler.h"
#include "config.h"
#include "data_store.h"
#include "chat_history.h"
#include "calendar.h"

#include <ctime>
#include <sstream>
#include <cstdio>
#include <fstream>
#include <sys/stat.h>

static std::string current_datetime_str() {
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char buf[64];
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tm_buf);
    return buf;
}

static std::string current_day_of_week() {
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    const char* days[] = {"Sunday", "Monday", "Tuesday", "Wednesday",
                          "Thursday", "Friday", "Saturday"};
    return days[tm_buf.tm_wday];
}

static std::string today_date_str() {
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char buf[16];
    strftime(buf, sizeof(buf), "%Y-%m-%d", &tm_buf);
    return buf;
}

static int today_day_of_month() {
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    return tm_buf.tm_mday;
}

static std::string lowercase(std::string_view s) {
    std::string r(s);
    for (auto& c : r) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    return r;
}

// --- File I/O helpers ---

static std::string read_file(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return {};
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::string buf(static_cast<size_t>(len), '\0');
    if (len > 0) fread(&buf[0], 1, static_cast<size_t>(len), f);
    fclose(f);
    return buf;
}

static void write_file_if_missing(const std::string& path, const std::string& content) {
    FILE* f = fopen(path.c_str(), "r");
    if (f) { fclose(f); return; } // already exists
    std::ofstream out(path, std::ios::trunc);
    out << content;
}

// --- Template substitution ---

static std::string substitute(const std::string& tmpl,
                              const std::string& assistant_name,
                              const std::string& tool_definitions) {
    std::string result = tmpl;

    auto replace_all = [&](const std::string& token, const std::string& value) {
        size_t pos = 0;
        while ((pos = result.find(token, pos)) != std::string::npos) {
            result.replace(pos, token.size(), value);
            pos += value.size();
        }
    };

    replace_all("{{assistant_name}}", assistant_name);
    replace_all("{{datetime}}", current_datetime_str());
    replace_all("{{date}}", today_date_str());
    replace_all("{{day_of_week}}", current_day_of_week());
    replace_all("{{tools}}", tool_definitions);

    return result;
}

// --- Default templates ---

static const char* DEFAULT_SYSTEM_PROMPT =
R"(You are {{assistant_name}}, my personal assistant. You are helpful, concise, and proactive.
Current date and time: {{datetime}}
Today is {{day_of_week}}.

You have access to the following tools. When you want to use a tool,
respond with the exact format:
<<TOOL:tool_name(param1, param2, ...)>>

Available tools:
{{tools}})";

static const char* DEFAULT_DAILY_REPORT =
R"(Generate my morning briefing for today. Include today's meals, calendar events, due chores, and upcoming reminders.{{weather_hint}})";

static const char* DEFAULT_END_OF_DAY =
R"(Generate my end-of-day summary. What got done today, what didn't, and a preview of tomorrow.{{weather_hint}})";

static const char* DEFAULT_MEAL_PREP =
R"(What's for dinner tonight? Give a brief meal prep reminder including any prep that should be started now.)";

static const char* DEFAULT_OVERDUE_CHORES =
R"(List any overdue chores that need attention today.)";

static const char* NOTES_CONTENT =
R"(# Prompt Template Substitutions

The following {{variables}} are replaced at runtime in the prompt files below:

  {{assistant_name}}  - The assistant's name from config (e.g. "Friday")
  {{datetime}}        - Current date and time (e.g. "2026-03-29 17:30:00")
  {{date}}            - Current date (e.g. "2026-03-29")
  {{day_of_week}}     - Current day name (e.g. "Sunday")
  {{tools}}           - The full list of available tool definitions
  {{weather_hint}}    - Expands to a "use the get_weather tool" instruction
                        when weather is enabled in settings, otherwise empty.
                        Only meaningful in daily_report.md and end_of_day.md.

## Files

  system_prompt.md    - Sent at the start of every AI call.
                        Defines the assistant's personality and tool instructions.
                        Put any user profile / preferences / persistent context
                        (dietary restrictions, wake time, chore meanings, etc.)
                        here as well.

  daily_report.md     - Instruction the assistant gives itself for the morning briefing.
  meal_prep.md        - Instruction for the meal-prep reminder.
  overdue_chores.md   - Instruction for the overdue-chores nag.
  end_of_day.md       - Instruction for the end-of-day summary.

  notes.txt           - This file. Reference only, not sent to the AI.

## Image Attachments (Claude Code backend)

When the backend is "claude", image attachments on Discord are handled
automatically -- no template file controls it. The flow: the image is
downloaded to working/tmp/, the path is appended to the current user
message with an explicit "Use your Read tool on this path" instruction,
Claude reads it, and the tmp file is deleted after the response.

The image directive is NOT stored in chat history -- only your caption
text is persisted, so future prompts never reference deleted files.

To change HOW the assistant describes images (e.g. "be terse about
images", "always extract any visible text"), add that guidance to
system_prompt.md. The directive itself is deliberately hardcoded so
Claude reliably uses the Read tool.

## Editing

Edit these files with any text editor (or via the Prompts tab in the app).
Changes take effect on the next AI call — the files are re-read each time.
Delete a file to regenerate its default on next launch.
)";

// --- Write defaults on startup (or whenever called) ---

void PromptAssembler::write_defaults() const {
    std::string prompts_dir = config_.working_directory + "/prompts";
    mkdir(prompts_dir.c_str(), 0755);

    write_file_if_missing(prompts_dir + "/system_prompt.md", DEFAULT_SYSTEM_PROMPT);
    write_file_if_missing(prompts_dir + "/daily_report.md", DEFAULT_DAILY_REPORT);
    write_file_if_missing(prompts_dir + "/end_of_day.md", DEFAULT_END_OF_DAY);
    write_file_if_missing(prompts_dir + "/meal_prep.md", DEFAULT_MEAL_PREP);
    write_file_if_missing(prompts_dir + "/overdue_chores.md", DEFAULT_OVERDUE_CHORES);
    write_file_if_missing(prompts_dir + "/notes.txt", NOTES_CONTENT);
}

// --- Build methods ---

PromptAssembler::PromptAssembler(const Config& config, DataStore& meals,
                                 DataStore& chores, DataStore& reminders,
                                 DataStore& notes, ChatHistory& history,
                                 CalendarManager* calendar)
    : config_(config), meals_(meals), chores_(chores),
      reminders_(reminders), notes_(notes), history_(history),
      calendar_(calendar) {}

std::string PromptAssembler::build_system_prompt(
    const std::string& tool_definitions) const {
    std::string prompts_dir = config_.working_directory + "/prompts";

    // Try to load from file, fall back to default
    std::string tmpl = read_file(prompts_dir + "/system_prompt.md");
    if (tmpl.empty()) tmpl = DEFAULT_SYSTEM_PROMPT;

    return substitute(tmpl, config_.assistant_name, tool_definitions);
}

std::string PromptAssembler::build_user_profile() const {
    std::string prompts_dir = config_.working_directory + "/prompts";

    std::string tmpl = read_file(prompts_dir + "/profile.md");
    if (tmpl.empty()) return {};

    return substitute(tmpl, config_.assistant_name, "");
}

std::string PromptAssembler::load_instruction(const std::string& name,
                                               const std::string& zip_code,
                                               const std::string& day) const {
    std::string prompts_dir = config_.working_directory + "/prompts";
    std::string tmpl = read_file(prompts_dir + "/" + name + ".md");

    if (tmpl.empty()) {
        // Fall back to built-in defaults so the system still works if the
        // file is missing or unreadable.
        if (name == "daily_report")         tmpl = DEFAULT_DAILY_REPORT;
        else if (name == "end_of_day")      tmpl = DEFAULT_END_OF_DAY;
        else if (name == "meal_prep")       tmpl = DEFAULT_MEAL_PREP;
        else if (name == "overdue_chores")  tmpl = DEFAULT_OVERDUE_CHORES;
        else return {};
    }

    // Compose the weather_hint expansion (only non-empty when enabled).
    std::string weather_hint;
    if (!zip_code.empty() && !day.empty()) {
        if (day == "today") {
            weather_hint = " Also include today's weather — call get_weather with location \""
                         + zip_code + "\" and day \"today\".";
        } else if (day == "tomorrow") {
            weather_hint = " Also include tomorrow's weather forecast — call get_weather with location \""
                         + zip_code + "\" and day \"tomorrow\".";
        }
    }

    std::string result = substitute(tmpl, config_.assistant_name, "");

    const std::string token = "{{weather_hint}}";
    size_t pos = 0;
    while ((pos = result.find(token, pos)) != std::string::npos) {
        result.replace(pos, token.size(), weather_hint);
        pos += weather_hint.size();
    }
    return result;
}

std::string PromptAssembler::build_reminders_context() const {
    std::ostringstream ss;

    auto pending = reminders_.filter([&](const DataItem& item) {
        auto it = item.meta.find("status");
        return it != item.meta.end() && it->second == "pending";
    });

    auto fired = reminders_.filter([&](const DataItem& item) {
        auto it = item.meta.find("status");
        return it != item.meta.end() && it->second != "pending";
    });

    if (!pending.empty()) {
        ss << "### Upcoming Reminders\n";
        int count = 0;
        for (const auto* item : pending) {
            if (count++ >= 14) break;
            auto dt_it = item->meta.find("datetime");
            ss << "- " << item->title;
            if (dt_it != item->meta.end()) ss << " (at " << dt_it->second << ")";
            ss << " [id: " << item->id << "]\n";
        }
    }

    if (!fired.empty()) {
        ss << "### Recently Fired Reminders\n";
        int count = 0;
        for (auto it = fired.rbegin(); it != fired.rend() && count < 2; ++it, ++count) {
            ss << "- " << (*it)->title << " [id: " << (*it)->id << "]\n";
        }
    }

    return ss.str();
}

std::string PromptAssembler::build_chores_context() const {
    std::ostringstream ss;

    auto all_chores = chores_.filter([](const DataItem&) { return true; });

    if (!all_chores.empty()) {
        ss << "### Chores\n";
        for (const auto* item : all_chores) {
            ss << "- " << item->title;
            auto rec_it = item->meta.find("recurrence");
            auto day_it = item->meta.find("day");
            auto comp_it = item->meta.find("completed_last");
            auto color_it = item->meta.find("color");

            if (rec_it != item->meta.end())
                ss << " (" << rec_it->second;
            if (day_it != item->meta.end())
                ss << ", " << day_it->second;
            if (rec_it != item->meta.end())
                ss << ")";
            if (comp_it != item->meta.end())
                ss << " [last completed: " << comp_it->second << "]";
            if (color_it != item->meta.end())
                ss << " [color: " << color_it->second << "]";
            ss << " [id: " << item->id << "]\n";
        }
    }

    return ss.str();
}

std::string PromptAssembler::build_meals_context() const {
    // Sort meals by id (numeric prefix controls order)
    std::vector<const DataItem*> meals;
    for (const auto& item : meals_.items()) meals.push_back(&item);
    std::sort(meals.begin(), meals.end(),
              [](const DataItem* a, const DataItem* b) { return a->id < b->id; });

    if (meals.empty()) return "";

    // Today's meal: day_of_year % num_meals
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    int idx = tm_buf.tm_yday % static_cast<int>(meals.size());

    std::ostringstream ss;
    ss << "### Today's Meal\n";
    ss << "- " << meals[idx]->title;
    auto type_it = meals[idx]->meta.find("type");
    if (type_it != meals[idx]->meta.end()) ss << " (" << type_it->second << ")";
    ss << " [id: " << meals[idx]->id << "] (#" << (idx + 1) << " of " << meals.size() << ")\n";

    ss << "### Full Rotation\n";
    for (size_t i = 0; i < meals.size(); i++) {
        ss << (i + 1) << ". " << meals[i]->title;
        auto t_it = meals[i]->meta.find("type");
        if (t_it != meals[i]->meta.end()) ss << " (" << t_it->second << ")";
        ss << " [id: " << meals[i]->id << "]\n";
    }

    return ss.str();
}

std::string PromptAssembler::build_notes_context(
    const std::vector<std::string>& relevant_note_ids) const {
    if (relevant_note_ids.empty()) return {};

    std::ostringstream ss;
    ss << "### Relevant Notes\n";
    for (const auto& id : relevant_note_ids) {
        const DataItem* item = notes_.find(id);
        if (!item) continue;
        ss << "#### " << item->title << "\n";
        std::string_view body = item->body;
        size_t first_nl = body.find('\n');
        if (first_nl != std::string_view::npos) {
            body = body.substr(first_nl + 1);
        }
        while (!body.empty() && (body.front() == '\n' || body.front() == '\r'))
            body.remove_prefix(1);
        ss << body << "\n\n";
    }
    return ss.str();
}

std::string PromptAssembler::build_calendar_context() const {
    if (!calendar_) return {};

    auto events = calendar_->get_cached_events("", "");
    if (events.empty()) return {};

    std::ostringstream ss;
    ss << "### Upcoming Calendar Events (cached)\n";
    for (const auto& evt : events) {
        ss << "- " << evt.summary << " (" << evt.start_time;
        if (!evt.end_time.empty()) ss << " to " << evt.end_time;
        ss << ")";
        if (!evt.location.empty()) ss << " at " << evt.location;
        ss << " [id: " << evt.id << "]";
        if (!evt.description.empty()) ss << "\n  Description: " << evt.description;
        ss << "\n";
    }
    ss << "\nNote: Use get_calendar tool to search any date range (past or future).\n";
    return ss.str();
}

std::string PromptAssembler::build_dynamic_context(
    const std::vector<std::string>& relevant_note_ids) const {
    std::ostringstream ss;
    ss << "## Current Context\n\n";

    std::string calendar = build_calendar_context();
    std::string reminders = build_reminders_context();
    std::string chores = build_chores_context();
    std::string meals = build_meals_context();
    std::string notes = build_notes_context(relevant_note_ids);

    if (!calendar.empty()) ss << calendar << "\n";
    if (!reminders.empty()) ss << reminders << "\n";
    if (!chores.empty()) ss << chores << "\n";
    if (!meals.empty()) ss << meals << "\n";
    if (!notes.empty()) ss << notes << "\n";

    return ss.str();
}

std::string PromptAssembler::assemble(
    std::string_view user_message,
    std::string_view username,
    const std::vector<std::string>& relevant_note_ids,
    const std::string& tool_definitions,
    const std::vector<std::string>& image_paths) const {

    std::ostringstream prompt;

    prompt << build_system_prompt(tool_definitions) << "\n\n";

    std::string profile = build_user_profile();
    if (!profile.empty()) {
        prompt << "## User Profile\n" << profile << "\n\n";
    }

    prompt << build_dynamic_context(relevant_note_ids);

    std::string history = history_.load_recent(config_.chat_history_exchanges);
    if (!history.empty()) {
        prompt << "## Recent Chat History\n" << history << "\n\n";
    }

    prompt << "## User Message (" << username << ")\n" << user_message << "\n";

    if (!image_paths.empty()) {
        bool single = image_paths.size() == 1;
        prompt << "\nThe user attached " << (single ? "an image" : "images")
               << ". Use your Read tool on " << (single ? "this path" : "these paths")
               << " to view " << (single ? "it" : "them") << ":\n";
        for (const auto& p : image_paths) {
            prompt << "- " << p << "\n";
        }
    }

    return prompt.str();
}

std::string PromptAssembler::assemble_proactive(
    std::string_view instruction,
    const std::string& tool_definitions) const {

    std::ostringstream prompt;

    prompt << build_system_prompt(tool_definitions) << "\n\n";

    std::string profile = build_user_profile();
    if (!profile.empty()) {
        prompt << "## User Profile\n" << profile << "\n\n";
    }

    prompt << build_dynamic_context({});

    prompt << "## Instruction\n" << instruction << "\n";

    return prompt.str();
}
