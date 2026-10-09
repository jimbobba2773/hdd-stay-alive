#!/bin/zsh
# Builds "HDD Stay Alive.app" and "HDD Stay Alive.zip" next to this script.
# Works in a temp dir because the project volume's side files break code signing.
VERSION="1.0"
REPO="jimbobba2773/hdd-stay-alive"   # GitHub "owner/repo" whose releases "Check for Updates" looks at
SRC="${0:A:h}"
NAME="HDD Stay Alive"
WORK=$(mktemp -d)
APP="$WORK/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/main.swift" "$WORK/"
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/"
swiftc -O "$WORK/main.swift" -o "$APP/Contents/MacOS/HDDStayAlive" || exit 1
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HDDStayAlive</string>
<key>CFBundleIdentifier</key><string>local.hdd-stay-alive</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>UpdateRepo</key><string>$REPO</string>
<key>LSUIElement</key><true/>
<key>NSRemovableVolumesUsageDescription</key><string>Writes a tiny file to keep your drive awake.</string>
</dict></plist>
PL
codesign --force --deep --sign - "$APP" || exit 1
rm -f "$SRC/$NAME.zip"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$SRC/$NAME.zip"
rm -rf "$SRC/$NAME.app"
ditto --norsrc --noextattr "$APP" "$SRC/$NAME.app"
rm -rf "$WORK"
echo "Built $NAME $VERSION: $NAME.app and $NAME.zip"
