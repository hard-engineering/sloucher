#!/bin/sh
# Replay first-run onboarding for local testing:
# clears all app defaults (baseline, runtime keys, preferences) and the
# camera permission so the welcome -> camera -> calibrate flow runs again.
#
# Usage: ./scripts/reset_onboarding.sh   (quit Sloucher first)

set -e

BUNDLE_ID="app.sloucher.Sloucher"

defaults delete "$BUNDLE_ID" 2>/dev/null || true
echo "Cleared defaults for $BUNDLE_ID (baseline, onboarding flags, preferences)."

tccutil reset Camera "$BUNDLE_ID" && echo "Reset camera permission."

echo
echo "Note: macOS has no CLI reset for notification permission."
echo "To retest that ask, remove Sloucher under System Settings > Notifications,"
echo "or test the rest of the flow with notifications already decided."
