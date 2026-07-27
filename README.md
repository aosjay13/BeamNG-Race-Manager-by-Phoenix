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
  headings, gate dimensions) — including the **joker route** and the
  **starting grid**, if either is placed — under a name, tagged with the level
  the server is hosting. Saving the same name on the same map overwrites it.
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

Everyone can watch the live timing, but the **editor and all race/derby
controls are hidden until you log in as an admin**. Type the master password
into the **Admin Login** bar and press **Login**; on success the controls
appear and an **ADMIN** badge shows in the header. Because BeamMP guest IDs
rotate constantly, admin rights are gated by this shared password rather than
a name/ID whitelist, and they are dropped as soon as you disconnect (or when
the admin presses **Log out**).

You never have to log in just to watch: press **Spectate »** on the login bar
to dismiss it and follow the timing. If an admin is already running the
session the prompt hides itself automatically. Either way a **🔒 Login**
button stays in the header so you can bring the login screen back at any time.
Admins can rotate the master password to **anything they like** from the
**Change password** bar — it applies on the server immediately.

> The server ships with a **default password of `phoenix`** (set at the top of
> `server/RaceManager/main.lua`). **Change it before your first public
> session:** log in, then use the **Change password** bar to set a new one — it
> takes effect on the server immediately.

### Step 2 — Build a track

Press **Editor** in the header to open the checkpoint editor, then drive the
course you want to race:

1. At each place you want a timing gate, drive through it **in the direction
   of travel** and press **+ Checkpoint Here**. A gate is a **flat rectangle**
   standing perpendicular to your heading — cars must pass through it.
2. **The last gate you place is the start/finish line** (drawn white in the
   world; earlier gates are orange, and your next target turns green during
   a session).
3. Every gate has a **width** (how far it reaches across) and a **height**
   (how far it reaches up and down). Set the live defaults with the **Gate
   width** slider (2–120 m) and the **Gate height** field. Raise the height on
   **high-banked tracks** so the rectangle covers the banking — what you see
   drawn in the world *is* the trigger, so you can verify it at a glance.
   Click any placed checkpoint in the list to **override its own
   Width / Height** (blank = inherit the default).
4. **Undo** removes the last gate, **Clear** wipes the route,
   **Hide/Show Gates** toggles the in-world drawing.
5. **Save** / **Load** keep a personal scratch copy on your own machine
   (`settings/raceManager/route.json`) — handy while iterating on a design.

#### Placing the starting grid

Switch the editor to the **Start Grid** tab, then drive to each grid slot
**facing down the track** and press **+ Place Start Position Here**. Slot 1 is
pole. Every placed slot stays editable:

- **Go** puts your car on that slot so you can check the spacing.
- **Move Here** moves the slot to wherever your car is standing now.
- **✕** deletes the slot; the rest of the grid closes up behind it.

Slots are drawn as numbered outlines with a direction arrow, and your own slot
turns green once the server assigns it. The grid is **saved and loaded with the
track layout**, so a track is its gates *and* where the cars line up.

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

### Step 4 — Who is actually in the race

Being connected is **not** the same as being entered. Every player gets a
**Race Entry** bar with a **Join Race** button; only drivers who joined are
put on the grid, and the bar shows how many have entered. Withdrawing
(**Leave Race**) gives up your slot. Entry closes once the countdown starts.

An admin can flip the mode to **Everyone races** if a session is simpler that
way — then every connected player is in the field, which is how the plugin
behaved before entry lists existed. Entry survives a **Start Quali**, so
drivers only ever have to join once per event.

### Step 5 — Qualifying

Press **Start Quali**. Every driver's first crossing of the start/finish
line starts their flying lap (the out-lap is free), and each full lap
through all gates posts to the server — the table shows everyone's **Best
Lap**, laps run and live provisional grid order, fastest on top. Only your
best counts. **End Session** closes qualifying but keeps the times.

Three qualifying options sit in the admin settings:

| Setting | What it does |
|---------|--------------|
| **Ghost quali** | Rival cars stop being obstacles for the session, so a flying lap can't be ruined by traffic. Ghosted cars are faded so you can see who they are. |
| **Quali laps** | Timed laps each driver gets. Their session ends when they use them up; the whole session closes once nobody has laps left. `0` = unlimited. |
| **Quali mins** | Wall-clock limit. The header shows the countdown, and the session closes itself when it expires. `0` = no limit. |

Both limits are locked while qualifying is actually running, so nobody has
the rug pulled mid-lap.

### Step 6 — Grid and race

1. Set the race distance with the **Laps** field + **Set** (visible to
   everyone as `race: N`).
2. Choose the **Grid order**:
   - **Quali** — fastest-first from quali bests; drivers without a time go to
     the back (the default, and with no qualifying at all it falls back to
     join order).
   - **Random** — a random draw, for a race with no qualifying behind it.
   - **Custom** — type a slot number next to any driver in the **Start**
     column and press Enter. Pinning a slot someone else holds takes it off
     them rather than doubling up; unpinned drivers fall in behind by quali
     time.
3. Press **Generate Grid**. Every entered driver is **placed on their start
   position and held there** — you cannot move until the countdown finishes,
   so nobody jumps the start. The header shows your slot and a `HOLD` tag.
   If there are more drivers than placed start positions, chat warns you.
4. Press **Start Countdown**: everyone gets a synchronized 3‑2‑1‑**GO!**
   overlay, every car is released by that same broadcast, and the race clock
   starts.
5. Race. The table now shows **Pos** (live position), the starting grid slot,
   current lap, best race lap and **Led** (laps led), and it re-sorts itself
   leader-first in real time as places change (see *Live position tracking*
   below). Finish order is decided by the server's single clock, so it's fair
   for every client.
6. The race ends when everyone has finished (or you press **End Session**,
   which DNFs anyone still out). Disconnecting mid-race is an automatic DNF.

### Step 7 — Results

When the race closes, the server automatically writes a results file
(qualifying classification + race classification, pole and winner tagged) to
`Resources/Server/RaceManager/results/` and announces the path in chat —
ready for league standings or a broadcast overlay. Housekeeping:

- **Reset** wipes the session back to Waiting with fresh driver records.
- **Clear Results Cache** deletes all saved result `.txt` files on the
  server (chat confirms how many were removed).

## Live position tracking

The race leaderboard shows the **actual running order**, not the starting
grid: a **Pos** column (P1, P2, …) sits next to **Start**, and the rows
re-sort themselves leader-first as places change on track.

Positions are decided by three metrics, in this exact order:

1. **Laps completed** — more laps is ahead. This comes from the server's own
   lap counter (`RM_Lap`), never from client telemetry, so a client cannot
   invent a lap.
2. **Checkpoints cleared** — on the current lap, more gates passed is ahead.
3. **Distance to the next checkpoint** — straight-line metres from the car to
   the centre of the gate it is driving towards. Shortest is ahead.

Metrics 2 and 3 can only be measured where the physics live, so each client
computes its distance to the next gate every frame and reports
`{ lap, checkpoints, distance }` to the server roughly **3 times a second**
(and immediately after clearing a gate, which is when places actually change).
Reports are validated and stored but **never broadcast on their own** — the
race tick loop re-sorts the field, stamps every driver with their position
integer and pushes the whole ordered array to all clients every **~300 ms**,
so a full grid costs a fixed handful of messages per second no matter how many
cars are running.

Classified finishers hold the top places by finish time, drivers still
circulating follow in running order, and DNF/disqualified drivers sit at the
bottom. The leaderboard flashes a green ▲ or red ▼ next to a driver who has
just gained or lost a place, and your own distance to the next checkpoint is
shown in the app header while you race.

## League regulations

Several rule systems layer on top of the session flow above. All of them are
off by default, so a plain race night behaves exactly as it always did.

### Vehicle reset limits

**Max resets** (Race settings, admin only) decides how many vehicle
resets/repairs each driver gets per session:

| Value | Meaning |
|-------|---------|
| `-1` (or blank) | Unlimited — the default |
| `0` | No resets at all: the reset button does nothing |
| `N` | `N` resets; every press after that is blocked |

The BeamMP server never sees a reset happen, so the **client** polices it.
Every reset inside the allowance is counted and reported (the leaderboard
gains an `Rst` column showing `used/allowed`). Once the allowance is gone the
reset is **blocked rather than punished**: BeamNG has already teleported the
car by the time the mod hears about it, so the car is put straight back on the
position and orientation it held a moment earlier. The driver keeps racing —
they simply cannot use the reset button any more.

Blocked attempts are still counted, so the `Rst` column reads `3/3+2` for a
driver who kept pressing R after running out, and the results file records the
same. Nobody is disqualified for it. The limit is locked once a countdown or
race starts.

### Cars on and off the track

Two things happen automatically so the track only ever holds cars that are
still racing:

- **A driver who takes the flag is removed from the track** and put into
  freecam. A finished car has nothing left to gain and is an obstacle for
  everyone still running.
- **When the session ends, every removed car is put back.** The same applies
  to a driver **eliminated in a Demo Derby** — their car returns when the derby
  finishes. The spectator lock is scoped per mode, so a race and a derby can
  never release each other's spectators.

### Rallycross joker laps

A **joker route** is a second, independent set of checkpoint gates describing
the alternate rallycross line. Build it in the editor with the **Joker Route**
tab (gates are drawn violet in the world), and it is saved and loaded together
with the track layout — one layout carries both routes.

Switch **Joker lap** on in Race settings and the rule is enforced:

- The joker route must be completed **exactly once per race**.
- **Lap 1 is closed**: any joker attempt on the opening lap is invalidated by
  the client on the spot — the progress is thrown away and nothing is reported.
- Repeat runs after a valid one are ignored and flagged to the driver.
- At the flag the **server rules on every finisher**. Anyone who did not take
  the joker exactly once is reclassified as
  **`Disqualified - Missed Joker`** (or `Disqualified - Extra Joker`), which
  goes straight into the results `.txt` alongside a `Joker` column showing the
  lap each driver used.

### Vehicle & setup locking (the Garage List)

The **Garage** panel (admin only) locks the session down to exact cars *and*
exact tunes:

1. Drive the car you want to allow, with the setup you want to allow, and
   press **+ Whitelist Current Vehicle**. The client fingerprints the exact
   configuration (jbeam model + every part in the part config + every tuning
   variable) and sends it to the server.
2. Repeat to build a Garage List of allowed cars. The list persists in
   `Resources/Server/RaceManager/garage.json` across restarts.
3. Flip the panel's toggle to **Enforcing**.

Enforcement runs on two layers, because the server has no vehicle
introspection of its own:

- BeamMP's `onVehicleSpawn` / `onVehicleEdited` hooks cancel any car whose
  **model** is not on the list before it exists for other players.
- Each client reports its exact configuration signature on spawn and whenever
  its setup changes; a signature that is not on the list gets the vehicle
  **deleted** and pushes **"Vehicle/Setup not allowed in this session."** to
  that player's UI.

Authenticated admins are exempt (otherwise you could never spawn the car you
are about to whitelist), and an empty list never enforces anything, so it is
impossible to lock the whole server out by accident.

### Driver UI (non-admins)

- **Checkpoint gates are drawn for everyone.** During a countdown, qualifying
  session or race the 3D oriented bounding boxes are visible on every
  connected client; the Hide/Show Gates toggle now only applies outside a
  session, where it exists to keep the editor view tidy.
- **Minimal mode.** A player who is not logged in as an admin sees *only the
  leaderboard* while a session is live — header, session controls, editor,
  derby panel, login bar and all panel backgrounds are removed from the DOM.
  During a derby the leaderboard shows the derby standings instead.
- **Resize & fade.** Drag the grip in the bottom-right corner of the
  leaderboard to resize it, and use the slider in the thin driver bar to set
  its background opacity so it does not obstruct the view. Both settings are
  remembered in `localStorage`. The driver bar also shows live joker/reset
  status and keeps a 🔒 button so the login prompt is always reachable.

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

   Arenas are **saved and loaded** the same way track layouts are. Type a name
   in the **Saved Arenas** panel and press **Save Current Arena**: the boundary
   polygon *and* both timers are stored on the server in
   `Resources/Server/RaceManager/derbyArenas.json`, tagged with the hosted map,
   so a prepped arena survives a restart. **Load Arena** pushes it to every
   connected client at once; **✕** deletes it. Loading is refused while a derby
   is running — the arena cannot move under the drivers.
3. **Start Derby**: every connected player becomes a participant. Each client
   checks its own vehicle against the arena polygon (ray-casting
   point-in-polygon) and its own speed:
   - Leaving the arena flashes **OUT OF BOUNDS! RETURN IN X.Xs** — return in
     time or you're **Disqualified**.
   - Sitting still flashes **VEHICLE STOPPED! DEMOLISHED IN X.Xs** — get
     moving or you're **Demolished**. Disconnecting counts as Disqualified.
   - An eliminated driver's vehicle is removed and their camera is forced into
     **freecam** until the derby ends; they cannot spawn a replacement car.
     When the derby finishes, their car is **put back** automatically.
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
