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
  -> with a speech service: one MAI-Transcribe-2 request per recording, file, or raw track
     otherwise: ten-minute windows with ten-second overlap, chunked per raw track when both tracks were mixed
  -> transcription coverage gate
  -> evidence-bound summary in the selected project (skipped when AI summaries are off)
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

Project folders are the source of truth and may use Unicode names. Users create projects; the menu bar panel selects the destination project for each recording, using `Inbox` only when no destination was selected. Completed meeting folders use the recording start date followed immediately by the human-readable title, with `-2`, `-3`, and later suffixes for collisions. The panel's Recent list shows up to three pending sessions as status cards (processing with its stage bar, queued, failed with Retry and Show files, or waiting for a provider) above the three most recent completed meetings; clicking a meeting opens it in Meeting summaries. Deletion moves the complete meeting directory to the macOS Trash immediately and offers Undo in the panel.

The panel collapses source settings to a one-line summary with separate mini meters per audio source; they expand on request or automatically when a source needs attention. Feedback raised while the panel is open appears inline, because modal alerts detach from a menu bar panel; standalone windows keep standard alerts or SwiftUI confirmations. Reassigning pending meetings from a missing project is confirmed inline. Completed and failed processing posts a notification instead of opening Finder; clicking a completion notification reveals the meeting.

System audio uses a private Core Audio process tap and aggregate device. All Mac audio is the default; one running application can be selected by bundle identifier. The tap handles preview and writes `system-audio.caf` during recording without using the screen picker.

Application discovery never changes the selected scope when an application disappears. The unavailable application remains selected; both the panel and the recording entry point reject starting it until it returns or the user explicitly selects another source. The recording destination cannot change while starting, recording, or stopping.

System-audio writing and its error state belong to the IO queue. The first write failure immediately reports an error and stops positive meter updates. CaptureService forwards it to the existing stop path on the main actor, using a capture generation to reject stale errors and meter callbacks. Stop still throws the retained error after draining the queue.

Microphone capture is optional and writes `microphone.m4a`. Its `AVCaptureSession` configuration, start, and stop operations run on one serial background queue so device transitions never block the main actor. After capture stops, both audio sources are mixed into `capture.mov`; the original tracks remain until compressed audio and Markdown outputs complete. Archiving then removes them unless **Keep original audio tracks** is on in Storage settings; the setting is read when processing starts. Recovery also accepts older sessions that only contain `capture.mov`. Between Stop and hand-off the app is in a saving phase: it reports `CapturePreparation` mixing progress to the panel and keeps audio previews off, so reopening the panel cannot restart capture devices while tracks are still being mixed. Saving outcomes reached while the panel is closed (failure, or a discarded short recording) post a notification.

During recording the microphone capture timer also reports raw dBFS (the higher of average and peak hold), separate from the meter scale, which is clamped at −60 dBFS. `MicrophoneSilenceMonitor` raises an inline warning when an included microphone stays at or below −96 dBFS for 30 s; a missing audio channel after the first reading counts as silence. Two seconds of input end the episode, and system notifications are at least five minutes apart within a recording.

Recording start and stop are single-flight operations. Capture callback failures use the same stop path so every active source is closed. Pending-session recovery does not run during recording, and `capture.mov` becomes visible only after a complete export is atomically moved into place. Completed outputs move into the selected project before recoverable pending media is cleaned up. A successfully stopped recording shorter than 10 seconds is discarded before mixing; capture failures still preserve the session in `.pending`.

`CapturePreparation` owns raw-track mixing and its persistent `capture-preparation.json` receipt. It writes the complete or system-only plan before exporting and marks it ready only after atomic movie publication. A preparing receipt rebuilds media and invalidates derived audio/transcription caches; a ready receipt reuses the completed movie. Legacy pending sessions with raw tracks rebuild once to establish their inclusion; combined-only legacy sessions remain accepted. A corrupt receipt fails visibly instead of being treated as absent.

If full mixing fails but system-only mixing succeeds, both raw tracks and the receipt survive archiving. Fixed notices are appended to both summaries after translation, and the recent-meeting panel and summary browser display the omission. Regeneration preserves the notice and checks the receipt for concurrent changes. Failed or otherwise idle pending sessions expose Retry and Show files even when saving a failed manifest was impossible. Recovery skips current and queued jobs.

ScreenCaptureKit handles optional video only. The Apple content picker selects a display, window, or application after Record Screen is enabled. Video remains 1080p HEVC at 10 FPS and writes directly to `screen.mov`.

## Imported audio

New audio preparation uses ten-minute blocks with ten-second overlap. Each chunk directory persists its block duration so retries retain the same audio and transcript boundaries; existing chunks from older builds continue using five-minute blocks.

The import window validates a selected or dropped audio file with AVFoundation, then copies it into a hidden staging directory. Only after the copy and manifest are complete is it moved into the recoverable pending queue. Imports persist the chosen meeting date, project, and original filename. Recovery and processing accept the original audio directly without a capture mixdown. After the completed session is archived, its temporary `original.<extension>` or `originals/` copies are removed. The archive retains `audio.m4a`, Markdown, and source metadata; the AirDropped source is never moved or deleted. Audio exports become visible atomically after successful completion so a failed export cannot masquerade as a reusable output.

Multi-file imports commit all source copies as one pending session. Ordered originals live in `originals/`, named by index to avoid filename collisions; `sources.json` preserves original names, order, and durations and stays in the final archive. The manifest also retains source metadata for recovery. Preparation concatenates playback audio but chunks each original independently, so overlap never crosses a source boundary. The transcript labels each recording and states that playback order does not establish continuous conversation or real-world chronology. The user chooses one reference date and project for the complete group; all blocks must succeed before a single summary is archived.

Transcription uses a bounded pool of concurrent block requests within the active meeting: eight for chat-model windows, three for speech-service uploads. Results are checkpointed serially as each completes and assembled in source/time order. After a terminal block failure, the pool stops scheduling new work and drains in-flight requests so successful results remain recoverable; retry resumes only incomplete blocks. The meeting queue remains serial, and summary generation starts only after complete coverage. Provider calls make at most three attempts for rate limits, temporary server errors, and transient network failures, with exponential backoff and `Retry-After` support. A 200 response whose body carries an upstream error, or that contains no text, is retried like a temporary server failure. Authentication and other permanent request failures are not automatically retried.

## Speaker attribution from raw tracks

When the capture receipt records a complete mix and both `system-audio.caf` and `microphone.m4a` remain, processing transcribes computer audio and microphone separately. Azure Speech normally transcribes each whole track; the chat-model path uses ten-minute windows. The chat microphone prompt requests every room voice and a new turn at each pause or speaker change. Blocks retain their track in `coverage.json`; speech-service blocks also retain millisecond starts and available phrase durations.

Equal-start capture windows share one section. If one track spans two or more fallback windows of the other, the finer windows define the headings and their bounds. Each turn from the covering track goes to the section with the latest start at or before that turn. Speaker letters remain local to each section, so readable-transcript cleanup cannot join speakers across fallback windows.

Within a section, the renderer interleaves turns by millisecond start and preserves input order for ties. Chat output and older checkpoints without that precision use their parsed whole-second starts. Markdown turns still use `[MM:SS] Speaker: text`. The speech path keeps one raw turn per phrase part; the readable transcript joins adjacent turns from the same speaker. Silence placeholders use `Speaker` and disappear when the section contains speech.

The renderer classifies the complete transcript once using the [online test](decisions.md#capture-transcript-attribution), then applies that result to every section. Online captures label microphone speech `Me`. Otherwise, room voices keep anonymous letters and the renderer labels computer speech `Computer`. The introduction in that case is:

> Speakers below were recorded by the microphone; their letters are anonymous within each section. Turns labeled Computer come from computer audio.

In hybrid meetings classified as online, every microphone voice is `Me`, including other people in the room. Retry retains a legacy cached microphone transcript's existing `Me` label, even when the meeting now classifies as in-person.

Transcripts keep the spoken language. Rendering converts Traditional Chinese characters to Simplified with the system `Hant-Hans` transform, including cached blocks; it does not change wording or other languages. Every prompt shares one name rule: confirmed Roman spellings from context, otherwise Pinyin, never Chinese characters for a personal name.

Imports, system-only recoveries, legacy combined captures, and sessions whose saved coverage has no track field keep single mixed-audio transcription.

## Speech-service transcription

Settings verifies the selected transcription service and summary provider together before saving either. Verification sends a JSON text probe and one second of generated silence, including audio-input validation when the chat provider handles transcription. Successful saving resumes pending recordings with the complete configuration. Speech authentication errors identify the speech service without invalidating the summary provider. Switching from whole-file speech to chat-model windows rebuilds incompatible transcription checkpoints from retained audio.

When AI summaries are off, Settings verifies and saves Azure Speech alone and `MeetingProcessor` runs without a provider client. After the coverage gate it writes `transcript_raw.md` and the locally tidied `transcript.md`, skips the summary, evidence and Chinese steps, and archives under `MMddyyyy-会议 HHmm` (recording start) or the first imported file's name. Without a speech service such a job fails as a configuration error and stays pending. `recentMeetings` lists a folder with `transcript.md` and no `summary.md` as transcript-only; moving it rewrites no file, and Meeting summaries shows its transcript without summary actions.

When Settings holds an Azure Speech endpoint and key, `SpeechTranscriber` replaces chat-model transcription and the provider handles text steps only. Each fast transcription request uploads 16 kHz mono 16-bit FLAC to MAI-Transcribe-2 in clean style with word timestamps, with diarization on for every track, including the microphone. A request normally covers the whole recording, one imported file, or one raw capture track. A phrase list supplies names and terms from the project and global context, most specific first. Diarized phrases become `[MM:SS] Speaker X:` turns locally and pass the same timestamp validation as model output. A single-track section joins a speaker's consecutive phrases. Azure keeps one speaker's sentences in one phrase across a pause, and on a capture track the other track's reply sits in that pause, so a capture-track phrase is split where its words pause for at least 500 ms; each part is one turn for the renderer to interleave.

A response whose phrases share one offset, or run past the section, lost its timing and is rejected. A section over fifteen minutes that fails for any reason other than authentication or cancellation is split into the standard overlapping ten-minute windows and retried; finished sections are kept. Azure reports a slow upload as a 400 form error, which is retried as a timeout. The readable transcript comes from local rules instead of an LLM pass (see decisions).

## Readable transcript and bilingual summaries

Upload chunks are mono AAC at 24 kHz and 48 kbps; the archive playback copy retains the normal Apple M4A export quality. Raw capture CAF files never enter provider requests. New chunks are speech-encoded before upload; existing cached chunks retain their previous encoding on retry.

`MeetingProcessor` writes the merged transcript to `transcript_raw.md` after attribution and any speech-path echo filtering ([rule](decisions.md#capture-transcript-attribution)). With a speech service, `TranscriptPolisher.tidy` derives `transcript.md` locally without rewording. Otherwise one text-only request edits the complete merged transcript into `transcript.md`, removing empty fillers and clear overlap duplicates while preserving recording/excerpt boundaries, timestamps, uncertainty and conversation. Structural rejection falls back to the raw transcript with a note; transport failure leaves the job recoverable. The source remains available for checking any editorial error.

`SummaryEvidence` supplies the original transcription to both summary requests and reference checks. Cleanup output is never the authority for a new summary. Original and Chinese summaries label the evidence filename, and provenance stores it. Regeneration snapshots both transcript files, including absence; only missing raw transcription permits an explicitly labeled legacy fallback. Existing but empty or unreadable raw transcription blocks generation. Adding, editing, or deleting either source after generation blocks saving.

The reviewed summary is saved as `summary.md`; another text-only request produces Mainland Simplified Chinese `summary_cn.md` and a short Chinese folder title. Names, technical terms, exact evidence quotes and metadata remain traceable. Folder names use `MMddyyyy-<short-title>`, bounded to 32 title characters and 96 UTF-8 bytes. Old names remain discoverable. Global and project meeting instructions live in `meeting_context.md`; general `context.md` files are not ingested.

Summary regeneration previews both languages, checks both files for concurrent edits, and backs up both before replacement. Regeneration preserves transcript and folder identity.

Meeting summaries has three columns: Library and the project tree (nested like the chooser, with a parent's own meetings under General meetings), a date-grouped meeting list, and the selected summary with a transcript inspector. Search covers titles, project paths and both summary languages. Project names show underscores as spaces; folder names are unchanged. A parent's General meetings row appears only when the parent holds meetings of its own. Summary text, snippets and audio durations load off the main actor and are cached by modification date; the archive scan runs off the main actor too. The document keeps a readable measure (at most 720 pt) and has no footer bar; the provider, model and evidence file appear in the Regenerate button's help. The transcript inspector opens by default and remembers whether the user closed it.

`SummaryDocument` splits a summary into typed sections and reads action items from the list format and legacy tables; anything else renders as generic Markdown blocks. Evidence references such as `L12` are chips, dashed when unverified. Inline `[needs verification]` markers (and `[待核实]` in Chinese summaries) render as a small amber warning sign and are dropped from list snippets and from the Needs verification callout, whose whole block already says so; the files are unchanged. Action cards show Owner and Due tags only for stated values. A chip's popover quotes that line of the evidence file with its speaker and time, and can play `audio.m4a` from the nearest preceding timestamp or reveal and highlight the line in the inspector. The inspector shows speaker colours, seekable timestamps, and scrubber marks at the shown summary's evidence; it can switch to the readable copy, which has no line references.

Debug builds can render the window without Screen Recording permission: `MeetingLog --render-summaries <out-dir> [--meeting <folder>] [--scope <project>] [--query <text>] [--no-inspector] [--show-line <n>] [--popover <n>] [--document] [--appearance light|dark|both]` reads the installed app's archive read-only, starts no capture, preview or processing, writes PNGs and exits. Liquid Glass panes are repainted flat in these images, so sidebar icons and speaker dots may be missing or discoloured; layout and type are faithful. Release builds do not contain the hook.

Debug builds render the menu bar panel the same way: `MeetingLog --render-panel <out-dir> [--state <name>] [--appearance light|dark|both]` writes `panel-<n>-<state>-<appearance>.png` for fixed fixture states (sources collapsed and expanded, microphone permission denied, recording with no input, saving, Recent with processing and failed cards, a long project path). It uses fixture projects and meetings, an absent archive root and argument-domain settings, so it reads and writes nothing of the installed app's; `AppModel(startsServices: false)` also keeps panel open and close from previewing, enumerating sources or rereading the archive. The offscreen window is drawn as key, but system switches still draw their inactive colour. Release builds do not contain the hook.

## Nested meeting destinations

Project identity is the archive-relative path, including structural `projects/` and `studies/` segments. Discovery includes top-level folders, direct children of these structural containers, and nested folders with `meeting_context.md` or `meetings/`. It skips hidden directories, symlinks and meeting contents, and does not descend into ordinary unmarked data directories. Unreadable subtrees do not discard accessible siblings; a failure to read the archive root still surfaces. Structural containers with their own meeting context or meetings are also destinations, and a top-level project named `meetings` remains valid. Creating an existing destination preserves its context.

The shared chooser groups destinations by their nearest project ancestor; group headings expand and General meetings selects that ancestor. Search shows parent labels, and the footer exposes the actual save location. Ancestor meeting contexts are read in outer-to-inner order, with more-specific preferences taking precedence. Sibling context is excluded. Recording snapshots the selected relative path in its manifest at start. Missing destinations remain visible and block new routing; retry can explicitly reassign pending meetings to the chosen replacement, preserving completed blocks. Retry waits until capture, import, recovery and the processing queue are idle so saved replacements cannot race with job snapshots.

## Reassigning completed meetings

Recent meeting actions include Move to project. The move window reuses the searchable nested project chooser and moves the complete archive folder without retaining duplicate media. It updates only the project metadata in the current original-language and Chinese summaries; generation provenance and prior revisions keep their historical context. Summary regeneration remains an explicit action after moving. Existing destination names receive numeric suffixes.

The More menu in Meeting summaries exposes the same move window and protections, so older meetings remain manageable without appearing in the recent three.

AppModel blocks moving during capture/import/processing and while the selected meeting has an active summary generation or unsaved preview. Move events refresh the summary browser and follow the selected meeting to its new location. Storage validates both projects and summary metadata before moving; write failures restore changed metadata and move the folder back. If rollback itself fails, the error reports the retained folder location for recovery.
