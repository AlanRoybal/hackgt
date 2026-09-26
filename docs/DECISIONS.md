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
