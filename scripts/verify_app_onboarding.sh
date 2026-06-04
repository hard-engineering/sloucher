#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-Sloucher}"
PROJECT="${PROJECT:-Sloucher.xcodeproj}"
SCHEME="${SCHEME:-Sloucher}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-DerivedData/AppOnboardingTest}"
TEST_BUNDLE_ID="${TEST_BUNDLE_ID:-app.sloucher.Sloucher.AppOnboardingTest.$(date +%Y%m%d%H%M%S)}"
LOG_PREDICATE='subsystem == "app.sloucher.Sloucher" && category == "notifications"'
keep_running=false

usage() {
  cat <<EOF
Usage: $0 [--keep-running]

Builds and launches a clean-bundle Sloucher app to verify first-launch
onboarding state. By default, the script quits the launched test app after the
automated check. Use --keep-running to leave it open for the manual camera,
calibration, notification prompt, and test-nudge flow.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-running)
      keep_running=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

app_path="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
start_time="$(date '+%Y-%m-%d %H:%M:%S')"

echo "Building $APP_NAME onboarding test app with clean bundle id:"
echo "  $TEST_BUNDLE_ID"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  PRODUCT_BUNDLE_IDENTIFIER="$TEST_BUNDLE_ID" \
  build

osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
defaults delete "$TEST_BUNDLE_ID" >/dev/null 2>&1 || true

echo
echo "Launching:"
echo "  $app_path"
open -n "$app_path"
sleep 4

pid="$(pgrep -n -x "$APP_NAME" || true)"
permission_status="$(defaults read "$TEST_BUNDLE_ID" runtime.notification.permissionStatus 2>/dev/null || true)"
runtime_status="$(defaults read "$TEST_BUNDLE_ID" runtime.status 2>/dev/null || true)"

echo
echo "Fresh launch state:"
echo "  process id: ${pid:-not found}"
echo "  runtime.status: ${runtime_status:-missing}"
echo "  runtime.notification.permissionStatus: ${permission_status:-missing}"

if [[ "$permission_status" == "notDetermined" ]]; then
  echo "PASS: first launch did not request notification authorization."
else
  echo "FAIL: expected notification permission to remain notDetermined on first launch." >&2
fi

echo
echo "Notification logs since launch:"
if [[ -n "$pid" ]]; then
  log show --info --style compact --start "$start_time" \
    --predicate "processID == $pid && $LOG_PREDICATE" || true
else
  log show --info --style compact --start "$start_time" \
    --predicate "$LOG_PREDICATE" || true
fi

echo
if [[ "$keep_running" == true ]]; then
  echo "Keeping the test app running for manual onboarding."
  echo
  echo "Manual onboarding test:"
  echo "  1. If camera setup is shown, allow camera access."
  echo "  2. Open Sloucher from the menu bar."
  echo "  3. Click Calibrate while sitting upright."
  echo "  4. In the notification setup panel, click Enable Notifications."
  echo "  5. Accept the macOS notification prompt."
  echo "  6. Click Test nudge."
  echo
  echo "Diagnostic command after the manual test:"
  echo "  log show --info --style compact --last 10m --predicate '$LOG_PREDICATE'"
else
  echo "Quitting the test app. Re-run with --keep-running for the manual onboarding path."
  if [[ -n "$pid" ]]; then
    osascript -e "tell application id \"$TEST_BUNDLE_ID\" to quit" >/dev/null 2>&1 || kill "$pid" >/dev/null 2>&1 || true
  fi
fi
