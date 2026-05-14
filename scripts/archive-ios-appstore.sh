#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: scripts/archive-ios-appstore.sh VERSION" >&2
  exit 1
fi

version="$1"

cd "$(dirname "$0")/.."

archive="ios/build/appstore/WebFinder-$version.xcarchive"
export_dir="ios/build/appstore/export-$version"

rm -rf "$archive" "$export_dir"
mkdir -p ios/build/appstore

xcodebuild archive \
  -project ios/WebFinder.xcodeproj \
  -scheme WebFinder \
  -configuration Release \
  -archivePath "$archive" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates

echo "Archive created: $archive"
echo "Attempting App Store Connect export/upload. This requires valid Xcode/App Store Connect credentials."

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist ios/exportOptions.plist \
  -exportPath "$export_dir" \
  -allowProvisioningUpdates
