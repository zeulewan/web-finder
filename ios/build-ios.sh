#!/bin/bash
set -e

cd "$(dirname "$0")"

SCHEME="WebFinder"
PROJECT="WebFinder.xcodeproj"
ARCHIVE="build/WebFinder.xcarchive"

echo "==> Cleaning..."
rm -rf build

echo "==> Archiving..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=iOS' \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=NO \
    | tail -3

echo "==> Creating unsigned .app..."
APP_PATH="$ARCHIVE/Products/Applications/WebFinder.app"
if [ -d "$APP_PATH" ]; then
    mkdir -p build
    cp -R "$APP_PATH" build/WebFinder.app
    cd build
    mkdir -p Payload
    cp -R WebFinder.app Payload/
    zip -qr WebFinder.ipa Payload/
    rm -rf Payload WebFinder.app
    echo "==> Built: build/WebFinder.ipa"
else
    echo "Error: Archive failed, no .app found"
    exit 1
fi
