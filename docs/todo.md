# Meeting Recorder: Parallel Subagent Implementation Plan

## Context

The meeting-recorder repo contains two detailed plan documents (`docs/plans/` and `docs/plan/`) specifying a 4-phase meeting recording and transcription system for macOS. No code exists yet — only plans. The goal is to implement all phases simultaneously using parallel subagent armies, each in an isolated worktree, to maximize throughput with zero merge conflicts.

**Key insight:** All inter-phase dependencies (sentinel file contract, config format, tool signatures, argument interface) are already fully specified in the plan docs. Every agent gets the same spec, so all 4 phases can be built in parallel.

---

## Wave 1: All Production Code (5 Parallel Agents)

All agents use `isolation: "worktree"`. File ownership is completely disjoint — zero merge conflicts guaranteed.

### Agent 1: CLI Pipeline
**Files:** `pipeline/meeting-pipeline.sh`, `pipeline/config.example.json`, `pipeline/test-pipeline.sh`

- [ ] Full bash script (~300-400 LOC) with `set -euo pipefail`
- [ ] Argument parsing: `--source mic|system|both`, `--output`, `--model-path`, `--language`, `--action start|stop|process`
- [ ] Config loading from `~/.config/meeting-recorder/config.json`
- [ ] `start`: validate prereqs, create `/tmp/meeting-recorder/{session-id}/`, start sox, write `.pid` (format: `{pid}:{timestamp}`), write `.recording` (JSON)
- [ ] `stop`: validate PID + timestamp, SIGINT sox, 10s timeout then SIGKILL, write `.processing`
- [ ] `process`: ffmpeg 16kHz mono, whisper-cpp with Metal path, move transcript, write `.done`, cleanup
- [ ] `--source both`: dual sox processes, merge with `sox -m`
- [ ] Error handling: `.error` sentinel as JSON `{step, exit_code, stderr}`. Exit codes 0-5
- [ ] Cleanup: `.done` deletes `.pid/.recording/.processing`; `.error` deletes `.pid/.processing` but keeps `.recording`
- [ ] `config.example.json`: micDevice, systemDevice, whisperModelPath, language, defaultOutputDir, defaultSource
- [ ] `test-pipeline.sh`: E2E test script (documents flow, detects missing tools gracefully)

### Agent 2: MCP Server
**Files:** `mcp/meeting_recorder_mcp.py`, `mcp/requirements.txt`, `.mcp.json`

- [ ] FastMCP v3: `from fastmcp import FastMCP`, `from fastmcp.exceptions import ToolError`
- [ ] `start_recording(source="mic", output_path=None, meeting_name=None)` — generates path from config+timestamp+sanitized name, checks `.recording` sentinel, launches pipeline via `subprocess.Popen`, writes session registry to `~/.config/meeting-recorder/current-session.json`
- [ ] `get_transcript(output_path=None)` — falls back to session registry, checks sentinels in priority: `.error` → `.done` → `.processing` → `.recording`, raises `ToolError` if nothing found
- [ ] Helpers: `_read_config()`, `_sanitize_filename()` (non-alphanumeric except `-_` → hyphens, truncate 64 chars)
- [ ] `PIPELINE_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "pipeline", "meeting-pipeline.sh")`
- [ ] `requirements.txt`: `fastmcp>=3.0.0`
- [ ] `.mcp.json`: stdio transport pointing to `mcp/meeting_recorder_mcp.py`

### Agent 3: SwiftUI App — Core Logic
**Files:** `app/MeetingRecorder/MeetingRecorderApp.swift`, `AppDelegate.swift`, `AppState.swift`, `PipelineRunner.swift`, `ConfigManager.swift`, `PreflightChecker.swift`, `Info.plist`

- [ ] `MeetingRecorderApp.swift`: `@main`, `@NSApplicationDelegateAdaptor`, `MenuBarExtra` with `.menuBarExtraStyle(.window)`
- [ ] `AppDelegate.swift`: `application(_:open urls:)` for `meetingrecorder://` URL scheme (NOT `.onOpenURL`)
- [ ] `AppState.swift`: `ObservableObject`, `RecordingState` enum (idle, recording, processing, error), state machine transitions, "already recording" rejection
- [ ] `PipelineRunner.swift`: wraps `Process` calls to `meeting-pipeline.sh` for start/stop/process
- [ ] `ConfigManager.swift`: reads `~/.config/meeting-recorder/config.json`
- [ ] `PreflightChecker.swift`: mic permission, device availability, disk space
- [ ] `Info.plist`: `LSUIElement=YES`, URL scheme `meetingrecorder://`, macOS 14+

### Agent 4: SwiftUI App — UI Layer
**Files:** `app/MeetingRecorder/MenuBarView.swift`, `BrickAnimation.swift`, `NotificationManager.swift`

- [ ] `MenuBarView.swift`: popover content switching on `AppState.state` — idle (start button, source picker, quit), recording (elapsed time, stop button), processing (current step text)
- [ ] `BrickAnimation.swift`: programmatic Canvas/Path animation, 12-16 frames at 18x18pt, 0.25s interval Timer, `isTemplate=true` for light/dark. Sequence: pyramid build → collapse → rectangle → collapse → loop
- [ ] `NotificationManager.swift`: wraps `UNUserNotificationCenter`, methods for recordingStarted/transcriptReady/error
- [ ] **Interface contract:** consumes `AppState` and `RecordingState` enum from Agent 3

### Agent 5: Claude Code Skill
**Files:** `.claude/skills/meeting-recorder/SKILL.md`

- [ ] YAML frontmatter: name, description (recording/transcript keywords), argument-hint, allowed-tools
- [ ] Source selection heuristics: mic (in-person/standup), system (Teams/Zoom/remote), both (hybrid), default mic
- [ ] Start workflow: call `start_recording`, don't poll, confirm to user
- [ ] Retrieve workflow: call `get_transcript`, handle all 4 statuses
- [ ] Post-processing: 3-5 bullet summary, action items with owners, key decisions
- [ ] Full Obsidian frontmatter: type, created, updated, workstreams, status, tags, meeting-type, attendees, recurring, source
- [ ] Write via Obsidian MCP to `20-meetings/`

---

## Merge Sequence (Between Waves)

- [ ] Merge all 5 worktree branches — file sets are disjoint, order doesn't matter
- [ ] Verify no conflicts

---

## Wave 2: Integration Verification (1-2 Agents)

### Agent 6: Consistency Check
- [ ] Verify `.mcp.json` path references are correct
- [ ] Verify sentinel file names match exactly between pipeline ↔ MCP server ↔ SwiftUI app
- [ ] Verify config JSON field names are consistent across all components
- [ ] Verify pipeline argument format matches what PipelineRunner.swift and MCP server use
- [ ] Verify skill file references correct MCP tool names and parameters
- [ ] Fix any inconsistencies

### Agent 7 (Optional): README
- [ ] Project overview, architecture, prerequisites, installation, usage, file structure

---

## Shared Contracts (Given to All Wave 1 Agents)

### Sentinel Files
| File | Content | Written by |
|------|---------|-----------|
| `{output}.pid` | `{pid}:{start_timestamp}` | Pipeline start |
| `{output}.recording` | JSON: `{session_id, source, start_time}` | Pipeline start |
| `{output}.processing` | Current step name string | Pipeline stop/process |
| `{output}.done` | Empty or hash | Pipeline process |
| `{output}.error` | JSON: `{step, exit_code, stderr}` | Pipeline on failure |

### Config JSON (`~/.config/meeting-recorder/config.json`)
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

### Pipeline Arguments
`meeting-pipeline.sh --source mic|system|both --output /path/to/file.md --model-path /path/to/model --language en --action start|stop|process`

---

## Verification

- [ ] `shellcheck pipeline/meeting-pipeline.sh` — lint the bash script
- [ ] `python -c "import ast; ast.parse(open('mcp/meeting_recorder_mcp.py').read())"` — verify Python syntax
- [ ] Verify all files from the planned file structure exist
- [ ] Verify `.mcp.json` is valid JSON
- [ ] Read through skill file for completeness against spec
- [ ] Git status clean, all files committed and pushed
