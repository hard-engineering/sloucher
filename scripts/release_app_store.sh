#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-Sloucher}"
PROJECT="${PROJECT:-Sloucher.xcodeproj}"
SCHEME="${SCHEME:-Sloucher AppStore}"
CONFIGURATION="${CONFIGURATION:-AppStore}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-DerivedData/AppStore}"
BUILD_ROOT="${BUILD_ROOT:-build/app-store}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_ROOT/$APP_NAME.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_ROOT/export}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
APP_STORE_DESTINATION="${APP_STORE_DESTINATION:-export}"
AUTHENTICATION_KEY_PATH="${AUTHENTICATION_KEY_PATH:-}"
AUTHENTICATION_KEY_ID="${AUTHENTICATION_KEY_ID:-}"
AUTHENTICATION_KEY_ISSUER_ID="${AUTHENTICATION_KEY_ISSUER_ID:-}"

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  echo "Set DEVELOPMENT_TEAM to your Apple Developer team ID." >&2
  exit 64
fi

if [[ "$APP_STORE_DESTINATION" != "export" && "$APP_STORE_DESTINATION" != "upload" ]]; then
  echo "APP_STORE_DESTINATION must be either export or upload." >&2
  exit 64
fi

auth_args=()
if [[ -n "$AUTHENTICATION_KEY_PATH" || -n "$AUTHENTICATION_KEY_ID" || -n "$AUTHENTICATION_KEY_ISSUER_ID" ]]; then
  if [[ -z "$AUTHENTICATION_KEY_PATH" || -z "$AUTHENTICATION_KEY_ID" || -z "$AUTHENTICATION_KEY_ISSUER_ID" ]]; then
    echo "Set AUTHENTICATION_KEY_PATH, AUTHENTICATION_KEY_ID, and AUTHENTICATION_KEY_ISSUER_ID together." >&2
    exit 64
  fi
  auth_args+=(
    -authenticationKeyPath "$AUTHENTICATION_KEY_PATH"
    -authenticationKeyID "$AUTHENTICATION_KEY_ID"
    -authenticationKeyIssuerID "$AUTHENTICATION_KEY_ISSUER_ID"
  )
fi

mkdir -p "$BUILD_ROOT"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  "${auth_args[@]}" \
  clean archive \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_ENTITLEMENTS=Sloucher/AppStore.entitlements \
  ENABLE_HARDENED_RUNTIME=YES

export_options="$BUILD_ROOT/ExportOptions.plist"
cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>$APP_STORE_DESTINATION</string>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates \
  "${auth_args[@]}"

echo "App Store export path: $EXPORT_PATH"
if [[ "$APP_STORE_DESTINATION" == "upload" ]]; then
  echo "Upload requested; check App Store Connect build processing."
fi
