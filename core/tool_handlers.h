#pragma once

#include "tool_handler.h"

// Registers all built-in tool handlers into the given registry.
void register_all_tools(ToolRegistry& registry);

// --- Reminder Tools ---

class SetReminderHandler : public ToolHandler {
public:
    std::string_view name() const override { return "set_reminder"; }
    std::string description() const override {
        return "set_reminder(message: string, datetime: string, recurrence: string)\n"
               "  Set a reminder. datetime is ISO 8601 format.\n"
               "  recurrence is optional: once (default), daily, weekly, or monthly.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class ListRemindersHandler : public ToolHandler {
public:
    std::string_view name() const override { return "list_reminders"; }
    std::string description() const override {
        return "list_reminders(count: int)\n"
               "  List upcoming reminders.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class DeleteReminderHandler : public ToolHandler {
public:
    std::string_view name() const override { return "delete_reminder"; }
    std::string description() const override {
        return "delete_reminder(id: string)\n"
               "  Delete a reminder by ID.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class EditReminderHandler : public ToolHandler {
public:
    std::string_view name() const override { return "edit_reminder"; }
    std::string description() const override {
        return "edit_reminder(id: string, message: string, datetime: string, recurrence: string)\n"
               "  Edit a reminder. Pass empty string for fields you don't want to change.\n"
               "  recurrence: once, daily, weekly, or monthly.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

// --- Meal Tools ---

class AddMealHandler : public ToolHandler {
public:
    std::string_view name() const override { return "add_meal"; }
    std::string description() const override {
        return "add_meal(name: string, type: string, content: string)\n"
               "  Add a new meal to the rotation. type is home or delivery. content is the recipe or description.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class EditMealHandler : public ToolHandler {
public:
    std::string_view name() const override { return "edit_meal"; }
    std::string description() const override {
        return "edit_meal(id: string, name: string, type: string, content: string)\n"
               "  Edit a meal. Pass empty string for fields you don't want to change.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class DeleteMealHandler : public ToolHandler {
public:
    std::string_view name() const override { return "delete_meal"; }
    std::string description() const override {
        return "delete_meal(id: string)\n"
               "  Delete a meal.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class GetMealsHandler : public ToolHandler {
public:
    std::string_view name() const override { return "get_meals"; }
    std::string description() const override {
        return "get_meals(date: string)\n"
               "  Get today's meal from the rotation and the full meal list.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class GetMealDetailsHandler : public ToolHandler {
public:
    std::string_view name() const override { return "get_meal_details"; }
    std::string description() const override {
        return "get_meal_details(id: string)\n"
               "  Get full recipe/details for a specific meal.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class SwapMealHandler : public ToolHandler {
public:
    std::string_view name() const override { return "swap_meal"; }
    std::string description() const override {
        return "swap_meal(date: string)\n"
               "  Skip today's meal in the rotation and use the next one instead.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

// --- Chore Tools ---

class AddChoreHandler : public ToolHandler {
public:
    std::string_view name() const override { return "add_chore"; }
    std::string description() const override {
        return "add_chore(name: string, color: string, recurrence: string, day: string)\n"
               "  Add a new chore.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class CompleteChoreHandler : public ToolHandler {
public:
    std::string_view name() const override { return "complete_chore"; }
    std::string description() const override {
        return "complete_chore(id: string)\n"
               "  Mark a chore as completed.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class ListChoresHandler : public ToolHandler {
public:
    std::string_view name() const override { return "list_chores"; }
    std::string description() const override {
        return "list_chores(date: string)\n"
               "  List chores due on a date.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class EditChoreHandler : public ToolHandler {
public:
    std::string_view name() const override { return "edit_chore"; }
    std::string description() const override {
        return "edit_chore(id: string, name: string, color: string, recurrence: string, day: string)\n"
               "  Edit a chore. Pass empty string for fields you don't want to change.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class DeleteChoreHandler : public ToolHandler {
public:
    std::string_view name() const override { return "delete_chore"; }
    std::string description() const override {
        return "delete_chore(id: string)\n"
               "  Delete a chore.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

// --- Note Tools ---

class SaveNoteHandler : public ToolHandler {
public:
    std::string_view name() const override { return "save_note"; }
    std::string description() const override {
        return "save_note(title: string, content: string, tags: string)\n"
               "  Save a note. The AI decides title and tags.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class EditNoteHandler : public ToolHandler {
public:
    std::string_view name() const override { return "edit_note"; }
    std::string description() const override {
        return "edit_note(id: string, title: string, content: string, tags: string)\n"
               "  Edit a note. Pass empty string for fields you don't want to change.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class SearchNotesHandler : public ToolHandler {
public:
    std::string_view name() const override { return "search_notes"; }
    std::string description() const override {
        return "search_notes(query: string)\n"
               "  Search notes by semantic similarity.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class ListNotesHandler : public ToolHandler {
public:
    std::string_view name() const override { return "list_notes"; }
    std::string description() const override {
        return "list_notes()\n"
               "  List all saved notes by title.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class DeleteNoteHandler : public ToolHandler {
public:
    std::string_view name() const override { return "delete_note"; }
    std::string description() const override {
        return "delete_note(id: string)\n"
               "  Delete a note.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

// --- Calendar Tools ---

class GetCalendarHandler : public ToolHandler {
public:
    std::string_view name() const override { return "get_calendar"; }
    std::string description() const override {
        return "get_calendar(start_date: string, end_date: string)\n"
               "  Search Google Calendar for events in any date range (past or future).\n"
               "  Dates are YYYY-MM-DD format. Queries Google directly, not limited to cache.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class CreateCalendarEventHandler : public ToolHandler {
public:
    std::string_view name() const override { return "create_calendar_event"; }
    std::string description() const override {
        return "create_calendar_event(title: string, datetime: string, duration_minutes: int, recurrence: string)\n"
               "  Create a Google Calendar event.\n"
               "  recurrence is optional. Use RRULE format: DAILY, WEEKLY, MONTHLY, YEARLY.\n"
               "  Examples: \"WEEKLY\" for every week, \"MONTHLY\" for every month.\n"
               "  Leave empty for a one-time event.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class EditCalendarEventHandler : public ToolHandler {
public:
    std::string_view name() const override { return "edit_calendar_event"; }
    std::string description() const override {
        return "edit_calendar_event(id: string, title: string, datetime: string, duration_minutes: int)\n"
               "  Edit a Google Calendar event. Pass empty string for fields you don't want to change.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};

class DeleteCalendarEventHandler : public ToolHandler {
public:
    std::string_view name() const override { return "delete_calendar_event"; }
    std::string description() const override {
        return "delete_calendar_event(id: string)\n"
               "  Delete a Google Calendar event.";
    }
    std::string execute(const std::vector<std::string>& params) override;
};
