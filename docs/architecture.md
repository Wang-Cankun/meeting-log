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
  -> ten-minute windows with ten-second overlap, chunked per raw track when both tracks were mixed
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
    meeting_context.md
    meetings/
      <MMddyyyy>-<short-title>/
        transcript.md
        summary.md
        audio.m4a
        screen.mov        # only when video was enabled
```

Incomplete sessions remain under `<root>/.pending/<uuid>/` with `session.json`. Startup recovery resumes processing from that manifest. Pending sessions block archive relocation until they finish; Settings can move them to the Trash when they are no longer wanted.

Project folders are the source of truth and may use Unicode names. Users create projects; the menu bar panel selects the destination project for each recording, using `Inbox` only when no destination was selected. Completed meeting folders use the recording start date followed immediately by the human-readable title, with `-2`, `-3`, and later suffixes for collisions. The menu panel lists the three most recent completed meetings; deletion moves the complete meeting directory to the macOS Trash immediately and offers Undo in the panel.

The panel collapses source settings to a one-line summary with a combined level meter; they expand on request or automatically when a source needs attention. Feedback raised while the panel is open appears inline, because modal alerts detach from a menu bar panel; standalone windows keep standard alerts or SwiftUI confirmations. Reassigning pending meetings from a missing project is confirmed inline. Completed and failed processing posts a notification instead of opening Finder; clicking a completion notification reveals the meeting.

System audio uses a private Core Audio process tap and aggregate device. All Mac audio is the default; one running application can be selected by bundle identifier. The tap handles preview and writes `system-audio.caf` during recording without using the screen picker.

Application discovery never changes the selected scope when an application disappears. The unavailable application remains selected; both the panel and the recording entry point reject starting it until it returns or the user explicitly selects another source. The recording destination cannot change while starting, recording, or stopping.

System-audio writing and its error state belong to the IO queue. The first write failure immediately reports an error and stops positive meter updates. CaptureService forwards it to the existing stop path on the main actor, using a capture generation to reject stale errors and meter callbacks. Stop still throws the retained error after draining the queue.

Microphone capture is optional and writes `microphone.m4a`. Its `AVCaptureSession` configuration, start, and stop operations run on one serial background queue so device transitions never block the main actor. After capture stops, both audio sources are mixed into `capture.mov`; the original tracks remain until compressed audio and Markdown outputs complete. Recovery also accepts older sessions that only contain `capture.mov`.

Recording start and stop are single-flight operations. Capture callback failures use the same stop path so every active source is closed. Pending-session recovery does not run during recording, and `capture.mov` becomes visible only after a complete export is atomically moved into place. Completed outputs move into the selected project before recoverable pending media is cleaned up. A successfully stopped recording shorter than 10 seconds is discarded before mixing; capture failures still preserve the session in `.pending`.

`CapturePreparation` owns raw-track mixing and its persistent `capture-preparation.json` receipt. It writes the complete or system-only plan before exporting and marks it ready only after atomic movie publication. A preparing receipt rebuilds media and invalidates derived audio/transcription caches; a ready receipt reuses the completed movie. Legacy pending sessions with raw tracks rebuild once to establish their inclusion; combined-only legacy sessions remain accepted. A corrupt receipt fails visibly instead of being treated as absent.

If full mixing fails but system-only mixing succeeds, both raw tracks and the receipt survive archiving. Fixed notices are appended to both summaries after translation, and the recent-meeting panel and summary browser display the omission. Regeneration preserves the notice and checks the receipt for concurrent changes. Failed or otherwise idle pending sessions expose Retry and Show files even when saving a failed manifest was impossible. Recovery skips current and queued jobs.

ScreenCaptureKit handles optional video only. The Apple content picker selects a display, window, or application after Record Screen is enabled. Video remains 1080p HEVC at 10 FPS and writes directly to `screen.mov`.

## Imported audio

New audio preparation uses ten-minute blocks with ten-second overlap. Each chunk directory persists its block duration so retries retain the same audio and transcript boundaries; existing chunks from older builds continue using five-minute blocks.

The import window validates a selected or dropped audio file with AVFoundation, then copies it into a hidden staging directory. Only after the copy and manifest are complete is it moved into the recoverable pending queue. Imports persist the chosen meeting date, project, and original filename. Recovery and processing accept the original audio directly without a capture mixdown. After the completed session is archived, its temporary `original.<extension>` or `originals/` copies are removed. The archive retains `audio.m4a`, Markdown, and source metadata; the AirDropped source is never moved or deleted. Audio exports become visible atomically after successful completion so a failed export cannot masquerade as a reusable output.

Multi-file imports commit all source copies as one pending session. Ordered originals live in `originals/`, named by index to avoid filename collisions; `sources.json` preserves original names, order, and durations and stays in the final archive. The manifest also retains source metadata for recovery. Preparation concatenates playback audio but chunks each original independently, so overlap never crosses a source boundary. The transcript labels each recording and states that playback order does not establish continuous conversation or real-world chronology. The user chooses one reference date and project for the complete group; all blocks must succeed before a single summary is archived.

Transcription uses a bounded pool of three concurrent block requests within the active meeting. Results are checkpointed serially as each completes and assembled in source/time order. After a terminal block failure, the pool stops scheduling new work and drains in-flight requests so successful results remain recoverable; retry resumes only incomplete blocks. The meeting queue remains serial, and summary generation starts only after complete coverage. Provider calls make at most three attempts for rate limits, temporary server errors, and transient network failures, with exponential backoff and `Retry-After` support. A 200 response whose body carries an upstream error, or that contains no text, is retried like a temporary server failure. Authentication and other permanent request failures are not automatically retried.

## Speaker attribution from raw tracks

When the capture receipt records a complete mix and both `system-audio.caf` and `microphone.m4a` remain, each ten-minute window is transcribed twice: once from computer audio and once from the microphone. Both use the playback windows, stored under `chunks/system/` and `chunks/microphone/`, and each block records its track in `coverage.json`. The renderer interleaves a window's turns by timestamp under one heading and fixes every microphone turn's label to `Me`; the model's label for that track is ignored. Silence placeholders are dropped when the window has speech. Cleanup removes a `Me` turn that repeats a nearby remote turn, which is loudspeaker echo.

Transcripts keep the spoken language. Rendering converts Traditional Chinese characters to Simplified with the system `Hant-Hans` transform, including cached blocks; it does not change wording or other languages. Every prompt shares one name rule: confirmed Roman spellings from context, otherwise Pinyin, never Chinese characters for a personal name.

Imports, system-only recoveries, legacy combined captures, and sessions whose saved coverage has no track field keep single mixed-audio transcription.

## Readable transcript and bilingual summaries

Upload chunks are mono AAC at 24 kHz and 48 kbps; the archive playback copy retains the normal Apple M4A export quality. Raw capture CAF files never enter provider requests. New chunks are speech-encoded before upload; existing cached chunks retain their previous encoding on retry.

Completed block output is retained as `transcript_raw.md`. One text-only request edits the complete merged transcript into `transcript.md`, removing empty fillers and clear overlap duplicates while preserving recording/excerpt boundaries, timestamps, uncertainty and conversation. Structural rejection falls back to the raw transcript with a note; transport failure leaves the job recoverable. The source remains available for checking any editorial error.

`SummaryEvidence` supplies the original transcription to both summary requests and reference checks. Cleanup output is never the authority for a new summary. Original and Chinese summaries label the evidence filename, and provenance stores it. Regeneration snapshots both transcript files, including absence; only missing raw transcription permits an explicitly labeled legacy fallback. Existing but empty or unreadable raw transcription blocks generation. Adding, editing, or deleting either source after generation blocks saving.

The reviewed summary is saved as `summary.md`; another text-only request produces Mainland Simplified Chinese `summary_cn.md` and a short Chinese folder title. Names, technical terms, exact evidence quotes and metadata remain traceable. Folder names use `MMddyyyy-<short-title>`, bounded to 32 title characters and 96 UTF-8 bytes. Old names remain discoverable. Global and project meeting instructions live in `meeting_context.md`; general `context.md` files are not ingested.

Summary regeneration previews both languages, checks both files for concurrent edits, and backs up both before replacement. Regeneration preserves transcript and folder identity.

The summary browser parses Markdown into headings, lists, indented continuation lines, quotes, and tables with any column count. Evidence references such as `L12` are links: clicking one opens the transcript inspector on the evidence file, highlights that line, and cues `audio.m4a` to the nearest preceding timestamp. Transcript timestamps play from that point. The inspector can switch to the readable copy, which has no line references.

## Nested meeting destinations

Project identity is the archive-relative path, including structural `projects/` and `studies/` segments. Discovery includes top-level folders, direct children of these structural containers, and nested folders with `meeting_context.md` or `meetings/`. It skips hidden directories, symlinks and meeting contents, and does not descend into ordinary unmarked data directories. Unreadable subtrees do not discard accessible siblings; a failure to read the archive root still surfaces. Structural containers with their own meeting context or meetings are also destinations, and a top-level project named `meetings` remains valid. Creating an existing destination preserves its context.

The shared chooser groups destinations by their nearest project ancestor; group headings expand and General meetings selects that ancestor. Search shows parent labels, and the footer exposes the actual save location. Ancestor meeting contexts are read in outer-to-inner order, with more-specific preferences taking precedence. Sibling context is excluded. Recording snapshots the selected relative path in its manifest at start. Missing destinations remain visible and block new routing; retry can explicitly reassign pending meetings to the chosen replacement, preserving completed blocks. Retry waits until capture, import, recovery and the processing queue are idle so saved replacements cannot race with job snapshots.

## Reassigning completed meetings

Recent meeting actions include Move to project. The move window reuses the searchable nested project chooser and moves the complete archive folder without retaining duplicate media. It updates only the project metadata in the current original-language and Chinese summaries; generation provenance and prior revisions keep their historical context. Summary regeneration remains an explicit action after moving. Existing destination names receive numeric suffixes.

The selected meeting's Files menu in All meetings exposes the same move window and protections, so older meetings remain manageable without appearing in the recent three.

AppModel blocks moving during capture/import/processing and while the selected meeting has an active summary generation or unsaved preview. Move events refresh the summary browser and follow the selected meeting to its new location. Storage validates both projects and summary metadata before moving; write failures restore changed metadata and move the folder back. If rollback itself fails, the error reports the retained folder location for recovery.
