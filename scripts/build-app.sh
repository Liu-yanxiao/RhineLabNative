#!/bin/zsh
# Set RHINE_APP_DESTINATION to update an installed bundle without leaving a second app in build/.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)/RhineLab
RHINE_STAGE_ROOT=$(mktemp -d /tmp/rhine-package.XXXXXX)
trap 'rm -rf "$RHINE_STAGE_ROOT"' EXIT
APP="$RHINE_STAGE_ROOT/RhineMusic.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RhineLab"
cp Resources/Fonts/*.ttf Resources/Models/*.glb Resources/Data/archives.json Resources/Data/boot-lettering.json Resources/Data/music-playlists.json Resources/Audio/*.m4a Resources/Audio/*.wav Resources/AppIcon.icns "$APP/Contents/Resources/"
mv "$APP/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/RhineTerminal.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>RhineMusic</string>
  <key>CFBundleDisplayName</key><string>Rhine Music</string>
  <key>CFBundleIdentifier</key><string>local.rhinelab.music.native4</string>
  <key>CFBundleExecutable</key><string>RhineLab</string>
  <key>CFBundleIconFile</key><string>RhineTerminal.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleShortVersionString</key><string>0.4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"
DESTINATION=${RHINE_APP_DESTINATION:-build/RhineMusic.app}
[[ "$DESTINATION" == *.app ]] || { echo "Destination must be an .app bundle" >&2; exit 1; }
mkdir -p "$(dirname "$DESTINATION")"
rm -rf "$DESTINATION"
ditto --norsrc --noextattr "$APP" "$DESTINATION"
echo "Built $DESTINATION"
