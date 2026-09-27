# Nudge Privacy Policy

Last updated: September 26, 2026

Nudge is a hackathon prototype maintained by the team behind the
[AlanRoybal/hackgt project](https://github.com/AlanRoybal/hackgt). It helps friends
find times to connect, make calls, share relevant photos, and remember conversations.
This policy describes the prototype and its optional integrations.

## Information used by Nudge

- **Account and social information:** account identifiers, display name, handle,
  optional profile photo and phone information, friendships, messages, and call history.
  These support sign-in, friend discovery, communication, and account management.
- **Calendar availability:** with permission, the app reads device calendars and
  uploads busy start/end times. Calendar event titles, notes, attendees, and locations
  are not included in those uploads.
- **Availability context:** authorized Focus status, driving estimates, time zone,
  quiet hours, and preferences help decide when to suggest a call.
- **Photos:** when indexing is enabled, reduced-size copies of eligible recent photos,
  associated date/place metadata, generated captions, and search embeddings are stored
  to retrieve photos mentioned during calls. Automated analysis filters sensitive
  content. Friends see photos you share manually or through enabled automatic sharing.
- **Calls and transcription:** Amazon Chime supports audio/video calls. Microphone
  audio is streamed to Amazon Transcribe to recognize speech. Transcript text supports
  photo suggestions and optional call summaries. Nudge does not implement saved
  audio/video call recordings.
- **Memories:** when both participants allow memories, generated summaries and
  follow-up topics are available to the two participants. Either can delete shared memories.
- **Contact discovery:** if enabled, contact phone numbers are normalized and hashed
  on the phone before matching. The submitted contact list is not retained as a list.
- **Operational data:** device and notification tokens, suggestion outcomes, timings,
  errors, and service logs support notifications, debugging, and reliability.

## Optional WHOOP integration

Connecting WHOOP authorizes Nudge to read recent sleep and workout records and refresh
that access in the background. Nudge uses those records to estimate usual sleep hours
and a short buffer after completed workouts, reducing nudges at potentially inconvenient
times. These estimates can be delayed and are not live sleep or exercise detection.

Nudge retains server-side authorization tokens, connection preferences, synchronization
status, and derived time windows. Raw WHOOP sleep/workout records are processed to derive
those windows rather than retained in the application database. WHOOP data is not sent
to friends or used in Nudge's photo-search or conversation-summary AI prompts.

You can independently disable sleep or workout estimates, or disconnect WHOOP in
Settings. Disconnecting deletes Nudge's saved connection and estimates and attempts to
revoke WHOOP authorization. Authorization can also be revoked through WHOOP.

## Service providers and sharing

Nudge uses Amazon Web Services for authentication, hosting, storage, calling,
transcription, image analysis, and AI features, including Amazon Bedrock and Rekognition.
Apple provides platform permissions, optional Apple sign-in, and push delivery.
WHOOP provides data only after you authorize the optional connection.

Information needed to deliver those features is processed by these providers.
Profile information, messages, shared photos, and shared memories are disclosed to
other users as required by the corresponding social features. The prototype does not
implement advertising or sale of personal information.

## Retention and controls

Final transcripts are deleted by post-call processing and assigned a 24-hour database
expiry as a fallback; expiry-based deletion may occur later. Stable partial transcripts
used for live retrieval are not saved as transcript history. Indexed photos and vectors
are scheduled for removal once outside the 30-day photo window. Diagnostic logs have
a configured two-week retention; other temporary records may expire separately.

Account information, messages, and memories remain until removed through the app or
account deletion. Settings provides controls for photo indexing, sharing, memories,
calendars, WHOOP, and account deletion. Device permissions can also be changed in iOS
Settings. Account deletion removes application account data and disconnects WHOOP;
operational logs may remain until their configured expiry. Deletion from Nudge cannot
remove copies another person independently saved outside the app.

## Contact and updates

For privacy questions or deletion assistance, contact the project team member who
invited you to test, or use the [project's issue tracker](https://github.com/AlanRoybal/hackgt/issues)
to request a private contact channel. Do not include personal records, credentials, or
health information in a public issue.

This policy may be updated as the prototype changes. The current version and its
update date are published on this page.

## Adaptive nudge timing

We use responses to automatic invitations (accept, skip, or no response), invitation timestamps, and your time zone to adjust timing temporarily. Recent behavior has more influence, and automatic cooldowns expire. The engine uses at most 100 responses from the last 28 days; older entries are ignored and pruned on the next response. This private history stays on your account until replaced or deleted with the account, and is not shared with friends. No location data is needed for this feature.
