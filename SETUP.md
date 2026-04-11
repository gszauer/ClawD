# ClawD Setup Guide

This guide walks through configuring ClawD from scratch. After building and launching the app, everything is configured in the **General** tab.

---

## 1. First Launch

When you open ClawD for the first time:

1. The **Working Directory** field is pre-populated with the path next to the `.app` bundle, and `config.json` is auto-loaded from it if present
2. All other fields have sensible defaults
3. Nothing is running yet — click **Start** when you're ready

The app creates the `working/` directory and all subdirectories automatically on first start.

---

## 2. Gemma (Required)

ClawD runs a self-hosted **Gemma 4** model for both chat generation and note-search embeddings. There is no cloud backend — everything happens locally on your Mac via llama.cpp with Metal GPU acceleration.

The prebuilt llama.cpp static libraries in `deps/lib/` are already Metal-enabled and include the multimodal (`libmtmd.a`) support needed for Gemma's vision capabilities. If you ever need to rebuild them (e.g. to pick up a new llama.cpp release), run `./deps/build_llama.sh` — the script clones llama.cpp at a pinned commit, builds with `GGML_METAL=ON` + `LLAMA_BUILD_TOOLS=ON`, and drops the resulting `.a` files into `deps/lib/` plus headers into `deps/include/`.

### Download the model

In the **Gemma** card on the General tab:

- **4B (~2.5 GB)** — Gemma 4 4B Q4_K_M + vision projector. Fits easily on 8 GB machines (e.g. MacBook Air). Fast, but less capable at complex reasoning and tool-calling.
- **12B (~7 GB)** — Gemma 4 12B Q4_K_M + vision projector. Comfortable on 24 GB Apple Silicon at the full 128k context window. **Recommended** for a Mac mini 24 GB.
- **27B (~17 GB)** — Gemma 4 27B Q4_K_M + vision projector. Highest quality but leaves zero headroom at 128k context. If you pick 27B, also drop **Context Length** in the Advanced section to something lower like `32768` or you risk OOM when other apps run.

Each button downloads two files sequentially into the working directory:
1. The language model GGUF (the big file)
2. The vision projector (`mmproj-*.gguf`, ~1 GB) — enables image input in the Chat tab

Both paths are populated in the Gemma card once the download finishes. You can also **Browse...** to point at your own GGUF files.

### Context length

By default `Context Length` is `0` which means "use the model's maximum trained context" — 128k for Gemma 4. The app uses Q8_0 KV cache quantization to make this fit in RAM: ~11 GB for 12B, ~23 GB for 27B. Lower it in the Advanced section if you need to free RAM for other apps.

Changing the context length requires a restart (click **Stop** then **Start**).

### Vision / image input

When the vision projector is loaded, the **Chat** tab shows a paperclip button next to the text field. Click it to attach a JPEG/PNG file to your next message. The image is processed alongside the text using mtmd (multimodal tokens), and Gemma can describe or reason about it.

The paperclip is greyed out if the vision projector isn't loaded. Discord image attachments are not yet supported — only the local Chat tab can send images.

### Note-search embeddings

Semantic note search uses the same Gemma model via a second llama.cpp context (mean-pooled, text-only). There's no separate embedding model to download. Embedding quality is good enough for personal note volumes, though purpose-built embedders would be more accurate for very large collections.

If you ever swap between 12B and 27B, the embedding dimension may change; ClawD detects this on startup and clears the HNSW index automatically. Re-index from the **Notes** tab after switching.

---

## 3. Audio Transcription (Optional)

Discord voice messages can be transcribed locally using whisper.cpp. The whisper.cpp static library is included in `deps/` — no extra setup required.

1. Set the Audio toggle to **whisper**
2. Click **Base** (142 MB, faster) or **Small** (466 MB, more accurate) to download a model, or **Browse** to select your own
3. Click **Save Config**, then **Start** (or restart)

When a voice message arrives on Discord:
1. The audio file is downloaded to `working/tmp/`
2. It's converted from OGG to WAV (via macOS `afconvert`)
3. Whisper transcribes the audio locally
4. The transcript is passed to the AI as a user message
5. After the AI responds, the transcript is posted to Discord
6. An ear emoji is added to the original voice message

Without whisper configured, voice messages are ignored.

---

## 4. Discord Bot (Optional)

Discord integration lets you chat with ClawD from any device. Reminders, proactive messages, and AI responses are all sent to your Discord channel.

### Create the Bot

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications)
2. Click **New Application**, name it "ClawD" (or anything)
3. Go to **Bot** in the left sidebar
4. Click **Reset Token** and copy the token — this is your **Bot Token**

### Enable Privileged Intents

Still on the Bot page:

1. Scroll down to **Privileged Gateway Intents**
2. Enable **Message Content Intent** (required — without this, ClawD can't read messages)
3. Enable **Server Members Intent** if you want username resolution
4. Click **Save Changes**

### Invite the Bot to Your Server

1. Go to **OAuth2** > **URL Generator** in the left sidebar
2. Under **Scopes**, check `bot`
3. Under **Bot Permissions**, check:
   - Send Messages
   - Read Message History
   - Add Reactions
   - Manage Messages (optional, for removing reactions)
4. Copy the generated URL and open it in your browser
5. Select your server and authorize

### Get the Channel ID

1. In Discord, go to **User Settings** > **Advanced** > enable **Developer Mode**
2. Right-click the channel you want ClawD to monitor
3. Click **Copy Channel ID** — it's a long number like `679801235737542657`

### ClawD Configuration

- **Bot Token**: paste the token from step 4
- **Channel ID**: paste the numeric ID
- **Assistant Name**: `ClawD` (or whatever you like — this is injected into the AI's system prompt)
- **Reaction Emoji**: the emoji ClawD adds to messages while processing (default: crab)

### How It Works

When ClawD is running and Discord is connected:

- Messages in the configured channel are received via WebSocket
- ClawD adds a crab reaction to acknowledge the message
- The AI processes the message and responds
- The response is sent back to Discord
- A tool-specific emoji is added (bell for reminders, memo for notes, etc.)
- The crab reaction is removed

The General tab shows "Discord: Connected" next to the status indicator. If the connection fails, you'll see a toast with the error. Common issues:

| Error | Fix |
|-------|-----|
| Close code 4014 | Enable Message Content Intent in Developer Portal |
| Close code 4004 | Invalid bot token — regenerate it |
| Connection refused | Check your internet connection |
| Max reconnect attempts | The bot will stop trying after 5 failures — click Stop then Start |

---

## 5. Google Calendar (Optional)

Calendar integration syncs your Google Calendar events and lets the AI create, edit, and delete events.

### Create a Google Cloud Project

1. Go to [console.cloud.google.com](https://console.cloud.google.com/)
2. Click **Select a project** > **New Project**
3. Name it (e.g. "ClawD") and click **Create**
4. Make sure the new project is selected

### Enable the Calendar API

1. Go to **APIs & Services** > **Library**
2. Search for "Google Calendar API"
3. Click it and click **Enable**

### Create a Service Account

1. Go to **APIs & Services** > **Credentials**
2. Click **Create Credentials** > **Service Account**
3. Name it (e.g. "clawd-service") and click **Create and Continue**
4. Skip the optional role and user access steps, click **Done**
5. Click on the newly created service account
6. Go to the **Keys** tab
7. Click **Add Key** > **Create new key** > **JSON** > **Create**
8. A `.json` file downloads — this is your service account key

### Share Your Calendar

1. Go to [calendar.google.com](https://calendar.google.com/)
2. Click the three dots next to the calendar you want to share > **Settings and sharing**
3. Under **Share with specific people**, click **Add people**
4. Enter the service account email (it looks like `clawd-service@your-project.iam.gserviceaccount.com` — ClawD shows this after you load the JSON)
5. Set permission to **Make changes to events**
6. Click **Send**

### Get Your Calendar ID

Still on the calendar settings page:

1. Scroll down to **Integrate calendar**
2. Copy the **Calendar ID**
   - For your primary calendar, it's your Gmail address
   - For secondary calendars, it's a long string ending in `@group.calendar.google.com`

### ClawD Configuration

1. In the **Calendar** section of the General tab, click **Browse...**
2. Select the downloaded JSON key file — it gets copied to `working/calendar.json`
3. The service account email appears below
4. Enter your **Calendar ID** in the "Your Calendar ID" field
5. Set the **Sync Interval** (default: 20 minutes)

### Test It

1. Click **Save Config** then **Start** (or restart if already running)
2. Go to the **Calendar** tab
3. Click **Sync Now**
4. Your events should appear in the 14-day view

If sync fails, check the Xcode console for `[Calendar]` log lines — they show the exact URL and status code.

### Without Google Calendar

If you don't configure Google Calendar, the calendar still works locally:
- The AI can create, edit, and delete events
- Events are stored in `working/calendar_cache.json`
- Local events show an orange "local" badge in the Calendar tab
- The AI tells the user that Google Calendar isn't connected

---

## 6. Notifications (Optional)

Scheduled messages that fire automatically. Enable them with the checkboxes and set the time.

| Notification | Default Time | What It Does |
|--------------|-------------|--------------|
| Daily Report | 07:00 | AI generates a morning briefing (meals, calendar, chores, reminders) |
| Meal Prep Reminder | 15:00 | AI reminds you about tonight's dinner and any prep needed |
| Overdue Chores | 10:00 | AI lists chores that are past due |
| End of Day Summary | 21:00 | AI summarizes what got done and previews tomorrow |
| Calendar Heads-Up | 30 min before | Notifies you before each calendar event |

All notifications:
- Run through the AI backend (so the message is natural language)
- Are sent to Discord (if connected)
- Appear as macOS desktop notifications
- Are logged in the chat history

The **Calendar Sync Interval** (in the Calendar section) controls how often events are fetched from Google. This is separate from the notifications.

---

## 7. Advanced Settings

| Setting | Default | What It Controls |
|---------|---------|-----------------|
| Chat History | 25 exchanges | How many past messages are included in the AI prompt |
| Heartbeat Interval | 30 seconds | How often the task queue is checked for due reminders/notifications |
| Note Search Results | 5 | How many semantically similar notes are injected into context |
| Max Notes in Index | 10000 | Maximum capacity of the HNSWLIB embedding index |

---

## 8. Prompt Templates

The AI's personality and instructions are editable files in `working/prompts/`:

- **`system_prompt.md`** — the base system prompt (tool format, personality)
- **`profile.md`** — your preferences (dietary restrictions, wake time, chore color meanings)
- **`notes.txt`** — reference file listing supported `{{variables}}`

Edit these with any text editor. The defaults are created on first start. If you delete a file, the default is regenerated.

---

## 9. Saving and Loading

- Click **Save Config** to write all settings to `working/config.json`
- Config is auto-loaded on app launch if the file exists
- Click **Start** to initialize the core, connect Discord, and begin the heartbeat
- Click **Stop** to disconnect everything cleanly

Settings that require a restart to take effect: Gemma model path, mmproj path, context length, working directory, heartbeat interval.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| App crashes when clicking tabs | Make sure you clicked **Start** first |
| Chat bubbles don't appear | Check that `chatLog.count` is non-zero in the console |
| Discord won't connect | Enable Message Content Intent in the Developer Portal |
| Calendar sync returns 0 events | Enter your Calendar ID (not "primary") and share the calendar with the service account |
| Gemma fails to load | Check the Xcode console for `[Gemma]` log lines. Verify the model path points at a real GGUF file. On 27B, try lowering Context Length. |
| `[Error: Gemma is not loaded]` in chat | Set the model path in the Gemma card, Save Config, then Stop/Start. |
| Attach-image button greyed out | The vision projector (mmproj) isn't loaded. Re-run the download or browse to the `mmproj-*.gguf` file. |
| Reminders don't fire | Check the console for `[Reminder]` log lines — verify the delay is positive |
| Permission popups on every build | The `.app` is rebuilt with a new signature each time — this is normal during development |
