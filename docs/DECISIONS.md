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

## Backend workstream (D-100+)

**D-100 One shared Lambda role.** All backend Lambdas share one IAM role (table, bucket, queues, Bedrock models, Rekognition, Chime, Cognito admin on the pool, S3 Vectors on the one bucket, SSM `/nudge/<stage>/*`, WS ManageConnections). Simpler to reason about for a small app; split per function before any public launch.

**D-101 Bundle the AWS SDK into every Lambda.** `externalModules: []` — the Node 22 runtime's built-in SDK may predate `@aws-sdk/client-s3vectors`. Bundles are 0.3–0.8 MB; cold starts stay well under a second.

**D-102 Reservation via `busyUntil`.** A user is "busy" (not nudgeable) while `busyUntil > now`: set to pre-check + 180 s + slack when a nudge is created, and to +3 h when a call starts; cleared on terminal states / call end. Abandoned calls can't block nudges for more than 3 h.

**D-103 Dev push log.** In `dev`, every push (alert/background/voip) is also written to `PUSHLOG#<userId>` (24 h TTL) so integration tests can assert on pushes without a real APNs key. Without the SSM key, pushes are only logged.

**D-104 Retrieval eval photos from Openverse, not Nova Canvas.** Nova Canvas is LEGACY in this account ("not actively used in the last 30 days") and no other first-party image model is ACTIVE. The 60 eval photos are CC0 / public-domain images from Openverse (credits in `evals/retrieval/CREDITS.json`); queries were relabeled by eye to describe what each downloaded photo shows.

**D-105 Image-only embeddings, threshold 0.37.** In `evals/retrieval`, Titan image-only embeddings scored top-1 1.00 / top-3 1.00 vs 0.95 / 0.97 when fused with the Nova caption. Production embeds the image alone; the caption is kept as non-filterable vector metadata. Similarity threshold 0.37 (positives' min 0.379, negatives' max 0.373 — a thin margin, so it leans toward recall; "Ask first" makes a stray suggestion cheap to dismiss).

**D-106 Chime live transcription as a fallback transcript source.** On match, the backend calls `StartMeetingTranscription` (Amazon Transcribe engine, en-US). If a device can't run its own Transcribe stream alongside Chime's audio session, iOS forwards its **own** attendee's lines from Chime's transcript events over WS `transcript` exactly like SPEC §3.8; the identity-pool direct-Transcribe path stays. Needs the `AWSServiceRoleForAmazonChimeTranscription` service-linked role (created once with `aws iam create-service-linked-role --aws-service-name transcription.chime.amazonaws.com`; free). Cost note: this transcribes every call even when devices use their own stream (billed at Transcribe streaming rates, credit-covered); set `MEETING_TRANSCRIPTION=off` to disable.

**D-107 Match notification never rings the accepter.** The user whose accept completes the match always gets WS `call.matched` (plus `callId` in the respond response) and never a VoIP push — the app is open by definition and its `waiting` message may land after the accept. Only the other participant, if not in the waiting room, gets the VoIP push.

**D-108 Detector judges only the newest line.** The prompt shows earlier lines as "context only" and the just-received segment separately as "LAST LINE"; the server always puts the current segment last even if the friend's segment arrived after it. Without this, earlier references in the same minute leaked into later queries (found by integration test; 8 context cases added to the eval).

**D-109 Summaries keep topics without dates.** Every extracted topic is stored `open`; only topics with `followUpAfter` can drive follow-up nudges.

**D-110 Consumers drop messages for deleted records.** Delay / summarize SQS consumers treat 404 (nudge or call deleted with an account) and 409 (already handled) as done instead of retrying into the DLQ.
