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

    // Write default prompt templates to working/prompts/ if they don't exist
    void write_defaults() const;

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
