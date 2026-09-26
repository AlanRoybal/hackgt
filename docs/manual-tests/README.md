# Manual device tests

These cover what a simulator or bot can't: real Sign in with Apple, APNs to a real phone, CallKit/PushKit, camera, Focus, Core Motion, and background behavior. All need the Apple team setup in `docs/APPLE_SETUP.md`.

| Script | Needs | Covers |
|---|---|---|
| [01-sign-in.md](01-sign-in.md) | 1 phone | ACC-1, ACC-2, ACC-3, ACC-5, ACC-8 |
| [02-nudges.md](02-nudges.md) | 1 phone + peer-bot | NUD-8, NUD-9, NUD-10, NUD-12, AV-1, AV-3 |
| [03-calls.md](03-calls.md) | 1 phone + peer-bot | CALL-1–5, NUD-11 |
| [04-photos.md](04-photos.md) | 1 phone + peer-bot | PHO-1, PHO-5, REF-1, REF-4, REF-5, REF-7–9 |
| [background-matrix.md](background-matrix.md) | 1 phone | BG-1 (fill in observed results) |
| [two-person.md](two-person.md) | 2 phones, 2 people, remote | end to end, TestFlight |

Record results in each script's table: ✅ pass, ❌ fail (with a note), ⏭ skipped (why). A story is only Done when its device steps pass.

The peer bot (`tools/peer-bot`) stands in for the friend: `npm run bot -- stand-in --friend <your handle>`.
