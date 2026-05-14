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
ditto -c -k --sequesterRsrc --keepParent macos/WebFinder.app WebFinder.app.zip

git add AGENTS.md CLAUDE.md PRIVACY.md README.md cli/package.json docs/index.html docs/privacy.html ios/WebFinder.xcodeproj/project.pbxproj ios/WebFinder/Info.plist macos/Info.plist scripts
git commit -m "Bump version to $version"
git tag "$tag"
git push origin main "$tag"

gh release create "$tag" WebFinder.app.zip \
  --repo zeulewan/web-finder \
  --title "Web Finder $version" \
  --notes "Web Finder $version release."

echo "Released $tag"
