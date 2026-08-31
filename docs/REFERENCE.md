# Race Manager - full reference

Every feature in detail: the complete race-night walkthrough, league
regulations, the Demo Derby, and how live positions are worked out.
The [README](../README.md) has the short version.

[← Back to the README](../README.md)

## Track layouts (persistent, per-map)

The **Track Layouts** panel at the bottom of the editor stores named
checkpoint configurations **on the BeamMP server** in
`Resources/Server/RaceManager/layouts.json`, so they survive server restarts
and can be prepped days before an event:

- **Save As New** bundles the currently placed gates (positions, headings,
  gate dimensions) - including the **joker route**, the **pit lane**, the
  **branch gates** and the **starting grid**, if any are placed - under a typed
  name,
  tagged with the level the server is hosting. A name that is already taken
  asks first.
- **Overwrite** and **Delete** act on the layout selected in the **Track**
  picker, so putting an edited track back needs no retyping. Both ask before
  they act.
- A save can never quietly empty part of a stored layout. If the client sending
  it is not holding a section the saved copy has - its joker route, pit lane,
  grid or branch gates - the server **refuses the save** and reports exactly what
  would have gone. The admin can still go ahead, but has to say so. This is
  what stops a load, an edit and a save coming back as a bare route.
- The dropdown is **strictly filtered by map** - the server only lists
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
qualifying **out lap** - the first lap of a qualifying session is not timed,
because it starts from a standing grid (see [Step 5](#step-5--qualifying)).

### Step 1 - Open the app

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

You never have to log in just to watch: close the login bar with **✕** and the
live timing is already there.

**Retiring** is how you leave a session you are already in. **⚑ Retire** in the
Race Entry row asks first, then treats it exactly like taking the flag: the car
is ghosted where it stands and you go to spectate in it. It is a **classified** retirement,
not a disappearance. You hold a position, you are in the results file, and you
score cup points like any other DNF.

Where you place is **behind every car that can still finish**. Retiring from
second of a running field does not keep second, because everyone still going
will come past. Retire later and fewer cars are left to pass you, so you
classify higher, which is how motorsport has always ordered retirements. The
place you were *running* in is kept separately: the results line prints it as
`was P2`, and a cup set to pay retirements at their **held** position uses that
rather than where they finally classified.

**Sitting a session out** is a different thing, and it has its own control.
**👁 Spectate** in the Race Entry row takes you out of the field even under
*everyone races*, which otherwise has no opt-out short of leaving the server.
Your car stays exactly where it is and becomes a ghost, so nothing is deleted
and nothing is respawned, and you watch however you like: BeamNG's own controls
tab between cars and free camera works as it always does. **↩ Rejoin the field** puts you back. Neither direction is available while a
session is running: sitting out decides whether you are in the field, and the
field is decided when the grid forms. Leaving a race you are already in is
retiring, above.

> The server ships with a **default password of `phoenix`** (set at the top of
> `server/RaceManager/main.lua`). **Change it before your first public
> session:** log in, then use the **Change password** bar to set a new one - it
> takes effect on the server immediately.

### Step 2 - Build a track

Press **Editor** in the header to open the checkpoint editor, then drive the
course you want to race:

1. At each place you want a timing gate, drive through it **in the direction
   of travel** and press **+ Checkpoint Here**. A gate is a **flat rectangle**
   standing perpendicular to your heading - cars must pass through it.
2. **The last gate you place is the start/finish line** (drawn white in the
   world; earlier gates are orange, and your next target turns green during
   a session).
3. Every gate has a **width** (how far it reaches across) and two independent
   vertical extents: **up**, how far it rises above the point it was placed at,
   and **down**, how far it drops below. **Each gate owns its own.** The first
   gate of a new route gets the standard size; every gate after it inherits the
   size of the one placed before, so you set it once and drive the rest of the
   route. Click any placed gate to change it - **nothing else moves**. Raise
   **up** on **high-banked tracks** so the rectangle covers the banking; what you
   see drawn in the world *is* the trigger, so you can verify it at a glance.

   > **Why the vertical is two numbers.** It used to be one, centerd on the
   > placement point, so half of every gate hung below the road. Making a gate
   > tall enough to see from a distance buried an equal amount of it under the
   > map, and there was no way to have one without the other. Splitting them
   > costs nothing and fixes both. The default is weighted upward for the same
   > reason: 8 meters up, 2 down, the same 10 meters of gate in a more useful
   > place.
   >
   > A layout saved before the split carries one height that meant the full
   > span, and is converted as it loads: half up, half down. The gate keeps
   > exactly the shape it always had, and the next save writes it in the new
   > form.

   > There used to be a global width/height that every gate without an override
   > read live. Nudging that slider resized the entire circuit at once,
   > retroactively, with no way back - so it is gone. Layouts saved under it are
   > unaffected: each gate is given the size it was drawn with as the layout
   > loads.
4. Every placed gate has **Go** (stand your car on it, facing the way through)
   and **Move Here** (move the gate to where your car is standing) - the same
   pair the starting grid has. A gate keeps its Width/Height override when it
   moves. Both work on the joker route and pit stalls too.
5. **Undo** removes the last gate, **Clear** wipes the route,
   **Hide/Show Gates** toggles the in-world drawing.
6. **Nudge** is the mouse pass. Turn it on and the cursor is released from the
   camera: click a gate to pick it, drag to move it along the ground, scroll to
   turn it, **ctrl+click** open ground to place a new one. It works on whichever
   editor tab you are on, so checkpoints, joker gates, pit stalls, branch gates
   and start positions are all movable.

   **Dragging is horizontal only.** A gate keeps whatever height it has while
   you slide it around, including over trees and buildings, and the only thing
   that can change that is being dragged into rising ground, which lifts it
   clear rather than burying it.

   **Shift+scroll raises and lowers** the selected gate, and **▲ Up** / **▼ Down**
   do the same in bigger steps for a mouse with no wheel. This is the only control
   that moves a gate vertically: the **Gate size** sliders set how far it extends
   *up and down from where it sits*, which is a different thing, so a gate that
   ended up in the terrain could not be recovered with them. It will not let you
   push a gate below the ground under it.

   A placed gate faces the way the route is already traveling, from the previous
   gate toward the point you clicked, so clicking along a road in order gives you
   gates that face the way the road goes. The first gate on an empty route has no
   previous one and faces where the camera looks, which the scroll wheel fixes.

   With a gate picked, a placement goes in **after** it rather than at the end,
   which is how a gap noticed halfway round gets filled. **Delete picked** removes
   the selected gate.

   Turning it off leaves the cursor free unless the mode is certain it took the
   mouse from the camera in the first place. BeamNG offers no way to ask what the
   cursor was doing, and guessing wrong in the other direction leaves an admin
   unable to click anything at all, including the button that would give the
   cursor back. Use your normal camera key to return the mouse to the view.

   Driving to a spot and pressing the button is still how a track gets built: it
   puts a gate where a car actually fits, facing the way one actually travels.
   Nudge is for the pass afterwards, where a gate is ten meters late or a few
   degrees off and re-driving the corner is the expensive part.
6. There is no local scratch copy. Tracks live on the server, where everyone
   races on the same one - save as you go with **Overwrite**.

#### Circuit or point to point

The **Main Route** row carries a toggle: **⟳ Circuit** or **⇥ Point to Point**.

- **Circuit** - the last gate is a start/finish line, and the race runs for the
  lap count.
- **Point to Point** - the stage is driven once, first gate to last, and the
  last gate is the finish. The gates relabel themselves (`1 START` … `N FINISH`),
  the header shows a **POINT TO POINT** badge, and the Laps field is disabled
  because laps do not apply.

Setting a circuit to one lap times the same thing, which is why that worked as a
workaround - but it reads as a one-lap circuit everywhere it is shown, and the
lap count becomes a setting an admin has to remember. The toggle is **saved with
the layout**, so a sprint stage stays a sprint stage.

Your lap setting is kept rather than overwritten, so switching a circuit layout
back in restores it. The mode is locked once a countdown or race starts.

#### Flags

An admin can show the field a **caution** at any point during a race or a
qualifying session, and go back to **green** when it is clear. Both are
announced in chat and pushed to every driver's panel as a notice, because the
panel is not where a driver is looking when a caution is called. A yellow lamp
pulses in the header for as long as it lasts; a red one shows while the field is
locked on the grid.

**The flag is advisory. It polices nothing.** Nobody is penalised for an
overtake under yellow and the running order is not frozen. Deciding that
automatically means holding a second running order that survives the caution and
reconciles on green, and a marshal who can see the incident is better at that
than a distance comparison. The flag tells the field what is happening; you
decide what it means.

Every session starts green: a caution belongs to the session it was called in
and is never carried into the next one.

#### Pit stalls

Switch the editor to the **Pit Stalls** tab, drive into each stall and press
**+ Place Pit Stall Here**. Stalls are drawn amber and labeled `PIT 1`, `PIT 2`.

**The box is drawn, because the box is the rule.** A stall is not a gate you
cross, it is a volume you occupy: the gate's width across, three meters either
way along it, measured on the stall's own axes so an angled stall still reads
correctly. On track it appears as a translucent amber floor with low side walls
and a corner post at each corner, open front and back because a stall is driven
into and out of. The walls are deliberately short: the height part of the test
excludes nobody, so drawing it full height would imply a constraint that is not
doing any work, while the footprint, which is what decides, is drawn exactly.

**You have to stop in the box yourself.** Driving into a stall is not enough
the car has to actually come to a stop inside it. While you are in the box and
still rolling the panel says *"come to a stop inside the box"*; the moment you
stop, the stop begins: the car is **held for 5 seconds, repaired in place, and
released**. The repair lands part-way through, so the car is whole before the
driver gets it back, and the same stall will not trigger again for 8 seconds.

Run through a stall without stopping and you simply **miss it**. Nothing is
seized, nothing is spent - no cooldown is started, so the stall is live again on
the very next visit and you can come round. Making the box alone the trigger is
what used to make a pit stop something that *happened to* a driver: clip a
corner of a stall at racing speed and the car was frozen where it stood,
mid-lane, at whatever angle it was traveling.

**A car serving a stop is ghosted.** It is frozen, so it cannot move out of the
way, and it is parked in the one part of the track everybody else arrives at
slowly and off-line. The ghost lasts exactly as long as the stop and is lifted
with the car. It rides the server's **reset-ghosting** switch: with that off,
nothing is ghosted here either - ghosting is applied per vehicle by each client
separately, so a car ghosted for its own driver and solid for everybody else is
worse than one that was never ghosted at all.

**A stall is an area, not a checkpoint.** They are kept out of the checkpoint
list entirely, so they can never affect laps, splits or the running order - you
can place them wherever a pit lane belongs without touching the race. A pit stop
is not a driver reset either: it spends no reset allowance and is never reported
as one. Every stop is logged server-side with the driver, the stall and the lap.

They are **not** respawn points. A stall repairs a car where it stands and does
nothing else - a later reset still goes wherever the reset ruleset says.

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

### Step 3 - Save it as a layout (so it survives the night)

Scratch saves are local to you; **Track Layouts** (bottom of the editor
panel) live on the server and persist across server restarts:

1. Type a name in the **Layout name** field and press **Save Current
   Layout**. The server stores it tagged with the map it is hosting and
   announces it in chat.
2. To race a prepped track later, pick it from the dropdown - the list only
   ever shows layouts saved **for the current map** - and check the 2D
   preview: gate dots, the connecting track shape, and the start/finish line
   in green.
3. Press **Load Layout**. Every connected player's gates rebuild instantly;
   nobody has to load anything manually. (Loading is locked while a
   countdown or race is running.)

### Step 4 - Who is actually in the race

**Everyone races.** Every connected player is in the field, so a server nobody
has configured grids the people who turned up. The **Race Entry** bar shows how
many that is.

A driver who does not want to race presses **Spectate** and the session runs
without them. Their car stays exactly where it is and becomes a ghost: nothing
is deleted and nothing is respawned. **Rejoin the field** puts them back. That
one control is the whole entry system, and it belongs to the driver rather than
to an admin.

It covers the case an admin-set opt-in mode used to: a one on one is two drivers
racing and everybody else pressing **Spectate**, with no mode to set first.

**Spectate is settled before the lights.** Once a session is running, the field
is fixed and the button disables. The way out of a race you are already in is
**Retire**, which is a different thing with a different result - a classified
retirement that keeps a position and scores like any other DNF, rather than
never having entered. Sitting out *between* sessions survives a reconnect;
**Reset** puts the whole field back in.

This replaced three overlapping answers to "am I in this race": an admin-set
entry mode, a per-driver **Join Race**, and spectating. They could disagree, and
the failure that made the case for cutting them down to one was a driver who sat
out and then had no way back in.

### Step 5 - Qualifying

Press **Start Quali**, then **Start Countdown**. Start Quali forms a
qualifying grid exactly the way Generate Grid forms a race one - every
entrant is stood on a start position and held - and the countdown releases
the field.

**The out lap.** The field starts from a standing grid, so the first lap is
the lap you spent getting off the line. It is given away: **not timed, not
scored, and not counted against the lap allowance.** Your clock starts as you
cross the line for the first time, and **three qualifying laps still means
three timed laps** - four trips past the line in total.

This is not the out-lap the mod used to have. That one existed because
qualifying began wherever each driver happened to be parked, so the first
crossing arrived at a different point of the circuit for everybody and a
"3 lap" session took five or six laps to finish. This one starts on the grid
with everyone else's and is counted *separately* from the allowance, so
nothing is taken out of a driver's session - only the standing start is
excluded from the timing.

Drivers are told, rather than left to work it out from a lap time that never
appears:

- chat announces it at **GO**, and again to each driver as they complete it
  (`Out lap complete - your next lap is TIMED`);
- the driver's own lap readout shows `OUT LAP - NOT TIMED` in place of the
  running clock, then `OUT LAP DONE - TIMING` as they cross the line;
- the timing table shows `OUT LAP` in the Best Lap column for every driver
  still on theirs, and an **OUT LAP RULE** badge sits in the header for the
  session;
- the results file records `out lap not timed` in the qualifying format line,
  so a lap count read months later still adds up.

**A point-to-point stage has no out lap.** A sprint is driven once, first gate
to last - a lap given away there is the whole session given away, and there is
no line to come back past to start a timed one.

The out lap is also never the crossing that *ends* a driver's session. If the
qualifying clock expires while you are still on it (see the final lap below),
you complete it, start your flying lap, and take the flag on that - the same
one timed lap everybody else on track gets.

Each full lap through all gates posts to the server - the table shows
everyone's **Best Lap**, laps run and live provisional grid order, fastest on
top. Only your best counts. A driver who uses their lap allowance is taken
off the track until the session ends, then gets their car back with everyone
else. **End Session** closes qualifying early but keeps the times.

Two qualifying options sit in the admin settings:

| Setting | What it does |
|---------|--------------|
| **Ghost quali** | Rival cars stop being obstacles for the session, so a flying lap can't be ruined by traffic. Ghosted cars are faded so you can see who they are. |
| **Quali length** | Whether the session is run to a **lap allowance** or to a **clock** - pick one, and only that box is shown. |

**A qualifying session runs to laps or to a clock, not both.** The **Quali
length** row is a choice between the two:

- **Laps** - the number of **timed** laps each driver gets. The out lap is not
  one of them, so `3` gives an out lap and then 3 flying laps. A driver's
  session ends when they use them up; the session closes once nobody has laps
  left.
- **Timed** - minutes of wall clock. The header shows the countdown; when it
  expires the session runs a **final lap** (below) rather than stopping dead.

Whichever you pick, `0` means unlimited, and switching between them switches the
other off - so the two can never be armed together by accident. Both are locked
while qualifying is actually running, so nobody has the rug pulled mid-lap.

**The final lap.** When a timed session's clock expires it does not end the
session - everyone still out is mid-lap, and in qualifying that is the lap
that matters. Instead:

- chat and the header announce **FINAL LAP**; the clock is replaced by that
  badge;
- every driver stays controllable and on track;
- each driver's session ends **as they cross the start/finish line** - their
  car is ghosted in place exactly as it is when a lap allowance runs out;
- when the last one is home, everybody's collisions come back together.

That last lap still **counts**: a time set on it goes into your Best Lap and
can move you up the order. The grid is not frozen at expiry, it settles when
the last driver has taken the flag.

Two rules keep it from hanging. A crossing the server sees *after* expiry is
terminal - there is no extra lap for whoever was closest to the line, and
arrival order at the server decides it, the same way it decides every other
question of who was first. (The one exception is the out lap, which is never
terminal: a driver still on theirs at expiry would otherwise be stood down
with no time at all, eliminated by the one lap the session had already
promised not to score.) And a driver who never comes round (parked, in the
pits, never left the grid) is bounded by a **3 minute grace**, after which
the stragglers are taken where they stand and the session closes normally.

### Step 6 - Grid and race

1. Set the **Race length**. A race runs to a **lap count** or to a **clock**,
   never both - one toggle, and picking one sends the other as zero, so they
   cannot both be armed by accident. It applies as you type; there is no Set
   button (see [Settings apply themselves](#settings-apply-themselves)), and the
   value in force is shown beside the box and to everyone else.

   - **Laps** - a fixed distance. The race ends as the last car completes them.
   - **Timed** - minutes, run as **"10 minutes + 1 lap"** (below). The lap count
     is inert while this is set; it is remembered, not used.
   - **Endurance** - **both**, whichever comes first: the distance, or the clock
     plus one lap. Both boxes are shown, because both are live.

   #### Endurance

   Set a distance *and* a clock. Whichever arrives first ends the race:

   - **The distance first** - the flag falls on the car that completes it, and
     everyone still out is classified as they come past. A car a lap down is not
     made to keep circulating after the race has been won.
   - **The clock first** - the "+1 lap" ending below, with the lap target still
     armed underneath it. A 50-lap-or-60-minute race that runs out of time at
     lap 31 ends on lap 32.

   The flag-falls-on-the-winner rule is **endurance only**. A plain **Laps** race
   is unchanged: every driver runs the full distance, and a lapped car goes on
   circulating until it has. That is long-standing behavior a league's results
   are built on, and changing it is a decision about how races are scored rather
   than a detail of this mode.

   #### Timed races: "10 minutes + 1 lap"

   **The clock running out ends nothing.** That is the whole format. A driver
   watching it reach zero still has **two** laps to run: the one they are on,
   and the last one.

   | State | Header | What it means |
   |---|---|---|
   | Clock running | `4:12` | Time **remaining** - the race clock counts down in a timed or endurance race, and is tinted while it does. |
   | Expired | `+1 LAP` | Time is up. The final lap starts when **the leader** next takes the line. Nothing is terminal yet. |
   | Leader past | `FINAL LAP` | The lap everyone still running finishes on. |
   | Winner home | `FLAG OUT` | The checkered flag. Your next crossing is your last. |

   **Everyone still running gets the whole final lap**, not "your next
   crossing". A car two seconds behind the leader has not reached the line when
   the leader starts the last lap; flagging it off there would end its race a lap
   early while the leader ran a full one.

   **A lapped car is classified where it got to.** It will never reach the final
   lap number, so once the winner is home its next crossing is its last - which
   is what a real checkered flag does to a car a lap down.

   **The leader is the car that reaches a lap number first**, not the first car
   past the line after expiry. Those differ exactly when a lapped car comes
   round, and using the second rule would hand the final lap to a backmarker.

   If **no** lead-lap crossing arrives within the 3 minute grace - the leader
   retired, the field is stopped - the flag goes out anyway and everyone still
   out is classified as they come past. The race cannot hang waiting on a
   crossing that is never coming.
2. Choose the **Grid order**:
   - **Quali** - fastest-first from quali bests; drivers without a time go to
     the back (the default, and with no qualifying at all it falls back to
     join order).
   - **Reverse** - a reverse grid: **slowest qualifier on pole, fastest at the
     back**, so the quick drivers have to come through the field. It inverts
     the *times* and nothing else - a driver who set no time still starts at
     the back, behind everyone who did. A literal reversal would put them on
     pole, and then the quickest way to start first is to sit in the pits and
     set nothing; a reverse grid is meant to reward the slow, not the absent.
     (Which also means the fastest qualifier lines up last of the drivers who
     actually ran.)
   - **Random** - a random draw, for a race with no qualifying behind it.
   - **Custom** - type a slot number next to any driver in the **Start**
     column and press Enter. Pinning a slot someone else holds takes it off
     them rather than doubling up; unpinned drivers fall in behind by quali
     time.
3. Press **Generate Grid**. Every entered driver is **placed on their start
   position and held there** - you cannot move until the countdown finishes,
   so nobody jumps the start. The header shows your slot and a `HOLD` tag.
   If there are more drivers than placed start positions, chat warns you.
   Cars are ghosted while the field forms up and land one after another
   rather than all at once, so a full grid cannot refuse a placement for an
   occupied slot or arrive interpenetrated and blow itself apart; collisions
   come back once everyone is standing still on their slot.
4. Press **Start Countdown**: everyone gets a synchronized 3‑2‑1‑**GO!**
   shown as **start lights**. Three lamps go amber one at a time as the count
   falls, then all three snap green together on GO, which is what a short-track
   start actually looks like. The number stays under the lamps, because it is
   the part that reads at a glance on a narrow panel.
   overlay, every car is released by that same broadcast, and the race clock
   starts.

   The hold is **enforced, not just requested** - see
   [Holding the grid](#holding-the-grid) for what that means and what gets
   logged.

   **Or press Start Race**, if the [pace lap](#pace-lap) is armed. There is no
   countdown: the field is released under yellow and forms up for a lap, and the
   green falls as the leader comes back to the line. The two buttons are
   alternatives and only one is ever on screen -- counting a field down to GO and
   then telling it to hold position at 40 mph is two instructions for the same
   moment, and a driver obeys whichever they read.
5. Race. The table now shows **Pos** (live position), the starting grid slot,
   current lap, best race lap and **Led** (laps led), and it re-sorts itself
   leader-first in real time as places change (see *Live position tracking*
   below). Finish order is decided by the server's single clock, so it's fair
   for every client.
6. The race ends when everyone has finished (or you press **End Session**,
   which DNFs anyone still out). Disconnecting mid-race is an automatic DNF.
   At the flag **every** participant gets their car back - ghosted and
   staggered, the same as a grid forming - and each driver's camera is put
   explicitly back on their *own* car rather than on whichever vehicle the
   game happens to pick.

### Step 7 - Results

When the race closes, the server automatically writes a results file
(qualifying classification + race classification, pole and winner tagged) to
`Resources/Server/RaceManager/results/` and announces the path in chat
ready for league standings or a broadcast overlay.

The race table records **Pos, Start, Driver, Best Lap, Laps Led, Finish** (plus
Joker and Resets columns when those regulations are armed). `Start` is the grid
slot the driver lined up on, which is what makes a finishing position readable
P2 means something very different from eighth on the grid than it does from pole.

Underneath it, two awards:

- **Half-way leader** - whoever completed the half-distance lap first.
- **Hard Charger** - the classified finisher who gained the most places between
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
the reason - `(was P3)` above. Whatever ended their race, that is where they
were, and "was P2" and "was P11" are very different afternoons. Finishers are
still listed above every retirement: a driver who stopped on lap two did not
beat one who took the flag. A cup can pay points for that held position - see
[What a DNF is worth](#what-a-dnf-is-worth).

Half distance **rounds up** on an odd number of laps: a 5-lap race is decided at
lap 3, the same as a 6-lap one - that is the lap on which a driver has more of
the race behind them than ahead. A one-lap race has no half way and reports none.

A tie on places gained goes to the **higher finisher**. Drivers who did not
finish are not eligible - there is no finishing position to have gained to - and
if nobody gained a place the line is left out rather than given to whoever lost
the fewest.

**If a cup is running**, the file ends with the championship round this race
just banked - see [Cup points in the results file](#cup-points-in-the-results-file).

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

1. **Laps completed** - more laps is ahead. This comes from the server's own
   lap counter (`RM_Lap`), never from client telemetry, so a client cannot
   invent a lap.
2. **Checkpoints cleared** - on the current lap, more gates passed is ahead.
3. **Distance to the next checkpoint** - straight-line meters from the car to
   the center of the gate it is driving towards. Shortest is ahead.

Metrics 2 and 3 can only be measured where the physics live, so each client
computes its distance to the next gate every frame and reports
`{ lap, checkpoints, distance }` to the server roughly **3 times a second**
(and immediately after clearing a gate, which is when places actually change).
Reports are validated and stored but **never broadcast on their own** - the
race tick loop re-sorts the field, stamps every driver with their position
integer and pushes the whole ordered array to all clients every **~300 ms**,
so a full grid costs a fixed handful of messages per second no matter how many
cars are running.

Classified finishers hold the top places by finish time, drivers still
circulating follow in running order, and DNF/disqualified drivers sit at the
bottom. The leaderboard flashes a green ▲ or red ▼ next to a driver who has
just gained or lost a place, and your own distance to the next checkpoint is
shown in the app header while you race.

## Time behind

Every board carries a **Gap** column: how far behind this driver is. The
broadcast board adds **Int**, the gap to the car directly ahead rather than to
the leader.

**It is measured, not estimated.** A gap here is the subtraction of two readings
off one clock - the server's `race.time`, which every finish and every lap is
already stamped from - taken at the **last checkpoint both cars have actually
reached**. Nothing is interpolated from speed or distance, so there is no figure
on screen that the mod cannot point at two timestamps for.

That has one consequence worth knowing before you commentate off it: **the gap
refreshes when the follower reaches a checkpoint, not continuously.** On a
twelve-gate circuit at ninety seconds a lap that is roughly every seven seconds.
It is finer than the sector timing a televised race shows, but it is not a
ticking number, and a leader pulling away mid-sector will not move it until the
car behind reaches the same gate.

**It works on branch layouts**, which is the reason it is built this way rather
than from track position. A [branch gate](#branch-gates-two-ways-through-a-checkpoint)
is another way through a checkpoint that already exists, so two cars at opposite
ends of a head-on oval have cleared the same checkpoints and their splits
subtract correctly. A gap built from distance would have them minutes apart.

### What each session measures

- **A race** is scored on the clock, so the gap is the split difference above.
  A finisher's gap is their finish time behind the winner's - the flag is
  stamped as a checkpoint like any other, so the same subtraction produces it.
- **Qualifying** is scored on the best *lap*. Two drivers who set identical
  times ten minutes apart are level, so a clock delta would rank them by when
  they went out; the qualifying gap is the difference between best laps, and the
  server deliberately sends no clock gap for a qualifying session at all.
- **A driver who is lapped** reads `+1 LAP`, not a number of seconds. The split
  subtraction across a lap boundary is a real figure that means nothing, and it
  is the one reading on these boards that would actively mislead.
- **A retirement or a disqualification** has no gap. They are classified by a
  ruling rather than by where they got to.

### Accuracy

Displayed to a tenth, and that is the honest limit rather than a display choice.
The server stamps a checkpoint when the client's report **arrives**, so a driver
on a 120 ms connection reads about a tenth behind one on 20 ms. Real clock sync
between clients would be a much larger change than this feature is worth, and
the plugin already settles finish order the same way - by arrival, deliberately,
so that the same input always produces the same result.

A gap is never shown as negative. If the order has changed since a driver's last
checkpoint - they were ahead when they passed it and have been overtaken between
there and here - it reads `+0.0`, which is what "too close to call" looks like.

### What it costs

Nothing that shows up on a race night, and it was built to that constraint:

- **No new network traffic in either direction.** The client already fires a
  checkpoint report on the frame after every crossing, because the running order
  needs it; the server simply notes what the clock read when one arrives. The
  broadcast grows by two numbers per driver.
- **No new work per frame or per tick.** The two subtractions happen inside the
  loop that was already stamping positions on the sorted field.
- Measured on a 20-driver, 20-lap, 12-gate race: **3.4 microseconds per
  broadcast**, three broadcasts a second - about a hundred-thousandth of one
  core - and **150 KB** of split times held for the whole race.

## Display names

BeamMP calls a guest something like `Guest_4471`, which makes for an
unreadable leaderboard and a worse results file. An admin can give any driver a
readable name from the **Admin** tab: the panel lists everyone connected with
their real name, a box, **Set**, and **✕** to clear.

The name is **display only**. Timing, checkpoints, scoring and the starting grid
all key on the BeamMP player id exactly as before - an alias is never used as a
lookup, so renaming somebody mid-session moves nothing but the text on screen.

**Names are saved on the server.** Every name an admin sets is written to
`Resources/Server/RaceManager/roster.json` as a **saved driver** - an id, the
name, and the guest name that connection was using at the time. They live
through Start Quali, Generate Grid, a whole race, **Reset**, a second race after
that, and the server going down and coming back up.

The roster is also what cup points hang off, so a saved driver is an identity
for a whole season, not just an evening.

### Who is who: an admin decides

**Nothing is ever assigned automatically.** BeamMP gives every connection a
fresh random guest name - a different one each time the same person joins - so
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

### Display names on the BeamMP nametag

**Show display names on nametags**, in the Display Names panel, appends a
driver's display name to the tag floating over their car:

    guest5961302 (Kestrel)

It is **appended, not substituted**, and that is a limit rather than a choice.
BeamMP has no server-side way to rename anybody - the guest identity comes from
their auth, and the plugin cannot reach it - so what this switches on is BeamMP's
own `setPlayerNickSuffix`, which adds text to a nametag and does nothing else to
it.

**Nothing but the text changes.** Distance fade, hide-behind-objects, color,
alpha, the spectator list, role tags: all of it is still BeamMP's, rendered by
BeamMP, obeying whatever each player has set. There is a way to take the whole
nametag over - hide BeamMP's and draw your own, which is what some mods do - and
it is deliberately not taken here. Owning the render means owning every one of
those settings, and getting any of them slightly wrong is worse for a player than
a guest number is.

The switch is **server-owned and off by default**, so every client agrees on it
and a league that has assigned no names gets nothing it did not ask for. Turning
it off takes every suffix back off, and so does leaving the server.

**Only players running Race Manager see it.** A nametag is drawn on each machine
from that machine's own player list, so this is a client-side presentation rule.
Everyone connected to a server running the mod has it - BeamMP pushes the client
zip on join - but nothing outside the session is affected.

**Chat, the player list and the server console still show the guest name.** Only
the floating tag changes. That is the same trade the leaderboard already makes:
an admin sees the real name beside the alias precisely so a tag can be tied back
to the guest session that set the lap times.

**If your server already runs a nametag mod** (BeamJoy, CEI), leave this off. The
suffix is filed under its own tag source so it will not overwrite theirs, but a
mod that replaces BeamMP's rendering entirely will not show it at all.

### Placeholders

A driver who races without being assigned is not dropped - their points go to a
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
on them, stays exactly where it is - it just stops being shown against that
connection. Clearing a display name does the same thing.

**Ending a cup does not clear the roster.** Names are not cup property.

> The account id BeamMP exposes for a *logged-in* player would let the server do
> all of this unaided. It is where this goes when the guest-accounts restriction
> lifts; until then, a person deciding is the only trustworthy anchor.

- **Fallback** - a driver with no name set simply shows their guest name. It can
  never render blank.
- **Validation** - 3–20 characters, letters, digits, spaces and `- _ .` only.
  ASCII only, because the results file lays out fixed-width columns and Lua pads
  by bytes, so one accented character would shear every row below it.
- **Collisions and impersonation** - a name already in use, as an alias *or* as
  someone's real guest name, is refused; so are `admin`, `server`, `host`,
  `console` and anything starting with `guest`.
- **Every attempt gets an answer** - the name applies, or a notice says why not.
- **A recycled session id never inherits a name.** BeamMP hands ids out again
  after a disconnect; if a different player turns up on one, the display name is
  dropped rather than passed on - and nothing reassigns it without an admin.
- **Race and derby** - names show on the race leaderboard, the derby standings
  and the derby winner announcement.
- **Results files** - both the race and derby exports record the name the driver
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
| `-1` | Unlimited - the default |
| `0` | No resets at all: the reset button does nothing |
| `N` | `N` resets; every press after that is blocked |

The field applies itself as you type (see [Settings apply
themselves](#settings-apply-themselves)), so an **empty** box means "still
typing" and is never sent - `-1` is how you ask for unlimited.

The BeamMP server never sees a reset happen, so the **client** polices it.
Every reset inside the allowance is counted and reported (the leaderboard
gains an `Rst` column showing `used/allowed`). Once the allowance is gone the
reset **inputs themselves are switched off** through BeamNG's input action
filter - pressing reset/recover does nothing at all, the car never resets,
and the driver simply keeps racing. As a fallback for reset paths the filter
cannot see, any reset that still slips through is undone: the car is put
straight back on the position and orientation it held a moment earlier.

Blocked attempts are still reported to the server and recorded in the results
file (`3/3+2` for a driver who kept pressing R after running out), but the
live `Rst` counter is clamped - it only ever shows `used/allowed` and can
never exceed the limit. Nobody is disqualified for a blocked attempt. The
limit is locked once a countdown or race starts.

**Reset mode** (Race settings, admin only) decides what a *legal* reset does
while racing:

| Mode | Behavior |
|------|-----------|
| **In place** | BeamNG's normal repair-where-you-stand (the default) |
| **Last checkpoint** | The car is respawned at the last checkpoint it crossed, facing the direction of travel |

Last-checkpoint mode applies whether or not resets are limited; before the
first checkpoint of a session it falls back to in-place. Like every
regulation it is locked once the countdown starts.

Two details keep a spent allowance from turning into a stuck car. BeamNG
reports every teleport as a vehicle reset, including the ones the mod performs
itself, so the car being put back - and being stood on its grid slot - is
recognized as the mod's own doing and never counted, blocked or reported.
And because the reset key repeats while it is held, the block is applied to
every press but the notice, the console line and the server report are limited
to one a second.

### Fastest lap

The quickest lap set by anyone in the session is shown **in gold** in the Best
Lap column, so the whole field can see who holds it and when it changes hands.
The driver who sets it gets a short `FASTEST LAP - 1:31.240` notice, on the same
channel as the reset and joker messages.

The notice fires again whenever the time changes hands **or improves** - beating
your own fastest lap is announced too.

It is per session - a new race starts with nobody holding it - and it is decided
by the server, so every leaderboard agrees. Qualifying highlights the **quali
best** (the time that session is scored on); the race highlights the **race
best**.

### Holding the grid

Between **Generate Grid** and **GO!** every gridded car is frozen on its start
position. The freeze itself is applied by each client - the server has no
physics - but the server owns the rule and checks that it is actually working.

A car dropped onto a start position first has to fall onto its suspension, and
nothing polices it until it has come to rest - enforcing against settling makes
a car hover at the height it was dropped from, being reset every frame. Where it
settles is then what "on its slot" means.

Distances are measured **across the ground**. Stealing a start is a move
forwards; a car sagging on its suspension has not moved anywhere, and counting
that as movement is what caused the hover.

The two failures get different answers. A car that is merely *moving* on its slot
has lost its freeze and is re-pinned where it stands - no teleport, so nothing is
disturbed. A car that has actually **left** its slot is put back on it.

Each held car reports its position four times a second. A car more than
**0.5 m** from its assigned slot is put back on it, re-frozen, and the
correction is logged with the driver, the distance, the slot and the race
state:

```
[RaceManager] HOLD violation: Ryder was 2.50m off grid slot 4 during countdown
              (tolerance 0.50m) - pulled back, correction #1
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
sitting idle, and that is intended - it is a standing start, and preparing the
launch is part of it. What the hold guarantees is that nobody is *ahead* of their
slot when the lights go out, not that everyone launches identically. One
consequence worth knowing: a car that has to be corrected is re-frozen, and
re-freezing resets the drivetrain, so that driver loses their revs and any
pre-selected gear. Only drivers whose hold actually failed pay that, and the
alternative is letting them creep.

If the server was never told where the grid slots are - an admin who built start
positions live on an older client build, so only a count was reported - it stays
out of it and the client-side guard alone enforces the hold. Loading a saved
layout always gives the server the coordinates.

### Reset ghosting

A driver who resets mid-session used to reappear **solid and stationary**,
often in the middle of the racing line, and whoever arrived next drove into
them. Reset ghosting removes that: for a few seconds after a reset the car has
no vehicle-to-vehicle collisions, in **both** directions - it cannot be hit and
it cannot hit anyone. Collisions with the **world and the terrain are
untouched**, so the car still sits on the road and still hits the scenery.

Everyone else sees the ghosted car go **translucent**, then fade back to solid
over the last second as a warning that contact is about to resume. The ghosted
driver gets a countdown of their own in the app.

It is on by default and applies during a race **and** during qualifying
resetting into somebody is the same physical problem in both.

| Setting | Default | What it does |
|---|---|---|
| `ghostOnReset` | `true` | Master switch. `false` disables reset ghosting entirely |
| `ghostMinDurationSec` | `5.0` | How long a ghost lasts, from the moment the car is placed and settled |
| `ghostMaxDurationSec` | `15.0` | Ceiling on the timer when a driver resets repeatedly |
| `ghostAlpha` | `0.35` | How translucent a ghosted car looks to everyone else |
| `ghostFadeOutSec` | `1.0` | Seconds spent fading back to solid before contact resumes |
| `ghostOverlapMargin` | `0.25` | Meters of clearance required around a car before it goes solid |
| `ghostOverlapWarnSec` | `10.0` | How long a driver may sit blocked before being told to move clear |

The first three are **server** settings (near the top of
`server/RaceManager/main.lua`) because they are a league rule - a client running
a five-second ghost in a field running eight is a field where two cars disagree
about whether they can touch, so the server broadcasts them and every client
obeys. The last four are **client** settings (the `TUNE` table in
`lua/ge/extensions/raceManager.lua`): local presentation and local geometry that
no other client has an opinion about.

**Why the timer is not the whole story.** Restoring collisions on two cars that
are *inside each other* welds their node structures together. It ends both
drivers' races instantly and there is no recovery from it. So when the timer
expires the space around the car is measured against every other car on track
a real bounding-box test, not a distance between origins, so a car lying
crossways through another is caught - and collisions come back only on a frame
that is provably clear.

Uncertainty counts as occupied, but it is always a question that can be asked
again rather than a permanent verdict. The space around a car is measured three
ways in order - its oriented bounding box, its axis-aligned world box, then its
own dimensions - so a car is nearly always measured at its true size: a car that cannot be measured precisely is
judged on distance, and one that is far away is not treated as being inside you.
The end of a session clears every ghost regardless - nothing stays intangible
past the flag.

That check has **no time limit and no override** while the session is running. A car parked inside another
stays a ghost indefinitely, is never forced solid, and goes solid the moment the
space clears. If it is blocked for longer than `ghostOverlapWarnSec` the driver
is told to **move clear** and the server logs it - a warning only, never a
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
penalised - the log is there so an admin can see it and rule on it themselves.

Ghosting is collision and rendering only. Checkpoint, lap and split validation
are completely unaffected.

### Picking a track or an arena

Both live **beside the session controls**, not in the editor. Pick a **Track** and
press **Load Layout** for a race; pick an **Arena** and press **Load Arena** for a
derby. Building either stays in the editor - opening it swaps the race visuals
for the authoring ones, which is not what you want with a field waiting.

### Joining while a session is running

Connecting mid-race does not put you in it. A driver who arrives has no grid
slot, no laps and no out lap behind them, so they are held as a **spectator until
the next grid forms** - which is where entry is decided for everybody.

**Their car is a ghost to everyone still racing.** They arrive with a vehicle, a
spawn point and no idea a session is running, and without this they can put a
leader into a wall before they have finished reading the message telling them not
to. The ghost lasts exactly as long as they are outside the session; forming the
next grid clears it and puts them in the race properly.

### Cars on and off the track

Two things happen automatically so the track only ever holds cars that are
still racing:

- **A driver who takes the flag keeps their car, and it becomes a ghost.** You
  stay exactly where you are, in the car you finished in, and you can drive it
  anywhere on the map to watch the rest of the race.

  **You still see your own car normally.** Everyone else sees it translucent.
  Its collisions are off in both directions: nobody still racing can hit, block,
  push, ram or draft off you, and you cannot touch their physics at all. Finished
  cars also pass through **each other**, so nobody can shunt a fellow spectator
  into the racing line. World and terrain collision are untouched, so you sit on
  the map as normal.

  **Nothing is created or destroyed at the flag.** Your car used to be deleted
  and respawned at the end of the race, which is an entity destroy and an entity
  create per driver at the one moment a whole field is coming home. That was the
  worst of it on a low-end machine, and it is gone: finishing is now a change of
  state and nothing else.

  You get a **checkered flag** for the rest of the session, with a count of how
  many drivers you are still waiting on, and a one-off message telling you where
  you placed. Resets still work if you land in the water, they cost you nothing,
  and the car comes back still ghosted.

  The mod never changes your camera *mode*: whatever view you were driving in is
  the view you spectate in, and **tab cycles targets** as it normally does. If a
  car you were watching **disconnects**, the view moves on to the next one still
  moving. A car that merely parks is left alone, and a car you tabbed to yourself
  is never taken off you.
- **The node grabber is switched off for the whole of a derby** - form-up,
  countdown and running. Dragging physics nodes is a debug tool everywhere else
  and a winning move in a demolition derby: it will right your own wreck, or put
  somebody else into a wall without touching them. It comes back when the derby
  ends.
- **When the field comes back, it comes back on the starting grid.** Cars are
  removed as they take the flag, so every one of them is removed within a few
  meters of the start/finish line - putting them all back where they were removed
  is what used to respawn the whole field inside itself. The grid is spaced by
  construction, so that is where they return.
- **When the session ends, every removed car is put back.** The same applies
  to a driver **eliminated in a Demo Derby** - their car returns when the derby
  finishes. The spectator lock is scoped per mode, so a race and a derby can
  never release each other's spectators.

### Caution and restart

A **full-course yellow** called mid-race, and **the field races back to the
line**. Press **Caution** while a race is running and:

1. The flag goes yellow and the field is told, in chat and on screen, to **race
   back to the line**. Nothing is frozen yet: on the road the race is still on,
   and the board goes on re-sorting to say so.
2. **The leader dictates the lap.** Their crossing makes the caution official
   and names the lap it was called on.
3. **Every other driver locks their place as they complete that same lap.**
   First back to the line is first. From there the board holds station: closing
   up under the yellow costs and gains nobody a place.
4. **Cars a lap or more down sort to the bottom**, in the order the lapped cars
   came back &mdash; wherever they happen to be on the road.
5. Optionally the **free pass** gives the first car a lap down its lap back
   before the green.
6. **Restart** is *called*, and the green falls as the leader reaches the line.
   It can be waved off until it does.

**The freeze is the feature, and it is the only half of a caution this mod can
enforce.** The server has no physics access: it cannot slow a car, close a gap or
line a field up behind the leader. What it *can* do is stop positions changing
&mdash; which is exactly what a real caution does to the timing sheet, and is a
scoring rule rather than a movement one.

**Why it is raced back to rather than snapshot at the button.** A snapshot scores
the field at a moment nobody on track can see, and hands a place to whoever
happened to be mid-overtake when a marshal reached for the mouse. Racing back to
the line is the rule drivers already understand and the one they can act on: get
to the line, and where you are when you arrive is where you restart.

It is **not** a ruling on any individual overtake. Nobody is penalised and no
incident is judged &mdash; the board simply stops re-sorting once you are past
the line. A marshal who can see the incident is still better at judging it than a
distance comparison.

#### The free pass ("lucky dog")

Off by default; switch **Free pass** on in Race settings. When the last car has
locked, **the highest-placed car a lap down takes its lap back** and restarts at
the **tail of the lead lap**.

It goes to the *first car a lap down*, not the car furthest back &mdash; the car
that was actually racing the leader when the yellow fell. Handing it to whoever
is deepest in the field would give it to the same slowest car every single
caution, which is not a prize anybody is racing for.

One car per caution. The whole field is told, and so is the driver's own client:
the credited lap has to reach both sides, or the driver's live position and gap
would quietly stop working for the rest of the race.

#### The restart, and calling it off

Pressing **Restart** does not go green. It says **the current lap is the
restart** and the green falls as the **leader reaches the start/finish line**, so
the field is packed up and looking at it rather than being waved off round the
back of the circuit at whatever moment the marshal decided.

**Cancel restart** waves the call off. Only the call goes: the race stays
neutralised, the board stays frozen and the caution laps go on counting. Pressing
Caution again would count a second yellow and re-freeze an order that never
thawed, which is why the wave-off is its own control.

Some details worth knowing:

- **In a race, the caution *is* the yellow and the restart *is* the green.** The
  advisory Yellow and Green flag buttons used to sit beside them, so a marshal
  calling a yellow saw two yellow buttons and only one of them neutralised
  anything. They now belong to **qualifying**, which has no running order to
  freeze &mdash; there a yellow really is only a hazard being pointed at.
- **Red is its own instrument, in both sessions.** It means stop where you are;
  the session keeps running. Pressing it again lifts it, and **lifting a red
  returns the field to whatever it was already under** &mdash; a neutralised race
  goes back to its caution rather than being waved off the instant the wreck is
  moved. A red also holds the restart: a leader who rolls the last few meters to
  the line under one does not start the race by arriving.
- **The Green flag button is still the restart** where it is reachable (a chat
  command, an older panel), so a green called by hand can never leave the race
  running with the order frozen and nothing to unfreeze it.
- **Laps run under the caution count** toward the distance, and are counted
  separately. The first is the leader's *next* crossing: the lap the yellow came
  out on is not a lap run under it.
- **A caution never outlives its session.** Ending or resetting a session drops
  it, the pending call, the restart call and every locked position &mdash; one
  left standing would silently order the *next* race, which is invisible until
  somebody wins a race they ran fourth in.
- **Qualifying cannot be neutralised.** Drivers are on their own laps and the
  board is a list of best times, so there is no running order to freeze.
- **Not during the pace lap.** The field is already under yellow with a green to
  come, which is what a caution would be asking for.
- The results file records **how many cautions there were and how many laps ran
  under them**. A race with four yellows in it used to read exactly like a clean
  one, which makes a lap chart impossible to explain afterwards.

### Importing BeamMP scenarii races and derbies

`tools/import_scenarii.py` converts the races and derbies from a BeamMP
**scenarii** folder into Race Manager layouts and arenas.

```
python tools/import_scenarii.py ~/Downloads/scenarii --list   # say what it finds
python tools/import_scenarii.py ~/Downloads/scenarii          # write import/
```

It writes `import/layouts.json` and `import/derbyArenas.json` (the formats the
server loads), `import/by-map/<map>.json` (the same content split one file per
track, which is the readable half: "which tracks do we have races for" becomes
`ls`), and `import/INDEX.md` listing every race with its gate count and any
caveat. **Nothing is installed** &mdash; `layouts.json` is every track an admin
has ever built, so the merge is left to a human. `--merge path/to/layouts.json`
folds an existing file in, imports second.

**What converts exactly.** A scenarii race is a list of *steps*, and each step is
a list of waypoints that are alternatives to each other. That is precisely a
Race Manager checkpoint plus [branch gates](#branch-gates-two-ways-through-a-checkpoint)
on the same slot: any one of them clears the step. Start positions, names and
`loopable` (which becomes a sprint stage when false) all carry over unchanged.

**What is approximated**, and both are noted per race in the index:

- **A radius becomes a width.** A scenarii waypoint is a sphere; a Race Manager
  checkpoint is an upright rectangle with a direction. Width is the same span
  across (`radius * 2`), but a sphere has no facing, so a car that used to clip
  the old gate diagonally can miss the new one. Widen it in the editor if a gate
  turns out to be missable.
- **Headings come from the route, not the stored rotation.** The rotation on a
  scenarii waypoint is wherever the author's car happened to point when they
  dropped it, which at a hairpin can be most of a right angle off the direction
  the field crosses it. The vector from the previous step to the next one is the
  honest answer and is what gets used. Start positions are the exception and do
  use the stored rotation, because there "which way does the car face" is the
  whole content of the slot.

Circular derby arenas become 16-sided polygons, which is what the mod polices
against; they stay in polygon mode so the rectangle editor's sliders cannot
silently square off a round arena.

Imported tracks are **not** approved for practice. Practice lets a non-admin load
a track on their own, and an import nobody has driven yet is not something to
hand the whole server unreviewed.

### Multi-class racing

Two car types on one grid, scored as two races. There was no class concept
anywhere before this: a league running GT3 and GT4 together either scored them
in one list or ran two separate events, and locking the Garage List to a single
car was the workaround.

**A class is a property of the car**, so it is tagged on the **Garage List entry**
rather than assigned to a driver. Open the **Garage** tab, whitelist the cars as
usual, and type a class into the box on each row &mdash; `GT3`, `GT4`, whatever
your league calls them. Every driver in that car is in that class, for every race,
with no per-driver bookkeeping and nothing to remember when somebody switches car.

Leave every box blank and nothing changes: no class on any driver, no Class
column, no per-class section. That is what a single-class night is.

What you get once a class is set:

- **A Class column on the leaderboard**, showing the class and the driver's
  position *within* it &mdash; `GT4 P1` on a car running third overall.
- **Per-class positions** everywhere the board is drawn, counted within the
  class, so the leading GT4 is P1 in class while still being P3 on the road.
- **Per-class sections in the results file**, each with its own finishing order
  and its own class winner, under the overall table.

Details:

- **The overall order never changes.** A class is a way of reading the race, not
  a change to it: the GT4 winner did not beat the GT3 field, and the overall
  table still says so with the real race winner at the top of it.
- **Classes work with enforcement OFF.** "What class is this car" and "is this
  car legal" are different questions, and a league that wants two classes scored
  without policing anybody's setup is an ordinary thing to want. Tagging a class
  does not switch enforcement on.
- **Tagging an entry re-classes everyone in that car immediately**, on the next
  broadcast rather than the next time each driver happens to touch their setup
  &mdash; which for a driver already sitting on the grid is never.
- **A class survives a disconnect**, like a heat does. Generate Grid purges every
  record that is not a connected player, so the class is mirrored into the driver
  roster: a driver who drops out between two races comes back in their class.
- **A class name is capped at twelve characters** and stripped to plain ASCII.
  The results file is a fixed-width text table, and a longer or multi-byte name
  would shear every row after it.
- **Not idle-locked.** Unlike the lap count, a class can be changed mid-session:
  it changes how the board is *grouped*, not the distance under cars already
  running, and correcting an entry tagged wrong is exactly what an admin needs to
  be able to do the moment they notice.
- **Cup points are still scored on the overall order.** A per-class championship
  is a separate decision about how a season is scored, and it is not made here.

### The blue flag

Lapped traffic was displayed and never signalled. The board read `+1 LAP` and
neither driver was told anything: the backmarker got no blue flag, and the car
closing on them got no warning that the car ahead was not racing it.

Now, when a car a lap or more up comes within a couple of seconds of a
backmarker:

- **the backmarker is shown the blue flag** in the header, and gets a notice
  telling them to hold their line and let the faster car by;
- **the car doing the lapping is told there is a backmarker ahead**, on the
  notice strip rather than as a flag, because no series waves anything at the
  car doing the passing.

**The classification is the wrong list to read this off**, and that is the whole
of why it needed writing rather than reading. A lapped car sorts *below* the
entire lead lap, so the car directly above it on the timing screen is another
backmarker &mdash; while the car physically behind it on the road, the one
actually about to come past, is somewhere near the top of the sheet. Adjacency on
the board and adjacency on the track stop being the same question the moment
anybody is lapped. So the server sorts a second list by how far round the lap
each car is, ignoring *which* lap that is, and two cars next to each other in
that list are next to each other on the road.

**The gap is measured at a point both cars have physically passed**, on each
car's own lap: the backmarker went through checkpoint 7 of lap 4 at 214.6s, the
lapping car went through checkpoint 7 of *lap 5* at 216.1s, so it is 1.5s behind
them on the road. That is the same subtraction the gap column is built from, with
each stamp taken on the lap its driver was actually running. Nothing is
estimated and nothing depends on how many checkpoints a lap has.

Details:

- **Two thresholds, not one.** The flag comes out inside `blueFlagWithin` (2.0s)
  and does not go away until the gap opens past `blueFlagClear` (4.0s). A single
  threshold makes a flag that strobes: a car hovering either side of it turns the
  flag on and off several times a second, and a flag that blinks is one a driver
  learns to ignore. Both live in `config.json`, and a file with them crossed over
  gets the clear distance pushed clear rather than the pair swapped.
- **It clears the moment it stops being true.** Let the car by, pit, or watch the
  car chasing you retire, and the flag is gone on the next broadcast. Nothing
  holds it open.
- **A caution outranks it.** Nobody is letting anybody by under a yellow, and a
  blue flag next to a yellow is two instructions that contradict each other. The
  server stops setting it under caution and on the pace lap, and the client ranks
  yellow above blue, so the two agree rather than one overriding the other.
- **Below the white flag.** A driver on their own last lap is being told their
  race is ending, which outranks being told to move over.
- **Not in qualifying.** Drivers are on their own laps and a car "a lap down" is
  just a car that went out later. There is nothing to let by.
- **It is a signal, not a ruling.** Nobody is penalised for ignoring it, and the
  classification does not change. It is the same choice the flags have always
  made here: a marshal who can see the incident is better at judging it than a
  distance comparison.

### Heats and transfers

Run the night as several short **heats** and then a **feature**, with the heat
results setting the feature grid &mdash; the format most oval and dirt leagues
actually run.

Set it up in the **Grid** tab:

1. **Heats** &mdash; how many the night is split into. 0 turns the program off.
2. **Transfer** &mdash; how many drivers get out of each heat. They start the
   feature ahead of everyone who did not.
3. **Heat laps** &mdash; how long a heat is. 0 runs them over the race distance.
4. **Draw heats** &mdash; splits the field.
5. **Next up** &mdash; pick a heat, or the feature. This decides who **Generate
   Grid** puts on the track.
6. Set **Grid order** to **Heats** for the feature.

**Heats get their own lap count** because heats are short and features are long
&mdash; eight-lap heats into a thirty-lap feature is the ordinary shape of a heat
night. With one shared lap box the number had to be retyped between every session
of the evening, which is a thing to forget once and run the feature over eight
laps. Set **Heat laps** and the feature keeps the **Laps** box in Race settings;
leave it at 0 and both run the same distance, exactly as before.

**The draw is a serpentine off qualifying time**, which is how heat racing has
always drawn them: 1st to heat 1, 2nd to heat 2, ... Nth to heat N, and then
*back along the row* &mdash; (N+1)th to heat N, (N+2)th to heat N-1. A straight
round-robin would put the four fastest drivers on four different poles and the
four slowest all at the back of their own heats, which makes the heats
incomparable and a transfer worth more out of one than another. The serpentine
gives every heat a comparable spread. With no qualifying behind it the draw falls
back to join order, which is at least repeatable.

**A heat is an ordinary race run by a subset of the field.** Everything else
works exactly as it always did &mdash; the grid, the hold, the countdown or pace
lap, the flags, the results file. Generate Grid simply forms a grid of that
heat's drivers, and the entrant count reads the heat rather than the night.

**The feature grid is the transfer order:** the heat winners on the front row,
then all the seconds, then all the thirds, with heat number breaking the tie
inside each row. So a three-heat night lines up 1st-of-H1, 1st-of-H2, 1st-of-H3,
2nd-of-H1... which is what makes a heat win worth having and stops one strong
heat filling the whole front of the grid.

**Drivers who did not transfer still race**, lining up behind everyone who did,
in their own heat order. Excluding them outright is the other reading of a
transfer and it is the wrong default for a league night &mdash; it sends half the
server to the spectator seats for the main event. An admin who wants a strict
transfer has **Sit Out** for exactly that.

Details:

- **A disqualification never transfers**, whatever place the sort left it in.
  The heat result is recorded after the joker ruling has run, so a driver
  excluded from a heat does not take a front-row start out of it.
- **Transfers survive a disconnect.** Generate Grid purges every record that is
  not a connected player, so heat results are mirrored into the driver roster:
  a driver who drops out between heat two and the feature comes back with the
  heat they were drawn into and the transfer they earned.
- **Qualifying is never split.** The draw is made *from* qualifying times, so a
  qualifying session that only let one heat out would be drawing heats from
  times set by the drivers it had already drawn. Qualifying always grids the
  whole field, even with a heat selected.
- **Setting the heat count to 0 ends the program** and forgets every draw and the
  heat distance with it, so a half-configured heat night can always be cleared.
  Reset Session does the same &mdash; a new evening starts with an undrawn field.
- **The heat distance is enforced on both sides.** The server ends the heat at
  it, and every client waves its own white and checkered flags off the same
  number &mdash; a heat whose length only the server knew would be flagged at the
  feature's lap count on every screen.

### Pace lap

Start the race **behind a pace car** instead of from the lights. Switch
**Pace lap** on in Race settings and **Start Countdown** is replaced by
**Start Race** on the grid.

Press it and:

1. The field is released **immediately**, with no countdown, under a **yellow
   flag**. Chat and the on-screen notice both say: *maintain position and limit
   your speed to 40 mph / 64 km/h*, and the driver bar carries a
   `PACE LAP 40 MPH / 64 KM/H` badge for as long as it lasts.
2. The field runs a **formation lap**.
3. The **green flag falls automatically** as the leader comes back within
   **10 m** of the start/finish line -- waved on the approach, not once the
   leader is already past, which is what a marshal actually does.
4. Every driver's own crossing of the line then starts **their** lap 1. The
   green is one event for the whole field, but the field is strung out, so the
   lap each driver is on is still decided at the line by that driver.

**The formation lap is not one of your laps.** It is driven and not scored, so a
5-lap race behind the pace car is a formation lap **plus** 5 racing laps -- six
crossings in total. It sets no lap time and cannot take fastest lap.

**The leaderboard counts racing laps, not crossings.** During the formation lap
the Lap cell reads `PACE`, and after it the leader on the last lap of a five-lap
race reads `5/5`. It used to read `6/5`: the numerator was counting crossings
while the denominator counted laps of the race, which are only the same number
when no lap is given away. Qualifying's out lap has always been counted out the
same way. The results file still says so in its header, because
`Race distance: 5 laps` above a Laps column is worth settling on the page.

This is the one place the pace lap differs from the out lap a
[head-on grid](#branch-gates-two-ways-through-a-checkpoint) owes. That one is a
*racing* lap that merely sets no time, so it comes **out** of the distance; a
formation lap is not a racing lap at all, so it goes **on top**.

**A timed race's clock starts at the green**, not at the release. Ninety seconds
of forming up still leaves the full ten minutes of racing, and the header's
countdown does not move until the green falls.

Two things stop a pace lap from hanging:

- **A red flag holds the green.** Red means stop where you are and wait, so a
  leader who coasts the last few meters to the line under one does not start the
  race by arriving. **Lifting the red resumes the formation lap** rather than
  ending it -- whatever the field was under before the stoppage, it is under it
  again afterwards. Call the green separately when the track is clear.
- **The Green flag button ends it at any time.** A field that has crashed,
  spun or simply stopped never brings its leader back to the line, and rather
  than guess how long a formation lap may take, the marshal who can see the
  track calls it with the same button they would use for any other green. If
  every driver has already crossed the line, the green falls on its own: a
  yellow that nothing can lift is worse than an early green.

**Races only, and circuits only.** Qualifying has no field to form up -- drivers
go out when they choose and the lap that matters is a solo one -- so a grid
formed by *Start Quali* keeps its countdown even with the rule armed. A
point-to-point sprint stage is driven once from the first gate to the last and
has no lap to form up on, so the switch is grayed out there, the server refuses
it if asked anyway, and loading a sprint stage switches it back off.

The trigger distances are server settings: `paceGreenAt` (10 m, where the green
falls) and `paceArmAt` (50 m, how far the leader must first get *away* from the
line before that means anything -- the field starts the lap standing on the line,
so without it the green would fall the instant the cars were let go). Both live
in `config.json` beside the lap count.

### Rallycross joker laps

A **joker route** is a second, independent set of checkpoint gates describing
the alternate rallycross line. Build it in the editor with the **Joker Route**
tab (gates are drawn violet in the world), and it is saved and loaded together
with the track layout - one layout carries both routes.

**The joker lap cannot be armed on a track that has no joker gates.** The rule
reclassifies anyone who did not complete the route exactly once, so with no route
that is every driver who finishes - disqualified for missing something that was
never there, and not told why until the results file is written. The toggle is
grayed out until gates are placed, the server refuses it if asked anyway, and
loading a track without a joker route switches it back off.

Switch **Joker lap** on in Race settings and the rule is enforced:

- The joker route must be completed **exactly once per race**.
- **Lap 1 is closed**: any joker attempt on the opening lap is invalidated by
  the client on the spot - the progress is thrown away and nothing is reported.
- Repeat runs after a valid one are ignored and flagged to the driver.
- At the flag the **server rules on every finisher**. Anyone who did not take
  the joker exactly once is reclassified as
  **`Disqualified - Missed Joker`** (or `Disqualified - Extra Joker`), which
  goes straight into the results `.txt` alongside a `Joker` column showing the
  lap each driver used.

#### Seeing the checkpoints

A driver gets **two poles** at the gate they are aiming at and two more, dimmed,
at the one after it - drawn by the mod in its own colors rather than BeamNG's
markers, which could not be made bright enough to see.

**No text on them.** The poles say where the gate is and the color says which
one is next; "CP 3" read at racing speed tells a driver nothing they can act on,
and it is one more thing painted across the racing line. Pit stalls are the same:
amber, unlabeled, drawn as the box they test.

**The joker is marked out, but not with words either.** It is the one gate whose
state changes what you should *do* - owed, taken, or forbidden on lap 1 - and
getting it wrong is a disqualification, so it gets a faint violet fill between
its poles and a **symbol** on the gate face: a translucent red **cross** while it
is shut, a green **tick** once it has been taken, a faded **arrow** while it is
open. A sentence read at racing speed is a sentence a driver has no attention
for; a cross is not.

It used to carry the wording as well, and that came off once the symbols were
doing the work - `JOKER 1/2 (lap 1: closed)` is a second copy of what the cross
had already said, in the form nobody can read at speed. **The editor still
numbers and labels everything, joker included**: that is where the words are
worth reading, and where there is time to read them.

Two gates ahead and nothing else - a whole lap's worth of numbered rectangles
across the racing line is clutter, but a checkpoint nobody can see is worse.

The poles cannot simply be made wider to fix visibility: **their spacing is the
gate's width**, so poles further apart than the trigger would show a target that
does not score, and the first thing a driver would do is aim between them and be
told they missed. If a gate is genuinely too narrow to see, widen the **gate**
click it in the editor and raise its Width - and the poles follow.

**On track the joker stays violet**, painted the same violet the editor uses
rather than BeamNG's stock alternate-route orange - which sits close enough to
the main route's color that the joker read as more of the same lap, and this is
the one route where that mistake is a disqualification. The pole stays up after
the joker has been taken, dimmed and wearing its tick - *"you have taken it"* is
as much a thing a driver needs to know as *"you still owe it"*.

The symbol is drawn by the mod rather than by BeamNG's own gate markers, which
render **no text or shapes at all** - a stock marker can say where the joker is
and never what state it is in, which for the joker is the half that matters.

### Branch gates (two ways through a checkpoint)

A **branch gate** is another way through a checkpoint that already exists. Drive
through **either** gate and that checkpoint is cleared. That is the whole rule.

A branch gate never adds a checkpoint, so a lap is the same number of them
however you got round, and **the whole field is scored together**: one clock, one
running order, one results table.

Nothing records which gate you took, and nothing has to. There is no lane to be
on, no direction to be assigned, and no way to end up on the wrong one. Each
checkpoint is decided on its own, so a car that spins and turns round simply
clears the next checkpoint by whichever of its gates it drives through.

**The track follows the session, not the moment you loaded it.** A layout is
re-sent to any client that joins afterwards and to the whole field again when a
grid forms, so an admin no longer has to wait for everyone to spawn before
pressing Load. If two admins load different layouts, the last one the server
processes wins and is announced in chat - it is one server-side state, so
everybody ends up on the same track either way.

Build them in the editor's **Branches** tab. Pick which checkpoint the next gate
belongs to, drive to where the other way through it crosses, and place it. Both
gates are drawn on track and both light up green together, so a driver can see
the choice rather than having to know about it.

**Gates score in both directions**, which is what makes shared corners work. A
checkpoint everybody passes - a back stretch, a start/finish line - is crossed one
way by half the field and the other way by the rest, and counts for both. This
also fixes something older: a driver who **missed a checkpoint** and turned round
used to have to drive through it, carry on past, turn round again and come back
through. Now the way back through counts. Where direction really is the only
thing separating two legs of a track - a hairpin, or a figure-8 crossover - mark
that gate **one-way**.

A checkpoint can hold **as many branch gates as you place**. Three ways through
one corner is three gates on `CP 4`.

#### A head-on "suicide" oval

The field starts in two blocks facing opposite ways and races the same oval in
opposite directions.

1. **Main route, clockwise.** `CP 1` at turn 1, `CP 2` on the back stretch,
   `CP 3` at turn 2, and the **start/finish** line.
2. **Branches** tab. Set **Next gate is another** to `CP 1`, drive to **turn 2
   facing anti-clockwise**, and place it. Then set it to `CP 3`, drive to **turn 1
   facing anti-clockwise**, and place that.
3. Leave `CP 2` and the start/finish alone. Both directions cross them, from
   opposite sides, and both are credited.
4. **Start Grid** - place the grid, then turn half of it round: set **Slots 7 to
   12** and press **↻ Turn Around**.

That last step is the only thing that splits the field, because the way a start
position points is the only thing deciding which way a driver goes. A car facing
anti-clockwise reaches the anti-clockwise gate for `CP 1` first and clears the
checkpoint on it; a car facing clockwise reaches the other one. Neither is told
anything.

Both directions clear CP 1, then 2, then 3, then the line: same lap, same count,
directly comparable on the leaderboard the whole way round.

#### The out lap

A grid that is **not on the start/finish line** - which a head-on layout cannot
be, since two directions will not share one row of slots - gives its **first lap
away**, exactly as qualifying does. The run from the grid to the first crossing
is a fraction of a lap, and timed it would take fastest lap off every driver who
ever set an honest one. It is detected from the track and travels with the
layout, so there is nothing to remember on the night.

**A race's first lap counts - it just is not timed.** It is run off a standing
start, so it carries the launch and the scramble to the first corner and is not
the same measurement as a flying lap. A **one-lap** race is the exception: there
the standing lap is the only lap there is, so it keeps its time. So a 10-lap race is **10 crossings**, and
the first of them sets no lap time. That is the difference from **qualifying's out
lap**, which is a lap given *away*: not timed *and* not one of the laps you were
promised, so it is added on top of the allowance.

**The checkpoints are armed and drawn on the first lap like any other lap** - it is
the lap a driver least knows the circuit, and the worst one to hide the gates on.
Reaching the **start/finish line** also ends it, from wherever you have got to and
with slots still owing, so a car gridded past CP 1 is never sent most of the way
round backwards to arm a gate behind it.

A 10-lap race on such a track is **10 racing laps**; the out lap is added on top,
so the eleventh crossing is the one that ends it.

#### Building the grid

Placing slots one car at a time is the tedious part, so the **Start Grid** tab
does it in bulk.

**Generate N slots, W abreast, from** either your car or a **start position you
have already placed**. Pole is then a decision you make once, by standing on it
everything behind it is arithmetic. Generating from a placed slot rebuilds the
grid from there and leaves every slot before it alone.

**Rows can be any width from single file to eight abreast.** Two is a road-race
grid and an oval's, three and four are short-track and dirt formats, and one is a
stage start. Each row is **centerd on the anchor**, so an odd width puts a car on
the spot you stood and the rest either side, and an even width straddles it
changing the width never walks the grid sideways off the track.

Once a grid has been generated, three **sliders** appear: how far apart the rows
sit, how much room each car has beside the next, and how many are abreast. Drag
them and the grid moves under you - no driving back to pole to try a different
shape. They only ever touch slots the generator laid out; anything placed by hand
is left where you put it, and moving or deleting a slot by hand hands the block
back so the sliders stop claiming it.

**↻ Turn Around** turns a range of slots through 180°, and on a head-on layout it
is the entire split: the way a slot points is the only thing deciding which
direction that driver races.

**Headings survive a respace**, which is what makes the head-on flow work:
**Generate** the block, **Turn Around** the back half, and *then* spread the grid
out - the turned-around half stays turned around. That holds when the **width**
changes too: the heading follows the slot, not the row, so "slots 7 to 12 go the
other way" stays true whether those twelve cars are in six rows of two or four
rows of three.

Every placed gate and grid slot also has **✕** (delete just this one),
**+ Before** (insert at your car) and **▲ ▼** (reorder). Editing the main route
renumbers the branch gates with it; deleting a checkpoint drops the branch gates
that belonged to it, and says so.

### Vehicle & setup locking (the Garage List)

The **Garage** panel (admin only) locks the session down to approved cars:

1. Drive the car you want to allow and press **+ Whitelist Current Vehicle**.
   The client fingerprints it (jbeam model + every part in the part config +
   every tuning variable) and sends it to the server.
2. Repeat to build a Garage List of allowed cars. The list persists in
   `Resources/Server/RaceManager/garage.json` across restarts.
3. Pick what a capture **Locks** (below), then flip the toggle to **Enforcing**.

### What a capture locks

| Mode | Model | Parts | Tuning | Paint |
|---|---|---|---|---|
| **Parts** (default) | locked | locked | free | free |
| **Strict** | locked | locked | locked | free |

Paint is not matched under either mode: it has never been part of the
signature.

One switch for the whole session, not per entry. **Several allowed builds of
the same car - a choice of engine, a choice of gearbox - is not a third mode**;
it is several entries under **Parts**, one per build. Capture each variant you
want to permit.

Refusals name the mode in force, so a driver is told whether the thing to undo
is a part swap or a tune.

### How it is enforced

Enforcement runs on two layers, because the server has no vehicle
introspection of its own:

- BeamMP's `onVehicleSpawn` / `onVehicleEdited` hooks cancel any car whose
  **model** is not on the list before it exists for other players.
- Each client reports its configuration signature on spawn and whenever its
  setup changes. One that the current mode does not match gets the vehicle
  **deleted**, and the driver told through three channels: the panel banner,
  the notice strip, and BeamNG's own **Messages** HUD app (which needs nothing
  open, so it reaches a driver running without the app or the chat).

The deletion happens **on the client**, which is not where it looks like it
should. `MP.RemoveVehicle` wants BeamMP's own per-player vehicle id, and the id
traveling on the config report is `veh:getID()` - a BeamNG game object id from
an unrelated numbering space. The client knows which car is its own without any
id, so it is sent the order instead.

**A client can lie.** The parts live on the client, so this is a rule for a
league running in good faith, not anti-cheat: what it costs a driver is
modifying the mod, rather than opening the parts menu.

### Admins, and the grid audit

**Nobody is exempt, admins included.** An admin in a car that is not on the list
is refused and has it deleted on exactly the same terms as any driver.

**So build the list with Enforcing switched off.** With it on, an unapproved car
is deleted a second or two after it spawns, which is before there is time to
press capture. The panel warns about this next to the switch. An admin without a
car can always still reach the panel to turn enforcement back off, so this
cannot lock anybody out of their own server.

An empty list never enforces anything either, so the first capture of a session
needs no special handling.

Non-compliant drivers appear in the panel's **Not on the list** block, and are
named in the line **Start Countdown** sends to whoever pressed it. That audit
**reports and does not act**: taking a car off the grid during the countdown
does more damage to the race than starting with one wrong setup in it.

### When a car that should be allowed is refused

The refusal a driver sees names the rule, which is all a driver can act on. The
**server console** prints the two signatures side by side - what the driver is
in, and what the list holds for that model - which is the comparison that
actually failed. Start there.

The usual causes are a BeamNG update that renamed parts (the rejection says so
if the entry recorded a different build) and a capture that was never stored,
which now reports itself rather than failing quietly.

### Upgrading an existing garage.json

Nothing to re-capture. A file written before parts and tuning were split loads
in **Parts** mode - the looser of the two, so an upgrade cannot silently start
rejecting tunes that were already being allowed - and the parts half of every
entry is recovered from the signature already on disk.

### Settings apply themselves

**Laps**, **Max resets** and the qualifying **Laps / Minutes** boxes have no Set
button. Type a number and it applies - half a second after you stop typing, or
immediately if you click away from the box. The value the server actually holds
is displayed beside each field, so what is in force is always readable.

A Set button earns its place when an edit is several fields that only make sense
applied together, which is why the **cup points tables keep theirs**. A single
number that is cheap to send and trivially changed again is not that, and
forgetting to press the button is a silent failure that turns up as the wrong
race distance.

Two consequences worth knowing:

- **An empty box is never sent.** It means "still typing", not zero and not
  unlimited - clearing `5` to type `12` must not spend the moment in between
  running an open session or an unlimited reset allowance. Type `-1` for
  unlimited resets, or `0` for an unlimited qualifying session.
- **Settings stay put for the whole event.** They live on the server, not in
  the app, and nothing but changing them again moves them: they survive Start
  Quali, Generate Grid, a countdown and **Reset**, and every admin's panel
  shows the same values because all of them are reading the server's. (They are
  *not* written to disk - restarting the server returns them to their
  defaults. Track layouts, the garage, the roster and the cup are the things
  that survive that.)

### What a checkpoint looks like

Two different drawings of the same checkpoint, for two different jobs:

- **In the editor** - the flat rectangle the crossing test actually uses, with
  its number and a direction arrow, drawn for the whole route at once so a
  layout can be checked. White is the start/finish line, orange the rest of the
  route, green your next target, violet the joker, amber a pit stall.
- **On track during a session** - BeamNG's own **gate poles**, two columns
  either side of the racing line, on the gate you are heading for and the one
  after it. Only those two: a whole circuit wearing poles is a wall of gates.

Both are as bright as their color allows. The poles take BeamNG's palette and
lift each color to the luminous version of itself - the hue is the engine's,
and the meanings a BeamNG driver already knows still hold, but a marker that was
a dark silhouette against a pale road or a low sun is now plainly a marker. The
one pole that is not merely brightened is **the gate after the one you are on**:
the engine ships that mode black, because in its own races it is not your
concern yet. This mod puts a marker there specifically so the line through the
corner reads before you arrive, so it is painted the orange of the route ahead
instead - visible, and a shade under the gate actually being aimed at.

### Driver UI (non-admins)

- **Checkpoint gates are drawn for everyone.** During a countdown, qualifying
  session or race the 3D oriented bounding boxes are visible on every
  connected client; the Hide/Show Gates toggle now only applies outside a
  session, where it exists to keep the editor view tidy.
- **Minimal mode.** A player who is not logged in as an admin sees *only the
  leaderboard* while a session is live - header, session controls, editor,
  derby panel, login bar and all panel backgrounds are removed from the DOM.
  During a derby the leaderboard shows the derby standings instead.
- **Collapse it when you are not using it.** The **▲** button in the header
  or on the driver bar, mid-session - folds the whole app down to that one
  line, and **▼** brings it back. The bar that stays still shows the phase, the
  clock and your own lap, so a collapsed HUD is a status strip rather than
  nothing at all.

  **Alerts are not collapsed away.** A countdown, an out-of-bounds timer, a
  rejected vehicle, a pit or ghost readout and the regulation notices all keep
  showing: collapsing hides the panels you go looking for, never the messages
  that come to find you.

  **And the ones that matter leave the app entirely.** Every surface above is
  drawn by Race Manager, and the server's chat lines need the chat window open,
  so a driver running with the app minimised and chat closed saw none of it.
  Notices a driver would have to **act** on are mirrored to BeamNG's own
  **Messages** HUD app, which needs nothing open: the flags, the out lap, being
  put out of a session, running out of resets, a refused car, a joker ruling,
  where you start, a pit call and the derby.

  The running commentary is deliberately *not* mirrored - a reset count, a
  fastest lap, a ghost state, a name change. Pushing everything through is how a
  channel that has to be read becomes one that is not. Each kind gets its own
  icon and its own slot there, so a repeat replaces rather than stacks and a pit
  call cannot wipe a red flag.

  The state is remembered in `localStorage` like the size and the opacity, so
  it survives the pause menu and the next session.
- **Resize & fade - everywhere the app renders.** Drag the grip in the
  bottom-right corner to resize the panel, and use the ◑ slider to set its
  background opacity so it does not obstruct the view. In minimal mode the
  grip and slider sit on the leaderboard and the driver bar; everywhere else
  (admins on any tab, and drivers between sessions) they sit on the whole app
  panel and in the header, with ⤢ to undo a drag.

  The opacity is one shared setting, so fading the HUD means the same thing in
  every view. The two sizes are stored separately - the leaderboard alone and
  the full panel with its chrome are different things to measure, so resizing
  one never disturbs the other. Everything is remembered in `localStorage`.

  **The grip sizes the panel inside the app window, it does not resize the
  window.** BeamNG paints every HUD app into a fixed-size box
  (`.ui-app-host`, `overflow: hidden`) whose size belongs to the HUD app
  layout editor - *Pause → System → HUD Apps*, edit mode, drag the app's
  corner - and an app has no supported way to grow its own box. So the grip
  stops at that edge rather than dragging into clipped, unreachable space.
  **To make Race Manager bigger, enlarge the window in the layout editor
  first, then drag the grip out to fill it.** Shrinking the window in the
  editor pulls an oversized stored panel back in automatically.

  The driver bar also shows live joker/reset status and keeps a 🔒 button so
  the login prompt is always reachable.
- **The status bars have a fixed layout in all three panels.** The first row is
  the live status run - phase, checkpoint, distance, clocks - and the flag and the
  two window controls (the size reset and the collapse) are **pinned to its
  right-hand corner**, in the same place at every panel width and in every state. Everything else sits **below it, left aligned**, and takes a
  third row only when it will not fit on the second: the rules in force
  (`JOKER`, `RESETS`, the out-lap notice), the states, the badges, and the admin
  controls with the fade slider.

  The split is not cosmetic. Every readout on the run changes width as it changes
  value, so with the controls immediately after them the buttons moved while you
  were reaching for one, and the wide text decided where the row broke.
  Collapsing does not rearrange it: that removes the panels *below* the header,
  and the header keeps the same layout folded or not, so the corner pair is in
  the corner in every view.
- **One slider fades every surface.** The ◑ control drives the panel fill, the
  header's tint and its bottom rule together. It used to drive the fill alone, so
  a HUD faded to nothing still had a solid orange band across it.

### Broadcast board (spectators)

A board for someone **watching rather than driving**: the whole field at once,
who is out and why, the championship, and a camera you steer by clicking a name.
It is not another view of the leaderboard - the questions are different. A
driver's HUD answers *where am I, what lap, how many resets left*; a
broadcaster has none of those.

**Getting to it.** Sit the session out with **👁 Spectate** (or finish the race
- a driver whose car has been taken is a spectator too), then press **📺
Broadcast**. The button is in the header between sessions and on the driver bar
during one, and it is offered to **admins as well**: the person running the race
night is usually the person streaming it, and spectating is an entry decision
that has nothing to do with rights.

**It is the whole app while it is on.** The header, the session controls, both
editors, the derby panel, the login bar, the leaderboard and every alert overlay
come off the screen - a broadcaster is not in the session, so a pit readout or
an out-of-bounds timer belongs to somebody else and would go out over the
stream. Everything worth keeping is on the board's own strip: phase, race clock
or qualifying clock, the lap the leader is on, the session flag, and who holds
the fastest lap. **✕** on that strip is the way back.

**The board does not outlive the spell that showed it.** Being out of the field
is two things wearing one name: pressing **Spectate** is a decision that lasts,
while taking the checkered flag makes you a spectator for the few seconds
between your finish and the results. So the switch is cleared when you rejoin
the field - press **📺** once per session you sit out, and merely finishing a
race never puts you in the board.

It *is* remembered while a spell lasts, which is why the setting is stored at
all: BeamNG rebuilds this app whenever the HUD layer goes (opening the pause
menu does it), and without that the board would vanish every time you paused.

**Click a name, get the camera.** Clicking any driver switches to their car and
puts you in **orbit**. That is the one place in the mod that sets a camera
*mode* - everywhere else the view is the driver's own business and is left
alone - and it is deliberate here, because a chase camera on that car is exactly
what the click was asking for. The row you are actually watching is marked with
a 👁 and a highlight; that comes back from the game rather than from the click,
so a name whose car is not loaded on your machine yet leaves the marker where it
was rather than claiming a camera it never got.

Drivers who are **out** get their own block under the field, with the ruling
that put them there - the same text the results file records - and the place
they were running in when they stopped. Their names are clickable too: the car
is still where it stopped, and the wreck is often the shot. Drivers who are
merely **sitting the session out** are counted at the foot of the board rather
than listed, because a board that puts them among the runners is claiming a
bigger field than the one on track.

**Gap and interval.** `Gap` is seconds behind the leader, `Int` seconds behind
the car directly ahead. Both are read at *this driver's own last checkpoint* -
see [Time behind](#time-behind) for what that means and what it costs. Beside
the position you also get **places gained or lost since the grid** - a green
`+2` or a red `-1` - which answers a different question: not how far away the
car ahead is, but how the race has moved since the lights.

**Derbies get their own table.** A [Demo Derby](#demo-derby-parallel-game-mode)
is a parallel game mode with its own field, its own clock and its own way of
going out, and the racing field is untouched by one - so while an arena is
running the board shows the derby and not the race that happened before it.
Names click through the same way; the wreck is usually the shot.

**Points.** With a [cup](#cup-points) running, a **Race / Points** pair appears
on the strip. The points view is the championship as the server ranks it -
position, driver, rounds scored, wins and total - and it computes nothing
itself, which is the same split the admin cup panel keeps. A standings row is a
*roster* identity rather than a connection, so it is clickable only while the
driver it is bound to is on the server. Opening the board (or switching to
points) pulls the standings, so a board opened halfway through a race night
shows the real table rather than an empty one.

The board is resizable and fades with the ◑ slider like every other panel, and
it keeps **its own stored size**: a stream graphic and a driver's leaderboard
are not the same thing to measure.

## Cup points

A **cup** is a championship run across several events. It can be **all races,
all derbies, or a mixture of both** - points accumulate per driver and nothing
but ending the cup clears them.

It is **off by default and entirely optional** - with no cup running, races
behave exactly as they do without the feature. Everything below lives on the
**Cup** tab under Race mode.

### Running a cup

1. Give every driver a **display name** first (Admin tab). Points attach to the
   saved driver, not to a connection - see [Display names](#display-names).
2. **After any reconnect or server restart, assign them again.** BeamMP reissues
   guest names at random, so nobody is recognized automatically and the Cup
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

Points come off the **finishing position**. A driver who did not finish - DNF or
disqualified - scores nothing rather than being paid for last place.

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
series pays for is a league decision - so it is a setting.

The place a driver was **running in when they stopped** is recorded whatever
ended their race - a disconnection, the admin closing the session, anything
added later. It appears in the results file beside the reason (`DNF -
Disconnected (was P2)`), and three rules decide what it is worth:

| Setting | A DNF scores |
|---|---|
| **Nothing** (default) | 0, as it always did |
| **Classified place** | its place in the final order, below everyone who finished |
| **Place when they stopped** | the position it was actually running in |

**Place when they stopped** can pay two drivers for the same position - a
retirement from second and a finish in second both score second. That is exactly
what the option is for; pick one of the other two if it isn't what you want.

A DNF is **never counted as a win**, however it is scored, and a
**disqualification always scores nothing** - that is what the penalty is.

### Qualifying points

Off by default. Give the quali table some values and qualifying starts scoring,
ordered by **best lap** - not by grid slot, which at the end of a qualifying
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

> **Everybody scores.** In a race, a driver who did not finish scores nothing
> not finishing is a failure to produce a result. In a derby, being eliminated
> *is* the result, and the position it produces is worth points.

**Turn derby points off** and derbies are simply not part of the cup: no round
is banked and no derby bonus is paid. Races go on scoring normally.

**Winning is not the same as finishing first.** A derby an admin ends early is
topped by whoever was still running, but nobody was the last one standing - so
that driver takes P1 points without it counting as a win, and without the
last-man-standing bonus.

### Bonus points

Bonuses belong to a **discipline**: race bonuses are only ever paid on a race
and derby bonuses only on a derby, so a derby can never collect a fastest-lap
bonus. Each is worth whatever you set it to and **worth nothing at zero**.

**Races:**

- **Fastest Lap** - the quickest lap of the race.
- **Halfway Led** - first to complete the half-distance lap. A one-lap race has
  no half way and awards none.
- **Hard Charger** - the classified finisher who gained the most places from
  their grid slot.

These are the same three the results file already reports; the cup consumes that
answer rather than working it out a second time.

**Fastest lap rule** - by default the fastest lap bonus is withheld from a driver
who did not finish. Switch it to *Any driver* if you would rather not.

**Derbies:**

- **Last Man Standing** - awarded only when somebody actually survived. A derby
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
| **End Cup** | ❌ - this is the only thing that clears them |

Cup state lives in `Resources/Server/RaceManager/cup.json`, written on every
change. It is deliberately **not** in the `results/` folder, because
[Clear Results Cache](#step-7--results) deletes everything there.

### Standings

**Race and derby are kept separate, and summarized together.** The default
**Combined** table shows events scored, wins, race points, derby points, manual
adjustments and the grand total - so a total can always be accounted for.

Once a cup has held **both** kinds of event, two more tabs appear:

- **Races** - races scored, race wins, position points, qualifying points and
  race bonuses, ranked on the race total alone.
- **Derbies** - derbies scored, derbies won outright, survival points and derby
  bonuses, ranked on the derby total alone.

A mixed cup therefore contains a race championship and a derby championship as
well as an overall one, and you can read any of the three. A cup that only ever
held one kind shows just the combined table, without an empty column for the
discipline it never ran.

### Cup points in the results file

When a cup is running, every results file ends with the round that event
banked - so the standings leave the game with the result, instead of being
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
  position - the table is the standings, with what each driver scored today
  broken out beside their total.
- **Race / Quali / Bonus** are the parts of this round's score; **Round** is
  their sum. A driver who was not in this round shows `-` in all four rather
  than `0`: not scoring and not being there are different facts.
- Bonuses are **listed by name and recipient** underneath. A `+8` in a column
  does not say what it was for, which is the question somebody checking a
  championship a month later actually has.
- Manual adjustments, if any, are listed the same way - a total nobody can take
  apart is a total nobody can check.
- The numbers come from the cup's own tables, so the file and the Cup panel can
  never disagree about a total.

A race night with no cup running produces exactly the results file it always
did; the section is simply absent. Qualifying does not get one either - its
points are [held, not banked](#qualifying-points), and they appear in the
**Quali** column of the race that banks them. Nor does an event that scored
nothing (a cup that is switched off, one at its round cap, or a derby in a cup
whose derby points are off): the file reports the round that was actually
banked, never "the round the cup is on".

Ties break on wins. Manual adjustments sit outside both disciplines - a penalty
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
> rather than posting a compensating adjustment - the breakdown should describe
> what actually happened. The cup's round count is deliberately left alone;
> renumbering later rounds to close the gap would hide the correction.

## The admin panel

**One tab row**, and the panel a tab opens decides everything under it:

| Tab | What it holds |
|---|---|
| **Race** | Race length, reset ruleset, joker lap |
| **Grid** | Qualifying rules and how the starting grid is filled |
| **Track** | The checkpoint editor, the starting-grid builder, and saved layouts |
| **Garage** | Allowed vehicles and setups |
| **Cup** | Championship scoring, bonuses and standings |
| **Derby** | Demo Derby rules, entry, live standings and the arena editor |
| **⚙** | Master password, results housekeeping |

**Session controls stay above the tabs** and are never one click away: Start
Quali, Generate Grid, Start Countdown, End Session, Reset, and the **Track
layout picker**. Selecting **Derby** swaps them for Form Up, Start Derby and End
Derby, and swaps the board underneath for the derby standings - so a *Load
Layout* button never sits over a derby nobody is setting up.

This replaces a two-row arrangement: a mode bar (Race / Derby / Admin) over a
per-mode sub-tab strip. Both rows were answering the same question - which panel
am I looking at - so an admin picked twice to reach one place and paid a row of
height for each question. Two duplications went with the fold: **Cup** was
listed under Race *and* Derby purely because it had to exist in both modes, and
**Editor** meant the checkpoint editor or the arena editor depending on where
you were. The race editor is under **Track** now and the arena editor under
**Derby**, beside the controls each belongs to.

Nothing was removed. The tab you were last on is remembered.

### The board sits above the setup

The leaderboard used to be the last thing in the panel, under every settings and
editor panel, so it took whatever height was left - about a tenth of the app,
with a race running in it. It now sits directly under the session controls, and
the setup panels scroll below it.

**And it folds away entirely while a session runs.** Once the lights go out, an
admin's settings and editor panels are replaced by a one-line strip, and the
board fills the panel. Drivers have had this since free practice shipped (their
panel becomes the board and their own numbers); admins never did, and an admin
is the one person who cannot simply close the app.

The strip carries two ways out: **Show** opens the setup for the session in
front of you (and closes again when the session changes), and **Keep open**
turns the behavior off for good. Like the collapse and the opacity, it is
remembered.

Both modes have an **Editor** sub-tab, and each one is a *render gate* as well as
a panel: opening it is what puts that mode's authoring visuals in the world, and
they belong to the admin who opened it. The **Race Entry** bar stays visible in
every mode, because it is one entry list - a driver who is spectating sits out
both, and nobody has to enter anything twice.

**The leaderboard at the bottom follows the mode too.** In Race mode it is the
race (or qualifying) table; in Derby mode it is the **derby standings**, on both
derby sub-tabs - so the field stays on screen while you are building an arena.
There is one copy of each board in the app, not one per panel.

A **driver's** leaderboard is not driven by the tab row, which they never see:
it follows the session. Once a derby forms up, their board is the derby
standings, through the countdown and the derby itself.

## Demo Derby (parallel game mode)

A completely separate last-man-standing mode, isolated from the circuit
racing systems above (own server events, own UI panel, own results files
running a derby never touches qualifying/race state). Pick the **Derby** tab;
its controls take the place of the race controls above the tab row, and its
arena editor is on the same tab. Race controls are not shown while you are on
it, and derby controls are not shown anywhere else - see
[The admin panel](#the-admin-panel).

1. **Set the rules**: *OOB timer* (seconds allowed outside the arena,
   default 5), *Demolished timer* (seconds a car may sit stopped before
   elimination, default 10) and *Max resets* (per driver per derby: `-1`
   unlimited, `0` none, `N` allowed - enforced exactly the way the race reset
   limit is, dead reset keys included), then **Set Rules**. When resets are
   limited the derby standings gain their own `Rst` column.
2. **Build the arena** on the **Derby Editor** sub-tab. There are two editors
   for it, and they produce the same thing - an ordered perimeter every client
   polices against - so pick whichever suits the ground:

   **▭ Rectangle.** Stand your car where the middle of the arena should be and
   the four corners are pulled out around you. **Set Center Here** re-centers it
   on your car at any time, keeping the size. Three sliders do the rest, each
   with a number box beside it, the same pairing the per-gate size editor uses:

   - **Width** and **Length**, 10–500 m, the full span across the arena.
     **▣ Square** links the two so one slider drives both.
   - **Rotation**, 0–90°, to line the arena up with the ground it sits on. A
     rectangle repeats every quarter turn - 90° just swaps width and length.

   The four corners all sit at the **center's height**, so on a slope the arena
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

   **Wall height** (2 to 30 m) and **Wall depth** (0 to 30 m) belong to both and
   are **visual only**: how far the walls are drawn up from the boundary and down
   below it, never what they enclose. The out-of-bounds test is flat, so neither
   changes who is in or out. Height decides how easily a driver sees the edge
   from inside a car; depth decides whether the wall still reaches the ground
   where the ground drops away, which on uneven terrain it previously could not,
   the drop being fixed at 1.5 m with no way to change it.

   Optionally place a **starting grid**: drive to each slot facing the way the
   car should point and press **+ Start Position** (slot 1 first;
   **Clear Start Grid** starts over). **Hide/Show Arena** keeps the setup view
   clean.

   A rectangle's corners are **derived** from its center and extents, so they are
   not individually editable - the sliders are how it is changed, and the marker
   list is only shown for a drive-and-place arena. Those markers are listed under
   the controls - `M1…Mn`, with `P1…Pn` for the start slots - and every entry
   stays editable, exactly the way the
   [starting grid](#placing-the-starting-grid) does. Click one to open its
   controls:

   - **Go** puts your car on that entry. A start slot uses its own facing; a
     boundary marker has none, so you keep the heading you already had.
   - **Move Here** moves that one entry to where your car is standing now.
   - **✕** deletes it; the perimeter (or the grid) closes up around the gap and
     everything else keeps its number.

   Fixing marker 2 of twelve no longer means clearing the arena and driving the
   whole perimeter again. Deleting can take the arena under three markers - it is
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
   is running - the arena cannot move under the drivers.

   A rectangle is stored as **both** its shape and the four corners it produced,
   so it loads back editable by slider - and stays readable by anything that only
   understands the polygon. **Arenas saved before rectangles existed load exactly
   as they always have**, as drive-and-place arenas: there is no migration step
   and nothing is lost.

   **The arena is drawn two different ways**, because laying one out and driving
   in one are different jobs - the same split the checkpoint editor already makes
   between an authoring gate and a race one:

   | | Derby Editor (admin, panel open) | During a derby (everyone) |
   |---|---|---|
   | Walls | Solid enough to read as a surface | **Translucent** - you can see the car on the other side of one |
   | Corner posts and rails | Full height, bright | A dim ground rail and a short post |
   | Floor | The enclosed area filled in, so the limits are exact - *rectangles only; filling an arbitrary polygon safely means triangulating it, and the cheap way paints outside a concave shape* | None |
   | Labels, corner numbers, center crosshair, size readout | Shown | **None** |
   | Start slots | All of them, numbered | Only your own, and only until the derby starts |

   The **boundary itself is always drawn** during a derby - leaving it is what
   eliminates you, so you have to be able to see it - but nothing authoring-only
   is. Closing the Derby Editor is enough to get the driving view: you do not
   have to start a derby to see what your drivers will see.
3. **Entry** is the same one switch the circuit races use: every connected
   player is in the field unless they have pressed **Spectate**, which is how
   the derby has always behaved by default. Somebody who only wants to watch
   sits out both modes with one press - worth knowing that being entered means
   losing your car to freecam the moment you are eliminated. The counter shows
   how many would be in a derby started right now, and the field is locked from
   Form Up onward.
4. **Form Up**, then **Start Derby** - the same two steps a circuit race uses.
   **Form Up** stands every participant on a start slot and **holds them there**;
   the header reads *Formed up - held*. **Start Derby** then runs a synchronised
   3‑2‑1‑**GO!**, and that same broadcast releases every car at once, so nobody
   can creep away early. A driver with no slot placed for them is held where
   they are rather than getting a free run at the field. **Abort Start** puts
   everyone back if you formed up by mistake - no result is recorded.

   The arena, the timers and the entry mode are all **locked from Form Up
   onward**, not just once the derby is running: cars are already standing on
   their slots by then and the ground must not move under them. Set the rules
   before you form up.
5. Once the lights go out each client polices **itself**, checking its own
   vehicle against the arena polygon (ray-casting point-in-polygon) and its own
   speed:
   - Leaving the arena flashes **OUT OF BOUNDS! RETURN IN X.Xs** - return in
     time or you're **Disqualified**.
   - Sitting still flashes **VEHICLE STOPPED! DEMOLISHED IN X.Xs** - get
     moving or you're **Demolished**. Disconnecting counts as Disqualified.
   - **With Lives set above 1**, the stopped timer spends a life instead of
     ending your derby: you go back to the slot you started from and keep
     playing, and both timers arm again as you land. Only the stopped timer
     spends a life - out of bounds is still an outright elimination.

     The returning car is **ghosted on every client** for four seconds, long
     enough to land, settle and drive off a slot that may well have somebody
     else's wreck parked on it by now. It waits longer if it has to: a car with
     another inside it does not get its collisions back until the space is
     clear.
   - An eliminated driver's car **stays in the arena as a rolling chassis**.
     Their driving inputs are filtered and every one of them is zeroed -
     throttle, brake, steering, clutch - so a driver knocked out mid-corner does
     not leave the engine screaming at a throttle nobody can lift. The **parking
     brake is released, not applied**: a wreck is meant to be an obstacle the
     survivors can shove and pile into, and one bolted to the floor is a wall.
     **The engine is switched off** - a car disqualified for leaving the arena
     was driving a second ago, and zeroed pedals still leave an engine that
     idles an automatic forward - so it coasts to a halt and stays where it
     stops. It is started again when the derby releases everyone. The car stays
     solid and free to roll; the only thing taken away is the driver's own
     ability to move it.
     The driver stays **in** it, and the camera is not touched - tab moves them
     around the arena like any other spectator. Nothing is removed and nothing is
     respawned: an elimination is a change of state, not an entity destroyed and
     rebuilt. (It used to delete the car and force freecam, which in BeamMP
     deleted it for *everyone* and re-asserted the camera once a second, so
     watching anybody was undone within the second.)
6. The driver table shows who's still in, who's out (with reason and
   elimination time) and the winner - under their **display name** if an admin
   set one (see *Display names* above), in both the standings and the exported
   results. When exactly one driver remains the
   server ends the derby, announces the **winner** in chat, and writes
   `derby_results_YYYY-MM-DD_HH-MM-SS.txt` to
   `Resources/Server/RaceManager/results/` (winner first, then everyone else
   in reverse elimination order). **End Derby** force-ends a running derby;
   pressing it again after the finish resets the mode for the next round.
