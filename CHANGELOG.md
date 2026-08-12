# Changelog

Notable changes per release. The version here is the same number as the git
tag, the packaged zip, and the build stamp the app shows — see the note in
`server/RaceManager/main.lua` for why those four have to agree.

[← Back to the README](README.md)

## 0.7.0 — Cup points, persistent names, derby arenas

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
  field. The saving is **bandwidth** — roughly 3.5 Mbit/s instead of 4.4 for a
  full grid, which is what a home-hosted server's uplink notices. Client-side
  the difference is immaterial (measured at hundredths of a millisecond per
  second), and CPU was never the constraint here.
- **The leaderboard no longer re-sorts itself.** It was ordering the driver
  array by a position integer that *is* that array's index, so the sort could
  never change anything. Removed as dead work rather than as an optimisation:
  the measured saving is 0.004 ms per second, which is nothing. The invariant it
  was guarding against is now checked directly, on every broadcast the stress
  test makes, in every phase.
- **A DNF keeps the place it was running in**, whatever ended the race — a
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
  author, so a total can always be taken apart and checked — and removing one
  deletes it rather than posting an opposite entry. A whole round can be dropped
  from a driver's record when a race was scored wrongly.
- **Derbies score into the cup too.** A cup can be all races, all derbies or a
  mixture. Derbies score on a points table of their own (same presets, starting
  out matching the race table) on survival order — and unlike a race, *every*
  driver scores, because being eliminated is the result of a derby rather than a
  failure to produce one. Bonuses now belong to a discipline, so a derby can
  never collect a fastest-lap bonus; **Last Man Standing** is the derby one, and
  it pays only when somebody actually survived. Turning derby points off leaves
  derbies out of the cup entirely.
- **Standings keep race and derby apart and summarise them together.** The
  Combined table totals both; once a cup has held both kinds of event, Races and
  Derbies tabs show each championship on its own, each ranked on its own total.
- **Cup points.** A cup scores a championship across several races: position
  points for the race and optionally for qualifying, configurable bonus points
  for Fastest Lap, Halfway Led and Hard Charger, and standings that only an
  admin ending the cup can clear. Points survive Start Qualifying, Reset
  Session, a phase change and a server restart, because cup state lives in its
  own module and its own file (`cup.json`, kept out of the results directory so
  Clear Results Cache cannot reach it). Five scoring presets ship: 30P
  Aggressive, 25P Aggressive, 25P Moderate, 24P Linear and 35P Folk Race —
  loading one fills the table, which you can then edit. With no cup running a
  race behaves exactly as it did. See [Cup points](docs/REFERENCE.md#cup-points).
- **A Cup tab**, under Race, with the scoring editor collapsed behind a toggle
  so the panel is one row until you want it. Drivers who are not admins see the
  standings read-only between sessions, and never during a live one.
- **Bonus points are configured, not coded.** The server ships a registry of
  bonus achievements and the panel builds a control per entry from it, so
  adding another kind of bonus later needs no UI work.

- **Rectangle arenas.** A derby boundary can now be pulled out from a centre
  instead of driven corner by corner: stand where the middle should be, then set
  Width, Length and Rotation on sliders (with **Square** linking the first two).
  The four corners are derived from the shape and all sit at the centre's
  height — the out-of-bounds test has always ignored height, so a flat plane is
  what the rule actually is.
- **The drive-and-place editor is unchanged and still there**, as the other half
  of a mode toggle. It remains the only way to build a non-rectangular arena.
  Switching between the two keeps the work: a rectangle becomes four ordinary
  markers, and a hand-driven arena becomes the rectangle that bounds it.
- **Wall height**, 2–30 m, for either kind of arena. Visual only.

### Changed

- **Loading a scoring preset fills the boxes.** The editors were re-seeded from
  the server "unless the buffer differs from it" — but pressing Load is exactly
  a case where the server's value changes, which that rule reads as an edit in
  progress. The boxes kept the old preset, and pressing Apply then posted those
  stale numbers back and turned the table into a hand-edited "Custom" one. The
  panel now re-seeds when the *server's* value has moved, so Load lands and
  typing is still safe from a broadcast arriving mid-edit. Both tables affected;
  both fixed.
- **The cup's dropdowns open.** The scoring presets and the driver picker were
  native `<select>` elements. In BeamNG's UI — Chromium Embedded Framework — a
  select popup is a separate OS window that never renders over the game, so the
  box showed its value and clicking it did nothing at all, with no error
  anywhere. They are now the same custom menu the track-layout picker has always
  used, and `ui_bindings_test` fails if a native `<select>` reappears.

- **The release package now spells the two folders `Client/` and `Server/`.**
  They map straight onto a BeamMP server's `Resources/Client` and
  `Resources/Server`, and Linux — where a good share of servers are hosted —
  cares about the difference: the old lowercase folders dropped into
  `Resources/` looked installed and were simply never read, with no error to go
  on. It matched on Windows, which is why it survived this long. Upgrading on a
  Linux host, delete any leftover lowercase `Resources/client` or
  `Resources/server`. The packaging workflow now prints the layout on every run
  and refuses to publish a package missing either folder.

- **The derby arena is drawn as walls, not poles and rope** — a translucent
  panel per edge, drawn from both sides so it is there from inside the arena as
  well as outside it.
- **An active derby no longer looks like an editor.** Authoring visuals — the
  filled floor, corner numbers, the arena label, the centre crosshair, the full
  set of numbered start slots — belong to an admin with the Derby Editor open.
  Everyone else, including that admin once a field has formed up, gets faint
  walls and a ground rail. The boundary itself is still always drawn during a
  derby; leaving it is what eliminates you. Start slots used to be drawn for
  every driver on the server whether or not a derby was near starting; now you
  see your own slot as you are placed on it, and nothing after GO.
- **Race and Derby are separated by mode.** A mode bar (🏁 Race · 💥 Derby ·
  ⚙ Admin) sits above the tab strip, and each mode carries its own controls and
  its own Editor sub-tab. The race session controls and the **Track layout
  picker used to render over the Derby tab**, offering a Load Layout button for a
  race nobody was setting up. Nothing was removed — every control is still there
  under the mode it belongs to, and the last sub-tab per mode is remembered.
- **The leaderboard follows the mode as well.** An admin in Derby mode was
  looking at a race table below the derby panel — and since a derby never
  touches race state, that table was the *last race's* field (or the last
  qualifying times), presented as though it were live. Derby mode now shows the
  derby standings there, on both derby sub-tabs, so the field is visible while
  an arena is being built. The duplicate copy of the standings inside the Derby
  panel is gone; there is one board, not two.

### Fixed

- **A car could be left ghosted for the rest of a race, and no reset would fix
  it.** The field-wide ghost reasons ("rivals are ghosts" during a mass respawn
  or qualifying) skip your own car when applying — but your car is identified by
  asking BeamMP who owns it, and a respawn opens a window where that question
  has no answer yet. The re-assert sweep fires inside that window and the reason
  lands on your own car; lifting it later skipped your car, because by then
  ownership *had* resolved. Nothing could take it off after that. A reset ghost
  layered on top came and went, and the car underneath stayed held — so it
  flashed solid as the timer ended and went straight back to being a ghost.
  Lifting a reason now skips nothing.
- **Reset Session clears the ghost roster.** A ghost ends when the client that
  owns it reports its car is clear, and a client that has been through a session
  reset has no such report to give — so a stuck ghost survived the reset and
  every other client kept seeing that car as intangible.
- **A car left parked in a pit stall no longer serves stop after stop.** The
  cooldown was meant to stop the box you are standing in re-triggering, but a
  timer only delays that: a car still in the stall when it expires is caught
  again, and again. Each stop freezes and ghosts it, so the car appears stuck as
  a ghost for the rest of the race — the reset ghost would count down, flash
  solid, and go straight back. Resetting in the pits is how a driver ends up
  parked there, since a reset in place leaves the car exactly where it stood.
  A stall now re-arms when the car **leaves** it, which is what "live on the
  next visit" always meant. Driving out and coming back still works normally.

- **A derby is now "live" for the UI from Form Up, not from GO.** Both the
  driver's minimal mode and their derby board keyed on `phase === 'running'`,
  which predates the two-step start — so a driver held on the derby grid through
  the countdown kept the full spectator chrome and the previous race's
  leaderboard until the field was released.
- **The joker route is violet again on track, and keeps its wording.** The
  checkpoint refactor moved drivers onto BeamNG's gate poles, whose stock
  alternate-route mode is *orange* — close enough to the main route's red-orange
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
  and off-line. The ghost is re-asserted after the repair — that reloads the
  vehicle VM, which silently dropped it, the same way it drops the freeze — and
  it rides the server's reset-ghosting switch so every client agrees about which
  cars are ghosts.

### Compatibility

- **Saved arenas from earlier builds load unchanged**, as drive-and-place
  arenas. `derbyArenas.json` moves to `version: 2` by adding three optional
  fields; a v1 entry simply has none of them, so there is no migration step. A
  rectangle is stored as *both* its shape and the polygon it produced, so it
  loads back editable by slider and stays readable by anything that only
  understands the polygon.
- Gameplay reads `boundary` and nothing else, in both modes — the out-of-bounds
  test, the broadcast and the results export are untouched.
- Mixed client/server versions degrade cleanly: an older client ignores the new
  fields and reads the four corners as an ordinary polygon; an older server
  ignores the two new events.

## 0.6.0 — Checkpoint refactor

### Added

- **Race checkpoints now look like race checkpoints.** During a session a driver
  sees BeamNG's own gate poles on the next two gates rather than the whole
  circuit drawn as numbered rectangles. The rectangles are the editor's view and
  only an admin with the editor open sees them — filled, translucent, numbered,
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
  circuit retroactively with no way back. Existing layouts are unaffected —
  each gate is given the size it was drawn with as the layout loads.
- Layout selection moved out of the editor into the session controls, so running
  a saved race never means opening the editor.

## 0.5.1 — Ghost release fix

### Fixed

- **A reset ghost could still last most of a race.** The occupancy check that
  decides when collisions come back has three ways to measure a car, and 0.5.0
  had only two of them plus a blunt fallback: if neither bounding box answered,
  the check fell through to a flat radius wide enough to contain the largest
  pair of vehicles. In a full field somebody is nearly always inside a radius
  that size, so the ghost stayed up. Between the boxes and that radius there is
  now a real measurement — the car's own dimensions, oriented by where it is
  facing — which every vehicle can answer for even when neither bounding box
  will say where it is. The radius is a genuine last resort again rather than
  the common path.

- **`raceManager.ghostStatus()`**, for the in-game Lua console. Reports whether
  a car is ghosted, WHICH of the three sources is measuring the space around it,
  and what is blocking the restore. There was previously no way to tell a field
  where the bounding boxes resolve from one where they never do, which is
  exactly the difference that produced this bug.

## 0.5.0 — Reset ghosting

### Added

- **Reset ghosting.** A driver who resets, recovers or teleports mid-session no
  longer reappears as a solid, stationary obstacle in the middle of the track.
  Their car loses vehicle-to-vehicle collisions for five seconds — in both
  directions, so it can neither be hit nor hit anyone — while world and terrain
  collision are untouched. Other drivers see the car go translucent and fade
  back to solid over the final second as a warning that contact is resuming;
  the ghosted driver gets their own countdown in the app. On by default, in
  races and in qualifying. See
  [Reset ghosting](docs/REFERENCE.md#reset-ghosting) for the seven settings.

- **An occupancy check before collisions come back.** Restoring collisions on
  two overlapping cars welds their node structures together, ends both races and
  cannot be undone. So the ghost does not simply expire: when the timer runs out
  the space around the car is measured against every other car — a real
  oriented-bounding-box test, so a car lying crossways through another is caught
  where a distance between origins would call it clear — and collisions return
  only on a frame that is provably clear. The check has no time limit and no
  override. A car parked inside another stays a ghost indefinitely and goes
  solid the moment the space clears. Every way of failing to *know* the space is
  clear counts as occupied.

- **Server-side ghost logging.** Every ghost records the driver, the race time,
  their running order, their lap and their distance to the next checkpoint, so
  reset-to-phase-through-a-pack is answerable from the log. A driver blocked
  inside another car for more than ten seconds is told to move clear and the
  block is logged. Both are warnings — nothing here penalises anyone.

- **The session's fastest lap is shown in gold** on every leaderboard, and the
  driver who set it is told so on the existing notice channel. The server owns
  which lap is fastest — it is tracked as laps are scored, not derived by
  scanning the field, and it rides on a broadcast that was already going out, so
  there is no extra per-frame or per-tick work. It belongs to the session: a new
  race starts with nobody holding it. Qualifying highlights the quali best,
  the race highlights the race best.

- **The results file records where each driver started.** A `Start` column
  between Pos and Driver, so a finishing position means something — "P2" reads
  very differently when the driver qualified eighth.

- **Half-way leader in the results.** Whoever completed the half-distance lap
  first, rounded **up** on an odd number of laps — a 5-lap race is decided at
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
  nothing re-asserting it — and BeamNG reports the placement teleport back as a
  vehicle reset, which reloads the vehicle's Lua VM and takes the freeze with
  it. The re-apply only ran when that report was recognised as the mod's own
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
  dropped from, and the teleport was reported as a vehicle reset — every frame,
  spamming the console. Placement is now left alone until the car comes to rest,
  the resting position is what drift is measured from, distances are measured
  across the ground rather than in three dimensions, and a car that is merely
  moving is re-pinned where it stands instead of being teleported. The settle
  grace is not a window in which the hold is off: a car that drives away before
  it settles is still put back.

- **A reset ghost could last the whole race, and outlive it** (regression, found
  in live testing). The occupancy check answered "occupied" on *any* uncertainty,
  including a car it simply could not measure — and that was a verdict nothing
  could revisit, so one unmeasurable vehicle anywhere on the map kept a driver
  ghosted indefinitely. `getSpawnWorldOOBB` returns nil more often than assumed;
  BeamNG's own code nil-guards it.

  Uncertainty is still resolved conservatively, but it now always resolves.
  Bounds fall back to the axis-aligned world box (the same one BeamNG's spawn
  occupancy test uses), and a car that still cannot be measured is judged on
  distance instead of being assumed to be inside us — conservative, but finite.
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
  held the lap, so a driver improving their own best — the case they most want
  to hear about — saw nothing because the holder had not changed. It is keyed on
  the time as well now.

- **Ghost qualifying never actually removed collisions.** It probed
  `MPVehicleGE` for `setGhostMode` / `setGhosts` / `enableGhostMode`, none of
  which exist on any BeamMP build, and fell back to fading rival cars while
  leaving them solid — so the rule looked as though it worked and did not. The
  collision toggle is BeamNG's own vehicle-side `obj:setGhostEnabled`, reached
  through `queueLuaCommand`. Ghost qualifying now does what it has always said
  it does. `docs/COMPATIBILITY.md` recorded the wrong conclusion and has been
  corrected.

- **Field placement no longer skips a rival's car when your own has been
  deleted.** The placement ghost excluded "the car this client is attached to",
  and the moment your car is removed the game attaches you to somebody else's —
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
