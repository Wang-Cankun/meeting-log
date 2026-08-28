# MeetingLog agent guide

## Constraints

- Use SwiftUI and Apple frameworks. Add a dependency only for an observed missing capability.
- Support macOS 26 on Apple Silicon. Do not add compatibility branches without a real target device.
- Preserve recorded media until compressed media and Markdown outputs are complete.
- Treat the transcript as evidence. Summary fields must trace to transcript or project context.
- Keep project and meeting folder names human-readable and Unicode-safe; reject filesystem control characters and reserve dot-prefixed names for app storage.

## Verification

```bash
scripts/check.sh
swift build
```

`scripts/build-app.sh` assembles and ad-hoc signs the local app bundle.

## Routing

| Touching | Read first |
|---|---|
| Capture, permissions, media tracks | `docs/architecture.md` |
| Prompts, archive format, project inference | `docs/decisions.md` |
| Delivery order or deferred work | `docs/plan.md` |
