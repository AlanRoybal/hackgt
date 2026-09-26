# 03 · Calls (1 phone + peer-bot)

Setup as in 02, bot running without `--skip`.

| # | Step | Expected | Result |
|---|---|---|---|
| 1 | App open, Friend profile → Call now. | Waiting room "Waiting for Test Friend…" with countdown. Bot accepts → call connects. | |
| 2 | In call: remote video full-screen (bot's fake video pattern), your self-view mini window top-right. | | |
| 3 | Drag the mini window and flick toward each corner. | Follows the finger 1:1, snaps to the projected corner with a spring, haptic on snap. | |
| 4 | Mute, camera off, flip, then end. | Each control works; bot sees your camera off tile; end → both leave, summary screen shows. | |
| 5 | Lock the phone. Force a match; accept from lock screen (Accept opens the app). Go back to lock screen while waiting. Have the bot accept later. | CallKit rings on the lock screen. Answer → audio connects; unlock → video starts. | |
| 6 | Kill the app from the app switcher. Force a match; from the bot's side, accept first; you accept from the notification. | App opens to waiting room → call matched → joins. | |
| 7 | Toggle Airplane mode for 5 s mid-call. | "Reconnecting…" banner, then recovers. | |
| 8 | Use a Network Link Conditioner "Very Bad Network" profile. | Poor network banner. | |
