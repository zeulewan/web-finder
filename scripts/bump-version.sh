#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: scripts/bump-version.sh VERSION [IOS_BUILD]" >&2
  exit 1
fi

version="$1"
ios_build="${2:-}"

case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *)
    echo "Version must look like X.Y.Z" >&2
    exit 1
    ;;
esac

cd "$(dirname "$0")/.."

if [ -z "$ios_build" ]; then
  current_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' ios/WebFinder/Info.plist 2>/dev/null || echo 0)"
  ios_build="$((current_build + 1))"
fi

node -e '
const fs = require("fs");
const file = "cli/package.json";
const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
pkg.version = process.argv[1];
fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");
' "$version"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" macos/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" macos/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" ios/WebFinder/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ios_build" ios/WebFinder/Info.plist

perl -0pi -e "s/MARKETING_VERSION = [0-9]+\\.[0-9]+\\.[0-9]+;/MARKETING_VERSION = $version;/g; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $ios_build;/g" ios/WebFinder.xcodeproj/project.pbxproj
perl -0pi -e "s/<span class=\"badge\">v[0-9]+\\.[0-9]+\\.[0-9]+<\\/span>/<span class=\"badge\">v$version<\\/span>/g" docs/index.html

echo "Bumped WebFinder to $version (iOS build $ios_build)"
