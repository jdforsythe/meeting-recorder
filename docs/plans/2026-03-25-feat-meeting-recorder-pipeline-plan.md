---
title: "Meeting Recorder: Recording, Transcription & Obsidian Integration"
type: feat
status: active
date: 2026-03-25
---

# Meeting Recorder: Recording, Transcription & Obsidian Integration

## Overview

A meeting recording and transcription system for macOS split into two halves:

1. **Deterministic half:** A macOS SwiftUI menu bar app + CLI pipeline that handles recording, audio conversion, and transcription. No LLM calls. Fully testable, always produces the same output for the same input.
2. **Agent half:** An MCP server with two tools that Claude Code (or any MCP client) uses to start recordings and retrieve transcripts. The LLM handles intent parsing, transcript summarization, action item extraction, and writing structured notes to the Obsidian vault.

**Architecture Principle:** Deterministic logic must be code. Fuzzy/interpretive logic can be LLM. The static pipeline (record → convert → transcribe → write file) is coded and tested. The agent layer only handles intent parsing, summarization, and vault integration.

## Problem Statement / Motivation

Meeting notes are a constant overhead. Recording exists but transcription, summarization, and structured note-taking are manual. The goal is a system where "record my standup" is a single utterance to Claude, and after the meeting a structured Obsidian note with summary, action items, and proper frontmatter appears in the vault — with zero manual steps beyond starting and stopping.

## Proposed Solution

Four-phase build, each independently testable before integrating with the next:

1. **Phase 1 — CLI Pipeline** (`pipeline/meeting-pipeline.sh`): Bash script using sox, ffmpeg, whisper-cpp
2. **Phase 2 — SwiftUI Menu Bar App** (`app/MeetingRecorder/`): Native macOS wrapper with state machine
3. **Phase 3 — MCP Server** (`mcp/meeting_recorder_mcp.py`): FastMCP v3 with two tools
4. **Phase 4 — Claude Code Skill** (`.claude/skills/meeting-recorder/SKILL.md`): Agent instruction set

**Recommended build order adjustment:** Build Phase 3 before Phase 2. The MCP server can drive the bash script directly, enabling the full Claude → MCP → pipeline → transcript loop before investing in SwiftUI. The SwiftUI app then wraps an already-proven pipeline.

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
         │ returns { session_id, output_path, status: "recording_started" }
         │ agent STOPS here, does nothing until user returns
         ▼
┌─────────────────────┐
│  MCP Server         │ ◄── Thin wrapper, spawns pipeline or app
│  (Python/FastMCP)   │     Writes current-session.json
└────────┬────────────┘
         │ launches via URL scheme or open command
         ▼
┌─────────────────────────────────────────┐
│  MeetingRecorder.app (SwiftUI)          │ ◄── Deterministic
│  Menu bar: red pulsing dot              │
│  macOS notification: "Recording started"│
│                                         │
│  User clicks Stop                       │
│  ┌────────────────────────────────┐     │
│  │ Internal pipeline (no LLM):   │     │
│  │ 1. SIGINT to sox → .wav       │     │
│  │ 2. Write .processing sentinel │     │
│  │ 3. ffmpeg → 16kHz mono .wav   │     │
│  │ 4. whisper-cpp → transcript   │     │
│  │ 5. Write .md to output_path   │     │
│  │ 6. Write .done sentinel       │     │
│  │ OR: Write .error sentinel     │     │
│  └────────────────────────────────┘     │
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
│  get_transcript()   │ ◄── Falls back to current-session.json if no path
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  MCP Server         │ ◄── Checks sentinels: .done / .error / .recording / .processing
│  returns transcript │
│  with rich status   │
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  Claude Code (LLM)  │ ◄── Fuzzy: summarize, extract action items,
│  writes to Obsidian │     apply full frontmatter schema, write via
│  via Obsidian MCP   │     Obsidian MCP server
└─────────────────────┘
```

## Technical Approach

### Sentinel File Contract

The entire system communicates state through the filesystem. This is the single source of truth shared between all layers:

| Sentinel | Written by | Meaning | Content |
|---|---|---|---|
| `{output_path}.pid` | Pipeline (start) | sox is recording | PID and process start timestamp |
| `{output_path}.recording` | Pipeline (start) | Recording confirmed active | Session ID, source, start time (JSON) |
| `{output_path}.processing` | Pipeline (stop) | Audio processing in progress | Current step name |
| `{output_path}.done` | Pipeline (process) | Transcript ready | Empty or transcript hash |
| `{output_path}.error` | Pipeline (any step) | A step failed permanently | JSON: `{step, exit_code, stderr}` |

**Cleanup rule:** On successful `.done`, delete `.pid`, `.recording`, `.processing`. On `.error`, delete `.pid`, `.processing` but keep `.recording` for debugging. The `.error` and `.done` files persist until the next `start_recording` targeting the same output path.

### Phase 1: CLI Pipeline

**File:** `pipeline/meeting-pipeline.sh`

**Prerequisites (one-time install):**

```bash
brew install whisper-cpp ffmpeg sox blackhole-2ch
```

Then in Audio MIDI Setup:
- Create a Multi-Output Device: Built-in Output (must be first/clock source) + BlackHole 2ch (enable Drift Correction)
- Set this as system output so meeting audio routes through BlackHole while you still hear it

Download the whisper model:
```bash
mkdir -p ~/models
curl -L -o ~/models/ggml-large-v3-turbo-q5_0.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true"
```

> **Note:** The quantized Q5_0 model (574 MB) is recommended over full precision (1.62 GB) for good speed/quality balance on Apple Silicon.

**Arguments:**

- `--source mic|system|both` — which audio source to record
- `--output /path/to/transcript.md` — where to write the final transcript
- `--model-path ~/models/ggml-large-v3-turbo-q5_0.bin` — path to model file
- `--language en` — language code (default: en)
- `--action start|stop|process` — what phase to run

**Behavior for `--action start`:**

1. Validate prerequisites: check sox, ffmpeg, whisper-cpp binaries exist
2. Validate audio device exists for the given `--source`:
   - `mic` → detect with `sox -V6 -n -t coreaudio junk 2>&1 | grep "Device"` or use config
   - `system` → verify `"BlackHole 2ch"` is available
   - `both` → verify both devices
3. Create session directory: `/tmp/meeting-recorder/{session-id}/` (session-id from output filename hash + timestamp)
4. Start sox recording to session temp `.wav`:
   ```bash
   # Let sox use device's native sample rate to avoid BlackHole rate mismatch
   sox -t coreaudio "BlackHole 2ch" /tmp/meeting-recorder/{session-id}/raw.wav &
   ```
5. Write `.pid` file: `{pid}:{process_start_timestamp}` (timestamp prevents stale PID reuse)
6. Write `.recording` sentinel (JSON with session_id, source, start_time)
7. Exit immediately (sox runs in background)

**Behavior for `--action stop`:**

1. Read the `.pid` file, extract PID and start timestamp
2. Validate PID: `kill -0 $pid` and check process name contains "sox"
3. If PID invalid (stale): write `.error` sentinel, clean up, exit 1
4. Send SIGINT to the sox process (graceful stop)
5. Wait for sox to finish writing (up to 10s timeout, then SIGKILL)
6. Remove `.pid` file
7. Write `.processing` sentinel with step "audio_stopped"
8. Exit

**Behavior for `--action process`:**

1. Read the raw `.wav` from session temp directory
2. Update `.processing` sentinel: step "converting_audio"
3. Convert to 16kHz mono WAV (whisper requirement):
   ```bash
   ffmpeg -y -i raw.wav -ar 16000 -ac 1 -c:a pcm_s16le /tmp/meeting-recorder/{session-id}/16k.wav
   ```
4. Update `.processing` sentinel: step "transcribing"
5. Set Metal GPU acceleration:
   ```bash
   export GGML_METAL_PATH_RESOURCES="$(brew --prefix whisper-cpp)/share/whisper-cpp"
   ```
6. Run whisper-cpp:
   ```bash
   whisper-cpp \
     -l en \
     -m ~/models/ggml-large-v3-turbo-q5_0.bin \
     --output-txt \
     -t 4 \
     -f /tmp/meeting-recorder/{session-id}/16k.wav \
     --output-file /tmp/meeting-recorder/{session-id}/transcript
   ```
7. Move transcript to target output path
8. Write `.done` sentinel
9. Clean up: remove `.recording`, `.processing`, session temp directory
10. Exit 0

**On any failure:** Write `.error` sentinel with JSON `{step, exit_code, stderr}`, clean up `.processing`, exit with appropriate code.

**Exit codes:** 0 = success, 1 = sox/recording error, 2 = ffmpeg error, 3 = whisper error, 4 = file write error, 5 = validation error (missing tools/devices)

**For `--source both`:** Run two sox processes (mic + BlackHole), merge with `sox -m mic.wav system.wav combined.wav` before processing. Track both PIDs in the `.pid` file.

**Implementation notes:**

- Use `set -euo pipefail` for strict error handling
- Detect available audio devices with: `sox -V6 -n -t coreaudio junk 2>&1 | grep "Device"`
- Config file at `~/.config/meeting-recorder/config.json` stores preferred device names

**Config file** (`~/.config/meeting-recorder/config.json`):

```json
{
  "micDevice": "MacBook Pro Microphone",
  "systemDevice": "BlackHole 2ch",
  "whisperModelPath": "~/models/ggml-large-v3-turbo-q5_0.bin",
  "language": "en",
  "defaultOutputDir": "~/Documents/meeting-transcripts/",
  "defaultSource": "mic"
}
```

**Testing the pipeline standalone:**

```bash
# Start recording from mic
./pipeline/meeting-pipeline.sh --source mic --output /tmp/test-meeting.md --action start

# Wait a few seconds, then stop
./pipeline/meeting-pipeline.sh --output /tmp/test-meeting.md --action stop

# Process the recording
./pipeline/meeting-pipeline.sh --source mic --output /tmp/test-meeting.md --action process

# Verify output
cat /tmp/test-meeting.md
ls /tmp/test-meeting.md.done
```

### Phase 2: SwiftUI Menu Bar App

**Project setup:**

- Xcode project: macOS → App → SwiftUI → Swift
- App name: `MeetingRecorder`
- `Info.plist`: `LSUIElement` = `YES` (no dock icon, no Cmd-Tab entry)
- Use `MenuBarExtra` with `.menuBarExtraStyle(.window)` for the popover
- Minimum deployment target: macOS 14 (Sonoma)
- App calls `pipeline/meeting-pipeline.sh` via Swift `Process`

**State machine:**

```
IDLE ──(start)──▶ RECORDING ──(stop clicked)──▶ PROCESSING ──(done)──▶ IDLE
  │                    │                              │
  │                    ├──(sox crash)──▶ IDLE (error notification)
  │                    │                              │
  │                    │                              ├──(ffmpeg/whisper fail)──▶ IDLE (error notification)
  │                    │                              │
  ▼                    ▼                              ▼
Gray mic icon     Red pulsing dot               Brick animation
Click: popover    Click: stop recording          Hover: current step
```

**State: IDLE**
- Menu bar icon: gray `mic.fill` SF Symbol
- Popover: "Start Recording" button, source picker (Microphone / System Audio / Both), last recording info, Quit button
- Pre-flight check before recording: mic permission, device availability, disk space

**State: RECORDING**
- Menu bar icon: red pulsing circle using `.symbolEffect(.pulse, isActive: true)` (macOS 14+)
- Clicking icon stops recording immediately
- macOS notification: "Meeting Recorder — Recording started"
- Popover shows elapsed time

**State: PROCESSING**
- Menu bar icon: brick animation (custom frame cycling via `Timer` at 0.25s intervals, `isTemplate = true` for light/dark adaptation)
- Popover shows current step text (driven by `.processing` sentinel content)
- Hover tooltip: current step one-liner
- macOS notification on complete: "Meeting Recorder — Transcript ready"

**Brick animation frames:** ~12-16 frames at 18x18pt (@2x = 36x36px). Generate programmatically with SwiftUI `Canvas`/`Path` for resolution independence:
1. Frames 1-4: Bricks stacking into pyramid
2. Frames 5-6: Pyramid collapses
3. Frames 7-10: Bricks form rectangle
4. Frames 11-12: Rectangle collapses, loop

**URL scheme handling (critical — `.onOpenURL` is unreliable in LSUIElement apps):**

```swift
// Use NSApplicationDelegateAdaptor to intercept URL events
class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .appReceivedURL, object: url)
        }
    }
}

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra { ContentView() } label: { /* ... */ }
            .menuBarExtraStyle(.window)
    }
}
```

Register URL scheme `meetingrecorder://` in Info.plist. URL format: `meetingrecorder://start?source=mic&output=%2Fpath%2Fto%2Ffile.md` (URL-encode the output path).

**Handling "already running" invocations:**
- If IDLE: start new recording with provided params
- If RECORDING: return error status, do NOT stop current recording (prevent data loss from Claude retries)
- If PROCESSING: return error status with "processing in progress"

**Notification implementation:**

```swift
import UserNotifications

UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

func sendNotification(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}
```

### Phase 3: MCP Server

**File:** `mcp/meeting_recorder_mcp.py`

Uses FastMCP v3.0+ (`pip install fastmcp`). Import: `from fastmcp import FastMCP`.

> **Correction from original plan:** MCP config goes in `~/.claude.json` (home directory root) or project `.mcp.json`, NOT `~/.claude/settings.json`.

**Tool 1: `start_recording`**

```python
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
import subprocess, os, json, datetime, hashlib

mcp = FastMCP("MeetingRecorder")

SESSION_REGISTRY = os.path.expanduser("~/.config/meeting-recorder/current-session.json")
PIPELINE_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "pipeline", "meeting-pipeline.sh")

@mcp.tool
def start_recording(
    source: str = "mic",
    output_path: str | None = None,
    meeting_name: str | None = None,
) -> dict:
    """Start recording a meeting. Returns session info and output path."""

    # Generate output_path if not provided
    if not output_path:
        config = _read_config()
        output_dir = os.path.expanduser(config.get("defaultOutputDir", "~/Documents/meeting-transcripts/"))
        os.makedirs(output_dir, exist_ok=True)
        timestamp = datetime.datetime.now().strftime("%Y-%m-%dT%H-%M")
        name_slug = _sanitize_filename(meeting_name) if meeting_name else "meeting"
        output_path = os.path.join(output_dir, f"{timestamp}-{name_slug}.md")

    # Check for existing recording at this path
    if os.path.exists(f"{output_path}.recording"):
        raise ToolError(
            f"A recording is already in progress at {output_path}. "
            "Stop it first or use a different output path."
        )

    # Launch pipeline
    subprocess.Popen([
        PIPELINE_SCRIPT,
        "--source", source,
        "--output", output_path,
        "--action", "start",
    ])

    # Write session registry for cross-conversation lookup
    session = {
        "output_path": output_path,
        "source": source,
        "meeting_name": meeting_name,
        "started_at": datetime.datetime.now().isoformat(),
    }
    os.makedirs(os.path.dirname(SESSION_REGISTRY), exist_ok=True)
    with open(SESSION_REGISTRY, "w") as f:
        json.dump(session, f)

    return {
        "status": "recording_started",
        "output_path": output_path,
        "source": source,
        "message": "Recording started. The MeetingRecorder app is now recording. "
                   "Tell me when you're ready to grab the transcript.",
    }
```

**Tool 2: `get_transcript`**

```python
@mcp.tool
def get_transcript(output_path: str | None = None) -> dict:
    """Retrieve transcript from a completed recording. Omit output_path to use the most recent session."""

    # Fall back to session registry if no path given
    if not output_path:
        if not os.path.exists(SESSION_REGISTRY):
            raise ToolError("No output_path provided and no recent session found.")
        with open(SESSION_REGISTRY) as f:
            session = json.load(f)
        output_path = session["output_path"]

    # Check sentinel files in priority order
    error_path = f"{output_path}.error"
    done_path = f"{output_path}.done"
    processing_path = f"{output_path}.processing"
    recording_path = f"{output_path}.recording"

    if os.path.exists(error_path):
        with open(error_path) as f:
            error_info = json.load(f)
        return {
            "status": "error",
            "output_path": output_path,
            "error": error_info,
            "message": f"Processing failed at step '{error_info.get('step')}': {error_info.get('stderr', 'unknown error')}",
        }

    if os.path.exists(done_path):
        with open(output_path) as f:
            transcript = f.read()
        return {
            "status": "ready",
            "output_path": output_path,
            "transcript": transcript,
        }

    if os.path.exists(processing_path):
        with open(processing_path) as f:
            step = f.read().strip()
        return {
            "status": "processing",
            "output_path": output_path,
            "current_step": step,
            "message": f"Audio is being processed (current step: {step}). Try again in 30 seconds.",
        }

    if os.path.exists(recording_path):
        return {
            "status": "recording",
            "output_path": output_path,
            "message": "Still recording. Stop the recording in the menu bar app first, then try again.",
        }

    raise ToolError(f"No session found at {output_path}. No sentinel files exist.")
```

**MCP config (project `.mcp.json`):**

```json
{
  "mcpServers": {
    "meeting-recorder": {
      "type": "stdio",
      "command": "python",
      "args": ["/Users/jforsythe/dev/ai/meeting-transcriber/mcp/meeting_recorder_mcp.py"]
    }
  }
}
```

### Phase 4: Claude Code Skill

**File:** `.claude/skills/meeting-recorder/SKILL.md`

```yaml
---
name: meeting-recorder
description: >
  Records meetings and retrieves transcripts for post-processing. Use when
  the user mentions recording a meeting, standup, sync, call, 1:1, retro,
  or any audio. Also handles transcript retrieval when the user returns
  and asks to grab, get, or process their transcript.
argument-hint: "[meeting name]"
allowed-tools: Bash
---
```

**Skill content covers:**

1. **When to use:** User mentions recording a meeting, standup, sync, call, etc.
2. **Source selection heuristic:**
   - "in-person" / "standup" / "at my desk" → `mic`
   - "Teams" / "Zoom" / "video call" / "remote" → `system`
   - "hybrid" / "conference room with remote folks" → `both`
   - No context provided → `mic` (safe default)
3. **Starting:** Call `start_recording` MCP tool. DO NOT poll or wait. Tell user recording has started.
4. **Retrieving:** Call `get_transcript`. Handle all status values:
   - `ready` → proceed to post-processing
   - `recording` → tell user to stop recording first
   - `processing` → tell user to wait ~30 seconds, ask if they want you to check again
   - `error` → report the error, suggest re-recording
5. **Post-processing:** Summarize in 3-5 bullets, extract action items with owners, extract key decisions. Write to Obsidian vault via Obsidian MCP `write_note` tool with full frontmatter:
   ```yaml
   ---
   type: meeting
   created: 2026-03-25
   updated: 2026-03-25
   workstreams:
     - (infer from content)
   status: active
   tags:
     - meeting
     - (infer type: standup, sync, retro, etc.)
   meeting-type: (standup|sync|retro|1:1|planning|other)
   attendees:
     - "[[Person Name]]"  # wikilinks required
   recurring: (true|false)
   source: meeting-recorder
   ---
   ```
   > Note: This schema matches the Obsidian vault at `/Users/jforsythe/Documents/Vault/work/`. Meeting notes go in `20-meetings/`.

## Implementation Phases

### Phase 1: CLI Pipeline (Foundation)

- [ ] Create `pipeline/meeting-pipeline.sh` with start/stop/process actions
- [ ] Implement sentinel file contract (.pid, .recording, .processing, .done, .error)
- [ ] Implement PID validation (check PID + start timestamp to prevent stale PID issues)
- [ ] Implement `--source both` dual-stream recording and merge
- [ ] Create `pipeline/config.example.json`
- [ ] Create `pipeline/test-pipeline.sh` — end-to-end test: record 10s, stop, process, verify .md and .done
- [ ] Test error paths: kill sox mid-record, feed corrupt audio to ffmpeg, verify .error sentinel

**Success criteria:** `test-pipeline.sh` produces a valid `.md` transcript and `.done` sentinel from a 10-second mic recording.

### Phase 2: MCP Server (Integration — build before SwiftUI app)

- [ ] Create `mcp/meeting_recorder_mcp.py` with FastMCP v3
- [ ] Implement `start_recording` tool with config reading, path generation, session registry
- [ ] Implement `get_transcript` tool with all sentinel status differentiation
- [ ] Create `mcp/requirements.txt` (fastmcp)
- [ ] Create `.mcp.json` project config
- [ ] Test from Claude Code: start recording via MCP, stop in terminal, retrieve transcript

**Success criteria:** Claude Code can call `start_recording`, user stops via terminal, Claude calls `get_transcript` and receives transcript text.

### Phase 3: SwiftUI Menu Bar App (Native UX)

- [ ] Create Xcode project with MenuBarExtra, LSUIElement=YES
- [ ] Implement state machine (IDLE → RECORDING → PROCESSING → IDLE, plus error transitions)
- [ ] Implement PipelineRunner.swift calling meeting-pipeline.sh via Process
- [ ] Implement URL scheme `meetingrecorder://` with NSApplicationDelegateAdaptor (not .onOpenURL)
- [ ] Implement notifications via UNUserNotificationCenter
- [ ] Implement pre-flight checks: mic permission, device availability
- [ ] Implement brick animation for PROCESSING state
- [ ] Handle "already recording" URL scheme invocations (reject, return error)
- [ ] Update MCP server to launch app via URL scheme instead of pipeline directly

**Success criteria:** App shows in menu bar, starts/stops recording, processes audio, shows notifications, responds to URL scheme from MCP server.

### Phase 4: Claude Code Skill (Agent Integration)

- [ ] Create `.claude/skills/meeting-recorder/SKILL.md`
- [ ] Define source selection heuristics
- [ ] Define post-processing instructions with full Obsidian frontmatter schema
- [ ] Test full loop: tell Claude to record → have meeting → retrieve transcript → see Obsidian note

**Success criteria:** "Record my standup" → recording starts → user stops → "grab the transcript" → structured note appears in Obsidian vault.

## Acceptance Criteria

### Functional Requirements

- [ ] CLI pipeline records audio from mic, system (BlackHole), or both sources
- [ ] whisper-cpp transcribes audio to .md with Metal GPU acceleration on Apple Silicon
- [ ] Sentinel files (.recording, .processing, .done, .error) accurately reflect system state at all times
- [ ] MCP `start_recording` launches recording and returns immediately with output path
- [ ] MCP `get_transcript` differentiates: ready, recording, processing, error, not found
- [ ] `get_transcript` works without output_path by reading session registry
- [ ] SwiftUI app shows correct menu bar icon for each state
- [ ] URL scheme `meetingrecorder://` starts recording when app is idle, rejects when busy
- [ ] Claude Code skill auto-invokes on recording-related user intent
- [ ] Post-processing writes Obsidian note with correct frontmatter to `20-meetings/`

### Non-Functional Requirements

- [ ] Pipeline handles recordings up to 2 hours (whisper-cpp context limit)
- [ ] All temp files cleaned up on success; preserved on error for debugging
- [ ] File permissions on transcripts are user-only (chmod 600)
- [ ] No secrets or credentials in any committed files
- [ ] URL parameters properly URL-encoded/decoded (handles spaces and special chars in paths)

## Dependencies & Prerequisites

| Tool | Install | Purpose | Phase |
|---|---|---|---|
| sox | `brew install sox` | Audio recording from CoreAudio devices | 1 |
| ffmpeg | `brew install ffmpeg` | Audio format conversion (→ 16kHz mono WAV) | 1 |
| whisper-cpp | `brew install whisper-cpp` | Local speech-to-text (binary: `whisper-cpp`) | 1 |
| BlackHole 2ch | `brew install blackhole-2ch` | Virtual audio loopback for system audio | 1 |
| Python 3 | system or brew | MCP server runtime | 2 |
| fastmcp | `pip install fastmcp` | MCP server framework (v3.0+) | 2 |
| Xcode | App Store | Build SwiftUI menu bar app | 3 |

**System setup required (one-time, manual):**
- Audio MIDI Setup: Create Multi-Output Device (Built-in Output as clock source + BlackHole 2ch with drift correction)
- Download whisper model: `curl -L -o ~/models/ggml-large-v3-turbo-q5_0.bin "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true"`
- Set `GGML_METAL_PATH_RESOURCES="$(brew --prefix whisper-cpp)/share/whisper-cpp"` in shell profile for GPU acceleration

**Current system state:**
- ffmpeg: installed (`/opt/homebrew/bin/ffmpeg`)
- sox: NOT installed
- whisper-cpp: NOT installed
- BlackHole 2ch: NOT installed

## Risk Analysis & Mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| Stale .pid pointing to recycled PID | SIGINT sent to wrong process | Store PID + start timestamp, validate both before signaling |
| BlackHole sample rate mismatch (48kHz vs 44.1kHz) | sox fails or corrupt audio | Let sox use device native rate, convert with ffmpeg afterward |
| SwiftUI `.onOpenURL` unreliable in LSUIElement apps | URL scheme invocations silently dropped | Use `NSApplicationDelegateAdaptor` for URL event interception |
| Claude loses output_path across conversations | Can't retrieve transcript | Session registry at `~/.config/meeting-recorder/current-session.json` |
| MCP start_recording called during active recording | Data loss if current recording stopped | Reject with ToolError, return current session info |
| Very long recordings (>2h) | whisper-cpp OOM or context overflow | Document limit in skill; future: implement chunked transcription |
| URL scheme called by unauthorized process | Covert recording trigger | v1 limitation — document and address in future phase |
| Meeting_name with filesystem-unsafe characters | File write failure | Sanitize: replace non-alphanumeric (except - _) with hyphens, truncate to 64 chars |

## File Structure

```
meeting-transcriber/
├── .mcp.json                         # MCP server config for Claude Code
├── pipeline/
│   ├── meeting-pipeline.sh           # Phase 1: standalone CLI pipeline
│   ├── config.example.json           # Example config file
│   └── test-pipeline.sh             # End-to-end test script
├── mcp/
│   ├── meeting_recorder_mcp.py       # Phase 2: FastMCP v3 server
│   └── requirements.txt             # fastmcp
├── app/
│   ├── MeetingRecorder/              # Phase 3: Xcode project
│   │   ├── MeetingRecorderApp.swift
│   │   ├── AppDelegate.swift         # URL scheme handling via NSApplicationDelegateAdaptor
│   │   ├── AppState.swift            # State machine (idle/recording/processing)
│   │   ├── MenuBarView.swift         # Popover UI
│   │   ├── BrickAnimation.swift      # Processing animation frames
│   │   ├── PipelineRunner.swift      # Calls meeting-pipeline.sh via Process
│   │   ├── NotificationManager.swift
│   │   ├── ConfigManager.swift       # Reads ~/.config/meeting-recorder/config.json
│   │   ├── PreflightChecker.swift    # Mic permission, device availability checks
│   │   └── Info.plist
│   └── MeetingRecorder.xcodeproj
└── .claude/
    └── skills/
        └── meeting-recorder/
            └── SKILL.md              # Phase 4: Claude Code skill
```

## Future Considerations (Phase 5)

- Audio level meter in popover during recording
- Speaker diarization (whisper.cpp experimental support)
- Launch at login toggle
- Global keyboard shortcut (⌘⇧R) for start/stop
- Recording history list in popover
- Auto-detect meeting source (if Teams/Zoom is running → default to system)
- Replace sox with native AVAudioEngine (removes sox dependency)
- Chunked transcription for recordings >2 hours
- `--format json` output with timestamps, segments, confidence scores

## Sources & References

### Internal References

- Original implementation plan: `docs/plan/meeting-recorder-implementation-plan.md`
- Obsidian vault structure: `/Users/jforsythe/Documents/Vault/work/docs/agent-knowledge/vault-structure.md`
- Existing skill pattern: `~/.claude/skills/gemini-image-generator/SKILL.md`

### External References

- [FastMCP v3 docs](https://gofastmcp.com/getting-started/welcome) — tool definition, error handling, transport config
- [whisper-cpp models](https://huggingface.co/ggerganov/whisper.cpp/tree/main) — GGML model downloads
- [whisper-cpp GitHub](https://github.com/ggml-org/whisper.cpp) — CLI flags, Metal acceleration
- [SwiftUI MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) — Apple docs
- [BlackHole Wiki](https://github.com/ExistentialAudio/BlackHole/wiki/Multi-Output-Device) — Multi-Output Device setup
- [Claude Code Skills](https://code.claude.com/docs/en/skills) — SKILL.md format and frontmatter
- [Claude Code MCP](https://code.claude.com/docs/en/mcp) — .mcp.json configuration

### Key Technical Corrections (from research)

- **MCP config location:** `~/.claude.json` or project `.mcp.json`, NOT `~/.claude/settings.json`
- **FastMCP v3:** Transport args moved to `mcp.run()`, not constructor. `@mcp.tool` (no parens) is v3 style.
- **whisper-cpp binary:** Homebrew installs as `whisper-cpp` (not `whisper` or `whisper-cli`)
- **Metal acceleration:** Requires `GGML_METAL_PATH_RESOURCES` env var or falls back to CPU silently
- **SwiftUI URL scheme:** `.onOpenURL` is unreliable in LSUIElement apps; must use `NSApplicationDelegateAdaptor`
- **BlackHole clock source:** Built-in Output MUST be first device (clock source) in Multi-Output Device
- **sox + BlackHole rate:** Don't specify `-r` flag; let sox use device native rate to avoid mismatch
