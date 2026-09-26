# 04 · Photo index and in-call references (1 phone + peer-bot)

| # | Step | Expected | Result |
|---|---|---|---|
| 1 | Take 5 photos today: a mug, your shoes, a plant, a screenshot of Settings, a photo of a fake card (write 4242 4242 4242 4242 on paper). | | |
| 2 | Open the app, keep it open ~1 min, then Settings → Photos. | Status shows photos from the last 30 days indexed; the card photo counted as excluded; the screenshot not uploaded (Include screenshots off). | |
| 3 | Turn Include screenshots on. | Screenshot uploads; indexed or excluded depending on content. | |
| 4 | Start a call with the bot. Say "I just got this plant last week". | Within ~2–4 s a suggestion chip with the plant thumbnail appears next to your mini window, only on your phone. | |
| 5 | Wait 8 s. | Chip auto-dismisses. | |
| 6 | Say it again, tap Show. | Your mini window swaps to the plant (spring cross-dissolve). The bot's log shows `display other` at the same moment (± 100 ms). Reverts after 6 s on both. | |
| 7 | Run the bot with `--share-after 2000` and tap Show on yours at the same time. | Your mini window shows the bot's photo (from Test Friend) while yours shows on the bot. | |
| 8 | Tap Show on 3 suggestions quickly (say three things). | Queue dots; each shows for less time. Swipe your photo away → next one. | |
| 9 | Settings → Photos → Sharing = Automatic. Mention the mug. | Photo shows without asking, with a 2 s "Hide" pill. | |
| 10 | Sharing = Off. Mention the shoes. | Nothing appears. | |
| 11 | Settings → Photos → Delete all indexed photos. | Status goes to 0. | |
