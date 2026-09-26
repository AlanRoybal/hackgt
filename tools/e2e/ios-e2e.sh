#!/usr/bin/env bash
# End-to-end: the real iOS app in the simulator against the deployed dev backend, with the peer bot as the friend.
# Usage: tools/e2e/ios-e2e.sh [simulator name]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIM_NAME="${1:-iPhone 17 Pro}"
RUN="$(date +%s | tail -c 7)"
OUT="$ROOT/tools/e2e/out/$RUN"
mkdir -p "$OUT"

UDID="$(xcrun simctl list devices available -j | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next(x['udid'] for v in d.values() for x in v if x['name']=='$SIM_NAME'))")"
xcrun simctl boot "$UDID" 2>/dev/null || true
BUNDLE_ID="$(grep NUDGE_BUNDLE_ID "$ROOT/ios/Config/Signing.xcconfig" | awk -F'= ' '{print $2}' | tr -d ' ')"

cd "$ROOT/ios"
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild build-for-testing -project Nudge.xcodeproj -scheme Nudge -destination "id=$UDID" \
  -derivedDataPath build/e2e CODE_SIGNING_ALLOWED=NO -quiet
APP="$(find build/e2e/Build/Products -maxdepth 2 -name Nudge.app | head -1)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant all "$BUNDLE_ID" || true

echo "run=$RUN  bot log: $OUT/bot.log"
(cd "$ROOT/tools/peer-bot" && npm run --silent bot -- app-e2e --run "$RUN" >"$OUT/bot.log" 2>&1) &
BOT=$!

set +e
TEST_RUNNER_E2E_RUN="$RUN" xcodebuild test-without-building -project Nudge.xcodeproj -scheme Nudge \
  -destination "id=$UDID" -derivedDataPath build/e2e -only-testing:NudgeUITests/E2ETests \
  -resultBundlePath "$OUT/result.xcresult" 2>&1 | tail -25
TEST=${PIPESTATUS[0]}
wait $BOT; BOTRC=$?
set -e
echo "xcodebuild=$TEST bot=$BOTRC  results: $OUT"
exit $(( TEST || BOTRC ))
