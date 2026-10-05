#!/bin/zsh
# Build RhineLab.app into ./build (release by default, `debug` for a debug build).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)/RhineLab
APP=build/RhineLab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RhineLab"
cp Resources/Fonts/*.ttf Resources/Models/*.glb Resources/Data/*.json Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>RhineLab</string>
  <key>CFBundleDisplayName</key><string>Rhine Lab</string>
  <key>CFBundleIdentifier</key><string>local.rhinelab.analysisos</string>
  <key>CFBundleExecutable</key><string>RhineLab</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
