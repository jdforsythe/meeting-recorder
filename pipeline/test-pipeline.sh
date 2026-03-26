#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# test-pipeline.sh — End-to-end tests for meeting-pipeline.sh
#
# Run with:  bash pipeline/test-pipeline.sh
#
# Tests the full start -> stop -> process -> verify pipeline as well as
# error paths. Skips gracefully when required macOS-specific tools are absent.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="${SCRIPT_DIR}/meeting-pipeline.sh"
TEST_DIR="/tmp/meeting-recorder-test-$$"
TEST_OUTPUT="${TEST_DIR}/test-transcript.md"
SESSION_BASE="/tmp/meeting-recorder"

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_SKIPPED=0
TESTS_FAILED=0

###############################################################################
# Helpers
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No color

log_test() {
    echo -e "${NC}[TEST] $*"
}

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: $*"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: $*"
}

skip() {
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    echo -e "  ${YELLOW}SKIP${NC}: $*"
}

begin_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    log_test "[$TESTS_RUN] $*"
}

cleanup() {
    # Remove test artifacts
    rm -rf "$TEST_DIR"
    rm -f "${TEST_OUTPUT}.pid"
    rm -f "${TEST_OUTPUT}.recording"
    rm -f "${TEST_OUTPUT}.processing"
    rm -f "${TEST_OUTPUT}.done"
    rm -f "${TEST_OUTPUT}.error"

    # Clean up any sox processes we may have started
    if [[ -f "${TEST_OUTPUT}.pid" ]]; then
        while IFS=: read -r pid _ts; do
            kill "$pid" 2>/dev/null || true
        done < "${TEST_OUTPUT}.pid"
    fi
}

# Always clean up on exit
trap cleanup EXIT

###############################################################################
# Pre-flight: check that the pipeline script exists and is executable
###############################################################################
if [[ ! -f "$PIPELINE" ]]; then
    echo "ERROR: Pipeline script not found at ${PIPELINE}"
    exit 1
fi

if [[ ! -x "$PIPELINE" ]]; then
    echo "WARNING: Pipeline script not executable, fixing..."
    chmod +x "$PIPELINE"
fi

###############################################################################
# Check for required tools
###############################################################################
HAS_SOX=false
HAS_FFMPEG=false
HAS_WHISPER=false

command -v sox &>/dev/null && HAS_SOX=true
command -v ffmpeg &>/dev/null && HAS_FFMPEG=true
command -v whisper-cpp &>/dev/null && HAS_WHISPER=true

echo "=============================================="
echo " Meeting Pipeline Test Suite"
echo "=============================================="
echo "Pipeline: ${PIPELINE}"
echo "Test dir: ${TEST_DIR}"
echo ""
echo "Tool availability:"
echo "  sox:        ${HAS_SOX}"
echo "  ffmpeg:     ${HAS_FFMPEG}"
echo "  whisper-cpp: ${HAS_WHISPER}"
echo ""

# Create test directory
mkdir -p "$TEST_DIR"

###############################################################################
# Test 1: Argument validation — missing --action
###############################################################################
begin_test "Missing --action argument returns exit code 5"

set +e
stderr_output=$(bash "$PIPELINE" --output "$TEST_OUTPUT" 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 5 ]]; then
    pass "Exit code is 5 for missing --action"
else
    fail "Expected exit code 5, got ${exit_code}"
fi

###############################################################################
# Test 2: Argument validation — missing --output
###############################################################################
begin_test "Missing --output argument returns exit code 5"

set +e
stderr_output=$(bash "$PIPELINE" --action start 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 5 ]]; then
    pass "Exit code is 5 for missing --output"
else
    fail "Expected exit code 5, got ${exit_code}"
fi

###############################################################################
# Test 3: Argument validation — invalid --source
###############################################################################
begin_test "Invalid --source value returns exit code 5"

set +e
stderr_output=$(bash "$PIPELINE" --action start --output "$TEST_OUTPUT" --source invalid 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 5 ]]; then
    pass "Exit code is 5 for invalid --source"
else
    fail "Expected exit code 5, got ${exit_code}"
fi

###############################################################################
# Test 4: Argument validation — invalid --action
###############################################################################
begin_test "Invalid --action value returns exit code 5"

set +e
stderr_output=$(bash "$PIPELINE" --action bogus --output "$TEST_OUTPUT" 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 5 ]]; then
    pass "Exit code is 5 for invalid --action"
else
    fail "Expected exit code 5, got ${exit_code}"
fi

###############################################################################
# Test 5: Argument validation — unknown flag
###############################################################################
begin_test "Unknown argument returns exit code 5"

set +e
stderr_output=$(bash "$PIPELINE" --action start --output "$TEST_OUTPUT" --unknown-flag foo 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 5 ]]; then
    pass "Exit code is 5 for unknown argument"
else
    fail "Expected exit code 5, got ${exit_code}"
fi

###############################################################################
# Test 6: start action — prerequisite validation (when tools missing)
###############################################################################
begin_test "Start action validates prerequisites"

if [[ "$HAS_SOX" == "true" && "$HAS_FFMPEG" == "true" && "$HAS_WHISPER" == "true" ]]; then
    skip "All tools are installed; cannot test missing-prerequisite path here"
else
    # At least one tool is missing so start should fail with exit 5
    cleanup
    mkdir -p "$TEST_DIR"

    set +e
    stderr_output=$(bash "$PIPELINE" --action start --output "$TEST_OUTPUT" --source mic 2>&1)
    exit_code=$?
    set -e

    if [[ $exit_code -eq 5 ]]; then
        pass "Exit code is 5 when prerequisites are missing"
    else
        fail "Expected exit code 5, got ${exit_code}"
    fi

    # Verify .error sentinel was written
    if [[ -f "${TEST_OUTPUT}.error" ]]; then
        pass ".error sentinel was created on prerequisite failure"

        # Check .error sentinel contains valid JSON with expected fields
        step_val=$(python3 -c "
import json
with open('${TEST_OUTPUT}.error') as f:
    data = json.load(f)
print(data.get('step', ''))
" 2>/dev/null) || step_val=""

        if [[ "$step_val" == "validate_prerequisites" ]]; then
            pass ".error sentinel has correct step field"
        else
            fail ".error sentinel step is '${step_val}', expected 'validate_prerequisites'"
        fi
    else
        fail ".error sentinel was not created on prerequisite failure"
    fi

    # Verify .pid was cleaned up (should not exist on error)
    if [[ ! -f "${TEST_OUTPUT}.pid" ]]; then
        pass ".pid file was cleaned up on error"
    else
        fail ".pid file still exists after error"
    fi
fi

###############################################################################
# Test 7: stop action — missing .pid file
###############################################################################
begin_test "Stop action fails gracefully when no .pid file exists"

cleanup
mkdir -p "$TEST_DIR"

set +e
stderr_output=$(bash "$PIPELINE" --action stop --output "$TEST_OUTPUT" 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 1 ]]; then
    pass "Exit code is 1 for missing .pid file"
else
    fail "Expected exit code 1, got ${exit_code}"
fi

if [[ -f "${TEST_OUTPUT}.error" ]]; then
    pass ".error sentinel created for missing .pid"
else
    fail ".error sentinel not created for missing .pid"
fi

###############################################################################
# Test 8: stop action — stale PID in .pid file
###############################################################################
begin_test "Stop action handles stale PID"

cleanup
mkdir -p "$TEST_DIR"

# Write a .pid file with a PID that definitely does not exist
echo "99999999:$(date '+%s')" > "${TEST_OUTPUT}.pid"

set +e
stderr_output=$(bash "$PIPELINE" --action stop --output "$TEST_OUTPUT" 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 1 ]]; then
    pass "Exit code is 1 for stale PID"
else
    fail "Expected exit code 1 for stale PID, got ${exit_code}"
fi

if [[ -f "${TEST_OUTPUT}.error" ]]; then
    pass ".error sentinel created for stale PID"
else
    fail ".error sentinel not created for stale PID"
fi

###############################################################################
# Test 9: process action — missing .recording sentinel
###############################################################################
begin_test "Process action fails when .recording sentinel missing"

cleanup
mkdir -p "$TEST_DIR"

set +e
stderr_output=$(bash "$PIPELINE" --action process --output "$TEST_OUTPUT" --model-path /nonexistent/model.bin 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 4 ]]; then
    pass "Exit code is 4 for missing .recording sentinel"
else
    fail "Expected exit code 4, got ${exit_code}"
fi

if [[ -f "${TEST_OUTPUT}.error" ]]; then
    step_val=$(python3 -c "
import json
with open('${TEST_OUTPUT}.error') as f:
    data = json.load(f)
print(data.get('step', ''))
" 2>/dev/null) || step_val=""

    if [[ "$step_val" == "process_recover_session" ]]; then
        pass ".error sentinel step is 'process_recover_session'"
    else
        fail ".error sentinel step is '${step_val}', expected 'process_recover_session'"
    fi
else
    fail ".error sentinel not created"
fi

###############################################################################
# Test 10: process action — missing raw WAV
###############################################################################
begin_test "Process action fails when raw WAV is missing"

cleanup
mkdir -p "$TEST_DIR"

# Create a fake .recording sentinel pointing to an empty session directory
FAKE_SESSION_ID="test-nosound-$(date '+%s')"
FAKE_SESSION_DIR="${SESSION_BASE}/${FAKE_SESSION_ID}"
mkdir -p "$FAKE_SESSION_DIR"

python3 -c "
import json
data = {'session_id': '${FAKE_SESSION_ID}', 'source': 'mic', 'start_time': '2026-01-01T00:00:00Z'}
with open('${TEST_OUTPUT}.recording', 'w') as f:
    json.dump(data, f)
"

set +e
stderr_output=$(bash "$PIPELINE" --action process --output "$TEST_OUTPUT" --model-path /nonexistent/model.bin 2>&1)
exit_code=$?
set -e

if [[ $exit_code -eq 4 ]]; then
    pass "Exit code is 4 for missing raw WAV"
else
    fail "Expected exit code 4, got ${exit_code}"
fi

if [[ -f "${TEST_OUTPUT}.error" ]]; then
    pass ".error sentinel created for missing raw WAV"
else
    fail ".error sentinel not created for missing raw WAV"
fi

# Verify .recording is preserved on error (per spec)
if [[ -f "${TEST_OUTPUT}.recording" ]]; then
    pass ".recording sentinel preserved on error"
else
    fail ".recording sentinel was deleted on error (should be preserved)"
fi

###############################################################################
# Test 11: Full pipeline integration (start -> stop -> process)
###############################################################################
begin_test "Full pipeline integration (start -> stop -> process)"

if [[ "$HAS_SOX" != "true" ]]; then
    skip "sox not installed — cannot run full integration test"
elif [[ "$HAS_FFMPEG" != "true" ]]; then
    skip "ffmpeg not installed — cannot run full integration test"
elif [[ "$HAS_WHISPER" != "true" ]]; then
    skip "whisper-cpp not installed — cannot run full integration test"
else
    cleanup
    mkdir -p "$TEST_DIR"

    # Determine available audio device for mic
    mic_device=$(python3 -c "
import json, os
config_path = os.path.expanduser('~/.config/meeting-recorder/config.json')
try:
    with open(config_path) as f:
        cfg = json.load(f)
    print(cfg.get('micDevice', 'default'))
except Exception:
    print('default')
" 2>/dev/null) || mic_device="default"

    # Check if the mic device is available
    if sox -t coreaudio --list-devices 2>&1 | grep -qF "$mic_device"; then
        log_test "Using mic device: ${mic_device}"
    else
        skip "Configured mic device '${mic_device}' not available"
        # Jump to summary (we still want to run the rest of tests)
        HAS_DEVICE=false
    fi

    if [[ "${HAS_DEVICE:-true}" == "true" ]]; then
        # --- START ---
        set +e
        stderr_output=$(bash "$PIPELINE" --action start --output "$TEST_OUTPUT" --source mic 2>&1)
        start_exit=$?
        set -e

        if [[ $start_exit -eq 0 ]]; then
            pass "start action exited 0"
        else
            fail "start action exited ${start_exit}"
            echo "  stderr: ${stderr_output}"
        fi

        # Verify .pid sentinel exists
        if [[ -f "${TEST_OUTPUT}.pid" ]]; then
            pass ".pid sentinel created"

            # Verify format: {pid}:{timestamp}
            pid_content=$(cat "${TEST_OUTPUT}.pid")
            if echo "$pid_content" | grep -qE '^[0-9]+:[0-9]+$'; then
                pass ".pid format is correct (${pid_content})"
            else
                fail ".pid format unexpected: ${pid_content}"
            fi
        else
            fail ".pid sentinel not created"
        fi

        # Verify .recording sentinel exists and has valid JSON
        if [[ -f "${TEST_OUTPUT}.recording" ]]; then
            pass ".recording sentinel created"

            session_id=$(python3 -c "
import json
with open('${TEST_OUTPUT}.recording') as f:
    data = json.load(f)
assert 'session_id' in data, 'missing session_id'
assert 'source' in data, 'missing source'
assert 'start_time' in data, 'missing start_time'
print(data['session_id'])
" 2>/dev/null) || session_id=""

            if [[ -n "$session_id" ]]; then
                pass ".recording has valid JSON with required fields"
            else
                fail ".recording JSON is invalid or missing fields"
            fi
        else
            fail ".recording sentinel not created"
        fi

        # Let it record for 2 seconds
        sleep 2

        # --- STOP ---
        set +e
        stderr_output=$(bash "$PIPELINE" --action stop --output "$TEST_OUTPUT" 2>&1)
        stop_exit=$?
        set -e

        if [[ $stop_exit -eq 0 ]]; then
            pass "stop action exited 0"
        else
            fail "stop action exited ${stop_exit}"
            echo "  stderr: ${stderr_output}"
        fi

        # Verify .pid removed after stop
        if [[ ! -f "${TEST_OUTPUT}.pid" ]]; then
            pass ".pid file removed after stop"
        else
            fail ".pid file still present after stop"
        fi

        # Verify .processing sentinel exists with "audio_stopped"
        if [[ -f "${TEST_OUTPUT}.processing" ]]; then
            proc_content=$(cat "${TEST_OUTPUT}.processing")
            if [[ "$proc_content" == "audio_stopped" ]]; then
                pass ".processing sentinel contains 'audio_stopped'"
            else
                fail ".processing sentinel contains '${proc_content}', expected 'audio_stopped'"
            fi
        else
            fail ".processing sentinel not created after stop"
        fi

        # --- PROCESS ---
        # Need the whisper model path
        model_path=$(python3 -c "
import json, os
config_path = os.path.expanduser('~/.config/meeting-recorder/config.json')
try:
    with open(config_path) as f:
        cfg = json.load(f)
    path = cfg.get('whisperModelPath', '')
    print(os.path.expanduser(path))
except Exception:
    print('')
" 2>/dev/null) || model_path=""

        if [[ -z "$model_path" || ! -f "$model_path" ]]; then
            skip "Whisper model not found at '${model_path}' — skipping process test"
        else
            set +e
            stderr_output=$(bash "$PIPELINE" --action process --output "$TEST_OUTPUT" --model-path "$model_path" 2>&1)
            process_exit=$?
            set -e

            if [[ $process_exit -eq 0 ]]; then
                pass "process action exited 0"
            else
                fail "process action exited ${process_exit}"
                echo "  stderr: ${stderr_output}"
            fi

            # Verify output transcript exists
            if [[ -f "$TEST_OUTPUT" ]]; then
                pass "Transcript file created at ${TEST_OUTPUT}"
            else
                fail "Transcript file not found at ${TEST_OUTPUT}"
            fi

            # Verify .done sentinel
            if [[ -f "${TEST_OUTPUT}.done" ]]; then
                pass ".done sentinel created"
            else
                fail ".done sentinel not created"
            fi

            # Verify cleanup: .recording and .processing should be gone
            if [[ ! -f "${TEST_OUTPUT}.recording" ]]; then
                pass ".recording cleaned up after process"
            else
                fail ".recording still present after successful process"
            fi

            if [[ ! -f "${TEST_OUTPUT}.processing" ]]; then
                pass ".processing cleaned up after process"
            else
                fail ".processing still present after successful process"
            fi
        fi
    fi
fi

###############################################################################
# Test 12: .error sentinel JSON structure validation
###############################################################################
begin_test "Error sentinel JSON structure is valid"

cleanup
mkdir -p "$TEST_DIR"

# Force an error by running process without .recording
set +e
bash "$PIPELINE" --action process --output "$TEST_OUTPUT" --model-path /nonexistent/model.bin 2>/dev/null
set -e

if [[ -f "${TEST_OUTPUT}.error" ]]; then
    valid=$(python3 -c "
import json, sys
with open('${TEST_OUTPUT}.error') as f:
    data = json.load(f)
required = ['step', 'exit_code', 'stderr']
missing = [k for k in required if k not in data]
if missing:
    print('missing: ' + ', '.join(missing))
    sys.exit(1)
if not isinstance(data['exit_code'], int):
    print('exit_code is not int')
    sys.exit(1)
print('ok')
" 2>/dev/null) || valid="parse_error"

    if [[ "$valid" == "ok" ]]; then
        pass ".error sentinel has valid JSON with step, exit_code, stderr"
    else
        fail ".error sentinel JSON validation: ${valid}"
    fi
else
    fail ".error sentinel not found"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "=============================================="
echo " Test Results"
echo "=============================================="
echo -e "  ${GREEN}Passed${NC}:  ${TESTS_PASSED}"
echo -e "  ${RED}Failed${NC}:  ${TESTS_FAILED}"
echo -e "  ${YELLOW}Skipped${NC}: ${TESTS_SKIPPED}"
echo -e "  Total:   ${TESTS_RUN}"
echo "=============================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All executed tests passed.${NC}"
    exit 0
fi
