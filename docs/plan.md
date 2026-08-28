# Implementation plan

## Goal

A personal menu bar app can record a real Zoom or Teams meeting, recover the source after interruption, and produce a complete project archive without manual file handling.

## Delivery status

### 1. Repository and contracts: complete

Create the app target, storage types, prompts, and deterministic path rules.

**Exit proof:** `scripts/check.sh` and `swift build` pass.

### 2. Capture: implemented

Record all Mac audio or one application's audio through a Core Audio process tap, optional selected microphone audio, and independent optional 1080p 10 fps HEVC screen capture. Opening the panel previews levels without writing media.

**Exit proof:** a short local recording contains both audio tracks and optional video.

### 3. Processing and recovery: implemented

Split audio, enforce block coverage, generate Markdown, archive the session, and resume pending sessions after launch.

**Exit proof:** a short recording reaches a final archive; a forced API failure leaves a recoverable pending session.

### 4. Recording panel and settings: implemented

Use a compact timer-led panel with persistent Mac audio and microphone rows, optional screen video, menu-bar recording time, system appearance, and a foreground Settings window. Recording remains available without OpenRouter; unprocessed sessions wait locally.

**Exit proof:** the panel and Settings lifecycle pass a real app check in both system appearances.

The code and signed app bundle pass local checks. A real five-minute recording remains the hardware and permission acceptance check because it requires the user's selected output route and privacy grants. OpenRouter is required only to verify post-recording processing.
