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
  -> Gemini transcription coverage gate
  -> project/title inference + evidence-bound summary
  -> project/meetings/session archive
```

## Components

| Component | Owns | Must not own |
|---|---|---|
| `Capture` | Core Audio system-audio scope, screen picker, microphone and media capture | prompts or archive naming |
| `Processing` | chunking, OpenRouter requests, coverage, transcript and summary | UI or permanent root selection |
| `Storage` | Keychain, pending sessions, ASCII paths, final archive writes | capture lifecycle |
| `UI` | menu bar controls and visible state | media or network implementation |
| `Models` | persisted and API boundary types | orchestration |

## Archive format

```text
<root>/
  <project-slug>/
    context.md
    meetings/
      <yyyymmdd-hhmm-title-slug>/
        transcript.md
        summary.md
        audio.m4a
        screen.mov        # only when video was enabled
```

Incomplete sessions remain under `<root>/.pending/<uuid>/` with `session.json`. Startup recovery resumes processing from that manifest.

System audio uses a private Core Audio process tap and aggregate device. All Mac audio is the default; one running application can be selected by bundle identifier. The tap handles preview and writes `system-audio.caf` during recording without using the screen picker.

Microphone capture is optional and writes `microphone.m4a`. After capture stops, both audio sources are mixed into `capture.mov`; the original tracks remain until compressed audio and Markdown outputs complete. Recovery also accepts older sessions that only contain `capture.mov`.

Recording start and stop are single-flight operations. Capture callback failures use the same stop path so every active source is closed. Pending-session recovery does not run during recording, and `capture.mov` becomes visible only after a complete export is atomically moved into place. A successfully stopped recording shorter than 10 seconds is discarded before mixing; capture failures still preserve the session in `.pending`.

ScreenCaptureKit handles optional video only. The Apple content picker selects a display, window, or application after Record Screen is enabled. Video remains 1080p HEVC at 10 FPS and writes directly to `screen.mov`.
