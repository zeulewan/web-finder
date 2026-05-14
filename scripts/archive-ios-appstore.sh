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
auth_args=()

if [ -n "${APP_STORE_CONNECT_KEY_PATH:-}" ] || [ -n "${APP_STORE_CONNECT_KEY_ID:-}" ] || [ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]; then
  if [ -z "${APP_STORE_CONNECT_KEY_PATH:-}" ] || [ -z "${APP_STORE_CONNECT_KEY_ID:-}" ] || [ -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]; then
    echo "Set all three: APP_STORE_CONNECT_KEY_PATH, APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID" >&2
    exit 1
  fi
  auth_args=(
    -authenticationKeyPath "$APP_STORE_CONNECT_KEY_PATH"
    -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID"
    -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
  )
fi

rm -rf "$archive" "$export_dir"
mkdir -p ios/build/appstore

xcodebuild archive \
  -project ios/WebFinder.xcodeproj \
  -scheme WebFinder \
  -configuration Release \
  -archivePath "$archive" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  "${auth_args[@]}"

echo "Archive created: $archive"
echo "Attempting App Store Connect export/upload. This requires valid Xcode/App Store Connect credentials."

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist ios/exportOptions.plist \
  -exportPath "$export_dir" \
  -allowProvisioningUpdates \
  "${auth_args[@]}"
