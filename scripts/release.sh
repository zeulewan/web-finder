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

npm ci --prefix cli
npm --prefix cli audit --audit-level=high
npm --prefix cli run check

(cd macos && bash build.sh)
rm -f WebFinder.app.zip
scripts/doctor-macos-release.sh
scripts/sign-and-notarize-macos.sh macos/WebFinder.app WebFinder.app.zip

git add -A
git commit -m "Bump version to $version"
git tag "$tag"
git push origin main "$tag"

gh release create "$tag" WebFinder.app.zip \
  --repo zeulewan/web-finder \
  --title "WebFinder for Tailscale $version" \
  --notes-file RELEASE_NOTES.md

echo "Released $tag"
