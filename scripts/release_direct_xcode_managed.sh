#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-Sloucher}"
PROJECT="${PROJECT:-Sloucher.xcodeproj}"
SCHEME="${SCHEME:-Sloucher}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-9MXC88C783}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-DerivedData/XcodeManagedRelease}"
BUILD_ROOT="${BUILD_ROOT:-build/xcode-managed-release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_ROOT/$APP_NAME.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_ROOT/export}"
UPLOAD_PATH="${UPLOAD_PATH:-$BUILD_ROOT/upload-output}"
DIST_PATH="${DIST_PATH:-dist}"
MAX_STAPLE_ATTEMPTS="${MAX_STAPLE_ATTEMPTS:-30}"
STAPLE_SLEEP_SECONDS="${STAPLE_SLEEP_SECONDS:-60}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"

mkdir -p "$BUILD_ROOT" "$DIST_PATH"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$UPLOAD_PATH"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -archivePath "$ARCHIVE_PATH" \
  clean archive \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  ENABLE_HARDENED_RUNTIME=YES \
  -allowProvisioningUpdates

export_options="$BUILD_ROOT/ExportOptions-export.plist"
cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM</string>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates

app_path="$EXPORT_PATH/$APP_NAME.app"
codesign --verify --strict --deep --verbose=2 "$app_path"

upload_options="$BUILD_ROOT/ExportOptions-upload.plist"
cat > "$upload_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>upload</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM</string>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$UPLOAD_PATH" \
  -exportOptionsPlist "$upload_options" \
  -allowProvisioningUpdates

# Xcode-managed uploads do not give notarytool credentials. Poll stapler; it
# can fetch the public ticket after Apple accepts the Developer ID submission.
for ((attempt = 1; attempt <= MAX_STAPLE_ATTEMPTS; attempt += 1)); do
  if xcrun stapler staple "$app_path"; then
    break
  fi

  if [[ "$attempt" -eq "$MAX_STAPLE_ATTEMPTS" ]]; then
    echo "Notarization ticket was not available after $MAX_STAPLE_ATTEMPTS attempts." >&2
    exit 65
  fi

  sleep "$STAPLE_SLEEP_SECONDS"
done

xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

info_plist="$app_path/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
zip_path="$DIST_PATH/$APP_NAME-$version+$build.app.zip"
dmg_path="$DIST_PATH/$APP_NAME-$version.dmg"
dmg_root="$BUILD_ROOT/dmg-root"

rm -f "$zip_path"
ditto -c -k --keepParent "$app_path" "$zip_path"

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

if [[ -n "$DEVELOPER_ID_APPLICATION" && -n "$NOTARY_PROFILE" ]]; then
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime "$dmg_path"
  codesign --verify --verbose=2 "$dmg_path"
  xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg_path"
  spctl --assess --type open --verbose=4 "$dmg_path"
else
  echo "DMG created without separate DMG signing/notarization; the app inside is stapled." >&2
fi

echo "Release app zip: $zip_path"
echo "Release DMG: $dmg_path"
