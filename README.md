# BeamNG Race Manager by Phoenix

A **multiplayer-only** race manager for BeamNG.drive on **BeamMP**: live standings,
lap counts, best/last lap times, and real-time gaps for every driver on the server.

## Architecture

The BeamMP server has no physics access, so the mod is split in three:

| Part | Path | Runtime | Role |
|------|------|---------|------|
| Server plugin | `server/RaceManager/main.lua` | BeamMP server (Lua 5.3, `MP.*` API) | Authoritative race state machine: grid, countdown, one shared clock, finish timestamps, broadcasts the driver table |
| Mod entry point | `scripts/raceManager/modScript.lua` | In-game (runs at mod mount) | Loads the client bridge — BeamNG **never** auto-loads GE extensions shipped in a mod zip |
| Client bridge | `lua/ge/extensions/raceManager.lua` | In-game GE Lua (LuaJIT / 5.1) | Waypoint editor, local finish-line detection (the server has no physics), relays server broadcasts to the UI |
| UI app | `ui/modules/apps/RaceManager/` | In-game UI (Angular) | Race controls, live driver table, waypoint editor panel |

Event flow: local car crosses the start/finish gate → `RM_QualiLap`/`RM_Lap`
to server → server scores it on its own clock → `RM_Update` broadcast to all
clients → UI.

Client and server obey **different rules**:

- **Client (BeamNG.drive)**: mods are zips mounted into the virtual
  filesystem. A UI app requires all four files (`app.js`, `app.html`,
  `app.json`, `app.png`) or it won't appear in the app selector, and GE
  extensions only load if `scripts/<name>/modScript.lua` loads them.
  Events use `AddEventHandler(name, fn)` / `TriggerServerEvent(name, str)`.
- **Server (BeamMP)**: Lua 5.3, no game/physics access. Handlers must be
  **global** functions registered by name string via
  `MP.RegisterEvent(event, "fnName")`; broadcast with
  `MP.TriggerClientEvent(-1, event, jsonString)`.

## Installation

### Server (BeamMP)

Copy `server/RaceManager/` into your BeamMP server's `Resources/Server/` folder:

```
Resources/Server/RaceManager/main.lua
```

### Client mod

Use `dist/RaceManager_Client.zip` (or zip the `scripts/`, `lua/` and `ui/`
folders yourself — they must sit at the **root** of the zip). Place it in
`Resources/Client/` on the server; BeamMP pushes it to joining players:

```
Resources/Client/RaceManager_Client.zip
  ├── scripts/raceManager/modScript.lua
  ├── lua/ge/extensions/raceManager.lua
  └── ui/modules/apps/RaceManager/{app.html,app.js,app.json,app.png}
```

For offline testing (waypoint editor only — racing needs BeamMP), drop the
same zip into your BeamNG user folder's `mods/` directory instead.

### Track layouts (persistent, per-map)

The **Track Layouts** panel at the bottom of the editor stores named
checkpoint configurations **on the BeamMP server** in
`Resources/Server/RaceManager/layouts.json`, so they survive server restarts
and can be prepped days before an event:

- **Save Current Layout** bundles the currently placed gates (positions,
  headings, gate width) under a name, tagged with the level the server is
  hosting. Saving the same name on the same map overwrites it.
- The dropdown is **strictly filtered by map** — the server only lists
  layouts saved for the level it is currently hosting.
- Selecting a layout draws a top-down **2D track preview** (checkpoints,
  connecting lines, start/finish gate in green) scaled to fit the minimap.
- **Load Layout** broadcasts the checkpoints to every connected client at
  once; everyone's gates rebuild instantly. Loading is locked during a
  countdown or an active race.

## Tutorial: running a race night

Everything below happens inside the **Race Manager** window in game. The
session flow is always the same:

```
Build/Load a track  →  Start Quali  →  Generate Grid  →  Start Countdown  →  Race  →  Results
```

### Step 1 — Open the app

Join the BeamMP server, open the UI app menu, and add **Race Manager** (it's
listed under the *Racing* and *Info* categories). The header shows the
current session phase (Waiting / Qualifying / Grid Locked / Countdown /
Racing / Race Over), the race clock, and your checkpoint progress (`CP 2/5`)
while you're on track.

### Step 2 — Build a track

Press **Editor** in the header to open the checkpoint editor, then drive the
course you want to race:

1. At each place you want a timing gate, drive through it **in the direction
   of travel** and press **+ Checkpoint Here**. A gate is two vertical poles
   spanning a line perpendicular to your heading — cars must pass between
   them.
2. **The last gate you place is the start/finish line** (drawn white in the
   world; earlier gates are orange, and your next target turns green during
   a session).
3. Use the **Gate width** slider to widen or narrow every gate live —
   2–120 m. Wide gates are forgiving; narrow ones force a precise line.
4. **Undo** removes the last gate, **Clear** wipes the route,
   **Hide/Show Gates** toggles the in-world drawing.
5. **Save** / **Load** keep a personal scratch copy on your own machine
   (`settings/raceManager/route.json`) — handy while iterating on a design.

### Step 3 — Save it as a layout (so it survives the night)

Scratch saves are local to you; **Track Layouts** (bottom of the editor
panel) live on the server and persist across server restarts:

1. Type a name in the **Layout name** field and press **Save Current
   Layout**. The server stores it tagged with the map it is hosting and
   announces it in chat.
2. To race a prepped track later, pick it from the dropdown — the list only
   ever shows layouts saved **for the current map** — and check the 2D
   preview: gate dots, the connecting track shape, and the start/finish line
   in green.
3. Press **Load Layout**. Every connected player's gates rebuild instantly;
   nobody has to load anything manually. (Loading is locked while a
   countdown or race is running.)

### Step 4 — Qualifying

Press **Start Quali**. Every driver's first crossing of the start/finish
line starts their flying lap (the out-lap is free), and each full lap
through all gates posts to the server — the table shows everyone's **Best
Lap** and live provisional grid order, fastest on top. Run as many laps as
you like; only your best counts. **End Session** closes qualifying but
keeps the times.

### Step 5 — Grid and race

1. Set the race distance with the **Laps** field + **Set** (visible to
   everyone as `race: N`).
2. Press **Generate Grid** — starting positions lock in fastest-first from
   quali bests; drivers without a time go to the back. (With no quali at
   all, the grid falls back to join order.) Line the cars up on track.
3. Press **Start Countdown**: everyone gets a synchronized 3‑2‑1‑**GO!**
   overlay and the race clock starts.
4. Race. The table now shows current lap, best race lap, **Led** (laps led),
   and live positions. Positions and finish order are decided by the
   server's single clock, so they're fair for every client.
5. The race ends when everyone has finished (or you press **End Session**,
   which DNFs anyone still out). Disconnecting mid-race is an automatic DNF.

### Step 6 — Results

When the race closes, the server automatically writes a results file
(qualifying classification + race classification, pole and winner tagged) to
`Resources/Server/RaceManager/results/` and announces the path in chat —
ready for league standings or a broadcast overlay. Housekeeping:

- **Reset** wipes the session back to Waiting with fresh driver records.
- **Clear Results Cache** deletes all saved result `.txt` files on the
  server (chat confirms how many were removed).

## Demo Derby (parallel game mode)

A completely separate last-man-standing mode, isolated from the circuit
racing systems above (own server events, own UI panel, own results files —
running a derby never touches qualifying/race state). Open it with the
**Derby** tab in the app header.

1. **Set the timers**: *OOB timer* (seconds allowed outside the arena,
   default 5) and *Demolished timer* (seconds a car may sit stopped before
   elimination, default 10), then **Set Timers**.
2. **Build the arena**: drive to each corner of your intended arena and press
   **+ Boundary Marker** — each press drops a red pole at your vehicle's
   position, and the poles connect in order into a closed perimeter polygon
   (3+ markers required; **Clear Boundary** starts over). Any shape works,
   including non-convex ones.
3. **Start Derby**: every connected player becomes a participant. Each client
   checks its own vehicle against the arena polygon (ray-casting
   point-in-polygon) and its own speed:
   - Leaving the arena flashes **OUT OF BOUNDS! RETURN IN X.Xs** — return in
     time or you're **Disqualified**.
   - Sitting still flashes **VEHICLE STOPPED! DEMOLISHED IN X.Xs** — get
     moving or you're **Demolished**. Disconnecting counts as Disqualified.
4. The driver table shows who's still in, who's out (with reason and
   elimination time) and the winner. When exactly one driver remains the
   server ends the derby, announces the **winner** in chat, and writes
   `derby_results_YYYY-MM-DD_HH-MM-SS.txt` to
   `Resources/Server/RaceManager/results/` (winner first, then everyone else
   in reverse elimination order). **End Derby** force-ends a running derby;
   pressing it again after the finish resets the mode for the next round.

## Troubleshooting: the app doesn't show up

- The game only scans mods at startup — **restart BeamNG** after
  installing/updating, and if the app list is still stale, clear the cache
  (Launcher → *Manage User Folder* → *Clear Cache*).
- Check the zip has `ui/`, `lua/`, `scripts/` at its root (no extra
  top-level folder from zipping the parent directory).
- In singleplayer, confirm the mod is **enabled** in the in-game Mods menu.
- Look for `Race Manager client bridge loaded` in the console (`~`) — if
  it's missing, the modScript never ran, meaning the zip wasn't mounted.
