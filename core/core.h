#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Callbacks from native layer to core (Phase 2)
struct PlatformCallbacks {
    void (*http_request)(const char* method, const char* url,
                         const char* headers, const char* body,
                         void (*on_complete)(const char* response, int status, void* ctx),
                         void* ctx);
    void (*websocket_send)(const char* message);
    void (*send_notification)(const char* title, const char* body);
    void (*schedule_timer)(double seconds, int timer_id);
    void (*cancel_timer)(int timer_id);
    void (*add_reaction)(const char* channel_id, const char* message_id, const char* emoji);
    void (*remove_reaction)(const char* channel_id, const char* message_id, const char* emoji);
};

// working_dir_override: if non-NULL, overrides the working_directory from config
void core_initialize(const char* config_path, struct PlatformCallbacks callbacks,
                     const char* working_dir_override);
void core_shutdown(void);

// Discord events
void core_on_message_received(const char* user, const char* text,
                              const char* channel_id, const char* message_id);
void core_on_connected(void);
void core_on_disconnected(void);

// Timer events
void core_on_timer_fired(int timer_id);

// Config changes
void core_on_config_changed(void);

// UI queries
const char* core_get_meals(void);
const char* core_get_chores(void);
const char* core_get_reminders(void);
const char* core_get_notes(void);
const char* core_get_chat_history(const char* date);

// Append an assistant message to chat history (no AI call)
void core_append_assistant(const char* text);

// Set the calendar access token from the native layer (for service account auth).
void core_set_calendar_token(const char* token);

// Trigger a calendar sync now. Returns 1 on success, 0 on failure.
int core_calendar_sync(void);

// Reload all data stores from disk (after external edits).
void core_reload_data(void);

// Re-index a note's embedding after it was edited on disk.
void core_reindex_note(const char* note_id);

// Transcribe an audio file using the configured audio backend (e.g. gemini CLI).
// Returns the transcript string. Caller must free with core_free_string().
const char* core_transcribe_audio(const char* file_path);

// Execute a tool directly (bypasses the AI). Returns the tool result string.
// Caller must free the returned string with core_free_string().
const char* core_execute_tool(const char* tool_name, const char* params_json);
void core_free_string(const char* str);

// Callback: called when a response is ready to send to Discord
// Set by the native layer. The core calls this after generating a response.
typedef void (*ResponseCallback)(const char* channel_id, const char* response);
void core_set_response_callback(ResponseCallback callback);

// Phase 1: manual heartbeat check from main loop
void core_check_tasks(void);

#ifdef __cplusplus
}
#endif
