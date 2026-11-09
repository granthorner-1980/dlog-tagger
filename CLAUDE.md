# D-Log Tagger

Mac app (+ Python CLI) that detects which DJI log profile (D-Log1 / D-Log2) a clip was shot in, then adds
`_DLOG1`/`_DLOG2` to the filename and an orange/blue Finder tag. See README.md for the full picture.

- `mac/main.swift` – the whole SwiftUI app (detection, Finder tags, UI). Built by `mac/build.sh`
  (`--install` → ~/Applications, `--zip` → release zip). No Xcode project.
- Hidden test mode: `"<app>/Contents/MacOS/DLogTagger" --detect file.MP4…` prints `PROFILE dbcm=… djmd=…`.
  `--folder <path>` opens the window with a folder pre-scanned (used for README screenshots).
- `python/dlog_offload.py` – cross-platform CLI; keep its value tables in sync with `dbcmMap`/`djmdMap`
  in `main.swift` when adding cameras.
- Detection values (Osmo Pocket 4P): dbcm 5 = D-Log1, 2 = D-Log2; djmd field 2.2.3.1: 22 = D-Log1, 2 = D-Log2.
  Learned from the user's own sample clips; no clips are in the repo (and .gitignore blocks video).

## Releasing

Follow RELEASING.md. Preferred: run the **Release** GitHub Action (`gh workflow run release.yml -f version=X.Y.Z
-f whats_new="…"`), after confirming the version number and notes with the user. The user is not a developer
and prefers buttons over Terminal commands; explain steps in plain language.
