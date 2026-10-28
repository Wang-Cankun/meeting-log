# Release notes

## 0.2.0

- Azure Speech now distinguishes voices on the microphone track, and the chat microphone prompt asks to transcribe everyone speaking in the room. Online captures label microphone speech `Me`; in-person captures retain anonymous speaker letters and label computer speech `Computer`. See [speaker attribution and limitations](architecture.md#speaker-attribution-from-raw-tracks).
- Complete captures keep each speech phrase at its own time, including Azure Speech turns within the same displayed second. Earlier builds joined the whole microphone track into one `Me` turn at its first phrase. Azure Speech phrases on a capture track are split at pauses, so a reply sits between the remote sentences around it. When only one track falls back to smaller windows, the transcript follows those windows and interleaves replies within each section.
- Online Azure Speech captures remove microphone echoes before saving raw summary evidence, while retaining replies after the remote sentence and unrelated speech. The [echo rule](decisions.md#capture-transcript-attribution) requires phrase durations; it keeps text-only cached and chat-model turns.
- The readable transcript keeps short `Me` replies such as "Okay.". It can remove wordless sounds such as "Mm-hmm." between another speaker's turns.
- Archived meetings keep their transcripts, and archiving removes the separate tracks unless **Keep original audio tracks** is on. Re-importing an archived `audio.m4a` transcribes the mixed audio with diarization, so the recording user becomes a lettered speaker instead of `Me`. Retry reuses completed cached microphone text; a transcript already labeled `Me` keeps that label.
- Turn on **Keep original audio tracks** in Settings → Projects & storage to keep each recording's separate microphone and computer audio in its meeting folder. It is off by default; computer audio takes about 1.4 GB per recorded hour.

## 0.1.0

- Turn off **Generate AI summaries** in Settings to keep transcripts only. Azure Speech is then the only service needed, no language model is contacted, and each meeting is archived with its audio, original transcription and readable transcript.
- Configure transcription and summaries entirely in Settings. Choose an audio-capable AI provider or Azure Speech with MAI-Transcribe-2, then test and save the complete configuration once.
- Failed configuration tests preserve saved settings. Correcting Speech credentials or switching transcription services resumes pending recordings without manual file cleanup.
- New installations save meetings under `~/Documents/MeetingLog`; existing archive locations are preserved.
- Local macOS and CI builds use free ad-hoc signing by default. No Apple account, Developer ID certificate, or signing secrets are required. CI builds and verifies `MeetingLog-macOS-arm64.dmg`, containing the signed app and an Applications shortcut. Version tags automatically publish the DMG to GitHub Releases.
- These builds are not notarized. macOS may require approval in System Settings → Privacy & Security when first opening a downloaded copy.

Requires macOS 26 or later on Apple Silicon. AI services use the user's own credentials and may charge separately.
