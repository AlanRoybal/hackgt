# peer-bot

Scripted Nudge users for testing calls and photo sync without a second person.

```sh
npm install
npm test                 # photo-share protocol unit tests (display rule, queue, simultaneous share, ready timeout)
npm run smoke            # headless Chrome + Chime bundle + fake camera/mic
npm run bot -- two-bots --verbose        # two bots: friend → Call now → match → Chime → photo sync checks
npm run bot -- stand-in --friend <handle> # bot plays your friend: accepts nudges, joins calls, answers photo offers
```

Config comes from `backend/cdk-outputs.dev.json`, or `NUDGE_API_URL` + `NUDGE_WS_URL`. Bots sign in through the dev-only `/auth/dev` route, so they only work against the `dev` stage.

`two-bots` checks:
- both get `call.matched` with one callId and join the Chime meeting (fake media)
- single share: both mini windows show the sender's photo and revert together; Show → visible on both, p95 ≤ 800 ms
- simultaneous share: each sees the other's photo; after one cancels, the other falls back to its own
- queue of three: 6 s, 4.5 s, 6 s on the viewer
- ending on one side sends `call.ended` to the other

Reports land in `out/` (gitignored).
