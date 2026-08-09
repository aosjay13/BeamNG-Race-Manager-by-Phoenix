# Changelog

Notable changes per release. The version here is the same number as the git
tag, the packaged zip, and the build stamp the app shows — see the note in
`server/RaceManager/main.lua` for why those four have to agree.

[← Back to the README](README.md)

## Unreleased — checkpoint refactor

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
