#include "task_queue.h"
#include <algorithm>

void TaskQueue::insert(ScheduledTask task) {
    // Insert-sort: find the right position to maintain ascending fire_time order
    auto it = tasks_.begin();
    while (it != tasks_.end() && it->fire_time <= task.fire_time) {
        ++it;
    }
    tasks_.insert(it, std::move(task));
}

bool TaskQueue::has_pending(double now) const {
    return !tasks_.empty() && tasks_.front().fire_time <= now;
}

ScheduledTask TaskQueue::pop_next() {
    ScheduledTask task = std::move(tasks_.front());
    tasks_.erase(tasks_.begin());
    return task;
}

void TaskQueue::remove_by_id(const std::string& task_id) {
    tasks_.erase(
        std::remove_if(tasks_.begin(), tasks_.end(),
                       [&](const ScheduledTask& t) { return t.task_id == task_id; }),
        tasks_.end());
}

void TaskQueue::remove_by_type(TaskType type) {
    tasks_.erase(
        std::remove_if(tasks_.begin(), tasks_.end(),
                       [type](const ScheduledTask& t) { return t.type == type; }),
        tasks_.end());
}

double TaskQueue::next_fire_time() const {
    if (tasks_.empty()) return 0;
    return tasks_.front().fire_time;
}
