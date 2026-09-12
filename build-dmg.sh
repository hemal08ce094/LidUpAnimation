#!/usr/bin/env bash
#
# Builds a Release LidUpAnimation.app and wraps it in a drag-to-Applications
# DMG at dist/LidUpAnimation-<version>.dmg.
#
#   ./build-dmg.sh                 sign with the identity in the Xcode project
#   SIGN_IDENTITY=- ./build-dmg.sh ad-hoc signature (what CI produces)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAM)" ./build-dmg.sh
#   NOTARY_PROFILE=<keychain profile> ./build-dmg.sh   also notarize + staple
#
# Without a Developer ID certificate and notarization, macOS shows
# "Apple could not verify" on first open. The README explains Open Anyway.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LidUpAnimation"
DISPLAY_NAME="Lid Up"
BUILD_DIR="build"
DIST_DIR="dist"
# Default matches the identity in the Xcode project.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

echo "Building Release…"
# "-" means ad-hoc: no team, no timestamp, no hardened runtime.
XCODE_SIGN_ARGS=()
CODESIGN_ARGS=()
if [ "$SIGN_IDENTITY" = "-" ]; then
  XCODE_SIGN_ARGS=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual)
  CODESIGN_ARGS=()
else
  XCODE_SIGN_ARGS=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY")
  CODESIGN_ARGS=(--options runtime --timestamp)
fi

xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" -destination 'platform=macOS' build \
  "${XCODE_SIGN_ARGS[@]}" \
  | grep -E "error:|warning: .*\.swift|BUILD" || true

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "build failed: $APP missing" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"

# Always re-sign: an incremental build can keep the previous signature.
echo "Signing app with ${SIGN_IDENTITY}…"
codesign --force --deep ${CODESIGN_ARGS[@]+"${CODESIGN_ARGS[@]}"} --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "Packaging ${DMG}…"
STAGING=$(mktemp -d)
mkdir -p "$DIST_DIR"
rm -f "$DMG"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "$DISPLAY_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarizing…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DIST_DIR/$APP_NAME-$VERSION.sha256"
echo "done: $DMG (version $VERSION build $BUILD)"
