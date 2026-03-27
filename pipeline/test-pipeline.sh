#!/usr/bin/env bash
set -euo pipefail

# test-pipeline.sh — End-to-end tests for meeting-pipeline.sh
# Handles missing macOS-specific tools (sox, whisper-cpp) gracefully on Linux.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="${SCRIPT_DIR}/meeting-pipeline.sh"
TEST_DIR="/tmp/meeting-recorder-tests"
PASS=0
FAIL=0
SKIP=0

# --- Helpers ---

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
    # Clean up any session dirs created during tests
    rm -rf /tmp/meeting-recorder/
}

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
}

skip() {
    SKIP=$((SKIP + 1))
    echo "  SKIP: $1"
}

has_tool() {
    command -v "$1" &>/dev/null
}

# --- Test: Argument validation ---

test_missing_action() {
    echo "[test] Missing --action should exit with code 5"
    local exit_code=0
    "$PIPELINE" --source mic --output "${TEST_DIR}/out.md" 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 5 ]]; then
        pass "Missing --action exits 5"
    else
        fail "Missing --action exited $exit_code (expected 5)"
    fi
}

test_missing_output() {
    echo "[test] Missing --output should exit with code 5"
    local exit_code=0
    "$PIPELINE" --action start --source mic 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 5 ]]; then
        pass "Missing --output exits 5"
    else
        fail "Missing --output exited $exit_code (expected 5)"
    fi
}

test_invalid_action() {
    echo "[test] Invalid --action value should exit with code 5"
    local exit_code=0
    "$PIPELINE" --action bogus --source mic --output "${TEST_DIR}/out.md" 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 5 ]]; then
        pass "Invalid --action exits 5"
    else
        fail "Invalid --action exited $exit_code (expected 5)"
    fi
}

test_unknown_argument() {
    echo "[test] Unknown argument should exit with code 5"
    local exit_code=0
    "$PIPELINE" --action start --source mic --output "${TEST_DIR}/out.md" --bogus-flag 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 5 ]]; then
        pass "Unknown argument exits 5"
    else
        fail "Unknown argument exited $exit_code (expected 5)"
    fi
}

test_invalid_source() {
    echo "[test] Invalid --source value should exit with code 5"
    # This test only makes sense if sox is available (otherwise it fails on prerequisite first)
    if ! has_tool sox; then
        skip "Invalid source test requires sox"
        return
    fi
    local exit_code=0
    "$PIPELINE" --action start --source badvalue --output "${TEST_DIR}/out.md" 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 5 ]]; then
        pass "Invalid --source exits 5"
    else
        fail "Invalid --source exited $exit_code (expected 5)"
    fi
}

# --- Test: Prerequisite validation ---

test_missing_sox() {
    echo "[test] Missing sox should produce .error sentinel and exit 5"
    if has_tool sox; then
        skip "sox is installed, cannot test missing-sox path"
        return
    fi
    local output="${TEST_DIR}/missing-sox.md"
    local exit_code=0
    "$PIPELINE" --action start --source mic --output "$output" 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 5 ]]; then
        pass "Missing sox exits 5"
    else
        fail "Missing sox exited $exit_code (expected 5)"
    fi
    if [[ -f "${output}.error" ]]; then
        pass "Missing sox creates .error sentinel"
        # Verify .error is valid JSON with expected fields
        if python3 -c "
import json, sys
with open('${output}.error') as f:
    d = json.load(f)
assert 'step' in d, 'missing step field'
assert 'exit_code' in d, 'missing exit_code field'
assert 'stderr' in d, 'missing stderr field'
assert 'sox' in d['stderr'].lower(), 'stderr should mention sox'
" 2>/dev/null; then
            pass ".error sentinel has valid JSON with expected fields"
        else
            fail ".error sentinel JSON validation failed"
        fi
    else
        fail "Missing sox did not create .error sentinel"
    fi
}

# --- Test: Sentinel file contract ---

test_sentinel_files_on_stop_no_pid() {
    echo "[test] --action stop without .pid file should create .error"
    local output="${TEST_DIR}/no-pid-test.md"
    local exit_code=0
    "$PIPELINE" --action stop --output "$output" 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 1 ]]; then
        pass "Stop without .pid exits 1"
    else
        fail "Stop without .pid exited $exit_code (expected 1)"
    fi
    if [[ -f "${output}.error" ]]; then
        pass "Stop without .pid creates .error sentinel"
    else
        fail "Stop without .pid did not create .error sentinel"
    fi
}

test_sentinel_files_on_process_no_recording() {
    echo "[test] --action process without .recording should create .error"
    local output="${TEST_DIR}/no-recording-test.md"
    local exit_code=0
    "$PIPELINE" --action process --source mic --output "$output" 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 4 ]]; then
        pass "Process without .recording exits 4"
    else
        fail "Process without .recording exited $exit_code (expected 4)"
    fi
    if [[ -f "${output}.error" ]]; then
        pass "Process without .recording creates .error sentinel"
    else
        fail "Process without .recording did not create .error sentinel"
    fi
}

# --- Test: Simulated start/stop/process flow with mock sentinels ---

test_stop_with_stale_pid() {
    echo "[test] --action stop with stale PID should create .error"
    local output="${TEST_DIR}/stale-pid-test.md"

    # Write a .pid file pointing to a non-existent PID
    echo "99999:2026-01-01T00:00:00Z" > "${output}.pid"

    # Write a minimal .recording sentinel (no valid session dir)
    echo '{"session_id":"test-stale-123","source":"mic","start_time":"2026-01-01T00:00:00Z"}' > "${output}.recording"

    local exit_code=0
    "$PIPELINE" --action stop --output "$output" 2>/dev/null || exit_code=$?

    if [[ $exit_code -eq 1 ]]; then
        pass "Stop with stale PID exits 1"
    else
        fail "Stop with stale PID exited $exit_code (expected 1)"
    fi

    if [[ -f "${output}.error" ]]; then
        pass "Stop with stale PID creates .error sentinel"
    else
        fail "Stop with stale PID did not create .error sentinel"
    fi

    # .pid should be cleaned up on error
    if [[ ! -f "${output}.pid" ]]; then
        pass ".pid cleaned up on error"
    else
        fail ".pid not cleaned up on error"
    fi

    # .recording should be kept for debugging
    if [[ -f "${output}.recording" ]]; then
        pass ".recording kept on error for debugging"
    else
        fail ".recording was deleted on error (should be kept)"
    fi
}

# --- Test: Process with mock audio (ffmpeg available) ---

test_process_with_mock_audio() {
    echo "[test] --action process with mock audio file (requires ffmpeg)"
    if ! has_tool ffmpeg; then
        skip "ffmpeg not installed, cannot test process action"
        return
    fi
    if ! has_tool whisper-cpp; then
        skip "whisper-cpp not installed, cannot test full process action"
        # But we can test the ffmpeg conversion step by checking it fails at whisper
        echo "  (testing partial process flow up to whisper step)"

        local output="${TEST_DIR}/mock-process.md"
        local session_id="mock-session-001"
        local session_dir="/tmp/meeting-recorder/${session_id}"
        mkdir -p "$session_dir"

        # Generate a short silent WAV file with ffmpeg
        ffmpeg -y -f lavfi -i "anullsrc=r=44100:cl=mono" -t 1 "${session_dir}/raw.wav" 2>/dev/null

        # Write .recording sentinel
        echo "{\"session_id\":\"${session_id}\",\"source\":\"mic\",\"start_time\":\"2026-01-01T00:00:00Z\"}" > "${output}.recording"

        local exit_code=0
        "$PIPELINE" --action process --source mic --output "$output" \
            --model-path "/nonexistent/model.bin" 2>/dev/null || exit_code=$?

        # Should fail at whisper step (exit code 3) since whisper-cpp is not installed
        if [[ $exit_code -eq 3 ]]; then
            pass "Process fails at whisper step with exit 3 (whisper-cpp not installed)"
        elif [[ $exit_code -eq 5 ]]; then
            # whisper-cpp binary not found during process (if pipeline rechecks)
            pass "Process fails at whisper prerequisite (exit 5)"
        else
            fail "Process exited $exit_code (expected 3 or 5)"
        fi

        # Check that 16k.wav was created (ffmpeg step succeeded)
        if [[ -f "${session_dir}/16k.wav" ]]; then
            pass "ffmpeg conversion produced 16k.wav"
        else
            fail "ffmpeg conversion did not produce 16k.wav"
        fi

        # Check that .processing was written before error
        # (may have been cleaned up by error handler, check .error instead)
        if [[ -f "${output}.error" ]]; then
            pass ".error sentinel created on whisper failure"
            local error_step
            error_step=$(python3 -c "
import json
with open('${output}.error') as f:
    print(json.load(f)['step'])
" 2>/dev/null || echo "unknown")
            if [[ "$error_step" == "transcribing" ]]; then
                pass ".error step is 'transcribing'"
            else
                fail ".error step is '$error_step' (expected 'transcribing')"
            fi
        else
            fail "No .error sentinel on whisper failure"
        fi

        # Cleanup
        rm -rf "$session_dir"
        return
    fi

    # Full process test (whisper-cpp available) — only on macOS with model
    local model_path="${HOME}/models/ggml-large-v3-turbo-q5_0.bin"
    if [[ ! -f "$model_path" ]]; then
        skip "Whisper model not found at $model_path"
        return
    fi

    local output="${TEST_DIR}/full-process.md"
    local session_id="full-session-001"
    local session_dir="/tmp/meeting-recorder/${session_id}"
    mkdir -p "$session_dir"

    # Generate a short silent WAV
    ffmpeg -y -f lavfi -i "anullsrc=r=44100:cl=mono" -t 2 "${session_dir}/raw.wav" 2>/dev/null

    # Write .recording sentinel
    echo "{\"session_id\":\"${session_id}\",\"source\":\"mic\",\"start_time\":\"2026-01-01T00:00:00Z\"}" > "${output}.recording"

    local exit_code=0
    "$PIPELINE" --action process --source mic --output "$output" \
        --model-path "$model_path" 2>/dev/null || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        pass "Full process completes successfully"
        if [[ -f "$output" ]]; then
            pass "Transcript file created at output path"
        else
            fail "Transcript file not found at output path"
        fi
        if [[ -f "${output}.done" ]]; then
            pass ".done sentinel created"
        else
            fail ".done sentinel not created"
        fi
        # Verify cleanup
        if [[ ! -f "${output}.recording" ]]; then
            pass ".recording cleaned up on success"
        else
            fail ".recording not cleaned up on success"
        fi
        if [[ ! -f "${output}.processing" ]]; then
            pass ".processing cleaned up on success"
        else
            fail ".processing not cleaned up on success"
        fi
        if [[ ! -d "$session_dir" ]]; then
            pass "Session temp dir cleaned up on success"
        else
            fail "Session temp dir not cleaned up on success"
        fi
    else
        fail "Full process exited $exit_code (expected 0)"
    fi
}

# --- Test: Config reading ---

test_config_defaults() {
    echo "[test] Config defaults applied when no config file exists"
    # Use a config path that does not exist by temporarily unsetting it
    # We test indirectly: the script should not crash when config file is missing
    local output="${TEST_DIR}/config-test.md"
    local exit_code=0

    # Just test that --action with missing tools produces the right error
    # (this implicitly tests config reading path since SOURCE defaults from config)
    if ! has_tool sox; then
        "$PIPELINE" --action start --output "$output" 2>/dev/null || exit_code=$?
        if [[ $exit_code -eq 5 ]]; then
            pass "Config defaults work (script runs with defaults, fails at sox check)"
        else
            fail "Unexpected exit code $exit_code when testing config defaults"
        fi
    else
        skip "Cannot test config defaults indirectly when sox is installed"
    fi
}

# --- Test: Start action on macOS with real tools ---

test_full_start_stop_flow() {
    echo "[test] Full start/stop flow (requires sox on macOS)"
    if ! has_tool sox; then
        skip "sox not installed, cannot test start/stop flow"
        return
    fi
    if [[ "$(uname)" != "Darwin" ]]; then
        skip "Start/stop flow requires macOS CoreAudio"
        return
    fi

    local output="${TEST_DIR}/start-stop-test.md"
    local exit_code=0

    # Start recording
    "$PIPELINE" --action start --source mic --output "$output" 2>/dev/null || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        fail "Start action failed with exit code $exit_code"
        return
    fi
    pass "Start action exits 0"

    # Verify sentinel files
    if [[ -f "${output}.pid" ]]; then
        pass ".pid sentinel created on start"
    else
        fail ".pid sentinel not created on start"
        return
    fi

    if [[ -f "${output}.recording" ]]; then
        pass ".recording sentinel created on start"
    else
        fail ".recording sentinel not created on start"
    fi

    # Verify .recording JSON content
    if python3 -c "
import json
with open('${output}.recording') as f:
    d = json.load(f)
assert 'session_id' in d
assert 'source' in d
assert 'start_time' in d
assert d['source'] == 'mic'
" 2>/dev/null; then
        pass ".recording sentinel has valid JSON with required fields"
    else
        fail ".recording sentinel JSON is invalid"
    fi

    # Verify .pid content format
    local pid_content
    pid_content=$(cat "${output}.pid")
    local pid_part
    pid_part=$(echo "$pid_content" | cut -d: -f1)
    if [[ "$pid_part" =~ ^[0-9]+$ ]]; then
        pass ".pid contains numeric PID"
    else
        fail ".pid content format unexpected: $pid_content"
    fi

    # Wait briefly for sox to start
    sleep 2

    # Stop recording
    exit_code=0
    "$PIPELINE" --action stop --output "$output" 2>/dev/null || exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        pass "Stop action exits 0"
    else
        fail "Stop action failed with exit code $exit_code"
    fi

    # Verify post-stop state
    if [[ ! -f "${output}.pid" ]]; then
        pass ".pid removed after stop"
    else
        fail ".pid still exists after stop"
    fi

    if [[ -f "${output}.processing" ]]; then
        local step
        step=$(cat "${output}.processing")
        if [[ "$step" == "audio_stopped" ]]; then
            pass ".processing sentinel says 'audio_stopped'"
        else
            fail ".processing sentinel says '$step' (expected 'audio_stopped')"
        fi
    else
        fail ".processing sentinel not created after stop"
    fi
}

# --- Test: Error sentinel JSON format ---

test_error_sentinel_format() {
    echo "[test] Error sentinel JSON format validation"
    local output="${TEST_DIR}/error-format-test.md"

    # Trigger an error by stopping with no .pid
    "$PIPELINE" --action stop --output "$output" 2>/dev/null || true

    if [[ -f "${output}.error" ]]; then
        if python3 -c "
import json, sys
with open('${output}.error') as f:
    d = json.load(f)
required = ['step', 'exit_code', 'stderr']
for field in required:
    assert field in d, f'Missing field: {field}'
assert isinstance(d['exit_code'], int), 'exit_code should be int'
assert isinstance(d['step'], str), 'step should be string'
assert isinstance(d['stderr'], str), 'stderr should be string'
" 2>/dev/null; then
            pass ".error sentinel JSON has correct schema"
        else
            fail ".error sentinel JSON has incorrect schema"
        fi
    else
        fail "No .error sentinel created for test"
    fi
}

# --- Test: Config example file ---

test_config_example() {
    echo "[test] config.example.json is valid JSON with all required fields"
    local config_file="${SCRIPT_DIR}/config.example.json"
    if [[ ! -f "$config_file" ]]; then
        fail "config.example.json does not exist"
        return
    fi

    if python3 -c "
import json, sys
with open('${config_file}') as f:
    d = json.load(f)
required = ['micDevice', 'systemDevice', 'whisperModelPath', 'language', 'defaultOutputDir', 'defaultSource']
for field in required:
    assert field in d, f'Missing field: {field}'
assert d['defaultSource'] in ('mic', 'system', 'both'), 'defaultSource must be mic|system|both'
assert isinstance(d['language'], str) and len(d['language']) >= 2, 'language must be a string >= 2 chars'
" 2>/dev/null; then
        pass "config.example.json is valid with all 6 required fields"
    else
        fail "config.example.json validation failed"
    fi
}

# --- Test: Pipeline script is executable ---

test_pipeline_executable() {
    echo "[test] meeting-pipeline.sh is executable"
    if [[ -x "$PIPELINE" ]]; then
        pass "meeting-pipeline.sh is executable"
    else
        fail "meeting-pipeline.sh is not executable"
    fi
}

# --- Main ---

main() {
    echo "========================================"
    echo "Meeting Pipeline Test Suite"
    echo "========================================"
    echo ""
    echo "Platform: $(uname -s) $(uname -m)"
    echo "Tools available:"
    for tool in sox ffmpeg whisper-cpp python3; do
        if has_tool "$tool"; then
            echo "  $tool: $(command -v "$tool")"
        else
            echo "  $tool: NOT INSTALLED"
        fi
    done
    echo ""

    setup

    # Argument validation tests (always run)
    test_missing_action
    echo ""
    test_missing_output
    echo ""
    test_invalid_action
    echo ""
    test_unknown_argument
    echo ""
    test_invalid_source
    echo ""

    # Prerequisite tests
    test_missing_sox
    echo ""

    # Sentinel file tests (always run)
    test_sentinel_files_on_stop_no_pid
    echo ""
    test_sentinel_files_on_process_no_recording
    echo ""
    test_stop_with_stale_pid
    echo ""

    # Error sentinel format
    test_error_sentinel_format
    echo ""

    # Process with mock audio
    test_process_with_mock_audio
    echo ""

    # Config tests
    test_config_defaults
    echo ""
    test_config_example
    echo ""

    # Executable test
    test_pipeline_executable
    echo ""

    # Full flow (macOS + sox only)
    test_full_start_stop_flow
    echo ""

    teardown

    echo "========================================"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    echo "========================================"

    if [[ $FAIL -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
