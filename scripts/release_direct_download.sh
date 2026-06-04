#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-Sloucher}"
PROJECT="${PROJECT:-Sloucher.xcodeproj}"
SCHEME="${SCHEME:-Sloucher}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-DerivedData/Release}"
BUILD_ROOT="${BUILD_ROOT:-build/release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_ROOT/$APP_NAME.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_ROOT/export}"
DIST_PATH="${DIST_PATH:-dist}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
  echo "Set DEVELOPER_ID_APPLICATION to your full Developer ID Application certificate name." >&2
  echo "Example: Developer ID Application: Your Name (TEAMID)" >&2
  exit 64
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Set NOTARY_PROFILE to a notarytool keychain profile name." >&2
  echo "Create one with: rtk xcrun notarytool store-credentials sloucher-notary" >&2
  exit 64
fi

mkdir -p "$BUILD_ROOT" "$DIST_PATH"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

archive_args=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -derivedDataPath "$DERIVED_DATA_PATH"
  -archivePath "$ARCHIVE_PATH"
  clean archive
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
  ENABLE_HARDENED_RUNTIME=YES
)

if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  archive_args+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

xcodebuild "${archive_args[@]}"

export_options="$BUILD_ROOT/ExportOptions.plist"
{
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingCertificate</key>
  <string>$DEVELOPER_ID_APPLICATION</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
PLIST
  if [[ -n "$DEVELOPMENT_TEAM" ]]; then
    cat <<PLIST
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM</string>
PLIST
  fi
  cat <<PLIST
</dict>
</plist>
PLIST
} > "$export_options"

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$export_options"

app_path="$EXPORT_PATH/$APP_NAME.app"
info_plist="$app_path/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
zip_path="$DIST_PATH/$APP_NAME-$version+$build.app.zip"
dmg_path="$DIST_PATH/$APP_NAME-$version.dmg"
dmg_root="$BUILD_ROOT/dmg-root"

codesign --verify --strict --deep --verbose=2 "$app_path"

rm -f "$zip_path"
ditto -c -k --keepParent "$app_path" "$zip_path"
xcrun notarytool submit "$zip_path" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

rm -rf "$dmg_root"
mkdir -p "$dmg_root"
cp -R "$app_path" "$dmg_root/"
ln -s /Applications "$dmg_root/Applications"

rm -f "$dmg_path"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$dmg_root" \
  -format UDZO \
  -ov \
  "$dmg_path"

codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"
xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg_path"
spctl --assess --type open --verbose=4 "$dmg_path"

echo "Release DMG: $dmg_path"
