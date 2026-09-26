# Background behavior matrix (BG-1)

Planned behavior is in SPEC §4.6. Fill in what actually happens on a device. For "terminated by system", launch the app, then open a heavy game or camera for a while until it's evicted (check with a breakpoint-free relaunch). For "force-quit", swipe it away in the app switcher.

| Behavior | Foreground | Background | Terminated by system | Force-quit |
|---|---|---|---|---|
| Nudge alert arrives | | | | |
| Accept from notification | | | | |
| Skip from notification (API call succeeds?) | | | | |
| See this less often from notification | | | | |
| Silent availability.check reports Focus/driving | | | | |
| BGAppRefresh calendar sync (check `syncedAt` next day) | | | | |
| VoIP call rings via CallKit | | | | |
| Message push | | | | |
| Nudge cleanup removes stale notification | | | | |
| Photo upload continues | | | | |

Device / iOS version: ______  Build: ______  Date: ______
