#!/usr/bin/env bash
# End-to-end: the real iOS app in the simulator against the deployed dev backend, with the peer bot as the friend.
# Usage: tools/e2e/ios-e2e.sh [app-e2e|app-closed|app-calls] [simulator name]
#   app-e2e    onboarding → friend → message → in-app nudge → call → bot's photo in the mini window → summary
#   app-closed onboarding → app terminated → real matcher nudge delivered as a push → Accept on the
#              notification launches the app → waiting room → call
#   app-calls  onboarding → friend → app user taps Call now on the bot's profile → ringing (waiting room) →
#              bot accepts → call
# Set BOT_NO_MEDIA=1 if the Mac is locked (media capture is blocked for every process then).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCENARIO="${1:-app-e2e}"
SIM_NAME="${2:-iPhone 17 Pro}"
case "$SCENARIO" in
  app-e2e) TEST=testOnboardFriendMessageCallAndPhoto ;;
  app-closed) TEST=testNudgeArrivesWhileAppClosed ;;
  app-calls) TEST=testAppUserCallsFromProfile ;;
  *) echo "unknown scenario $SCENARIO"; exit 2 ;;
esac
RUN="$(date +%s | tail -c 7)"
OUT="$ROOT/tools/e2e/out/$RUN"
mkdir -p "$OUT" "$ROOT/tools/peer-bot/out"

UDID="$(xcrun simctl list devices available -j | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next(x['udid'] for v in d.values() for x in v if x['name']=='$SIM_NAME'))")"
xcrun simctl boot "$UDID" 2>/dev/null || true
BUNDLE_ID="$(grep NUDGE_BUNDLE_ID "$ROOT/ios/Config/Signing.xcconfig" | awk -F'= ' '{print $2}' | tr -d ' ')"

cd "$ROOT/ios"
/opt/homebrew/bin/xcodegen generate --quiet
xcodebuild build-for-testing -project Nudge.xcodeproj -scheme Nudge -destination "id=$UDID" \
  -derivedDataPath build/e2e CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet
APP="$(find build/e2e/Build/Products -maxdepth 2 -name Nudge.app | head -1)"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant all "$BUNDLE_ID" || true

echo "scenario=$SCENARIO run=$RUN  bot log: $OUT/bot.log"
(cd "$ROOT/tools/peer-bot" && npm run --silent bot -- "$SCENARIO" --run "$RUN" --udid "$UDID" --bundle "$BUNDLE_ID" >"$OUT/bot.log" 2>&1) &
BOT=$!

set +e
TEST_RUNNER_E2E_RUN="$RUN" TEST_RUNNER_E2E_SCENARIO="$SCENARIO" xcodebuild test-without-building -project Nudge.xcodeproj -scheme Nudge \
  -destination "id=$UDID" -derivedDataPath build/e2e -only-testing:"NudgeUITests/E2ETests/$TEST" \
  -resultBundlePath "$OUT/result.xcresult" 2>&1 | tail -25
TEST_RC=${PIPESTATUS[0]}
wait $BOT; BOTRC=$?
set -e
echo "xcodebuild=$TEST_RC bot=$BOTRC  results: $OUT"
exit $(( TEST_RC || BOTRC ))
