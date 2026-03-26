# Meeting Recorder: Parallel Subagent Implementation Plan

## Context

The meeting-recorder repo contains two detailed plan documents (`docs/plans/` and `docs/plan/`) specifying a 4-phase meeting recording and transcription system for macOS. No code exists yet — only plans. The goal is to implement all phases simultaneously using parallel subagent armies, each in an isolated worktree, to maximize throughput with zero merge conflicts.

**Key insight:** All inter-phase dependencies (sentinel file contract, config format, tool signatures, argument interface) are already fully specified in the plan docs. Every agent gets the same spec, so all 4 phases can be built in parallel.

---

## Wave 1: All Production Code (5 Parallel Agents)

All agents use `isolation: "worktree"`. File ownership is completely disjoint — zero merge conflicts guaranteed.

### Agent 1: CLI Pipeline
**Files:** `pipeline/meeting-pipeline.sh`, `pipeline/config.example.json`, `pipeline/test-pipeline.sh`

- [x] Full bash script (~300-400 LOC) with `set -euo pipefail`
- [x] Argument parsing: `--source mic|system|both`, `--output`, `--model-path`, `--language`, `--action start|stop|process`
- [x] Config loading from `~/.config/meeting-recorder/config.json`
- [x] `start`: validate prereqs, create `/tmp/meeting-recorder/{session-id}/`, start sox, write `.pid` (format: `{pid}:{timestamp}`), write `.recording` (JSON)
- [x] `stop`: validate PID + timestamp, SIGINT sox, 10s timeout then SIGKILL, write `.processing`
- [x] `process`: ffmpeg 16kHz mono, whisper-cpp with Metal path, move transcript, write `.done`, cleanup
- [x] `--source both`: dual sox processes, merge with `sox -m`
- [x] Error handling: `.error` sentinel as JSON `{step, exit_code, stderr}`. Exit codes 0-5
- [x] Cleanup: `.done` deletes `.pid/.recording/.processing`; `.error` deletes `.pid/.processing` but keeps `.recording`
- [x] `config.example.json`: micDevice, systemDevice, whisperModelPath, language, defaultOutputDir, defaultSource
- [x] `test-pipeline.sh`: E2E test script (documents flow, detects missing tools gracefully)

### Agent 2: MCP Server
**Files:** `mcp/meeting_recorder_mcp.py`, `mcp/requirements.txt`, `.mcp.json`

- [x] FastMCP v3: `from fastmcp import FastMCP`, `from fastmcp.exceptions import ToolError`
- [x] `start_recording(source="mic", output_path=None, meeting_name=None)` — generates path from config+timestamp+sanitized name, checks `.recording` sentinel, launches pipeline via `subprocess.Popen`, writes session registry to `~/.config/meeting-recorder/current-session.json`
- [x] `get_transcript(output_path=None)` — falls back to session registry, checks sentinels in priority: `.error` → `.done` → `.processing` → `.recording`, raises `ToolError` if nothing found
- [x] Helpers: `_read_config()`, `_sanitize_filename()` (non-alphanumeric except `-_` → hyphens, truncate 64 chars)
- [x] `PIPELINE_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "pipeline", "meeting-pipeline.sh")`
- [x] `requirements.txt`: `fastmcp>=3.0.0`
- [x] `.mcp.json`: stdio transport pointing to `mcp/meeting_recorder_mcp.py`

### Agent 3: SwiftUI App — Core Logic
**Files:** `app/MeetingRecorder/MeetingRecorderApp.swift`, `AppDelegate.swift`, `AppState.swift`, `PipelineRunner.swift`, `ConfigManager.swift`, `PreflightChecker.swift`, `Info.plist`

- [x] `MeetingRecorderApp.swift`: `@main`, `@NSApplicationDelegateAdaptor`, `MenuBarExtra` with `.menuBarExtraStyle(.window)`
- [x] `AppDelegate.swift`: `application(_:open urls:)` for `meetingrecorder://` URL scheme (NOT `.onOpenURL`)
- [x] `AppState.swift`: `ObservableObject`, `RecordingState` enum (idle, recording, processing, error), state machine transitions, "already recording" rejection
- [x] `PipelineRunner.swift`: wraps `Process` calls to `meeting-pipeline.sh` for start/stop/process
- [x] `ConfigManager.swift`: reads `~/.config/meeting-recorder/config.json`
- [x] `PreflightChecker.swift`: mic permission, device availability, disk space
- [x] `Info.plist`: `LSUIElement=YES`, URL scheme `meetingrecorder://`, macOS 14+

### Agent 4: SwiftUI App — UI Layer
**Files:** `app/MeetingRecorder/MenuBarView.swift`, `BrickAnimation.swift`, `NotificationManager.swift`

- [x] `MenuBarView.swift`: popover content switching on `AppState.state` — idle (start button, source picker, quit), recording (elapsed time, stop button), processing (current step text)
- [x] `BrickAnimation.swift`: programmatic Canvas/Path animation, 12-16 frames at 18x18pt, 0.25s interval Timer, `isTemplate=true` for light/dark. Sequence: pyramid build → collapse → rectangle → collapse → loop
- [x] `NotificationManager.swift`: wraps `UNUserNotificationCenter`, methods for recordingStarted/transcriptReady/error
- [x] **Interface contract:** consumes `AppState` and `RecordingState` enum from Agent 3

### Agent 5: Claude Code Skill
**Files:** `.claude/skills/meeting-recorder/SKILL.md`

- [x] YAML frontmatter: name, description (recording/transcript keywords), argument-hint, allowed-tools
- [x] Source selection heuristics: mic (in-person/standup), system (Teams/Zoom/remote), both (hybrid), default mic
- [x] Start workflow: call `start_recording`, don't poll, confirm to user
- [x] Retrieve workflow: call `get_transcript`, handle all 4 statuses
- [x] Post-processing: 3-5 bullet summary, action items with owners, key decisions
- [x] Full Obsidian frontmatter: type, created, updated, workstreams, status, tags, meeting-type, attendees, recurring, source
- [x] Write via Obsidian MCP to `20-meetings/`

---

## Merge Sequence (Between Waves)

- [x] Merge all 5 worktree branches — file sets are disjoint, order doesn't matter
- [x] Verify no conflicts

---

## Wave 2: Integration Verification (1-2 Agents)

### Agent 6: Consistency Check
- [x] Verify `.mcp.json` path references are correct
- [x] Verify sentinel file names match exactly between pipeline ↔ MCP server ↔ SwiftUI app
- [x] Verify config JSON field names are consistent across all components
- [x] Verify pipeline argument format matches what PipelineRunner.swift and MCP server use
- [x] Verify skill file references correct MCP tool names and parameters
- [x] Fix any inconsistencies (8 found and fixed)

### Agent 7 (Optional): README
- [ ] Project overview, architecture, prerequisites, installation, usage, file structure

---

## Verification

- [ ] `shellcheck pipeline/meeting-pipeline.sh` — lint the bash script
- [x] `python -c "import ast; ast.parse(open('mcp/meeting_recorder_mcp.py').read())"` — verify Python syntax
- [x] Verify all files from the planned file structure exist
- [x] Verify `.mcp.json` is valid JSON
- [x] Read through skill file for completeness against spec
- [x] Git status clean, all files committed and pushed

---

## Remaining Gaps (from plan audit)

Items specified in the original plan docs that are not yet fully implemented:

### Critical (functional gaps)

- [ ] **NotificationManager is dead code** — `NotificationManager` class exists but is never called from `AppState`. Recording-started, transcript-ready, and error notifications are never actually sent. Need to wire `NotificationManager.shared` calls into `AppState.startRecording()`, `handleProcessingComplete()`, and `handleError()`. Also need to call `requestAuthorization()` on app launch (in `AppDelegate.applicationDidFinishLaunching`).

- [ ] **MCP server does not launch SwiftUI app** — The plan's Phase 3 checklist says "Update MCP server to launch app via URL scheme instead of pipeline directly." Currently the MCP server calls the pipeline script directly via `subprocess.Popen`, bypassing the SwiftUI app entirely. The app and MCP are disconnected — using MCP tools won't trigger menu bar UI, notifications, or state machine. Need to add a code path that launches `open meetingrecorder://start?source=...&output=...` when the app is installed.

- [ ] **Elapsed time display does not update live** — `MenuBarView.recordingView` shows `appState.elapsedTime` but nothing triggers SwiftUI redraws on a timer. Need a `Timer` publisher or `TimelineView` to drive periodic updates during recording state.

### Minor (UX/polish)

- [ ] **No hover tooltip on menu bar icon during PROCESSING** — Plan specifies: "Hover tooltip on the menu bar icon: shows the current step as a one-liner (use `.help()` modifier or NSStatusItem button toolTip)." Not implemented on `BrickAnimationMenuBarIcon`.

- [ ] **PreflightChecker doesn't verify BlackHole specifically** — For `--source system`, the check just verifies *any* audio device exists, not specifically "BlackHole 2ch". For `--source both`, only mic devices are checked, not system devices separately.

- [ ] **Test error paths incomplete** — Plan checklist: "Test error paths: kill sox mid-record, feed corrupt audio to ffmpeg, verify .error sentinel." Current tests cover stale PID and missing files but not these specific scenarios (requires macOS with sox/ffmpeg installed).

- [ ] **Output path naming inconsistency** — Three different default filename formats across MCP server (`2026-03-25T14-30-standup.md`), AppState (`meeting_2026-03-25_143000.md`), and MenuBarView (`2026-03-25T14-30-meeting.md`). Should be unified.

### Deviations (intentional or acceptable)

- `--model` argument from original plan was simplified to just `--model-path` (reasonable)
- `.mcp.json` uses relative path instead of absolute (more portable)
- Error state added to RecordingState enum (enhancement beyond spec)
- Auto-recovery from error state after 5 seconds (addition, not in spec)
- `stop` action merges dual-stream audio instead of `process` (arguably better)
