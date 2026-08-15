# BeamNG Race Manager by Phoenix

A **multiplayer-only** race manager for BeamNG.drive on **BeamMP**: live
standings, lap counts, best and last lap times, and real-time gaps for every
driver on the server.

You place checkpoint gates by driving the track, run a qualifying session, let
it build the starting grid, and the server writes a results file at the flag.

| | |
|---|---|
| **[Install](#install)** | Two files, then restart the server |
| **[Run a race night](#run-a-race-night)** | The whole flow, start to finish |
| **[What else it does](#what-else-it-does)** | Reset limits, joker laps, car locking, Demo Derby |
| **[Troubleshooting](#troubleshooting)** | Mostly "the app doesn't show up" |

> **This page is the short version.** Every feature in full is in
> **[docs/REFERENCE.md](docs/REFERENCE.md)**. See also
> [Architecture](docs/ARCHITECTURE.md) (how it's built),
> [Compatibility](docs/COMPATIBILITY.md) (what each BeamNG and BeamMP release
> changed) and the [Changelog](CHANGELOG.md).

## Install

You need a **BeamMP server you control**. Racing is multiplayer-only; offline
you get the checkpoint editor and nothing else.

Download `RaceManager-vX.Y.Z.zip` from [Releases](../../releases) and extract
it. Inside are two folders that map straight onto your server's `Resources/`
directory. Copy them both in:

```
Client/RaceManager.zip        →  Resources/Client/RaceManager.zip
Server/RaceManager/main.lua   →  Resources/Server/RaceManager/main.lua
```

Restart the server and you're done. BeamMP pushes `RaceManager.zip` to everyone
who joins, so **players install nothing by hand**.

Building from source instead? `python3 tools/deploy.py` writes the package and
installs both halves onto a BeamMP server it finds, backing up whatever it
replaces and leaving your saved layouts and results alone. Add `--dry-run` to see
what it would do first. The client zip is always
called `RaceManager.zip`, with no version in the name, so an update overwrites
the old one instead of leaving two copies side by side.

**Three things to get right:**

1. **Deploy both halves together, and delete the old ones.** Two versions of the
   server plugin each run their own state machine and take turns broadcasting,
   which makes the UI flicker between two states. The app header shows a version
   for each piece; if they don't match, something didn't copy. A stale file
   fails *silently*: a button just stops doing anything.
2. **Change the password before your first public session.** It ships as
   `phoenix`. Log in, then set a new one from the **Change password** bar.
3. **Upgrading from 0.6.0 or earlier on Linux?** Those packages spelled the
   folders in lower case. Delete any leftover `Resources/client` or
   `Resources/server`. Windows is unaffected.

## Run a race night

Everything happens inside the **Race Manager** window in game:

```
Build/Load a track  →  Start Quali  →  Start Countdown  →  Qualifying
                    →  Generate Grid  →  Start Countdown  →  Race  →  Results
```

Qualifying and the race run the **same** lifecycle: form the grid, hold the
field, count down, run, take finished cars off the track, give everybody their
car back. Only the lap target and the scoring differ.

**1. Open the app and log in.** Join the server, open the HUD app menu and add
**Race Manager** (under *Racing* and *Info*). Everyone sees the live timing, but
the editor and race controls stay hidden until you type the master password into
the **Admin Login** bar. Anyone who just wants to watch presses **Spectate »**.

**2. Build a track.** Press **Editor**, then drive the course. At each timing
gate, drive through it *in the direction of travel* and press **+ Checkpoint
Here**. Gates are flat rectangles standing across your heading, and what you see
drawn in the world **is** the trigger.

- **The last gate you place is the start/finish line.**
- Set **Gate width** and **Gate height**. Raise the height on **banked tracks**
  so the rectangle covers the banking. Any single gate can override both.
- **Undo**, **Clear** and **Hide/Show Gates** do what you'd expect.

Then switch to the **Start Grid** tab and drive to each grid slot *facing down
the track*, pressing **+ Place Start Position Here**. Slot 1 is pole. Every slot
stays editable: **Go** to it, **Move Here**, or **✕** to delete.

**3. Save it as a layout.** In **Track Layouts**, type a name and press **Save
As New**. A layout lives on the *server*, survives restarts, and carries the
gates, the joker route, the pit lane, the lanes and the starting grid together.

Once it's saved, the **Track** picker at the top drives everything else:
**Load Layout** rebuilds it on every connected client at once, and **Overwrite**
and **Delete** act on whatever is selected, so putting an edited track back takes
no retyping. Both ask first. A save can never quietly empty part of a stored
layout; if the client sending it isn't holding a section the saved copy has, the
server refuses and says exactly what would have gone.

**4. Decide who's racing.** By default **everyone on the server is in the
field**, so there's nothing to do. Flip to **Opt-in entry** when the field should
be a subset of who's connected: each player then gets a **Join Race** button and
only they are gridded. Entry survives Start Quali, so drivers join once per
event.

**5. Qualifying.** Press **Start Quali**, then **Start Countdown**. The field
starts from the grid, so the first lap is an **out lap**: not timed, not scored,
and not counted against the allowance. *Three qualifying laps still means three
timed laps*, run after it. Drivers see `OUT LAP: NOT TIMED` instead of a running
clock until they cross the line. (A point-to-point stage is driven once, so it
has no out lap.) The table shows everyone's best lap, fastest on top.

Optional: **Ghost quali** (rivals stop being obstacles), **Quali laps**, and
**Quali mins** (which triggers a proper final lap rather than stopping dead).

**6. Grid and race.** Set **Laps**, pick a **Grid order** (Quali, Reverse,
Random or Custom), then **Generate Grid**. Every driver is placed on their slot
and **held** there, so nobody can jump the start. **Start Countdown** gives
everyone a synchronised 3‑2‑1‑**GO!** and releases the whole field on the same
broadcast. The table re-sorts leader-first in real time as places change.

**7. Results.** At the flag the server writes a results file to
`Resources/Server/RaceManager/results/` and announces the path in chat, ready for
league standings, with the cup round it just banked appended if a cup is running.
**Reset** clears the session for the next one.

> Each step has more to it: grid pinning, final-lap rules, what happens to a
> driver who disconnects. It's all in
> **[docs/REFERENCE.md](docs/REFERENCE.md#tutorial-running-a-race-night)**.

## What else it does

All of it is **off by default**, so a plain race night behaves exactly as you'd
expect without touching any of it.

| Feature | What it gives you |
|---|---|
| **[Vehicle reset limits](docs/REFERENCE.md#vehicle-reset-limits)** | Cap resets per driver per session. Past the allowance the reset key genuinely stops working. Can respawn at the last checkpoint instead of in place. |
| **[Reset ghosting](docs/REFERENCE.md#reset-ghosting)** | A driver who resets is intangible for a few seconds rather than reappearing solid in the racing line. Collisions return only once the space around them is provably clear. |
| **[Branching routes](docs/REFERENCE.md#branching-routes-two-ways-round-one-track)** | Two ways round one track, scored together on one leaderboard. Includes head-on "suicide" ovals where the field races in opposite directions. |
| **[Rallycross joker laps](docs/REFERENCE.md#rallycross-joker-laps)** | A second gate route that must be taken exactly once per race. Lap 1 is closed, and the server disqualifies anyone who missed it or took it twice. |
| **[Garage List](docs/REFERENCE.md#vehicle--setup-locking-the-garage-list)** | Lock the session to exact cars *and* exact tunes. Anything else is deleted on spawn and the driver is told why. |
| **[Cup points](docs/REFERENCE.md#cup-points)** | Championship points across several events: races, derbies or both. Scoring presets, qualifying points and bonuses, and standings that survive a server restart. |
| **[Display names](docs/REFERENCE.md#display-names)** | Give `Guest_4471` a readable name for the leaderboard and the results file. Saved on the server. |
| **[Live position tracking](docs/REFERENCE.md#live-position-tracking)** | True running order from laps, checkpoints cleared and distance to the next gate, not just the grid order. |
| **[Demo Derby](docs/REFERENCE.md#demo-derby-parallel-game-mode)** | A separate last-man-standing mode with its own arena, timers and results, fully isolated from the racing. |
| **[Driver UI](docs/REFERENCE.md#driver-ui-non-admins)** | Non-admins see just the leaderboard. Resizable, fades so it doesn't block the view, and collapses to a single status line. Alerts still get through. |

## Troubleshooting

**The app doesn't show up:**

- Since BeamNG **v0.39** the app list is called **HUD Apps**, not *UI Apps*, and
  is reached from the Pause menu (*System → HUD Apps*). Race Manager is under
  **Racing** and **Info**.
- The game only scans mods at startup, so **restart BeamNG** after installing or
  updating. If the list is still stale, clear the cache (Launcher →
  *Manage User Folder* → *Clear Cache*).
- Check the zip has `ui/`, `lua/` and `scripts/` at its **root**, with no extra
  top-level folder from zipping the parent directory.
- In singleplayer, confirm the mod is **enabled** in the in-game Mods menu.
- Look for `Race Manager client bridge loaded` in the console (`~`). If it's
  missing, the modScript never ran, meaning the zip wasn't mounted.

**Buttons do nothing, or the UI flickers between two states:** mismatched or
duplicated versions are installed. See [Install](#install).

**Drivers rejected in a car that's plainly on the Garage List:** a BeamNG update
renamed some vehicle parts, which changes the configuration signature. Re-capture
the list. See [Compatibility](docs/COMPATIBILITY.md).

## Support development

Race Manager is free and always will be. If it's improved your race nights and
you'd like to put something toward the hosting and the hours:

- **PayPal**: [krossx13](https://www.paypal.me/krossx13)
- **Cash App**: [$disciplejtmay](https://cash.app/$disciplejtmay)

## License

Released under the [MIT License](LICENSE): use it, fork it, run it on your own
server, ship it in your own mod, so long as the copyright notice travels with it.
Contributions are accepted under the same license.
