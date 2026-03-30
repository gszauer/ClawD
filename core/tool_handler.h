#pragma once

#include <string>
#include <string_view>
#include <memory>
#include <map>
#include <vector>

// Forward declarations for core context
struct Config;
class DataStore;
class ChatHistory;
class NoteSearch;
class TaskQueue;
class CalendarManager;

struct CoreContext {
    Config* config = nullptr;
    DataStore* meals = nullptr;
    DataStore* chores = nullptr;
    DataStore* reminders = nullptr;
    DataStore* notes = nullptr;
    NoteSearch* note_search = nullptr;
    TaskQueue* task_queue = nullptr;
    CalendarManager* calendar = nullptr;
};

class ToolHandler {
public:
    virtual ~ToolHandler() = default;
    virtual std::string_view name() const = 0;
    virtual std::string description() const = 0;
    virtual std::string execute(const std::vector<std::string>& params) = 0;

    void set_context(CoreContext* ctx) { ctx_ = ctx; }

protected:
    CoreContext* ctx_ = nullptr;
};

class ToolRegistry {
public:
    void register_handler(std::unique_ptr<ToolHandler> handler);
    ToolHandler* find(std::string_view name) const;
    std::string get_definitions() const;
    void set_context(CoreContext* ctx);

private:
    std::map<std::string, std::unique_ptr<ToolHandler>, std::less<>> handlers_;
};
