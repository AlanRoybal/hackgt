# 01 · Sign-in and onboarding (1 phone)

Build: Debug from Xcode onto your iPhone (sandbox APNs) or TestFlight.

| # | Step | Expected | Result |
|---|---|---|---|
| 1 | Delete the app if installed. Install and launch. | Launch → Welcome cards (3, swipeable). | |
| 2 | Tap Sign in with Apple, complete Face ID. Choose "Hide my email" once, "Share" once on a second Apple ID if available. | Terms & consent screen appears; no other tab reachable. | |
| 3 | Kill the app, relaunch. | Still on Terms (not accepted yet). | |
| 4 | Tap I agree. | Choose your handle. | |
| 5 | Type `ab` then `a..b` then a handle you know is taken (a bot's) then a free one. | too short → invalid; `..` → invalid; taken → "Taken"; free → check mark. Status updates within ~0.4 s of stopping typing. | |
| 6 | Set a display name and pick an avatar from Photos. Continue. | Phone screen (optional). | |
| 7 | Enter your number (must be an SNS sandbox verified number, see APPLE_SETUP). | SMS code arrives within 30 s. | |
| 8 | Enter a wrong code, then the right one. | Wrong → inline error; right → continues. | |
| 9 | Permission primers: allow each (Notifications, Calendar, Photos, Contacts, Camera & Mic, Focus, Motion). | Each primer explains why, then shows the system prompt. | |
| 10 | Deny one (e.g. Contacts) on a reinstall. | Denied variant with "Open Settings". | |
| 11 | Add your first friends: contacts screen lists any contact who has verified their phone in Nudge. | Match appears with Add. | |
| 12 | Friends tab → share link. Send `nudge://add/<handle>` to yourself in Notes, tap it. | App opens Add Friends prefilled with that handle. | |
| 13 | Kill and relaunch. | Lands on Friends directly (tokens in Keychain). | |
| 14 | Settings → Account → Delete account → confirm. | Back to Welcome. Signing in again creates a fresh account (ToS + handle again). | |
