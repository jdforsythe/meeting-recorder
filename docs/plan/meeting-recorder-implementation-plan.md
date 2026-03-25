# Meeting Recorder — Implementation Plan

## Overview

A meeting recording and transcription system split into two halves:

1. **Deterministic half:** A macOS SwiftUI menu bar app + CLI pipeline that handles recording, audio conversion, and transcription. No LLM calls. Fully testable, always produces the same output for the same input.
2. **Agent half:** An MCP server with two tools that Claude Code (or any MCP client) uses to start recordings and retrieve transcripts. The LLM handles intent parsing, transcript summarization, action item extraction, and writing structured notes to the Obsidian vault.

### Architecture Principle

> Deterministic logic must be code. Fuzzy/interpretive logic can be LLM. The static pipeline (record → convert → transcribe → write file) is coded and tested. The agent layer only handles intent parsing, summarization, and vault integration.

---

## System Diagram

```
User says "Record my standup"
        │
        ▼
┌─────────────────────┐
│  Claude Code (LLM)  │ ◄── Fuzzy: parses intent, picks params
│  calls MCP tool:    │
│  start_recording()  │
└────────┬────────────┘
         │ returns { output_path, status: "recording" }
         │ agent STOPS here, does nothing until user returns
         ▼
┌─────────────────────┐
│  MCP Server         │ ◄── Thin wrapper, spawns app
│  (Python/FastMCP)   │
└────────┬────────────┘
         │ launches via `open` command
         ▼
┌─────────────────────────────────────────┐
│  MeetingRecorder.app (SwiftUI)          │ ◄── Deterministic
│  Menu bar: red pulsing dot              │
│  macOS notification: "Recording started"│
│                                         │
│  User clicks Stop                       │
│  ┌────────────────────────────────┐     │
│  │ Internal pipeline (no LLM):   │     │
│  │ 1. sox stops recording → .wav │     │
│  │ 2. ffmpeg → 16kHz mono .wav   │     │
│  │ 3. whisper-cpp → transcript   │     │
│  │ 4. Write .md to output_path   │     │
│  │ 5. Write .done sentinel       │     │
│  └────────────────────────────────┘     │
│  Menu bar: brick animation              │
│  Hover tooltip: "Converting audio..."   │
│  macOS notification: "Transcript ready" │
│  App stays running (idle state)         │
└─────────────────────────────────────────┘

... time passes, user returns to Claude Code ...

User says "Grab that transcript"
        │
        ▼
┌─────────────────────┐
│  Claude Code (LLM)  │
│  calls MCP tool:    │
│  get_transcript()   │
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  MCP Server         │ ◄── Checks .done file exists, reads .md
│  returns transcript │
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Claude Code (LLM)  │ ◄── Fuzzy: summarize, extract action items,
│  writes to Obsidian │     apply frontmatter schema, write via
│  via Obsidian MCP   │     Obsidian MCP server
└─────────────────────┘
```

---

## Phase 1: CLI Pipeline

Build and test this first, standalone, before any UI or MCP work. This is the core deterministic engine.

### Prerequisites (one-time install)

```bash
brew install whisper-cpp ffmpeg sox blackhole-2ch
```

Then in Audio MIDI Setup:
- Create a Multi-Output Device: BlackHole 2ch + your speakers/headphones
- Set this as your system output so Teams/Zoom audio routes through BlackHole while you still hear it

Download the whisper model:
```bash
# The large-v3-turbo model is the sweet spot for Apple Silicon
# Check whisper-cpp docs for the exact download command — it may be:
whisper-cpp --download-model large-v3-turbo
# or download from huggingface and place in a known path like ~/models/
```

### File: `meeting-pipeline.sh`

A single bash script that is the entire deterministic pipeline. This is what the SwiftUI app will call internally.

**Arguments:**
- `--source mic|system|both` — which audio source to record
- `--output /path/to/transcript.md` — where to write the final transcript
- `--model large-v3-turbo` — whisper model (default: large-v3-turbo)
- `--model-path ~/models/ggml-large-v3-turbo.bin` — path to model file
- `--language en` — language code (default: en)
- `--action start|stop|process` — what phase to run

**Behavior for `--action start`:**
1. Determine the CoreAudio device name based on `--source`:
   - `mic` → built-in or external microphone (detect with `sox` or let user configure)
   - `system` → `"BlackHole 2ch"`
   - `both` → record both simultaneously, merge later
2. Start `sox` recording to a temp `.wav` file
3. Write the sox PID to a `.pid` file next to the output path
4. Exit immediately (sox runs in background)

**Behavior for `--action stop`:**
1. Read the `.pid` file
2. Send SIGINT to the sox process (graceful stop)
3. Wait for sox to finish writing
4. Exit

**Behavior for `--action process`:**
1. Read the raw `.wav` from the temp location
2. Run ffmpeg to convert to 16kHz mono WAV (whisper requirement):
   ```bash
   ffmpeg -y -i raw_recording.wav -ar 16000 -ac 1 /tmp/meeting_16k.wav
   ```
3. Run whisper-cpp:
   ```bash
   whisper-cpp \
     --language en \
     --model ~/models/ggml-large-v3-turbo.bin \
     --output-txt \
     --file /tmp/meeting_16k.wav \
     --output-file /path/to/output
   ```
   This produces `/path/to/output.txt`
4. Rename/move the `.txt` to the target `.md` path (or just write as `.md`)
5. Write a `.done` sentinel file at `{output_path}.done`
6. Clean up temp files (raw wav, 16k wav, pid file)
7. Exit 0

**Testing the pipeline standalone:**
```bash
# Start recording from mic
./meeting-pipeline.sh --source mic --output /tmp/test-meeting.md --action start

# Wait a few seconds, then stop
./meeting-pipeline.sh --output /tmp/test-meeting.md --action stop

# Process the recording
./meeting-pipeline.sh --source mic --output /tmp/test-meeting.md --action process

# Verify output
cat /tmp/test-meeting.md
ls /tmp/test-meeting.md.done
```

### Implementation notes for the pipeline script

- Use `set -euo pipefail` for strict error handling
- All temp files should live in a predictable location, e.g., `/tmp/meeting-recorder/{session-id}/`
- The session ID can be derived from the output filename or a timestamp
- For `--source both`: run two sox processes (mic + BlackHole), then `sox -m mic.wav system.wav combined.wav` to merge before processing
- Detect available audio devices with: `sox -V -t coreaudio null -n 2>&1 | grep "Found Audio" | cut -d'"' -f2`
- For device names, consider a config file at `~/.config/meeting-recorder/config.sh` that stores the user's preferred mic device name and BlackHole device name, since these vary by hardware
- Exit codes: 0 = success, 1 = sox/recording error, 2 = ffmpeg error, 3 = whisper error, 4 = file write error

---

## Phase 2: SwiftUI Menu Bar App

Once the CLI pipeline works standalone, wrap it in a native macOS menu bar app.

### Project setup

- Create a new Xcode project: macOS → App → SwiftUI → Swift
- App name: `MeetingRecorder`
- Set `Info.plist`: `Application is agent (UIElement)` = `YES` (no dock icon)
- Use `MenuBarExtra` with `.menuBarExtraStyle(.window)` for the custom popover view
- Minimum deployment target: macOS 14 (Sonoma) for latest SwiftUI features
- The app bundle should include or reference the `meeting-pipeline.sh` script (or embed the pipeline logic directly in Swift using `Process` to call sox/ffmpeg/whisper-cpp)

### App lifecycle / state machine

```
IDLE  ──(start recording)──▶  RECORDING  ──(stop clicked)──▶  PROCESSING  ──(done)──▶  IDLE
  │                              │                                │
  │                              │                                │
  ▼                              ▼                                ▼
Menu bar: gray mic icon     Red pulsing dot               Brick animation
Click: shows popover        Click: stops recording         Hover: shows step
  - "Start Recording"       Notification: "Recording..."   Notification: "Done!"
  - Source picker
  - Quit
```

### States and UI

**State: IDLE**
- Menu bar icon: gray microphone SF Symbol (`mic.fill` or similar), subtle, not attention-grabbing
- Clicking the icon opens a popover/window with:
  - "Start Recording" button
  - Source picker: Microphone / System Audio / Both (segmented control or picker)
  - A small "Quit" button at the bottom
  - Shows last recording info if any (timestamp, duration, output path)

**State: RECORDING**
- Menu bar icon: red pulsing circle (SF Symbol `record.circle` with a pulsing animation, or a custom red dot)
- The pulse animation: use SwiftUI's `.symbolEffect(.pulse)` or a custom `withAnimation(.easeInOut(duration: 1).repeatForever())` on opacity
- Clicking the red icon: stops the recording immediately
- macOS notification on enter: "Meeting Recorder — Recording started" (use `UNUserNotificationCenter`)
- Optional: show elapsed time in the popover if opened

**State: PROCESSING**
- Menu bar icon: the brick animation (see below)
- Clicking the icon opens a popover showing current step text:
  - "Stopping recording..."
  - "Converting audio format..."
  - "Transcribing with Whisper..."
  - "Writing transcript..."
- The step updates are driven by the pipeline — either by parsing stdout from the subprocess, or by checking for intermediate files, or by the Swift code calling each pipeline step sequentially and updating state between them
- Hover tooltip on the menu bar icon: shows the current step as a one-liner (use `.help()` modifier or NSStatusItem button toolTip)
- macOS notification on complete: "Meeting Recorder — Transcript ready" with the output filename
- After notification: transition back to IDLE

### The Brick Animation

This is the custom menu bar icon animation during PROCESSING state. It's a looping sequence of small frames rendered as an animated SF Symbol replacement or a series of `NSImage` frames.

**Concept:** ~12-16 frames of a tiny (18x18 or so) pixel animation:
1. Frames 1-4: Bricks stacking into a pyramid (one brick appears per frame, building up)
2. Frames 5-6: Pyramid collapses into a heap (bricks scatter/fall)
3. Frames 7-10: Bricks reassemble into a rectangular building shape
4. Frames 11-12: Building collapses into heap
5. Loop back to frame 1

**Implementation approach:**
- Create the frames as small SF Symbol-sized images (recommend 18x18pt, @2x = 36x36px)
- Store as an array of `NSImage` in the app bundle
- Use a `Timer` (e.g., every 0.25s) to cycle through frames and update `statusItem.button?.image`
- OR: render them as a SwiftUI `TimelineView` if using a custom label for `MenuBarExtra`
- The frames should be template images (monochrome, `isTemplate = true`) so they adapt to light/dark menu bar
- Consider generating these programmatically with SwiftUI `Canvas` or `Path` drawings rather than static assets — this keeps them resolution-independent and avoids bundling image files

### Launching from MCP / command line

The app needs to accept launch arguments so the MCP server can tell it what to do:

```bash
# MCP server launches app with params
open -a MeetingRecorder --args --source mic --output /path/to/transcript.md

# Or if using the raw binary:
/path/to/MeetingRecorder.app/Contents/MacOS/MeetingRecorder \
  --source mic \
  --output /path/to/transcript.md
```

When launched with `--source` and `--output` args:
1. App starts (or is already running)
2. Immediately begins recording with the specified source
3. Enters RECORDING state
4. Fires the "Recording started" notification

When launched without args (user clicks app icon directly):
1. App starts in IDLE state
2. User picks source and clicks "Start Recording" manually

**Handling the "already running" case:**
- If the app is already running and receives new launch args, it should start a new recording (if idle) or reject (if already recording)
- Use `NSAppleEventManager` to handle reopen events, or use a URL scheme (`meetingrecorder://start?source=mic&output=/path/to/file.md`)
- A URL scheme is cleaner for MCP invocation: `open "meetingrecorder://start?source=mic&output=/path/to/file.md"`

### Audio recording implementation

Rather than shelling out to `sox` from Swift (which works but is clunky), consider using `AVAudioEngine` or `AVCaptureSession` directly in Swift for the recording portion. This gives you:
- Native access to CoreAudio devices
- No dependency on sox at runtime (one fewer brew install)
- Better control over start/stop lifecycle
- Access to audio levels for a visual meter in the popover

However, if you want to keep the pipeline as a single bash script that's testable independently, shelling out to `sox` via `Process` is perfectly fine. The tradeoff is testability-of-pipeline vs native-feel.

**Recommendation:** Use `Process` to call the pipeline script for Phase 2. This keeps the pipeline independently testable. In a future Phase, you could replace sox with native AVAudioEngine if you want to eliminate the sox dependency.

### Notification implementation

```swift
import UserNotifications

// Request permission on first launch
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
    // handle
}

// Send notification
func sendNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}
```

### Config file

Store user preferences at `~/.config/meeting-recorder/config.json`:

```json
{
  "micDevice": "MacBook Pro Microphone",
  "systemDevice": "BlackHole 2ch",
  "whisperModel": "large-v3-turbo",
  "whisperModelPath": "~/models/ggml-large-v3-turbo.bin",
  "language": "en",
  "defaultOutputDir": "~/Documents/meeting-transcripts/",
  "defaultSource": "mic"
}
```

The app reads this on launch. The MCP server can also read it to supply defaults. The pipeline script reads it for device names.

---

## Phase 3: MCP Server

A thin Python MCP server with exactly two tools. It does NOT do any audio processing — it just launches the app and reads files.

### File: `meeting_recorder_mcp.py`

Use FastMCP (pip install fastmcp).

**Tool 1: `start_recording`**

Parameters:
- `source`: string, one of "mic", "system", "both" (default from config)
- `output_path`: string, optional — if not provided, generate one like `~/Documents/meeting-transcripts/2026-03-25T14-30-standup.md`
- `meeting_name`: string, optional — human-friendly name used in filename generation

Behavior:
1. Generate output_path if not provided (using timestamp + meeting_name)
2. Launch the SwiftUI app via URL scheme or `open` command:
   ```python
   subprocess.Popen([
       "open", "meetingrecorder://start",
       f"?source={source}&output={output_path}"
   ])
   # or:
   subprocess.Popen([
       "open", "-a", "MeetingRecorder",
       "--args", "--source", source, "--output", output_path
   ])
   ```
3. Return immediately:
   ```json
   {
     "status": "recording_started",
     "output_path": "/Users/jeremy/Documents/meeting-transcripts/2026-03-25T14-30-standup.md",
     "message": "Recording started. The MeetingRecorder app is now recording. Tell me when you're ready to grab the transcript."
   }
   ```

**Tool 2: `get_transcript`**

Parameters:
- `output_path`: string — the path returned by start_recording

Behavior:
1. Check if `{output_path}.done` exists
   - If NO: return `{ "status": "not_ready", "message": "Transcript is not ready yet. The recording may still be in progress or processing." }`
   - If YES: read the `.md` file, return its contents
2. Return:
   ```json
   {
     "status": "ready",
     "output_path": "/path/to/transcript.md",
     "transcript": "... full transcript text ..."
   }
   ```

### MCP server config for Claude Code

In `~/.claude/settings.json` (user-wide) or project `.mcp.json`:

```json
{
  "mcpServers": {
    "meeting-recorder": {
      "command": "python",
      "args": ["/path/to/meeting_recorder_mcp.py"]
    }
  }
}
```

---

## Phase 4: Claude Code Skill

Create a skill that teaches the agent how to use this pipeline.

### File: `.claude/skills/meeting-recorder/SKILL.md`

Contents should explain:

1. **When to use:** User mentions recording a meeting, standup, sync, call, etc.
2. **How to start:** Call `start_recording` MCP tool with appropriate source and meeting name
3. **What happens next:** The app is now recording. DO NOT poll or wait. Tell the user the recording has started and to come back when they're done.
4. **How to retrieve:** When user says they're done or asks for the transcript, call `get_transcript` with the output_path from the earlier call
5. **If not ready:** Tell the user the transcript is still processing and to try again in a moment
6. **Post-processing:** Once you have the raw transcript:
   - Summarize the meeting in 3-5 bullet points
   - Extract action items with owners (if identifiable from speaker context)
   - Extract key decisions made
   - Format as an Obsidian note with frontmatter:
     ```yaml
     ---
     type: meeting-note
     date: 2026-03-25
     workstreams:
       - platform
     attendees:
       - (extract from transcript or ask user)
     tags:
       - meeting
       - standup
     ---
     ```
   - Write to the Obsidian vault using the Obsidian MCP server's `write_note` tool
7. **Source selection heuristic:**
   - "in-person meeting" / "standup" / "at my desk" → `mic`
   - "Teams call" / "Zoom" / "video call" / "remote" → `system`
   - "hybrid" / "in the conference room with remote folks" → `both`

---

## Phase 5: Polish & Iteration

Once the core loop works end-to-end:

### Nice-to-haves
- **Audio level meter** in the popover during recording (confirms mic is picking up audio)
- **Speaker diarization** — whisper.cpp has experimental support; adds "Speaker 1:", "Speaker 2:" labels
- **Configurable whisper model** — let the user pick in the menu bar app settings (small for speed, large for accuracy)
- **Launch at login** — toggle in the app so it's always in the menu bar
- **Keyboard shortcut** — global hotkey to start/stop recording (e.g., ⌘⇧R)
- **Recording history** — list of past recordings in the popover, click to open transcript
- **Auto-detect meeting source** — if Teams/Zoom is running, default to `system`
- **Intermediate transcript** — whisper-cpp can output as it processes; stream partial results to the popover

### Potential refactors
- Replace sox with native `AVAudioEngine` in Swift (removes sox dependency)
- Replace bash pipeline with Swift `Process` calls directly (removes bash dependency)
- Add a `--format json` flag to the pipeline that outputs structured JSON (timestamps, segments, confidence scores) instead of plain text — richer data for the LLM to work with

---

## File Structure

```
meeting-recorder/
├── pipeline/
│   ├── meeting-pipeline.sh        # Phase 1: standalone CLI pipeline
│   ├── config.example.json        # Example config file
│   └── test-pipeline.sh           # Test script for the pipeline
├── app/
│   ├── MeetingRecorder/           # Phase 2: Xcode project
│   │   ├── MeetingRecorderApp.swift
│   │   ├── AppState.swift         # State machine (idle/recording/processing)
│   │   ├── MenuBarView.swift      # Popover UI
│   │   ├── BrickAnimation.swift   # The processing animation frames
│   │   ├── PipelineRunner.swift   # Calls meeting-pipeline.sh via Process
│   │   ├── NotificationManager.swift
│   │   ├── ConfigManager.swift    # Reads ~/.config/meeting-recorder/config.json
│   │   └── Info.plist
│   └── MeetingRecorder.xcodeproj
├── mcp/
│   ├── meeting_recorder_mcp.py    # Phase 3: FastMCP server
│   └── requirements.txt           # fastmcp
└── skill/
    └── SKILL.md                   # Phase 4: Claude Code skill
```

---

## Build Order

1. **Pipeline script** — get `meeting-pipeline.sh` working end-to-end from the terminal. Record 30 seconds, verify you get a transcript `.md` and a `.done` file.
2. **MCP server** — wire up the two tools pointing at the pipeline script. Test from Claude Code: start a recording, stop it manually in terminal, then retrieve transcript.
3. **SwiftUI app** — build the menu bar app that wraps the pipeline. Start with basic start/stop, then add notifications, then the brick animation.
4. **Skill file** — write the SKILL.md and test the full loop: tell Claude to record, have the meeting, come back, get the transcript, see it land in your Obsidian vault.

---

## Dependencies Summary

| Tool | Install | Purpose | Phase |
|------|---------|---------|-------|
| sox | `brew install sox` | Audio recording from CoreAudio devices | 1 |
| ffmpeg | `brew install ffmpeg` | Audio format conversion (→ 16kHz mono WAV) | 1 |
| whisper-cpp | `brew install whisper-cpp` | Local speech-to-text transcription | 1 |
| BlackHole 2ch | `brew install blackhole-2ch` | Virtual audio loopback for system audio | 1 |
| Python 3 | system or brew | MCP server runtime | 3 |
| fastmcp | `pip install fastmcp` | MCP server framework | 3 |
| Xcode | App Store | Build SwiftUI menu bar app | 2 |

All free and open source (except Xcode, which is free but proprietary).
