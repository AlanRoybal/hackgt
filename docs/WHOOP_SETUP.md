# WHOOP availability enhancement

Optional connection under Settings → WHOOP. The cloud API supplies recorded activities,
not reliable live sleep/workout state. Nudge derives a usual sleep window from at least
three main sleeps in the past seven days (latest within 48 hours), and a 30-minute buffer
after a completed workout. Both controls can be disabled independently. A record arriving
after the buffer ends will not block nudges. Estimates expire after 15 minutes without a
successful sync. Calendar, quiet hours, Focus, and driving rules continue to apply.

## Developer configuration

1. Create an application at https://developer.whoop.com/ using your WHOOP account.
2. Register the exact redirect URI: `app.nudge.whoop://oauth`.
3. Enable/request `read:sleep`, `read:workout`, and `offline` (refresh token).
4. Store Client ID as `/nudge/dev/whoop/clientId` (SSM String), and Client Secret as
   `/nudge/dev/whoop/clientSecret` (SSM SecureString), in us-east-1 using the `nudge-dev`
   AWS profile. Never commit the secret or put it in the iOS app.
5. Deploy with `AWS_PROFILE=nudge-dev npm run deploy:dev` from `backend`.
6. Build/install the app, open Settings → WHOOP → Connect WHOOP, and grant access.
7. Confirm last-sync time and estimated sleep window. Fewer than three recent main
   sleeps deliberately yields no estimated window. Disconnect removes local integration
   data and attempts WHOOP token revocation; if WHOOP is unavailable, revoke in WHOOP too.

## Implementation

Authenticated `/me/whoop` routes return only status and derived timing data. The native
web authentication session returns an authorization code to the app, which exchanges it
through the authenticated backend using a single-use, expiring state bound to its user.
Credentials stay server-side in the encrypted DynamoDB table and are never returned in
status responses. Refresh uses a per-connection synchronization lock and saves rotated
tokens before fetching data. Sync runs every five minutes and on connection. It only
retains derived time windows, not raw sleep/workout records or heart-rate measurements.
Deleting an account disconnects WHOOP. Friends never receive WHOOP records or reasons.

This polling implementation targets the hackathon prototype. Before broader rollout,
add a queued worker per connection and WHOOP signed webhooks for timely updates, plus
live OAuth/refresh/revoke acceptance tests with a real WHOOP account. Do not describe
the inferred sleep window as proof that someone is currently asleep.

References: https://developer.whoop.com/docs/developing/oauth/ and
https://developer.whoop.com/docs/developing/webhooks/
