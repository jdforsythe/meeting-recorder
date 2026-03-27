# macOS Testing Playbook

Step-by-step guide to test every component of the meeting recorder system on macOS.

---

## Prerequisites

### 1. Install dependencies

```bash
brew install sox ffmpeg whisper-cpp blackhole-2ch
```

Verify:
```bash
sox --version
ffmpeg -version
whisper-cpp --help
```

### 2. Download whisper model

```bash
mkdir -p ~/models
curl -L -o ~/models/ggml-large-v3-turbo-q5_0.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true"
```

### 3. Set up Audio MIDI (for system audio capture)

1. Open **Audio MIDI Setup** (Spotlight → "Audio MIDI Setup")
2. Click **+** → **Create Multi-Output Device**
3. Check **Built-in Output** (must be first — this is the clock source)
4. Check **BlackHole 2ch** (enable **Drift Correction**)
5. Rename to "Meeting Recorder Output" (optional)
6. Set this Multi-Output Device as your system output (System Settings → Sound → Output)

### 4. Create config file

```bash
mkdir -p ~/.config/meeting-recorder
cat > ~/.config/meeting-recorder/config.json << 'EOF'
{
  "micDevice": "MacBook Pro Microphone",
  "systemDevice": "BlackHole 2ch",
  "whisperModelPath": "~/models/ggml-large-v3-turbo-q5_0.bin",
  "language": "en",
  "defaultOutputDir": "~/Documents/meeting-transcripts/",
  "defaultSource": "mic"
}
EOF
```

> **Note:** Run `sox -V6 -n -t coreaudio junk 2>&1 | grep "Device"` to find your exact mic device name. Update `micDevice` if it differs.

### 5. Set up Metal acceleration

Add to `~/.zshrc`:
```bash
export GGML_METAL_PATH_RESOURCES="$(brew --prefix whisper-cpp)/share/whisper-cpp"
```

Then `source ~/.zshrc`.

---

## Phase 1: CLI Pipeline Tests

### Test 1A: Automated test suite

```bash
cd /path/to/meeting-recorder
bash pipeline/test-pipeline.sh
```

**Expected:** All tests pass. The integration test (test 11) should now run instead of being skipped.

### Test 1B: Manual mic recording (10 seconds)

```bash
# Start recording
./pipeline/meeting-pipeline.sh --source mic --output /tmp/test-meeting.md --action start

# Verify sentinel files were created
cat /tmp/test-meeting.md.pid          # Should show {pid}:{timestamp}
cat /tmp/test-meeting.md.recording    # Should show JSON with session_id, source, start_time
ls /tmp/meeting-recorder/             # Should show session directory

# Wait 10 seconds, speak into mic
sleep 10

# Stop recording
./pipeline/meeting-pipeline.sh --output /tmp/test-meeting.md --action stop

# Verify stop sentinels
cat /tmp/test-meeting.md.processing   # Should say "audio_stopped"
test ! -f /tmp/test-meeting.md.pid && echo "PASS: .pid removed" || echo "FAIL: .pid still exists"

# Process
./pipeline/meeting-pipeline.sh --output /tmp/test-meeting.md --action process

# Verify output
cat /tmp/test-meeting.md              # Should contain transcript of what you said
test -f /tmp/test-meeting.md.done && echo "PASS: .done exists" || echo "FAIL: .done missing"
test ! -f /tmp/test-meeting.md.recording && echo "PASS: .recording cleaned" || echo "FAIL: .recording still exists"
test ! -f /tmp/test-meeting.md.processing && echo "PASS: .processing cleaned" || echo "FAIL: .processing still exists"
```

**Expected:** Transcript of your spoken words in `/tmp/test-meeting.md`.

### Test 1C: System audio recording

Play any audio (e.g., a YouTube video) during this test.

```bash
./pipeline/meeting-pipeline.sh --source system --output /tmp/test-system.md --action start
sleep 10
./pipeline/meeting-pipeline.sh --output /tmp/test-system.md --action stop
./pipeline/meeting-pipeline.sh --output /tmp/test-system.md --action process
cat /tmp/test-system.md
```

**Expected:** Transcript of whatever audio was playing through your system.

> If this fails with a device error, verify BlackHole is set up (step 3) and `systemDevice` in config matches.

### Test 1D: Dual-source recording (both)

```bash
./pipeline/meeting-pipeline.sh --source both --output /tmp/test-both.md --action start
cat /tmp/test-both.md.pid            # Should show TWO lines (mic PID + system PID)
sleep 10
./pipeline/meeting-pipeline.sh --output /tmp/test-both.md --action stop
./pipeline/meeting-pipeline.sh --output /tmp/test-both.md --action process
cat /tmp/test-both.md
```

**Expected:** Transcript capturing both mic and system audio.

### Test 1E: Error path — kill sox mid-record

```bash
./pipeline/meeting-pipeline.sh --source mic --output /tmp/test-kill.md --action start

# Read the PID and kill sox
PID=$(cut -d: -f1 /tmp/test-kill.md.pid)
kill -9 $PID

# Try to stop — should detect stale PID
./pipeline/meeting-pipeline.sh --output /tmp/test-kill.md --action stop
echo "Exit code: $?"                  # Should be 1

# Verify error sentinel
cat /tmp/test-kill.md.error           # Should be JSON with step, exit_code, stderr
test -f /tmp/test-kill.md.recording && echo "PASS: .recording kept for debugging" || echo "FAIL"
test ! -f /tmp/test-kill.md.pid && echo "PASS: .pid cleaned up" || echo "FAIL"
```

### Test 1F: Error path — corrupt audio to ffmpeg

```bash
# Create a fake session
SESSION_ID="test-corrupt-$(date +%s)"
mkdir -p "/tmp/meeting-recorder/${SESSION_ID}"
echo "this is not audio data" > "/tmp/meeting-recorder/${SESSION_ID}/raw.wav"
echo "{\"session_id\":\"${SESSION_ID}\",\"source\":\"mic\",\"start_time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > /tmp/test-corrupt.md.recording

./pipeline/meeting-pipeline.sh --output /tmp/test-corrupt.md --action process
echo "Exit code: $?"                  # Should be 2 (ffmpeg error)

cat /tmp/test-corrupt.md.error        # Should show step "converting_audio" or similar
test -f /tmp/test-corrupt.md.recording && echo "PASS: .recording preserved" || echo "FAIL"
```

---

## Phase 2: MCP Server Tests

### Test 2A: Python syntax and imports

```bash
cd /path/to/meeting-recorder
pip install fastmcp>=3.0.0
python3 -c "import mcp.meeting_recorder_mcp; print('Import OK')"
```

### Test 2B: Start recording via MCP (from Claude Code)

Open Claude Code in the meeting-recorder project directory and say:

> "Record my standup"

**Expected:**
1. Claude calls `start_recording` MCP tool
2. Returns `{status: "recording_started", output_path: "...", source: "mic"}`
3. If the SwiftUI app is NOT built yet, the pipeline script runs directly
4. A `.recording` sentinel appears at the output path
5. Session registry written to `~/.config/meeting-recorder/current-session.json`

### Test 2C: Get transcript via MCP

After stopping the recording (either via pipeline CLI or the app):

> "Grab the transcript"

**Expected:**
1. Claude calls `get_transcript` (no output_path — uses session registry)
2. Returns `{status: "ready", transcript: "..."}` if done
3. Returns `{status: "recording"}` if still recording
4. Returns `{status: "processing", current_step: "..."}` if processing

### Test 2D: Test all sentinel statuses

```bash
OUTPUT=~/Documents/meeting-transcripts/test-statuses.md

# Test "recording" status
echo '{"session_id":"test","source":"mic","start_time":"now"}' > "${OUTPUT}.recording"
# Call get_transcript from Claude Code — should return status "recording"

# Test "processing" status
rm "${OUTPUT}.recording"
echo "transcribing" > "${OUTPUT}.processing"
# Call get_transcript — should return status "processing"

# Test "error" status
rm "${OUTPUT}.processing"
echo '{"step":"whisper","exit_code":3,"stderr":"model not found"}' > "${OUTPUT}.error"
# Call get_transcript — should return status "error"

# Test "ready" status
rm "${OUTPUT}.error"
echo "This is a test transcript." > "${OUTPUT}"
touch "${OUTPUT}.done"
# Call get_transcript — should return status "ready" with transcript text

# Cleanup
rm -f "${OUTPUT}" "${OUTPUT}.done" "${OUTPUT}.recording" "${OUTPUT}.processing" "${OUTPUT}.error"
```

---

## Phase 3: SwiftUI App Tests

### Build the app

```bash
cd /path/to/meeting-recorder/app
# Create Xcode project (or open existing one)
# Add all .swift files from MeetingRecorder/
# Set Info.plist settings
# Build and run
```

> **Note:** The app needs an Xcode project wrapper. The Swift source files are ready but there's no `.xcodeproj` yet. Create one in Xcode: File → New → Project → macOS → App → SwiftUI, then add all files from `app/MeetingRecorder/`.

### Test 3A: App appears in menu bar

1. Launch MeetingRecorder.app
2. **Verify:** Gray mic icon appears in menu bar
3. **Verify:** App does NOT appear in Dock or Cmd-Tab (LSUIElement)
4. Click the icon — popover should show:
   - "Meeting Recorder" title
   - Source picker (Microphone / System Audio / Both)
   - "Start Recording" button
   - "Quit" button

### Test 3B: Recording lifecycle

1. Click "Start Recording"
2. **Verify:** Menu bar icon changes to red pulsing dot
3. **Verify:** macOS notification: "Meeting Recorder — Recording started"
4. **Verify:** Popover shows elapsed time (MM:SS) counting up live
5. Speak for 10 seconds
6. Click the red dot to stop
7. **Verify:** Menu bar icon changes to brick animation
8. **Verify:** Popover shows "Processing audio..." with current step
9. **Verify:** Brick animation tooltip shows current step on hover
10. Wait for processing to complete
11. **Verify:** macOS notification: "Meeting Recorder — Transcript ready: {filename}"
12. **Verify:** Menu bar icon returns to gray mic
13. **Verify:** "Last Recording" info shows in popover (timestamp, duration, path)

### Test 3C: URL scheme

```bash
# From Terminal, trigger a recording via URL scheme
open "meetingrecorder://start?source=mic&output=%2Ftmp%2Furl-test.md"
```

**Verify:** App starts recording (red pulsing dot appears).

```bash
# Try starting while already recording — should be rejected
open "meetingrecorder://start?source=system&output=%2Ftmp%2Furl-test2.md"
```

**Verify:** Nothing changes. First recording continues.

```bash
# Stop via URL scheme
open "meetingrecorder://stop"
```

**Verify:** Recording stops, processing begins.

### Test 3D: Error handling

1. Remove sox temporarily: `brew unlink sox`
2. Try to start recording
3. **Verify:** Error state shown (warning icon in menu bar, error message in popover)
4. **Verify:** macOS notification with error message
5. **Verify:** Auto-recovers to idle after 5 seconds
6. Restore sox: `brew link sox`

### Test 3E: Source picker

1. Select "System Audio" in source picker
2. Start recording while playing audio
3. Stop and process
4. **Verify:** Transcript contains system audio content

Repeat with "Both" to test dual-source.

---

## Phase 4: Skill + Full Loop Test

### Test 4A: End-to-end with Claude Code

This is the ultimate acceptance test.

1. Open Claude Code in the meeting-recorder project
2. Say: **"Record my standup"**
3. **Verify:** Claude calls `start_recording(source="mic")`, tells you recording started
4. Have a brief "meeting" — speak for 30 seconds about some topics with action items
5. Return to Claude Code and say: **"Grab the transcript"**
6. **Verify:** Claude calls `get_transcript`, receives transcript
7. **Verify:** Claude summarizes in 3-5 bullets, extracts action items, extracts decisions
8. If Obsidian MCP is configured: **Verify** note appears in `20-meetings/` with full frontmatter

### Test 4B: Source selection heuristics

Test these prompts and verify Claude picks the right source:

| Prompt | Expected source |
|--------|----------------|
| "Record my standup" | `mic` |
| "Record my Zoom call" | `system` |
| "Record this Teams meeting" | `system` |
| "Record the conference room meeting, some folks are remote" | `both` |
| "Record this" | `mic` (default) |

### Test 4C: Status handling

1. Start a recording via Claude: "Record my meeting"
2. Immediately ask: "Get the transcript"
3. **Verify:** Claude reports "Still recording, stop it first"
4. Stop recording in menu bar
5. Immediately ask: "Get the transcript"
6. **Verify:** Claude reports "Processing, try again in 30 seconds"
7. Wait for processing, then ask again
8. **Verify:** Claude receives and summarizes transcript

### Test 4D: Cross-conversation session recovery

1. In one Claude Code session: "Record my sync"
2. Close that Claude Code session
3. Open a new Claude Code session: "Grab my transcript"
4. **Verify:** Claude finds the session via `~/.config/meeting-recorder/current-session.json`

---

## Phase 5: Integration (MCP + App)

### Test 5A: MCP launches app via URL scheme

1. Build and install MeetingRecorder.app (copy to /Applications or ~/Applications)
2. Open Claude Code and say: "Record my standup"
3. **Verify:** The MCP server detects the app and launches via URL scheme
4. **Verify:** The menu bar app shows the red recording dot
5. **Verify:** Stop/process/done flow works through the app UI

### Test 5B: MCP falls back to pipeline

1. Quit MeetingRecorder.app (or move it out of /Applications)
2. Open Claude Code and say: "Record my meeting"
3. **Verify:** MCP falls back to launching pipeline directly
4. **Verify:** Recording starts (check `.recording` sentinel)
5. Stop manually: `./pipeline/meeting-pipeline.sh --output <path> --action stop`
6. Process manually: `./pipeline/meeting-pipeline.sh --output <path> --action process`
7. Ask Claude: "Get the transcript"
8. **Verify:** Transcript returned

---

## Checklist Summary

```
Phase 1: CLI Pipeline
  [ ] 1A  Automated test suite passes (all tests, no skips)
  [ ] 1B  Manual mic recording produces transcript
  [ ] 1C  System audio recording produces transcript
  [ ] 1D  Dual-source (both) recording works
  [ ] 1E  Kill sox mid-record → .error sentinel correct
  [ ] 1F  Corrupt audio → ffmpeg error sentinel correct

Phase 2: MCP Server
  [ ] 2A  Python imports successfully
  [ ] 2B  start_recording via Claude Code works
  [ ] 2C  get_transcript via Claude Code works
  [ ] 2D  All sentinel statuses handled correctly

Phase 3: SwiftUI App
  [ ] 3A  App appears in menu bar (no Dock/Cmd-Tab)
  [ ] 3B  Full recording lifecycle (start → record → stop → process → done)
  [ ] 3C  URL scheme starts/stops recording
  [ ] 3D  Error handling and recovery
  [ ] 3E  All three source types work

Phase 4: Skill + Full Loop
  [ ] 4A  End-to-end: "Record standup" → meeting → "Grab transcript" → Obsidian note
  [ ] 4B  Source selection heuristics match expected values
  [ ] 4C  All transcript statuses handled (recording/processing/ready/error)
  [ ] 4D  Cross-conversation session recovery works

Phase 5: Integration
  [ ] 5A  MCP launches app via URL scheme when installed
  [ ] 5B  MCP falls back to pipeline when app not installed
```
