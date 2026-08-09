# Race Manager — full reference

Every feature in detail: the complete race-night walkthrough, league
regulations, the Demo Derby, and how live positions are worked out.
The [README](../README.md) has the short version.

[← Back to the README](../README.md)

## Track layouts (persistent, per-map)

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
   (how far it reaches up and down), and **each gate owns its own**. The first
   gate of a new route gets the standard size; every gate after it inherits the
   size of the one placed before, so you set it once and drive the rest of the
   route. Click any placed gate to change it — **nothing else moves**. Raise the
   height on **high-banked tracks** so the rectangle covers the banking; what
   you see drawn in the world *is* the trigger, so you can verify it at a glance.

   > There used to be a global width/height that every gate without an override
   > read live. Nudging that slider resized the entire circuit at once,
   > retroactively, with no way back — so it is gone. Layouts saved under it are
   > unaffected: each gate is given the size it was drawn with as the layout
   > loads.
4. Every placed gate has **Go** (stand your car on it, facing the way through)
   and **Move Here** (move the gate to where your car is standing) — the same
   pair the starting grid has. A gate keeps its Width/Height override when it
   moves. Both work on the joker route and pit stalls too.
5. **Undo** removes the last gate, **Clear** wipes the route,
   **Hide/Show Gates** toggles the in-world drawing.
6. **Save** / **Load** keep a personal scratch copy on your own machine
   (`settings/raceManager/route.json`) — handy while iterating on a design.

#### Circuit or point to point

The **Main Route** row carries a toggle: **⟳ Circuit** or **⇥ Point to Point**.

- **Circuit** — the last gate is a start/finish line, and the race runs for the
  lap count.
- **Point to Point** — the stage is driven once, first gate to last, and the
  last gate is the finish. The gates relabel themselves (`1 START` … `N FINISH`),
  the header shows a **POINT TO POINT** badge, and the Laps field is disabled
  because laps do not apply.

Setting a circuit to one lap times the same thing, which is why that worked as a
workaround — but it reads as a one-lap circuit everywhere it is shown, and the
lap count becomes a setting an admin has to remember. The toggle is **saved with
the layout**, so a sprint stage stays a sprint stage.

Your lap setting is kept rather than overwritten, so switching a circuit layout
back in restores it. The mode is locked once a countdown or race starts.

#### Pit stalls

Switch the editor to the **Pit Stalls** tab, drive into each stall and press
**+ Place Pit Stall Here**. Stalls are drawn amber and labelled `PIT 1`, `PIT 2`.

**You have to stop in the box yourself.** Driving into a stall is not enough —
the car has to actually come to a stop inside it. While you are in the box and
still rolling the panel says *"come to a stop inside the box"*; the moment you
stop, the stop begins: the car is **held for 5 seconds, repaired in place, and
released**. The repair lands part-way through, so the car is whole before the
driver gets it back, and the same stall will not trigger again for 8 seconds.

Run through a stall without stopping and you simply **miss it**. Nothing is
seized, nothing is spent — no cooldown is started, so the stall is live again on
the very next visit and you can come round. Making the box alone the trigger is
what used to make a pit stop something that *happened to* a driver: clip a
corner of a stall at racing speed and the car was frozen where it stood,
mid-lane, at whatever angle it was travelling.

**A car serving a stop is ghosted.** It is frozen, so it cannot move out of the
way, and it is parked in the one part of the track everybody else arrives at
slowly and off-line. The ghost lasts exactly as long as the stop and is lifted
with the car. It rides the server's **reset-ghosting** switch: with that off,
nothing is ghosted here either — ghosting is applied per vehicle by each client
separately, so a car ghosted for its own driver and solid for everybody else is
worse than one that was never ghosted at all.

**A stall is an area, not a checkpoint.** They are kept out of the checkpoint
list entirely, so they can never affect laps, splits or the running order — you
can place them wherever a pit lane belongs without touching the race. A pit stop
is not a driver reset either: it spends no reset allowance and is never reported
as one. Every stop is logged server-side with the driver, the stall and the lap.

They are **not** respawn points. A stall repairs a car where it stands and does
nothing else — a later reset still goes wherever the reset ruleset says.

Drivers get a pole on the **nearest** stall so the lane can be found; a whole
lane wearing poles would read as a wall of gates across the track.

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

   The hold is **enforced, not just requested** — see
   [Holding the grid](#holding-the-grid) for what that means and what gets
   logged.
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
ready for league standings or a broadcast overlay.

The race table records **Pos, Start, Driver, Best Lap, Laps Led, Finish** (plus
Joker and Resets columns when those regulations are armed). `Start` is the grid
slot the driver lined up on, which is what makes a finishing position readable —
P2 means something very different from eighth on the grid than it does from pole.

Underneath it, two awards:

- **Half-way leader** — whoever completed the half-distance lap first.
- **Hard Charger** — the classified finisher who gained the most places between
  their grid slot and the flag.

```
Pos   Start  Driver                 Best Lap   Laps Led  Finish
P1    P3     Cara                   1:30.000   1         0:00.000    << RACE WINNER
P2    P1     Alice                  1:32.000   0         0:00.100
P3    P2     Dan                    1:33.000   0         0:00.200

 HALF-WAY LEADER: Alice  (led at lap 3 of 5)
 HARD CHARGER: Cara  (P3 -> P1, +2 places)
```

Half distance **rounds up** on an odd number of laps: a 5-lap race is decided at
lap 3, the same as a 6-lap one — that is the lap on which a driver has more of
the race behind them than ahead. A one-lap race has no half way and reports none.

A tie on places gained goes to the **higher finisher**. Drivers who did not
finish are not eligible — there is no finishing position to have gained to — and
if nobody gained a place the line is left out rather than given to whoever lost
the fewest.

Housekeeping:

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

### Fastest lap

The quickest lap set by anyone in the session is shown **in gold** in the Best
Lap column, so the whole field can see who holds it and when it changes hands.
The driver who sets it gets a short `FASTEST LAP — 1:31.240` notice, on the same
channel as the reset and joker messages.

The notice fires again whenever the time changes hands **or improves** — beating
your own fastest lap is announced too.

It is per session — a new race starts with nobody holding it — and it is decided
by the server, so every leaderboard agrees. Qualifying highlights the **quali
best** (the time that session is scored on); the race highlights the **race
best**.

### Holding the grid

Between **Generate Grid** and **GO!** every gridded car is frozen on its start
position. The freeze itself is applied by each client — the server has no
physics — but the server owns the rule and checks that it is actually working.

A car dropped onto a start position first has to fall onto its suspension, and
nothing polices it until it has come to rest — enforcing against settling makes
a car hover at the height it was dropped from, being reset every frame. Where it
settles is then what "on its slot" means.

Distances are measured **across the ground**. Stealing a start is a move
forwards; a car sagging on its suspension has not moved anywhere, and counting
that as movement is what caused the hover.

The two failures get different answers. A car that is merely *moving* on its slot
has lost its freeze and is re-pinned where it stands — no teleport, so nothing is
disturbed. A car that has actually **left** its slot is put back on it.

Each held car reports its position four times a second. A car more than
**0.5 m** from its assigned slot is put back on it, re-frozen, and the
correction is logged with the driver, the distance, the slot and the race
state:

```
[RaceManager] HOLD violation: Ryder was 2.50m off grid slot 4 during countdown
              (tolerance 0.50m) — pulled back, correction #1
```

Each client also watches its own car and pulls it back before the server has to,
so in practice a correction that reaches the server means the local guard did not
run. Both are driven by the car *moving*: a car standing still on its slot is
never touched, which is what lets you rev against the hold and pre-select a gear.
Corrections are rate-limited per driver so one shove does not become a storm.

The hold survives things that used to break it: a driver pressing reset on the
grid, a vehicle reloaded or respawned on the grid, and a placement that settles
too slowly all put the car back on its slot, held. A driver who resets on the
grid gets a notice saying so.

**Release is one broadcast to everybody.** No car is released ahead of another by
its position in a loop; the only spread is each client's own network latency.

**On launching:** a driver holding throttle with revs up will out-launch a driver
sitting idle, and that is intended — it is a standing start, and preparing the
launch is part of it. What the hold guarantees is that nobody is *ahead* of their
slot when the lights go out, not that everyone launches identically. One
consequence worth knowing: a car that has to be corrected is re-frozen, and
re-freezing resets the drivetrain, so that driver loses their revs and any
pre-selected gear. Only drivers whose hold actually failed pay that, and the
alternative is letting them creep.

If the server was never told where the grid slots are — an admin who built start
positions live on an older client build, so only a count was reported — it stays
out of it and the client-side guard alone enforces the hold. Loading a saved
layout always gives the server the coordinates.

### Reset ghosting

A driver who resets mid-session used to reappear **solid and stationary**,
often in the middle of the racing line, and whoever arrived next drove into
them. Reset ghosting removes that: for a few seconds after a reset the car has
no vehicle-to-vehicle collisions, in **both** directions — it cannot be hit and
it cannot hit anyone. Collisions with the **world and the terrain are
untouched**, so the car still sits on the road and still hits the scenery.

Everyone else sees the ghosted car go **translucent**, then fade back to solid
over the last second as a warning that contact is about to resume. The ghosted
driver gets a countdown of their own in the app.

It is on by default and applies during a race **and** during qualifying —
resetting into somebody is the same physical problem in both.

| Setting | Default | What it does |
|---|---|---|
| `ghostOnReset` | `true` | Master switch. `false` disables reset ghosting entirely |
| `ghostMinDurationSec` | `5.0` | How long a ghost lasts, from the moment the car is placed and settled |
| `ghostMaxDurationSec` | `15.0` | Ceiling on the timer when a driver resets repeatedly |
| `ghostAlpha` | `0.35` | How translucent a ghosted car looks to everyone else |
| `ghostFadeOutSec` | `1.0` | Seconds spent fading back to solid before contact resumes |
| `ghostOverlapMargin` | `0.25` | Metres of clearance required around a car before it goes solid |
| `ghostOverlapWarnSec` | `10.0` | How long a driver may sit blocked before being told to move clear |

The first three are **server** settings (near the top of
`server/RaceManager/main.lua`) because they are a league rule — a client running
a five-second ghost in a field running eight is a field where two cars disagree
about whether they can touch, so the server broadcasts them and every client
obeys. The last four are **client** settings (the `TUNE` table in
`lua/ge/extensions/raceManager.lua`): local presentation and local geometry that
no other client has an opinion about.

**Why the timer is not the whole story.** Restoring collisions on two cars that
are *inside each other* welds their node structures together. It ends both
drivers' races instantly and there is no recovery from it. So when the timer
expires the space around the car is measured against every other car on track —
a real bounding-box test, not a distance between origins, so a car lying
crossways through another is caught — and collisions come back only on a frame
that is provably clear.

Uncertainty counts as occupied, but it is always a question that can be asked
again rather than a permanent verdict. The space around a car is measured three
ways in order — its oriented bounding box, its axis-aligned world box, then its
own dimensions — so a car is nearly always measured at its true size: a car that cannot be measured precisely is
judged on distance, and one that is far away is not treated as being inside you.
The end of a session clears every ghost regardless — nothing stays intangible
past the flag.

That check has **no time limit and no override** while the session is running. A car parked inside another
stays a ghost indefinitely, is never forced solid, and goes solid the moment the
space clears. If it is blocked for longer than `ghostOverlapWarnSec` the driver
is told to **move clear** and the server logs it — a warning only, never a
penalty. Cars that are themselves ghosts are ignored by the check, because a
ghost cannot weld to anything and counting it would deadlock two overlapping
ghosts against each other forever.

Resetting again while already ghosted **restarts** the timer rather than adding
a second ghost, up to `ghostMaxDurationSec`. That cap is on the timer only and
never shortens the occupancy check.

Every ghost is logged server-side with the driver, the race time, their running
order, their lap and how far they were from their next checkpoint, so "reset to
phase through the pack" is answerable from the log. **It is worth knowing that
this is possible:** a ghosted car can drive through traffic for the length of
its ghost, and parking inside another car is a way to stay ghosted. Neither is
penalised — the log is there so an admin can see it and rule on it themselves.

Ghosting is collision and rendering only. Checkpoint, lap and split validation
are completely unaffected.

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

**On track, the joker stays violet and keeps its wording.** Drivers get a gate
pole on the joker like any other checkpoint, painted the same violet the editor
uses rather than BeamNG's stock alternate-route orange — which sits close enough
to the main route's colour that the joker read as more of the same lap, and this
is the one route where that mistake is a disqualification. Above it sits the
label the editor shows, in the same words: `JOKER 2/3`, `JOKER EXIT`,
`(lap 1: closed)` while the opening lap forbids it, and `(used)` once it has been
taken. The pole stays up after the joker has been taken, dimmed — *"you have
taken it"* is as much a thing a driver needs to know as *"you still owe it"*.

The label is drawn separately from the pole because BeamNG's gate markers render
**no text at all** — a pole can say where the joker is and never what state it is
in, which for the joker is the half that matters.

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
- **Resize & fade — everywhere the app renders.** Drag the grip in the
  bottom-right corner to resize the panel, and use the ◑ slider to set its
  background opacity so it does not obstruct the view. In minimal mode the
  grip and slider sit on the leaderboard and the driver bar; everywhere else
  (admins on any tab, and drivers between sessions) they sit on the whole app
  panel and in the header, with ⤢ to undo a drag.

  The opacity is one shared setting, so fading the HUD means the same thing in
  every view. The two sizes are stored separately — the leaderboard alone and
  the full panel with its chrome are different things to measure, so resizing
  one never disturbs the other. Everything is remembered in `localStorage`.

  **The grip sizes the panel inside the app window, it does not resize the
  window.** BeamNG paints every HUD app into a fixed-size box
  (`.ui-app-host`, `overflow: hidden`) whose size belongs to the HUD app
  layout editor — *Pause → System → HUD Apps*, edit mode, drag the app's
  corner — and an app has no supported way to grow its own box. So the grip
  stops at that edge rather than dragging into clipped, unreachable space.
  **To make Race Manager bigger, enlarge the window in the layout editor
  first, then drag the grip out to fill it.** Shrinking the window in the
  editor pulls an oversized stored panel back in automatically.

  The driver bar also shows live joker/reset status and keeps a 🔒 button so
  the login prompt is always reachable.

## Race and Derby are separate

The admin panel is grouped by **mode** first. The bar under the session header
picks one, and everything below it belongs to that mode:

| Mode | Controls above the tabs | Sub-tabs |
|---|---|---|
| **🏁 Race** | Start Quali, Generate Grid, Start Countdown, End Session, Reset, and the **Track** layout picker | Race · Quali & Grid · Garage · **Race Editor** |
| **💥 Derby** | Form Up, Start Derby, End Derby, and the live phase | Derby · **Derby Editor** |
| **⚙ Admin** | — | Master password, results housekeeping |

This is a change from earlier builds, where every panel shared one flat tab
strip and the race session controls sat above all of them. That put the **Track
layout picker over the Derby tab** — a *Load Layout* button for a race nobody was
setting up — and made Derby read as one more race panel rather than the separate
game mode it is. Nothing was removed in the regrouping: every control is still
there, under the mode it belongs to.

Both modes have an **Editor** sub-tab, and each one is a *render gate* as well as
a panel: opening it is what puts that mode's authoring visuals in the world, and
they belong to the admin who opened it. The **Race Entry** bar stays visible in
every mode, because it is one entry list — a driver who pressed **Join Race**
is entered for both, and never has to join twice.

**The leaderboard at the bottom follows the mode too.** In Race mode it is the
race (or qualifying) table; in Derby mode it is the **derby standings**, on both
derby sub-tabs — so the field stays on screen while you are building an arena.
There is one copy of each board in the app, not one per panel.

A **driver's** leaderboard is not driven by the mode bar, which they never see:
it follows the session. Once a derby forms up, their board is the derby
standings, through the countdown and the derby itself.

The mode you were last in, and the sub-tab you were last on **within each mode**,
are both remembered — switching to Derby and back lands on the race panel you
left.

## Demo Derby (parallel game mode)

A completely separate last-man-standing mode, isolated from the circuit
racing systems above (own server events, own UI panel, own results files —
running a derby never touches qualifying/race state). Pick **💥 Derby** on the
mode bar; its controls sit above the tab strip and its authoring tools are on
the **Derby Editor** sub-tab. Race controls are not shown while you are in it,
and derby controls are not shown while you are in Race — see
[Race and Derby are separate](#race-and-derby-are-separate).

1. **Set the rules**: *OOB timer* (seconds allowed outside the arena,
   default 5), *Demolished timer* (seconds a car may sit stopped before
   elimination, default 10) and *Max resets* (per driver per derby: `-1`
   unlimited, `0` none, `N` allowed — enforced exactly the way the race reset
   limit is, dead reset keys included), then **Set Rules**. When resets are
   limited the derby standings gain their own `Rst` column.
2. **Build the arena** on the **Derby Editor** sub-tab. There are two editors
   for it, and they produce the same thing — an ordered perimeter every client
   polices against — so pick whichever suits the ground:

   **▭ Rectangle.** Stand your car where the middle of the arena should be and
   the four corners are pulled out around you. **Set Centre Here** re-centres it
   on your car at any time, keeping the size. Three sliders do the rest, each
   with a number box beside it, the same pairing the per-gate size editor uses:

   - **Width** and **Length**, 10–500 m, the full span across the arena.
     **▣ Square** links the two so one slider drives both.
   - **Rotation**, 0–90°, to line the arena up with the ground it sits on. A
     rectangle repeats every quarter turn — 90° just swaps width and length.

   The four corners all sit at the **centre's height**, so on a slope the arena
   is a flat plane cut through the hill rather than a boundary that climbs it.
   That matches the rule being enforced: the out-of-bounds test has always
   ignored height, so a corner drawn further up the slope would not change who
   is in or out. The walls are drawn tall enough to cut into the ground rather
   than hover over it.

   **✎ Drive & Place.** The original editor, and still the only way to build an
   arena that is not a rectangle: drive to each corner and press
   **+ Boundary Marker**. Markers connect in order into a closed perimeter
   (3+ required). Any shape works, including non-convex ones.

   **Switching between them keeps your work.** A rectangle becomes four ordinary
   markers you can then drag anywhere; a hand-driven arena becomes the rectangle
   that bounds it. **Clear Boundary** throws the arena away and starts over with
   an empty drive-and-place one.

   **Wall height** (2–30 m) belongs to both and is **visual only** — it is how
   far up the walls are drawn, never what they enclose.

   Optionally place a **starting grid**: drive to each slot facing the way the
   car should point and press **+ Start Position** (slot 1 first;
   **Clear Start Grid** starts over). **Hide/Show Arena** keeps the setup view
   clean.

   A rectangle's corners are **derived** from its centre and extents, so they are
   not individually editable — the sliders are how it is changed, and the marker
   list is only shown for a drive-and-place arena. Those markers are listed under
   the controls — `M1…Mn`, with `P1…Pn` for the start slots — and every entry
   stays editable, exactly the way the
   [starting grid](#placing-the-starting-grid) does. Click one to open its
   controls:

   - **Go** puts your car on that entry. A start slot uses its own facing; a
     boundary marker has none, so you keep the heading you already had.
   - **Move Here** moves that one entry to where your car is standing now.
   - **✕** deletes it; the perimeter (or the grid) closes up around the gap and
     everything else keeps its number.

   Fixing marker 2 of twelve no longer means clearing the arena and driving the
   whole perimeter again. Deleting can take the arena under three markers — it is
   then simply not a polygon yet, the same state it is in before the third marker
   is first placed. All of it is **refused from Form Up onward**, like every other
   setup control: the arena cannot move under a field standing on it, so during a
   derby the lists stay readable but nothing in them can be changed.

   Arenas are **saved and loaded** the same way track layouts are. Type a name
   in the **Saved Arenas** panel and press **Save Current Arena**: the boundary
   polygon, both timers, the reset limit *and* the starting grid are stored on
   the server in
   `Resources/Server/RaceManager/derbyArenas.json`, tagged with the hosted map,
   so a prepped arena survives a restart. **Load Arena** pushes it to every
   connected client at once; **✕** deletes it. Loading is refused while a derby
   is running — the arena cannot move under the drivers.

   A rectangle is stored as **both** its shape and the four corners it produced,
   so it loads back editable by slider — and stays readable by anything that only
   understands the polygon. **Arenas saved before rectangles existed load exactly
   as they always have**, as drive-and-place arenas: there is no migration step
   and nothing is lost.

   **The arena is drawn two different ways**, because laying one out and driving
   in one are different jobs — the same split the checkpoint editor already makes
   between an authoring gate and a race one:

   | | Derby Editor (admin, panel open) | During a derby (everyone) |
   |---|---|---|
   | Walls | Solid enough to read as a surface | **Translucent** — you can see the car on the other side of one |
   | Corner posts and rails | Full height, bright | A dim ground rail and a short post |
   | Floor | The enclosed area filled in, so the limits are exact — *rectangles only; filling an arbitrary polygon safely means triangulating it, and the cheap way paints outside a concave shape* | None |
   | Labels, corner numbers, centre crosshair, size readout | Shown | **None** |
   | Start slots | All of them, numbered | Only your own, and only until the derby starts |

   The **boundary itself is always drawn** during a derby — leaving it is what
   eliminates you, so you have to be able to see it — but nothing authoring-only
   is. Closing the Derby Editor is enough to get the driving view: you do not
   have to start a derby to see what your drivers will see.
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
6. The driver table shows who's still in, who's out (with reason and
   elimination time) and the winner — under their **display name** if an admin
   set one (see *Display names* above), in both the standings and the exported
   results. When exactly one driver remains the
   server ends the derby, announces the **winner** in chat, and writes
   `derby_results_YYYY-MM-DD_HH-MM-SS.txt` to
   `Resources/Server/RaceManager/results/` (winner first, then everyone else
   in reverse elimination order). **End Derby** force-ends a running derby;
   pressing it again after the finish resets the mode for the next round.
