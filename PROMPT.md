# ClawD Personal Assistant Harness — Technical Design

## Overview

A C/C++ personal assistant harness that connects to Discord, assembles contextual prompts, routes them to a **self-hosted Gemma 4** model (llama.cpp + Metal GPU acceleration, with multimodal vision support), parses tool calls from the AI's response, and executes them against local data stores. The application runs as a native macOS app (SwiftUI) wrapping the C++17 core. The assistant's name is ClawD.

Everything runs locally. There is no cloud backend. One loaded Gemma model serves both chat generation and note-search embeddings via two `llama_context`s sharing the same `llama_model`.

## Architecture

The system is split into two layers:

**C++ Core** (`core/`) — owns all logic: prompt assembly, tool parsing, tool execution, data store management, task scheduling, semantic note search, Google Calendar integration, and self-hosted Gemma inference via llama.cpp + mtmd. Exposes a C-compatible interface for the native layer to call into.

**Swift Native Layer** (`clawd/`) — owns the application lifecycle, UI (SwiftUI tabbed window), networking (NSURLSession for HTTP, URLSessionWebSocketTask for Discord), desktop notifications (UNUserNotificationCenter), timers, and Google service account JWT authentication. Calls into the C++ core via a bridging header and provides OS services through PlatformCallbacks function pointers.

Source files are organized into directories:
- `core/` — all C/C++ source files and headers
- `clawd/` — all Swift source files and assets
- `core/hnswlib/` — HNSWLIB header-only dependency
- `tmp/` — build artifacts (.o files)
- `working/` — runtime data (created on first launch)

The Xcode project (`clawd.xcodeproj`) lives at the root. The built `.app` is output to the project root via `CONFIGURATION_BUILD_DIR = $(SRCROOT)`. A `Makefile` builds the standalone Phase 1 CLI binary.

---

## Status

Both Phase 1 (C++ core) and Phase 2 (Swift native layer) are implemented and functional.

### What Works

- Fully self-hosted Gemma 4 (12B or 27B Q4_K_M) via llama.cpp with Metal GPU acceleration
- Multimodal: attach an image to a chat message via the Chat tab's paperclip button; image tokens flow through mtmd + the generation context
- Note-search embeddings from the same Gemma model (second llama_context with mean pooling)
- Full AI chat via local UI and Discord
- All tool handlers with complete CRUD (create, read, update, delete)
- Semantic note search via HNSWLIB, dimension-aware with automatic index invalidation on model swap
- Google Calendar integration (service account auth, sync, live queries)
- Local-only calendar fallback when Google isn't connected
- Discord WebSocket gateway with reconnect, reactions, and message routing
- Proactive messages (daily report, meal prep, overdue chores, end-of-day summary)
- Recurring reminders (daily, weekly, monthly) and one-shot cleanup
- Desktop notifications via UNUserNotificationCenter
- Externalized prompt templates (editable system prompt and user profile)
- Non-blocking toast notifications in the UI for errors and status
- Inline markdown editor for all data types with frontmatter validation
- Chat history persistence with daily markdown logs
- User-configurable context length in the Advanced section (default: model's trained max, typically 128k for Gemma 4)

---

## Dependencies

**cJSON** — single `cJSON.c` + `cJSON.h`. Used for all JSON parsing: config files, API responses, tool call extraction, Google Calendar API responses, calendar cache. Included in `core/`.

**HNSWLIB** — header-only C++ library (`core/hnswlib/`). Used for approximate nearest neighbor search on note embeddings. Compiled with `-DNO_MANUAL_VECTORIZATION` for ARM macOS compatibility. The index persists as `working/notes.index`.

No external package managers (no CocoaPods, no SPM). Everything is in the repo.

**llama.cpp** — pre-built static libraries in `deps/lib/` with headers in `deps/include/`. Built with `GGML_METAL=ON` (Metal GPU backend), `GGML_METAL_EMBED_LIBRARY=ON` (shaders baked into the static lib), and `LLAMA_BUILD_TOOLS=ON` (mtmd multimodal library). Linked as `libmtmd.a` + `libllama.a` + `libggml*.a` + `libggml-metal.a`. The rebuild is reproducible via `deps/build_llama.sh`, which pins a specific llama.cpp commit, clones, builds, and copies the resulting `.a` files and headers into `deps/lib/` and `deps/include/`.

**libmtmd** (part of the llama.cpp build) — llama.cpp's multimodal tokens library. Handles vision projectors (CLIP-style), image preprocessing, and the `mtmd_tokenize` → `mtmd_helper_eval_chunks` pipeline used in `local_gemma.cpp` for image input.

**whisper.cpp** — pre-built static library in `deps/lib/libwhisper.a` with `deps/include/whisper.h`. Used for local audio transcription via `whisper_transcribe.h/cpp`. Converts OGG to WAV (via macOS `afconvert`), resamples to 16kHz, runs whisper inference.

### Gemma Integration (`local_gemma.h/cpp`)

One module owns the entire llama.cpp world:

- **One `llama_model*`** loaded from the Gemma LM GGUF (`llama_model_load_from_file` with `n_gpu_layers = 999` to offload everything to Metal).
- **One `mtmd_context*`** loaded from the vision projector GGUF (optional). If it fails to load, text-only mode is retained and `local_gemma_has_vision()` returns false.
- **Two `llama_context*`** sharing the model weights:
  - `g_ctx_gen` — generation context. `n_ctx` is user-configurable (0 = use `llama_model_n_ctx_train`), `type_k = type_v = GGML_TYPE_Q8_0` (quantized KV cache, halves memory to make 128k fit on 24 GB Apple Silicon), `flash_attn_type = AUTO`, `offload_kqv = true`.
  - `g_ctx_embed` — embedding context. `n_ctx = 512`, `embeddings = true`, `pooling_type = LLAMA_POOLING_TYPE_MEAN`, FP16 KV cache (tiny, doesn't matter).
- **Sampling chain** (hardcoded): top-k 40 → top-p 0.95 → temperature 0.7 → dist.
- **Chat template**: the assembled prompt is wrapped in Gemma turn tokens (`<start_of_turn>user\n...<end_of_turn>\n<start_of_turn>model\n`). The PromptAssembler already encodes turn structure via markdown headers inside the user turn.
- **Text path**: `llama_batch_get_one` → `llama_decode` prefill → sampler loop (EOS / `<end_of_turn>` / `max_tokens` stop).
- **Image path**: `mtmd_helper_bitmap_init_from_file` → build prompt with `mtmd_default_marker()` placeholder → `mtmd_tokenize` → `mtmd_helper_eval_chunks` → sample as normal.
- **Embedding path**: tokenize (truncated to 512) → `llama_encode` on `g_ctx_embed` → `llama_get_embeddings_seq` → L2 normalize.
- **Graceful degradation**: generation-context creation retries at half n_ctx on OOM. mmproj init failures clear `has_vision_` and keep text-only running.

Semantic search falls back to title matching only if Gemma is not loaded at all.

### Audio Transcription

When the audio backend is set to **whisper**, Discord voice messages are transcribed locally using whisper.cpp (`whisper_transcribe.h/cpp`). The pipeline: download OGG from Discord -> convert to WAV via `afconvert` -> resample to 16kHz -> run whisper inference -> feed transcript to the AI as `[Voice message transcript]: <text>`. Models (base.en or small.en) are downloadable from the UI.

---

## Directory Structure

```
Assistant/
  Makefile                    # Builds Phase 1 CLI binary
  TODO.md                     # This file
  README.md                   # User-facing documentation
  .gitignore
  clawd.xcodeproj/            # Xcode project
  clawd.app/                  # Built macOS app (gitignored)
  assistant                   # Built CLI binary (gitignored)

  core/                       # C++ core source
    config.h / config.cpp
    core.h / core.cpp
    main.cpp                  # Phase 1 CLI entry point (excluded from Xcode)
    frontmatter.h / frontmatter.cpp
    data_store.h / data_store.cpp
    chat_history.h / chat_history.cpp
    tool_parser.h / tool_parser.cpp
    tool_handler.h / tool_handler.cpp
    tool_handlers.h / tool_handlers.cpp
    prompt_assembler.h / prompt_assembler.cpp
    backend.h / backend.cpp          # Thin wrapper calling local_gemma_generate
    task_queue.h / task_queue.cpp
    note_search.h / note_search.cpp
    local_gemma.h / local_gemma.cpp  # Gemma model + mtmd + generation + embeddings
    whisper_transcribe.h / whisper_transcribe.cpp
    calendar.h / calendar.cpp
    http_client.h / http_client.cpp
    cJSON.h / cJSON.c
    hnswlib/                  # Header-only library (7 headers)

  deps/                       # Pre-built static libraries + rebuild script
    build_llama.sh            # Reproducible llama.cpp rebuild (Metal + mtmd)
    include/                  # llama.h, mtmd.h, whisper.h, ggml*.h, gguf.h
    lib/                      # libmtmd.a, libllama.a, libwhisper.a, libggml*.a, libggml-metal.a

  clawd/                      # Swift native layer
    clawdApp.swift            # @main entry point
    ContentView.swift         # NavigationSplitView sidebar (7 sections) + toast overlay
    AppState.swift            # @Observable singleton, config I/O, data refresh
    CoreBridge.swift          # C++ core wrapper, platform callbacks
    DiscordService.swift      # WebSocket gateway + REST API
    CalendarAuth.swift        # Google service account JWT auth
    NotificationService.swift # Desktop notifications
    TimerService.swift        # Timer callbacks
    EditHelpers.swift         # Frontmatter validation on edit
    GeneralTab.swift          # Config UI
    ChatTab.swift             # Chat log + message input + paperclip image attach
    NotesTab.swift            # Notes list + editor
    MealsTab.swift            # Meals list + editor
    ChoresTab.swift           # Chores list + editor
    RemindersTab.swift        # Reminders list + editor
    CalendarTab.swift         # Calendar day view + sync
    clawd-Bridging-Header.h
    Assets.xcassets/

  tmp/                        # Build artifacts (gitignored)
  working/                    # Runtime data (gitignored)
```

### Working Directory Layout (created on first launch)

```
working/
  config.json                 # Application configuration
  gemma-4-*-it-Q4_K_M.gguf    # Gemma 4 LM weights (12B or 27B, downloaded from UI)
  mmproj-gemma-4-*.gguf       # Gemma 4 vision projector (downloaded alongside LM)
  whisper-ggml-*.en.bin       # Optional whisper model for audio transcription
  calendar.json               # Google service account credentials (user-provided)
  calendar_cache.json         # Cached calendar events
  notes.index                 # HNSWLIB binary search index
  index_map.json              # HNSWLIB label-to-filename mapping
  .embed_dim                  # Sidecar recording the current embedding dimension (for migration)
  tmp/                        # Temporary files (audio downloads, cleared on launch)

  chat/
    2026-03-29.md             # Daily chat logs
  notes/
    wifi_password_a3f1b2.md   # Notes (slug + random hex)
  meals/
    chicken_stir_fry_b2d4f6.md
  chores/
    clean_bathroom_c4e8d1.md
  reminders/
    call_dentist_e8a1c3.md
  prompts/
    system_prompt.md          # Editable system prompt template
    profile.md                # Editable user profile
    notes.txt                 # Template substitution reference
```

---

## Configuration

A single `config.json` in the working directory. The native UI reads and writes this file. Auto-loaded on app launch if present.

```json
{
  "gemma_model_path": "/Users/user/Desktop/ClawD/working/gemma-4-12b-it-Q4_K_M.gguf",
  "gemma_mmproj_path": "/Users/user/Desktop/ClawD/working/mmproj-gemma-4-12b-it-F16.gguf",
  "gemma_n_ctx": 0,
  "audio_backend": "off",
  "whisper_model_path": "",
  "assistant_name": "ClawD",
  "assistant_emoji": "\ud83e\udd80",
  "discord_bot_token": "...",
  "discord_channel_id": "...",
  "calendar_id": "your.email@gmail.com",
  "calendar_sync_interval_minutes": 20,
  "chat_history_exchanges": 25,
  "heartbeat_interval_seconds": 30,
  "note_search_results": 5,
  "max_notes_in_index": 10000,
  "working_directory": "/Users/user/Desktop/ClawD/working",
  "notifications": {
    "daily_report": { "enabled": true, "time": "07:00" },
    "calendar_heads_up": { "enabled": true, "minutes_before": 30 },
    "meal_prep_reminder": { "enabled": true, "time": "15:00" },
    "overdue_chores": { "enabled": true, "time": "10:00" },
    "end_of_day_summary": { "enabled": true, "time": "21:00" }
  }
}
```

Gemma fields:
- `gemma_model_path` — absolute path to the Gemma 4 LM GGUF file. Required for chat to work.
- `gemma_mmproj_path` — absolute path to the vision projector GGUF. Optional: if empty, vision is disabled but chat and embeddings still work.
- `gemma_n_ctx` — context length for generation. `0` means "use model's trained max" (128k for Gemma 4). Non-zero values clamp to `[512, llama_model_n_ctx_train]`.

Audio options: `"whisper"` (local whisper.cpp transcription), `"off"` (default).

---

## Data Formats

### Markdown with Frontmatter

All user data files use YAML-style frontmatter followed by markdown content. Filenames are slugified titles with a random 6-digit hex suffix (e.g. `call_dentist_a3f1b2.md`) to prevent collisions.

**Meal:**
```markdown
---
type: home
days: [3, 14, 27]
slot: 1
---

# Chicken Stir Fry

Rice, chicken breast, soy sauce, mixed vegetables.
```

Meal types: `home`, `delivery`.

**Chore:**
```markdown
---
color: green
recurrence: weekly
day: tuesday
completed_last: 2026-03-25
---

# Clean the Bathroom

Scrub the tub, clean the mirror, mop the floor.
```

Colors: `green` (default), `blue`, `pink`. Recurrence: `weekly`, `biweekly`, `monthly`, `one-shot`. One-shot chores are deleted when completed.

**Reminder:**
```markdown
---
datetime: 2026-03-29T09:00:00
status: pending
recurrence: once
---

# Call the Dentist

Schedule a cleaning appointment. Their number is 555-0123.
```

Recurrence: `once` (default, deleted after firing), `daily`, `weekly`, `monthly`. Recurring reminders auto-advance `datetime` and re-insert into the task queue.

**Note:**
```markdown
---
created: 2026-03-28T14:32:00
tags: home, tech
---

# WiFi Password

Network: MyNetwork5G
Password: hunter2
```

### Chat History

One markdown file per day in `chat/`. Appended live as messages flow.

```markdown
## User 14:32
Remind me to call the dentist tomorrow at 9am

## Assistant 14:32
Done, I've set a reminder for tomorrow at 9:00 AM.

## Tool 14:32
set_reminder("Call the Dentist", "2026-03-29T09:00:00")
```

---

## C++ Core Interface

### Platform Callbacks (native layer provides to core)

```c
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
```

### Core API

```c
void core_initialize(const char* config_path, PlatformCallbacks callbacks,
                     const char* working_dir_override);
void core_shutdown(void);

// Chat entry points
void core_on_message_received(const char* user, const char* text,
                              const char* channel_id, const char* message_id);
void core_send_message_with_image(const char* user, const char* text,
                                  const char* image_path);  // Local chat tab only
int  core_has_vision(void);                                 // Non-zero if mmproj is loaded

void core_on_timer_fired(int timer_id);
void core_on_config_changed(void);
void core_check_tasks(void);
void core_reload_data(void);
void core_set_calendar_token(const char* token);
int  core_calendar_sync(void);
void core_reindex_note(const char* note_id);
const char* core_transcribe_audio(const char* file_path);
void core_append_assistant(const char* text);
void core_set_response_callback(ResponseCallback callback);
const char* core_execute_tool(const char* tool_name, const char* params_json);
void core_free_string(const char* str);

// UI queries
const char* core_get_meals(void);
const char* core_get_chores(void);
const char* core_get_reminders(void);
const char* core_get_notes(void);
const char* core_get_chat_history(const char* date);
```

`core_on_message_received` and `core_send_message_with_image` both delegate to a shared internal `handle_message_impl`, which embeds the user text, assembles the prompt, calls `Backend::execute` (which forwards to `local_gemma_generate` with an optional image path), parses tool calls, and threads tool results through a follow-up prompt. The Discord code path passes `image_path = ""`; only the Chat tab's paperclip button passes a non-empty image path.

---

## Tool System

### Tool Call Format

The AI responds with tool calls inline in its text:

```
Sure, I'll set that reminder for you.
<<TOOL:set_reminder("Call the Dentist", "2026-03-29T09:00:00")>>
```

The core scans for `<<TOOL:...>>` markers, dispatches to handlers, feeds results back to the AI for a follow-up response, and adds emoji reactions to Discord messages indicating what tool was used.

### Tool Emoji Reactions

When a tool executes, the corresponding emoji is added to the user's Discord message:
- Reminders: bell
- Chores: 100
- Notes: memo
- Meals: meat on bone
- Calendar: calendar

The assistant emoji (crab by default) is added when processing starts and removed when the response is sent.

### Available Tools (24 total)

**Reminders:** `set_reminder`, `list_reminders`, `edit_reminder`, `delete_reminder`
**Meals:** `add_meal`, `get_meals`, `get_meal_details`, `edit_meal`, `delete_meal`, `swap_meal`
**Chores:** `add_chore`, `edit_chore`, `complete_chore`, `list_chores`, `get_chore_details`, `delete_chore`
**Notes:** `save_note`, `edit_note`, `search_notes`, `list_notes`, `delete_note`
**Calendar:** `get_calendar`, `create_calendar_event`, `edit_calendar_event`, `delete_calendar_event`

`get_calendar` queries Google Calendar live for any date range (past or future). `create_calendar_event` supports recurrence (`DAILY`, `WEEKLY`, `MONTHLY`, `YEARLY`). When Google isn't connected, all calendar tools fall back to local-only storage with events flagged as `local_only`.

The UI also calls tools directly via `core_execute_tool()` for add/edit/delete operations, bypassing the AI entirely.

---

## Prompt Assembly

Every prompt sent to the AI is assembled from these components in order:

1. **System Prompt** — loaded from `working/prompts/system_prompt.md` with `{{variable}}` substitution
2. **User Profile** — loaded from `working/prompts/profile.md`
3. **Dynamic Context:**
   - Upcoming calendar events (from cache)
   - Pending + recently fired reminders
   - All chores with recurrence/completion status
   - Today's meals + all meals
   - Top N semantically relevant notes (from embedding search)
4. **Chat History** — last N exchanges from today/yesterday
5. **User Message** — with username: `## User Message (gszauer)` or `## User Message (Local)`

Supported template variables: `{{assistant_name}}`, `{{datetime}}`, `{{date}}`, `{{day_of_week}}`, `{{tools}}`

---

## Scheduled Task Queue

A priority queue sorted by fire time. Checked every heartbeat (configurable, default 30s).

### Task Types

| Task | Trigger | Behavior |
|------|---------|----------|
| Reminder | Scheduled datetime | Fires notification + Discord message. One-shot: deleted. Recurring: advances datetime and re-queues. |
| Daily Report | Configured time | AI generates morning briefing. Sent to Discord + chat log + desktop notification. |
| Meal Prep | Configured time | AI generates dinner prep reminder. |
| Overdue Chores | Configured time | AI lists overdue chores. |
| End of Day | Configured time | AI generates daily summary. |
| Calendar Sync | Every N minutes | Syncs Google Calendar. Incremental sync via sync tokens. |

All proactive messages are logged to chat history and sent to Discord (if connected). Desktop notifications fire regardless of Discord. Backend errors (`[Error:...]`) are sent to Discord but not recorded in chat history.

---

## Google Calendar Integration

### Authentication

Uses a Google Cloud **service account** JSON key file. The app handles JWT creation (RS256 signing via macOS Security framework) and token exchange automatically.

Setup:
1. Create a service account in Google Cloud Console
2. Enable Google Calendar API
3. Download the JSON key file
4. In the app, browse to select the JSON (copied to `working/calendar.json`)
5. Share your Google Calendar with the service account email
6. Enter your calendar ID (email or calendar-specific ID) in the General tab

### Sync

Periodic sync fetches events from 14 days ago to 14 days ahead. Uses Google's sync tokens for incremental updates. "Sync Now" button forces a full re-fetch. The cache persists to `working/calendar_cache.json`.

### Local Fallback

When Google credentials aren't configured, calendar tools create/edit/delete events locally in the cache. Events are flagged `local_only` and displayed with an orange badge in the Calendar tab.

---

## Discord Integration

### Connection

The Swift native layer manages the Discord WebSocket:
- GET `/api/v10/gateway` for gateway URL
- WebSocket with heartbeat loop
- MESSAGE_CREATE events dispatched to core
- Exponential backoff reconnect (2s, 4s, 8s, 16s, 32s, max 5 attempts)
- Fatal close codes (4014 disallowed intents, 4004 bad token) stop retries with a toast

### Message Flow

**Text messages:**
1. Message received from Discord
2. Crab emoji reaction added (acknowledgment)
3. User message embedded for note search
4. Full prompt assembled and sent to AI backend
5. AI response parsed for tool calls
6. Tools executed, results fed back to AI
7. Final response sent to Discord + logged to chat history
8. Tool-specific emoji added, crab removed

**Voice messages (when whisper is enabled):**
1. Audio attachment detected, downloaded to `working/tmp/`
2. Ear emoji added to the message
3. OGG converted to WAV, resampled to 16kHz, transcribed via whisper.cpp
4. Transcript passed to AI as `[Voice message transcript]: <text>`
5. AI responds (same flow as text from step 4 above)
6. Transcript posted to Discord after the AI response
7. Audio file deleted from tmp

### Bot Personality

The bot's name (`assistant_name`) and reaction emoji (`assistant_emoji`, default crab) are configurable. The name is injected into the system prompt. The emoji is used as the thinking/processing indicator on Discord messages.

Intents: `GUILDS | GUILD_MESSAGES | DIRECT_MESSAGES | MESSAGE_CONTENT` (37377). MESSAGE_CONTENT is a privileged intent that must be enabled in the Discord Developer Portal.

---

## Native UI (SwiftUI)

The UI uses a `NavigationSplitView` with a left sidebar listing the seven sections. `Tab` is an internal enum; the detail view switch lives in `ContentView.swift`.

### Tabs

| Tab | Purpose |
|-----|---------|
| General | Working directory, Gemma download (12B / 27B), mmproj path, audio transcription, Discord/Calendar setup, notification toggles, advanced tuning (Context Length, Chat History, Heartbeat, Note Results, Max Notes), start/stop |
| Chat | Chat log with bubbles (user right-aligned, assistant left), paperclip button to attach an image (greyed out when mmproj isn't loaded), image preview strip, send as User or Assistant, live updates |
| Notes | List + detail with inline markdown editor, add/delete |
| Meals | List + detail with editor, type (home/delivery) |
| Chores | List with color dots, recurrence, mark complete, add/edit/delete |
| Reminders | Pending/past sections, datetime picker, recurrence |
| Calendar | 14-day view with day sections, sync button, local-only badges |

### Editing

All data tabs support inline markdown editing:
- Click **Edit** to switch to a monospaced text editor
- **Cancel** / **Save** buttons replace Edit
- While editing: tab switching, item selection, add/delete are blocked with a "Finish editing first" toast
- On save: frontmatter is validated (required fields added if missing), data stores are reloaded, note embeddings are re-indexed

### Non-blocking Toasts

Errors and status messages appear as a toast bar at the bottom of the window. Red for errors (8s), neutral for info (4s). Click to dismiss. Used for: Discord connection status, embedding health, calendar sync, backend errors.

---

## Code Style

- Modern C++17: `std::unique_ptr`, `std::string_view`, move semantics, RAII
- No raw `new`/`delete`
- `const` by default
- C boundary uses `const char*`, wrapped to `std::string`/`std::string_view` on the C++ side
- SwiftUI with `@Observable` / `@Bindable` for reactive state
- All data flows through `AppState.shared.refreshData()` for consistent UI updates
