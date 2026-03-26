#!/usr/bin/env bash
set -euo pipefail

# meeting-pipeline.sh — Core deterministic pipeline for meeting recording and transcription.
# No LLM calls. Fully testable. Runs on macOS with Homebrew-installed tools.

###############################################################################
# Constants
###############################################################################
CONFIG_PATH="${HOME}/.config/meeting-recorder/config.json"
SESSION_BASE="/tmp/meeting-recorder"

###############################################################################
# Logging helpers
###############################################################################
log_info() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] INFO: $*" >&2
}

log_error() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2
}

###############################################################################
# Config loading — uses python3 for JSON parsing (jq may not be installed)
###############################################################################
read_config() {
    local key="$1"
    local default="${2:-}"

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo "$default"
        return
    fi

    local value
    value=$(_CFG_PATH="$CONFIG_PATH" _CFG_KEY="$key" python3 -c "
import json, os
try:
    with open(os.environ['_CFG_PATH']) as f:
        cfg = json.load(f)
    print(cfg.get(os.environ['_CFG_KEY'], ''))
except Exception:
    print('')
" 2>/dev/null) || true

    if [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

###############################################################################
# Session helpers
###############################################################################
get_session_id() {
    local output_path="$1"
    local ts
    ts=$(date '+%s')
    # Derive from output filename hash + timestamp
    local hash
    hash=$(echo -n "$output_path" | shasum -a 256 2>/dev/null | cut -c1-12 || echo -n "$output_path" | python3 -c "import sys,hashlib;print(hashlib.sha256(sys.stdin.read().strip().encode()).hexdigest()[:12])")
    echo "${hash}-${ts}"
}

get_session_dir() {
    local session_id="$1"
    echo "${SESSION_BASE}/${session_id}"
}

# Recover session directory from .recording sentinel
recover_session_dir() {
    local output="$1"
    local recording_file="${output}.recording"

    if [[ ! -f "$recording_file" ]]; then
        log_error "No .recording sentinel found at ${recording_file}"
        return 1
    fi

    local session_id
    session_id=$(_REC_FILE="$recording_file" python3 -c "
import json, os
with open(os.environ['_REC_FILE']) as f:
    data = json.load(f)
print(data['session_id'])
" 2>/dev/null) || { log_error "Failed to read session_id from .recording sentinel"; return 1; }

    echo "${SESSION_BASE}/${session_id}"
}

recover_session_id() {
    local output="$1"
    local recording_file="${output}.recording"

    if [[ ! -f "$recording_file" ]]; then
        return 1
    fi

    _REC_FILE="$recording_file" python3 -c "
import json, os
with open(os.environ['_REC_FILE']) as f:
    data = json.load(f)
print(data['session_id'])
" 2>/dev/null
}

###############################################################################
# Sentinel file writers
###############################################################################
write_pid_sentinel() {
    local output="$1"
    local pid="$2"
    local ts
    ts=$(date '+%s')
    echo "${pid}:${ts}" >> "${output}.pid"
}

write_recording_sentinel() {
    local output="$1"
    local session_id="$2"
    local source="$3"
    local start_time
    start_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    _REC_SID="$session_id" _REC_SRC="$source" _REC_TIME="$start_time" _REC_FILE="${output}.recording" \
    python3 -c "
import json, os
data = {'session_id': os.environ['_REC_SID'], 'source': os.environ['_REC_SRC'], 'start_time': os.environ['_REC_TIME']}
with open(os.environ['_REC_FILE'], 'w') as f:
    json.dump(data, f, indent=2)
"
}

write_processing_sentinel() {
    local output="$1"
    local step="$2"
    echo "$step" > "${output}.processing"
}

write_done_sentinel() {
    local output="$1"
    touch "${output}.done"
}

write_error_sentinel() {
    local output="$1"
    local step="$2"
    local exit_code="$3"
    local stderr_msg="$4"

    _ERR_STEP="$step" _ERR_CODE="$exit_code" _ERR_MSG="$stderr_msg" _ERR_FILE="${output}.error" \
    python3 -c "
import json, os
data = {'step': os.environ['_ERR_STEP'], 'exit_code': int(os.environ['_ERR_CODE']), 'stderr': os.environ['_ERR_MSG']}
with open(os.environ['_ERR_FILE'], 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true
    # Cleanup on error: remove .pid and .processing but keep .recording
    rm -f "${output}.pid"
    rm -f "${output}.processing"
}

###############################################################################
# Validation helpers
###############################################################################
validate_prerequisites() {
    local missing=()
    for cmd in sox ffmpeg whisper-cpp; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites: ${missing[*]}"
        return 1
    fi
    log_info "All prerequisites found"
}

validate_audio_device() {
    local device_name="$1"

    # List available CoreAudio devices via sox and check for the device
    local devices
    devices=$(sox -t coreaudio --list-devices 2>&1 || true)

    if echo "$devices" | grep -qF "$device_name"; then
        log_info "Audio device found: ${device_name}"
        return 0
    else
        log_error "Audio device not found: ${device_name}"
        log_error "Available devices:"
        echo "$devices" >&2
        return 1
    fi
}

###############################################################################
# Argument parsing
###############################################################################
SOURCE=""
OUTPUT=""
MODEL_PATH=""
LANGUAGE="en"
ACTION=""

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
            log_error "Unknown argument: $1"
            exit 5
            ;;
    esac
done

# Validate required arguments
if [[ -z "$ACTION" ]]; then
    log_error "Missing required argument: --action"
    exit 5
fi

if [[ -z "$OUTPUT" ]]; then
    log_error "Missing required argument: --output"
    exit 5
fi

if [[ "$ACTION" == "process" && -z "$MODEL_PATH" ]]; then
    # Try config
    MODEL_PATH=$(read_config "whisperModelPath" "")
    if [[ -z "$MODEL_PATH" ]]; then
        log_error "Missing required argument: --model-path"
        exit 5
    fi
fi

# Expand tilde in MODEL_PATH
MODEL_PATH="${MODEL_PATH/#\~/$HOME}"

# Default source from config if not set
if [[ -z "$SOURCE" ]]; then
    SOURCE=$(read_config "defaultSource" "mic")
fi

# Validate source value
if [[ "$SOURCE" != "mic" && "$SOURCE" != "system" && "$SOURCE" != "both" ]]; then
    log_error "Invalid --source value: ${SOURCE}. Must be mic, system, or both."
    exit 5
fi

# Validate action value
if [[ "$ACTION" != "start" && "$ACTION" != "stop" && "$ACTION" != "process" ]]; then
    log_error "Invalid --action value: ${ACTION}. Must be start, stop, or process."
    exit 5
fi

###############################################################################
# ACTION: start
###############################################################################
action_start() {
    log_info "Starting recording (source=${SOURCE}, output=${OUTPUT})"

    # 1. Validate prerequisites
    if ! validate_prerequisites; then
        write_error_sentinel "$OUTPUT" "validate_prerequisites" 5 "Missing required binaries"
        exit 5
    fi

    # 2. Resolve device names from config
    local mic_device
    mic_device=$(read_config "micDevice" "default")
    local system_device
    system_device=$(read_config "systemDevice" "BlackHole 2ch")

    # 3. Validate audio devices
    case "$SOURCE" in
        mic)
            if ! validate_audio_device "$mic_device"; then
                write_error_sentinel "$OUTPUT" "validate_audio_device" 5 "Mic device not found: ${mic_device}"
                exit 5
            fi
            ;;
        system)
            if ! validate_audio_device "$system_device"; then
                write_error_sentinel "$OUTPUT" "validate_audio_device" 5 "System device not found: ${system_device}"
                exit 5
            fi
            ;;
        both)
            if ! validate_audio_device "$mic_device"; then
                write_error_sentinel "$OUTPUT" "validate_audio_device" 5 "Mic device not found: ${mic_device}"
                exit 5
            fi
            if ! validate_audio_device "$system_device"; then
                write_error_sentinel "$OUTPUT" "validate_audio_device" 5 "System device not found: ${system_device}"
                exit 5
            fi
            ;;
    esac

    # 4. Create session directory
    local session_id
    session_id=$(get_session_id "$OUTPUT")
    local session_dir
    session_dir=$(get_session_dir "$session_id")
    mkdir -p "$session_dir"
    log_info "Session directory: ${session_dir}"

    # 5. Start sox recording
    # Clean any previous pid file
    rm -f "${OUTPUT}.pid"

    case "$SOURCE" in
        mic)
            sox -t coreaudio "$mic_device" "${session_dir}/raw.wav" &
            local sox_pid=$!
            log_info "Started mic recording (PID=${sox_pid})"
            write_pid_sentinel "$OUTPUT" "$sox_pid"
            ;;
        system)
            sox -t coreaudio "$system_device" "${session_dir}/raw.wav" &
            local sox_pid=$!
            log_info "Started system recording (PID=${sox_pid})"
            write_pid_sentinel "$OUTPUT" "$sox_pid"
            ;;
        both)
            sox -t coreaudio "$mic_device" "${session_dir}/mic.wav" &
            local mic_pid=$!
            log_info "Started mic recording (PID=${mic_pid})"
            write_pid_sentinel "$OUTPUT" "$mic_pid"

            sox -t coreaudio "$system_device" "${session_dir}/system.wav" &
            local sys_pid=$!
            log_info "Started system recording (PID=${sys_pid})"
            write_pid_sentinel "$OUTPUT" "$sys_pid"
            ;;
    esac

    # 6. Write .recording sentinel
    write_recording_sentinel "$OUTPUT" "$session_id" "$SOURCE"
    log_info "Recording started. Sentinel files written."

    # 7. Exit immediately — sox runs in background
    exit 0
}

###############################################################################
# ACTION: stop
###############################################################################
action_stop() {
    log_info "Stopping recording (output=${OUTPUT})"

    local pid_file="${OUTPUT}.pid"

    # 1. Read .pid file
    if [[ ! -f "$pid_file" ]]; then
        log_error "No .pid file found at ${pid_file}"
        write_error_sentinel "$OUTPUT" "stop_read_pid" 1 "No .pid file found"
        exit 1
    fi

    # Read all PID entries (may be multiple for --source both)
    local pids=()
    local timestamps=()
    while IFS=: read -r pid ts; do
        pids+=("$pid")
        timestamps+=("$ts")
    done < "$pid_file"

    # 2. Validate and stop each PID
    local stopped_count=0
    for pid in "${pids[@]}"; do
        # Check PID is alive
        if ! kill -0 "$pid" 2>/dev/null; then
            log_error "PID ${pid} is not running (stale)"
            continue
        fi

        # Check process name contains "sox"
        local proc_name
        proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        if [[ "$proc_name" != *sox* ]]; then
            log_error "PID ${pid} is not a sox process (found: ${proc_name})"
            continue
        fi

        # 3. Send SIGINT for graceful stop
        log_info "Sending SIGINT to sox PID ${pid}"
        kill -INT "$pid" 2>/dev/null || true

        # 4. Wait up to 10s for sox to finish
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
            sleep 1
            waited=$((waited + 1))
        done

        # If still running, SIGKILL
        if kill -0 "$pid" 2>/dev/null; then
            log_info "Sox PID ${pid} did not stop in 10s, sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
        fi

        stopped_count=$((stopped_count + 1))
        log_info "Sox PID ${pid} stopped"
    done

    if [[ $stopped_count -eq 0 ]]; then
        write_error_sentinel "$OUTPUT" "stop_validate_pid" 1 "All PIDs were stale or invalid"
        exit 1
    fi

    # 5. Remove .pid file
    rm -f "$pid_file"

    # 6. Write .processing sentinel
    write_processing_sentinel "$OUTPUT" "audio_stopped"
    log_info "Recording stopped. Processing sentinel written."

    exit 0
}

###############################################################################
# ACTION: process
###############################################################################
action_process() {
    log_info "Processing recording (output=${OUTPUT})"

    # 1. Recover session directory from .recording sentinel
    local session_dir
    session_dir=$(recover_session_dir "$OUTPUT") || {
        write_error_sentinel "$OUTPUT" "process_recover_session" 4 "Could not recover session directory"
        exit 4
    }

    local source_from_recording
    source_from_recording=$(_REC_FILE="${OUTPUT}.recording" python3 -c "
import json, os
with open(os.environ['_REC_FILE']) as f:
    data = json.load(f)
print(data.get('source', 'mic'))
" 2>/dev/null) || source_from_recording="$SOURCE"

    log_info "Session directory: ${session_dir}"

    # For --source both, merge audio files first
    local input_wav="${session_dir}/raw.wav"
    if [[ "$source_from_recording" == "both" ]]; then
        log_info "Merging mic and system audio"
        write_processing_sentinel "$OUTPUT" "merging_audio"
        local merge_stderr
        if ! merge_stderr=$(sox -m "${session_dir}/mic.wav" "${session_dir}/system.wav" "${session_dir}/raw.wav" 2>&1); then
            log_error "Failed to merge audio: ${merge_stderr}"
            write_error_sentinel "$OUTPUT" "merging_audio" 1 "$merge_stderr"
            exit 1
        fi
    fi

    # 2. Validate raw wav exists
    if [[ ! -f "$input_wav" ]]; then
        log_error "Raw WAV not found at ${input_wav}"
        write_error_sentinel "$OUTPUT" "process_find_wav" 4 "Raw WAV not found at ${input_wav}"
        exit 4
    fi

    # 3. Convert to 16kHz mono WAV
    write_processing_sentinel "$OUTPUT" "converting_audio"
    log_info "Converting audio to 16kHz mono"

    local ffmpeg_stderr
    if ! ffmpeg_stderr=$(ffmpeg -y -i "$input_wav" -ar 16000 -ac 1 -c:a pcm_s16le "${session_dir}/16k.wav" 2>&1); then
        log_error "ffmpeg conversion failed: ${ffmpeg_stderr}"
        write_error_sentinel "$OUTPUT" "converting_audio" 2 "$ffmpeg_stderr"
        exit 2
    fi

    # 4. Transcribe with whisper-cpp
    write_processing_sentinel "$OUTPUT" "transcribing"
    log_info "Transcribing with whisper-cpp (model=${MODEL_PATH}, language=${LANGUAGE})"

    # Set Metal GPU acceleration
    local brew_prefix
    brew_prefix=$(brew --prefix whisper-cpp 2>/dev/null || echo "/opt/homebrew")
    export GGML_METAL_PATH_RESOURCES="${brew_prefix}/share/whisper-cpp"

    local whisper_stderr
    if ! whisper_stderr=$(whisper-cpp \
        -l "$LANGUAGE" \
        -m "$MODEL_PATH" \
        --output-txt \
        -t 4 \
        -f "${session_dir}/16k.wav" \
        --output-file "${session_dir}/transcript" 2>&1); then
        log_error "whisper-cpp transcription failed: ${whisper_stderr}"
        write_error_sentinel "$OUTPUT" "transcribing" 3 "$whisper_stderr"
        exit 3
    fi

    # 5. Move transcript to target output path
    local transcript_file="${session_dir}/transcript.txt"
    if [[ ! -f "$transcript_file" ]]; then
        log_error "Transcript file not found at ${transcript_file}"
        write_error_sentinel "$OUTPUT" "move_transcript" 4 "Transcript file not found at ${transcript_file}"
        exit 4
    fi

    # Ensure output directory exists
    local output_dir
    output_dir=$(dirname "$OUTPUT")
    mkdir -p "$output_dir"

    if ! cp "$transcript_file" "$OUTPUT"; then
        log_error "Failed to copy transcript to ${OUTPUT}"
        write_error_sentinel "$OUTPUT" "move_transcript" 4 "Failed to copy transcript to ${OUTPUT}"
        exit 4
    fi
    log_info "Transcript written to ${OUTPUT}"

    # 6. Write .done sentinel
    write_done_sentinel "$OUTPUT"

    # 7. Cleanup: remove .recording, .processing, session temp directory
    rm -f "${OUTPUT}.recording"
    rm -f "${OUTPUT}.processing"
    rm -rf "$session_dir"

    log_info "Processing complete. Cleanup done."
    exit 0
}

###############################################################################
# Main dispatch
###############################################################################
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
esac
