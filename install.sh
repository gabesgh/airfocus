#!/bin/bash
# Installs or updates AirFocus from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/gabesgh/airfocus/main/install.sh | bash
#
# Set AIRFOCUS_INSTALL_DIR to install somewhere other than /Applications,
# and AIRFOCUS_NO_OPEN=1 to skip launching it afterwards.
set -euo pipefail

REPO="gabesgh/airfocus"
BUNDLE_ID="com.gshimoon.airfocus"
DIR="${AIRFOCUS_INSTALL_DIR:-/Applications}"
APP="$DIR/AirFocus.app"
BASE="https://github.com/$REPO/releases/latest/download"

fail() { echo "airfocus: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "AirFocus is a macOS app."
[[ "$(uname -m)" == "arm64" ]] || fail "AirFocus needs a Mac with Apple silicon."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 26 )) || fail "AirFocus needs macOS 26 Tahoe or later."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading the latest AirFocus release..."
curl -fsSL "$BASE/AirFocus.zip" -o "$tmp/AirFocus.zip" || fail "download failed. Is there a release yet?"
curl -fsSL "$BASE/AirFocus.zip.sha256" -o "$tmp/AirFocus.zip.sha256" || fail "checksum download failed."

expected="$(awk '{print $1}' "$tmp/AirFocus.zip.sha256")"
actual="$(shasum -a 256 "$tmp/AirFocus.zip" | awk '{print $1}')"
[[ "$expected" == "$actual" ]] || fail "checksum mismatch, not installing."

ditto -x -k "$tmp/AirFocus.zip" "$tmp/unpacked"
codesign --verify --strict "$tmp/unpacked/AirFocus.app" || fail "the app's signature doesn't verify."

updating=0
if [[ -d "$APP" ]]; then
  updating=1
  pkill -f "$APP/Contents/MacOS/AirFocus" 2>/dev/null || true
  sleep 0.5
fi

mkdir -p "$DIR"
if [[ -w "$DIR" ]]; then
  rm -rf "$APP"
  ditto "$tmp/unpacked/AirFocus.app" "$APP"
else
  echo "Installing into $DIR needs your password."
  sudo rm -rf "$APP"
  sudo ditto "$tmp/unpacked/AirFocus.app" "$APP"
fi

# Each release is a new build, so the old permission entries no longer match
# it. Clearing them lets AirFocus ask again cleanly instead of failing silently.
if (( updating )); then
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset Motion "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

version="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Installed AirFocus $version in $DIR."

if [[ "${AIRFOCUS_NO_OPEN:-0}" != "1" ]]; then
  open "$APP"
  echo "AirFocus will ask for Accessibility and Motion & Fitness access. Allow both, then press ⌃⌥⌘C to calibrate."
fi
