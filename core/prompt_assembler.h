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

    // Assemble full prompt for a user message, with relevant notes injected
    std::string assemble(std::string_view user_message,
                         std::string_view username,
                         const std::vector<std::string>& relevant_note_ids,
                         const std::string& tool_definitions) const;

    // Assemble a proactive prompt (no user message, but with an instruction)
    std::string assemble_proactive(std::string_view instruction,
                                   const std::string& tool_definitions) const;

    // Load a proactive instruction template from working/prompts/<name>.md.
    // Applies {{weather_hint}} and other standard substitutions. Falls back to
    // the built-in default if the file is missing. Safe to call on every task
    // fire — the file is re-read each time so edits take effect immediately.
    std::string load_proactive_instruction(const std::string& name) const;

    // Write default prompt templates to working/prompts/ if they don't exist.
    // Static so it can be called without a fully-initialized core (e.g. from
    // the Prompts tab before the user has clicked Start).
    static void write_defaults(const std::string& working_directory);

private:
    const Config& config_;
    DataStore& meals_;
    DataStore& chores_;
    DataStore& reminders_;
    DataStore& notes_;
    ChatHistory& history_;
    CalendarManager* calendar_;

    std::string build_system_prompt(const std::string& tool_definitions) const;
    std::string build_dynamic_context(
        const std::vector<std::string>& relevant_note_ids) const;
    std::string build_reminders_context() const;
    std::string build_chores_context() const;
    std::string build_meals_context() const;
    std::string build_notes_context(
        const std::vector<std::string>& relevant_note_ids) const;
    std::string build_calendar_context() const;
};
