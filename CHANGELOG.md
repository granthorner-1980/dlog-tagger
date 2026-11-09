# Changelog

What changed in each release of D-Log Tagger. Newest first.

New changes go under **Unreleased** as they're made. When you press **Release** on GitHub, that section
becomes the new version's release notes automatically.

## [Unreleased]

## [1.1.0] - 2026-11-09

### Added
- **Undo** (or ⌘Z) straight after Rename & Tag puts those clips back exactly as they were.
- **Restore Originals…** puts every clip in the folder back to its original name and removes the D-Log
  tags, even for clips renamed long ago. It asks first, keeps your own Finder tags, and skips any clip whose
  original name is already taken.
- **Show in Finder** button opens the chosen folder. Double-click a clip (or right-click → Show in Finder)
  to open Finder with that file selected.

### Fixed
- The clip list now shows new names straight after Rename & Tag, so Restore Originals works without
  pressing Scan Again first.

## [1.0.0] - 2026-11-09

First release.

- Choose a folder and every clip is checked straight away and shown as **D-Log1** or **D-Log2**
  (DJI Osmo Pocket 4P).
- **Rename & Tag** adds `_DLOG1` / `_DLOG2` to filenames and an orange / blue Finder tag.
- Clips already done are skipped; clips it doesn't recognise are left untouched; video data is never
  modified.
- Universal app (Apple Silicon + Intel), macOS 14 or later.

[Unreleased]: https://github.com/granthorner-1980/dlog-tagger/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/granthorner-1980/dlog-tagger/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/granthorner-1980/dlog-tagger/releases/tag/v1.0.0
