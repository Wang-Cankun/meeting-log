# Architecture

> This document owns the system map. Reasons live in `decisions.md`; delivery state lives in `plan.md`.

## Live path

```text
menu bar panel
  -> panel-open system audio + optional microphone level preview
  -> preview stops before recording and when the panel closes
  -> Core Audio process tap: all Mac audio or one application
  -> optional independent microphone capture
  -> optional independent ScreenCaptureKit video capture
  -> pending session directory
  -> system audio + microphone mixdown to compatible capture.mov
  -> compressed audio + optional HEVC video
  -> five-minute audio blocks
  -> configured OpenAI-compatible provider transcription coverage gate
  -> evidence-bound summary in the selected project
  -> project/meetings/session archive
```

## Components

| Component | Owns | Must not own |
|---|---|---|
| `Capture` | Core Audio system-audio scope, screen picker, microphone and media capture | prompts or archive naming |
| `Processing` | chunking, configured provider requests, coverage, transcript and summary | UI or permanent root selection |
| `Storage` | app preferences, pending sessions, project folders, final archive writes | capture lifecycle |
| `UI` | menu bar controls and visible state | media or network implementation |
| `Models` | persisted and API boundary types | orchestration |

## Archive format

```text
<root>/
  <project-name>/
    context.md
    meetings/
      <MMddyyyy><title>/
        transcript.md
        summary.md
        audio.m4a
        screen.mov        # only when video was enabled
```

Incomplete sessions remain under `<root>/.pending/<uuid>/` with `session.json`. Startup recovery resumes processing from that manifest. Pending sessions block archive relocation until they finish; Settings can move them to the Trash when they are no longer wanted.

Project folders are the source of truth and may use Unicode names. Users create projects; the menu bar panel selects the destination project for each recording, falling back to `Inbox` when nothing valid is selected. Completed meeting folders use the recording start date followed immediately by the human-readable title, with `-2`, `-3`, and later suffixes for collisions. The menu panel lists the three most recent completed meetings; deletion moves the complete meeting directory to the macOS Trash.

System audio uses a private Core Audio process tap and aggregate device. All Mac audio is the default; one running application can be selected by bundle identifier. The tap handles preview and writes `system-audio.caf` during recording without using the screen picker.

Microphone capture is optional and writes `microphone.m4a`. Its `AVCaptureSession` configuration, start, and stop operations run on one serial background queue so device transitions never block the main actor. After capture stops, both audio sources are mixed into `capture.mov`; the original tracks remain until compressed audio and Markdown outputs complete. Recovery also accepts older sessions that only contain `capture.mov`.

Recording start and stop are single-flight operations. Capture callback failures use the same stop path so every active source is closed. Pending-session recovery does not run during recording, and `capture.mov` becomes visible only after a complete export is atomically moved into place. Completed outputs move into the selected project before recoverable pending media is cleaned up. A successfully stopped recording shorter than 10 seconds is discarded before mixing; capture failures still preserve the session in `.pending`.

ScreenCaptureKit handles optional video only. The Apple content picker selects a display, window, or application after Record Screen is enabled. Video remains 1080p HEVC at 10 FPS and writes directly to `screen.mov`.

## Imported audio

The import window validates a selected or dropped audio file with AVFoundation, then copies it into a hidden staging directory. Only after the copy and manifest are complete is it moved into the recoverable pending queue. Imports persist the chosen meeting date, project, and original filename. Recovery and processing accept the original audio directly without a capture mixdown. The archive retains `original.<extension>` in addition to `audio.m4a` and the Markdown outputs; the AirDropped source is never moved or deleted. Audio exports become visible atomically after successful completion so a failed export cannot masquerade as a reusable output.
