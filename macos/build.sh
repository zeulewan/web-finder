#!/bin/bash
set -e

APP="WebFinder.app"
BINARY="WebFinder"

echo "Building $BINARY..."
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp ".build/release/$BINARY" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

# Build icon from iconset or use pre-built .icns
if [ -d "AppIcon.iconset" ]; then
    iconutil -c icns AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
elif [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP/Contents/Resources/"
fi

echo ""
echo "Done: $APP"
echo "Run: open $APP"
echo "Or install: cp -r $APP /Applications/"
