# Decisions

> This document owns rationale. Current behavior belongs to code and tests.

| Decision | Status | Consequence |
|---|---|---|
| Personal macOS 26 app | accepted | No accounts, installer, updater, or backward-compatibility paths |
| Native SwiftUI | accepted | Core Audio, ScreenCaptureKit, AVFoundation, Security, and URLSession remain direct dependencies |
| Configurable AI provider | accepted | One user-entered OpenAI-compatible endpoint, model, and API key serve transcription and summary; OpenRouter and Gemini 3.7 Flash remain the defaults |
| Ten-minute blocks with ten-second overlap | accepted | Every block must succeed before final Markdown is written |
| Transcript is evidence | accepted | Unsupported decisions are empty; unsupported context and reasons are empty strings |
| Folder-owned projects | accepted | Users create Unicode project folders and choose the destination per recording in the panel; selection uses its relative path; a missing destination requires an explicit replacement |
| Human-readable meeting folders | accepted | New meetings use `MMddyyyy-<short-title>` and numeric collision suffixes without migration of development archives |
| Recoverable meeting deletion | accepted | The main panel lists three recent completed meetings and moves deleted meetings to the macOS Trash; Settings moves discarded pending sessions to the Trash as well |
| Markdown owns project context | accepted | `<project>/meeting_context.md` supplies names, jargon, aliases, and project-specific instructions |
| Compressed media is retained | accepted | Temporary chunks and imported original copies are deleted only after the final audio and Markdown archive succeeds |
| Zero third-party packages | accepted | A new package requires an observed missing native capability |
| Independent audio and video scope | accepted | System audio selects all Mac audio or one application; the Apple picker selects optional screen video |
| Plain app-preference API key | accepted | The personal app stores its configured API key unencrypted in the current user's preferences instead of Keychain |
| Native settings window | accepted | Archive and AI provider configuration stay out of the recording panel |
| Recording precedes AI configuration | accepted | Missing provider configuration leaves a recoverable local session and never blocks capture |
| Core Audio owns system audio | accepted | System audio uses its dedicated privacy permission; ScreenCaptureKit is requested only for optional video |
| Timer-led recording panel | accepted | The panel shows elapsed time while recording; the menu bar uses a static recording indicator because self-updating SwiftUI content in a `MenuBarExtra` label caused an unbounded redraw loop on macOS 26 |

Prompt changes and evaluation criteria are documented in [prompt quality](prompt-quality.md); project authors can use the [context template](templates/project-context.md).

## Summary regeneration

Saved meetings expose regeneration through All meetings and each recent meeting's action menu. Generation sends only the existing transcript and current global/project context through the draft and evidence-review steps. Users compare the current and proposed Markdown before explicitly saving; generation and cancellation do not replace files.

Saving preserves the existing date, directory, transcript, and media. The proposed summary includes a regenerated full title, and the meeting list reads that title from Markdown. It derives the project from the current folder and rejects a preview if the summary, transcript, or context changed meanwhile. Before atomic replacement, `.summary-history/<revision-id>/` retains `previous.md`, `replacement.md`, and `provenance.json` with the exact prompts, context, endpoint and model (never the API key). A previous summary can be restored by copying `previous.md` back to `summary.md`.

## Operational summary evidence

The schema separates milestones, open questions, deferred work, and infrastructure/documents. Prompts request transcript line references and supporting quotes for these entries, actions, and decisions. Reference checking is advisory: missing references or unmatched quotes never block generation or saving. Unmatched references are labeled unverified and a concise note is added to Needs verification. A matching quote establishes source correspondence, not whether it semantically proves a claim. The review pass checks coverage as well as unsupported claims, with distinct event/transition timings and explicit access deadlines.

Transcript prompts number original lines and scope anonymous speaker labels per section. They do not claim to identify voices across chunks or recover paths visible only on a shared screen. Empty project context is flagged in the regeneration window. Full titles remain intact in Markdown; only folder names have a UTF-8 byte budget. Initial summaries retain exact prompts and provider/model in `summary-provenance.json`; regenerated summaries retain them with the revision history.
