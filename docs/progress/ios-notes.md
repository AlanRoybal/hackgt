# iOS workstream notes

## Layout

```
ios/
  project.yml                XcodeGen (use Homebrew xcodegen ≥ 2.46, see D-209)
  Config/                    Signing.xcconfig (Team ID, bundle ID), Env.xcconfig (API/WS URLs), Debug/Release
  App/                       SwiftUI app: Core (AppModel, AppDelegate, RootView), Onboarding, Friends,
                             Messages, Nudge, Call, Settings, Debug (screenshot mode + mock data), Assets
  Extensions/                NotificationContent (expanded nudge), NotificationService (avatar attachment)
  Packages/NudgeKit/         15 library modules + NudgeKitTests
  scripts/                   screenshots.sh, contact-sheet.swift, make-icon.swift, contrast.py
```

NudgeKit modules: DesignSystem, Models, Networking, Auth, Friends, Availability, Nudges, Calls, Transcription, PhotoIndex, PhotoShare, Messages, Memory, Settings, BackgroundWork (renamed from BackgroundTasks, D-200). Dependencies: Amazon Chime SDK 0.27.4 (SPM), PhoneNumberKit 4.3.

## How to run

```sh
cd ios && /opt/homebrew/bin/xcodegen generate
# Build (simulator, unsigned)
xcodebuild -project Nudge.xcodeproj -scheme Nudge -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO build
# Package tests
cd Packages/NudgeKit && xcodebuild -scheme NudgeKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
# Screenshots → docs/screens/<light|dark|ax5|reduce-motion>/<screen>.jpg
ios/scripts/screenshots.sh
```

Point the app at the dev backend by editing `ios/Config/Env.xcconfig` (`https:/$()/…` escaping), then use **Developer sign-in** (DEBUG only) on the sign-in screen, which calls `POST /auth/dev`.

## Verified here

See the final report in the task result for the current numbers. Pure logic is tested in `Packages/NudgeKit/Tests`:
- display-rule truth table and two-device scenarios, including both people sharing at once
- queue timing, and the photo protocol state machine (ready timeout, in-flight guard, burst durations, drop-oldest, create failure, echo and stale drops, cancel)
- handle rules, E.164 + SHA-256 hashing, busy-block extraction, merging and clipping, driving detection, and add-friend links
- snap projection and rubber-banding, photo selection, resizing and asset hashing
- the event-stream codec (AWS empty-message vector, CRC checks, round trips), the transcript parser, and SigV4 (AWS signing-key vector and S3 presign vector)
- contract decoding for the Nudge DTO, server events and client actions

## Not verifiable on the simulator (needs a device and/or Apple team)

- Sign in with Apple (the native sheet needs a signed build with the capability)
- APNs and PushKit delivery, CallKit ringing, and notification actions from the lock screen
- the Notification Content and Service extensions rendering
- Chime media: camera and mic capture, and remote video
- concurrent AVAudioEngine mic tap + Chime audio unit (D-202)
- Focus status, Core Motion driving detection, background URLSession uploads, BGTaskScheduler runs
- the reverse geocoding rate limit on real photo libraries

The app code for all of these is written and compiles. The Developer sign-in path lets everything else (REST, WS, stores) be exercised against the dev stage from the simulator.
