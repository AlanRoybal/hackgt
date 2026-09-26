# Two-person remote test (Alan + friend, TestFlight)

Both install the latest TestFlight build. Do this on a video/voice chat on a laptop so you can talk about what you see.

| # | Who | Step | Expected | Result |
|---|---|---|---|---|
| 1 | Both | Sign in with Apple, accept Terms, pick handles, allow all permissions. | | |
| 2 | Alan | Add friend by handle. Friend accepts. | Both see each other in Friends. | |
| 3 | Both | Set a nickname for the other (e.g. "Sam"). | Only you see your nickname. | |
| 4 | Both | Clear calendars for the next hour, frequency High, outside quiet hours. Open the app once. | | |
| 5 | Either | Force matcher (dev hook) or wait ≤ 5 min. | Both phones get a nudge within ~60 s, each with their own nickname for the other. | |
| 6 | Alan | Accept from lock screen. | Waiting room. | |
| 7 | Friend | Skip. | Alan sees "Sam can't right now" + the auto message in Messages. | |
| 8 | Both | Next nudge: both accept (one from lock screen with phone locked). | Call connects; locked phone rings via CallKit. | |
| 9 | Both | Each take a photo of something on your desk before the call. In the call, talk about it. | Suggestion chip appears only for the speaker. | |
| 10 | Alan | Show a photo. | Both mini windows show Alan's photo together; revert together after 6 s. | |
| 11 | Both | Count down "3, 2, 1" and both tap Show on a suggestion. | Each sees the other's photo. | |
| 12 | Both | Mention an upcoming event (e.g. "my physics exam is Thursday"). End the call. | Summary screen: duration + "We'll remember: physics exam". | |
| 13 | Friend | Delete one memory chip. | Gone for Alan too (Friend profile → Memories). | |
| 14 | Both | After the follow-up date (or use the dev hook to set followUpAfter to now), force matcher. | Nudge says "…Want to follow up about the physics exam?" | |
| 15 | Both | Kill the app; send a message from the other side. | Push arrives. | |

Notes / bugs:
