#!/usr/bin/env bash
# Captures every screen (ScreenshotMode.all) in light, dark, AX5 Dynamic Type and Reduce Motion.
# Output: docs/screens/<variant>/<screen>.jpg (half-size JPEGs to keep the repo small).
#
#   ios/scripts/screenshots.sh              # all variants
#   ios/scripts/screenshots.sh light dark   # subset
#   SCREENS="call-mine banner" ios/scripts/screenshots.sh light
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/ios"
OUT="$ROOT/docs/screens"
DERIVED="$IOS/build/screens"
DEVICE_NAME="Nudge Screens (iPhone 17 Pro)"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
BUNDLE_ID="app.nudge.dev"
VARIANTS=("$@")
[ ${#VARIANTS[@]} -eq 0 ] && VARIANTS=(light dark ax5 reduce-motion)

# Screen ids come from the app so the list can't drift.
DEFAULT_SCREENS=$(sed -n '/static let all: \[String\] = \[/,/\]/p' "$IOS/App/Debug/ScreenshotMode.swift" | grep -o '"[a-z0-9-]*"' | tr -d '"')
SCREENS="${SCREENS:-$DEFAULT_SCREENS}"

XCODEGEN=$(command -v /opt/homebrew/bin/xcodegen || command -v xcodegen)
(cd "$IOS" && "$XCODEGEN" generate -q)

RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin)['runtimes'] if x['platform']=='iOS' and x['isAvailable']]; print(r[-1]['identifier'])")
UDID=$(xcrun simctl list devices -j | python3 -c "
import json,sys
for rt, devs in json.load(sys.stdin)['devices'].items():
    for d in devs:
        if d['name'] == '$DEVICE_NAME' and d['isAvailable']: print(d['udid']); sys.exit()
")
if [ -z "$UDID" ]; then UDID=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME"); fi
echo "Simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "Building…"
xcodebuild -project "$IOS/Nudge.xcodeproj" -scheme Nudge -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build -quiet
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Nudge.app"
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3

set_variant() {
  xcrun simctl ui "$UDID" appearance light
  xcrun simctl ui "$UDID" content_size large
  xcrun simctl spawn "$UDID" defaults write com.apple.Accessibility ReduceMotionEnabled -bool false
  case "$1" in
    dark) xcrun simctl ui "$UDID" appearance dark ;;
    ax5) xcrun simctl ui "$UDID" content_size accessibility-extra-extra-extra-large ;;
    reduce-motion) xcrun simctl spawn "$UDID" defaults write com.apple.Accessibility ReduceMotionEnabled -bool true ;;
  esac
}

for variant in "${VARIANTS[@]}"; do
  set_variant "$variant"
  mkdir -p "$OUT/$variant"
  for screen in $SCREENS; do
    extra=()
    [ "$variant" = "reduce-motion" ] && extra=(-forceReduceMotion YES)
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -screenshotScreen "$screen" ${extra[@]+"${extra[@]}"} >/dev/null
    sleep 2.2
    tmp="$(mktemp -t nudge).png"
    xcrun simctl io "$UDID" screenshot --type=png "$tmp" >/dev/null 2>&1
    sips -s format jpeg -s formatOptions 78 -Z 1311 "$tmp" --out "$OUT/$variant/$screen.jpg" >/dev/null
    rm -f "$tmp"
    printf '.'
  done
  echo " $variant done"
done
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
set_variant light
echo "Screenshots in $OUT"
