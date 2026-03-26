"""MCP Server for meeting recording and transcription."""

import datetime
import json
import os
import re
import subprocess

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError

mcp = FastMCP("MeetingRecorder")

SESSION_REGISTRY = os.path.expanduser("~/.config/meeting-recorder/current-session.json")
PIPELINE_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "pipeline", "meeting-pipeline.sh")

_CONFIG_PATH = os.path.expanduser("~/.config/meeting-recorder/config.json")
_CONFIG_DEFAULTS: dict = {
    "micDevice": "MacBook Pro Microphone",
    "systemDevice": "BlackHole 2ch",
    "whisperModelPath": "~/models/ggml-large-v3-turbo-q5_0.bin",
    "language": "en",
    "defaultOutputDir": "~/Documents/meeting-transcripts/",
    "defaultSource": "mic",
}


def _read_config() -> dict:
    """Read config from ~/.config/meeting-recorder/config.json with defaults."""
    config = dict(_CONFIG_DEFAULTS)
    try:
        with open(_CONFIG_PATH, "r") as f:
            user_config = json.load(f)
        config.update(user_config)
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return config


def _sanitize_filename(name: str) -> str:
    """Sanitize a string for use in filenames."""
    name = name.lower()
    name = re.sub(r"[^a-z0-9\-_]", "-", name)
    name = re.sub(r"-{2,}", "-", name)
    name = name.strip("-")
    name = name[:64]
    return name


@mcp.tool
def start_recording(
    source: str = "mic",
    output_path: str | None = None,
    meeting_name: str | None = None,
) -> dict:
    """Start recording a meeting. Returns session info and output path."""
    # 1. Validate source
    if source not in ("mic", "system", "both"):
        raise ToolError(f"Invalid source '{source}'. Must be one of: mic, system, both")

    # 2. Generate output_path if not provided
    if output_path is None:
        config = _read_config()
        output_dir = os.path.expanduser(config.get("defaultOutputDir", _CONFIG_DEFAULTS["defaultOutputDir"]))
        os.makedirs(output_dir, exist_ok=True)

        timestamp = datetime.datetime.now().strftime("%Y-%m-%dT%H-%M")
        name_slug = _sanitize_filename(meeting_name) if meeting_name else "meeting"
        output_path = os.path.join(output_dir, f"{timestamp}-{name_slug}.md")

    # 3. Check for existing recording
    if os.path.exists(f"{output_path}.recording"):
        raise ToolError(f"A recording is already in progress at {output_path}")

    # 4. Read config for model path and language
    config = _read_config()
    model_path = os.path.expanduser(config.get("whisperModelPath", _CONFIG_DEFAULTS["whisperModelPath"]))
    language = config.get("language", _CONFIG_DEFAULTS["language"])

    # 5. Launch pipeline
    subprocess.Popen([
        PIPELINE_SCRIPT,
        "--source", source,
        "--output", output_path,
        "--model-path", model_path,
        "--language", language,
        "--action", "start",
    ])

    # 6. Write session registry
    os.makedirs(os.path.dirname(SESSION_REGISTRY), exist_ok=True)
    session_data = {
        "output_path": output_path,
        "source": source,
        "meeting_name": meeting_name or "meeting",
        "started_at": datetime.datetime.now().isoformat(),
    }
    with open(SESSION_REGISTRY, "w") as f:
        json.dump(session_data, f, indent=2)

    # 7. Return
    return {
        "status": "recording_started",
        "output_path": output_path,
        "source": source,
        "message": "Recording started. The MeetingRecorder app is now recording. Tell me when you're ready to grab the transcript.",
    }


@mcp.tool
def get_transcript(output_path: str | None = None) -> dict:
    """Retrieve transcript from a completed recording. Omit output_path to use the most recent session."""
    # 1. Resolve output_path from session registry if not provided
    if output_path is None:
        try:
            with open(SESSION_REGISTRY, "r") as f:
                session = json.load(f)
            output_path = session["output_path"]
        except FileNotFoundError:
            raise ToolError("No output_path provided and no current session found. Start a recording first.")
        except (json.JSONDecodeError, KeyError):
            raise ToolError("Session registry is corrupted. Please provide an explicit output_path.")

    # 2. Check sentinel files in priority order

    # .error
    error_file = f"{output_path}.error"
    if os.path.exists(error_file):
        try:
            with open(error_file, "r") as f:
                error_data = json.load(f)
        except (json.JSONDecodeError, OSError):
            error_data = {"step": "unknown", "exit_code": -1, "stderr": "Could not read error file"}
        step = error_data.get("step", "unknown")
        return {
            "status": "error",
            "output_path": output_path,
            "error": error_data,
            "message": f"Processing failed at step '{step}': {error_data.get('stderr', 'unknown error')}",
        }

    # .done
    done_file = f"{output_path}.done"
    if os.path.exists(done_file):
        try:
            with open(output_path, "r") as f:
                transcript = f.read()
        except OSError as e:
            raise ToolError(f"Transcript file could not be read: {e}")
        return {
            "status": "ready",
            "output_path": output_path,
            "transcript": transcript,
        }

    # .processing
    processing_file = f"{output_path}.processing"
    if os.path.exists(processing_file):
        try:
            with open(processing_file, "r") as f:
                current_step = f.read().strip()
        except OSError:
            current_step = "unknown"
        return {
            "status": "processing",
            "output_path": output_path,
            "current_step": current_step,
            "message": f"Audio is being processed (current step: {current_step}). Try again in 30 seconds.",
        }

    # .recording
    recording_file = f"{output_path}.recording"
    if os.path.exists(recording_file):
        return {
            "status": "recording",
            "output_path": output_path,
            "message": "Still recording. Stop the recording in the menu bar app first, then try again.",
        }

    # 3. No sentinel files found
    raise ToolError(f"No session found at {output_path}. No sentinel files exist.")


if __name__ == "__main__":
    mcp.run()
