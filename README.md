# BeamNG Race Manager by Phoenix

A **multiplayer-only** race manager for BeamNG.drive on **BeamMP**: live
standings, lap counts, best/last lap times and real-time gaps for every driver
on the server.

You place checkpoint gates by driving the track, run a qualifying session, let
it build the starting grid, and the server writes a results file at the flag.

- **[Install](#install)** — two files, then restart the server
- **[Run a race night](#run-a-race-night)** — the whole flow, start to finish
- **[What else it does](#what-else-it-does)** — reset limits, joker laps, car locking, Demo Derby
- **[Troubleshooting](#troubleshooting)** — mostly "the app doesn't show up"

> **This page is the short version.** Every feature in full detail is in
> **[docs/REFERENCE.md](docs/REFERENCE.md)**. See also
> [Architecture](docs/ARCHITECTURE.md) (how it's built),
> [Game version compatibility](docs/COMPATIBILITY.md) (what each BeamNG and
> BeamMP release changed) and the [Changelog](CHANGELOG.md).

## Install

You need a **BeamMP server you control**. Racing is multiplayer-only — offline
you get the checkpoint editor and nothing else.

Download `RaceManager-vX.Y.Z.zip` from the
[Releases](../../releases) page and extract it. Inside are two folders that map
straight onto your server's `Resources/` directory — copy them both in:

```
Client/RaceManager.zip        →  Resources/Client/RaceManager.zip
Server/RaceManager/main.lua   →  Resources/Server/RaceManager/main.lua
```

Restart the server and you're done. BeamMP pushes `RaceManager.zip` to everyone
who joins, so **players install nothing by hand**.

The client zip is always called `RaceManager.zip` — no version in the name — so
an update overwrites the old one instead of leaving two copies side by side.

> **Updating? Delete the old copies first.** Two versions of the server plugin
> installed side by side each run their own state machine and take turns
> broadcasting, which makes every UI element flicker between two states. Always
> deploy the server plugin and the client zip **together** — the app header
> shows a version number for each piece, and if those numbers aren't identical,
> something didn't get copied. A stale file fails *silently*: a button just
> stops doing anything, with no error anywhere.

> **Change the password before your first public session.** It ships as
> `phoenix`. Log in, then set a new one from the **Change password** bar — it
> applies immediately.

## Run a race night

Everything happens inside the **Race Manager** window in game:

```
Build/Load a track  →  Start Quali  →  Start Countdown  →  Qualifying
                    →  Generate Grid  →  Start Countdown  →  Race  →  Results
```

Qualifying and the race run the **same** lifecycle — form the grid, hold the
field, count down, run, take finished cars off the track, give everybody their
car back. Only the lap target and the scoring differ.

**1. Open the app and log in.** Join the server, open the HUD app menu and add
**Race Manager** (under *Racing* and *Info*). Everyone sees the live timing,
but the editor and all race controls stay hidden until you type the master
password into the **Admin Login** bar. Anyone who just wants to watch presses
**Spectate »**.

**2. Build a track.** Press **Editor**, then drive the course. At each timing
gate, drive through it *in the direction of travel* and press **+ Checkpoint
Here**. Gates are flat rectangles standing across your heading — what you see
drawn in the world **is** the trigger.

- **The last gate you place is the start/finish line.**
- Set **Gate width** (how far it reaches across) and **Gate height** (how far
  up and down). Raise the height on **banked tracks** so the rectangle covers
  the banking. Any single gate can override both.
- **Undo**, **Clear** and **Hide/Show Gates** do what you'd expect.

Then switch to the **Start Grid** tab and drive to each grid slot *facing down
the track*, pressing **+ Place Start Position Here**. Slot 1 is pole. Every
slot stays editable afterwards — **Go** to it, **Move Here**, or **✕** to
delete.

**3. Save it as a layout.** Type a name in **Track Layouts** and press **Save
Current Layout**. This lives on the *server*, survives restarts, and carries
the gates, the joker route and the starting grid together. Layouts are filtered
to the map you're hosting, and **Load Layout** rebuilds them on every connected
client at once.

**4. Decide who's racing.** Being connected isn't being entered — each player
gets a **Join Race** button. Or flip the mode to **Everyone races** and skip
it. Entry survives Start Quali, so drivers only join once per event.

**5. Qualifying.** Press **Start Quali**, then **Start Countdown**. Lap 1
starts at the line, so *three qualifying laps means three laps* — there's no
out-lap. The table shows everyone's best lap, fastest on top. Optional
settings: **Ghost quali** (rivals stop being obstacles), **Quali laps**, and
**Quali mins** (which triggers a proper final lap rather than stopping dead).

**6. Grid and race.** Set **Laps**, pick a **Grid order** (Quali / Random /
Custom), then **Generate Grid** — every driver is placed on their slot and
**held** there, so nobody can jump the start. **Start Countdown** gives
everyone a synchronised 3‑2‑1‑**GO!** and releases the whole field on the same
broadcast. The table re-sorts leader-first in real time as places change.

**7. Results.** At the flag the server writes a results file to
`Resources/Server/RaceManager/results/` and announces the path in chat, ready
for league standings. **Reset** clears the session for the next one.

> Each step above has a lot more to it — grid pinning, the final-lap rules,
> what happens to a driver who disconnects. It's all in
> **[docs/REFERENCE.md](docs/REFERENCE.md#tutorial-running-a-race-night)**.

## What else it does

All of this is **off by default**, so a plain race night behaves exactly as you
would expect without touching any of it.

| Feature | What it gives you |
|---|---|
| **[Vehicle reset limits](docs/REFERENCE.md#vehicle-reset-limits)** | Cap resets per driver per session. Once the allowance is gone the reset key genuinely stops working. Optionally respawn at the last checkpoint instead of in place. |
| **[Reset ghosting](docs/REFERENCE.md#reset-ghosting)** | A driver who resets is intangible for a few seconds instead of reappearing solid in the racing line. Collisions come back only once the space around them is provably clear — never while another car is inside them. |
| **[Rallycross joker laps](docs/REFERENCE.md#rallycross-joker-laps)** | A second gate route that must be taken exactly once per race. Lap 1 is closed, and the server disqualifies anyone who missed it or took it twice. |
| **[Garage List](docs/REFERENCE.md#vehicle--setup-locking-the-garage-list)** | Lock the session to exact cars *and* exact tunes. Anything not on the list gets deleted and the driver is told why. |
| **[Cup points](docs/REFERENCE.md#cup-points)** | Championship points across several events — all races, all derbies, or a mixture. Scoring presets, qualifying points and bonuses; race and derby standings kept separate with a combined total. Points survive resets and a server restart; only ending the cup clears them. |
| **[Display names](docs/REFERENCE.md#display-names)** | Give `Guest_4471` a readable name for the leaderboard and the results file. Saved on the server, so it survives a restart. |
| **[Live position tracking](docs/REFERENCE.md#live-position-tracking)** | True running order from laps, checkpoints cleared and distance to the next gate — not just the grid order. |
| **[Demo Derby](docs/REFERENCE.md#demo-derby-parallel-game-mode)** | A separate last-man-standing mode with its own arena, timers and results, fully isolated from the racing. |
| **[Driver UI](docs/REFERENCE.md#driver-ui-non-admins)** | Non-admins see just the leaderboard during a session. Resizable, and fades so it doesn't block the view. |

## Troubleshooting

**The app doesn't show up:**

- Since BeamNG **v0.39** the app list is called **HUD Apps**, not *UI Apps*,
  and is reached from the Pause menu (*System → HUD Apps*). Race Manager is
  under the **Racing** and **Info** categories.
- The game only scans mods at startup — **restart BeamNG** after
  installing/updating. If the list is still stale, clear the cache
  (Launcher → *Manage User Folder* → *Clear Cache*).
- Check the zip has `ui/`, `lua/` and `scripts/` at its **root** (no extra
  top-level folder from zipping the parent directory).
- In singleplayer, confirm the mod is **enabled** in the in-game Mods menu.
- Look for `Race Manager client bridge loaded` in the console (`~`). If it's
  missing, the modScript never ran, meaning the zip wasn't mounted.

**Buttons do nothing, or the UI flickers between two states:** you have
mismatched or duplicated versions installed — see the note under
[Install](#install).

**Drivers rejected in a car that's plainly on the Garage List:** a BeamNG
update renamed some vehicle parts, which changes the configuration signature.
Re-capture the list. See
[Game version compatibility](docs/COMPATIBILITY.md).
