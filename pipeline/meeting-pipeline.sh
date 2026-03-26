#!/usr/bin/env bash
set -euo pipefail

# meeting-pipeline.sh — Core deterministic recording/transcription pipeline
# Usage:
#   meeting-pipeline.sh --source mic|system|both --output /path/to/transcript.md \
#     [--model-path ~/models/ggml-large-v3-turbo-q5_0.bin] [--language en] \
#     --action start|stop|process

# Exit codes
EXIT_SUCCESS=0
EXIT_SOX_ERROR=1
EXIT_FFMPEG_ERROR=2
EXIT_WHISPER_ERROR=3
EXIT_FILE_WRITE_ERROR=4
EXIT_VALIDATION_ERROR=5

# --- Defaults ---
SOURCE=""
OUTPUT=""
MODEL_PATH=""
LANGUAGE=""
ACTION=""

CONFIG_FILE="${HOME}/.config/meeting-recorder/config.json"

# --- Config reading ---
read_config_field() {
    local field="$1"
    local default="$2"
    if [[ -f "$CONFIG_FILE" ]] && command -v python3 &>/dev/null; then
        local val
        val=$(python3 -c "
import json, sys
try:
    with open('${CONFIG_FILE}') as f:
        c = json.load(f)
    print(c.get('${field}', ''))
except Exception:
    print('')
" 2>/dev/null)
        if [[ -n "$val" ]]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            SOURCE="$2"
            shift 2
            ;;
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        --model-path)
            MODEL_PATH="$2"
            shift 2
            ;;
        --language)
            LANGUAGE="$2"
            shift 2
            ;;
        --action)
            ACTION="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit "$EXIT_VALIDATION_ERROR"
            ;;
    esac
done

# --- Apply config defaults ---
if [[ -z "$SOURCE" ]]; then
    SOURCE=$(read_config_field "defaultSource" "mic")
fi
if [[ -z "$MODEL_PATH" ]]; then
    MODEL_PATH=$(read_config_field "whisperModelPath" "${HOME}/models/ggml-large-v3-turbo-q5_0.bin")
fi
if [[ -z "$LANGUAGE" ]]; then
    LANGUAGE=$(read_config_field "language" "en")
fi

# Expand ~ in MODEL_PATH
MODEL_PATH="${MODEL_PATH/#\~/$HOME}"

# --- Validation ---
if [[ -z "$ACTION" ]]; then
    echo "Error: --action is required (start|stop|process)" >&2
    exit "$EXIT_VALIDATION_ERROR"
fi

if [[ -z "$OUTPUT" ]]; then
    echo "Error: --output is required" >&2
    exit "$EXIT_VALIDATION_ERROR"
fi

if [[ "$ACTION" == "start" || "$ACTION" == "process" ]] && [[ -z "$SOURCE" ]]; then
    echo "Error: --source is required for action '$ACTION'" >&2
    exit "$EXIT_VALIDATION_ERROR"
fi

# --- Derived paths ---
# Session ID: hash of output filename + timestamp
generate_session_id() {
    local hash
    hash=$(echo -n "${OUTPUT}" | shasum -a 256 2>/dev/null || echo -n "${OUTPUT}" | sha256sum 2>/dev/null)
    hash="${hash%% *}"
    echo "${hash:0:12}-$(date +%s)"
}

get_session_dir_from_recording() {
    if [[ -f "${OUTPUT}.recording" ]]; then
        local sid
        sid=$(python3 -c "
import json, sys
try:
    with open('${OUTPUT}.recording') as f:
        print(json.load(f)['session_id'])
except Exception:
    sys.exit(1)
" 2>/dev/null)
        if [[ -n "$sid" ]]; then
            echo "/tmp/meeting-recorder/${sid}"
            return
        fi
    fi
    echo ""
}

# Sentinel paths
PID_FILE="${OUTPUT}.pid"
RECORDING_FILE="${OUTPUT}.recording"
PROCESSING_FILE="${OUTPUT}.processing"
DONE_FILE="${OUTPUT}.done"
ERROR_FILE="${OUTPUT}.error"

# --- Helper functions ---
write_error() {
    local step="$1"
    local exit_code="$2"
    local stderr_msg="$3"

    # Escape special characters for JSON
    local escaped_stderr
    escaped_stderr=$(printf '%s' "$stderr_msg" | python3 -c "
import sys, json
print(json.dumps(sys.stdin.read())[1:-1])
" 2>/dev/null || printf '%s' "$stderr_msg" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')

    printf '{"step":"%s","exit_code":%d,"stderr":"%s"}\n' \
        "$step" "$exit_code" "$escaped_stderr" > "${ERROR_FILE}"

    # Cleanup on error: remove .pid and .processing, keep .recording
    rm -f "${PID_FILE}" "${PROCESSING_FILE}"
}

write_processing() {
    local step="$1"
    echo "$step" > "${PROCESSING_FILE}"
}

check_binary() {
    local bin="$1"
    if ! command -v "$bin" &>/dev/null; then
        echo "Error: Required binary '$bin' not found in PATH" >&2
        write_error "prerequisite_check" "$EXIT_VALIDATION_ERROR" "Missing binary: $bin"
        exit "$EXIT_VALIDATION_ERROR"
    fi
}

get_device_name() {
    local source_type="$1"
    case "$source_type" in
        mic)
            read_config_field "micDevice" "MacBook Pro Microphone"
            ;;
        system)
            read_config_field "systemDevice" "BlackHole 2ch"
            ;;
        *)
            echo ""
            ;;
    esac
}

validate_audio_device() {
    local device="$1"
    # On macOS, use sox to detect CoreAudio devices
    # On Linux (development), skip device validation
    if [[ "$(uname)" == "Darwin" ]]; then
        local available_devices
        available_devices=$(sox -V6 -n -t coreaudio junk 2>&1 || true)
        if ! echo "$available_devices" | grep -q "$device"; then
            echo "Error: Audio device '$device' not found" >&2
            write_error "device_validation" "$EXIT_VALIDATION_ERROR" "Audio device not found: $device"
            exit "$EXIT_VALIDATION_ERROR"
        fi
    else
        echo "Warning: Skipping audio device validation on non-macOS platform" >&2
    fi
}

# --- Action: start ---
action_start() {
    # 1. Validate prerequisites
    check_binary sox
    check_binary ffmpeg
    check_binary whisper-cpp

    # 2. Validate audio devices
    case "$SOURCE" in
        mic)
            local mic_device
            mic_device=$(get_device_name "mic")
            validate_audio_device "$mic_device"
            ;;
        system)
            local sys_device
            sys_device=$(get_device_name "system")
            validate_audio_device "$sys_device"
            ;;
        both)
            local mic_device sys_device
            mic_device=$(get_device_name "mic")
            sys_device=$(get_device_name "system")
            validate_audio_device "$mic_device"
            validate_audio_device "$sys_device"
            ;;
        *)
            echo "Error: Invalid --source value '$SOURCE'. Must be mic|system|both" >&2
            write_error "source_validation" "$EXIT_VALIDATION_ERROR" "Invalid source: $SOURCE"
            exit "$EXIT_VALIDATION_ERROR"
            ;;
    esac

    # 3. Create session directory
    local session_id
    session_id=$(generate_session_id)
    local session_dir="/tmp/meeting-recorder/${session_id}"
    mkdir -p "$session_dir"

    # Ensure output directory exists
    local output_dir
    output_dir=$(dirname "$OUTPUT")
    mkdir -p "$output_dir"

    # Clean up any stale sentinel files from previous runs targeting this output
    rm -f "${DONE_FILE}" "${ERROR_FILE}"

    # 4. Start sox recording
    local start_timestamp
    start_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [[ "$SOURCE" == "both" ]]; then
        local mic_device sys_device
        mic_device=$(get_device_name "mic")
        sys_device=$(get_device_name "system")

        # Start two sox processes
        sox -t coreaudio "$mic_device" "${session_dir}/mic.wav" &
        local mic_pid=$!

        sox -t coreaudio "$sys_device" "${session_dir}/system.wav" &
        local sys_pid=$!

        # 5. Write .pid file with both PIDs
        echo "${mic_pid}:${sys_pid}:${start_timestamp}" > "${PID_FILE}"
    else
        local device
        if [[ "$SOURCE" == "mic" ]]; then
            device=$(get_device_name "mic")
        else
            device=$(get_device_name "system")
        fi

        # Let sox use device's native sample rate to avoid BlackHole rate mismatch
        sox -t coreaudio "$device" "${session_dir}/raw.wav" &
        local sox_pid=$!

        # 5. Write .pid file
        echo "${sox_pid}:${start_timestamp}" > "${PID_FILE}"
    fi

    # 6. Write .recording sentinel
    python3 -c "
import json
with open('${RECORDING_FILE}', 'w') as f:
    json.dump({
        'session_id': '${session_id}',
        'source': '${SOURCE}',
        'start_time': '${start_timestamp}'
    }, f)
" 2>/dev/null || {
        cat > "${RECORDING_FILE}" <<SENTINEL_EOF
{"session_id":"${session_id}","source":"${SOURCE}","start_time":"${start_timestamp}"}
SENTINEL_EOF
    }

    echo "Recording started (session: ${session_id}, source: ${SOURCE})"

    # 7. Exit immediately (sox runs in background)
    exit "$EXIT_SUCCESS"
}

# --- Action: stop ---
action_stop() {
    # 1. Read .pid file
    if [[ ! -f "${PID_FILE}" ]]; then
        echo "Error: No .pid file found at ${PID_FILE}. Is a recording active?" >&2
        write_error "stop_no_pid" "$EXIT_SOX_ERROR" "No .pid file found"
        exit "$EXIT_SOX_ERROR"
    fi

    local pid_content
    pid_content=$(cat "${PID_FILE}")

    # Determine if this is a dual-PID (both) or single-PID recording
    # by reading the source from the .recording sentinel
    local recording_source=""
    if [[ -f "${RECORDING_FILE}" ]]; then
        recording_source=$(python3 -c "
import json, sys
try:
    with open('${RECORDING_FILE}') as f:
        print(json.load(f).get('source', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")
    fi

    local is_both=0
    if [[ "$recording_source" == "both" ]]; then
        is_both=1
    fi

    stop_sox_pid() {
        local pid="$1"
        local label="$2"

        # 2. Validate PID
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "Warning: PID $pid ($label) is not running" >&2
            return 1
        fi

        # Check process name contains "sox" (platform-aware)
        local proc_name=""
        if [[ "$(uname)" == "Darwin" ]]; then
            proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        else
            proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        fi

        if [[ -n "$proc_name" ]] && ! echo "$proc_name" | grep -qi "sox"; then
            echo "Warning: PID $pid ($label) does not appear to be a sox process (found: $proc_name)" >&2
            return 1
        fi

        # 4. Send SIGINT for graceful stop
        kill -INT "$pid" 2>/dev/null || true

        # 5. Wait for sox to finish (up to 10s)
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
            sleep 1
            waited=$((waited + 1))
        done

        # If still running after 10s, SIGKILL
        if kill -0 "$pid" 2>/dev/null; then
            echo "Warning: sox ($label) did not stop within 10s, sending SIGKILL" >&2
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
        fi

        return 0
    }

    local any_error=0

    if [[ "$is_both" -eq 1 ]]; then
        # Both mode: mic_pid:sys_pid:timestamp
        local mic_pid sys_pid start_ts
        mic_pid=$(echo "$pid_content" | cut -d: -f1)
        sys_pid=$(echo "$pid_content" | cut -d: -f2)
        start_ts=$(echo "$pid_content" | cut -d: -f3-)

        stop_sox_pid "$mic_pid" "mic" || any_error=1
        stop_sox_pid "$sys_pid" "system" || any_error=1

        if [[ $any_error -eq 1 ]]; then
            # Check if at least one was valid
            local session_dir
            session_dir=$(get_session_dir_from_recording)
            if [[ -z "$session_dir" ]] || { [[ ! -f "${session_dir}/mic.wav" ]] && [[ ! -f "${session_dir}/system.wav" ]]; }; then
                write_error "stop_invalid_pids" "$EXIT_SOX_ERROR" "Both recording PIDs are invalid or stale"
                exit "$EXIT_SOX_ERROR"
            fi
        fi

        # Merge the two recordings if both exist
        local session_dir
        session_dir=$(get_session_dir_from_recording)
        if [[ -n "$session_dir" ]] && [[ -f "${session_dir}/mic.wav" ]] && [[ -f "${session_dir}/system.wav" ]]; then
            sox -m "${session_dir}/mic.wav" "${session_dir}/system.wav" "${session_dir}/raw.wav" 2>/dev/null || {
                write_error "stop_merge" "$EXIT_SOX_ERROR" "Failed to merge mic and system audio"
                exit "$EXIT_SOX_ERROR"
            }
        elif [[ -n "$session_dir" ]] && [[ -f "${session_dir}/mic.wav" ]]; then
            cp "${session_dir}/mic.wav" "${session_dir}/raw.wav"
        elif [[ -n "$session_dir" ]] && [[ -f "${session_dir}/system.wav" ]]; then
            cp "${session_dir}/system.wav" "${session_dir}/raw.wav"
        fi
    else
        # Single source mode: pid:timestamp
        local sox_pid start_ts
        sox_pid=$(echo "$pid_content" | cut -d: -f1)
        start_ts=$(echo "$pid_content" | cut -d: -f2-)

        if ! stop_sox_pid "$sox_pid" "recording"; then
            # PID invalid — check if it's completely stale
            local session_dir
            session_dir=$(get_session_dir_from_recording)
            if [[ -z "$session_dir" ]] || [[ ! -f "${session_dir}/raw.wav" ]]; then
                write_error "stop_invalid_pid" "$EXIT_SOX_ERROR" "Recording PID $sox_pid is invalid or stale"
                exit "$EXIT_SOX_ERROR"
            fi
            echo "Warning: sox PID was invalid but raw.wav exists, proceeding" >&2
        fi
    fi

    # 6. Remove .pid file
    rm -f "${PID_FILE}"

    # 7. Write .processing sentinel
    write_processing "audio_stopped"

    echo "Recording stopped. Run --action process to transcribe."
    exit "$EXIT_SUCCESS"
}

# --- Action: process ---
action_process() {
    # 1. Read raw .wav from session temp dir
    local session_dir
    session_dir=$(get_session_dir_from_recording)

    if [[ -z "$session_dir" ]]; then
        echo "Error: Cannot determine session directory. Is .recording sentinel present?" >&2
        write_error "process_no_session" "$EXIT_FILE_WRITE_ERROR" "No .recording sentinel found"
        exit "$EXIT_FILE_WRITE_ERROR"
    fi

    local raw_wav="${session_dir}/raw.wav"
    if [[ ! -f "$raw_wav" ]]; then
        echo "Error: Raw audio file not found at ${raw_wav}" >&2
        write_error "process_no_audio" "$EXIT_FILE_WRITE_ERROR" "Raw audio file not found: ${raw_wav}"
        exit "$EXIT_FILE_WRITE_ERROR"
    fi

    # 2. Update .processing: "converting_audio"
    write_processing "converting_audio"

    # 3. ffmpeg convert to 16kHz mono WAV
    local converted_wav="${session_dir}/16k.wav"
    local ffmpeg_stderr
    ffmpeg_stderr=$(mktemp)

    if ! ffmpeg -y -i "$raw_wav" -ar 16000 -ac 1 -c:a pcm_s16le "$converted_wav" 2>"$ffmpeg_stderr"; then
        local err_msg
        err_msg=$(cat "$ffmpeg_stderr")
        rm -f "$ffmpeg_stderr"
        write_error "converting_audio" "$EXIT_FFMPEG_ERROR" "$err_msg"
        exit "$EXIT_FFMPEG_ERROR"
    fi
    rm -f "$ffmpeg_stderr"

    # 4. Update .processing: "transcribing"
    write_processing "transcribing"

    # 5. Set Metal GPU acceleration (macOS only)
    if [[ "$(uname)" == "Darwin" ]] && command -v brew &>/dev/null; then
        local whisper_prefix
        whisper_prefix=$(brew --prefix whisper-cpp 2>/dev/null || true)
        if [[ -n "$whisper_prefix" ]] && [[ -d "${whisper_prefix}/share/whisper-cpp" ]]; then
            export GGML_METAL_PATH_RESOURCES="${whisper_prefix}/share/whisper-cpp"
        fi
    fi

    # 6. Run whisper-cpp
    local transcript_base="${session_dir}/transcript"
    local whisper_stderr
    whisper_stderr=$(mktemp)

    if ! whisper-cpp \
        -l "$LANGUAGE" \
        -m "$MODEL_PATH" \
        --output-txt \
        -t 4 \
        -f "$converted_wav" \
        --output-file "$transcript_base" 2>"$whisper_stderr"; then
        local err_msg
        err_msg=$(cat "$whisper_stderr")
        rm -f "$whisper_stderr"
        write_error "transcribing" "$EXIT_WHISPER_ERROR" "$err_msg"
        exit "$EXIT_WHISPER_ERROR"
    fi
    rm -f "$whisper_stderr"

    # 7. Move transcript to target output path
    local transcript_file="${transcript_base}.txt"
    if [[ ! -f "$transcript_file" ]]; then
        write_error "transcript_move" "$EXIT_FILE_WRITE_ERROR" "Transcript file not found at ${transcript_file}"
        exit "$EXIT_FILE_WRITE_ERROR"
    fi

    # Ensure output directory exists
    local output_dir
    output_dir=$(dirname "$OUTPUT")
    mkdir -p "$output_dir"

    if ! cp "$transcript_file" "$OUTPUT"; then
        write_error "transcript_move" "$EXIT_FILE_WRITE_ERROR" "Failed to copy transcript to ${OUTPUT}"
        exit "$EXIT_FILE_WRITE_ERROR"
    fi

    # Set user-only permissions on transcript
    chmod 600 "$OUTPUT" 2>/dev/null || true

    # 8. Write .done sentinel
    touch "${DONE_FILE}"

    # 9. Clean up: remove .recording, .processing, session temp directory
    rm -f "${RECORDING_FILE}" "${PROCESSING_FILE}"
    rm -rf "$session_dir"

    echo "Transcript written to ${OUTPUT}"

    # 10. Exit 0
    exit "$EXIT_SUCCESS"
}

# --- Dispatch ---
case "$ACTION" in
    start)
        action_start
        ;;
    stop)
        action_stop
        ;;
    process)
        action_process
        ;;
    *)
        echo "Error: Invalid --action value '$ACTION'. Must be start|stop|process" >&2
        exit "$EXIT_VALIDATION_ERROR"
        ;;
esac
