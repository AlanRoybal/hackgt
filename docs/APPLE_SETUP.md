# Apple setup checklist (remote)

Alan doesn't have a paid Apple Developer account; a friend's team is used. Everything below can be done over chat/video. Nothing here costs Alan money.

## Friend (account holder / admin)

1. **Invite Alan to the team.** App Store Connect → Users and Access → **+** → Alan's Apple ID email.
   - Roles: **App Manager** and **Developer**.
   - Tick **Access to Certificates, Identifiers & Profiles**.
   - Apps: All apps (or just Nudge once it exists).
2. **Find the Team ID.** developer.apple.com → Account → Membership details → Team ID (10 chars). Send it to Alan.
3. **Register the App ID** (or let Alan do it after step 1): Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App.
   - Bundle ID (explicit): e.g. `com.<friendteam>.nudge`.
   - Capabilities: **Push Notifications**, **Sign in with Apple**, **Communication Notifications**, **App Groups**, **Time Sensitive Notifications** (optional).
   - Background Modes are set in Xcode, not here.
4. **App Group:** Identifiers → **+** → App Groups → `group.<bundleId>`. Attach it to the App ID above and to the two extension IDs Xcode creates (`<bundleId>.NotificationContent`, `<bundleId>.NotificationService`).
5. **APNs auth key:** Keys → **+** → name "Nudge APNs" → enable **Apple Push Notifications service (APNs)** → Continue → Register → **Download the .p8** (only downloadable once).
   - Send Alan: the `.p8` file, its **Key ID**, and the **Team ID**, via a secure channel (1Password share, Signal — not email/Slack plaintext).
   - The same key works for alert, background and VoIP pushes, sandbox and production.
6. **App Store Connect app record:** Apps → **+** → New App → iOS, name "Nudge (dev)", bundle ID from step 3, SKU `nudge-dev`.
7. **TestFlight:** once Alan uploads a build, TestFlight → Internal Testing → create group "Core" → add Alan and yourself. Internal testers need no Beta App Review.

## Alan

1. Accept the team invite email. In Xcode → Settings → Accounts, add the Apple ID; the friend's team appears.
2. Edit `ios/Config/Signing.xcconfig`:
   ```
   DEVELOPMENT_TEAM = <TEAM_ID>
   NUDGE_BUNDLE_ID = com.<friendteam>.nudge
   ```
   Then `cd ios && xcodegen` and open `Nudge.xcodeproj`. Automatic signing registers your iPhone's UDID on first run.
3. Store the APNs key in SSM (never commit it):
   ```sh
   cd backend
   ./scripts/put-apns-secrets.sh dev <KEY_ID> <TEAM_ID> <BUNDLE_ID> ~/Downloads/AuthKey_<KEY_ID>.p8
   ```
   Repeat with `prod` if you deploy a prod stage. Delete the `.p8` from Downloads afterward (keep a copy in your password manager).
4. Redeploy: `cd backend && npm run deploy:dev` (Sign in with Apple's audience check uses the bundle ID from SSM).
5. **Sign in with Apple** needs nothing else: the native flow's token audience is the bundle ID.
6. **SMS (optional phone step):** new AWS accounts are in the SNS SMS sandbox. AWS Console → SNS → Text messaging (SMS) → Sandbox destination phone numbers → add your number and your friend's, verify each with the code they receive.
7. Upload to TestFlight: Xcode → Product → Archive → Distribute App → App Store Connect → Upload. (Needs the App Manager role from step 1.)

## APNs environment gotcha

- **Debug builds from Xcode** get **sandbox** device tokens → pushes must go to `api.sandbox.push.apple.com`.
- **TestFlight / App Store builds** get **production** tokens → `api.push.apple.com`.

The app reports `apnsEnv` with every token registration (derived from the embedded provisioning profile's `aps-environment`), and the backend picks the host per device. If pushes silently fail, check this first.

## Two-person remote test

Alan and the friend each install the TestFlight build on their own iPhone, sign in, add each other by handle, then follow `docs/manual-tests/two-person.md`.
