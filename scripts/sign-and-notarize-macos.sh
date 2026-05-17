#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: scripts/sign-and-notarize-macos.sh APP_PATH [OUTPUT_ZIP]" >&2
  exit 1
fi

app_path="$1"
output_zip="${2:-WebFinder.app.zip}"
sign_identity="${DEVELOPER_ID_APPLICATION:-}"

if [ ! -d "$app_path" ]; then
  echo "App not found: $app_path" >&2
  exit 1
fi

if [ -z "$sign_identity" ]; then
  detected_identities="$(
    security find-identity -v -p codesigning 2>/dev/null |
      awk -F '"' '/Developer ID Application:/ { print $2 }'
  )"
  detected_count="$(printf "%s\n" "$detected_identities" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  if [ "$detected_count" = "1" ]; then
    sign_identity="$(printf "%s\n" "$detected_identities" | sed '/^[[:space:]]*$/d')"
  fi
fi

if [ -z "$sign_identity" ]; then
  echo "DEVELOPER_ID_APPLICATION is required, for example:" >&2
  echo "  export DEVELOPER_ID_APPLICATION=\"Developer ID Application: Your Name (TEAMID)\"" >&2
  echo "" >&2
  echo "Valid signing identities on this Mac:" >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi

if ! command -v xcrun >/dev/null; then
  echo "xcrun is required" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

submit_zip="$tmp_dir/WebFinder-notary-submit.zip"

echo "Signing $app_path..."
codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$sign_identity" \
  "$app_path"
codesign --verify --strict --verbose=2 "$app_path"

echo "Creating notarization upload..."
ditto --norsrc -c -k --keepParent "$app_path" "$submit_zip"

echo "Submitting to Apple notary service..."
asc_key_path="${APP_STORE_CONNECT_KEY_PATH:-}"
asc_key_id="${APP_STORE_CONNECT_KEY_ID:-}"
asc_issuer_id="${APP_STORE_CONNECT_ISSUER_ID:-}"

if [ -z "$asc_key_id" ] && [ -n "$asc_key_path" ]; then
  key_base="$(basename "$asc_key_path")"
  if [[ "$key_base" =~ ^AuthKey_([A-Z0-9]+)\.p8$ ]]; then
    asc_key_id="${BASH_REMATCH[1]}"
  fi
fi

submit_with_api_key() {
  key_file="$1"
  shift
  args=(
    "$submit_zip"
    --key "$key_file"
    --key-id "$asc_key_id"
  )
  if [ -n "$asc_issuer_id" ]; then
    args+=(--issuer "$asc_issuer_id")
  fi
  xcrun notarytool submit "${args[@]}" --wait "$@"
}

if [ -n "${APP_STORE_CONNECT_API_KEY_P8:-}" ] &&
   [ -n "$asc_key_id" ]; then
  key_file="$tmp_dir/AuthKey.p8"
  printf "%s" "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > "$key_file"
  submit_with_api_key "$key_file"
elif [ -n "$asc_key_path" ] &&
     [ -n "$asc_key_id" ]; then
  submit_with_api_key "$asc_key_path"
elif [ -n "${NOTARYTOOL_PROFILE:-}" ]; then
  xcrun notarytool submit "$submit_zip" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ]; then
  xcrun notarytool submit "$submit_zip" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait
else
  echo "Missing notarization credentials." >&2
  echo "Set APP_STORE_CONNECT_KEY_PATH plus APP_STORE_CONNECT_KEY_ID, with APP_STORE_CONNECT_ISSUER_ID for Team API keys," >&2
  echo "or APP_STORE_CONNECT_API_KEY_P8 plus APP_STORE_CONNECT_KEY_ID, with APP_STORE_CONNECT_ISSUER_ID for Team API keys," >&2
  echo "or NOTARYTOOL_PROFILE, or APPLE_ID/APPLE_TEAM_ID/APP_SPECIFIC_PASSWORD." >&2
  exit 1
fi

echo "Stapling notarization ticket..."
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl -a -t exec -vv "$app_path"

# Avoid AppleDouble files in the final archive. This is packaging hygiene, not
# a Gatekeeper bypass; installers should not strip com.apple.quarantine.
xattr -cr "$app_path"
find "$app_path" -name '._*' -delete

echo "Creating distribution zip..."
rm -f "$output_zip"
ditto --norsrc -c -k --keepParent "$app_path" "$output_zip"

echo "Signed and notarized: $output_zip"
