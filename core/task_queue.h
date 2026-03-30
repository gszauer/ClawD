#pragma once

#include <string>
#include <vector>
#include <ctime>

enum class TaskType {
    REMINDER,
    DAILY_REPORT,
    CALENDAR_SYNC,
    CALENDAR_HEADS_UP,
    MEAL_PREP_REMINDER,
    OVERDUE_CHORES,
    END_OF_DAY_SUMMARY,
    HEARTBEAT
};

struct ScheduledTask {
    double fire_time;       // Unix timestamp
    TaskType type;
    std::string task_id;    // reference to specific item (e.g. reminder ID)
};

class TaskQueue {
public:
    void insert(ScheduledTask task);
    bool has_pending(double now) const;
    ScheduledTask pop_next();
    void remove_by_id(const std::string& task_id);
    void remove_by_type(TaskType type);
    bool empty() const { return tasks_.empty(); }
    size_t size() const { return tasks_.size(); }

    // Get the next fire time (or 0 if empty)
    double next_fire_time() const;

private:
    std::vector<ScheduledTask> tasks_; // sorted by fire_time ascending
};
