# Meeting Recorder

A meeting recording and transcription system for macOS split into two halves:

1. **Deterministic half:** A macOS SwiftUI menu bar app + CLI pipeline that handles recording, audio conversion, and transcription. No LLM calls. Fully testable.
2. **Agent half:** An MCP server with two tools that Claude Code uses to start recordings and retrieve transcripts. The LLM handles intent parsing, summarization, and Obsidian vault integration.

## Architecture

```
User says "Record my standup"
        │
        ▼
┌─────────────────────┐
│  Claude Code (LLM)  │ ← Fuzzy: parses intent, picks params
│  calls MCP tool:    │
│  start_recording()  │
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  MCP Server         │ ← Launches app (or pipeline directly)
│  (Python/FastMCP)   │
└────────┬────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  MeetingRecorder.app / Pipeline │ ← Deterministic
│  sox → ffmpeg → whisper-cpp     │
│  Writes .done sentinel + .md   │
└─────────────────────────────────┘

... user returns ...

User says "Grab that transcript"
        │
        ▼
┌─────────────────────┐
│  Claude Code (LLM)  │ ← Summarize, extract action items,
│  calls get_transcript│    write to Obsidian via MCP
└─────────────────────┘
```

## Prerequisites

```bash
brew install sox ffmpeg whisper-cpp blackhole-2ch
```

**One-time setup:**
- Audio MIDI Setup: Create a Multi-Output Device (Built-in Output as clock source + BlackHole 2ch with drift correction)
- Download the whisper model:
  ```bash
  mkdir -p ~/models
  curl -L -o ~/models/ggml-large-v3-turbo-q5_0.bin \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true"
  ```

## Configuration

Create `~/.config/meeting-recorder/config.json`:

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

See `pipeline/config.example.json` for a template.

## Components

### CLI Pipeline (`pipeline/meeting-pipeline.sh`)

Standalone bash script — the core deterministic engine.

```bash
# Start recording from mic
./pipeline/meeting-pipeline.sh --source mic --output /tmp/test.md --action start

# Stop recording
./pipeline/meeting-pipeline.sh --output /tmp/test.md --action stop

# Process (ffmpeg + whisper-cpp)
./pipeline/meeting-pipeline.sh --output /tmp/test.md --model-path ~/models/ggml-large-v3-turbo-q5_0.bin --action process

# Verify
cat /tmp/test.md
ls /tmp/test.md.done
```

**Arguments:** `--source mic|system|both`, `--output PATH`, `--model-path PATH`, `--language CODE`, `--action start|stop|process`

**Exit codes:** 0=success, 1=sox error, 2=ffmpeg error, 3=whisper error, 4=file write error, 5=validation error

### MCP Server (`mcp/meeting_recorder_mcp.py`)

Two tools via FastMCP v3:

- **`start_recording(source, output_path, meeting_name)`** — Launches the app (or pipeline), writes session registry, returns immediately.
- **`get_transcript(output_path)`** — Checks sentinel files, returns transcript when ready. Falls back to session registry if no path given.

### SwiftUI Menu Bar App (`app/MeetingRecorder/`)

Native macOS menu bar app (macOS 14+):
- **Idle:** Gray mic icon, popover with source picker and start button
- **Recording:** Red pulsing dot, click to stop
- **Processing:** Brick animation, shows current step
- URL scheme: `meetingrecorder://start?source=mic&output=/path/to/file.md`

### Claude Code Skill (`.claude/skills/meeting-recorder/SKILL.md`)

Agent instructions for intent parsing, source selection, and Obsidian note creation with full frontmatter.

## Sentinel File Contract

All components communicate state through filesystem sentinels:

| File | Content | Meaning |
|------|---------|---------|
| `{output}.pid` | `{pid}:{timestamp}` | sox is recording |
| `{output}.recording` | JSON (session_id, source, start_time) | Recording active |
| `{output}.processing` | Step name string | Processing in progress |
| `{output}.done` | Empty | Transcript ready |
| `{output}.error` | JSON (step, exit_code, stderr) | Pipeline failed |

## Testing

```bash
bash pipeline/test-pipeline.sh
```

Runs argument validation, sentinel file, and error path tests. Full integration tests require macOS with sox/ffmpeg/whisper-cpp installed.

## File Structure

```
meeting-recorder/
├── .mcp.json                              # MCP server config
├── .claude/skills/meeting-recorder/
│   └── SKILL.md                           # Claude Code skill
├── pipeline/
│   ├── meeting-pipeline.sh                # CLI pipeline
│   ├── config.example.json                # Example config
│   └── test-pipeline.sh                   # Test suite
├── mcp/
│   ├── meeting_recorder_mcp.py            # FastMCP v3 server
│   └── requirements.txt                   # Python deps
└── app/MeetingRecorder/                   # SwiftUI menu bar app
    ├── MeetingRecorderApp.swift
    ├── AppDelegate.swift
    ├── AppState.swift
    ├── PipelineRunner.swift
    ├── MenuBarView.swift
    ├── BrickAnimation.swift
    ├── NotificationManager.swift
    ├── ConfigManager.swift
    ├── PreflightChecker.swift
    └── Info.plist
```
