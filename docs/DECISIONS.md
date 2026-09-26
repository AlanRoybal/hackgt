# Decisions log

Newest at the bottom. Each entry: decision, why, consequence.

**D-1 Build without the approval pause.** The prompt asks to stop after `SPEC.md` for approval; the user then set a session goal "implement all steps" and asked not to pause. The spec was written first and the build continued. Revisit anything in SPEC.md you disagree with and it'll be changed.

**D-2 Budget alert email.** The prompt says to ask for the address; the goal forbids pausing, so the alert goes to the account owner's email on file for this session (alan@elarahealthai.com). Change it in `backend/lib/budget.ts` → `BUDGET_EMAIL` context.

**D-3 Sign in with Apple → Cognito without the hosted UI.** Cognito's Apple federation only works through the hosted UI / web redirect, which forces an `ASWebAuthenticationSession` instead of the native Apple button. Instead: the app uses the native `ASAuthorizationAppleIDProvider`, sends the identity token to `POST /auth/apple`, the Lambda verifies it against Apple's JWKS (issuer, audience = bundle ID, expiry), creates/looks up Cognito user `apple_<sub>`, sets a fresh random password, and runs `AdminInitiateAuth` to mint normal Cognito tokens. Everything downstream (JWT authorizer, identity pool) is standard Cognito. Refresh goes through `POST /auth/refresh`.

**D-4 Access tokens as bearer.** HTTP API JWT authorizer validates the access token's `client_id`. Using the access token also lets the server call user-scoped Cognito APIs (phone `UpdateUserAttributes` / `VerifyUserAttribute`) on the user's behalf.

**D-5 No AWS SDK for Swift.** The prompt lists it as expected for Transcribe streaming, but it adds a very large dependency tree and slow builds. The app instead calls Cognito Identity (`GetId`, `GetCredentialsForIdentity`, plain JSON over HTTPS), SigV4-presigns the Transcribe streaming WebSocket URL with CryptoKit, and implements the small AWS event-stream binary codec (prelude + headers + CRC32). ~300 lines, fully unit-tested. Dependencies are Chime SDK and PhoneNumberKit only.

**D-6 Photo share URL indirection.** Chime data messages are capped at 2 KB; a presigned S3 URL signed with Lambda session credentials can approach that. The `offer` carries a `shareId`; the recipient calls `GET /calls/{id}/shares/{shareId}` for the URL (+1 small request, inside the 800 ms budget). This also lets the server enforce "only the other participant of an active call".

**D-7 Delays via SQS, not Step Functions.** Pre-check (60 s), expiry (180 s) and summarize (30 s) use per-message `DelaySeconds` on SQS queues. Cheapest and simplest; max 900 s covers all cases.

**D-8 Matcher scans friendships.** The matcher queries all friendship items through the GSI (`FRIENDSHIPS`). Fine for a hackathon-scale user base; at scale it'd shard by user bucket.

**D-9 Frequency values.** See SPEC §3.6. "See this less often" floors at Low; only Settings can choose Off (a long-press shouldn't silently turn the whole app off).

**D-10 Direct "Call now".** The Figma brief has a Call now button on the friend profile; it reuses the nudge flow as a `direct` nudge with the caller pre-accepted, so waiting room / skip / follow-up behave identically.

**D-11 Expired = skipped.** A nudge that expires with one acceptance triggers the skipper's follow-up behavior, per the product definition.

**D-12 Bedrock models.** Only Amazon first-party models (credit-eligible): Nova Lite for detection/captioning/summaries/messages, Titan Multimodal Embeddings G1 at 1024 dims. Nova Canvas generates the retrieval eval image set.

**D-13 Share link without a domain.** No domain is owned, so the share link is the custom scheme `nudge://add/<handle>` with a text fallback ("Add me on Nudge: @handle"). Universal links need a domain + AASA file later.

**D-14 SMS sandbox.** New AWS accounts are in the SNS SMS sandbox: codes only go to numbers verified in the SNS console. `APPLE_SETUP.md` lists adding both testers' numbers. Dev stage also has `/dev/phone/verify` to bypass SMS in integration tests.

**D-15 Legal.** No in-call indicator; consent comes from the ToS accepted at first sign-in, which explicitly covers transcription of both participants. **A lawyer should review the ToS before any public launch** (two-party consent laws, biometric/photo analysis laws such as BIPA).

**D-16 Minimum iOS 18.** Built with Xcode 26.5 / iOS 26 SDK. On iOS 26 the system tab bar and nav bar pick up Liquid Glass automatically; per the brief, system chrome stays standard and only content is flat pastel.

## iOS (D-200+)

**D-200 Module renamed `BackgroundTasks` → `BackgroundWork`.** A local module named `BackgroundTasks` shadows Apple's framework of the same name, so the scheduler couldn't import it.

**D-201 Contrast-adjusted tokens.** Appendix A's light-mode *Strong* colors measure 3.4–4.0:1 on their own pastel fills, below WCAG AA (4.5:1). They were darkened the minimum amount (`ios/scripts/contrast.py`): lavenderStrong #6052BD, mintStrong #277553, peachStrong #9F5130, skyStrong #3569A5, butterStrong #83680F, roseStrong #B13647. inkTertiary is #6D727C light / #828796 dark (was 2.5:1 / 3.5:1). Fills, dark-mode Strong colors and names are unchanged. **The Figma file (Devin) should adopt these values.**

**D-202 Transcription without the AWS SDK, plus a Chime fallback.** Own-mic transcription uses AVAudioEngine → 16 kHz PCM → SigV4-presigned Transcribe WebSocket (D-5). Chime's audio unit and an AVAudioEngine input tap may not coexist on every device, which can't be verified on the simulator. Fallback: if the own stream isn't running and the meeting has Chime live transcription (`StartMeetingTranscription`) turned on, the client forwards its *own* final segments from Chime's transcript events over the same WS `transcript` action. The backend would need to call `StartMeetingTranscription` at match time for the fallback to activate; that's a contract question for the lead.

**D-203 Photo-share reducer.** `PhotoShareSession` is a pure state machine (event + time → effects), driven by `PhotoShareController`. It matches the peer-bot semantics:
- an in-flight `createShare` blocks further offers and counts toward the max-5 queue
- `durationMs` is fixed at offer time from the number of pending items (including the one being offered)
- messages echoed from self are ignored
- on `createShare` failure it logs and moves to the next item
- stale messages (older Chime `timestampMs` from the same sender) are dropped

**D-204 Swipe-away = fling off-screen.** The mini window is draggable to corners, so "swipe my photo away" is a fling whose projected end point leaves the screen horizontally. It cancels the photo and the window still snaps to the nearest corner.

**D-205 One full-screen cover for the waiting room → call → summary.** A single `fullScreenCover` switches content internally, so the transitions don't stack or re-present modals.

**D-206 No location permission.** Reverse geocoding uses each photo's own EXIF location with `CLGeocoder`, which needs no Core Location authorization. Results are cached per ~1 km cell because the geocoder is rate-limited.

**D-207 Nudge notification actions.** `ACCEPT` is a foreground action (opens the waiting room). `SKIP` and `LESS` run in the background: iOS launches the app to call the API, even after termination. Swiping the notification away sends no response; the nudge just expires, per SPEC.

**D-208 Screenshot mode.** `-screenshotScreen <id>` (DEBUG) renders any screen with in-memory mock data via each store's `preview(...)` method. `-forceReduceMotion` sets `_accessibilityReduceMotion` for the Reduce Motion capture, because the simulator's accessibility setting only takes effect after a respring. Camera frames and photos in captures are flat illustrations, not real video.

**D-209 XcodeGen.** Use Homebrew `xcodegen` ≥ 2.46. The copy at `~/.local/bin/xcodegen` ships without its SettingPresets, so extensions end up with no `PRODUCT_NAME`. `ios/scripts/screenshots.sh` prefers `/opt/homebrew/bin/xcodegen`.
