# Sloucher Privacy

Sloucher uses the camera only to measure posture on this Mac. Camera frames are processed locally with Apple's Vision framework. The app does not upload camera frames, posture measurements, settings, or diagnostics.

Sloucher stores local settings in `UserDefaults`, including calibration values, nudge preferences, launch-at-login preference, and runtime diagnostic keys used for troubleshooting.

Release builds do not write camera frame images or raw camera planes to disk. Debug builds may include extra forensic capture paths for local development.

The bundled privacy manifest declares app-private `UserDefaults` access and no tracking or collected data.
