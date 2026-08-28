# Decisions

> This document owns rationale. Current behavior belongs to code and tests.

| Decision | Status | Consequence |
|---|---|---|
| Personal macOS 26 app | accepted | No accounts, installer, updater, or backward-compatibility paths |
| Native SwiftUI | accepted | Core Audio, ScreenCaptureKit, AVFoundation, Security, and URLSession remain direct dependencies |
| Configurable AI provider | accepted | One user-entered OpenAI-compatible endpoint, model, and API key serve transcription and summary; OpenRouter and Gemini 3.7 Flash remain the defaults |
| Five-minute blocks with ten-second overlap | accepted | Every block must succeed before final Markdown is written |
| Transcript is evidence | accepted | Unsupported decisions are empty; unsupported context and reasons are empty strings |
| Folder-owned projects | accepted | Users create Unicode project folders and choose the destination per recording in the panel; a missing or renamed selection falls back to `Inbox` |
| Human-readable meeting folders | accepted | New meetings use `MMddyyyy<title>` and numeric collision suffixes without migration of development archives |
| Recoverable meeting deletion | accepted | The main panel lists three recent completed meetings and moves deleted meetings to the macOS Trash; Settings moves discarded pending sessions to the Trash as well |
| Markdown owns project context | accepted | `<project>/context.md` supplies names, jargon, aliases, and project-specific instructions |
| Compressed media is retained | accepted | Temporary chunks are deleted only after the final archive succeeds |
| Zero third-party packages | accepted | A new package requires an observed missing native capability |
| Independent audio and video scope | accepted | System audio selects all Mac audio or one application; the Apple picker selects optional screen video |
| Plain app-preference API key | accepted | The personal app stores its configured API key unencrypted in the current user's preferences instead of Keychain |
| Native settings window | accepted | Archive and AI provider configuration stay out of the recording panel |
| Recording precedes AI configuration | accepted | Missing provider configuration leaves a recoverable local session and never blocks capture |
| Core Audio owns system audio | accepted | System audio uses its dedicated privacy permission; ScreenCaptureKit is requested only for optional video |
| Timer-led recording panel | accepted | The panel shows elapsed time while recording; the menu bar uses a static recording indicator because self-updating SwiftUI content in a `MenuBarExtra` label caused an unbounded redraw loop on macOS 26 |
