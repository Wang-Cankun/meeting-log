# Decisions

> This document owns rationale. Current behavior belongs to code and tests.

| Decision | Status | Consequence |
|---|---|---|
| Personal macOS 26 app | accepted | No accounts, installer, updater, or backward-compatibility paths |
| Native SwiftUI | accepted | ScreenCaptureKit, AVFoundation, Security, and URLSession remain direct dependencies |
| Gemini 3.7 Flash | accepted | One configured OpenRouter key serves transcription and summary |
| Five-minute blocks with ten-second overlap | accepted | Every block must succeed before final Markdown is written |
| Transcript is evidence | accepted | Unsupported decisions are empty; unsupported context and reasons are empty strings |
| Project-centered archive | accepted | The model infers ASCII project and title slugs and creates missing project directories |
| Markdown owns project context | accepted | `<project>/context.md` supplies names, jargon, aliases, and project-specific instructions |
| Compressed media is retained | accepted | Temporary chunks are deleted only after the final archive succeeds |
| Zero third-party packages | accepted | A new package requires an observed missing native capability |
| Independent audio and video scope | accepted | System audio selects all Mac audio or one application; the Apple picker selects optional screen video |
| Native settings window | accepted | Archive and OpenRouter configuration stay out of the recording panel |
