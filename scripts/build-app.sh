#!/bin/bash
# Builds build/AirFocus.app: release binary + Info.plist, signed with a stable designated
# requirement so Accessibility and Motion grants survive rebuilds (R§7.3, R§7.4).
#
#   SIGN_IDENTITY=<sha1 or name>  sign with this certificate
#   SIGN_IDENTITY=-               sign ad hoc (with an explicit designated requirement)
#   VERSION=1.2.0 BUILD_NUMBER=7  stamp the version into Info.plist (the release workflow does)
#
# Without SIGN_IDENTITY, the first line of signing-identity.local (untracked) names the certificate.
# Without either, the build is ad hoc. A real certificate keeps the designated requirement stable,
# so Accessibility and Motion grants survive rebuilds; ad hoc builds keep it stable too, but each
# build is a new binary and macOS asks again after an update.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.gshimoon.airfocus"
APP="build/AirFocus.app"
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f signing-identity.local ]; then
  IDENTITY="$(head -n1 signing-identity.local | tr -d '[:space:]')"
fi
IDENTITY="${IDENTITY:--}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AirFocus"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AirFocus"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The menu bar icon (the app falls back to an SF Symbol without it).
cp Support/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"

# The Liquid Glass app icon: actool compiles the Icon Composer document into Assets.car
# (CFBundleIconName). It wants absolute paths. Support/AppIcon.icns is the fallback for anything that
# reads CFBundleIconFile, at full resolution where actool's own .icns stops at 256 px.
ACTOOL_PLIST="$(mktemp -t airfocus-actool)"
if ! ACTOOL_OUTPUT="$(xcrun actool "$PWD/Support/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon \
    --include-all-app-icons --platform macosx --target-device mac --minimum-deployment-target 26.0 \
    --errors --warnings --output-format human-readable-text --output-partial-info-plist "$ACTOOL_PLIST" 2>&1)"; then
  echo "warning: actool failed; shipping Support/AppIcon.icns alone" >&2
fi
grep -E ': (warning|error):' <<< "$ACTOOL_OUTPUT" >&2 || true
rm -f "$ACTOOL_PLIST"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -q -- "$IDENTITY"; then
  echo "warning: signing identity '$IDENTITY' not found in the keychain; falling back to ad-hoc" >&2
  IDENTITY="-"
fi

# Hardened runtime, no entitlements (an entitlement-bearing ad-hoc build gets SIGKILLed by AMFI).
if [ "$IDENTITY" = "-" ]; then
  # Ad-hoc: pin the DR to the bundle id, otherwise it is a cdhash that changes on every build.
  codesign --force --options runtime --timestamp=none --sign - \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
fi

codesign --verify --strict "$APP"
# No pipes here: with pipefail an early-exiting grep would fail the whole line.
SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
AUTHORITY="$(grep -m1 '^Authority=' <<< "$SIGN_INFO" || true)"
echo "signed: ${AUTHORITY:-ad-hoc (Signature=adhoc)}"
echo -n "designated requirement: "
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p'
echo "built $APP"
