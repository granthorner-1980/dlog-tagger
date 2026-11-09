#!/bin/zsh
# Builds "D-Log Tagger.app" into mac/build/.
#   ./build.sh            build only
#   ./build.sh --install  build, then copy into ~/Applications
#   ./build.sh --zip      build, then make a zip for sharing (GitHub release)
# Needs Xcode or the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "${0:A:h}"

VERSION="1.2.0"
MIN_MACOS="14.0"
OUT="build"
APP="$OUT/D-Log Tagger.app"

# In-app updates (Sparkle). The feed lists new versions; the public key checks that each
# download was signed by our Release workflow before it is installed.
FEED_URL="https://github.com/granthorner-1980/dlog-tagger/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="+TqPIWrUWWfycQIdqWsKDJByR+q4Kg3UXJ1jRlFLmp4="

# Sparkle framework: downloaded once into vendor/ (not committed), pinned and checksum-verified.
SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
SPARKLE="vendor/Sparkle-$SPARKLE_VERSION"
if [[ ! -d "$SPARKLE/Sparkle.framework" ]]; then
  mkdir -p vendor
  TARBALL="vendor/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL -o "$TARBALL" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  if [[ "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" != "$SPARKLE_SHA256" ]]; then
    rm -f "$TARBALL"; echo "Sparkle download failed its checksum check - stopping." >&2; exit 1
  fi
  rm -rf "$SPARKLE" && mkdir -p "$SPARKLE"
  tar -xJf "$TARBALL" -C "$SPARKLE"
  rm -f "$TARBALL"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Universal binary: Apple Silicon + Intel
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" main.swift -o "$OUT/DLogTagger-$arch" \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
done
lipo -create "$OUT/DLogTagger-arm64" "$OUT/DLogTagger-x86_64" -output "$APP/Contents/MacOS/DLogTagger"
rm -f "$OUT"/DLogTagger-*
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"   # keeps its symlinks

# App icon: draw it (if needed), scale to every size macOS wants, pack into .icns
[[ -f icon.png ]] || swift make_icon.swift icon.png
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>D-Log Tagger</string>
  <key>CFBundleDisplayName</key><string>D-Log Tagger</string>
  <key>CFBundleIdentifier</key><string>io.github.granthorner-1980.dlogtagger</string>
  <key>CFBundleExecutable</key><string>DLogTagger</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>To find and rename the clips you offloaded.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>To find and rename the clips you offloaded.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>To find and rename clips on your card.</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SURequireSignedFeed</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature (not notarised): fine on the Mac that built it.
codesign --force -s - "$APP"   # Sparkle.framework keeps its own signature
echo "Built $PWD/$APP"

case "${1:-}" in
  --install)
    mkdir -p ~/Applications
    rm -rf ~/Applications/"D-Log Tagger.app"
    cp -R "$APP" ~/Applications/
    echo "Installed to ~/Applications/D-Log Tagger.app"
    ;;
  --zip)
    ZIP="$OUT/DLogTagger-$VERSION-macOS.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Zipped $PWD/$ZIP"
    ;;
esac
