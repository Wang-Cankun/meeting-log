# Decisions

> This document owns rationale. Current behavior belongs to code and tests.

| Decision | Status | Consequence |
|---|---|---|
| Personal macOS 26 app | accepted | No accounts, installer, updater, or backward-compatibility paths |
| Native SwiftUI | accepted | Core Audio, ScreenCaptureKit, AVFoundation, Security, and URLSession remain direct dependencies |
| Gemini 3.7 Flash | accepted | One configured OpenRouter key serves transcription and summary |
| Five-minute blocks with ten-second overlap | accepted | Every block must succeed before final Markdown is written |
| Transcript is evidence | accepted | Unsupported decisions are empty; unsupported context and reasons are empty strings |
| Folder-owned projects | accepted | Users create Unicode project folders; the model selects an existing project or falls back to `Inbox` |
| Human-readable meeting folders | accepted | New meetings use `MMddyyyy<title>` and numeric collision suffixes without migration of development archives |
| Recoverable meeting deletion | accepted | The main panel lists three recent completed meetings and moves deleted meetings to the macOS Trash |
| Markdown owns project context | accepted | `<project>/context.md` supplies names, jargon, aliases, and project-specific instructions |
| Compressed media is retained | accepted | Temporary chunks are deleted only after the final archive succeeds |
| Zero third-party packages | accepted | A new package requires an observed missing native capability |
| Independent audio and video scope | accepted | System audio selects all Mac audio or one application; the Apple picker selects optional screen video |
| Native settings window | accepted | Archive and OpenRouter configuration stay out of the recording panel |
| Recording precedes AI configuration | accepted | Missing OpenRouter credentials leave a recoverable local session and never block capture |
| Core Audio owns system audio | accepted | System audio uses its dedicated privacy permission; ScreenCaptureKit is requested only for optional video |
| Timer-led recording panel | accepted | The panel shows elapsed time while recording; the menu bar uses a static recording indicator because self-updating SwiftUI content in a `MenuBarExtra` label caused an unbounded redraw loop on macOS 26 |
