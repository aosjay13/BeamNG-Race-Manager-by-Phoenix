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
                                       (or Start Race, behind a pace lap)
```

Qualifying and the race run the **same** lifecycle: form the grid, hold the
field, count down, run, take finished cars off the track, give everybody their
car back. Only the lap target and the scoring differ.

**1. Open the app and log in.** Join the server, open the HUD app menu and add
**Race Manager** (under *Racing* and *Info*). Everyone sees the live timing, but
the editor and race controls stay hidden until you type the master password into
the **Admin Login** bar; anyone who just wants to watch closes it with **✕**.
To sit a session out entirely, press **👁 Spectate** in the Race Entry row: the
field runs without you, your car stays put as a ghost, and you watch with
BeamNG's own camera controls. Streaming the night? **📺 Broadcast** then swaps
the app for a [spectator's board](docs/REFERENCE.md#broadcast-board-spectators):
the whole field, who is out and why, cup standings, and click a name to put the
camera on that car.

**2. Build a track.** Press **Editor**, then drive the course. At each timing
gate, drive through it *in the direction of travel* and press **+ Checkpoint
Here**. Gates are flat rectangles standing across your heading, and what you see
drawn in the world **is** the trigger.

- **The last gate you place is the start/finish line.**
- Set **Gate width**, and the two halves of the vertical: **up** is how far the
  gate rises above where it was placed, **down** how far it drops below. They are
  independent, so a gate can stand tall enough to see without an equal amount of
  it hanging under the road. Raise **up** on **banked tracks** so the rectangle
  covers the banking. Any single gate can override all three.
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

**4. Decide who's racing.** **Everyone on the server is in the field**, so
there's nothing to do. A driver who'd rather watch presses **Spectate** and the
session runs without them; their car stays put as a ghost, and **Rejoin the
field** puts them back. That's the whole entry system, and it's the driver's own
call, not an admin setting. A one on one is two people racing and everybody else
spectating. Once a session is running the field is fixed: the way out from there
is **Retire**, which keeps a classified position and scores like any other DNF.

**5. Qualifying.** Press **Start Quali**, then **Start Countdown**. The field
starts from the grid, so the first lap is an **out lap**: not timed, not scored,
and not counted against the allowance. *Three qualifying laps still means three
timed laps*, run after it. Drivers see `OUT LAP: NOT TIMED` instead of a running
clock until they cross the line. (A point-to-point stage is driven once, so it
has no out lap.) The table shows everyone's best lap, fastest on top.

Optional: **Ghost quali** (rivals stop being obstacles), **Quali laps**, and
**Quali mins** (which triggers a proper final lap rather than stopping dead).

**6. Grid and race.** Set **Laps**, pick a **Grid order** (Quali, Reverse,
Random, Points, Points rev or Custom), then **Generate Grid**. Every driver is placed on their slot
and **held** there, so nobody can jump the start. **Start Countdown** gives
everyone a synchronised 3‑2‑1‑**GO!** and releases the whole field on the same
broadcast. The table re-sorts leader-first in real time as places change.

Once the race is running, **Caution** throws a full-course yellow and the field
**races back to the line**. The leader's crossing makes the caution official and
names the lap; everyone else locks their place as they complete that same lap,
first back to the line first, with the lapped cars at the bottom in their own
order. From there the board holds station, so closing up under the yellow
&mdash; which is what drivers have been told to do &mdash; costs and gains
nobody a place. **Restart** is *called* rather than taken: the green falls as the
leader reaches the line, and **Cancel restart** waves it off until it does. Turn
**Free pass** on and the first car a lap down takes its lap back before the
green.

Turn on **Pace lap** and Start Countdown becomes **Start Race** instead. The
field is released under a **yellow flag** with no countdown, told to hold
position at 40 mph / 64 km/h, and runs a formation lap; the **green flag** falls
automatically as the leader comes back within 10 m of the start/finish line. The
pace lap is not scored and is not one of your laps &mdash; a 5-lap race behind
the pace car is a formation lap plus 5 racing laps, and the board counts the
racing ones. A red flag holds the green, and the **Green flag** button ends the
pace lap at any time if the field never makes it round.

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
| **[Branch gates](docs/REFERENCE.md#branch-gates-two-ways-through-a-checkpoint)** | Give a checkpoint a second gate and either one clears it. Split lanes and head-on "suicide" ovals, scored together on one leaderboard, with nothing to assign anyone to. |
| **[Mouse track editing](docs/REFERENCE.md#tutorial-running-a-race-night)** | Nudge mode: click, drag and scroll to move and turn gates from free cam, ctrl+click to place new ones. Driving to a gate still works and still builds the track. |
| **[Caution and restart](docs/REFERENCE.md#caution-and-restart)** | A full-course yellow the field **races back to the line** for: the leader's crossing sets the lap, everyone locks their place as they complete it, and lapped cars go to the bottom in their own order. Optional free pass. The restart is called and falls at the line, and can be waved off. |
| **[Multi-class racing](docs/REFERENCE.md#multi-class-racing)** | Two car types on one grid, scored as two races. Tag a class on each Garage List entry and every driver in that car is in it: a Class column with per-class positions on the board, and a section per class in the results file. The overall order is unchanged. |
| **[The blue flag](docs/REFERENCE.md#the-blue-flag)** | Lapped traffic gets signalled instead of only displayed: the backmarker is shown blue when a car a lap up closes on them, and the car doing the lapping is told there is one ahead. Measured on the road rather than off the timing sheet, which are different orders once anybody is lapped. |
| **[Heats and transfers](docs/REFERENCE.md#heats-and-transfers)** | Run the night as heats into a feature, with a lap count of their own. The field is split by a serpentine draw off qualifying, the top N from each heat transfer, and the feature grid is built from the results &mdash; winners on the front row, interleaved by heat. |
| **[Pace lap](docs/REFERENCE.md#pace-lap)** | Start the race behind a pace car instead of from the lights: released under yellow, one formation lap at 40 mph / 64 km/h, green flag as the leader returns to the line. The formation lap is not scored and does not count against the distance. |
| **[Rallycross joker laps](docs/REFERENCE.md#rallycross-joker-laps)** | A second gate route that must be taken exactly once per race. Lap 1 is closed, and the server disqualifies anyone who missed it or took it twice. |
| **[Garage List](docs/REFERENCE.md#vehicle--setup-locking-the-garage-list)** | Lock the session to exact cars *and* exact tunes. Anything else is deleted on spawn and the driver is told why. |
| **[Cup points](docs/REFERENCE.md#cup-points)** | Championship points across several events: races, derbies or both. Scoring presets, qualifying points and bonuses, and standings that survive a server restart. |
| **[Nametag display names](docs/REFERENCE.md#display-names-on-the-beammp-nametag)** | Optionally append a driver's display name to the tag over their car. Uses BeamMP's own suffix API, so only the text changes -- fade, color and occlusion stay BeamMP's. |
| **[Display names](docs/REFERENCE.md#display-names)** | Give `Guest_4471` a readable name for the leaderboard and the results file. Saved on the server. |
| **[Time behind](docs/REFERENCE.md#time-behind)** | Gap to the leader and interval to the car ahead on every board, measured off the shared clock at the last checkpoint both cars reached - not estimated from speed or distance. Reads `+1 LAP` once a driver is lapped. |
| **[Live position tracking](docs/REFERENCE.md#live-position-tracking)** | True running order from laps, checkpoints cleared and distance to the next gate, not just the grid order. |
| **[Demo Derby](docs/REFERENCE.md#demo-derby-parallel-game-mode)** | A separate last-man-standing mode with its own arena, timers and results, fully isolated from the racing. |
| **[Broadcast board](docs/REFERENCE.md#broadcast-board-spectators)** | A spectator's board for streaming: the whole field, the drivers who are out and why, cup standings, and click a name to put the camera on that car in orbit. |
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
