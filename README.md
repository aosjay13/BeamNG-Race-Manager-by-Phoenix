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

> **When updating: remove old copies first.** Two versions of the server
> plugin installed side by side (e.g. an old `RaceManager` folder next to a
> renamed new one) each run their own state machine and take turns
> broadcasting, which makes every UI element flicker between two states on
> each tick. State broadcasts now carry a protocol stamp and the client
> ignores unstamped ones (a notice tells you when that happens), but the
> outdated copy should still be deleted from `Resources/Server/`.

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
Build/Load a track  →  Start Quali  →  Start Countdown  →  Qualifying
                    →  Generate Grid  →  Start Countdown  →  Race  →  Results
```

Qualifying and the race run the **same** session lifecycle: form the grid,
hold the field, count down, run, take finished cars off the track, give
everybody their car back. The only things that differ are the lap target and
how a lap is scored (best lap in qualifying, running order in the race).

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
drivers only ever have to join once per event (**Reset** stands the whole
field down and everyone joins again).

The two modes are two answers to "who is in the field" and nothing more —
from there they run identical code. A field of drivers who all pressed **Join
Race** grids exactly the same way, slot for slot, as flipping to **Everyone
races**.

### Step 5 — Qualifying

Press **Start Quali**, then **Start Countdown**. Start Quali forms a
qualifying grid exactly the way Generate Grid forms a race one — every
entrant is stood on a start position and held — and the countdown releases
the field.

Lap 1 starts at the line, so **three qualifying laps means three laps**.
There is no out-lap: qualifying used to begin wherever each driver happened
to be parked, which cost everyone a lap before their first one counted and
made a "3 lap" session take five or six.

Each full lap through all gates posts to the server — the table shows
everyone's **Best Lap**, laps run and live provisional grid order, fastest on
top. Only your best counts. A driver who uses their lap allowance is taken
off the track until the session ends, then gets their car back with everyone
else. **End Session** closes qualifying early but keeps the times.

Three qualifying options sit in the admin settings:

| Setting | What it does |
|---------|--------------|
| **Ghost quali** | Rival cars stop being obstacles for the session, so a flying lap can't be ruined by traffic. Ghosted cars are faded so you can see who they are. |
| **Quali laps** | Timed laps each driver gets. Their session ends when they use them up; the whole session closes once nobody has laps left. `0` = unlimited. |
| **Quali mins** | Wall-clock limit. The header shows the countdown; when it expires the session runs a **final lap** (below) rather than stopping dead. `0` = no limit. |

**The final lap.** When a timed session's clock expires it does not end the
session — everyone still out is mid-lap, and in qualifying that is the lap
that matters. Instead:

- chat and the header announce **FINAL LAP**; the clock is replaced by that
  badge;
- every driver stays controllable and on track;
- each driver's session ends **as they cross the start/finish line** — their
  car is taken off the track exactly as it is when a lap allowance runs out;
- when the last one is home, everybody respawns together.

That last lap still **counts**: a time set on it goes into your Best Lap and
can move you up the order. The grid is not frozen at expiry, it settles when
the last driver has taken the flag.

Two rules keep it from hanging. A crossing the server sees *after* expiry is
terminal — there is no extra lap for whoever was closest to the line, and
arrival order at the server decides it, the same way it decides every other
question of who was first. And a driver who never comes round (parked, in the
pits, never left the grid) is bounded by a **3 minute grace**, after which
the stragglers are taken where they stand and the session closes normally.

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
   Cars are ghosted while the field forms up and land one after another
   rather than all at once, so a full grid cannot refuse a placement for an
   occupied slot or arrive interpenetrated and blow itself apart; collisions
   come back once everyone is standing still on their slot.
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
   At the flag **every** participant gets their car back — ghosted and
   staggered, the same as a grid forming — and each driver's camera is put
   explicitly back on their *own* car rather than on whichever vehicle the
   game happens to pick.

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

## Display names

BeamMP calls a guest something like `Guest_4471`, which makes for an
unreadable leaderboard and a worse results file. An admin can give any driver a
readable name from the **Admin** tab: the panel lists everyone connected with
their real name, a box, **Set**, and **✕** to clear.

The name is **display only**. Timing, checkpoints, scoring and the starting grid
all key on the BeamMP player id exactly as before — an alias is never used as a
lookup, so renaming somebody mid-session moves nothing but the text on screen.

**Names last as long as the connection does.** They survive Start Quali,
Generate Grid, a whole race, **Reset**, and a second race after that — a name
is bound to the BeamMP player id in a registry that outlives the per-session
driver records, and never to a vehicle (a vehicle id changes on every
respawn, so a name attached to one would not survive a single reset).

They do **not** survive a reconnect, and that is a consequence of the accounts
restriction rather than a choice: every player is a guest, BeamMP recycles
session ids between players, and a guest name is regenerated on every join, so
there is nothing stable to attach a lasting name to. If a driver reconnects,
set their name again. The account id BeamMP exposes for a *logged-in* player
would be the right anchor, and is where this goes when the restriction lifts.

- **Fallback** — a driver with no name set simply shows their guest name. It can
  never render blank.
- **Validation** — 3–20 characters, letters, digits, spaces and `- _ .` only.
  ASCII only, because the results file lays out fixed-width columns and Lua pads
  by bytes, so one accented character would shear every row below it.
- **Collisions and impersonation** — a name already in use, as an alias *or* as
  someone's real guest name, is refused; so are `admin`, `server`, `host`,
  `console` and anything starting with `guest`.
- **Every attempt gets an answer** — the name applies, or a notice says why not.
- **A recycled session id never inherits a name.** BeamMP hands ids out again
  after a disconnect; if a different player turns up on one, the display name is
  dropped rather than passed on.
- **Race and derby** — names show on the race leaderboard, the derby standings
  and the derby winner announcement.
- **Results files** — both the race and derby exports record the name the driver
  raced under, with their real guest name in brackets beside it, so a file is
  readable *and* still traceable back to the session that set the times. Results
  are a snapshot: renaming somebody later never rewrites a file already written.

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
reset **inputs themselves are switched off** through BeamNG's input action
filter — pressing reset/recover does nothing at all, the car never resets,
and the driver simply keeps racing. As a fallback for reset paths the filter
cannot see, any reset that still slips through is undone: the car is put
straight back on the position and orientation it held a moment earlier.

Blocked attempts are still reported to the server and recorded in the results
file (`3/3+2` for a driver who kept pressing R after running out), but the
live `Rst` counter is clamped — it only ever shows `used/allowed` and can
never exceed the limit. Nobody is disqualified for a blocked attempt. The
limit is locked once a countdown or race starts.

**Reset mode** (Race settings, admin only) decides what a *legal* reset does
while racing:

| Mode | Behaviour |
|------|-----------|
| **In place** | BeamNG's normal repair-where-you-stand (the default) |
| **Last checkpoint** | The car is respawned at the last checkpoint it crossed, facing the direction of travel |

Last-checkpoint mode applies whether or not resets are limited; before the
first checkpoint of a session it falls back to in-place. Like every
regulation it is locked once the countdown starts.

Two details keep a spent allowance from turning into a stuck car. BeamNG
reports every teleport as a vehicle reset, including the ones the mod performs
itself, so the car being put back — and being stood on its grid slot — is
recognised as the mod's own doing and never counted, blocked or reported.
And because the reset key repeats while it is held, the block is applied to
every press but the notice, the console line and the server report are limited
to one a second.

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

1. **Set the rules**: *OOB timer* (seconds allowed outside the arena,
   default 5), *Demolished timer* (seconds a car may sit stopped before
   elimination, default 10) and *Max resets* (per driver per derby: `-1`
   unlimited, `0` none, `N` allowed — enforced exactly the way the race reset
   limit is, dead reset keys included), then **Set Rules**. When resets are
   limited the derby standings gain their own `Rst` column.
2. **Build the arena**: drive to each corner of your intended arena and press
   **+ Boundary Marker** — each press drops a red pole at your vehicle's
   position, and the poles connect in order into a closed perimeter polygon
   (3+ markers required; **Clear Boundary** starts over). Any shape works,
   including non-convex ones. Optionally place a **starting grid**: drive to
   each slot facing the way the car should point and press
   **+ Start Position** (slot 1 first; **Clear Start Grid** starts over).
   **Hide/Show Boundary** keeps the setup view clean. Once the derby starts the
   **boundary is always drawn** — leaving it is what eliminates you, so you have
   to be able to see it — while the **start slots are hidden**, since every car
   has left its slot by then and the outlines would just clutter the arena.

   Arenas are **saved and loaded** the same way track layouts are. Type a name
   in the **Saved Arenas** panel and press **Save Current Arena**: the boundary
   polygon, both timers, the reset limit *and* the starting grid are stored on
   the server in
   `Resources/Server/RaceManager/derbyArenas.json`, tagged with the hosted map,
   so a prepped arena survives a restart. **Load Arena** pushes it to every
   connected client at once; **✕** deletes it. Loading is refused while a derby
   is running — the arena cannot move under the drivers.
3. **Entry** decides who takes part. **Everyone** (the default) puts every
   connected player in the field, which is how the derby has always behaved.
   **Opt-in** honours the same **Join Race** button the circuit races use, so
   somebody who only wants to watch is not dragged in — worth knowing that being
   entered means losing your car to freecam the moment you are eliminated.
   Drivers never have to join twice: it is one entry list, read by both modes.
   The counter beside the toggle shows how many would be in a derby started
   right now, and the mode is locked from Form Up onward.
4. **Form Up**, then **Start Derby** — the same two steps a circuit race uses.
   **Form Up** stands every participant on a start slot and **holds them there**;
   the header reads *Formed up — held*. **Start Derby** then runs a synchronised
   3‑2‑1‑**GO!**, and that same broadcast releases every car at once, so nobody
   can creep away early. A driver with no slot placed for them is held where
   they are rather than getting a free run at the field. **Abort Start** puts
   everyone back if you formed up by mistake — no result is recorded.

   The arena, the timers and the entry mode are all **locked from Form Up
   onward**, not just once the derby is running: cars are already standing on
   their slots by then and the ground must not move under them. Set the rules
   before you form up.
5. Once the lights go out each client polices **itself**, checking its own
   vehicle against the arena polygon (ray-casting point-in-polygon) and its own
   speed:
   - Leaving the arena flashes **OUT OF BOUNDS! RETURN IN X.Xs** — return in
     time or you're **Disqualified**.
   - Sitting still flashes **VEHICLE STOPPED! DEMOLISHED IN X.Xs** — get
     moving or you're **Demolished**. Disconnecting counts as Disqualified.
   - An eliminated driver's vehicle is removed and their camera is forced into
     **freecam** until the derby ends; they cannot spawn a replacement car.
     When the derby finishes, their car is **put back** automatically —
     ghosted and staggered like every other mass respawn, and this is the
     biggest one in the mod, since a derby ends with nearly the whole field
     removed. Each driver's camera goes back on their own car.
5. The driver table shows who's still in, who's out (with reason and
   elimination time) and the winner — under their **display name** if an admin
   set one (see *Display names* above), in both the standings and the exported
   results. When exactly one driver remains the
   server ends the derby, announces the **winner** in chat, and writes
   `derby_results_YYYY-MM-DD_HH-MM-SS.txt` to
   `Resources/Server/RaceManager/results/` (winner first, then everyone else
   in reverse elimination order). **End Derby** force-ends a running derby;
   pressing it again after the finish resets the mode for the next round.

## Game version compatibility

Tracked against **BeamNG.drive v0.39.2** and **BeamMP v4.22.0**. The mod talks
to a lot of game surfaces — vehicles, cameras, the input action filter, the
debug drawer, the UI app host, BeamMP's event bridge — so every release gets a
pass over the changelogs.

### BeamMP v4.22.0

| v4.22.0 change | Effect on the mod | Status |
|---|---|---|
| BeamMP renamed its extension hooks with an `onBeamMP*` prefix — `onServerLeave` → `onBeamMPServerLeave`, `runPostJoin` → `onBeamMPPostJoin`, `onLauncherConnected` → `onBeamMPLauncherConnected` | The mod referenced none of them, which was the bug: it never learned that a session had started or ended. Every regulation the server owns is *applied* on the client (reset keys switched off at the input filter, the car frozen on its grid slot, a finished or eliminated driver held in freecam) and lifted by a broadcast — so leaving a server mid-race dropped you into singleplayer with a dead reset key, a frozen car and a camera reasserting freecam every second | Fixed: the mod now handles the session-leave hook and purges everything it was enforcing. Both the new and the old hook name are registered, so it works on v4.22.0 and on v4.21.1 and earlier |
| Same rename on the join side | The extension can be mounted and loaded before BeamMP's network extension is ready, in which case it bound no handlers and sat deaf for the whole session | Fixed: the join hook (both names) re-binds the handlers and asks the server for the live state a beat later, so joining mid-session works without opening the app |
| Handlers are keyed by a *source* and a re-registration from the same source replaces rather than stacks | Only affects how the bridge binds | The source is now passed explicitly instead of being inferred from the call site, so re-binding is idempotent. Older builds ignore the extra argument |
| TCP connection handling and retry logic; batch-based mod loading; UI refresh; avatar null-pointer fix; translation updates | Internal to BeamMP | No change needed |
| `ADM` → `ADMIN` role rename; `ui.multiplayer.*` → `ui.beammp.*` translation keys | The mod uses neither BeamMP roles nor its translation keys | No change needed |

**Ghost qualifying, one honest caveat:** BeamMP exposes no vehicle-collision
toggle — not in v4.22.0 and not in v4.21.1 either, so this is not a regression.
The mod probes for one and, finding none, fades rival cars so you can *see* who
is ghosted, but they remain solid. The console says so when the rule arms.

### BeamNG.drive v0.39.2 (hotfix)

Reviewed, **nothing to change in the code**. The hotfix covers a Mod Manager
update fix, an explicit D3D12 launcher option with better GPU detection, the
VRAM detection threshold dropping 6 GB → 5.5 GB, a Wl40 front-axle fix, and
premature Steam achievement unlocks. None of it touches a surface this mod
binds to: no UI/HUD app hosting, no GE Lua or `guihooks` change, nothing on the
input action filter, `onVehicleResetted`/`objectTeleported`, the debug drawer,
or the cameras.

Two things for admins rather than the code, though:

| v0.39.2 change | Why it matters here | What to do |
|---|---|---|
| *"Fixed update process for users with mods installed"* — the automatic mod-disabling system on major updates **failed to trigger** for some users, and now does | Anyone in that group can come back from the update with the client mod switched off. It is the same end state as the "app doesn't show up" case below, reached by a different route | Check Race Manager is still listed under **HUD Apps** and enabled in the Mods menu. Whether BeamMP-pushed client mods are caught by this as well is not stated in the changelog — worth a look on the first session after updating |
| Wl40 front-axle fix on the showloader configuration | A jbeam change to a shipped vehicle. The Garage List matches an exact configuration **signature** built from part names, so a part that moved or was renamed invalidates a stored entry and the driver is rejected in a car that is plainly approved | **Re-capture any whitelisted Wl40.** Entries record the game build they were captured on, so a rejection caused by this says so rather than reading as an ordinary "setup not allowed" |

### BeamNG.drive v0.39.1 (hotfix)

Reviewed, nothing to change. The hotfix covers jbeam parts with a missing
`slotType`, D3D12 texture/VRAM/emissive fixes with a D3D11 fallback, a fix for
large mod lists failing to load, restored vehicle spawning under memory
pressure, and a PlayStation controller crash. None of it touches a surface this
mod binds to — it draws only immediate-mode `debugDrawer` shapes and ships no
jbeam.

### BeamNG.drive v0.39

| v0.39 change | Effect on the mod | Status |
|---|---|---|
| *"Renamed UI Apps to HUD Apps"*, UI ported to Vue | The app is an AngularJS directive under `ui/modules/apps/`. Legacy Angular screens are still hosted, and the app uses plain HTML plus core `ng-*` directives only (no Angular Material, no `bng-*` components), so it keeps working — it is now listed under **HUD Apps**. Its `types` categories (`ui.apps.categories.racing`, `.info`) are both still live keys | No change needed |
| *"Changed naming of the custom config files"* — a saved setup's name lives in the vehicle's `info.json` and no longer matches the `.pc` filename | The Garage List labelled cars by the `.pc` filename stem, which now shows a sanitised derivative instead of the setup's real name | Fixed: the name is read off the config itself, with the filename kept as the fallback |
| *"Renamed a bunch of parts on some vehicles"* | The Garage List matches an exact configuration **signature** built from part names. Renamed parts change the signature without the car changing, so lists captured before v0.39 stop matching and drivers are rejected in a car that is plainly approved. Only a re-capture can fix it | Fixed as far as it can be: entries now record the game build they were captured on, and a rejection caused by that skew says so instead of reading as an ordinary "setup not allowed" |
| New Pause-menu **Vehicle Management** flow with its own repair/reset buttons | A reset the input action filter cannot see, so the "reset keys go dead" layer no longer covers every path | Already covered — the `onVehicleResetted` restore catches it and was built for exactly this |
| *"Improved vehicle teleporting detector `objectTeleported()`"* (fewer false negatives on fast vehicles) | The mod teleports the car itself (blocked-reset restore, grid placement, checkpoint respawn) and has to recognise the resulting reset hook as its own echo. A later-arriving echo from a fast car is no longer where it was put | Fixed: the "is this our own teleport" tolerance now scales with the distance the car could actually have covered, instead of a flat 2 m |
| `be:*` accessors called out as a framerate/GC cost, plus a new startup warning for slow extensions | The player's vehicle is read several times per frame | Fixed: uses `getPlayerVehicle(0)` / `getAllVehicles()`, falling back to the old calls on builds without them. The position behind those reads is now sampled **once per frame** and shared, and the gate draw loop caches its geometry, labels and colours instead of rebuilding them every frame for every gate |
| *"`guihooks.trigger` … now communicates only with the main UI HTML"* | Every UI push goes to the main UI app | No change needed |
| Folder-based translations (`locales/translations/<lang>/*.json`) | The mod ships no translation keys of its own; its app name and description are literal strings, which stay supported | No change needed |

The one thing an admin has to do by hand after a BeamNG update: if the
**Garage List** is in use, re-capture it. A game update that renames vehicle
parts invalidates every stored signature, and the server will now tell
rejected drivers that is what happened.

## Troubleshooting: the app doesn't show up

- Since BeamNG **v0.39** the app list is called **HUD Apps**, not *UI Apps*,
  and is reached from the Pause menu (*System → HUD Apps*). Race Manager is
  under the **Racing** and **Info** categories.
- The game only scans mods at startup — **restart BeamNG** after
  installing/updating, and if the app list is still stale, clear the cache
  (Launcher → *Manage User Folder* → *Clear Cache*).
- Check the zip has `ui/`, `lua/`, `scripts/` at its root (no extra
  top-level folder from zipping the parent directory).
- In singleplayer, confirm the mod is **enabled** in the in-game Mods menu.
- Look for `Race Manager client bridge loaded` in the console (`~`) — if
  it's missing, the modScript never ran, meaning the zip wasn't mounted.
