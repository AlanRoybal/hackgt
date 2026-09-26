# Backend notes (M0–M6)

Stack `Nudge-dev` in us-east-1, deployed from `backend/` with `npm run deploy:dev`. Outputs are in `backend/cdk-outputs.dev.json`.

| Output | Value |
|---|---|
| HTTP API | https://2pe0i2c1kg.execute-api.us-east-1.amazonaws.com |
| WebSocket | wss://a0ngqoooq6.execute-api.us-east-1.amazonaws.com/dev |
| User pool / client | us-east-1_FOSgjtqj2 / 2tkdgrqlbrs3vrfjqvo4k776rb |
| Identity pool (Transcribe only) | us-east-1:b9309c38-a36c-4199-816c-0907862428e9 |
| Media bucket / vector bucket | nudge-media-dev-724772092774 / nudge-vectors-dev-724772092774 (index `photos`, 1024-d cosine) |
| Table | Nudge-dev (single table + `gsi1`, TTL `ttl`) |
| Budget | `nudge-net-cost`, net after credits > $1/month → alan@elarahealthai.com (verified: subscriber set, includes credits) |

## What's built

Every route in SPEC §3.7, the WebSocket routes in §3.8, APNs payloads in §3.9, and dev hooks. Also:

- **Scheduled jobs:** the matcher runs every 5 minutes. The photo sweep runs daily at 04:00 UTC.
- **SQS delays:** a 60 s pre-check, a 180 s nudge expiry, and a 30 s wait before summarizing. All have a DLQ.
- **Photo indexing:** triggered by S3 upload. It runs the Rekognition moderation check and OCR, then the rules and the Nova safety check, then the Nova caption, then the Titan image embedding into S3 Vectors.
- **Transcript → photo suggestion:** each transcript segment runs the detector, then embedding, then vector search (date filter first, falling back to no filter), then sends `photo.suggestion` to the speaker's socket only.
- **Chime live transcription** as a fallback transcript source (D-106).

`scripts/put-apns-secrets.sh` stores the APNs key and bundle ID in SSM. `scripts/logs.ts <fn> [min] [filter]` tails a function's logs.

## Tests: all passing against the deployed stack

- **Unit tests** (`npm test`): **93 passing.** Includes fast-check property tests for:
  - overlap merging and window safety
  - the frequency limiter never exceeding the daily cap
  - the state machine: terminal states are final, and a match requires two accepts

  Also covered: DST, quiet hours that cross midnight, the full sensitive-text rule table, moderation filtering with mocked Rekognition, and the APNs ES256 JWT.
- **Integration tests** (`npm run integ`): **31 passing across 5 files.** They cover:
  - **Accounts:** ACC-1..12 plus the WebSocket auth and ping checks.
  - **Nudges and messages:** NUD-1/2/4/5/7/8/10/11/12/13, the match race (D-107), and MSG.
  - **Calls:** CALL-5.
  - **Photos:** PHO-1..6, with real images through the real pipeline.
  - **References:** REF-1..7/10/11.
  - **Memory:** MEM-1..5.
  - **Real SQS timing** (`queues.test.ts`): the pre-check fired after 62 s, expiry 179 s after accept, and the summary came from the queue.
- **Evals:** see `evals/RESULTS.md`.
  - Detector: precision 1.000, recall 0.896.
  - Retrieval: top-1 1.00, top-3 1.00.
  - Safety: 9/9 sensitive fixtures excluded, 0/7 benign excluded.

## Latency (REF-10)

**Server stages** (CloudWatch EMF, `Nudge/Latency`, warm):

| Stage | Time |
|---|---|
| Store | 10–30 ms |
| Context | 10–20 ms |
| Detector (Nova Lite) | 420–550 ms |
| Embed | 120–180 ms |
| Search | ~150 ms |
| **Total** | **≈ 0.8–1.0 s** |

**Client-measured, transcript send → `photo.suggestion` received** (includes WebSocket, polled every 200 ms): **p50 1007 ms, p95 1010 ms** (n=6).

Transcribe finalization time on the device (~0.7 s budgeted) is not included. The measured part fits comfortably inside the 2.5 s p50 target.

**Share handshake:** GET share URL + download of a ~70 KB photo took 200 ms.

**Photo indexing:** ≈ 1.4 s per photo (safety 0.45 s, caption 0.6 s, embed 0.14 s, vector write 0.2 s).

## Contract notes for iOS

- **Additive only:** `Message` may include `systemEvent` (`{type: "missed_nudge", at}` or `{type: "call", durationSec, callId}`) on `kind: "system"` messages. `Topic` in memories includes `sourceCallId`. Nothing was renamed or removed.
- **`POST /nudges/{id}/respond`:** when your accept completes the match, the response has `state: "matched"` and `callId`, and the socket also gets `call.matched`. You won't get a VoIP push (D-107).
- **`GET /calls/{id}/summary`:** returns 202 `{"pending": true}` until the summarizer has run. When memory is off, it returns 200 with an empty summary and no topics.
- **`photoId` values:** these are the `assetHash` the device uploaded.
- **`CallJoin.meeting` / `attendee`:** these are the bare Chime `Meeting` / `Attendee` objects (PascalCase keys).
- **Quiet hours:** setting `quietStart == quietEnd` means no quiet hours.

## Not verified (needs the Apple team or a device)

- **Real APNs delivery** of alert, background and VoIP pushes. No `.p8` key exists yet. Payloads, topics, host selection and JWT signing are unit-tested. The push log proves the right pushes are sent at the right time.
- **The success path of `/auth/apple`** with a genuine Apple identity token. The rejection path is integration-tested.
- **SMS phone verification** (Cognito → SNS; the account is in the SMS sandbox). The dev hook `/dev/phone/verify` covers the claim-and-match logic.
- **Chime live transcription producing transcript events on a device.** Start succeeds (logged: "meeting transcription started"). Whether events reach the iOS SDK needs a real call.
- **`apnsEnv` on real TestFlight or debug tokens.**

## Cost

Cost Explorer lags about 24 h: 2026-09-26 (UTC) usage wasn't visible when this was written.

- **2026-09-25, whole account, before this stack existed:** gross $1.48, net $0.00 after credits.
- **Estimate for this workstream at list price:** under $2, all first-party and credit-covered:
  - Bedrock: ~400 Nova Lite calls, ~400 Titan embeddings
  - Rekognition: ~150 image pairs
  - DynamoDB, Lambda, API Gateway and SQS: pennies
  - Chime: a few seconds of meetings
- **Idle cost is $0:** everything is on-demand or serverless, with no NAT, EC2, RDS or OpenSearch. The only standing items are S3 storage (a few MB) and CloudWatch logs (2-week retention).
- **`cdk destroy`** removes everything, including the S3 objects and vector bucket. The Budget is part of the stack and is removed too.
