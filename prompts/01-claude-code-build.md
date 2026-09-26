# Build Prompt — Claude Code

> Paste everything below the line into Claude Code, run from the root of the `hackgt` repo.
> "Nudge" is a working name — find/replace it if you pick a real one.

---

You are the lead engineer building **Nudge**, a native iOS app (Swift, SwiftUI) plus its AWS backend. Nudge helps people stay in touch with the people they care about. It watches when you and a friend are both free, sends you both a nudge to call, runs a video call, and during that call surfaces photos you mention from your camera roll. After the call it remembers what you talked about so later nudges can suggest a follow-up.

The app must look and feel like a polished, professional Apple-quality product.

## 0. How to work

1. **Plan first.** Before writing any app code, write `docs/SPEC.md` with these four sections. Use the product definition below as the source of truth, and resolve any gaps with the decisions in §3.
   - **User stories.** For every feature in §2, write stories in the form "As a user, I want … so that …". Give each story numbered acceptance criteria written as testable Given/When/Then statements.
   - **Verification methodology.** For each story, say how it will be proven: unit test, integration test, device test, or eval. Follow the strategy in §6.
   - **Data models.** Cover both the backend (DynamoDB) and the client (Swift) models. Start from §5, then refine.
   - **Architecture.** Cover the iOS modules, the backend services, sequence diagrams (Mermaid) for every cross-device flow, and background execution. Start from §4.
2. **Stop and show me `docs/SPEC.md`.** Wait for my approval before you build anything.
3. **Build in the milestone order from §7.** After each milestone:
   - run its verification
   - write a short report in `docs/progress/M<n>.md` covering what was built, test results, anything you couldn't verify, and the AWS cost so far
   - commit
4. **Never claim something works without proof.** If a step needs a physical device or a second person, write it up as a manual test script and tell me. Don't mark it done.
5. **Keep a running `docs/DECISIONS.md`.** Log every non-obvious choice there, along with the reason for it.

## 1. Constraints

- **iOS:** Swift 6 with strict concurrency, SwiftUI, and Observation. Minimum iOS 18. Use async/await everywhere. Use Swift Testing for tests, and SwiftData for the local cache. Avoid adding third-party dependencies unless one is clearly needed. The expected ones are the Amazon Chime SDK for iOS, the AWS SDK for Swift (for Transcribe streaming), and a libphonenumber port.
- **Backend:** AWS only, defined as code with AWS CDK in TypeScript. Lambdas run Node.js 22 and are written in TypeScript. Use region `us-east-1`. The AWS CLI on this machine is already configured (account `724772092774`).
- **Money:**
  - Real money must not be charged. Everything must be covered by AWS promotional credits.
  - Use only first-party AWS services and first-party Amazon Bedrock models. AWS Marketplace and third-party Bedrock models are often not covered by credits.
  - Avoid anything with an always-on minimum cost: no OpenSearch Serverless, no NAT Gateways, no always-on EC2/RDS, no reserved capacity. Use serverless and pay-per-request only.
  - In M0, create an AWS Budgets alert that fires when the **net cost after credits** goes above $1. Send it to my email, and ask me for the address.
  - Tag every resource with `project=nudge`.
  - `cdk destroy` must be able to tear everything down.
- **Secrets:** store them in SSM Parameter Store as SecureString (it's free). Never commit secrets.
- **Apple Developer account:** I don't have one. A friend's paid team will be used.
  - Write `docs/APPLE_SETUP.md` as a checklist my friend and I can follow remotely:
    1. They invite me to their App Store Connect team with the roles **App Manager** and **Developer**, with access to Certificates, Identifiers & Profiles.
    2. We register a bundle ID under their team and enable its capabilities: Push Notifications, Sign in with Apple, Communication Notifications, Background Modes, and App Groups.
    3. They create an **APNs auth key (.p8)** and send me the Key ID, the Team ID, and the file through a secure channel. I put them into SSM.
    4. Installs go through TestFlight internal testing.
  - Keep the Team ID and bundle ID in one xcconfig so they're easy to change.
  - **Gotcha: TestFlight builds use the *production* APNs environment. Debug builds use *sandbox*.** Register each device token together with its environment, and send pushes to the matching APNs host.
- **Design:**
  - Install and follow the Apple design skill: `npx skills add https://github.com/emilkowalski/skills --skill apple-design`.
  - That skill is written for the web. Translate it to SwiftUI:
    - Use springs (`.spring(response:dampingFraction:)`) with the skill's defaults: move 1.0/0.4, sheet 0.8/0.3.
    - Animations must be interruptible, and gestures should hand their release velocity into the following animation.
    - Haptics: use `.sensoryFeedback`, and only at meaningful moments (commit, success, error, snap).
    - Support Dynamic Type everywhere.
    - Respect `accessibilityReduceMotion` (cross-fade instead of sliding) and `accessibilityReduceTransparency`.
  - Visual style is **pastel and flat**:
    - solid fills, no gradients, no decorative shadows
    - system chrome (tab bar, nav bar) stays standard iOS
  - A separate designer (Devin) is making the Figma file. Put every color, radius, spacing value, and type style into a `DesignSystem` module built from the tokens in Appendix A. That way the Figma file can be matched later by changing tokens only.

## 2. Product definition

Every user has the same experience. There are no roles.

### 2.1 Accounts and friends
- Sign in with Apple, through Cognito federation.
- On first sign-in, the user must accept the Terms of Service and Privacy notice before going further. That document explicitly covers:
  - calendar free/busy sharing
  - uploading and AI analysis of the last 30 days of photos
  - live transcription of calls, including the other participant's speech
  - AI-generated call memories

  Record the ToS version and the time it was accepted. There is **no** indicator during calls; this consent covers it. (Note in DECISIONS.md that a lawyer should review the ToS before a public launch.)
- **Profile:**
  - A unique **handle**, like Instagram: 3–20 characters from `a-z 0-9 _ .`, case-insensitive, with reserved words blocked. Check availability live as the user types.
  - A display name and an optional avatar.
- **Optional phone number,** verified by SMS through Cognito. It's only used so friends can find you from their contacts.
- **Adding friends:**
  - By handle search.
  - **From contacts.** Numbers are normalized to E.164 on the device and hashed with SHA-256; the server matches the hashes and does **not** store the uploaded list.
  - **By share link.**
  - Friend requests must be accepted. Friendship is mutual.
- **Nicknames are per person.** Each user can give each friend a private nickname ("Mom"), and all copy that user sees uses it.
- Remove friend, block, and **delete account** (the App Store requires this). Deleting an account deletes all of that user's data, including S3 objects and vectors.

### 2.2 Availability
- Read **free/busy only** from Apple Calendar using EventKit. Events marked "free" are ignored, and so are calendars the user has turned off in Settings. Only `{start, end}` busy blocks for the next 7 days leave the device, never titles.
- Put calendars behind a `CalendarProvider` abstraction.
  - Implement `AppleCalendarProvider` now.
  - Design `GoogleCalendarProvider` as a *server-side* provider (OAuth, sync on the server) that is **not built yet**. Leave a stub.
- **Sync triggers:**
  - app launch and foreground
  - `EKEventStoreChanged`
  - `BGAppRefreshTask`
  - handling any notification action
- **Also report context state** whenever the app runs:
  - **Focus:** `INFocusStatusCenter`, which needs the Communication Notifications entitlement and user permission.
  - **Driving:** Core Motion's `automotive` activity with medium confidence or higher in the last 10 minutes.
  - Each report is time-stamped.

### 2.3 Nudges
- **Matching:** a scheduled backend job (EventBridge Scheduler, every 5 minutes) finds friend pairs with a **mutual free window that starts now**. The window must be at least the larger of the two users' minimum lengths (default **5 minutes**).
- **Suppress the nudge if either user:**
  - is in quiet hours in their local time zone (default 00:00–08:00, adjustable)
  - reported Focus in the last 15 minutes (when the "respect Focus" setting is on)
  - reported driving in the last 15 minutes
  - is already in a nudge or a call
  - has calendar data more than 48 hours old (in that case send at most one "open Nudge to keep availability fresh" notice per week)
  - is over their frequency limit
- **Pre-check:** send a silent push to both users about 60 seconds before the nudge so their devices can report fresh Focus/driving state. If no answer comes back, go ahead anyway; this is best effort.
- **Frequency** is one global setting: Off / Low / Normal (default) / High. Each level sets:
  - a daily cap per user
  - a cooldown per pair
  - a minimum gap between any two nudges

  Pick sensible values and document them. **"See this less often"** moves the user one level down.
- **Choosing a pair** when several are possible: prefer pairs that have a follow-up topic due, then the pair with the longest time since their last call.
- **Copy:** each person sees their own version.
  - Standard: "You and Mom are both free for the next 10 minutes. Call?" The minutes are the mutual window, rounded down to 5, and shown as "the next hour" if 60 or more.
  - With a follow-up topic due: "You and Mom are both free for 15 minutes. Want to follow up about the physics exam?"
- **Delivery with the app closed** is a normal APNs alert push with the category `NUDGE` and these actions:
  - **Accept.** This is a foreground action: it opens the app to a waiting screen.
  - **Skip.**
  - **See this less often.**

  The actions appear when the notification is long-pressed. Build a Notification Content Extension so the expanded view shows both avatars and the free window.
- **Delivery with the app open:** suppress the system banner and show a custom **in-app banner that drops down from the top** with Accept and Skip. It springs in and can be swiped away. Long-pressing it opens a menu with "See this less often"; after choosing it, show a toast with **Undo**.
- **Nudge states:** `pending → accepted_by_one → matched → in_call`, or `skipped` / `expired`. A nudge expires **3 minutes** after it's sent.
  - When a nudge ends, clean up the notification on the other device where possible (a silent push that removes it).
  - Expiring counts as skipping.
- **Both accept:**
  1. The backend creates a Chime meeting.
  2. Any participant who isn't already on the waiting screen gets a **VoIP push**, and CallKit rings as an incoming call.
  3. Participants already on the waiting screen join directly.
- **One accepts, the other skips or lets it expire:**
  - If the skipper's setting "When I skip" is **Send a follow-up message** (the default), the backend generates a short, warm, natural in-app message from the skipper, for example "Can't right now, I'll call you soon!", and delivers it to the person who accepted, with a push.
  - If the setting is **Send nothing**, nothing is sent.
  - Either way, the person who accepted sees a calm "Mom can't right now" state on the waiting screen.

### 2.4 Calls
- Build the video call ourselves using the **Amazon Chime SDK**. It's 1:1 only.
- Use **CallKit + PushKit** so incoming calls ring even when the app is closed or the phone is locked, and add background modes for voip and audio. When a call is answered on the lock screen, video starts as soon as the phone is unlocked.
- **Layout:**
  - the remote video fills the screen
  - a draggable self-view **mini window** snaps to the corners, using momentum projection per the design skill
  - controls: mute, camera on/off, flip camera, end call
- Handle these states: connecting, reconnecting, the other person's camera off, and poor network.

### 2.5 Photo references during a call
- **Indexing (in the cloud):** only photos **taken in the last 30 days**.
  - The device uploads a 1024-pixel-long-edge JPEG of each one through a presigned S3 PUT, using a background `URLSession`. It runs incrementally, watching for Photos library changes, and during `BGProcessingTask` runs (preferably while charging).
  - Metadata sent with each photo: capture date, a place name reverse-geocoded on the device, and the screenshot subtype flag.
  - Skip hidden photos. Skip screenshots unless the user turns on "Include screenshots".
  - Anything older than 30 days is deleted from S3 and from the index. Use an S3 lifecycle rule plus a daily sweep.
- **Pipeline** (runs on an S3 event):
  1. **Safety check** with Rekognition `DetectModerationLabels`. Exclude Explicit, Non-Explicit Nudity, Violence, Visually Disturbing, Hate Symbols, and Rude Gestures.
  2. **Sensitive text check** with Rekognition `DetectText`, plus rules and an LLM check. Exclude documents and screenshots that contain card numbers, bank or account details, IDs, passwords or codes, or medical records.
  3. Photos that fail either check are **never searchable**, but still show in a count in Settings.
  4. A **caption** is generated with an Amazon Nova multimodal model.
  5. An **embedding** is made with Amazon Titan Multimodal Embeddings, using the image plus its caption.
  6. The embedding is stored in **Amazon S3 Vectors**, with metadata filters for `userId`, `takenAt`, and `place`.
- **Vector store fallback:** if S3 Vectors isn't available in this account, store one packed float32 blob of vectors per user in S3. The detector Lambda loads it and keeps it cached while the call lasts. A month of photos is small enough for brute-force cosine search. Record which option you chose in DECISIONS.md.
- **Live pipeline:**
  - **Each device transcribes only its own microphone** with Amazon Transcribe streaming. That gives speaker attribution for free, and both people can talk at once.
  - Use Cognito identity-pool credentials limited to `transcribe:StartStreamTranscription`.
  - Final transcript segments go to the backend over the WebSocket API.
- **Reference detector:**
  - Runs on Amazon Nova Lite, looking at a rolling window of about 60 seconds of *both* speakers' transcript.
  - Decides whether the *latest speaker* is referring to something a photo would show ("that hike last weekend", "the cake I made").
  - Outputs `{isReference, query, dateHint, placeHint, confidence}`.
- **Search** covers only the **speaker's own** library, combining vector similarity with the date and place filters. Suggest nothing unless the result clears a similarity threshold, which should be tuned by the eval in §6.
- **Sharing mode** is a per-user setting:
  - **Ask first (default):** a small suggestion chip with a thumbnail appears next to the *speaker's* mini window, with Show and ✕. It disappears on its own after 8 seconds. Only the speaker ever sees suggestions.
  - **Automatic:** the photo is shown right away, with a 2-second "Hide" option.
  - **Off.**
- **Showing a photo, kept in sync on both ends:**
  - Send control messages over **Chime real-time data messages**, topic `photo`, types `offer | ready | end | cancel`, each carrying a sequence number.
  - Photo bytes are fetched through a **presigned GET that lasts 5 minutes**, and only for the other person in the call.
  - Handshake:
    1. The sender sends `offer`.
    2. The recipient downloads the photo, then sends `ready`.
    3. Both sides start the swap animation. The sender starts when it receives `ready`, and the recipient starts right after sending it.
    4. If `ready` doesn't arrive within 1.5 seconds, the sender goes ahead anyway.
  - Order events by the Chime server timestamp. Log every shown photo in the call record for auditing.
- **Display rule:** every device decides what its own mini window shows, using the same function on both phones:
  ```
  if the OTHER participant has an active photo → show the other participant's photo
  else if I have an active photo               → show my own photo
  else                                         → show my camera self-view
  ```
  Some examples:
  - If only A shares, both phones show A's photo in their mini window.
  - If both share at the same time, each person sees the *other's* photo.
  - When one photo ends, both phones re-evaluate and fall back cleanly.
- **Swap animation:** the mini window changes from video to photo seamlessly, with a spring cross-dissolve and a slight scale. There's a subtle label with the sender's nickname, such as "from Mom". It changes back the same way.
- **Queue** (per sender, maximum 5, the oldest is dropped): the more photos queued, the shorter each is shown.
  - 1 photo: 6 seconds
  - 2: 4.5 seconds each
  - 3 or more: 3.5 seconds each

  Small dots show the queue position. The sender can swipe their own photo away to end it early, which sends `cancel`. Both ends time from the same `ready` moment so they end together.
- **Latency targets:**
  - from the end of an utterance to the suggestion chip: p50 ≤ 2.5 s, p95 ≤ 4 s
  - from tapping Show to the photo appearing on both devices: p95 ≤ 800 ms

  Measure every stage.

### 2.6 Memory and follow-ups
- Each device uploads its transcript segments during the call. They're stored with a **24-hour TTL**.
- **After the call:**
  1. A Nova model writes a short summary and extracts **topics** in the form `{title, whose (which participant it's about), followUpAfter (date or null), summary}`. For example: "physics exam", about the other person, follow up the day after the exam.
  2. The raw transcript is deleted as soon as the summary is saved.
- Memories belong to the **pair**. Both people can see them on the friend's profile. **Either person can delete any memory, and the deletion applies to both.** There is also a global Memory on/off switch; if either person has it off, nothing is saved for that call.
- Topics that are due feed nudge copy (§2.3). A topic is marked used once a call happens after it was suggested. Users can dismiss topics.
- After a call ends, show a short **call summary screen**: its duration, plus "We'll remember" chips for each topic, each deletable. It closes itself if ignored.

### 2.7 Messages
- There's a simple in-app thread per friend: text messages, auto follow-up messages (labeled "Sent automatically"), and system events such as "Missed nudge · 3:40 PM" and "Called · 12 min".
- New messages arrive by push. Keep the thread minimal; this isn't a chat app.

### 2.8 Settings
- **Nudges:** frequency, quiet hours, minimum window length (5 / 10 / 15 / 30 minutes), respect Focus, respect driving, and "When I skip" (follow-up message / nothing).
- **Calendars:** Apple Calendar with a toggle for each calendar. Google Calendar shows as "Coming soon".
- **Photos:**
  - sharing mode (Ask first / Automatic / Off)
  - indexing on/off
  - a status readout: "132 photos from the last 30 days indexed · 4 excluded for safety"
  - include screenshots
  - delete all indexed photos
- **Memory:** on/off, view all memories, delete all memories.
- **Account:** handle, display name, avatar, phone, blocked users, sign out, delete account, Terms and Privacy.

### 2.9 Works when the app is closed
This requirement applies across everything above.
- Nudges arrive, and Accept, Skip, and See less work from the lock screen.
- Calls ring through CallKit.
- Messages and the follow-up message arrive by push.
- Availability and state reports use every background opportunity iOS allows.

The known limit is that iOS decides how often a closed app gets background time, so calendar freshness is best effort. Write down how each behavior works when the app is foreground, backgrounded, terminated, and force-quit.

## 3. Decisions already made (don't reopen these)
- The video call is our own (Chime SDK), not FaceTime.
- Calendars: free/busy only. Apple now, Google later.
- Quiet hours start at midnight; nudges are skipped while driving or in Focus; minimum window is 5 minutes.
- Photo sharing defaults to Ask first, with Automatic as a setting.
- When both people share at once, each sees the other's photo. Queued photos show for less time.
- Follow-up messages are in-app messages.
- Handles are like Instagram's, and friends can be added from contacts.
- AI runs in the cloud. Only the last month of photos is uploaded and indexed.
- "See this less often" affects all nudges.
- The backend is AWS, and sign-in is Sign in with Apple.
- There's no in-call recording indicator; consent comes from the ToS at first sign-in.

## 4. Architecture (starting point; refine it in SPEC.md)

**iOS app modules** (as local Swift packages):
- `DesignSystem`
- `Networking` (REST client and WebSocket client with automatic reconnect)
- `Auth`
- `Friends`
- `Availability` (the CalendarProvider, Focus and driving reporters)
- `Nudges` (notification categories, the in-app banner, the waiting room)
- `Calls` (Chime, CallKit, PushKit)
- `Transcription`
- `PhotoIndex`
- `PhotoShare` (a state machine plus the pure display-rule function)
- `Messages`
- `Memory`
- `Settings`
- `BackgroundTasks`

**Extensions:**
- a Notification Content Extension for the expanded nudge
- a Notification Service Extension for avatars and localized copy

The app and its extensions share data through an App Group.

**Backend:**
- **Cognito:** a user pool with Apple as the identity provider, plus an identity pool for Transcribe.
- **API Gateway:** an HTTP API with the Cognito JWT authorizer for REST, and a **WebSocket API** for live events (nudge updates, call match, messages, transcript segments).
- **Lambda** handlers.
- **DynamoDB:** a single table.
- **S3:** photos and avatars, private, SSE-S3 encryption, lifecycle rules.
- **S3 Vectors.**
- **EventBridge Scheduler:** nudge matching, the 30-day photo sweep, and follow-up topic due dates.
- **Bedrock:** Nova Lite and Titan Multimodal Embeddings.
- **Rekognition.**
- **Transcribe streaming.**
- **Chime SDK Meetings.**
- **APNs:** HTTP/2 from Lambda using token authentication; alerts on topic `bundleId`, VoIP on `bundleId.voip`.
- **SSM** for secrets, and **CloudWatch** metrics and alarms.

**Required Mermaid sequence diagrams:**
- sign-in and handle creation
- adding a friend from contacts
- calendar sync
- nudge match → both accept → call
- nudge match → one skips → follow-up message
- photo index pipeline
- in-call reference → suggestion → show, including the case where both share at once
- end of call → memory → follow-up nudge

## 5. Data models (starting point)

Use one DynamoDB table (`pk`, `sk`) and GSIs as needed:

| Entity | Key | Main attributes |
|---|---|---|
| User | `USER#id / PROFILE` | handle, displayName, avatarKey, tz, settings{frequency, quietStart, quietEnd, minWindowMin, respectFocus, respectDriving, skipBehavior, photoMode, photoIndexing, includeScreenshots, memoryEnabled}, tosVersion, tosAcceptedAt, createdAt |
| Handle claim | `HANDLE#handle / CLAIM` | userId (conditional put to guarantee uniqueness) |
| Phone claim | `PHONE#sha256 / CLAIM` | userId |
| Device | `USER#id / DEVICE#deviceId` | apnsToken, voipToken, apnsEnv (sandbox/production), appVersion, lastSeenAt |
| Availability | `USER#id / AVAIL` | busyBlocks[{start,end}], syncedAt, source, focus{isFocused, at}, driving{isDriving, at} |
| Friend request | `USER#to / FREQ#from` | status, createdAt |
| Friendship (one per direction) | `USER#a / FRIEND#b` | nickname (a's name for b), since, lastCallAt, lastNudgeAt, blocked |
| Nudge | `NUDGE#id / META` | pairKey, participants, window{start,end}, copyByUser, topicId?, state, responses{userId→accepted/skipped/expired}, expiresAt, callId? |
| Call | `CALL#id / META` | nudgeId, chimeMeetingId, participants, startedAt, endedAt, memoryAllowed |
| Transcript segment | `CALL#id / SEG#ts#userId` | text, ttl (24 h) |
| Photo share (audit) | `CALL#id / SHARE#ts` | senderId, photoId, shownAt, durationMs |
| Photo | `USER#id / PHOTO#assetHash` | s3Key, takenAt, place, caption, isScreenshot, safety{status, labels}, vectorId, ttl (takenAt+31d) |
| Topic | `PAIR#pairKey / TOPIC#id` | title, aboutUserId, summary, followUpAfter, status(open/suggested/used/dismissed), sourceCallId |
| Call summary | `PAIR#pairKey / SUMMARY#callId` | summary, durationSec, createdAt |
| Message | `PAIR#pairKey / MSG#ts#id` | senderId, body, kind(user/auto_followup/system), readBy |
| WS connection | `CONN#id / META` | userId (GSI), connectedAt, ttl |

`pairKey` is the two user IDs in sorted order. Also define the Swift client models, the SwiftData cache entities, and the exact JSON shapes for every REST endpoint, WebSocket event, APNs payload, and Chime data message.

## 6. Verification methodology

**Pure logic gets exhaustive unit tests,** including property-based tests where they fit. That covers:
- **Overlap engine:** time zones, DST changes, quiet hours that cross midnight, adjacent and overlapping busy blocks, stale data.
- **Frequency limiter.**
- **Nudge state machine:** every transition, plus expiry.
- **Photo display-rule function:** a full truth table, including both sharing at once.
- **Queue timing**, handle validation, and phone normalization.

**Backend integration tests** run against a deployed **dev** stage.
- Sign in with Apple can't be automated, so the dev stage (and never prod) also allows Cognito username/password test users.
- Scripts create two test users, add them as friends, upload busy blocks, force a matching run, and assert on the nudge, responses, match, follow-up message, and memory.

**Peer bot:** a Node script that signs in as a test user, accepts nudges through the API, and joins the Chime meeting (Chime SDK JS in headless Chrome with fake media). It can send and receive `photo` data messages and play prerecorded speech. With it, I can test calls, photo sync, and both-sharing-at-once with **one** phone.

**Device versus simulator:**
- Remote push works on Apple-silicon simulators.
- CallKit, PushKit, the camera, Focus, and Core Motion need a real device.
- Give each of those a numbered manual test script.
- The final two-person script is written for me and my friend testing **remotely**, each on our own phone through TestFlight.

**AI evaluations,** committed under `evals/`:
- **Reference detector:** at least 120 labeled utterances in a two-speaker context, including hard negatives. Target: precision ≥ 0.85, recall ≥ 0.6.
- **Retrieval:** a test set of about 60 license-free photos with target queries. Target: top-1 ≥ 0.7, top-3 ≥ 0.9.
- **Safety:** use mocked Rekognition responses in unit tests. Use a benign fixture set (fake card numbers, sample IDs, screenshots of fake bank apps) to confirm 100% exclusion. **Commit no explicit imagery.**

**Latency:** log a timestamp at every pipeline stage to CloudWatch and report p50/p95 against the §2.5 targets.

**UI:** capture screenshots of every screen in light and dark mode, at the largest Dynamic Type size, and with Reduce Motion on. Save them to `docs/screens/`.

**Background behavior:** a table of the foreground / background / terminated / force-quit states from §2.9, filled in with what was actually observed on a device.

**Cost:** at the end of each milestone, run `aws ce get-cost-and-usage` for gross and net cost and put the numbers in the progress report.

## 7. Milestones
1. **M0.** Repo layout, CDK skeleton, dev stage, the budget alert, `APPLE_SETUP.md`, CI (xcodebuild tests plus backend tests).
2. **M1.** Auth, ToS, handle, profile, phone, friends (handle search, contacts, link), nicknames, delete account.
3. **M2.** Calendar sync, Focus and driving reports, overlap engine, frequency rules, nudge push with actions, in-app banner, See less.
4. **M3.** Waiting room, match, Chime calls, CallKit and PushKit, follow-up message on skip, Messages.
5. **M4.** Photo indexing pipeline, safety checks, vectors, Photos settings.
6. **M5.** Transcription, reference detector, suggestions, synced photo swap, queue, both-share-at-once.
7. **M6.** Memory, topics, follow-up nudges, call summary screen.
8. **M7.** Design polish matched to Figma tokens, accessibility, background-behavior table, full two-person test script.

## Appendix A — Design tokens (match Figma exactly)

**Colors** (light / dark):

| Token | Light | Dark | Use |
|---|---|---|---|
| bg | #FBF8F4 | #15161C | app background |
| surface | #FFFFFF | #1E2028 | cards, sheets |
| surfaceAlt | #F4EFE9 | #262833 | grouped rows, inputs |
| divider | #ECE7E0 | #2F3240 | hairlines |
| ink | #1F2330 | #F2F1F6 | primary text |
| inkSecondary | #5B6172 | #A9ADBB | secondary text |
| inkTertiary | #9AA0AE | #6E7385 | placeholders |
| lavender / lavenderStrong | #E4DDFB / #6B5BD2 | #3A3358 / #C9BEFF | brand, primary action |
| mint / mintStrong | #D5F0E3 / #2E8B63 | #23423A / #9FE0C2 | accept, success, "free" |
| peach / peachStrong | #FFE2D3 / #C0623A | #4A3128 / #FFBFA0 | skip, secondary |
| sky / skyStrong | #DCEBFA / #3A73B5 | #233447 / #A9CCF2 | info, messages |
| butter / butterStrong | #FCF0C4 / #9A7A12 | #463E22 / #F2DB8A | memory, highlights |
| rose / roseStrong | #FADADF / #C23B4E | #4A262D / #FFA9B5 | end call, destructive |

Pastel fills sit behind **Strong** text and icons. All text must meet WCAG AA contrast.

**Radii:** 8 (chips), 12 (inputs, small cards), 20 (cards, banner), 28 (sheets), full (avatars, round buttons).

**Spacing:** a 4-point base, and use only 4, 8, 12, 16, 20, 24, 32, 40, 56. Screen side margin 20.

**Type:** SF Pro on the Dynamic Type scale. Large titles and friend names use SF Pro Rounded Semibold. Tracking follows the skill's rule of being tighter on large text.

**Elevation:** flat. Separate things with fill contrast and a 1-point divider. No shadows except under the in-call mini window (0 4 16 at 12% ink) so it reads over video.

**Motion:** springs as listed in §1. The nudge banner enters at 0.8/0.3. The photo swap uses a 0.35-second spring cross-dissolve with a scale of 0.96→1.0.
