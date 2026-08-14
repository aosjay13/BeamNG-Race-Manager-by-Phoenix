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
everybody their car back. The only things that differ are the lap target, how
a lap is scored (best lap in qualifying, running order in the race), and the
qualifying **out lap** — the first lap of a qualifying session is not timed,
because it starts from a standing grid (see [Step 5](#step-5--qualifying)).

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

**Everyone races** is the default: every connected player is in the field, and
a server nobody has configured grids the people who turned up. The **Race
Entry** bar shows how many that is.

That default is the one that fails safe. Under opt-in, an admin who has not
realised the setting exists presses Generate Grid and forms a grid of *nobody* —
every driver on the server left standing while the one person who could fix it
works out that a button they have never needed was the problem. Under
**Everyone races**, the mistake is that somebody who wanted to watch is put on
the grid, and they undo it with one press.

An admin can flip the mode to **Opt-in entry** when the field needs to be a
subset of who is connected — a league night on a public server, say. Then being
connected is **not** being entered: every player gets a **Join Race** button and
only drivers who pressed it are gridded, withdrawing (**Leave Race**) gives up
the slot, and entry closes once the countdown starts. Entry survives a **Start
Quali**, so drivers only ever have to join once per event (**Reset** stands the
whole field down and everyone joins again).

The two modes are two answers to "who is in the field" and nothing more —
from there they run identical code. A field of drivers who all pressed **Join
Race** grids exactly the same way, slot for slot, as flipping to **Everyone
races**.

### Step 5 — Qualifying

Press **Start Quali**, then **Start Countdown**. Start Quali forms a
qualifying grid exactly the way Generate Grid forms a race one — every
entrant is stood on a start position and held — and the countdown releases
the field.

**The out lap.** The field starts from a standing grid, so the first lap is
the lap you spent getting off the line. It is given away: **not timed, not
scored, and not counted against the lap allowance.** Your clock starts as you
cross the line for the first time, and **three qualifying laps still means
three timed laps** — four trips past the line in total.

This is not the out-lap the mod used to have. That one existed because
qualifying began wherever each driver happened to be parked, so the first
crossing arrived at a different point of the circuit for everybody and a
"3 lap" session took five or six laps to finish. This one starts on the grid
with everyone else's and is counted *separately* from the allowance, so
nothing is taken out of a driver's session — only the standing start is
excluded from the timing.

Drivers are told, rather than left to work it out from a lap time that never
appears:

- chat announces it at **GO**, and again to each driver as they complete it
  (`Out lap complete — your next lap is TIMED`);
- the driver's own lap readout shows `OUT LAP — NOT TIMED` in place of the
  running clock, then `OUT LAP DONE — TIMING` as they cross the line;
- the timing table shows `OUT LAP` in the Best Lap column for every driver
  still on theirs, and an **OUT LAP RULE** badge sits in the header for the
  session;
- the results file records `out lap not timed` in the qualifying format line,
  so a lap count read months later still adds up.

**A point-to-point stage has no out lap.** A sprint is driven once, first gate
to last — a lap given away there is the whole session given away, and there is
no line to come back past to start a timed one.

The out lap is also never the crossing that *ends* a driver's session. If the
qualifying clock expires while you are still on it (see the final lap below),
you complete it, start your flying lap, and take the flag on that — the same
one timed lap everybody else on track gets.

Each full lap through all gates posts to the server — the table shows
everyone's **Best Lap**, laps run and live provisional grid order, fastest on
top. Only your best counts. A driver who uses their lap allowance is taken
off the track until the session ends, then gets their car back with everyone
else. **End Session** closes qualifying early but keeps the times.

Two qualifying options sit in the admin settings:

| Setting | What it does |
|---------|--------------|
| **Ghost quali** | Rival cars stop being obstacles for the session, so a flying lap can't be ruined by traffic. Ghosted cars are faded so you can see who they are. |
| **Quali length** | Whether the session is run to a **lap allowance** or to a **clock** — pick one, and only that box is shown. |

**A qualifying session runs to laps or to a clock, not both.** The **Quali
length** row is a choice between the two:

- **Laps** — the number of **timed** laps each driver gets. The out lap is not
  one of them, so `3` gives an out lap and then 3 flying laps. A driver's
  session ends when they use them up; the session closes once nobody has laps
  left.
- **Timed** — minutes of wall clock. The header shows the countdown; when it
  expires the session runs a **final lap** (below) rather than stopping dead.

Whichever you pick, `0` means unlimited, and switching between them switches the
other off — so the two can never be armed together by accident. Both are locked
while qualifying is actually running, so nobody has the rug pulled mid-lap.

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
question of who was first. (The one exception is the out lap, which is never
terminal: a driver still on theirs at expiry would otherwise be stood down
with no time at all, eliminated by the one lap the session had already
promised not to score.) And a driver who never comes round (parked, in the
pits, never left the grid) is bounded by a **3 minute grace**, after which
the stragglers are taken where they stand and the session closes normally.

### Step 6 — Grid and race

1. Set the race distance in the **Laps** field. It applies as you type — there
   is no Set button (see [Settings apply
   themselves](#settings-apply-themselves)) — and the value in force is shown
   beside the box, and to everyone else, as `race: N`.
2. Choose the **Grid order**:
   - **Quali** — fastest-first from quali bests; drivers without a time go to
     the back (the default, and with no qualifying at all it falls back to
     join order).
   - **Reverse** — a reverse grid: **slowest qualifier on pole, fastest at the
     back**, so the quick drivers have to come through the field. It inverts
     the *times* and nothing else — a driver who set no time still starts at
     the back, behind everyone who did. A literal reversal would put them on
     pole, and then the quickest way to start first is to sit in the pits and
     set nothing; a reverse grid is meant to reward the slow, not the absent.
     (Which also means the fastest qualifier lines up last of the drivers who
     actually ran.)
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
DNF   P4     Erin                   1:34.000   0         DNF - Disconnected (was P3)

 HALF-WAY LEADER: Alice  (led at lap 3 of 5)
 HARD CHARGER: Cara  (P3 -> P1, +2 places)
```

**A DNF records the place the driver was running in when they stopped**, beside
the reason — `(was P3)` above. Whatever ended their race, that is where they
were, and "was P2" and "was P11" are very different afternoons. Finishers are
still listed above every retirement: a driver who stopped on lap two did not
beat one who took the flag. A cup can pay points for that held position — see
[What a DNF is worth](#what-a-dnf-is-worth).

Half distance **rounds up** on an odd number of laps: a 5-lap race is decided at
lap 3, the same as a 6-lap one — that is the lap on which a driver has more of
the race behind them than ahead. A one-lap race has no half way and reports none.

A tie on places gained goes to the **higher finisher**. Drivers who did not
finish are not eligible — there is no finishing position to have gained to — and
if nobody gained a place the line is left out rather than given to whoever lost
the fewest.

**If a cup is running**, the file ends with the championship round this race
just banked — see [Cup points in the results file](#cup-points-in-the-results-file).

Housekeeping:

- **Reset** wipes the session back to Waiting with fresh driver records.
- **Clear Results Cache** deletes all saved result `.txt` files on the
  server (chat confirms how many were removed). It asks first: the button is
  replaced by *Delete every saved results file on the server?* with **Yes,
  clear them** and **Cancel**, the same two-press step **End Cup** is behind.
  Once a session is over that file is the only record a league has that the
  race happened, and there is no undo.

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

**Names are saved on the server.** Every name an admin sets is written to
`Resources/Server/RaceManager/roster.json` as a **saved driver** — an id, the
name, and the guest name that connection was using at the time. They live
through Start Quali, Generate Grid, a whole race, **Reset**, a second race after
that, and the server going down and coming back up.

The roster is also what cup points hang off, so a saved driver is an identity
for a whole season, not just an evening.

### Who is who: an admin decides

**Nothing is ever assigned automatically.** BeamMP gives every connection a
fresh random guest name — a different one each time the same person joins — so
a guest name identifies nobody. The server cannot tell a returning regular from
a stranger, and it does not try:

> Matching on a guest name would miss a returning driver almost every time, and
> on the occasion two people were ever issued the same one it would hand a
> stranger somebody else's name **and their championship points**. Losing points
> is recoverable; giving them to the wrong person quietly is not.

So after a restart or a reconnect, drivers arrive **unassigned** and an admin
puts them back. Two ways, both admin actions:

- **Set their display name again** (Admin tab). A name already in the roster is
  matched rather than duplicated, so typing "Ryder" reattaches that connection
  to the saved Ryder and everything on them. Matching ignores capitalisation.
- **Assign them from the Cup tab's Drivers panel**, which lists everyone
  connected beside a dropdown of saved drivers. This is the better route when
  you cannot remember the exact spelling, or when a driver has no name yet.

The Drivers panel also warns how many connections are **not yet identified**, so
a full grid does not quietly race an entire round as strangers.

### Placeholders

A driver who races without being assigned is not dropped — their points go to a
**placeholder** entry named after their guest name and marked as such. It is
somewhere to keep points, not a claim about who they are.

When you assign that connection to a real driver, **the placeholder's points
move with them** and the placeholder is retired. So an admin who only notices
halfway through the evening loses nothing by being late.

Placeholders left behind by drivers who never came back can be deleted with
**✕** in the Saved drivers list. That removes the driver and every cup point
they hold, and is only offered while nobody is connected to them.

### Unassigning

**Unassign** detaches a connection from a driver. The driver, and every point
on them, stays exactly where it is — it just stops being shown against that
connection. Clearing a display name does the same thing.

**Ending a cup does not clear the roster.** Names are not cup property.

> The account id BeamMP exposes for a *logged-in* player would let the server do
> all of this unaided. It is where this goes when the guest-accounts restriction
> lifts; until then, a person deciding is the only trustworthy anchor.

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
  dropped rather than passed on — and nothing reassigns it without an admin.
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
| `-1` | Unlimited — the default |
| `0` | No resets at all: the reset button does nothing |
| `N` | `N` resets; every press after that is blocked |

The field applies itself as you type (see [Settings apply
themselves](#settings-apply-themselves)), so an **empty** box means "still
typing" and is never sent — `-1` is how you ask for unlimited.

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

**The joker lap cannot be armed on a track that has no joker gates.** The rule
reclassifies anyone who did not complete the route exactly once, so with no route
that is every driver who finishes — disqualified for missing something that was
never there, and not told why until the results file is written. The toggle is
greyed out until gates are placed, the server refuses it if asked anyway, and
loading a track without a joker route switches it back off.

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

### Branching routes (two ways round one track)

A **lane** is another way round the same track. Its gates **replace** the main
route's at the slots you give them — a lane never adds a checkpoint — so every
lane has the same number of checkpoints, and **the whole field is scored
together**: one clock, one running order, one results table. Which way a driver
went is a record, never a place gained or lost.

Build lanes in the editor's **Lanes** tab. Each lane gate is placed against a
**slot**: "this is what CP 3 is, for this lane". Drivers are put on a lane by
their **grid slot**, tagged in the **Start Grid** tab — that is the only place a
direction is decided, and the server reads it as it hands the slot out, so a
driver can never pick their own.

**Gates score in both directions**, which is what makes shared corners work. A
checkpoint both lanes pass — a back stretch, a start/finish line — is crossed one
way by one lane and the other way by the other, and counts for both. This also
fixes something older: a driver who **missed a checkpoint** and turned round used
to have to drive through it, carry on past, turn round again and come back
through. Now the way back through counts. Where direction really is the only
thing separating two legs of a track — a hairpin, or a figure-8 crossover — mark
that gate **one-way**.

#### A head-on "suicide" oval

The field starts in two blocks facing opposite ways and races the same oval in
opposite directions.

1. **Main route, clockwise.** `CP 1` at turn 1, `CP 2` on the back stretch,
   `CP 3` at turn 2, and the **start/finish** line.
2. **Lanes → + Add Lane**, called *Counter-clockwise*.
3. With that lane selected, set **Next gate replaces** to `CP 1`, drive to
   **turn 2 facing anti-clockwise**, and place it. Then set it to `CP 3`, drive to
   **turn 1 facing anti-clockwise**, and place that.
4. Leave `CP 2` and the start/finish alone. Both lanes cross them, from opposite
   sides, and both are credited.
5. **Start Grid** — place the grid, then tag half the slots to the lane
   (**Slots 7 to 12 → Counter-clockwise → Set Lane**).

Both directions clear slot 1, then 2, then 3, then the line: same lap, same
count, directly comparable on the leaderboard the whole way round.

#### The out lap

A grid that is **not on the start/finish line** — which a head-on layout cannot
be, since two directions will not share one row of slots — gives its **first lap
away**, exactly as qualifying does. The run from the grid to the first crossing
is a fraction of a lap, and timed it would take fastest lap off every driver who
ever set an honest one. It is detected from the track and travels with the
layout, so there is nothing to remember on the night. During that lap the only
thing armed is the **line itself** — with the field spread round the circuit, CP 1
can be behind you at the lights.

A 10-lap race on such a track is **10 racing laps**; the out lap is added on top,
so the eleventh crossing is the one that ends it.

#### Building the grid

Placing slots one car at a time is the tedious part, so the **Start Grid** tab
does it in bulk.

**Generate N slots, W abreast, from** either your car or a **start position you
have already placed**. Pole is then a decision you make once, by standing on it —
everything behind it is arithmetic. Generating from a placed slot rebuilds the
grid from there and leaves every slot before it alone.

**Rows can be any width from single file to eight abreast.** Two is a road-race
grid and an oval's, three and four are short-track and dirt formats, and one is a
stage start. Each row is **centred on the anchor**, so an odd width puts a car on
the spot you stood and the rest either side, and an even width straddles it —
changing the width never walks the grid sideways off the track.

Once a grid has been generated, three **sliders** appear: how far apart the rows
sit, how much room each car has beside the next, and how many are abreast. Drag
them and the grid moves under you — no driving back to pole to try a different
shape. They only ever touch slots the generator laid out; anything placed by hand
is left where you put it, and moving or deleting a slot by hand hands the block
back so the sliders stop claiming it.

**Lane tags and headings survive a respace**, which is what makes the head-on
flow work: **Generate** the block, **Turn Around** the back half, **Set Lane** on
it, and *then* spread the grid out — the turned-around half stays turned around
and keeps its lane. That holds when the **width** changes too: the tags follow the
slot, not the row, so "slots 7 to 12 go the other way" stays true whether those
twelve cars are in six rows of two or four rows of three.

Every placed gate and grid slot also has **✕** (delete just this one),
**+ Before** (insert at your car) and **▲ ▼** (reorder). Editing the main route
renumbers the lanes with it; deleting a checkpoint drops the lane gates standing
in for it, and says so.

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

### Settings apply themselves

**Laps**, **Max resets** and the qualifying **Laps / Minutes** boxes have no Set
button. Type a number and it applies — half a second after you stop typing, or
immediately if you click away from the box. The value the server actually holds
is displayed beside each field, so what is in force is always readable.

A Set button earns its place when an edit is several fields that only make sense
applied together, which is why the **cup points tables keep theirs**. A single
number that is cheap to send and trivially changed again is not that, and
forgetting to press the button is a silent failure that turns up as the wrong
race distance.

Two consequences worth knowing:

- **An empty box is never sent.** It means "still typing", not zero and not
  unlimited — clearing `5` to type `12` must not spend the moment in between
  running an open session or an unlimited reset allowance. Type `-1` for
  unlimited resets, or `0` for an unlimited qualifying session.
- **Settings stay put for the whole event.** They live on the server, not in
  the app, and nothing but changing them again moves them: they survive Start
  Quali, Generate Grid, a countdown and **Reset**, and every admin's panel
  shows the same values because all of them are reading the server's. (They are
  *not* written to disk — restarting the server returns them to their
  defaults. Track layouts, the garage, the roster and the cup are the things
  that survive that.)

### What a checkpoint looks like

Two different drawings of the same checkpoint, for two different jobs:

- **In the editor** — the flat rectangle the crossing test actually uses, with
  its number and a direction arrow, drawn for the whole route at once so a
  layout can be checked. White is the start/finish line, orange the rest of the
  route, green your next target, violet the joker, amber a pit stall.
- **On track during a session** — BeamNG's own **gate poles**, two columns
  either side of the racing line, on the gate you are heading for and the one
  after it. Only those two: a whole circuit wearing poles is a wall of gates.

Both are as bright as their colour allows. The poles take BeamNG's palette and
lift each colour to the luminous version of itself — the hue is the engine's,
and the meanings a BeamNG driver already knows still hold, but a marker that was
a dark silhouette against a pale road or a low sun is now plainly a marker. The
one pole that is not merely brightened is **the gate after the one you are on**:
the engine ships that mode black, because in its own races it is not your
concern yet. This mod puts a marker there specifically so the line through the
corner reads before you arrive, so it is painted the orange of the route ahead
instead — visible, and a shade under the gate actually being aimed at.

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

## Cup points

A **cup** is a championship run across several events. It can be **all races,
all derbies, or a mixture of both** — points accumulate per driver and nothing
but ending the cup clears them.

It is **off by default and entirely optional** — with no cup running, races
behave exactly as they do without the feature. Everything below lives on the
**Cup** tab under Race mode.

### Running a cup

1. Give every driver a **display name** first (Admin tab). Points attach to the
   saved driver, not to a connection — see [Display names](#display-names).
2. **After any reconnect or server restart, assign them again.** BeamMP reissues
   guest names at random, so nobody is recognised automatically and the Cup
   tab's **Drivers** panel warns you how many are unidentified. A driver who
   races unassigned still scores, into a placeholder; assigning them afterwards
   moves those points onto them, so being late costs nothing.
3. Press **Start New Cup**, optionally naming it.
4. Run races and derbies as normal. Each finished event banks a **round**.
5. Watch the standings on the same tab.
6. **End Cup** deletes every point in it. It asks twice, because nothing else
   in the app throws away a season.

**Pause without losing anything** with the Scoring toggle: a race finished while
it is off scores nothing, and the standings are untouched.

### Scoring

Points come off the **finishing position**. A driver who did not finish — DNF or
disqualified — scores nothing rather than being paid for last place.

Five presets ship. Loading one **fills** the table so you can then edit it; a
preset is a starting point, not a mode.

| Preset | P1 | P2 | P3 | P4 | P5 | … | Pays down to |
|---|---|---|---|---|---|---|---|
| 30P Aggressive | 30 | 27 | 25 | 23 | 20 | … | P24 |
| 25P Aggressive | 25 | 18 | 15 | 12 | 10 | … | P10 |
| 25P Moderate | 25 | 20 | 16 | 11 | 10 | … | P14 |
| 24P Linear | 24 | 23 | 22 | 21 | 20 | … | P24 |
| 35P Folk Race | 35 | 30 | 25 | 20 | 18 | … | P21 |

A position past the last non-zero entry scores **nothing**, which is what makes
a short table legal: 25P Aggressive simply pays no-one from P11 back.

### What a DNF is worth

**A retirement is not always a nil score.** A driver taken out of second place
has not had the same afternoon as one who never turned up, and which of those a
series pays for is a league decision — so it is a setting.

The place a driver was **running in when they stopped** is recorded whatever
ended their race — a disconnection, the admin closing the session, anything
added later. It appears in the results file beside the reason (`DNF -
Disconnected (was P2)`), and three rules decide what it is worth:

| Setting | A DNF scores |
|---|---|
| **Nothing** (default) | 0, as it always did |
| **Classified place** | its place in the final order, below everyone who finished |
| **Place when they stopped** | the position it was actually running in |

**Place when they stopped** can pay two drivers for the same position — a
retirement from second and a finish in second both score second. That is exactly
what the option is for; pick one of the other two if it isn't what you want.

A DNF is **never counted as a win**, however it is scored, and a
**disqualification always scores nothing** — that is what the penalty is.

### Qualifying points

Off by default. Give the quali table some values and qualifying starts scoring,
ordered by **best lap** — not by grid slot, which at the end of a qualifying
session is only where each driver started it.

Qualifying points are **held, not banked immediately**: they belong to the race
that follows and are added to that round when it finishes. The panel shows how
many results are waiting. Run a qualifying session with no race after it and
they are simply superseded by the next one.

### Derby points

Derbies score on a **table of their own**, because a cup may be all races, all
derbies or a mixture, and lasting eight minutes in a banger is not the same
achievement as winning a ten-lap race. It uses the same five presets and starts
out matching the race table, so an all-derby cup scores sensibly the moment you
start it.

Position is **survival order**: the last driver running, then whoever lasted
longest, and so on. The one place derby scoring genuinely differs from a race:

> **Everybody scores.** In a race, a driver who did not finish scores nothing —
> not finishing is a failure to produce a result. In a derby, being eliminated
> *is* the result, and the position it produces is worth points.

**Turn derby points off** and derbies are simply not part of the cup: no round
is banked and no derby bonus is paid. Races go on scoring normally.

**Winning is not the same as finishing first.** A derby an admin ends early is
topped by whoever was still running, but nobody was the last one standing — so
that driver takes P1 points without it counting as a win, and without the
last-man-standing bonus.

### Bonus points

Bonuses belong to a **discipline**: race bonuses are only ever paid on a race
and derby bonuses only on a derby, so a derby can never collect a fastest-lap
bonus. Each is worth whatever you set it to and **worth nothing at zero**.

**Races:**

- **Fastest Lap** — the quickest lap of the race.
- **Halfway Led** — first to complete the half-distance lap. A one-lap race has
  no half way and awards none.
- **Hard Charger** — the classified finisher who gained the most places from
  their grid slot.

These are the same three the results file already reports; the cup consumes that
answer rather than working it out a second time.

**Fastest lap rule** — by default the fastest lap bonus is withheld from a driver
who did not finish. Switch it to *Any driver* if you would rather not.

**Derbies:**

- **Last Man Standing** — awarded only when somebody actually survived. A derby
  ended early by an admin has no winner and pays none.

Bonuses are defined as data on the server and the panel builds itself from that
list, so more can be added later without redesigning anything.

### What points survive

Everything except ending the cup:

| | Points kept? |
|---|---|
| Start Qualifying | ✅ |
| Generate Grid | ✅ |
| A countdown / phase change | ✅ |
| **Reset** (session reset) | ✅ |
| Server restart | ✅ |
| **End Cup** | ❌ — this is the only thing that clears them |

Cup state lives in `Resources/Server/RaceManager/cup.json`, written on every
change. It is deliberately **not** in the `results/` folder, because
[Clear Results Cache](#step-7--results) deletes everything there.

### Standings

**Race and derby are kept separate, and summarised together.** The default
**Combined** table shows events scored, wins, race points, derby points, manual
adjustments and the grand total — so a total can always be accounted for.

Once a cup has held **both** kinds of event, two more tabs appear:

- **Races** — races scored, race wins, position points, qualifying points and
  race bonuses, ranked on the race total alone.
- **Derbies** — derbies scored, derbies won outright, survival points and derby
  bonuses, ranked on the derby total alone.

A mixed cup therefore contains a race championship and a derby championship as
well as an overall one, and you can read any of the three. A cup that only ever
held one kind shows just the combined table, without an empty column for the
discipline it never ran.

### Cup points in the results file

When a cup is running, every results file ends with the round that event
banked — so the standings leave the game with the result, instead of being
retyped off a screenshot by whoever compiles them. **Derby results files carry
the same section**, in the same layout: a league reading two files from one
evening should not have to learn two formats, or find the championship in only
one of them.

```
--- CUP: Winter Series (round 4) ---
 Scoring: 30P Aggressive to P24, qualifying to P3 | DNF: none
Pos   Driver                 Race   Quali  Bonus  Round   Total
P1    Ryder                  25     0      0      25      110
P2    Phoenix                27     0      0      27      108
P3    Falcon                 30     0      8      38      91
P4    Nomad                  23     0      0      23      77

 BONUSES THIS ROUND
 Fastest Lap: Falcon (+5)
 Hard Charger: Falcon (+3)
```

- **Pos** is the championship position *after* this round, not the finishing
  position — the table is the standings, with what each driver scored today
  broken out beside their total.
- **Race / Quali / Bonus** are the parts of this round's score; **Round** is
  their sum. A driver who was not in this round shows `-` in all four rather
  than `0`: not scoring and not being there are different facts.
- Bonuses are **listed by name and recipient** underneath. A `+8` in a column
  does not say what it was for, which is the question somebody checking a
  championship a month later actually has.
- Manual adjustments, if any, are listed the same way — a total nobody can take
  apart is a total nobody can check.
- The numbers come from the cup's own tables, so the file and the Cup panel can
  never disagree about a total.

A race night with no cup running produces exactly the results file it always
did; the section is simply absent. Qualifying does not get one either — its
points are [held, not banked](#qualifying-points), and they appear in the
**Quali** column of the race that banks them. Nor does an event that scored
nothing (a cup that is switched off, one at its round cap, or a derby in a cup
whose derby points are off): the file reports the round that was actually
banked, never "the round the cup is on".

Ties break on wins. Manual adjustments sit outside both disciplines — a penalty
applies to a driver's standing in the cup, not to one half of it.

Drivers who are not admins see a read-only copy between sessions. It is hidden
during a live session, where the leaderboard is what matters.

### Adjusting points by hand

Drivers disconnect, races get administered badly, penalties are agreed after the
fact. Press **±** on any standings row to open that driver's adjustment panel.

- Type a number and a reason, then **Apply**. A negative number takes points
  away.
- Or use the **quick buttons** (−1, −5, −10, +1, +5, +10) with the reason still
  in the box.
- Every adjustment is kept as its own **ledger entry** with its reason, who made
  it and when. The standings show earned points and adjustments as separate
  columns, so a total can always be accounted for.
- **✕** removes an adjustment outright rather than posting an opposite one: a
  mistake in the ledger is not an event that happened.

Adjustments are keyed to the driver's **cup entry**, not to their connection, so
they survive a reconnect and a server restart like everything else.

> **To fix a race that was scored wrongly**, drop that round and run it again
> rather than posting a compensating adjustment — the breakdown should describe
> what actually happened. The cup's round count is deliberately left alone;
> renumbering later rounds to close the gap would hide the correction.

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
