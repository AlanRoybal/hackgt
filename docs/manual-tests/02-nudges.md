# 02 · Nudges (1 phone + peer-bot)

Setup: `cd tools/peer-bot && npm run bot -- stand-in --friend <your handle>`; accept the bot's friend request in the app. Make sure your calendar has no event right now and you're outside quiet hours. Frequency → High in Settings to avoid cooldowns while testing.

Force a match instead of waiting 5 minutes (dev only):
```sh
curl -X POST "$API/dev/matcher/run" -H "authorization: Bearer $TOKEN"   # or use backend/integ helpers
```

| # | Step | Expected | Result |
|---|---|---|---|
| 1 | Add a calendar event covering now. Open the app (syncs). Force matcher. | No nudge (you're busy). | |
| 2 | Delete the event, reopen app, force matcher. Lock the phone. | ~60 s later: lock-screen nudge "You and Test Friend are both free for …". | |
| 3 | Long-press the notification. | Expanded view shows both avatars + free-window bar; actions Accept / Skip / See this less often. | |
| 4 | Tap Skip (bot started with `--skip` off, so it accepted). | Bot's thread gets your auto follow-up message (Settings → When I skip = Send a follow-up message). | |
| 5 | Settings → When I skip → Send nothing. Repeat, Skip. | No message sent. | |
| 6 | Repeat, choose See this less often. | Frequency drops one level (High → Normal). | |
| 7 | With the app open on Friends, force a match. | Custom banner drops from the top with Accept/Skip; no system banner. | |
| 8 | Swipe the banner up. | Dismissed without responding; nudge still pending. | |
| 9 | Long-press the banner → See this less often. | Toast "Nudges set to Low · Undo". Tap Undo → back to previous level. | |
| 10 | Let a nudge sit 3 minutes without responding. | It disappears from Notification Center; the bot's side shows expired. | |
| 11 | Turn on a Focus (e.g. Do Not Disturb). Open the app once (reports focus). Force matcher. | No nudge while Focus is on (respect Focus on). | |
| 12 | Settings → quiet hours set to start 1 minute from now. Force matcher after that. | No nudge. | |
| 13 | Driving: go for a drive with the app recently opened, force matcher from a laptop. | No nudge while driving. (Or verify the `driving` report in DynamoDB after a drive.) | |
