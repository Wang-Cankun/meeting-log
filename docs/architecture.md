# Architecture

> This document owns the system map. Reasons live in `decisions.md`; delivery state lives in `plan.md`.

## Live path

```text
menu bar panel
  -> panel-open system audio + optional microphone level preview
  -> preview stops before recording and when the panel closes
  -> ScreenCaptureKit audio capture: all Mac audio or one application
  -> optional independent ScreenCaptureKit video capture
  -> pending session directory
  -> compressed audio + optional HEVC video
  -> five-minute audio blocks
  -> Gemini transcription coverage gate
  -> project/title inference + evidence-bound summary
  -> project/meetings/session archive
```

## Components

| Component | Owns | Must not own |
|---|---|---|
| `Capture` | system-audio scope, screen picker, microphone preflight, media capture | prompts or archive naming |
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

System audio and screen video use separate ScreenCaptureKit filters. The Apple content picker selects video only. New recordings write audio to `capture.mov` and optional 10 FPS video directly to `screen.mov`; recovery still accepts older sessions where both lived in `capture.mov`.
