#!/usr/bin/env bash
set -euo pipefail

ok=1

say() {
  printf '%s\n' "$*"
}

fail() {
  ok=0
  printf 'Missing: %s\n' "$*" >&2
}

say "macOS release doctor"
say ""

if ! command -v xcrun >/dev/null; then
  fail "xcrun"
else
  say "xcrun: ok"
fi

if ! command -v codesign >/dev/null; then
  fail "codesign"
else
  say "codesign: ok"
fi

developer_ids="$(
  security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Developer ID Application:/ { print $2 }'
)"
developer_id_count="$(printf "%s\n" "$developer_ids" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"

if [ "$developer_id_count" = "0" ]; then
  fail "Developer ID Application certificate in Keychain"
elif [ "$developer_id_count" = "1" ]; then
  say "Developer ID Application: $(printf "%s\n" "$developer_ids" | sed '/^[[:space:]]*$/d')"
else
  say "Developer ID Application: $developer_id_count found; set DEVELOPER_ID_APPLICATION explicitly"
fi

asc_key_path="${APP_STORE_CONNECT_KEY_PATH:-}"
asc_key_id="${APP_STORE_CONNECT_KEY_ID:-}"
asc_issuer_id="${APP_STORE_CONNECT_ISSUER_ID:-}"

if [ -z "$asc_key_path" ]; then
  shopt -s nullglob
  local_keys=("$HOME"/.private_keys/AuthKey_*.p8)
  shopt -u nullglob
  if [ "${#local_keys[@]}" = "1" ]; then
    asc_key_path="${local_keys[0]}"
  fi
fi

if [ -z "$asc_key_id" ] && [ -n "$asc_key_path" ]; then
  key_base="$(basename "$asc_key_path")"
  if [[ "$key_base" =~ ^AuthKey_([A-Z0-9]+)\.p8$ ]]; then
    asc_key_id="${BASH_REMATCH[1]}"
  fi
fi

if [ -n "${NOTARYTOOL_PROFILE:-}" ]; then
  say "Notary credentials: NOTARYTOOL_PROFILE=$NOTARYTOOL_PROFILE"
elif [ -n "$asc_key_path" ] && [ -n "$asc_key_id" ]; then
  history_args=(history --key "$asc_key_path" --key-id "$asc_key_id" --output-format json)
  if [ -n "$asc_issuer_id" ]; then
    history_args+=(--issuer "$asc_issuer_id")
  fi
  if xcrun notarytool "${history_args[@]}" >/dev/null 2>&1; then
    if [ -n "$asc_issuer_id" ]; then
      say "Notary credentials: App Store Connect Team API key"
    else
      say "Notary credentials: App Store Connect Individual API key"
    fi
  else
    fail "working App Store Connect notary API credentials"
    say "Found one App Store Connect key candidate under ~/.private_keys"
    say "Key ID: ${asc_key_id:-unknown}"
    if [ -z "$asc_issuer_id" ]; then
      say "Still need: APP_STORE_CONNECT_ISSUER_ID for a Team API key, or a valid Individual API key"
    else
      say "Check: APP_STORE_CONNECT_ISSUER_ID or API key permissions"
    fi
  fi
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ]; then
  say "Notary credentials: Apple ID app-specific password"
else
  fail "notarization credentials"
  if [ -n "$asc_key_path" ]; then
    say "Found one App Store Connect key candidate under ~/.private_keys"
    say "Key ID: ${asc_key_id:-unknown}"
    say "Still need: APP_STORE_CONNECT_ISSUER_ID for a Team API key, a valid Individual API key, NOTARYTOOL_PROFILE, or Apple ID app-specific password"
  fi
fi

say ""
if [ "$ok" = "1" ]; then
  say "Ready for signed/notarized macOS release."
else
  say "Not ready for signed/notarized macOS release."
  exit 1
fi
