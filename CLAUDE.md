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

## Tests

`python3 tests/test_dlog_tagger.py` (after `mac/build.sh` so the app tests run too). It generates synthetic
Pocket 4P-style and corrupt MP4s at runtime; never commit real footage. Add a case there for any new camera
values or parser change. The Release workflow runs it and won't publish on failure.
Don't run crash tests against the user's installed app in ~/Applications: each crash pops a "quit
unexpectedly" dialog on their screen. Use mac/build/ instead, and don't kill/replace their running app
without telling them.

## Changelog

Every user-visible change (feature, fix, behaviour change) gets a line under `## [Unreleased]` in
CHANGELOG.md, in the same commit, grouped as `### Added` / `### Changed` / `### Fixed`. Write for the
end user (what they'll notice), not for developers. Internal-only changes (CI, refactors) don't need an entry.
Never edit the released sections by hand; the Release workflow stamps them.

## Releasing

Follow RELEASING.md. Preferred: run the **Release** GitHub Action (`gh workflow run release.yml -f version=X.Y.Z`),
after confirming the version number with the user and showing them the Unreleased notes that will be published.
The workflow fails if Unreleased is empty. The user is not a developer and prefers buttons over Terminal
commands; explain steps in plain language.
