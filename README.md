# MeetingLog

MeetingLog is a personal macOS menu bar app that records all Mac audio or one application's audio, optionally includes a microphone and screen video, and turns each session into an archived transcript and evidence-bound summary. Recording works without an AI provider; processing waits locally until one is configured.

## Start here

1. Run `scripts/build-app.sh` on macOS 26 or later.
2. Open `.build/MeetingLog.app`.
3. Open Settings to choose an archive root and create project folders, then pick the destination project in the menu bar panel. Configure the AI provider in Settings when transcription is needed.
4. Grant system-audio permission. Grant microphone or screen-recording permission only when enabling those sources.

## Routes

| Question | Owner |
|---|---|
| How do I change this repository safely? | `AGENTS.md` |
| Where do capture, processing, and storage connect? | `docs/architecture.md` |
| Why were the current boundaries chosen? | `docs/decisions.md` |
| What is implemented next? | `docs/plan.md` |

## Import an iPhone recording

AirDrop a Voice Memo to Downloads, then click **Import Audio** in MeetingLog. Choose a file or drop it into the import window, select a project, and check the meeting date before importing. M4A, MP3, WAV, AIFF, and CAF are supported. The source file stays untouched; a copy is retained alongside the archived audio and Markdown. Processing uses the configured AI provider, or waits locally when no provider is configured.

Run local import checks with real audio files (provider responses are simulated; no audio is uploaded):

```bash
scripts/check.sh "$HOME/Downloads/New Recording.m4a" "$HOME/Downloads/New Recording 2.m4a"
```
