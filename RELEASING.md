# Releasing a new version

## The easy way (no commands)

1. Make sure your changes are pushed to `main` on GitHub.
2. Check **[CHANGELOG.md](CHANGELOG.md)**: everything that changed since the last release should be listed
   under **Unreleased**. These become the release notes. (Claude adds entries there as it makes changes; you
   can also edit the file on GitHub with the ✏️ pencil button.)
3. Go to **[Actions → Release](https://github.com/granthorner-1980/dlog-tagger/actions/workflows/release.yml)**.
4. Click **Run workflow** (top right of the list), then fill in:
   - **New version number** – one higher than the [latest release](https://github.com/granthorner-1980/dlog-tagger/releases/latest):
     - `1.0.0 → 1.0.1` for fixes only
     - `1.0.0 → 1.1.0` for new features
     - `1.0.0 → 2.0.0` for a big change
   - **Extra line** – optional, shown above the list of changes, e.g. *"Thanks to everyone who sent test clips!"*
5. Click the green **Run workflow** button. After about 3–5 minutes the new release appears on the
   [Releases page](https://github.com/granthorner-1980/dlog-tagger/releases) with the zip and notes attached.

GitHub builds the app on its own Mac, updates the version number in `mac/build.sh`, moves the
**Unreleased** notes in CHANGELOG.md under the new version number (with today's date), tags it, and publishes
the release. It also signs the update and publishes `appcast.xml` with it, so everyone on 1.2.0 or later gets
an "update available" prompt in the app (within a day, or straight away via **Check for Updates…**). If something goes wrong, the run shows a red ✗ and nothing is published – click it to see why.
The usual reasons: that version number already exists, or nothing is listed under Unreleased.
Run it from the **main** branch (the default) – the signing key is locked to main, so other branches fail.

**Not sure it'll work?** Tick **Test only** – it builds the zip and shows the release notes it *would* use
on the run's summary page, but publishes nothing. The zip appears under *Artifacts* at the bottom of that page.

Then, so your own Mac has the new version too: open Terminal in this folder and run
`git pull && mac/build.sh --install`, or just download it from the release like everyone else.

## The update signing key – keep it safe

Updates are signed with a private key so the app can tell they really came from you. It's stored in two
places:

- **GitHub** – the `SPARKLE_PRIVATE_KEY` secret in the protected **release** environment
  (Settings → Environments → release). Nobody can read it there, and only the Release workflow running on
  `main` can use it.
- **Your Mac's keychain** – the backup. In Keychain Access, search for **dlog-tagger**
  ("Private key for signing Sparkle updates").

**Don't lose it.** Without the key you can't ship updates the app will accept, and everyone would have to
download the next version by hand. Also save a copy in your password manager: in Terminal run
`mac/vendor/Sparkle-*/bin/generate_keys --account dlog-tagger -x ~/Desktop/dlog-key.txt`, store the file's
contents, then delete the file. To put it back on GitHub (e.g. on a new repo):
`gh secret set SPARKLE_PRIVATE_KEY --env release < ~/Desktop/dlog-key.txt`.

The matching public key is `SPARKLE_PUBLIC_KEY` in `mac/build.sh`; it's fine for that to be public. Never
change it – apps already out there only trust updates signed with the original key.

## Or ask Claude

Open this folder in Claude Code and say *"release a new version"* – it will follow this file.

## Doing it by hand (if GitHub Actions is ever unavailable)

```bash
# 1. edit VERSION="x.y.z" near the top of mac/build.sh, then:
.github/scripts/changelog.sh unreleased > /tmp/notes.md     # this release's notes
.github/scripts/changelog.sh stamp X.Y.Z "$(date +%Y-%m-%d)"  # move them under the new version
cd mac && ./build.sh --zip
cd .. && git commit -am "Release vX.Y.Z" && git tag vX.Y.Z && git push --follow-tags
# 2. sign the update and write the feed (uses the key in your keychain)
SIG=$(mac/vendor/Sparkle-*/bin/sign_update --account dlog-tagger -p mac/build/DLogTagger-X.Y.Z-macOS.zip)
python3 .github/scripts/appcast.py X.Y.Z 14.0 \
  https://github.com/granthorner-1980/dlog-tagger/releases/download/vX.Y.Z/DLogTagger-X.Y.Z-macOS.zip \
  mac/build/DLogTagger-X.Y.Z-macOS.zip "$SIG" /tmp/notes.md > mac/build/appcast.xml
mac/vendor/Sparkle-*/bin/sign_update --account dlog-tagger mac/build/appcast.xml
gh release create vX.Y.Z mac/build/DLogTagger-X.Y.Z-macOS.zip mac/build/appcast.xml \
  --title "D-Log Tagger X.Y.Z" --notes-file /tmp/notes.md
```

Every release **must** include `appcast.xml`, or the app's update check stops finding new versions.
