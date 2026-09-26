# Design Prompt — Devin (Figma)

> Paste everything below the line into Devin.
> "Nudge" is a working name.

---

Design the complete iOS app UI for **Nudge** in Figma. Nudge helps people stay in touch with the people they care about:
- When you and a friend are both free on your calendars, you both get a nudge to call.
- If you both accept, a video call starts.
- During the call, photos you mention from your camera roll appear in the small self-view window on both phones.
- Afterwards, the app remembers what you talked about so it can suggest a follow-up next time ("Want to follow up with Mom about that physics exam?").

Every user has the same experience; there are no roles. An engineer (Claude Code) is building the SwiftUI app at the same time. Your file is the visual source of truth, so it has to be precise and ready for handoff.

## Style

- **Professional, calm, warm, pastel, flat.**
  - Solid fills only: no gradients, no glassmorphism, no decorative shadows, no emoji in UI copy.
  - It should feel like a premium Apple app with a soft pastel palette. It must not look childish.
- **Follow Apple's design principles** from this skill: https://www.ui-skills.com/skills/emilkowalski/apple-design
  - restraint and simplicity (not minimalism)
  - clear hierarchy from weight + size + leading together
  - labels that name what's inside ("Friends", "Messages"), never "Home"
  - every screen answers: Where am I? Where can I go? How do I get out?
  - controls sit next to what they affect
  - motion that starts from where things are and can be interrupted
- **Keep system chrome standard iOS:** tab bar, navigation bar, sheets, system alerts, lock screen notifications, and the CallKit incoming call screen. Style the content, not the operating system.
- **Frames:**
  - iPhone 16 Pro (402 × 874) is the primary size.
  - Also check key screens on iPhone SE (375 × 667).
  - Respect safe areas and the Dynamic Island.
- **Light mode first.** Then provide dark mode for every screen marked ◐.

## Foundations — build these as Figma Variables (Light / Dark modes)

**Colors:**

| Token | Light | Dark | Use |
|---|---|---|---|
| bg | #FBF8F4 | #15161C | app background |
| surface | #FFFFFF | #1E2028 | cards, sheets |
| surfaceAlt | #F4EFE9 | #262833 | grouped rows, inputs |
| divider | #ECE7E0 | #2F3240 | hairlines |
| ink | #1F2330 | #F2F1F6 | primary text |
| inkSecondary | #5B6172 | #A9ADBB | secondary text |
| inkTertiary | #9AA0AE | #6E7385 | placeholders |
| lavender / lavenderStrong | #E4DDFB / #6B5BD2 | #3A3358 / #C9BEFF | brand, primary action |
| mint / mintStrong | #D5F0E3 / #2E8B63 | #23423A / #9FE0C2 | accept, success, "free" |
| peach / peachStrong | #FFE2D3 / #C0623A | #4A3128 / #FFBFA0 | skip, secondary |
| sky / skyStrong | #DCEBFA / #3A73B5 | #233447 / #A9CCF2 | info, messages |
| butter / butterStrong | #FCF0C4 / #9A7A12 | #463E22 / #F2DB8A | memory, highlights |
| rose / roseStrong | #FADADF / #C23B4E | #4A262D / #FFA9B5 | end call, destructive |

- Pastel fills sit behind **Strong** text and icons.
- Every text/background pair must pass WCAG AA. Note any pair you had to adjust, and tell me.
- You may tune these values, but keep the token names. Tokens are the contract with engineering.

**Type:**
- SF Pro for everything, following the iOS Dynamic Type scale (Large Title, Title 1–3, Headline, Body, Callout, Subheadline, Footnote, Caption 1–2).
- **SF Pro Rounded Semibold** for Large Titles and friend names.
- Tracking changes with size: tighter on large text, near 0 for body text.
- Make each style a text style whose name matches its iOS name.

**Spacing and radii:**
- Spacing on a 4-point base, using only 4, 8, 12, 16, 20, 24, 32, 40, 56. Screen side margin 20.
- Radii: 8 (chips), 12 (inputs, small cards), 20 (cards, nudge banner), 28 (sheets), full (avatars, round buttons).
- Use Auto Layout everywhere.

**Elevation:** flat. Separate things with fill contrast plus a 1-point `divider`. The only shadow is the in-call mini window (y 4, blur 16, ink at 12%), because it floats over video.

**Iconography:** SF Symbols only, in regular or medium weight, matched to the text size they sit next to.

**Illustration:** simple flat pastel spot illustrations for onboarding and empty states. Keep them geometric and soft, and limited to the token palette. Export them as SVG.

## Components (with variants and states)

**Buttons:**
- primary: lavender fill, lavenderStrong label
- secondary: surfaceAlt fill
- accept: mint fill
- skip: peach fill
- destructive: rose fill
- text button
- round call-control buttons (56 pt): mute, camera, flip, end
- States for each: default, pressed, disabled, loading

**Avatar:**
- sizes 28, 40, 56, 96
- an image variant, and an initials variant on a pastel background chosen from the name
- an optional status ring: mint = free now, none = busy

**Friend row:** avatar, nickname, handle, a status line ("Free until 3:40 PM" / "Busy" / "Last talked 3 days ago"), and a chevron.

**Nudge banner (in-app):**
- Default: two overlapping avatars, the headline, a line showing the free window, and Accept + Skip buttons.
- Long-press menu: "See this less often".
- Toast after choosing it: "Nudges set to Low · Undo".

**System notification mocks:**
- a lock screen banner
- the expanded notification after a long press, with a custom content area (both avatars and a small timeline bar showing the shared free window) and the actions Accept / Skip / See this less often

**Mini window (in-call self-view):**
- self camera
- camera off (initials)
- showing a photo, with a "from Mom" label
- showing a photo with 2–5 queue dots
- dragging

**Photo suggestion chip:** a thumbnail, "Show this?", Show, ✕, and a thin progress line showing the 8-second auto-dismiss.

**Automatic-mode hide pill:** "Showing to Mom · Hide", with a 2-second progress.

**Topic chip** (memory): butter fill, with a remove affordance.

**Message bubbles:**
- mine
- theirs
- an automatic follow-up, with a "Sent automatically" caption
- a centered system event ("Missed nudge · 3:40 PM", "Called · 12 min")

**Controls and inputs:**
- list cells: toggle, value + chevron, destructive
- segmented control, slider with labeled steps, time-range picker row
- inputs: default, focused, valid, error, with a handle-availability indicator
- a toast, empty-state block, skeleton loaders, and a permission primer card

## Screens

Mark each screen ◐ if it needs dark mode.

**Onboarding and account:**
1. **Launch** ◐
2. **Welcome.** Three short swipeable cards with illustrations:
   - "Know when you're both free"
   - "Call in one tap"
   - "Your photos join the conversation, and we remember what matters"
3. **Sign in with Apple.** Use Apple's standard button.
4. **Terms & consent.** Plain-language summary cards, each with an icon, then "I agree" and a link to the full Terms. The cards cover:
   - "We see when you're busy, not what you're doing"
   - "Photos from the last 30 days are analyzed to find the ones you mention"
   - "Calls are transcribed by AI so photos can appear and follow-ups can be remembered, for both people on the call"
   - "You can delete anything, anytime"
5. **Choose your handle.** A live availability check with valid, taken, and invalid states, plus display name and avatar picker.
6. **Phone number (optional).** "Let friends find you from their contacts." Number entry, then the 6-digit code screen, with a Skip option.
7. **Permission primers.** One template with variants for Notifications, Calendar, Photos, Contacts, Camera & Microphone, Focus status, and Motion. Each explains *why* before the system prompt appears, with "Continue" and "Not now". Include a denied-state variant with a link to Settings.
8. **Add your first friends.** Contact matches with Add buttons, a search field, and a share-your-link card.

**Main (tab bar: Friends · Messages · Settings):**

9. **Friends** ◐
   - A "Free now" section at the top listing friends who are free right now, with a mint ring.
   - Then all friends.
   - A pending-requests pill.
   - Empty state.
10. **Add friends**
    - three segments: Search / Contacts / Invite
    - search results with Add / Requested / Friends states
    - contact matches
    - "Invite" to share a link and QR code
11. **Friend requests:** incoming and outgoing, with Accept / Decline.
12. **Friend profile** ◐
    - large avatar, nickname (editable, with a note that only you see it), and handle
    - "Call now" and "Message" buttons
    - **Memories:** topic chips, plus short past-call summaries by date, each deletable, with the note "Deleting removes it for both of you"
    - call history
    - Remove friend and Block (destructive)
13. **Messages list** and **Message thread** ◐

**Nudge and call flow (the core, polish these most):**

14. **Nudge, app closed:**
    - lock screen banner
    - expanded long-press view with the actions
15. **Nudge, app open:**
    - the in-app banner dropping over the Friends screen
    - the long-press menu
    - the "See this less often" toast
16. **Waiting room** ◐
    - "Waiting for Mom…" with both avatars and a calm pulse, the expiry countdown ("Nudge ends in 2:41"), and Cancel
    - Outcome state: "Mom can't right now". If a follow-up message came, show it quoted as it will appear in Messages.
    - Expired state.
17. **Incoming call:** a mock of the CallKit screen for reference only, plus an in-app incoming screen for when the app is open.
18. **In-call** ◐ (dark UI over video). Design every state:
    - a. connecting
    - b. connected (remote video full screen, the mini window in the top-right corner, and controls at the bottom that fade after 4 s idle and come back on tap)
    - c. mini window dragged to each of the 4 corners
    - d. photo suggestion chip (Ask-first mode)
    - e. **my photo shown**: my mini window shows my photo, and a companion frame shows the other person's screen where their mini window shows the same photo
    - f. **the other person's photo shown** to me: "from Mom"
    - g. **both sharing at once**: each side's mini window shows the *other* person's photo, as a side-by-side companion frame
    - h. queue with dots
    - i. automatic-mode hide pill
    - j. muted / camera off / other person's camera off
    - k. reconnecting and poor-network banners
19. **Call ended summary** ◐: the duration, "We'll remember" topic chips (removable), and Done. It closes itself after 10 s.
20. **Follow-up nudge example:** lock screen and in-app versions of "You and Mom are both free for 15 minutes. Want to follow up about the physics exam?"

**Settings:**

21. **Settings root** ◐
22. **Nudges:**
    - frequency segmented control (Off / Low / Normal / High) with one line explaining each
    - quiet hours (start and end, default 12:00 AM–8:00 AM)
    - minimum free time (5 / 10 / 15 / 30 min)
    - toggles: "Don't nudge during Focus", "Don't nudge while driving"
    - "When I skip": Send a follow-up message / Send nothing, with a preview of the message
23. **Calendars:** Apple Calendar with a toggle for each calendar (colored dots). A Google Calendar row reading "Coming soon". The note: "Only busy times are shared. Never event names."
24. **Photos:**
    - Sharing: Ask first / Automatic / Off
    - indexing toggle and status card ("132 photos from the last 30 days · 4 excluded for safety", and a progress state while indexing)
    - Include screenshots
    - Delete all indexed photos (destructive)
25. **Memory:** on/off, All memories (grouped by friend), Delete all.
26. **Account:** handle, display name, avatar, phone, blocked users, Terms, Privacy, Sign out, **Delete account** (with a confirmation sheet).

**Cross-cutting:**

27. **States:** empty states (no friends, no messages, no memories), loading skeletons, offline banner, and an error toast for each main screen.
28. **App icon.** Flat and pastel, and simple enough to read at 29 pt. Provide light, dark, and tinted versions as required by current iOS.

## Motion (describe it in the prototypes and in annotations)

Build Smart Animate prototypes for:
- the nudge banner appearing and dismissing
- Accept → waiting room → call
- the photo swap in the mini window, one sender and both at once

Annotate each with spring values the engineer can use:

| Motion | Damping | Response | Notes |
|---|---|---|---|
| Nudge banner in | 0.8 | 0.3 | slides from the top, swipe up to dismiss |
| Sheets | 0.8 | 0.3 | |
| Moves and repositioning | 1.0 | 0.4 | |
| Mini window corner snap | 0.8 | 0.4 | uses the release velocity |
| Photo swap | — | 0.35 s | spring cross-dissolve, scale 0.96 → 1.0, reversed exactly on exit |

**Reduced Motion:** replace all of these with plain opacity cross-fades.

**Haptics:** mark where they fire. Only on Accept, a photo shown, the corner snap, and errors.

## Copy rules

- Sentence case. Short, warm, and plain.
- Always use the viewer's nickname for the friend ("Mom"), never their handle, in nudges and calls.
- Times are in the device's format ("3:40 PM").
- No exclamation marks except in auto follow-up message examples.

## Deliverables

1. The Figma file, organized into these pages: **Cover · Foundations (Variables) · Components · Onboarding · Main · Nudge & Call · Settings · States · Prototypes · Handoff**.
2. The **Handoff** page, containing:
   - measurements and annotations for the mini window, nudge banner, suggestion chip, and in-call controls
   - behavior notes for every interactive element
   - a list of any token changes you made
3. An export of all Variables as `design-tokens.json`, with light and dark values and token names exactly as above.
4. SVG exports of the illustrations and app icon PNGs at every required size.
5. A short summary listing every screen and state, with a link to each frame.
