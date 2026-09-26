# Nudge (hackgt)

iOS app + AWS backend that nudges two friends to call when their calendars are both free, runs the video call, surfaces photos you mention from your camera roll in the call, and remembers what you talked about for follow-ups.

| Where | What |
|---|---|
| `docs/SPEC.md` | user stories, verification plan, data models, API/WS/APNs/Chime contracts, architecture |
| `docs/DECISIONS.md` | every non-obvious choice and why |
| `docs/progress/M0–M7.md` | what's built, verified, and still awaiting a device |
| `docs/APPLE_SETUP.md` | remote checklist for the Apple Developer team, APNs key, TestFlight |
| `docs/manual-tests/` | device and two-person test scripts |
| `backend/` | CDK stack + Lambdas (`npm test`, `npm run integ`, `npm run deploy:dev`) |
| `ios/` | XcodeGen project + `NudgeKit` package (`cd ios && xcodegen`) |
| `tools/peer-bot` | scripted friend: headless Chime participant (`npm run bot -- two-bots`) |
| `tools/e2e/ios-e2e.sh` | real app in the simulator vs the dev stack, bot as the friend |
| `tools/latency-report` | p50/p95 per pipeline stage from CloudWatch |
| `evals/` | detector, retrieval and safety evals (`evals/RESULTS.md`) |
| `prompts/` | the build prompt and the Figma design brief |
