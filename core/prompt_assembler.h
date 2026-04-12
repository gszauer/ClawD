#pragma once

#include <string>
#include <string_view>
#include <vector>

struct Config;
class DataStore;
class ChatHistory;
class CalendarManager;

class PromptAssembler {
public:
    PromptAssembler(const Config& config, DataStore& meals, DataStore& chores,
                    DataStore& reminders, DataStore& notes, ChatHistory& history,
                    CalendarManager* calendar = nullptr);

    // Assemble full prompt for a user message, with relevant notes injected.
    // If image_paths is non-empty, an explicit "use the Read tool on these
    // paths" instruction is appended to the user-message section.
    std::string assemble(std::string_view user_message,
                         std::string_view username,
                         const std::vector<std::string>& relevant_note_ids,
                         const std::string& tool_definitions,
                         const std::vector<std::string>& image_paths = {}) const;

    // Assemble a proactive prompt (no user message, but with an instruction)
    std::string assemble_proactive(std::string_view instruction,
                                   const std::string& tool_definitions) const;

    // Write default prompt templates to working/prompts/ if they don't exist
    void write_defaults() const;

    // Load a proactive instruction file (e.g. "daily_report", "end_of_day",
    // "meal_prep", "overdue_chores") from working/prompts/<name>.md. The
    // template's {{weather_hint}} token is replaced based on `zip_code` and
    // `day` ("today"/"tomorrow"/""). Returns the default instruction text if
    // the file is missing.
    std::string load_instruction(const std::string& name,
                                  const std::string& zip_code,
                                  const std::string& day) const;

private:
    const Config& config_;
    DataStore& meals_;
    DataStore& chores_;
    DataStore& reminders_;
    DataStore& notes_;
    ChatHistory& history_;
    CalendarManager* calendar_;

    std::string build_system_prompt(const std::string& tool_definitions) const;
    std::string build_user_profile() const;
    std::string build_dynamic_context(
        const std::vector<std::string>& relevant_note_ids) const;
    std::string build_reminders_context() const;
    std::string build_chores_context() const;
    std::string build_meals_context() const;
    std::string build_notes_context(
        const std::vector<std::string>& relevant_note_ids) const;
    std::string build_calendar_context() const;
};
