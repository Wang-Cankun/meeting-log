# MeetingLog

MeetingLog is a personal macOS menu bar app that records all Mac audio or one application's audio, optionally includes a microphone and screen video, and turns each session into an archived transcript and evidence-bound summary. Recording works without an OpenRouter key; processing waits locally until one is configured.

## Start here

1. Run `scripts/build-app.sh` on macOS 26 or later.
2. Open `.build/MeetingLog.app`.
3. Open Settings to choose an archive root. Add an OpenRouter model and API key when transcription is needed.
4. Grant system-audio permission. Grant microphone or screen-recording permission only when enabling those sources.

## Routes

| Question | Owner |
|---|---|
| How do I change this repository safely? | `AGENTS.md` |
| Where do capture, processing, and storage connect? | `docs/architecture.md` |
| Why were the current boundaries chosen? | `docs/decisions.md` |
| What is implemented next? | `docs/plan.md` |
