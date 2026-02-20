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

echo ""
echo "Done: $APP"
echo "Run: open $APP"
echo "Or copy to /Applications: cp -r $APP /Applications/"
