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

# Meeting Recorder Skill

## When to Use

Activate this skill when the user wants to:
- **Record** a meeting, standup, sync, call, 1:1, retro, or any audio capture
- **Retrieve** a transcript (phrases like "grab the transcript", "get my notes", "process that meeting")

## Source Selection Heuristics

Infer the audio source from context clues in the user's request:

| User says | Source | Rationale |
|---|---|---|
| "in-person", "standup", "at my desk" | `mic` | Local microphone captures room audio |
| "Teams", "Zoom", "video call", "remote" | `system` | System audio via BlackHole loopback |
| "hybrid", "conference room with remote folks" | `both` | Captures both room and remote participants |
| No context provided | `mic` | Safe default; mic works without extra setup |

## Starting a Recording

1. Determine the `source` using the heuristics above.
2. Call the `start_recording` MCP tool:
   - `source`: one of `mic`, `system`, `both`
   - `meeting_name`: optional, use whatever the user called the meeting (e.g., "standup", "sprint planning")
   - Omit `output_path` to let the server auto-generate one.
3. The tool returns `{status: "recording_started", output_path, source, message}`.
4. **DO NOT poll, wait, or loop after starting.** The recording runs in the background.
5. Tell the user:
   - Recording has started
   - What source is being used
   - To come back when the meeting is done and say something like "grab the transcript"
   - They stop the recording by clicking the menu bar icon

## Retrieving a Transcript

When the user returns and asks for their transcript:

1. Call the `get_transcript` MCP tool.
   - Omit `output_path` to automatically use the most recent session.
   - Only pass `output_path` if the user specifies a particular file.
2. Handle the response based on `status`:

### status: `ready`
Transcript text is in the `transcript` field. Proceed to post-processing (see below).

### status: `recording`
The meeting is still being recorded. Tell the user:
- "The recording is still running. Click the menu bar icon to stop it, then ask me again."

### status: `processing`
Audio is being transcribed. Tell the user:
- The current processing step (from `current_step` field)
- To wait about 30 seconds
- Offer: "Want me to check again in a moment?"

If the user says yes, call `get_transcript` again.

### status: `error`
Something failed. Tell the user:
- Which step failed and the error details (from the `error` field)
- Suggest re-recording if the error is unrecoverable

### ToolError (exception)
No session found. Ask the user:
- "I couldn't find a recent recording session. Do you have the file path for the transcript?"
- If they provide a path, call `get_transcript` with that `output_path`.

## Post-Processing (When Transcript is Ready)

Once you have the transcript text:

### 1. Analyze the transcript
- Summarize the meeting in 3-5 concise bullet points
- Extract action items with owners in **bold** (if identifiable from the conversation)
- Extract key decisions that were made
- Infer meeting metadata: type, attendees, workstreams, whether it is recurring

### 2. Write to Obsidian vault

Use the Obsidian MCP `write_note` tool to create a note in the `20-meetings/` directory.

#### Frontmatter schema (all fields required)

```yaml
---
type: meeting
created: YYYY-MM-DD
updated: YYYY-MM-DD
workstreams:
  - (infer from transcript content)
status: active
tags:
  - meeting
  - (infer type: standup, sync, retro, 1:1, planning, etc.)
meeting-type: standup|sync|retro|1:1|planning|other
attendees:
  - "[[Person Name]]"
recurring: true|false
source: meeting-recorder
---
```

Key rules:
- `created` and `updated` use today's date in `YYYY-MM-DD` format
- `attendees` must use wikilink syntax: `"[[Person Name]]"`
- `meeting-type` is one of: `standup`, `sync`, `retro`, `1:1`, `planning`, `other`
- `workstreams` and `tags` are inferred from the transcript content
- `recurring` is `true` for standups, syncs, retros; `false` for ad-hoc meetings

#### Note structure

```markdown
# Meeting Title

## Summary
- Bullet point 1
- Bullet point 2
- Bullet point 3

## Action Items
- **Owner Name**: Description of action item
- **Owner Name**: Description of action item

## Key Decisions
- Decision that was made
- Another decision

## Raw Transcript
<details>
<summary>Full transcript</summary>

(paste the complete transcript text here)

</details>
```

- The H1 title should be the meeting name if provided, or inferred from the transcript content
- If no action items or decisions are identifiable, include the section with "None identified."
- The raw transcript goes in a collapsible `<details>` block to keep the note scannable
