#!/bin/zsh
# Builds Clipload.app next to this script.
set -e
cd "$(dirname "$0")"
APP=Clipload.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -target arm64-apple-macos14 main.swift Core.swift Views.swift Toast.swift -o $APP/Contents/MacOS/Clipload
rm -rf build/Clipload.iconset && mkdir -p build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift makeicon.swift build/Clipload.iconset
iconutil -c icns build/Clipload.iconset -o $APP/Contents/Resources/Clipload.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Clipload</string>
  <key>CFBundleDisplayName</key><string>Clipload</string>
  <key>CFBundleIdentifier</key><string>local.clipload</string>
  <key>CFBundleExecutable</key><string>Clipload</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>Clipload</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Clipload download link</string>
    <key>CFBundleURLSchemes</key><array><string>clipload</string></array>
  </dict></array>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - $APP
echo "Built $PWD/$APP"
