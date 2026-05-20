#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: scripts/release.sh VERSION [IOS_BUILD]" >&2
  exit 1
fi

version="$1"
ios_build="${2:-}"
tag="v$version"

cd "$(dirname "$0")/.."

if ! command -v gh >/dev/null; then
  echo "gh CLI is required" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Tracked working tree changes must be committed or stashed before release" >&2
  git status --short >&2
  exit 1
fi

if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "Tag $tag already exists" >&2
  exit 1
fi

scripts/bump-version.sh "$version" ${ios_build:+"$ios_build"}

(cd macos && bash build.sh)
rm -f WebFinder.app.zip
if [ -n "${APP_STORE_CONNECT_KEY_PATH:-}" ] ||
   [ -n "${APP_STORE_CONNECT_API_KEY_P8:-}" ] ||
   [ -n "${NOTARYTOOL_PROFILE:-}" ] ||
   { [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ]; }; then
  scripts/sign-and-notarize-macos.sh macos/WebFinder.app WebFinder.app.zip
else
  echo "Signing/notarization skipped. Set notarization credentials for polished macOS releases." >&2
  echo "The signing script will auto-detect a Developer ID Application certificate, or use DEVELOPER_ID_APPLICATION." >&2
  ditto --norsrc -c -k --keepParent macos/WebFinder.app WebFinder.app.zip
fi

git add AGENTS.md CLAUDE.md PRIVACY.md README.md cli/package.json cli/package-lock.json docs/index.html docs/privacy.html ios/WebFinder.xcodeproj/project.pbxproj ios/WebFinder/Info.plist macos/Info.plist macos/build.sh scripts
git commit -m "Bump version to $version"
git tag "$tag"
git push origin main "$tag"

gh release create "$tag" WebFinder.app.zip \
  --repo zeulewan/web-finder \
  --title "WebFinder for Tailscale $version" \
  --notes "WebFinder for Tailscale $version release."

echo "Released $tag"
