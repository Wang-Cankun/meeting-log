# MeetingLog

MeetingLog is a personal macOS menu bar app that records all Mac audio or one application's audio, optionally includes a microphone and screen video, and turns each session into an archived transcript and evidence-bound summary. Recording works without an AI provider; processing waits locally until one is configured.

## Start here

1. Run `scripts/build-app.sh` on macOS 26 or later.
2. Open `.build/MeetingLog.app`.
3. Open Settings to choose an archive root and create project folders, then pick the destination project in the menu bar panel. New installations default to `~/Documents/MeetingLog`; existing archive locations are kept. In **AI processing**, choose **AI provider** for a model that accepts audio, or **Azure Speech · MAI-Transcribe-2** and enter your Speech resource endpoint and key. With **Generate AI summaries** on (the default), also enter the summary provider's OpenAI-compatible base URL, model ID, and key. Turn it off to keep transcripts only: Azure Speech is then the only service needed, and no language model is contacted. Click **Test & save** once for the entire configuration.
4. Grant system-audio permission. Grant microphone or screen-recording permission only when enabling those sources.

The destination project stays locked while starting, recording, and stopping. If the selected audio application closes, it stays selected and recording is blocked until it returns or you choose another source. MeetingLog never changes that selection to all Mac audio automatically.

Settings tests JSON output and sends one second of generated silence to the selected transcription service. Both services must pass before any configuration changes are saved or pending recordings resume. Failed tests keep your previous configuration. With MAI, the summary model needs text support only; without MAI, its audio input is tested too. With AI summaries on you always need a summary provider. With them off, only Azure Speech is tested and saved; a saved summary provider is kept, unused, for when summaries are turned back on. All of this setup is available in Settings, with no configuration files or shell commands. Changing the transcription selection takes effect after **Test & save** succeeds.

Failed recordings stay local. **Retry** resumes their recovery, and **Show files** opens the pending recordings, even when a disk error prevented saving the failure status. If recovery can use only system audio, the completed meeting shows a partial-recovery warning and keeps both original tracks for manual recovery.

## Routes

| Question | Owner |
|---|---|
| How do I change this repository safely? | `AGENTS.md` |
| Where do capture, processing, and storage connect? | `docs/architecture.md` |
| Why were the current boundaries chosen? | `docs/decisions.md` |
| What is implemented next? | `docs/plan.md` |
| What changed in this release? | `docs/release-notes.md` |

## Build and distribution

Local macOS and CI builds use the same `scripts/build-app.sh` script and free ad-hoc signing by default. No Apple account, Developer ID certificate, or signing secrets are needed. The GitHub Actions build produces `MeetingLog-macOS-arm64.zip`, preserving the signed app bundle and executable permissions. These builds are not notarized; macOS may require approval in System Settings → Privacy & Security on first launch after download. Signing is free; AI provider usage and any applicable CI runner charges are separate.

## Import an iPhone recording

AirDrop a Voice Memo to Downloads, then click **Import Audio** in MeetingLog. Choose a file or drop it into the import window, select a project, and check the meeting date before importing. M4A, MP3, WAV, AIFF, and CAF are supported. The source file stays untouched; the app keeps its imported copy until compressed audio and Markdown are complete, then removes that extra copy. Processing uses the configured AI provider, or waits locally when no provider is configured.

Run local import checks with real audio files (provider responses are simulated; no audio is uploaded):

```bash
scripts/check.sh "$HOME/Downloads/New Recording.m4a" "$HOME/Downloads/New Recording 2.m4a"
```

For a meeting captured in several recordings, add all related files to one import. Use the up/down controls to set their playback order, remove unwanted files, and choose one project and archive date. MeetingLog produces one transcript and summary, with labeled source boundaries, plus combined playback audio. The completed archive keeps combined audio and source metadata; temporary imported originals are removed. Unrelated meetings should be imported separately.

Transcription submits up to three audio blocks concurrently, saves completed results for retry, and restores their original order before summarizing. Rate limits and temporary provider failures use delayed retries.

### Regenerate a saved summary

**All meetings** opens Meeting summaries: pick a project in the sidebar, search titles and summaries, and select a meeting. Click any `L` reference in a summary to see the quoted transcript line, then **Play from** it or **Show in transcript**; click a timestamp in the transcript to play the recording from there.

To regenerate, choose **Regenerate** in Meeting summaries, or **Regenerate summary…** in a recent meeting's menu. Update the project context if needed, then generate. The app uses the saved transcript, uploads no audio, and shows the current and proposed Markdown side by side. Choose **Save new summary** to replace it with a backup, or **Discard preview** to keep the original. Previous versions and generation provenance live in the meeting's hidden `.summary-history` folder.

The **More** menu in Meeting summaries also offers **Move to project…**, including for older meetings. Moving remains disabled during processing or an unsaved summary preview.

## Meeting files

Use `meeting_context.md` at the archive root and in each project for meeting-specific names, aliases, and preferences. General project `context.md` is separate.

New meetings use short Chinese folder names such as `09112026-空间多组学与R21课题合作`. The full title remains in Markdown. Uploads use 10-minute mono AAC chunks at 48 kbps, not the raw recording.

When a recording includes the microphone, MeetingLog transcribes it separately from computer audio, so your own turns are labeled `Me`. Other participants keep anonymous letters unless the conversation identifies them.

Each new completed meeting includes `audio.m4a`, `transcript_raw.md`, the edited `transcript.md`, `summary.md`, and Mainland Simplified Chinese `summary_cn.md`. Cleanup removes empty fillers and obvious overlap duplicates while retaining conversation; the raw transcript remains the evidence backup. Summary regeneration previews and saves both languages. Existing transcripts are not automatically rewritten. Meetings processed with AI summaries off contain only `audio.m4a`, `transcript_raw.md` and `transcript.md`, in a folder named from the recording's start time (`MMddyyyy-会议 HHmm`) or the first imported file's name. Meeting summaries shows their transcript; they have no summary to regenerate.

New summaries and regenerated summaries use `transcript_raw.md` for generation, evidence review, and quoted line references. The readable `transcript.md` remains for browsing. Old meetings without raw transcription explicitly fall back to `transcript.md`; an empty or unreadable raw file is an error. Both summary languages identify the evidence file, and saving rejects a preview if either transcript or the recording recovery details changed meanwhile.
