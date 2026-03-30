#include "tool_handler.h"

void ToolRegistry::register_handler(std::unique_ptr<ToolHandler> handler) {
    std::string key(handler->name());
    handler->set_context(nullptr); // context set later via set_context()
    handlers_[key] = std::move(handler);
}

ToolHandler* ToolRegistry::find(std::string_view name) const {
    auto it = handlers_.find(name);
    if (it != handlers_.end()) return it->second.get();
    return nullptr;
}

std::string ToolRegistry::get_definitions() const {
    std::string result;
    for (const auto& [name, handler] : handlers_) {
        result += "- ";
        result += handler->description();
        result += "\n\n";
    }
    return result;
}

void ToolRegistry::set_context(CoreContext* ctx) {
    for (auto& [name, handler] : handlers_) {
        handler->set_context(ctx);
    }
}
