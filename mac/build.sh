#!/bin/zsh
# Builds "D-Log Tagger.app" into mac/build/.
#   ./build.sh            build only
#   ./build.sh --install  build, then copy into ~/Applications
#   ./build.sh --zip      build, then make a zip for sharing (GitHub release)
# Needs Xcode or the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "${0:A:h}"

VERSION="1.1.0"
MIN_MACOS="14.0"
OUT="build"
APP="$OUT/D-Log Tagger.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: Apple Silicon + Intel
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" main.swift -o "$OUT/DLogTagger-$arch"
done
lipo -create "$OUT/DLogTagger-arm64" "$OUT/DLogTagger-x86_64" -output "$APP/Contents/MacOS/DLogTagger"
rm -f "$OUT"/DLogTagger-*

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
</dict>
</plist>
PLIST

# Ad-hoc signature (not notarised): fine on the Mac that built it.
codesign --force --deep -s - "$APP"
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
