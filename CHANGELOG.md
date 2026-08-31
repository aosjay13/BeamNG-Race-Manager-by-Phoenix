# Changelog

Notable changes per release. The version here is the same number as the git
tag, the packaged zip, and the build stamp the app shows - see the note in
`server/RaceManager/main.lua` for why those four have to agree.

[← Back to the README](README.md)

## 0.11.0 - Race control: the pace lap, the caution, and heats into a feature

Three ways to run a race night that this mod could not run before, and they are
meant to be run together: heats into a feature, started behind the pace car,
neutralised by a caution the field races back to the line for.

### Added

- **The pace lap.** Switch **Pace lap** on in Race settings and **Start
  Countdown** becomes **Start Race** on the grid. The field is released
  immediately under a **yellow flag** -- no countdown -- and told, in chat and on
  screen, to maintain position at **40 mph / 64 km/h**. It runs a formation lap,
  and the **green flag falls automatically** as the leader comes back within
  **10 m** of the start/finish line: waved on the approach, which is what a
  marshal does, rather than once the leader is already past.

  **The two start buttons are alternatives and only one is ever on screen.**
  Counting a field down to GO and then telling it to hold position at 40 mph is
  two instructions for the same moment, and a driver obeys whichever of them they
  read. The server refuses whichever button the session is not set up for.

  **Mechanically the formation lap is an out lap**, which is a rule this plugin
  already had -- a lap that is driven and not scored, ending at the line for each
  driver in turn. That is what settles the awkward part on its own: the green
  falls once, for everybody, while the field is strung out around the circuit,
  and each driver's own crossing is still what starts their lap 1.

  It is **not one of your laps**, and this is the one place it differs from the
  out lap a head-on grid owes. That one is a *racing* lap that merely sets no
  time, so it comes out of the distance; a formation lap is not a racing lap at
  all, so it goes on top. A 5-lap race behind the pace car is a formation lap
  plus 5 racing laps -- six crossings.

  **The board counts racing laps, not crossings.** The Lap cell reads `PACE`
  while the formation lap runs, and the leader on the last lap of a five-lap race
  reads `5/5`. Counting the crossing would have read `6/5`: the numerator
  counting crossings against a denominator counting laps of the race, which are
  only the same number when no lap is given away. Qualifying's out lap has always
  been counted out the same way. The leaderboard, the broadcast strip and the
  results table go through the same two helpers, so a commentator never reads out
  a lap the table does not show. The results file still names the distance in its
  header, because `Race distance: 5 laps` above a Laps column is worth settling
  on the page.

  **A timed race's clock starts at the green, not at the release.** Ninety
  seconds of forming up still leaves the full ten minutes of racing, and the
  header's countdown does not move until the green falls. The *session* clock
  keeps running underneath it and is never wound back -- reset-ghost end times
  are expressed on it, and a client that re-anchored to a clock that had gone
  backwards would show a car ghosted with a countdown that never reached zero.

  **Two things stop it hanging.** A red flag holds the green, so a leader who
  coasts the last few meters to the line under one does not start the race by
  arriving; and the **Green flag** button ends the pace lap at any time, which is
  why there is no timeout to guess at -- a field that has crashed or stopped
  never brings its leader back to the line, and the marshal who can see the track
  is better at judging that than a clock. If every driver has already crossed the
  line the green falls on its own: a yellow nothing can lift is worse than an
  early green.

  **Races on circuits only.** Qualifying has no field to form up, so a grid
  formed by *Start Quali* keeps its countdown with the rule still armed for the
  race after it. A point-to-point sprint stage has no lap to form up on: the
  switch is grayed out, the server refuses it, and loading a sprint stage
  switches it back off and says so -- a switch reading ENABLED above a button
  that has silently changed back is worse than either state.

- **The caution, and the field races back to the line.** A full-course yellow
  called mid-race, in two halves:

  1. **Caution** puts the yellow out and tells the field to **race back to the
     line**. Nothing is frozen: the board goes on re-sorting, because on the road
     the race is still on.
  2. **The leader's crossing makes it official** and names the lap it was called
     on. Every other driver locks their own place as they complete that same lap.
     First back to the line is first.

  Freezing the board at the button instead would score the field at a moment
  nobody on track can see, and hand a place to whoever happened to be
  mid-overtake when a marshal reached for the mouse. Racing back to the line is
  the rule drivers already understand and the one they can act on.

  **The freeze is the feature**, and it is the only half of a caution this plugin
  can enforce. The server has no physics: it cannot slow a car, close a gap or
  line a field up behind the leader. What it *can* do is stop positions changing
  -- which is exactly what a real caution does to the timing sheet, and is a
  scoring rule rather than a movement one. Without it, a driver who obeys the
  instruction to close up is shown **gaining places for obeying it**.

  **Lapped cars go to the bottom**, in the order the lapped cars came back,
  however close behind they are sitting. Laps down at the caution lap is the
  first key the frozen order compares, so a car a lap down cannot appear to be
  running third because it is physically third in the queue. That is how a
  caution board reads everywhere.

  It is deliberately **not** a ruling on any individual overtake -- nobody is
  penalised and no incident is judged. The flag note in `main.lua` said an
  automatic ruling would need "a second running order that survives the caution
  and reconciles on green"; this is that order, and it does only that.

  **The restart is called, not taken.** Pressing **Restart** says *the current
  lap is the restart*, and the green falls as the **leader reaches the line** --
  so the field is packed up and looking at it rather than being waved off round
  the back of the circuit at whatever moment the marshal decided. Two paths drop
  it, and the second exists because the first can be starved: a distance watch
  ten meters short of the line, and the leader's crossing as the backstop for a
  track whose length the server never learned or telemetry that never landed near
  the line.

  **Cancel restart** waves the call off. Only the call goes -- the race stays
  neutralised, the board stays frozen and the caution laps go on counting.
  Pressing Caution again would count a second yellow and re-freeze an order that
  never thawed, which is why the wave-off is its own control.

  Three header badges rather than one, because **RACE BACK TO THE LINE**,
  **POSITIONS FROZEN** and **RESTART THIS LAP** are three different instructions
  to a driver, each with its own on-screen notice on the edge it happens.

  A caution never outlives its session: one frozen position left standing is the
  first thing the comparator reads, so it would silently order the next race,
  which is invisible until somebody wins a race they ran fourth in. The results
  file records **how many cautions there were and how many laps ran under them**
  -- a race with four yellows in it used to read exactly like a clean one.

- **The free pass ("lucky dog").** Off by default; switch **Free pass** on in
  Race settings. When the last car has locked, the **highest-placed car a lap
  down** takes its lap back and restarts at the **tail of the lead lap**.

  It goes to the *first car a lap down* rather than the car furthest back -- the
  car that was actually racing the leader when the yellow fell. Handing it to
  whoever is deepest in the field would give it to the same slowest car every
  single caution, which is not a prize anybody is racing for.

  The credited lap is sent to that driver's client as well as counted on the
  server. That is not decoration: the server drops any progress report whose lap
  number disagrees with its own, so a lap credited on one side only would quietly
  kill that driver's live position and gap for the rest of the race.

- **Heats and transfers.** Run the night as several short heats and then a
  feature, with the heat results setting the feature grid.

  **The draw is a serpentine off qualifying time** -- 1st to heat 1, 2nd to heat
  2, ... Nth to heat N, then *back along the row*. A straight round-robin puts
  the four fastest drivers on four different poles and the four slowest all at
  the back of their own heats, which makes the heats incomparable and a transfer
  worth more out of one than another.

  **A heat is an ordinary race run by a subset of the field**, and one function
  carries the whole idea: `isEntrant` returns false for a driver who is not in
  the heat being run. Everything downstream -- forming the grid, the online
  purge, the respawn, the garage audit, the entrant count -- already routes
  through it and needed no idea heats exist. A server with no heat program
  configured is untouched by every line of it.

  **Heats get a lap count of their own.** **Heat laps** in the Grid tab, 0
  meaning "the same as the race". Heats are short and features are long --
  eight-lap heats into a thirty-lap feature is the ordinary shape of a heat night
  -- and one shared lap box would mean retyping the number between every session
  of the evening, which is a thing to forget once and run the feature over eight
  laps. Enforced on both sides: the client waves its own white and checkered
  flags off its copy of the lap target, so a heat whose length only the server
  knew would be flagged at the feature's distance on every screen.

  The feature grid is the transfer order: **heat winners on the front row, then
  all the seconds**, interleaved by heat, which is what makes a heat win worth
  having and stops one strong heat filling the whole front. Drivers who did not
  transfer still race, behind those who did -- excluding them is the other
  reading and it is the wrong default for a league night, because it sends half
  the server to the spectator seats for the main event.

  A disqualification never transfers, whatever place the sort left it in: the
  heat result is recorded after the joker ruling runs. Heat results are mirrored
  into the driver roster, so a driver who drops out between heat two and the
  feature comes back with the transfer they earned rather than a back-row start
  and no explanation. Qualifying is never split -- the draw is made *from*
  qualifying times, so a qualifying session that let one heat out would be
  drawing heats from times set by the drivers it had already drawn.

- **Three new suites**, and each one tests the thing that would otherwise pass by
  accident.

  **`tests/pace_test.lua`** (84 checks): the arming latch, the ticks before any
  client has reported a position (a leader search that skipped those drivers
  finds nobody, reads it as "the field has all crossed" and answers with an
  instant green), the distance arithmetic, the timed-race clock, the red-flag
  hold, the manual green, qualifying declining to pace, and Reset Session
  dropping the running pace lap while keeping the league setting that armed it.

  **`tests/caution_test.lua`** (104 checks): that calling the caution freezes
  *nothing*, that a lapped car back to the line first is still classified last,
  that a red holds both restart paths, and that no pending call or locked
  position outlives its session. The freeze itself is tested by making the field
  *overtake* under the yellow and asserting the board does not move -- a test
  that only checked the flag colour would pass against a caution that froze
  nothing at all.

  **`tests/heats_test.lua`** (106 checks): three full heats and a feature, which
  is what caught the position bug below. A single-heat test passes either way.

### Changed

- **One instrument per instruction.** The advisory Yellow and Green flag buttons
  used to show throughout a race. Beside the Caution and Restart buttons that
  meant a marshal calling a yellow saw two yellow buttons, with only one of them
  neutralising anything, and going green saw two greens with only one of them
  unfreezing the board. In a race the caution *is* the yellow and the restart
  *is* the green, so the advisory pair now belongs to **qualifying**, which has
  no running order to freeze -- there a yellow really is only a hazard being
  pointed at. The pace lap keeps its own manual green: that override is the
  reason a formation lap needs no timeout.

- **Red is one button that lifts what it threw**, in both sessions, and lifting
  it returns the field to whatever it was already under: a neutralised race goes
  back to its caution, a formation lap goes back to forming up. Clearing a red
  used to be a plain green, which on a paced field ended the formation lap
  outright -- waving the race off in the same keystroke that moved the wreck.

- **The release path is shared.** There are two start procedures now -- the
  lights and the pace car -- and everything they have in common (one release,
  one clock reset, one wipe of every per-driver counter) is one function rather
  than two copies. A second release path that forgot a line of it would be a
  race carrying last week's lap counts. The garage audit went the same way, for
  the same reason: an audit that ran on only one of the two buttons would be an
  audit that silently stopped happening for every race started behind the pace
  car.

### Fixed

- **A rival's trailer stayed a ghost for the rest of the session.** When another
  driver reset, their reset ghost was applied to their whole rig -- the car and
  whatever was coupled to it -- but lifted from the **car alone**. The trailer
  kept a `reset` reason nothing would ever clear: `reset` is only cleared in two
  places, the owner's own restore (already rig-wide) and this one. So on every
  client except its owner's, that trailer was intangible for the rest of the
  session -- you drove straight through it -- while its owner saw it solid.

  The two halves had drifted apart because they were different calls,
  `reasonRig` to apply and `reason` to lift. They are the same call now:
  whatever a ghost is applied to is what it comes off. The un-ghost still goes
  through the weld gate per vehicle, so nothing is handed its collisions back
  with a car inside it.

- **Three checks in `ghost_test` had been failing since the trailer support
  landed**, and they were failing on the harness rather than on the mod. The
  stubbed BeamMP vehicle map filed *anything it did not recognise* under the
  rival's player id. That was harmless until the trailer was added to the test
  world -- from then on two vehicles answered to `RIVAL_PID`, `vehicleForPid`
  returned whichever `pairs` reached first, and a rival's reset ghost landed on
  the trailer instead of their car.

  So the three checks that exist to prove a remote rig ghost works were reading
  as broken while it worked perfectly -- and, worse, they were the checks that
  should have caught the real bug above. The map is an explicit table now and an
  unmapped vehicle belongs to nobody rather than silently to the rival.

  The lift is now asserted **with the coupling still in place**, which is the
  real case: a trailer is on the hitch when the ghost expires just as it was
  when it began. The old test dropped the coupling first, so there was no rig
  left to lift the ghost off and nothing to catch.

- **Heat positions were taken from the whole field's classification.** The
  result walk indexed into `raceClassification()`, which is every record the
  server holds -- so by heat 2 the drivers who had already raced heat 1 sorted
  above it, every position was wrong, and because that index was then compared
  against "top 2", **nobody transferred at all**. Counted within the heat now.

  Heat 1 alone passed either way, which is the whole reason the test runs three.

- **`M.setGridMode` would have silently rewritten the new Heats order.** The
  client sanitises the mode on the way out against a list that has to name every
  mode the server accepts, and a mode missing from it is normalised to `quali`
  before the server ever sees it. That is exactly how Reverse shipped as a dead
  button once already; `ui_bindings_test` now derives the list from the template
  and checks the client names every one of them.

### Config

Four new settings in `config.json`, beside the lap count:

- `paceGreenAt` (10 m) -- where the green falls, and `paceArmAt` (50 m), how far
  the leader must first get *away* from the line before that means anything. The
  second is not a tuning knob but a correctness one: **the field starts the pace
  lap standing on the line**, so "the leader is within ten meters of the line" is
  true at the release as well as at the end of the lap. Without it the green
  falls on the tick the cars are let go, and it would look like a working feature
  to anyone testing with a car already circulating. The two are kept in order at
  load: a file with them crossed over gets the arming distance pushed clear
  rather than the pair swapped, because swapping would produce a working pace lap
  the admin never asked for.
- `luckyDog` (false) -- the free pass rule as a server default.
- `heatLaps` (0) -- the heat distance as a server default.

## 0.10.0 - A car shoved on the grid no longer floods the UI

### Fixed

- **A held car off its slot pushed 120 UI updates a second.** The grid hold
  corrects a drifting car every frame, deliberately: landing on the same slot is
  idempotent, and a car whose freeze will not take must not ratchet forward
  between corrections. Only the *talking about it* is meant to be rationed, and
  on two of the three correction paths it was not.

  The settle-window branch had no throttle at all, and it is the one a car being
  shoved actually sits in - `hold.restore` re-arms the settle window every time
  it runs, so the car never leaves that window and the notice fired on **every
  frame**. The drift branch had a throttle it never armed.

  That cost doubled when notices started reaching BeamNG's Messages HUD app in
  0.9.1: one notice is two crossings of the Lua/CEF boundary now, and each wakes
  an AngularJS digest over the whole template. 120 pushes a second, on the grid,
  at the one moment a panel most needs to be responsive.

  **Measured: 120/sec before, 6/sec after.** The corrections themselves are
  unchanged - a car still gets put back every frame.

  Drift corrections are also counted in `hold.corrections` now. They were
  missing from the tally reported to the server, so a car being pushed around on
  the grid reported none of it.

### Added

- **A frame-cost budget for the held grid.** `perf_test` measured a racing frame
  and a countdown frame; the grid hold is the one steady state with a notice
  inside a per-frame function, and nothing was watching it. Two budgets now: 12
  pushes a second, and 4 of them to the Messages app.

  `ui_message` is deliberately left unstubbed in that harness, so `hudMessage`
  falls through to `guihooks.trigger` and the HUD channel is counted inside
  every budget in the file rather than being invisible to all of them.

## 0.9.10 - The race clock stays put

### Fixed

- **The race clock moved between the first and second rows of the bar while it
  was being read.** Every readout beside it is conditional - the checkpoint
  counter, the distance to the next gate, the lap and sector holds all come and
  go mid-session - and they shared one wrapping line with the title, the phase
  and the mode badge. So the line broke in a different place depending on which
  of them happened to be showing, and the clock went with it. A clock you have
  to find is not a clock.

  Two changes, and both are needed:

  - **The live timing run owns a line.** Not a break marker, which only says
    "break here" and cannot stop the run being pulled up onto the line above
    when the things before it are narrow enough that frame. A container with
    `flex-basis: 100%` can never share a line with anything.
  - **The clock leads the run.** Everything that appears and disappears is now
    downstream of the one number that has to stay put, so it no longer slides
    sideways either. It also gets a reserved width, so ticking from 9:59 to
    10:00 does not shove the readouts after it.

  **Both panels, same order.** The admin header and the driver bar carry the
  same run, and `ui_bindings_test` compares them - switching between them must
  not move a number.

### Note

That test had gone quietly blind to this field. It matched the clock by
`formatRaceTime(raceTime)`, and 0.9.6 renamed the readout to `sessionClock()`
when it learned to count down - so the pattern matched nothing, the clock
dropped out of *both* orders, and the two panels went on agreeing about a field
neither of them was checking. Repaired, and the new ordering is
mutation-tested: putting the clock back behind the checkpoint counter fails
three assertions.

## 0.9.9 - The setup actually folds away now

### Fixed

- **The setup panels did not fold away during a session.** 0.9.8 gated the tab
  row and the collapsed strip on `setupHidden()` and left the body they open
  gated on nothing, so the settings stayed on screen. Folding the tabs without
  the panel they belong to is worse than not folding at all.

  If it still does not fold after this, it is BeamNG's UI cache serving a stale
  `app.js` alongside the new `app.html` - `setupHidden` resolves to undefined,
  which reads as "not hidden". The build stamps on the admin tab disagree when
  that happens; a restart clears it.

### Changed

- **A control that is disabled during a race is now hidden during a race.**
  Graying a button out is how a panel says "not now, and here is why" while you
  are setting up. Mid-race it is a row of dead buttons over the one thing being
  watched. **Start Quali**, **Generate Grid**, **Start Countdown**, **Load
  Layout** and the **Race / Spectate** pair all go while a session runs.

  Every condition is the `ng-disabled` one it replaces, unchanged, so nothing
  became reachable or unreachable that was not already. **Retire stays** - it is
  the one entry control that means anything mid-race - and so do the flags,
  End Session and Reset.

  What is left on an admin's screen once the lights go out: the header, the
  flags, End Session, Reset, the board, and a one-line strip.

## 0.9.8 - One tab row, and the board above the setup

### Changed

- **The admin panel has one tab row instead of two.** A mode bar (Race / Derby /
  Admin) sat over a per-mode sub-tab strip, and both rows were answering the same
  question - which panel am I looking at. An admin picked twice to reach one
  place and paid a row of height for each question.

  | Now | Was |
  |---|---|
  | Race · Grid · Track · Garage · Cup · Derby · ⚙ | 🏁 Race / 💥 Derby / ⚙ Admin, then Race · Quali & Grid · Cup · Garage · Race Editor |

  Two duplications went with the fold. **Cup** was listed under Race *and* Derby
  purely because it had to exist in both modes. And **Editor** meant the
  checkpoint editor or the arena editor depending on which mode you were in,
  which is a name that only works while something else carries the meaning - the
  race editor is under **Track** now, the arena editor under **Derby**.

  Selecting Derby still swaps the session controls and the board, exactly as the
  mode did; the mode is a consequence of the tab rather than a second choice.
  Opening **⚙** no longer takes the race controls off screen, which making it a
  third mode used to do.

- **The leaderboard sits above the setup panels.** It was the last child in the
  DOM, after every admin panel, so it took whatever was left - about a tenth of
  the app with a race running in it. Done with flex `order` rather than moving
  180 lines of table markup: every one of those blocks is already a direct child
  of the panel's flex column, so the stack changes and no binding, guard or
  editor wiring has to know.

- **Setup folds away while a session runs.** Admins get what drivers have had
  since practice shipped: once the lights go out the panel is the board. A
  one-line strip replaces the settings, with **Show** for this session and
  **Keep open** to turn it off permanently. Remembered, like the collapse and
  the opacity.

- **The CONFIG / ON GRID / RUNNING badge moved to the header.** It is status, not
  a destination, and at tab size in the tab row it read as a selected tab.

- **Free practice moved to the bottom of an admin's panel.** It sat between the
  race entry bar and the controls an admin reaches for during setup. Drivers are
  untouched - they have no tabs and it is their only control, so it stays exactly
  where it was for them.

### Note

The **Track layout picker keeps its row** above the tabs. The mockup put it
under the Track tab and the comment sitting on the code argued the opposite,
convincingly: picking a saved layout is part of starting a race, not authoring
one, and behind a tab it would cost a click on the critical path of every race.
It is the one row the fold did not reclaim.

## 0.9.7 - No more "lap 8 of 5", and American spelling throughout

### Fixed

- **A timed race no longer reads `8/5` on the leaderboard.** The Lap column was
  dividing by the lap box, which is inert in a timed race - so a driver eight
  laps into a ten minute race was shown as being on lap 8 of a 5 that nothing
  was counting towards.

  There is no denominator when there is no target. Once the leader has been
  past, the **final lap number** is the target and the column counts against
  that instead. Endurance and Laps races are unchanged.

  That is the third copy of this rule (the server's `sessionLapTarget`, the
  client's `effectiveLapTarget`, and now the panel's `raceLapTarget`), and all
  three name it deliberately: three copies that disagree is how a driver gets
  told two different distances.

### Changed

- **American spelling throughout**, in code and prose alike: **checkered**,
  color, center, meter, gray, behavior, honor, recognize, initialize, practice.
  513 lines across 40 files.

  **Identifiers moved with the prose.** `colour` was a field on the notice
  payload crossing the Lua bridge into the Angular app, and `grey` was a CSS
  class and the default notice color; leaving those British while everything
  around them changed is the half-measure that reads as an oversight. Every side
  of each lives in this repo, so they moved together, and the flash classes
  still cover every value the bridge can send.

  Historical CHANGELOG entries were reworded too, so the file does not switch
  dialect halfway down.

## 0.9.6 - A timed race stops counting laps, and the clock counts down

### Fixed

- **A timed race waved two white flags and two checkered flags.** Reported from a
  live session, and the cause was on the client: both flags are per-driver
  events, so only the client can wave them, and both were being waved off
  `session.totalLaps` alone.

  In a timed race that number is **inert** - the server drops the lap target
  entirely, because nobody knows how many laps ten minutes is - but it was still
  being broadcast and still being counted against. So the lap box waved its own
  pair of flags, on a limit nothing was enforcing, alongside the pair the clock
  waved.

  The client now works out the **effective** lap target the same way the server
  does: the final lap number once the leader has been past, no target at all in a
  timed race before that, and the lap count in a Laps or Endurance race. The
  enforcement mode rides on the state broadcast so the client can tell.

### Changed

- **The race clock counts DOWN in a timed or endurance race**, and up in a lap
  race. "How long is left" is the question every driver in a timed race is
  actually asking, and making them subtract the number on screen from ten
  minutes at racing speed is not an answer. It is tinted while counting down, so
  which direction it is running is visible at a glance rather than inferred from
  two readings a second apart.

  **Elapsed time comes back at the flag.** A finished race frozen on 0:00 says
  nothing, and the elapsed time is what a result is read against.

  This replaces the separate `R 4:12` readout added in 0.9.4, which put the same
  number on screen twice.

## 0.9.5 - Endurance: the distance or the clock, whichever comes first

### Added

- **An Endurance race length.** **Race length** is now three modes rather than
  two, and Endurance is the one that runs to **both** limits at once: a
  distance *and* a clock, whichever arrives first. Both boxes are shown, because
  both are live.

  - **The distance arrives first** - the flag falls on the car that completes it,
    and everyone still out is classified as they come past. A car a lap down is
    not made to keep circulating after the race has been won.
  - **The clock arrives first** - the `+1 LAP` / `FINAL LAP` ending from 0.9.4,
    with the lap target still armed underneath it. A 50-lap-or-60-minute race
    that runs out of time on lap 31 ends on lap 32.

  Which limits are live is now carried as a **named mode** rather than inferred
  from which number happens to be non-zero. That reading stopped being safe the
  moment a mode existed with both of them set, and inferring it is how a
  50-lap-or-60-minute race quietly becomes a 60-minute one.

  Picking **Laps** clears the clock on the server rather than trusting the panel
  to send a zero: a lap race with a live time limit underneath it ends when
  nobody expects it to.

### Note

The flag-falls-on-the-winner rule is **Endurance only**. A plain **Laps** race is
unchanged - every driver runs the full distance, and a lapped car goes on
circulating until it has. That is long-standing behavior a league's results are
built on, and changing it is a decision about how races are scored rather than a
detail of this mode. Say the word if you want the two unified.

## 0.9.4 - Timed races: ten minutes plus a lap

### Added

- **A race can be run to a clock instead of a lap count.** **Race length** is now
  a **Laps / Timed** toggle, the same shape and the same rule as the qualifying
  control below it: one or the other, never both. Picking one sends the other as
  zero, so they cannot both be armed by accident.

  The format is **"10 minutes + 1 lap"**, and the whole of it is in what does
  *not* happen when the clock runs out. Nothing does. A driver watching it reach
  zero still has **two** laps to run:

  | State | Header | What it means |
  |---|---|---|
  | Clock running | `R 4:12` | Time remaining. |
  | Expired | `+1 LAP` | Time is up. The final lap starts when **the leader** next takes the line. |
  | Leader past | `FINAL LAP` | The lap everyone still running finishes on. |
  | Winner home | `FLAG OUT` | Checkered. Your next crossing is your last. |

  **Everyone still running gets the whole final lap.** Not "your next crossing" -
  that is qualifying's rule, and it would flag off a car two seconds behind the
  leader a full lap early while the leader ran a complete one. A lapped car,
  which will never reach the final lap number, is classified on its next crossing
  once the winner is home, exactly as a real checkered flag classifies it.

  **The leader is the car that reaches a lap number first**, not the first car
  past the line after expiry. Those differ precisely when a backmarker comes
  round, and the second rule would hand the final lap to one.

  If no lead-lap crossing arrives within the 3 minute grace - the leader retired,
  the field is stopped - the flag goes out anyway. The race cannot hang waiting
  on a crossing that is never coming.

  The lap count is remembered underneath a timed race, not discarded, so
  switching back to Laps returns the distance that was set.

## 0.9.3 - Free practice gets the timing screen it was already generating

### Fixed

- **Sector times and the running lap clock now show while practising.** A
  practising driver saw one sector per lap, at the line, alongside the completed
  lap time, and nothing in between.

  The sectors were never missing. `checkGates` runs in practice - that is what
  makes practice timed - and every crossing was being stamped and pushed. What
  was missing was the **lap clock**: it ran on `sessionRunning()`, and practice
  is deliberately not a session.

  That mattered more than a missing clock should, because the app draws the
  sector readout **inside** the lap-time block, and that block only appears when
  a clock is running or a lap time is being held. With no clock, the single
  moment anything could appear was the instant a lap completed and parked a time
  there - by which point the sector on hold was the last one of the lap. Hence
  "only the final sector and the lap time, at the line".

  Fixed at both ends: the lap clock runs in free practice, and a held sector time
  is now reason enough on its own to show the readout. The ticker underneath was
  always written to keep a lone sector on screen and expire it; the test in front
  of it was never letting one through.

  The lap counter follows **practice** laps. `session.localLap` does not move in
  practice, so the readout would otherwise have said LAP 1 all afternoon.

## 0.9.2 - The Garage List stops refusing the car it was built from

### Fixed

- **A car was refused the moment it spawned, including the exact one the list
  had just been captured from.** `onVehicleSpawned` declared the setup on the
  frame the vehicle object appeared, and at that instant BeamNG has not finished
  loading its parts: `getConfig()` answers with nothing, the signature comes out
  as `model=X|parts=`, and that matches no entry on any list.

  It had been doing this all along and cost nothing, because the deletion was
  broken (0.9.1's other fix). The moment the client started honoring the
  removal order, the same spurious rejection deleted the car.

  Fixed on both sides, because either alone would do: the client will not report
  a configuration with an empty part list, and the server will not rule on one.
  A spawn now arms the poll instead of answering immediately.

- **The model is matched on the bare jbeam name.** The list stores whatever
  `veh:getJBeamFilename()` returned and the spawn packet carries `jbm`, and
  nothing promises those agree on case, on a leading path, or on the `.jbeam`
  extension. A disagreement refused a car that was plainly listed, with a
  message blaming the model.

- **A capture refused for size now says so.** An oversized configuration
  signature printed to the server console and returned, so the button did
  nothing visible and the car was believed to be on a list it had never reached.

### Changed

- **Nobody is exempt from the Garage List any more, admins included.** This
  reverses 0.9.1, where an admin was told and listed but kept the car.

  **Build the list with Enforcing switched off.** That is the whole of the
  workaround for the case the exemption existed for, and an empty list never
  enforces anything, so the first capture of a session needs no special case.
  The panel says this next to the switch rather than leaving it to the docs, and
  an admin without a car can always still reach the panel to switch enforcement
  back off.

  Admins still appear in the grid audit.

### Added

- **A refusal prints both signatures to the server console.** A driver is told
  the rule they broke, which is all a driver can act on. An admin looking at a
  car that ought to be on the list needs the two signatures side by side, and
  there was nowhere to get them.

## 0.9.1 - The Garage List learns the difference between parts and tuning

### Added

- **The Garage List locks parts and tuning separately.** A capture used to mean
  one thing: this car, these parts, this exact tune. That is one of the two
  rules a league actually runs, and the panel now carries both under **Locks**:

  - **Parts** (the default) matches the model and the part config. Tuning is the
    driver's business.
  - **Strict** matches the tune as well.

  Paint was never matched and still is not, under either mode.

  Several allowed builds of the same car - a choice of engine, say - is **not** a
  third mode. It is several entries under Parts, one per build, which is the same
  thing the capture button has always done.

  The mode is one switch for the whole session, persists in `garage.json`, and is
  named in every refusal: a driver is told whether the thing to undo is a part
  swap or a tune, because those are different evenings.

- **Admins in an unapproved car are flagged and listed, never removed.** An admin
  has to be able to drive an unapproved setup - it is how a car gets captured -
  but an admin quietly starting a race in one used to be invisible everywhere.
  They now get the same message every driver gets, appear in a **Not on the list**
  block in the Garage panel, and are named in the line **Start Countdown** sends
  to whoever pressed it.

  The audit **reports and does not act**. Pulling a car off the grid during the
  countdown does more damage to the race than starting with one wrong setup in
  it, and it is the admin's call either way.

- **Driver notices reach BeamNG's Messages HUD app.** Every surface this mod had
  was its own: the notice strip, the full-panel flash and the red vehicle banner
  are drawn by the Race Manager app, and the server's chat lines need the chat
  window open. A driver running with the app minimised and chat closed saw none
  of them, and **"RED FLAG: stop where you are"** is not a message that can
  depend on which windows somebody happens to have up.

  Every driver-facing notice already passes through one funnel, so the HUD copy
  is decided there by kind rather than bolted onto forty call sites. What goes
  out is what a driver would have to **act** on: the flags, the out lap, being
  put out of a session, running out of resets, a refused car, a joker ruling,
  where you start, a pit call, and the derby. The running commentary (a reset
  count, a fastest lap, a ghost state, a name change) does not - pushing that
  through as well is how a channel that must be read becomes one that is not.

  Each kind gets its own icon and its own message slot, so a repeat replaces
  rather than stacks, and a pit call cannot wipe a red flag.

  **The chat lines stay.** They are the scrollback an admin reads after the
  fact; this is the copy that reaches a driver at the wheel.

### Fixed

- **A refused setup is now actually deleted.** This is why the Garage List could
  be walked straight past: spawn a listed car, change whatever you liked, and the
  server noticed within two seconds, said so, and did nothing at all.

  `MP.RemoveVehicle` wants BeamMP's own per-player vehicle id. The id the client
  was reporting is `veh:getID()`, a BeamNG game object id from an unrelated
  numbering space, so the call matched nothing and failed silently inside its
  `pcall`. The client knows which car is its own without any id, so it is sent
  the order and does the deletion. The old call is kept on the one path that
  does carry a real BeamMP id (the spawn hook).

- **A race that owes an out lap now says so on screen.** `onOutLap()` dropped its
  qualifying-only test when a race gridded away from the start/finish line
  started owing one too, but the notice at GO kept it - so for a race the
  message existed **only** as the server's chat line, on the reasoning that chat
  "reaches a driver who has not opened the app". It does not reach one who has
  not opened chat, which is most of them.

- **A driver's setup is only reported while they are in their own car.** The
  capture read whatever vehicle the client was ATTACHED to, and in multiplayer
  that comes apart the moment somebody spectates - filing a rival's parts under
  their own name, or whitelisting a rival's car when an admin pressed capture.
  Nothing is reported while the camera is on somebody else's car, which leaves
  the last good declaration standing.

### Upgrading

**No re-capture needed.** A `garage.json` written by an earlier release has no
mode and no per-entry parts signature; it loads in **Parts** mode (the looser of
the two, so an upgrade cannot silently start rejecting tunes a league was
already allowing) and the parts half of every entry is recovered from the
signature already on disk.

## 0.9.0 - A board for the person holding the camera, and how far back everyone is

### Added

- **Display names can go on the BeamMP nametag.** A switch in the Display Names
  panel appends a driver's display name to the tag over their car, so
  `guest5961302` reads `guest5961302 (Kestrel)`.

  **Appended, not substituted**, which is a limit and not a preference: BeamMP
  has no server-side way to rename anyone -- the guest identity comes from their
  auth and the plugin cannot reach it.

  **Nothing but the text changes.** It goes through BeamMP's own
  `setPlayerNickSuffix`, so distance fade, hide-behind-objects, color, alpha,
  the spectator list and role tags are all still BeamMP's, obeying whatever each
  player has set. Hiding BeamMP's nametags and drawing our own would have allowed
  a full replacement, and was rejected: owning the render means owning every
  setting a player has already chosen, and getting one of them slightly wrong is
  worse for them than a guest number.

  The suffix is filed under its own tag source, so a server also running BeamJoy
  or CEI keeps both tags rather than one clobbering the other. The switch is
  server-owned and **off by default**; turning it off removes every suffix, and
  so does leaving the server.

- **The status bars have a deliberate layout now, in all three panels.** Every
  readout changes width as it changes value -- a lap clock crossing 0:09.9 to
  0:10.0, a checkpoint counter reaching double figures, a fastest-lap holder
  called `guest5961302` replacing one called `Ana` -- and the controls sat
  immediately after them. So the buttons moved while you were reaching for one,
  and how many ended up on a second row depended on the width of a number.

  **The first row is the live status run, and the flag and the two window
  controls are PINNED to its right-hand corner** -- out of the flex flow
  entirely, so they are in the same place at every panel width, in every state,
  and wrapping cannot reach them.

  They were pushed there first, with a greedy flex item, and that turned out to
  be a bug waiting for a busy bar. A push distributes space only *after* the
  browser has decided where the lines break, so a bar that is marginally too wide
  wraps its last button onto row two and only then inflates the push on row one:
  one control stranded on its own line, and a lake of empty space after the lap
  clock, from the same cause -- and it shows up exactly when a race is running and
  the bar is fullest. The space the pinned group needs is reserved in each bar's
  own padding shorthand, because as a separate `padding-right` rule it lost to
  whichever `padding:` came later in the stylesheet.

  **Everything else is below, left aligned**, and flows: it takes a third row
  only when it will not fit on the second. That is where the wide, wordy things
  live now -- `JOKER PENDING`, `RESETS 0/3`, the out-lap notice, `WAITING ON n`,
  the grid slot, the badges, and the admin controls with the fade slider. They
  come and go mid-session and they are the widest things on the bar, which is
  exactly what was shoving the corner controls around.

  The rows below **used to be right aligned**, which was not deliberate either:
  `.rm-btn-tab` and `.rm-admin-tag` each carried a `margin-left: auto`, so the
  first of them in a row went hard right and dragged everything after it along --
  the buttons on one row, and `ADMIN`, `Log out` and the fade slider on the
  next.

  **Collapsing does not rearrange the bar.** It removes the panels below the
  header; the header itself is laid out the same way folded or not, so the corner
  pair is in the corner in every state. An earlier pass stood the break and the
  push down while collapsed, on the reasoning that collapsing exists to leave one
  line -- but the header carries its badges and its admin controls either way, so
  that did not produce one line. It produced one long wrapping run with the
  corner buttons adrift in the middle of it.

  The size reset lost its `!hudCollapsed` guard for the same reason: with it, the
  corner held two buttons expanded and one folded, so the collapse toggle moved
  sideways at the moment it was pressed.

- **Time behind the leader, on every board.** A **Gap** column on the race
  table, the qualifying table and the broadcast board, plus an **Int** column on
  the broadcast board for the gap to the car directly ahead.

  **It is measured rather than estimated.** The server now stamps `race.time`
  when each driver reaches each checkpoint, and a gap is the subtraction of two
  of those stamps at the last checkpoint both cars have actually reached. No
  speed, no track-distance model, nothing interpolated: every figure on screen
  has two timestamps behind it.

  **Which means it works on branch layouts**, and that is why it is built from
  splits rather than from track position. A branch gate is another way through a
  checkpoint that already exists, so two cars at opposite ends of a head-on oval
  have cleared the same checkpoints and their splits subtract correctly. A gap
  built from distance would put them minutes apart.

  **The trade is that it refreshes per checkpoint, not continuously** - about
  every seven seconds on a twelve-gate, ninety-second lap. Finer than the sector
  timing a televised race shows, but a leader pulling away mid-sector does not
  move it until the car behind reaches the same gate.

  **Qualifying gets a different gap on purpose.** That session is scored on the
  best *lap*, so two drivers who set identical times ten minutes apart are level
  and a clock delta would rank them by when they went out. The qualifying gap is
  the difference between best laps, and the server sends no clock gap for a
  qualifying session at all.

  **A lapped driver reads `+1 LAP`**, never a number of seconds - the split
  subtraction across a lap boundary is a real figure that means nothing, and it
  is the one reading here that would actively mislead. A retirement has no gap:
  it is classified by a ruling rather than by where it got to. And a gap is
  never negative - if the order has changed since a driver's last checkpoint it
  reads `+0.0`, which is what too close to call looks like.

  **It costs nothing on a race night, and was built to that constraint.** No new
  network traffic in either direction: the client already fires a checkpoint
  report on the frame after every crossing because the running order needs one,
  and the server just notes what the clock read when it arrives. No new work per
  frame or per tick - the two subtractions happen inside the loop already
  stamping positions on the sorted field. Measured on a 20-driver, 20-lap,
  12-gate race: 3.4 microseconds per broadcast at three broadcasts a second, and
  150 KB of split times held for the whole race.

- **A broadcast board for spectators.** Sit a session out with **👁 Spectate**
  (or finish the race - a driver whose car has been taken is a spectator too) and
  a **📺 Broadcast** button appears, in the header between sessions and on the
  driver bar during one. It is offered to **admins as well**: the person running
  the race night is usually the person streaming it, and spectating is an entry
  decision that has nothing to do with rights.

  It is not another view of the leaderboard. A driver's HUD answers *where am I,
  what lap, how many resets left*, and a broadcaster has none of those questions.
  Theirs is the whole field at once, who is out and why, the championship, and a
  camera they can steer.

  **Click a name and the camera goes to that car, in orbit.** That is the one
  place in the mod that sets a camera *mode* - everywhere else the view is the
  driver's own business and is deliberately left alone - and it is the exception
  because here the view *is* the request: a chase camera on that car is exactly
  what the click asked for. The row actually being watched is marked, and the
  mark comes back from the game rather than from the click, so a name whose car
  is not loaded on this machine yet leaves the marker where it was instead of
  claiming a camera it never got.

  **Drivers who are out get their own block**, with the ruling that put them
  there - the same text the results file records - and the place they were
  running in when they stopped. Their names are clickable too: the car is still
  where it stopped, and the wreck is often the shot. Drivers merely sitting the
  session out are counted at the foot of the board rather than listed, because a
  board that puts them among the runners claims a bigger field than the one on
  track.

  It carries the **Gap** and **Int** columns described above, and keeps the
  places-gained-since-the-grid marker beside the position: one says how far away
  the car ahead is, the other how the race has moved since the lights.

  **A derby gets its own table.** It is a parallel game mode with its own field
  and its own clock, and the racing field is untouched by one - so a board that
  simply kept rendering `drivers` while an arena was running would be showing the
  race that happened before it. Names click through the same way.

  **With a cup running, a Race / Points pair appears.** The points view is the
  championship as the server ranks it - position, driver, rounds, wins, total -
  and computes nothing itself, the same split the admin cup panel keeps. Opening
  the board pulls the standings, so a board opened halfway through a race night
  shows the real table instead of an empty one; a standings row is a roster
  identity rather than a connection, so it is clickable only while the driver it
  is bound to is on the server.

  **The board does not outlive the spell that showed it.** Being out of the field
  is two things wearing one name: pressing Spectate is a decision that lasts,
  while taking the checkered flag makes you a spectator for the few seconds
  between your finish and the results. The switch is cleared when you rejoin the
  field, so a driver who merely finished is never thrown into a stream graphic
  and back out again -- press it once per session you sit out. It is still
  remembered *within* a spell, which is the reason it is stored at all: BeamNG
  rebuilds the app whenever the HUD layer goes, and the pause menu does that.

  **The board is the whole app while it is on.** Header, session controls, both
  editors, the derby panel, the login bar, the leaderboard and every alert
  overlay come off the screen - a broadcaster is not in the session, so a pit
  readout or somebody else's out-of-bounds timer would simply go out over the
  stream. Everything worth keeping is on the board's own strip: phase, clock, the
  lap the leader is on, the session flag and the fastest lap. It drops itself the
  moment you rejoin the field, because you cannot broadcast from a car you are
  racing, and it remembers the preference for the next session you sit out.

### Fixed

- **An eliminated derby car sat there revving at full throttle.** Blocking a
  driver's inputs stops new ones arriving; it does nothing about the ones already
  there. BeamNG's action filter suppresses an action's `onChange`, so whatever
  the value was at the instant the filter armed is the value it keeps -- knock
  somebody out mid-corner and the throttle stays exactly where their foot left
  it, with neither them nor anyone else able to do a thing about it.

  Every input the filter covers is now zeroed once, after it arms. Once is
  enough: with the action filtered nothing can move it again.

  **The ignition goes with them**, and the out-of-bounds case is why rather than
  the stopped one. A car counted out by the idle timer is by definition sitting
  still; one disqualified for leaving the arena was driving a second ago, and
  zeroed pedals leave an engine that still idles, still walks an automatic
  forward and still lets the car be nudged along under its own power. It is put
  back when the derby releases them, so nobody is handed a car that will not
  start for the next session.

  **The parking brake is released, not applied**, which is the deliberate
  difference from the end-of-derby stand-down. A wreck is meant to be an obstacle
  the survivors can shove, pile into and use -- one bolted to the floor by its
  handbrake is a wall instead. It stays solid and unfrozen for the same reason,
  and a car disqualified at speed therefore coasts to a halt rather than
  anchoring itself mid-arena. The only thing taken away is the driver's own
  ability to move it.

- **A derby driver who lost a life stopped being policed for the rest of it.**
  After one life was spent the idle timer and the out-of-bounds timer both went
  dead for that driver, and the derby then ran on with no winner until an admin
  pressed **End Derby**.

  Both symptoms are one cause. The client's `out` flag meant two things at once
  -- *the server says I am not in this derby* and *I have reported something, do
  not report it twice* -- and the timer-expiry path set it. That was true while a
  stopped timer meant elimination. Lives made it false: the server can now answer
  with a life and put the car back, and nothing cleared the latch. And a field
  that cannot report cannot be eliminated, which is where the derby that never
  ends comes from.

  The two meanings are separate flags now. `out` is the server's ruling and only
  a broadcast sets it; `pending` is the hold-off while a report is in flight, and
  it is cleared by the ruling whichever way that goes. The grace period is
  re-armed on both paths, because the life message and the broadcast are sent one
  after the other and nothing guarantees which lands first -- if the broadcast
  wins, the car has not been moved yet and is still sitting exactly where the
  timer expired.

- **A car coming back on a life is now ghosted on every client, not just its
  own.** The placement queue ghosts the *rivals* on the respawning driver's
  machine, which is right for a form-up where everyone is landing at once. A
  single respawn is one-sided: the returning car passes through everybody on its
  own screen and lands solid on everyone else's, which is the side the weld comes
  from. The server broadcasts, each client ghosts that one car for four seconds,
  and going solid still passes through the weld gate -- so the four seconds are a
  floor, not a promise: a car with somebody inside it at the end of them waits
  until the space is actually clear.

  Timed locally rather than on the shared race clock, which does not run during a
  derby -- an end time computed from it would never arrive and the car would stay
  a ghost for the rest of the arena.


- **The joker gate no longer carries its wording on track.** `JOKER 1/2
  (lap 1: closed)` was a sentence to read at racing speed, and the glyph beside
  it had already said the same thing: a red cross while the joker is shut, a
  green tick once taken, a faded arrow while it is open. The fill and the symbol
  stay, the words go.

  **The editor still numbers and labels everything, joker included.** That is
  where the words are worth reading, and where there is time to read them.

- **The opacity slider now fades everything with a background.** It drove the
  panel fill and nothing else, so the header's orange band and its bottom rule
  kept their own fixed alpha: fade the HUD all the way out and a solid orange
  stripe stayed painted across the middle of the view. Both are driven from the
  same watcher now.

  The driver bar was mixing its own fill at 0.8x the slider as well, so it sat
  visibly lighter than the board directly beneath it at every setting but zero.
  One slider, one value, every surface.

- **The leaderboard stopped clipping its last column.** The panel scrolled
  vertically only, so a wide row -- the race table runs to ten columns with the
  joker and reset ones armed -- had its right-hand end cut off at the panel edge
  with no way to reach it. It scrolls horizontally too now. There is a lot in
  those rows and a narrow HUD window cannot show all of it at once, but reaching
  it beats not having it.

- **A quarter of `ui_bindings_test` was running after its own summary.** The
  pass/fail block sat a hundred lines from the end of the file, so twenty-eight
  checks below it ran, printed their FAIL lines into the middle of a run that had
  already reported "0 failures", and exited 0. A build could go out red. The
  summary is last now and those checks are counted; the suite goes from 511 to
  539.

  One of its checks was also matching `===`. `$scope.spectating` may only ever be
  assigned twice -- the initializer and the server's own `youSpectating` -- and
  the counter looked for `$scope.spectating` followed by an `=`, which a
  comparison begins with too. The first predicate to *read* the flag made the
  count say three.

- **The driver bar's Race / Spectate buttons never showed which one was on.**
  The "this one is active" style was written as `.rm-btn.rm-flag-on`, and the
  driver bar's buttons are `.rm-driverbar-btn` -- a different class that does not
  contain the other -- so the pair wore a state class nothing answered to. Both
  classes carry the style now, which is also what makes the board's Race /
  Points toggle readable.

## 0.8.4 - Derby lives, and an editor that keeps hold of your gates

### Added

- **Derby lives.** A driver counted out by the stopped timer now spends a life
  and goes back to the slot they started from, instead of being out of the derby
  on the first mistake. Set **Lives** in the derby rules; 1 is exactly the
  behavior that existed before.

  The respawn goes through the same placement queue the form-up uses, so the car
  is ghosted on the way in and gets its collisions back only once it has settled
  and the space around it is provably clear -- a driver cannot be dropped into
  the middle of a scrum and welded to it. The stopped countdown is cleared and
  the start grace re-armed before the car moves, so nobody lands already counting
  down toward the next life.

  Lives are snapshotted at form-up, so an admin raising the setting mid-derby
  cannot hand the survivors more chances than the drivers already knocked out
  got. Remaining lives show on the derby board when the rule is in use.

  **Out of bounds still eliminates outright.** Leaving the arena is a choice in a
  way that being wrecked is not, and a driver with lives in hand could otherwise
  use the boundary as a free teleport back into the middle of the fight.

### Fixed

- **Checkpoints no longer fly into the sky, and can be brought back if they
  have.** The ground probe added in 0.8.3 started fifty meters *above* a gate and
  took the first surface on the way down. That is not the ground: it is whatever
  is highest in that column, so a gate under a bridge got the bridge deck, one
  beside a building got the roof, one under trees got the canopy -- and the gate
  was duly teleported up onto it. Because the lift only ever raises, that bogus
  surface then became the floor shift+scroll clamped against, so the gate could
  not be brought back down either.

  The probe now looks *down from the gate itself* first, which is the only
  surface that has any claim to be its ground. A genuinely buried gate is still
  rescued, by walking upward in short steps so the lowest surface above it wins
  and overhead geometry is never reached.

- **Clicking a gate no longer moves it.** Dragging moved the gate *to* wherever
  the cursor ray landed, and the ray does not stop on a gate -- a debug drawing
  has no collision -- so it carried on to the ground behind, which from any
  raised camera is meters away and at whatever height was under *there*. Picking
  a gate therefore teleported it, reported as "I clicked it and it went all the
  way under the map".

  A drag now moves the gate **by** how far the cursor has travelled since it was
  grabbed, never to where the ray currently lands. A click that does not move the
  mouse is a zero delta and moves nothing, so "click picks, drag moves" is
  finally true rather than merely written on the panel.

- **Nothing moves a gate DOWN into ground it cannot see.** A failed ground probe
  used to leave the requested drop already applied, so every press of Down or
  click of the wheel sank the gate further with no floor under it. Downward moves
  now probe first and refuse outright when there is no answer.

- **Pressing a movement button no longer deselects the gate.** The HUD app is a
  CEF overlay and ImGui's mouse-capture flag knows nothing about it, so pressing
  Up, Down or a turn button also registered as a click on the world. The ray
  behind the panel hit no gate, the miss cleared the selection, and the buttons
  grayed out -- pressing Up disabled Up.

  A click that picks nothing now leaves the selection alone, which is the better
  rule anyway: a miss is ambiguous (the panel, a mis-aim, a gate hidden behind
  another) and none of those mean "forget what I was editing". A panel press also
  suppresses world picking and dragging for a few frames, so a button whose ray
  happens to land on another gate cannot steal the selection or start dragging it.

- **A drag is now purely horizontal, and follows the cursor across a plane at the
  gate's own height.** It used to follow the raycast against the world, which
  jumps: drag across a treeline and the hit flips between the ground and a canopy
  twenty meters up, so a centimeter of mouse movement reads as meters of travel
  in a direction nobody asked for, and the height came out wrong at the end --
  first climbing the trees, then dropping to the floor. A plane has none of that.
  It ignores trees, roofs and terrain completely, and it makes a drag mean the
  one thing it should: move this gate around at the height it is already at.

  Height belongs to the wheel and the Up/Down buttons now. The only height change
  a drag can make is the floor at the end, which can only ever lift a gate out of
  a hillside it was dragged into.

- **Dragging a gate across trees no longer climbs them.** The cursor raycast
  stops at the first thing it meets, which over woodland is the canopy, and the
  gate took its new height from that hit -- so hovering a drag over a group of
  trees lifted it to treetop level. The destination ground is now probed from the
  gate's own height, which is already under the canopy, so the trees are never in
  the ray at all. Same class of mistake as the sky bug above: trusting whatever a
  ray met first to be the ground.

- **Raising and lowering is faster, and has buttons.** Shift+scroll moves in
  bigger steps, and **▲ Up** / **▼ Down** sit beside the turn controls for a
  mouse with no wheel, or for digging a gate out of a hillside without spinning
  the wheel. Both floor at ground clearance, so neither can bury a gate.

- **A drag that catches the horizon no longer flings a gate out of sight.** The
  cursor ray lands on whatever it hits, and aimed near the skyline that is
  terrain kilometers away. A drag beyond reach is now ignored rather than
  followed, so the gate stays where you last had control of it.

- **Start position markers now say which way they face.** The direction line
  down the middle of a slot was a plain cylinder, which draws the axis and not
  the direction: tail-to-head looked identical to head-to-tail, so a slot facing
  down the track was indistinguishable from one facing back up it until you drove
  onto it. It has an arrowhead now, the same shape the joker gate's arrow uses.

## 0.8.3 - Finishing without despawning, and placement that stays above ground

### Fixed (placement on uneven terrain)

- **A generated grid now follows the ground.** Every slot used to be handed the
  height of wherever the car generating it was standing, which is a flat plane
  laid through a hill: rows behind a car on a crest ended up inside the slope and
  rows behind one in a dip floated above it. Each slot now finds the terrain
  under itself. What is preserved is the anchor's height *above ground*, so a
  grid laid out on a bridge stays on the bridge.
- **Ctrl+click no longer places gates in the dirt.** A gate placed by driving
  takes the car's origin, about half a meter up; a clicked one took the raycast
  hit, which is the terrain surface itself. Clicked gates therefore sat lower
  than driven ones on the same road, far enough to disappear into a slope.
- **Shift+scroll raises and lowers the selected gate in nudge mode.** There was
  no control that moved a gate vertically at all: the Gate size sliders set
  height and depth, which is a gate's *extent*, not its position, so a buried
  gate was permanent. It clamps at ground clearance, so the control that digs a
  gate out cannot be used to bury one.
- **A Last Checkpoint reset no longer spawns the car underground**, which was the
  same bug seen from the other end: the respawn put the car's origin exactly at
  the gate's height, so a gate sitting on the surface left the car half buried.
  Respawns are now clamped above the ground whatever the gate claims, which also
  rescues layouts saved before this.
- **A gate inserted mid-route no longer faces the wrong way.** The heading for a
  clicked gate is taken from the gate before it, but with a gate selected the
  click is an *insert* and the code read the last gate on the route instead. A
  gate inserted into the middle of a lap was therefore aimed at wherever the lap
  finished, which is what stood a car sideways across the track on a reset.

### Fixed (from live testing)

- **A race's first lap no longer sets a lap time.** It is run off a standing
  start, so it carries the launch and the scramble to the first corner and is not
  the same measurement as a flying lap. The rule existed and was gated on the
  grid sitting *away* from the start/finish line, so on an ordinary circuit the
  standing lap went on the board like any other and could take fastest lap. The
  crossing still counts in every other way; only the time is dropped. A **one-lap
  race is exempt**, because there the standing lap is the only lap there is.

  `docs/REFERENCE.md` already described the corrected behavior, so the code and
  the docs had been disagreeing.

- **The last lap no longer lights CP 1 ahead of the finish.** The look-ahead gate
  wraps -- the gate after the start/finish is CP 1 -- so on the final lap it drew
  a gate for a lap nobody was going to drive. Only the wrap is suppressed: the
  second gate is still shown everywhere else on the last lap.

- **A five second hold at the flag.** A race no longer closes on the tick the
  last car crosses. It announces the hold in chat, waits (`race.endDelay`), then
  writes results and releases the field -- so finished drivers stay ghosted long
  enough to actually see the finish. Races only; qualifying closes immediately,
  because there is no flag, no placement and nothing ghosted to look at. The
  derby has had the same hold since it was built.

### Changed (finishing)

- **Taking the flag no longer despawns your car.** It is ghosted in place
  instead, and you go on driving it to watch the rest of the race.

  The old behavior deleted the finisher's vehicle and respawned the whole field
  on the grid when the race ended. That is an entity destroy and an entity create
  per driver, plus the network sync churn each drags behind it, all landing at
  the one moment a field is coming home together and hitting hardest on the
  machines least able to absorb it. Finishing is now a state change and nothing
  else: no entity is created, no entity is destroyed, and no reset routine runs.

  **The ghost is asymmetric on purpose.** You see your own car exactly as before;
  everyone else sees it translucent. Collision is dropped on *every* client
  including your own, which is what makes the race provably unaffected: in BeamMP
  your car is simulated on your machine, so leaving it collidable locally would
  bounce you off a racer whose own simulation felt nothing, and your position is
  what gets synced.

  **Finished cars pass through each other too**, so spectating drivers cannot
  shunt one another into the racing line. World and terrain collision are
  untouched, so nobody falls through the map.

  A finisher gets a **checkered flag** for the rest of the session, a count of
  the drivers they are still waiting on, and a one-off "you placed 3rd" message.
  Their place is locked at the crossing. Resets still work, still cost nothing,
  and the car comes back still ghosted -- a reset reloads the vehicle's Lua VM,
  which is where the collision toggle lives, so it is re-asserted on the way out.

  DNF and DSQ drivers get the same treatment. At the flag every ghost is lifted
  together and nothing is teleported: drivers are released wherever they drove
  to.

- **`spectate.attachToRunner` no longer runs on finishing.** It existed because
  deleting the car left BeamNG to hand the view to whatever vehicle was nearest,
  which with a field finishing together put every client on the same arbitrary
  driver. It still covers a car that **disconnects** out from under the view.

## 0.8.2 - Branch gates: two ways through one checkpoint

### Changed (branching)

- **A branch gate is now another way through a checkpoint, and that is the whole
  feature.** Drive through either gate and the checkpoint is cleared. Nothing
  records which one you took, and each checkpoint is decided on its own.

  What this replaces is the **lane** system: a named line, built in a Lanes tab,
  whose gates *replaced* the main route's at the slots you gave them, and which
  drivers were assigned to by a tag on their grid slot. It worked, and it was
  more machinery than the job needed. The concept a race night actually wants is
  "this is CP 1, and so is that one", and everything else was scaffolding around
  saying it.

  Gone with it: lane names and ids, the Lanes tab, **Set Lane** and **Alternate
  Lanes** in Start Grid, the lane tag on a start position, the per-driver lane on
  the wire, the **LINE** badge on the driver bar, and the **Line** column in the
  leaderboard and the results file. A track with branch gates now exports exactly
  the results table an ordinary race does.

  **Splitting a head-on field is now just ↻ Turn Around.** The way a start
  position points is the only thing deciding which direction a driver races,
  because every gate for the next checkpoint is armed for everybody: a car facing
  anti-clockwise reaches the anti-clockwise gate for CP 1 first and clears the
  checkpoint on it. Nothing has to be told, so nothing can be told wrong.

  **Both gates are drawn on track and light up green together.** The old drawing
  showed a driver only their own lane's gate, which meant the choice was
  something you had to know about rather than see.

  Two things this can now express that lanes could not: **as many branch gates on
  one checkpoint as you place** (three ways through a corner is three gates, where
  a third route used to need a third lane), and a driver who spins and turns round
  is no longer stuck on a line they can no longer reach.

  **Saved layouts with lanes will not load their branch gates.** The stored shape
  changed from a list of named lanes to a flat list of gates, each carrying its
  checkpoint. Rebuild the branch gates on affected tracks; the main route, joker
  route, pit stalls and grid are untouched.

- **`tests/branch_test.lua` is rewritten** around the new rule, and in passing a
  drift was fixed: its mirror of `checkGates` armed only the start/finish line on
  the out lap, which the real code stopped doing some releases ago. It now arms
  the checkpoints like any other lap, and the test says so.

## 0.8.1 - One switch for race entry, start lights and flags, joker and pit visuals

### Changed (race entry)

- **Race entry is one switch, and it belongs to the driver.** Everyone connected
  is in the field; a driver who would rather watch presses **Spectate**, and
  **Race** puts them back. The admin-set entry mode (Everyone races / Opt-in) and
  the per-driver **Join Race** and **Leave Race** buttons are gone. There were
  three ways to answer "am I in this race", they could disagree, and the one that
  broke was a driver who sat out and then had no way back in. Spectating covers
  what opt-in was for: a one on one is two people racing and everybody else
  spectating, with no mode to set first.

  The demo derby shares it. It had its own entry mode that resolved by reading
  the *racing* opt-in flag, so a driver had to join a race to be put in a derby.
  Sitting out now sits you out of both.

  Spectate is settled before the lights. Once a session is running the field is
  fixed and the controls disable in place rather than disappearing; the way out
  of a race you are already in is **Retire**. Sitting out survives a reconnect,
  and **Reset** puts the whole field back in.

- **Retire**, for pulling out of a session you are already in. It is a classified
  retirement, not a disappearance: the driver keeps a position, appears in the
  results and scores like any other DNF. A retirement classifies **behind the
  last car that can still finish**, which is how motorsport has always ordered
  them, so stopping later classifies higher. Asked for before it happens, because
  it cannot be undone.

### Added (visuals)

- **Start lights and flags.** A three-lamp gantry counts the field down, amber to
  green. A flag reports the session at a glance in both panels: green racing,
  yellow caution, white on the last lap, red while the grid is held or a red flag
  is out. A caution is a **condition, not a phase** -- the session keeps running
  underneath it, and red goes to yellow, then back to green.
- **The joker and the pit stall wear their state.** The pit stall is drawn as the
  box it actually tests, with semi-transparent walls. The joker shows an arrow
  while it is open, a cross when it is closed and a tick once it has been taken,
  so it reads at speed without stopping to think.
- **Height and depth are separate.** A gate used to be one measurement centerd on
  the placement point, so half of every gate hung under the road and making one
  tall enough to see buried an equal amount. Height raises the top bar, depth
  lowers the bottom. The derby arena walls got the same split.

### Fixed

- **Spectating had no way back.** Three separate faults, each of which alone was
  enough: the entry decision was written to the record but never the identity
  registry, so the online purge undid it; the wire could express "you are
  spectating" but not "you are not", because `rec and x == true or nil` cannot
  return false; and the panel's single toggle took both its label and its action
  from its own belief about the state, so one stale broadcast left the driver
  holding a button for the state they were already in. Entry is now **two
  buttons sending absolute values**, and a redundant request resyncs the panel
  rather than being answered with silence.
- **Racing twice without a Reset left the grid hold asleep.** The hold's rate
  limiter kept a stamp from the previous race's clock, which read as "corrected a
  moment ago" and swallowed the first correction of the new session -- the one
  that matters, with the field stood on the grid. Reset Session had been hiding
  it by dropping the records outright.
- **On the grid, the two highlighted gates were the ones behind the field**: the
  finish line and checkpoint 1, instead of checkpoints 1 and 2.
- **Loading a layout told the panel nothing**, so a joker track had to be loaded
  twice before the joker lap setting unlocked.
- **The flag never changed color.** It was a glyph the font renders as an emoji,
  which carries its own color and ignores CSS. It asks for the text form now.
- **The Race Entry row did not render at all** on account of an apostrophe inside
  a single-quoted Angular string, which is a parse error rather than a warning.
- Ending a derby put everyone on the last race's start line; a ghost timer
  stacked when a ghosted driver reset; full-window overlays escaped the panel in
  minimal mode; and a refused admin command now says so instead of failing quiet.

### Internal

- **The Demo Derby is its own module** (`lua/ge/extensions/raceManager/derby.lua`),
  the first split out of the client. This matters more than it sounds: Lua allows
  200 active locals per function, the top level of a file **is** a function, and
  going over does not warn -- the file silently fails to compile and the mod is
  simply absent. Both large files were at zero headroom.
- **The deploy script grew two guards.** It refuses to write the server plugin
  while BeamMP is running, because the server hot-reloads a changed plugin
  immediately and that ends any live session -- which happened, and was reported
  as a joker bug until the log said otherwise. It also detects a rival copy of
  the plugin loaded from another folder: BeamMP loads *every* folder under
  `Resources/Server`, so one called `deactivated_plugins` is not deactivated, and
  two copies had been registering the same events and stealing the admin login.
- **A frame-cost budget** (`tests/perf_test.lua`) measures what the client costs
  per frame rather than only whether it is correct: UI pushes per second, draw
  calls and allocations, with the draw calls held flat as the circuit grows.

## 0.8.0 - Branching routes, mouse track editing, the qualifying out lap

### Added (track building)

- **Branching routes: two ways round one track, scored together.** A lane is a
  set of per-slot gate *overrides*. It replaces the gate at a checkpoint rather
  than adding one, so every lane has the same number of slots and the whole
  field runs one lap count on one leaderboard. That covers a left/right split,
  and it covers the head-on "suicide" oval where two halves of the field race in
  opposite directions and still finish the same race. Gates score in **either
  direction** now unless marked one-way, so a driver who missed a checkpoint can
  turn round and take it rather than driving the whole loop again.
- **A race whose grid sits away from the start/finish line gives its first lap
  away**, for the same reason qualifying does: a lap is only a lap if it starts
  where it ends. A head-on layout always trips it, because two directions cannot
  share one row of slots. It travels with the track, not with the session.
- **Nudge mode: build and fix a track with the mouse.** Turn it on in the editor
  and the cursor is released from the camera. **Click** a gate to pick it,
  **drag** to move it along the ground, **scroll** to turn it, **ctrl+click**
  open ground to place a new one. Works on whichever editor tab you are on, so
  checkpoints, joker gates, pit stalls, lane gates and start positions are all
  movable. A placed gate faces the way the route is already traveling, so
  clicking along a road in order gives gates that face the way the road goes.
  With a gate picked, a placement goes in *after* it, which is how a gap noticed
  halfway round gets filled. Driving to a gate and pressing the button is
  unchanged and still the way a track gets built: it puts a gate where a car
  actually fits, facing the way one actually travels.
- **Grid tools.** Generate a block of start positions from an anchor, respace
  them, set how many abreast, flip half of them 180 degrees for a head-on grid,
  and deal lanes across the slots one at a time. Checkpoints and start positions
  can be reordered and deleted individually.
- **Pit stalls.** Drive into one during a race and the car is stopped, repaired
  and released. Not checkpoints: they never affect laps or splits.

### Fixed (this one lost work)

- **A save could quietly empty the layout it was overwriting.** Loading a track
  with a joker route, a pit stall and a grid, adjusting a pole height and saving
  under the same name could return a layout with none of them, silently. A save
  writes whatever the sending client holds, so any path that emptied one
  collection while leaving the route alone made the next same-name save a
  permanent loss. The server now **refuses a save that would empty a section the
  stored layout has** and says exactly what would go; the panel asks and
  re-sends if that is really the intent. The editor's separate local Save/Load
  pair, which rebuilt the route while emptying the joker route and the grid, is
  gone. **Save As New**, **Overwrite** and **Delete** replace the duplicate
  buttons, and Overwrite and Delete act on the layout selected in the Track
  picker, so putting an edited track back needs no retyping.

### Changed (settings and visibility)

- **Session settings apply themselves - the Set buttons are gone.** **Laps**,
  **Max resets** and the qualifying **Laps / Minutes** boxes now apply half a
  second after you stop typing, or immediately when you click away from the
  box. Forgetting to press Set is a silent failure that turns up as the wrong
  race distance, and a commit button only earns its place when an edit is
  several fields that must land together - which is why the cup points tables
  keep theirs. An **empty box is never sent**: it means "still typing", so
  clearing `5` to type `12` cannot spend the moment in between running an open
  session. Unlimited resets is `-1` (a blank box used to mean it too, which
  cannot survive auto-apply).
- **Every checkpoint is brighter, in both of the ways one is drawn.** The hues
  are unchanged throughout - what a color means here is learned, and a driver
  who has learned that green is the gate they are heading for should not have to
  learn it twice.
  - **The editor rectangles** (white line, orange route, green next target,
    violet joker, amber pit) are each now at full value and near-full opacity
    instead of being that hue mixed with black. A gate at 70% alpha two thirds
    of the way to black is legible against tarmac at noon and close to invisible
    against snow, sand or a low sun. They are thin edges rather than fills, so a
    brighter gate still shows the track through the middle of itself.
  - **The race poles** are BeamNG's own markers, and its palette is built for
    its own races: `default` is a deep red-orange that reads as a silhouette
    against a bright map. Every mode is now lifted to the luminous version of
    the same color as the marker is created - once, on its own private copy of
    the table, so re-pointing a marker at the next gate can never wash it out
    further.
  - **The gate after the one you are on is no longer invisible.** The engine
    ships that mode black, because in its own races that gate is not your
    concern yet. This mod puts a marker there deliberately, so the line through
    the corner reads before the driver arrives - a job a black pole cannot do.
    It is painted the orange of the route ahead, a shade under the gate actually
    being aimed at.
  - The joker's on-track pole color moved with its editor color, and a test
    now pins the two together - a comment had claimed for a long time that they
    were the same color with nothing checking it.

### Changed (defaults)

- **Everyone on the server races by default.** Race entry used to default to
  opt-in, so a server nobody had configured started with a field of nobody. That
  is the setting that fails unsafe: an admin who has not realized it exists
  presses Generate Grid and forms an empty grid, leaving every driver standing
  while the one person who could fix it works out that a button they have never
  needed was the problem. The other way round, the mistake is that somebody who
  wanted to watch is put on the grid, and they undo it with one press of Leave.
  **Opt-in entry** is unchanged and one click away; the demo derby has defaulted
  to "everyone" since it was written, so this is the racing side agreeing with
  it.

### Added

- **Reverse grids.** A fourth **Grid order**: slowest qualifier on pole, fastest
  at the back, so the quick drivers have to come through the field. It inverts
  the *times* and nothing else - a driver who set no time still starts at the
  back, behind everyone who did. A literal reversal would put them on pole, and
  then the quickest way to start first is to sit in the pits and set nothing; a
  reverse grid is meant to reward the slow, not the absent.
- **The qualifying table stops calling its first column "Grid" when the grid is
  not going to match it.** Under a reverse, random or custom order that column
  is the qualifying position and now says so - it promised a slot the grid was
  about to contradict, which reverse grids made obvious but random and custom
  had been doing all along.
- **Every results file ends with the cup round it banked**, when a cup is
  running: the standings after the round, what each driver scored in it broken
  into race, qualifying and bonus points, the bonuses listed by name and
  recipient, and any manual adjustments. A championship that only exists inside
  the game leaves whoever compiles the standings retyping numbers off a
  screenshot. Derby results files carry the same section in the same layout
  a derby banks a round exactly as a race does, and a league reading two files
  from one evening should not have to learn two formats. The numbers come from
  the cup's own tables, so a file and the Cup panel cannot disagree about a
  total. The round is the one the event actually banked rather than "the round
  the cup is on", so an event that scored nothing prints nothing instead of the
  previous one's points; a race night with no cup running produces exactly the
  file it always did.
- **Qualifying is run to laps OR to a clock, and the panel now asks which.** The
  lap allowance and the time limit used to sit side by side as two boxes, and
  the server takes both numbers - so "3 laps and 10 minutes" was a state it
  could hold, and two boxes side by side is how it got armed by accident. A
  **Quali length** toggle picks Laps or Timed, only that box is shown, and the
  one not in use is sent as `0`. Switching applies immediately, so the limit the
  panel has stopped showing is never left armed underneath it. Whichever is
  picked, `0` still means unlimited. The panel lands on the mode the session is
  actually running when it is opened onto one somebody else set up.
- **Clear Results Cache asks first.** It now takes two presses, the same step
  End Cup is behind, and for the same reason: it deletes every saved results
  file on the server, there is no undo, and once a session is over that file is
  the only record a league has that the race happened. The button sits one row
  under Set Password in a panel an admin opens for other things.

### Changed

- **The first lap of a qualifying session is now an out lap: not timed, not
  scored, and not counted against the lap allowance.** Qualifying starts from a
  standing grid, so that lap measured a launch rather than a car and a driver
  over a circuit - and on any track with a slow first corner it set a time
  nobody could beat later in the session for reasons that had nothing to do with
  pace. The clock starts as a driver crosses the line for the first time.

  **The lap allowance is unchanged in meaning: three qualifying laps still means
  three timed laps**, now run after the out lap rather than including it. The
  session target counts crossings, so a 3 lap session ends on the fourth.

  This is not a return to the out-lap this mod removed. That one existed because
  qualifying had no defined start at all - drivers began from wherever they were
  parked, so the first crossing arrived at a different point of the circuit for
  everybody and a "3 lap" session took five or six laps to get through. This one
  starts on the grid with everyone else's and is counted separately from the
  allowance, so nothing is taken out of a driver's session.

- **A point-to-point stage has no out lap.** A sprint is driven once, first gate
  to last: a lap given away there is the whole session given away, and there is
  no line to come back past to start a timed one.

- **The out lap is never the crossing that ends a driver's session.** When a
  timed session's clock expires the next crossing is terminal for everyone still
  out - but a driver still on their out lap would have been stood down with no
  time at all, eliminated by the one lap the session had already promised not to
  score. They complete it, start their flying lap, and take the flag on that:
  the same one timed lap every other driver on track gets.

### Added

- **Drivers are told, rather than left to infer it from a time that never
  appears.** The lap readout shows `OUT LAP - NOT TIMED` in place of the running
  clock, then `OUT LAP DONE - TIMING` as they cross the line - a ticking clock
  on a lap that is not being timed is worse than no readout at all, because it
  is a number a driver will drive to. Chat announces the rule at GO and confirms
  each driver's out lap as they complete it, so it reaches a driver with no app
  open. The timing table shows `OUT LAP` in the Best Lap column for everyone
  still on theirs, so a blank is never mistaken for a lap gone wrong, and an
  **OUT LAP RULE** badge sits in the header for the session.
- **The results file records it.** The qualifying format line carries
  `out lap not timed`, so a lap count read months later by somebody who was not
  there still adds up against the number of times a driver crossed the line.

## 0.7.0 - Cup points, persistent names, derby arenas

### Added

- **Display names are now saved on the server and survive a restart.** Every
  name an admin sets is written to `Resources/Server/RaceManager/roster.json`
  as a saved driver, and cup points attach to that driver rather than to a
  connection. This reverses a documented limitation; see
  [Display names](docs/REFERENCE.md#display-names).
- **Who is who is an admin decision, never a guess.** BeamMP issues a fresh
  random guest name on every join, so a guest name identifies nobody: matching
  on one would miss a returning driver almost every time, and on the occasion
  two people were ever issued the same name it would hand a stranger somebody
  else's identity and their championship points. Nothing is assigned
  automatically. After a reconnect or a restart an admin either sets the name
  again or picks the driver from the Cup tab's new **Drivers** panel, which also
  warns how many connections are still unidentified.
- **Nobody loses points by being identified late.** A driver who races
  unassigned scores into a **placeholder**; assigning them afterwards moves
  those points onto the real driver and retires the placeholder. Placeholders
  left by drivers who never returned can be deleted outright.
- **The live timing broadcast is about 20% smaller.** A player record carries
  audit counters and comparator scratch that no client renders, and all of it
  was being serialised for the whole field three times a second. The broadcast
  now sends only what the app reads: ~4.7 KB instead of ~5.9 KB for a 20-car
  field. The saving is **bandwidth** - roughly 3.5 Mbit/s instead of 4.4 for a
  full grid, which is what a home-hosted server's uplink notices. Client-side
  the difference is immaterial (measured at hundredths of a millisecond per
  second), and CPU was never the constraint here.
- **The leaderboard no longer re-sorts itself.** It was ordering the driver
  array by a position integer that *is* that array's index, so the sort could
  never change anything. Removed as dead work rather than as an optimisation:
  the measured saving is 0.004 ms per second, which is nothing. The invariant it
  was guarding against is now checked directly, on every broadcast the stress
  test makes, in every phase.
- **A DNF keeps the place it was running in**, whatever ended the race - a
  disconnection, the admin closing the session, anything else. The results file
  records it beside the reason (`DNF - Disconnected (was P2)`).
- **A DNF is not always a nil score.** Three settings decide what one is worth:
  nothing (the default, as before), its place in the final classification, or
  the place it was actually running in when it stopped. The last of those can
  pay two drivers for the same position, which is what a series choosing it is
  asking for. A DNF is never counted as a win, and a disqualification still
  scores nothing.
- **Manual point adjustments.** Press ± on any standings row to add or remove
  points by hand, with a reason. Adjustments are kept as a ledger beside the
  points a driver earned and never folded into them, each with its reason and
  author, so a total can always be taken apart and checked - and removing one
  deletes it rather than posting an opposite entry. A whole round can be dropped
  from a driver's record when a race was scored wrongly.
- **Derbies score into the cup too.** A cup can be all races, all derbies or a
  mixture. Derbies score on a points table of their own (same presets, starting
  out matching the race table) on survival order - and unlike a race, *every*
  driver scores, because being eliminated is the result of a derby rather than a
  failure to produce one. Bonuses now belong to a discipline, so a derby can
  never collect a fastest-lap bonus; **Last Man Standing** is the derby one, and
  it pays only when somebody actually survived. Turning derby points off leaves
  derbies out of the cup entirely.
- **Standings keep race and derby apart and summarize them together.** The
  Combined table totals both; once a cup has held both kinds of event, Races and
  Derbies tabs show each championship on its own, each ranked on its own total.
- **Cup points.** A cup scores a championship across several races: position
  points for the race and optionally for qualifying, configurable bonus points
  for Fastest Lap, Halfway Led and Hard Charger, and standings that only an
  admin ending the cup can clear. Points survive Start Qualifying, Reset
  Session, a phase change and a server restart, because cup state lives in its
  own module and its own file (`cup.json`, kept out of the results directory so
  Clear Results Cache cannot reach it). Five scoring presets ship: 30P
  Aggressive, 25P Aggressive, 25P Moderate, 24P Linear and 35P Folk Race
  loading one fills the table, which you can then edit. With no cup running a
  race behaves exactly as it did. See [Cup points](docs/REFERENCE.md#cup-points).
- **A Cup tab**, under Race, with the scoring editor collapsed behind a toggle
  so the panel is one row until you want it. Drivers who are not admins see the
  standings read-only between sessions, and never during a live one.
- **Bonus points are configured, not coded.** The server ships a registry of
  bonus achievements and the panel builds a control per entry from it, so
  adding another kind of bonus later needs no UI work.

- **Rectangle arenas.** A derby boundary can now be pulled out from a center
  instead of driven corner by corner: stand where the middle should be, then set
  Width, Length and Rotation on sliders (with **Square** linking the first two).
  The four corners are derived from the shape and all sit at the center's
  height - the out-of-bounds test has always ignored height, so a flat plane is
  what the rule actually is.
- **The drive-and-place editor is unchanged and still there**, as the other half
  of a mode toggle. It remains the only way to build a non-rectangular arena.
  Switching between the two keeps the work: a rectangle becomes four ordinary
  markers, and a hand-driven arena becomes the rectangle that bounds it.
- **Wall height**, 2–30 m, for either kind of arena. Visual only.

### Changed

- **No car is handed its collisions back while another car is inside it - for
  any ghosted condition.** Previously only the driver's own reset ghost waited
  for a clear space; the field-wide ghosts (mass respawn, ghost qualifying) and
  the pit ghost were released on a timer, so cars could go solid still
  overlapping. And the clear check deliberately ignored cars that were
  themselves ghosts, which made it useless exactly where it is needed most:
  after a race the whole field is respawned at once, so every car was a ghost
  and every car looked clear to every other one. Every ghost now returns through
  one gate that asks one question, and a car that cannot go solid yet is retried
  until it can. Two overlapping ghosts cannot deadlock - being intangible is
  what lets them drive apart.
- **Loading a scoring preset fills the boxes.** The editors were re-seeded from
  the server "unless the buffer differs from it" - but pressing Load is exactly
  a case where the server's value changes, which that rule reads as an edit in
  progress. The boxes kept the old preset, and pressing Apply then posted those
  stale numbers back and turned the table into a hand-edited "Custom" one. The
  panel now re-seeds when the *server's* value has moved, so Load lands and
  typing is still safe from a broadcast arriving mid-edit. Both tables affected;
  both fixed.
- **The cup's dropdowns open.** The scoring presets and the driver picker were
  native `<select>` elements. In BeamNG's UI - Chromium Embedded Framework - a
  select popup is a separate OS window that never renders over the game, so the
  box showed its value and clicking it did nothing at all, with no error
  anywhere. They are now the same custom menu the track-layout picker has always
  used, and `ui_bindings_test` fails if a native `<select>` reappears.

- **The release package now spells the two folders `Client/` and `Server/`.**
  They map straight onto a BeamMP server's `Resources/Client` and
  `Resources/Server`, and Linux - where a good share of servers are hosted
  cares about the difference: the old lowercase folders dropped into
  `Resources/` looked installed and were simply never read, with no error to go
  on. It matched on Windows, which is why it survived this long. Upgrading on a
  Linux host, delete any leftover lowercase `Resources/client` or
  `Resources/server`. The packaging workflow now prints the layout on every run
  and refuses to publish a package missing either folder.

- **The derby arena is drawn as walls, not poles and rope** - a translucent
  panel per edge, drawn from both sides so it is there from inside the arena as
  well as outside it.
- **An active derby no longer looks like an editor.** Authoring visuals - the
  filled floor, corner numbers, the arena label, the center crosshair, the full
  set of numbered start slots - belong to an admin with the Derby Editor open.
  Everyone else, including that admin once a field has formed up, gets faint
  walls and a ground rail. The boundary itself is still always drawn during a
  derby; leaving it is what eliminates you. Start slots used to be drawn for
  every driver on the server whether or not a derby was near starting; now you
  see your own slot as you are placed on it, and nothing after GO.
- **Race and Derby are separated by mode.** A mode bar (🏁 Race · 💥 Derby ·
  ⚙ Admin) sits above the tab strip, and each mode carries its own controls and
  its own Editor sub-tab. The race session controls and the **Track layout
  picker used to render over the Derby tab**, offering a Load Layout button for a
  race nobody was setting up. Nothing was removed - every control is still there
  under the mode it belongs to, and the last sub-tab per mode is remembered.
- **The leaderboard follows the mode as well.** An admin in Derby mode was
  looking at a race table below the derby panel - and since a derby never
  touches race state, that table was the *last race's* field (or the last
  qualifying times), presented as though it were live. Derby mode now shows the
  derby standings there, on both derby sub-tabs, so the field is visible while
  an arena is being built. The duplicate copy of the standings inside the Derby
  panel is gone; there is one board, not two.

### Fixed

- **A car could be left ghosted for the rest of a race, and no reset would fix
  it.** The field-wide ghost reasons ("rivals are ghosts" during a mass respawn
  or qualifying) skip your own car when applying - but your car is identified by
  asking BeamMP who owns it, and a respawn opens a window where that question
  has no answer yet. The re-assert sweep fires inside that window and the reason
  lands on your own car; lifting it later skipped your car, because by then
  ownership *had* resolved. Nothing could take it off after that. A reset ghost
  layered on top came and went, and the car underneath stayed held - so it
  flashed solid as the timer ended and went straight back to being a ghost.
  Lifting a reason now skips nothing.
- **Reset Session clears the ghost roster.** A ghost ends when the client that
  owns it reports its car is clear, and a client that has been through a session
  reset has no such report to give - so a stuck ghost survived the reset and
  every other client kept seeing that car as intangible.
- **A car left parked in a pit stall no longer serves stop after stop.** The
  cooldown was meant to stop the box you are standing in re-triggering, but a
  timer only delays that: a car still in the stall when it expires is caught
  again, and again. Each stop freezes and ghosts it, so the car appears stuck as
  a ghost for the rest of the race - the reset ghost would count down, flash
  solid, and go straight back. Resetting in the pits is how a driver ends up
  parked there, since a reset in place leaves the car exactly where it stood.
  A stall now re-arms when the car **leaves** it, which is what "live on the
  next visit" always meant. Driving out and coming back still works normally.

- **A derby is now "live" for the UI from Form Up, not from GO.** Both the
  driver's minimal mode and their derby board keyed on `phase === 'running'`,
  which predates the two-step start - so a driver held on the derby grid through
  the countdown kept the full spectator chrome and the previous race's
  leaderboard until the field was released.
- **The joker route is violet again on track, and keeps its wording.** The
  checkpoint refactor moved drivers onto BeamNG's gate poles, whose stock
  alternate-route mode is *orange* - close enough to the main route's red-orange
  that the joker stopped reading as a separate route, on the one route where
  that mistake is a disqualification. The pole is now painted the same violet the
  editor uses, and the editor's own label sits above it: `JOKER 2/3`,
  `(lap 1: closed)`, `(used)`. The label is drawn separately because the engine's
  gate markers render no text whatsoever. A joker already taken now stays
  signposted, dimmed, instead of vanishing.
- **A pit stop is something you perform again, not something that happens to
  you.** The stall triggered on its box alone, so clipping a corner of one at
  racing speed seized the car and froze it mid-lane. You now have to bring the
  car to a stop inside the box; run through without stopping and you simply miss
  it, with no cooldown spent, so the stall is live on the next lap.
- **A car serving a pit stop is ghosted for the stop.** It is frozen, so it
  cannot move out of the way, and it is parked where everyone else arrives slowly
  and off-line. The ghost is re-asserted after the repair - that reloads the
  vehicle VM, which silently dropped it, the same way it drops the freeze - and
  it rides the server's reset-ghosting switch so every client agrees about which
  cars are ghosts.

### Compatibility

- **Saved arenas from earlier builds load unchanged**, as drive-and-place
  arenas. `derbyArenas.json` moves to `version: 2` by adding three optional
  fields; a v1 entry simply has none of them, so there is no migration step. A
  rectangle is stored as *both* its shape and the polygon it produced, so it
  loads back editable by slider and stays readable by anything that only
  understands the polygon.
- Gameplay reads `boundary` and nothing else, in both modes - the out-of-bounds
  test, the broadcast and the results export are untouched.
- Mixed client/server versions degrade cleanly: an older client ignores the new
  fields and reads the four corners as an ordinary polygon; an older server
  ignores the two new events.

## 0.6.0 - Checkpoint refactor

### Added

- **Race checkpoints now look like race checkpoints.** During a session a driver
  sees BeamNG's own gate poles on the next two gates rather than the whole
  circuit drawn as numbered rectangles. The rectangles are the editor's view and
  only an admin with the editor open sees them - filled, translucent, numbered,
  with an arrow showing which way through each gate counts.
- **Point-to-point stages.** A toggle on the Main Route row switches a track
  between a circuit and a sprint driven once from first gate to last. Saved with
  the layout; the gates relabel to START/FINISH, the header carries a badge, and
  the Laps field says "driven once" instead of accepting a number.
- **Pit stalls.** An optional pit lane: drive into a stall and the car is held,
  repaired in place and released. Stalls live outside the checkpoint list, so
  they can never affect laps or splits, and a pit stop is not a driver reset.
- **Every gate owns its size.** The first gate of a route takes the standard
  default and each one after inherits from the gate placed before it, so a
  creator sets it once and drives the route. The global width/height that every
  gate without an override read *live* is gone: nudging it resized the whole
  circuit retroactively with no way back. Existing layouts are unaffected
  each gate is given the size it was drawn with as the layout loads.
- Layout selection moved out of the editor into the session controls, so running
  a saved race never means opening the editor.

## 0.5.1 - Ghost release fix

### Fixed

- **A reset ghost could still last most of a race.** The occupancy check that
  decides when collisions come back has three ways to measure a car, and 0.5.0
  had only two of them plus a blunt fallback: if neither bounding box answered,
  the check fell through to a flat radius wide enough to contain the largest
  pair of vehicles. In a full field somebody is nearly always inside a radius
  that size, so the ghost stayed up. Between the boxes and that radius there is
  now a real measurement - the car's own dimensions, oriented by where it is
  facing - which every vehicle can answer for even when neither bounding box
  will say where it is. The radius is a genuine last resort again rather than
  the common path.

- **`raceManager.ghostStatus()`**, for the in-game Lua console. Reports whether
  a car is ghosted, WHICH of the three sources is measuring the space around it,
  and what is blocking the restore. There was previously no way to tell a field
  where the bounding boxes resolve from one where they never do, which is
  exactly the difference that produced this bug.

## 0.5.0 - Reset ghosting

### Added

- **Reset ghosting.** A driver who resets, recovers or teleports mid-session no
  longer reappears as a solid, stationary obstacle in the middle of the track.
  Their car loses vehicle-to-vehicle collisions for five seconds - in both
  directions, so it can neither be hit nor hit anyone - while world and terrain
  collision are untouched. Other drivers see the car go translucent and fade
  back to solid over the final second as a warning that contact is resuming;
  the ghosted driver gets their own countdown in the app. On by default, in
  races and in qualifying. See
  [Reset ghosting](docs/REFERENCE.md#reset-ghosting) for the seven settings.

- **An occupancy check before collisions come back.** Restoring collisions on
  two overlapping cars welds their node structures together, ends both races and
  cannot be undone. So the ghost does not simply expire: when the timer runs out
  the space around the car is measured against every other car - a real
  oriented-bounding-box test, so a car lying crossways through another is caught
  where a distance between origins would call it clear - and collisions return
  only on a frame that is provably clear. The check has no time limit and no
  override. A car parked inside another stays a ghost indefinitely and goes
  solid the moment the space clears. Every way of failing to *know* the space is
  clear counts as occupied.

- **Server-side ghost logging.** Every ghost records the driver, the race time,
  their running order, their lap and their distance to the next checkpoint, so
  reset-to-phase-through-a-pack is answerable from the log. A driver blocked
  inside another car for more than ten seconds is told to move clear and the
  block is logged. Both are warnings - nothing here penalises anyone.

- **The session's fastest lap is shown in gold** on every leaderboard, and the
  driver who set it is told so on the existing notice channel. The server owns
  which lap is fastest - it is tracked as laps are scored, not derived by
  scanning the field, and it rides on a broadcast that was already going out, so
  there is no extra per-frame or per-tick work. It belongs to the session: a new
  race starts with nobody holding it. Qualifying highlights the quali best,
  the race highlights the race best.

- **The results file records where each driver started.** A `Start` column
  between Pos and Driver, so a finishing position means something - "P2" reads
  very differently when the driver qualified eighth.

- **Half-way leader in the results.** Whoever completed the half-distance lap
  first, rounded **up** on an odd number of laps - a 5-lap race is decided at
  lap 3, the same as a 6-lap one. It is a lookup of the lap-leader table the
  Laps Led count already maintains, so it costs nothing. A one-lap race has no
  half way and reports none.

- **Hard Charger in the results.** The classified finisher who gained the most
  places between their grid slot and the flag, named at the foot of the race
  table with the gain. A tie goes to the higher finisher. Drivers who did not
  finish are not eligible, and if nobody gained a place the line is omitted
  rather than awarded to whoever went backwards least.

### Fixed

- **Cars could creep forward during the grid hold.** The hold was a single
  fire-and-forget freeze issued at placement, with nothing verifying it and
  nothing re-asserting it - and BeamNG reports the placement teleport back as a
  vehicle reset, which reloads the vehicle's Lua VM and takes the freeze with
  it. The re-apply only ran when that report was recognized as the mod's own
  echo, inside a 0.6 s window, so three ordinary things left a car free for the
  whole countdown: the report arriving late (likelier the more loaded the
  client), the driver pressing reset on the grid, and the driver reloading their
  vehicle on the grid. Because nothing re-asserted the freeze, any one of them
  was permanent.

  The hold is now **verified and server-authoritative**. Each client watches its
  own held car and puts it back on its slot if it moves or starts moving; each
  held car reports its position to the server, which judges it against the real
  slot coordinates and corrects anything more than 0.5 m off, logging the driver,
  distance, slot and race state. Reset-on-grid and respawn-on-grid put the driver
  back on their slot, still held. A car standing still is never touched, so
  revving against the hold and pre-selecting a gear still work. See
  [Holding the grid](docs/REFERENCE.md#holding-the-grid).

- **A car placed on the grid hovered and reset every frame** (regression, found
  in live testing). The hold guard treated a car settling onto its suspension as
  a car creeping off its slot, teleported it back up to the height it was
  dropped from, and the teleport was reported as a vehicle reset - every frame,
  spamming the console. Placement is now left alone until the car comes to rest,
  the resting position is what drift is measured from, distances are measured
  across the ground rather than in three dimensions, and a car that is merely
  moving is re-pinned where it stands instead of being teleported. The settle
  grace is not a window in which the hold is off: a car that drives away before
  it settles is still put back.

- **A reset ghost could last the whole race, and outlive it** (regression, found
  in live testing). The occupancy check answered "occupied" on *any* uncertainty,
  including a car it simply could not measure - and that was a verdict nothing
  could revisit, so one unmeasurable vehicle anywhere on the map kept a driver
  ghosted indefinitely. `getSpawnWorldOOBB` returns nil more often than assumed;
  BeamNG's own code nil-guards it.

  Uncertainty is still resolved conservatively, but it now always resolves.
  Bounds fall back to the axis-aligned world box (the same one BeamNG's spawn
  occupancy test uses), and a car that still cannot be measured is judged on
  distance instead of being assumed to be inside us - conservative, but finite.
  Waiting for a car to report a bounding box before starting its timer is capped
  too, since that was a second way to wait forever. The block reason is logged,
  so a ghost that does persist says why. Separately, the end of a session now
  clears every car in the world rather than only the ones this client believes it
  ghosted: a session ending leaves nothing intangible, whatever the bookkeeping
  thinks.

- **The end-of-session respawn only ghosted the drivers being respawned.** A
  driver still running when the session ended never lost their car, so their
  client ignored the release and they sat solid in the middle of a field
  materialising around them. Every client now ghosts for the respawn window, and
  a car that appears during one is ghosted immediately rather than waiting up to
  two seconds for the re-assert sweep.

- **Beating your own fastest lap said nothing.** The notice was keyed on who
  held the lap, so a driver improving their own best - the case they most want
  to hear about - saw nothing because the holder had not changed. It is keyed on
  the time as well now.

- **Ghost qualifying never actually removed collisions.** It probed
  `MPVehicleGE` for `setGhostMode` / `setGhosts` / `enableGhostMode`, none of
  which exist on any BeamMP build, and fell back to fading rival cars while
  leaving them solid - so the rule looked as though it worked and did not. The
  collision toggle is BeamNG's own vehicle-side `obj:setGhostEnabled`, reached
  through `queueLuaCommand`. Ghost qualifying now does what it has always said
  it does. `docs/COMPATIBILITY.md` recorded the wrong conclusion and has been
  corrected.

- **Field placement no longer skips a rival's car when your own has been
  deleted.** The placement ghost excluded "the car this client is attached to",
  and the moment your car is removed the game attaches you to somebody else's
  so the one car you were about to be respawned next to was the only solid thing
  on track. It now asks which car is genuinely *ours*.

### Changed

- Ghosting is refcounted **per vehicle** rather than as one global flag, so
  simultaneous ghosts are independent and none can end another's. Qualifying,
  field placement and reset ghosting all share that one mechanism.

- Ghost state is broadcast keyed by **player id**, not vehicle id: a vehicle id
  is a local scene-object id and refers to a different car on every client.
  The authoritative roster rides on the ordinary state broadcast, so a client
  joining or reconnecting mid-ghost sees it correctly, with a one-shot event
  alongside it so the ghost applies immediately rather than on the next state
  push.

- Remaining ghost time travels as an absolute end time on the server clock, so
  latency makes a ghost *shorter* on a late client rather than longer, and every
  client agrees on the instant the fade completes.
