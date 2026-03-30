#include "backend.h"
#include "config.h"
#include "http_client.h"
#include "cJSON.h"

#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <array>

// Escape a string for safe shell embedding in single quotes
static std::string shell_escape(std::string_view s) {
    std::string result = "'";
    for (char c : s) {
        if (c == '\'') {
            result += "'\\''";
        } else {
            result += c;
        }
    }
    result += "'";
    return result;
}

static std::string run_popen(const std::string& cmd) {
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) return "[Error: failed to execute backend CLI]";

    std::string result;
    std::array<char, 4096> buf;
    while (fgets(buf.data(), static_cast<int>(buf.size()), pipe) != nullptr) {
        result += buf.data();
    }

    int status = pclose(pipe);
    if (status != 0 && result.empty()) {
        return "[Error: backend CLI exited with status " + std::to_string(status) + "]";
    }

    while (!result.empty() && (result.back() == '\n' || result.back() == '\r' ||
                                result.back() == ' '))
        result.pop_back();

    return result;
}

std::string Backend::execute_cli(std::string_view cli_path, std::string_view prompt) {
    if (cli_path.empty()) return "[Error: no backend CLI path configured]";
    std::string cmd = std::string(cli_path) + " -p " + shell_escape(prompt) + " 2>/dev/null";
    return run_popen(cmd);
}

std::string Backend::execute_api(std::string_view api_url,
                                 std::string_view api_key,
                                 std::string_view model,
                                 std::string_view prompt) {
    if (api_url.empty()) return "[Error: no backend API URL configured]";
    // Build OpenAI-compatible chat completion request
    cJSON* root = cJSON_CreateObject();
    if (!model.empty()) {
        cJSON_AddStringToObject(root, "model", std::string(model).c_str());
    }

    cJSON* messages = cJSON_CreateArray();

    // System message
    cJSON* sys_msg = cJSON_CreateObject();
    cJSON_AddStringToObject(sys_msg, "role", "system");
    cJSON_AddStringToObject(sys_msg, "content", "You are a helpful personal assistant.");
    cJSON_AddItemToArray(messages, sys_msg);

    // User message (contains the full assembled prompt)
    cJSON* user_msg = cJSON_CreateObject();
    cJSON_AddStringToObject(user_msg, "role", "user");
    cJSON_AddStringToObject(user_msg, "content", std::string(prompt).c_str());
    cJSON_AddItemToArray(messages, user_msg);

    cJSON_AddItemToObject(root, "messages", messages);

    char* json = cJSON_PrintUnformatted(root);
    std::string body = json;
    free(json);
    cJSON_Delete(root);

    std::string auth;
    if (!api_key.empty()) {
        auth = "Bearer " + std::string(api_key);
    }
    HttpResponse resp = http_post(api_url, body, "application/json", auth);
    if (!resp.ok()) {
        return "[Error: API request failed with status " + std::to_string(resp.status) +
               ": " + resp.body + "]";
    }

    // Parse response
    cJSON* resp_json = cJSON_Parse(resp.body.c_str());
    if (!resp_json) {
        return "[Error: failed to parse API response]";
    }

    std::string result;

    // OpenAI format: choices[0].message.content
    const cJSON* choices = cJSON_GetObjectItemCaseSensitive(resp_json, "choices");
    if (cJSON_IsArray(choices) && cJSON_GetArraySize(choices) > 0) {
        const cJSON* first = cJSON_GetArrayItem(choices, 0);
        const cJSON* message = cJSON_GetObjectItemCaseSensitive(first, "message");
        if (message) {
            const cJSON* content = cJSON_GetObjectItemCaseSensitive(message, "content");
            if (cJSON_IsString(content) && content->valuestring) {
                result = content->valuestring;
            }
        }
    }

    cJSON_Delete(resp_json);

    if (result.empty()) {
        return "[Error: no content in API response]";
    }

    return result;
}

std::string Backend::execute(const Config& config, std::string_view prompt) {
    if (config.backend == "local") {
        return execute_api(config.backend_api_url, config.backend_api_key,
                           config.backend_api_model, prompt);
    } else if (config.backend == "claude") {
        if (config.backend_cli_path.empty()) return "[Error: no backend CLI path configured]";
        std::string cmd = std::string(config.backend_cli_path)
            + " --allowedTools WebSearch -p "
            + shell_escape(prompt) + " 2>/dev/null";
        return run_popen(cmd);
    } else {
        return execute_cli(config.backend_cli_path, prompt);
    }
}
