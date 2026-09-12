#!/usr/bin/env bash
#
# Builds LidUpAnimation.app and wraps it in a drag-to-Applications DMG at
# dist/LidUpAnimation-<version>.dmg.
#
#   ./build-dmg.sh                       Developer ID via Xcode archive/export,
#                                        notarized and stapled when
#                                        NOTARY_PROFILE is set (default: LidUp)
#   NOTARY_PROFILE= ./build-dmg.sh       Developer ID, skip notarization
#   SIGN_IDENTITY=- ./build-dmg.sh       ad-hoc signature (what CI produces);
#                                        users need Privacy & Security → Open Anyway
#
# The Developer ID certificate is cloud-managed by Xcode, so the signing goes
# through xcodebuild -exportArchive rather than a local codesign identity.
# TEAM_ID defaults to the team in the project.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LidUpAnimation"
DISPLAY_NAME="Lid Up"
BUILD_DIR="build"
DIST_DIR="dist"
TEAM_ID="${TEAM_ID:-542W8Z2VM3}"
SIGN_IDENTITY="${SIGN_IDENTITY:-developer-id}"
NOTARY_PROFILE="${NOTARY_PROFILE-LidUp}"

filter() { grep -E "error:|warning: .*\.swift|SUCCEEDED|FAILED" || true; }

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "Building Release, ad-hoc signed…"
  xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$BUILD_DIR" -destination 'platform=macOS' build \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual | filter
  APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
  [ -d "$APP" ] || { echo "build failed: $APP missing" >&2; exit 1; }
  # An incremental build can keep an older signature.
  codesign --force --deep --sign - "$APP"
  NOTARY_PROFILE=""
else
  echo "Archiving Release…"
  ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
  EXPORT="$BUILD_DIR/export"
  rm -rf "$ARCHIVE" "$EXPORT"
  xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$BUILD_DIR" -archivePath "$ARCHIVE" -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="Apple Development" \
    archive | filter
  OPTIONS=$(mktemp -t exportoptions).plist
  cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
  echo "Exporting with Developer ID…"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath "$EXPORT" -allowProvisioningUpdates | filter
  rm -f "$OPTIONS"
  APP="$EXPORT/$APP_NAME.app"
  [ -d "$APP" ] || { echo "export failed: $APP missing" >&2; exit 1; }
fi

codesign --verify --strict --verbose=1 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^Authority=|TeamIdentifier|flags" | head -3

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "Packaging ${DMG}…"
STAGING=$(mktemp -d)
mkdir -p "$DIST_DIR"
rm -f "$DMG"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "$DISPLAY_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarizing with profile ${NOTARY_PROFILE}…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  # Gatekeeper judges the app, not the (unsigned) disk image.
  MOUNT=$(hdiutil attach -nobrowse -readonly "$DMG" | tail -1 | awk -F'\t' '{print $NF}')
  spctl --assess --type execute -v "$MOUNT/$APP_NAME.app"
  hdiutil detach -quiet "$MOUNT"
fi

shasum -a 256 "$DMG" | tee "$DIST_DIR/$APP_NAME-$VERSION.sha256"
echo "done: $DMG (version $VERSION build $BUILD)"
