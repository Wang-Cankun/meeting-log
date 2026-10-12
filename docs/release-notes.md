# Release notes

## 0.1.0

- Turn off **Generate AI summaries** in Settings to keep transcripts only. Azure Speech is then the only service needed, no language model is contacted, and each meeting is archived with its audio, original transcription and readable transcript.
- Configure transcription and summaries entirely in Settings. Choose an audio-capable AI provider or Azure Speech with MAI-Transcribe-2, then test and save the complete configuration once.
- Failed configuration tests preserve saved settings. Correcting Speech credentials or switching transcription services resumes pending recordings without manual file cleanup.
- New installations save meetings under `~/Documents/MeetingLog`; existing archive locations are preserved.
- Local macOS and CI builds use free ad-hoc signing by default. No Apple account, Developer ID certificate, or signing secrets are required. CI builds and verifies `MeetingLog-macOS-arm64.dmg`, containing the signed app and an Applications shortcut. Version tags automatically publish the DMG to GitHub Releases.
- These builds are not notarized. macOS may require approval in System Settings → Privacy & Security when first opening a downloaded copy.

Requires macOS 26 or later on Apple Silicon. AI services use the user's own credentials and may charge separately.
