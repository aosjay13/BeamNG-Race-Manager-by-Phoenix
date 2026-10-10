-- Race Manager - client GE extension (BeamMP bridge + checkpoint editor)
--
-- Multiplayer-only for racing. The BeamMP server (server/RaceManager/main.lua)
-- owns the session state; this extension does what only a client can do:
--   1. Checkpoint editor: place gate-style checkpoints at the local vehicle's
--      position AND heading. Each checkpoint is a FLAT RECTANGLE standing
--      perpendicular to the travel direction - a width (lateral span) by a
--      height (vertical extent, so high banking still gets covered). Both are
--      adjustable globally and per checkpoint from the UI.
--   2. Detect the LOCAL vehicle crossing each gate, in order, by intersecting
--      the frame-to-frame movement segment with that rectangle (the server has
--      no physics access). The last checkpoint placed is the start/finish line;
--      completing the checkpoint sequence and crossing it again scores a lap,
--      which is timed locally and reported upstream on RM_Lap. ONE event for
--      both kinds of session: which laps count is the server's rule, not this
--      file's (qualifying, for one, does not count the first).
--   3. Starting grid: place start positions along the grid, then put the local
--      car on the slot the server assigns and hold it there until GO.
--   4. Receive the server's state broadcasts, reset local lap tracking on
--      session changes, and hand the data to the UI app via guihooks.
--
-- Runs in BeamNG's GE Lua (LuaJIT / Lua 5.1 semantics) and talks to the
-- server through BeamMP's client bridge (TriggerServerEvent / AddEventHandler).
--
-- Author: Phoenix

local M = {}

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
-- One table, not a local apiece: the top level is near Lua's 200-local limit,
-- and going over stops the file compiling, with no error in game.
local TUNE = {
  DEFAULT_WIDTH = 20,    -- meters across the gate (lateral span)
  MIN_WIDTH = 2,
  MAX_WIDTH = 120,
  -- HEIGHT IS UP, DEPTH IS DOWN, both from the placement point, so a tall gate
  -- does not bury an equal amount of itself under the road.
  DEFAULT_HEIGHT = 8,     -- meters the gate rises ABOVE the placement point
  MIN_HEIGHT = 1,
  MAX_HEIGHT = 100,
  DEFAULT_DEPTH = 2,      -- meters it drops BELOW it
  -- Zero: the bottom bar never sits above the placement point.
  MIN_DEPTH = 0,
  MAX_DEPTH = 100,
  EDGE_RADIUS = 0.15,  -- meters; thickness of the drawn rectangle edge
  -- A race pole: fatter than an editor edge, but 0.35 read as pillars.
  POLE_RADIUS = 0.18,
  GHOST_ALPHA = 0.35,  -- mesh alpha applied to a ghosted car
  -- How far a placed thing clears the ground under it. A driven gate takes the
  -- car's origin, a clicked one the terrain hit; both are lifted by this.
  GROUND_CLEAR = 0.5,
  -- Meters per shift+scroll step on a selected gate.
  NUDGE_LIFT_PER_STEP = 0.75,
  -- One press of Raise/Lower: bigger than a scroll step, to dig a gate out.
  NUDGE_LIFT_PER_PRESS = 2.0,
  -- Furthest one drag or ctrl+click may move a gate: a cursor ray near the
  -- horizon lands kilometers away.
  NUDGE_MAX_REACH = 500,
  -- Meters the cursor must travel before a drag moves anything (hand and
  -- raycast jitter).
  NUDGE_DRAG_MIN = 0.15,
  -- Frames a panel press suppresses world picking: the button's Lua can run a
  -- frame or two after the click is seen here.
  NUDGE_UI_GRACE = 3,
  -- Frames between panel pushes mid-drag: each push serialises the whole route.
  NUDGE_PUSH_FRAMES = 6,
  -- Heights to look for a buried point's surface at, shortest first, so the
  -- lowest surface above it wins and overhead geometry is never reached.
  GROUND_RESCUE_STEPS = { 2, 5, 12, 30, 60, 150 },
  GROUND_PROBE_DOWN = 200,
  -- Last Checkpoint respawn (snapshot.trackZ). Heights above the road to look
  -- for a higher surface at the gate's center, for a car that crossed low on a
  -- banking. Short steps first, so an arch over the line is never reached.
  RESPAWN_SEARCH_UP = { 0.5, 1, 2, 3, 4, 6, 8, 10 },
  -- Most ride height a respawn keeps. A car airborne through the gate must not
  -- respawn in the air.
  RESPAWN_RIDE_MAX = 3.0,
  -- Reset ghost DURATIONS are a league rule the server broadcasts (ghost.rules);
  -- only local presentation and geometry live here.
  GHOST_FADE_OUT_SEC     = 1.0,   -- fade back to solid over the last second
  GHOST_OVERLAP_MARGIN   = 0.25,  -- meters added to every bound before testing
  GHOST_OVERLAP_WARN_SEC = 10.0,  -- blocked this long: warn the driver, tell the server
  -- Separation when a car cannot be measured: larger than any vehicle pair, but
  -- finite, so an unmeasurable car far away cannot block a ghost forever.
  GHOST_FALLBACK_RADIUS = 9.0,
  -- Longest a ghost will wait for its car to report a bounding box before
  -- starting the timer anyway.
  GHOST_SETTLE_MAX = 1.0,
  -- Seconds; swallows same-crossing re-fires on the S/F gate. Low, so very short
  -- circuits still report.
  LAP_DEBOUNCE = 2.0,
  -- Meters a start position may be from the S/F line and still count as a grid
  -- behind it; past this the first crossing is a part lap (branch.gridIsOff).
  GRID_ON_LINE_RANGE = 250,
  -- Most cars a generated grid may put in one row. Two is a road-race grid and
  -- an oval's; three and four are short-track and dirt formats.
  GRID_MAX_WIDTH = 8,
  -- Meters a legal reset may move a car before it is treated as a RECOVERY
  -- teleport and undone. A repair in place moves it centimeters; BeamNG's
  -- recover/load-home drops it at a spawn point that is never this close.
  RECOVER_SNAP_RANGE = 25,
  -- An in-place reset keeps the car's yaw, so a spun car came back spun. Past
  -- this many degrees off the course it is turned to face it; inside it the
  -- driver's own heading is kept, since it follows a bend better than a line.
  RESET_FACE_TOLERANCE = 45,
  -- Meters from the next gate inside which the gate's own heading is the course
  -- direction. Closer than this the line to its center swings wildly.
  RESET_FACE_NEAR = 8,
  -- Meters off a mapped road's edge that still counts as being on it.
  RESET_ROAD_MARGIN = 3,
  -- Meters along the road route to the next gate that a reset car is aimed at.
  RESET_PATH_AHEAD = 15,
  PROGRESS_EVERY = 0.3,   -- seconds between live-position reports
  -- Meters before the S/F line the white flag shows: waved on the approach. Not
  -- off the progress report, which is 12 m between samples at 90 mph.
  WHITE_FLAG_AT = 50,
  -- Live lap clock push rate; the UI interpolates between pushes.
  LAP_TIME_EVERY = 0.25,
  -- Grid hold. Tighter than the server's 0.5 m, so the client normally corrects
  -- a car before the server sees it move.
  HOLD_DRIFT       = 0.75,  -- meters off the settled slot before putting it back
  HOLD_CREEP_SPEED = 0.60,  -- m/s on the slot: a lost freeze, re-pin where it is
  -- A placed car falls onto its suspension; enforcement waits for it to settle
  -- or it fights the settling.
  HOLD_SETTLE_GRACE = 3.0,  -- seconds allowed for a placed car to come to rest
  HOLD_SETTLED_SPEED = 0.20, -- m/s under which a car counts as settled
  -- ...but not before this: a car reports no velocity on the frame it is
  -- placed, so early stillness would anchor it at the drop height.
  HOLD_SETTLE_MIN  = 1.0,   -- seconds before stillness counts as settled
  HOLD_REPORT_EVERY = 0.25, -- seconds between position reports while held
  HOLD_CORRECT_COOLDOWN = 0.5, -- seconds after a correction before another
  -- Pit stall dwell: long enough to cost something. The repair lands part-way.
  PIT_HOLD_SEC   = 5.0,
  -- Seconds the freeze and ghost are re-asserted after a stop: recoverInPlace
  -- reloads the vehicle VM and both vehicle-side calls go with it.
  PIT_SETTLE_SEC = 1.5,
  -- Meters per direction-marker chevron.
  MARKER_CELL     = 3.0,
  -- Ceiling on marks per board, so an enormous one does not turn into a solid
  -- block of geometry drawn every frame.
  MARKER_MAX_MARKS = 60,
  -- Mark thickness as a fraction of the mark's own size, and how much fatter
  -- the dark outline behind it is drawn.
  MARKER_STROKE   = 0.17,
  MARKER_EDGE     = 1.9,
  -- Shapes (U turn, fork, P) draw larger than a cell, so a thinner ratio keeps
  -- the stroke comparable in meters. See place() in render.lua.
  MARKER_SHAPE_STROKE = 0.07,
  PIT_COOLDOWN   = 8.0,   -- before the same stall can trigger again
  -- A stall's footprint in meters, across and along: room to park, tested at
  -- the car's center.
  PIT_BOX_WIDTH  = 3.5,
  PIT_BOX_LENGTH = 6.0,
  PIT_BOX_MIN_W  = 2,  PIT_BOX_MAX_W = 20,
  PIT_BOX_MIN_L  = 3,  PIT_BOX_MAX_L = 30,
  -- m/s below which the car counts as stopped in the stall. Clipping a stall at
  -- speed must not freeze the car; the driver has to stop in it.
  PIT_STOP_SPEED = 0.7,
  PIT_PROMPT_EVERY = 1.5, -- seconds between "stop in the box" reminders
  -- Drawn height of a stall's walls. Not a rule: pit.inside ignores height.
  PIT_WALL_H     = 1.5,
  START_SLOT_LEN  = 4.6,  -- meters; roughly one car long
  START_SLOT_WIDE = 2.2,
  -- Pole colors set outright: the stock value is black and cannot be lifted.
  -- `next` is the gate after the one aimed at, so the line through a corner
  -- reads early; a shade under the aimed gate so the two are not confused.
  POLE_MODE_RGB = {
    next = { 0.95, 0.45, 0.12 },
  },
  ROUTE_FILE = 'settings/raceManager/route.json',
}

-- Build stamp, pushed to the UI. Must match the server plugin and app.js -- see
-- the note in main.lua for why a mismatch is otherwise invisible.
local RM_BUILD = '0.19.0'

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
-- THE SESSION, AS ONE OBJECT: one local, and modules hold it without a getter
-- per rebound name. Mirrored from the server; the client owns only what it
-- measures (localLap, armedWp, timingActive).
local session = {
  -- Mirrored from the server broadcast.
  phase      = 'waiting',   -- waiting | grid | countdown | racing | qualifying | finished
  totalLaps  = 5,
  raceFlag   = 'green',     -- green | yellow | red
  maxResets  = -1,          -- -1 unlimited, 0 none, N per driver per session
  resetMode  = 'inplace',   -- inplace | checkpoint
  jokerEnabled = false,
  -- THE PACE LAP, in two halves (see the server's race.paceLap):
  --   paceLap  the RULE: the race starts behind the pace car, so the final lap
  --            is one crossing further out (effectiveLapTarget).
  --   pacing   the CONDITION: the formation lap is running now.
  paceLap      = false,
  pacing       = false,
  -- THE CAUTION, distinct from a yellow raceFlag: a yellow is a local hazard,
  -- a caution freezes the running order.
  caution      = false,
  cautionLaps  = 0,
  -- Called and not yet official: the field is racing back to the line.
  cautionPending = false,
  -- THE BLUE FLAG, decided by the server, read off our own driver row:
  --   beingLapped   a car a lap or more up is close behind.
  --   lappingAhead  the car close ahead is a lap or more down.
  beingLapped  = false,
  lappingAhead = false,
  -- A restart is called and the green falls as the leader reaches the line.
  restartPending = false,
  -- The heat program: a heat can run its own distance (effectiveLapTarget).
  heatCount    = 0,
  heatCurrent  = 0,
  heatLaps     = 0,
  -- Which heat we were drawn into (nil: none). Compared with heatCurrent to
  -- explain why our car is intangible during somebody else's heat.
  myHeat       = nil,
  -- This driver's own lap, measured here because only the client sees the car
  -- cross anything. The server scores what this reports.
  localLap     = 1,
  armedWp      = 1,         -- next gate the local car must cross
  timingActive = false,     -- quali: false until the first S/F crossing (out lap)
  lapStart     = 0,         -- localTime at the start of the current lap
  prevPos      = nil,       -- vehicle position last frame (the crossing segment)
  resetsUsed   = 0,         -- what THIS client has spent
  -- Joker lap progress, per driver and per session.
  jokerArmed   = 1,         -- next joker gate the local car must cross
  jokerTaken   = false,     -- joker route already completed this race
  jokerLapUsed = nil,       -- lap the joker was taken on, for the UI
  -- Where the server put this car for the start, and whether the hold is on.
  gridSlot   = nil,
  gridFrozen = false,
  -- TIMED RACE, mirrored from the server:
  --   raceExpired  the clock is out; the final lap begins when the leader next
  --                takes the line.
  --   lastLapNum   the leader has been past; completing this lap ends your race.
  raceExpired  = false,
  lastLapNum   = nil,
  -- 'laps' | 'timed' | 'endurance'. Needed here: the flags are decided on this
  -- client, and a timed race has no lap target to count towards.
  raceMode     = 'laps',
  -- Out of the session: finished, retired, or eliminated. 'race' | 'derby'.
  spectatorLock = nil,
  -- Is this client an authenticated admin? Cached to survive the pause menu,
  -- corrected whenever the server refuses a command (BeamMP reuses session ids).
  isAdmin = false,
  -- 'admin' | 'moderator'. isAdmin gates every control; this narrows three.
  -- nil MEANS FULL ADMIN: offline and pre-tier servers send no role.
  role = nil,
}

-- THE TRACK, AS ONE OBJECT. Its fields are rebound when a layout loads
-- (route = cps); `track` never is, so anything handed it sees every change.
local track = {
  -- The RM_ApplyLayout payload last applied, so an identical re-send is a no-op.
  appliedRaw = nil,
  -- Checkpoints: ordered { x, y, z, hx, hy }, where (hx, hy) is the normalized
  -- direction of travel captured at placement. The LAST one is the start/finish
  -- line. A gate may carry its own width/height/depth; absent, it inherits the
  -- defaults below.
  route = {},
  -- Optional rallycross joker route: a second, independent gate sequence.
  jokerRoute = {},
  -- Pit stalls. Never part of the checkpoint sequence.
  pitRoute = {},
  -- The pit lane's mouth and its exit. Arrays, because a lane can have more
  -- than one way in. Declared HERE and not only where a layout is applied: the
  -- renderer reads them every frame, including before any layout exists, and a
  -- nil here is a crash in the draw path rather than an empty lane.
  pitEntry = {},
  pitExit  = {},
  -- Starting grid, slot 1 is pole. Travels with the layout.
  startPositions = {},
  -- Circuit or sprint. A point-to-point stage is driven once and its last gate
  -- is a FINISH. Travels with the layout.
  pointToPoint = false,
  -- A point-to-point layout filed as a drag strip. Saved with the layout; only
  -- true while pointToPoint is.
  dragStrip = false,
  -- Size given to newly placed gates, and the layout's stored default for any
  -- gate without an override of its own.
  checkpointWidth  = TUNE.DEFAULT_WIDTH,
  checkpointHeight = TUNE.DEFAULT_HEIGHT,
  checkpointDepth  = TUNE.DEFAULT_DEPTH,
}

-- WHO OWNS THE ROUTE BUFFER. The route tables are both the track this client
-- races against and the editor's working copy, so an incoming layout must not
-- overwrite what an admin has half-built (the app re-requests state on every
-- mount, and the server answers with the globally loaded layout).
local edit = {
  -- Is the panel open. Mirrored because the authoring furniture is drawn from
  -- Lua; a closed app means a closed editor.
  open   = false,
  -- Which list the editor appends to: main | joker | pit | branch | marker | start.
  target = 'main',
  -- Draw the gates at all (Hide/Show): this client's view, not the race.
  visualize = true,
  -- Fingerprint of the buffer as the server last handed it over. nil until a
  -- layout is applied, which keeps late joiners and drivers on the plain path.
  stamp   = nil,
  -- Name of a layout whose apply was refused, so the panel can name it.
  refused = nil,
}

-- DIRECTION MARKERS: signage, and nothing else. Placed like a checkpoint, but
-- never armed, crossed, timed or counted; the crossing code does not know they
-- exist.
local marker = {
  -- Placed markers: { x, y, z, hx, hy, width, height, depth, kind }.
  list = {},
  -- The symbol the next placed marker gets. Changeable after placement too.
  kind = 'right',
}

-- Every symbol, in one place. The order is the order the panel offers them.
marker.KINDS = { 'right', 'left', 'up', 'down', 'uturn', 'splitRight', 'splitLeft', 'pit' }
marker.LABEL = {
  right = 'Right', left = 'Left', up = 'Straight on', down = 'Slow / stop',
  uturn = 'U turn', splitRight = 'Split, keep right', splitLeft = 'Split, keep left',
  pit = 'Pit lane',
}

-- SYMBOL GEOMETRY: { x1, y1, x2, y2 } segments in a -1..1 cell, +x to the
-- marker's right as a driver faces it, +y up. Segments, not text, because
-- debugDrawer text does not scale with distance.
marker.GLYPH = {
  -- CHEVRONS, not arrows: tiled, they read as one long arrow (">>>>>>").
  right = { {-0.55,0.8, 0.45,0}, {0.45,0, -0.55,-0.8} },
  left  = { {0.55,0.8, -0.45,0}, {-0.45,0, 0.55,-0.8} },
  up    = { {-0.8,-0.55, 0,0.45}, {0,0.45, 0.8,-0.55} },
  down  = { {-0.8,0.55, 0,-0.45}, {0,-0.45, 0.8,0.55} },
  -- These are SHAPES, not tiled marks, so they carry a stem. Strokes are filled
  -- quads drawn fattened (outline) then as a face, ends extended by half the
  -- thickness, so short or shallow-angled segments overlap into a blob. Keep
  -- every segment longer than the stroke is wide and joins at right angles.
  -- U turn: up the left, across, down the right, arrowhead pointing down.
  uturn = { {-0.45,-0.85, -0.45,0.55},
            {-0.45,0.55, 0.45,0.55},
            {0.45,0.55, 0.45,-0.25},
            {0.45,-0.25, 0.10,0.10},
            {0.45,-0.25, 0.80,0.10} },
  splitRight = { {0,-0.8, 0,-0.1}, {0,-0.1, -0.45,0.5}, {0,-0.1, 0.5,0.5},
                 {0.5,0.5, 0.1,0.42}, {0.5,0.5, 0.44,0.08} },
  splitLeft  = { {0,-0.8, 0,-0.1}, {0,-0.1, 0.45,0.5}, {0,-0.1, -0.5,0.5},
                 {-0.5,0.5, -0.1,0.42}, {-0.5,0.5, -0.44,0.08} },
  -- A stencil P: stem, top bar, right side, waist bar, all axis-aligned (see
  -- the stroke note above).
  pit = { {-0.40,-0.80, -0.40,0.80},
          {-0.40,0.80, 0.30,0.80},
          {0.30,0.80, 0.30,0.15},
          {0.30,0.15, -0.40,0.15} },
}

-- Which symbols TILE as a repeating mark and which are one shape.
-- A chevron field wants to be dense; a U turn wants to be legible.
marker.TILES = { right = true, left = true, up = true, down = true }

function marker.validKind(k)
  k = tostring(k or '')
  for i = 1, #marker.KINDS do
    if marker.KINDS[i] == k then return k end
  end
  return nil
end

-- PROPS: static scenery saved with the layout (see props.lua). Required up here,
-- not with the other modules: the purge, the save and the fingerprint below
-- all read props.list. Initialised further down, once groundAt exists.
local props = require('raceManager/props')

-- BRANCHING ROUTES. Slot i is cleared by the main gate route[i] OR any branch
-- gate authored against slot i. Nothing remembers which: armedWp stays an index
-- bounded by #route, so laps, counts and the running order are unchanged. The
-- same rule covers a split lane and a head-on oval.
local branch = {
  -- As authored, flat: { { slot, x, y, z, hx, hy, ... }, ... }
  list   = {},
  -- slot -> gates, resolved when a layout is applied. nil for a slot with no
  -- branch, so the per-frame path is one index and no allocation.
  bySlot = {},
  -- Does this track grid away from the S/F line? Decides whether the first
  -- crossing is an out lap, and until then the line is the only armed gate.
  gridOffLine = false,
  -- Editor: the checkpoint the next placed branch gate belongs to.
  editSlot = 1,
}
local selfSpectating   = false     -- this player has opted out of the field

-- What the session WANTS held ('race' | 'derby' | nil), apart from whether the
-- freeze is applied, so it can be put back when a placement reset drops it.
local holdWanted     = nil
local setLocalVehicleFrozen      -- forward declaration, assigned further down

-- GRID HOLD, VERIFIED. The freeze is lost whenever the vehicle VM reloads (a
-- late placement echo, a driver reset, a respawn), so while a hold is wanted the
-- car's drift from its slot is watched and corrected. Driven by movement, never
-- a timer: re-freezing resets the drivetrain, so a car that is behaving is left
-- alone to rev and pick a gear against the hold.
local hold = {
  -- Where the car came to rest after placement; drift is measured from here,
  -- not from the slot, which is above the ground by the suspension drop.
  anchor      = nil,
  -- The slot itself, for putting a car back before it has settled.
  slot        = nil,
  rot         = nil,   -- the rotation it was placed with
  settleLeft  = 0,     -- seconds of grace left for a just-placed car to rest
  reportLeft  = 0,     -- seconds until the next position report to the server
  correctLeft = 0,     -- cooldown after a correction, so one slip is not a storm
  corrections = 0,     -- how many times this car has been pulled back
}
-- Forward declaration: the placement scheduler ghosts the field on the way in.
local setGhostReason             -- forward declaration, assigned further down

-- Everything ghosting knows, in ONE table: one local for state and functions,
-- and declared above onVehicleResetted, which arms a reset ghost, while the
-- functions are filled in further down.
local ghost = {
  -- veh[gameVehId] = { reason = true, ... }; ghosted while non-empty. Per car,
  -- so two drivers resetting a second apart never end each other's ghost.
  veh     = {},
  -- Our own car's id while we are a finished driver, so alphaFor keeps it
  -- unfaded and the reason comes off that car even after a reset into another.
  finishedOwn = nil,
  -- Other finished cars: [tostring(pid)] = gameVehId (true until it appears).
  -- A pid missing from the server list ends its ghost (disconnect mid-ghost).
  finishedRemote = {},
  -- Practice ghosts (ghost.practiceSync): our own car while we practise
  -- ghosted, the server's list of everyone else who is, and
  -- [tostring(pid)] = gameVehId (false until their car appears).
  practiceOwn = nil,
  practiceList = {},
  practiceRemote = {},
  applied = {},   -- [gameVehId] = true while the ghost is actually applied
  -- Cars whose reasons have gone but which still overlap another car: retried
  -- until the space is clear.
  pending = {},
  -- Seconds left per vehicle, for the fade. Only reset ghosts have a clock.
  left    = {},
  -- Last alpha pushed per car, so the fade skips unchanged engine calls.
  alpha   = {},
  -- Field-wide reasons in force ('quali', 'placement'), re-asserted by the sweep.
  field   = {},
  -- Our own reset ghost. A repeat reset restarts it rather than stacking.
  own = {
    pid      = nil,    -- our BeamMP id, as the server knows us
    vehId    = nil,    -- the car the ghost is on
    settling = false,  -- placed, but not yet reporting a usable bounding box
    settleLeft = 0,    -- ...and a cap on how long that wait may last
    left     = 0,      -- seconds of base timer remaining
    total    = 0,      -- base duration this ghost was granted (for the fade)
    blocked  = 0,      -- seconds spent waiting for an occupied space to clear
    warned   = false,  -- the "move clear" warning has been sent once
  },
  -- Other clients' ghosts: remote[pid] = the SERVER-CLOCK time it ends. An end
  -- time, not a countdown, so latency shortens a ghost rather than lengthening
  -- it, and every receiver lands on the same instant.
  remote = {},
  -- Estimated server clock (race.time), set per broadcast and advanced locally.
  serverTime = 0,
  -- League rules, mirrored from the server; defaults until it is heard from.
  rules = { onReset = true, minSec = 5.0, maxSec = 15.0 },
  -- Why our ghost is held past its timer, for the log.
  blockReason = nil,
  refresh  = 0,       -- seconds until the next re-assert sweep
  -- [pid] = that player's local vehicle id, cached: the lookup allocates and the
  -- fade runs every frame.
  remoteVeh = {},
  hudLeft  = 0,       -- seconds until the next HUD push is due
  hudShown = false,   -- a HUD push has been sent that the UI is still showing
  -- [vehId] = seconds left of a derby respawn ghost, counted locally: race.time
  -- is frozen during a derby, so an end time from it would never arrive.
  respawn  = {},
}

-- ---------------------------------------------------------------------------
-- Display names on the BeamMP nametag
-- ---------------------------------------------------------------------------
-- Adds the admin-set alias as a SUFFIX on BeamMP's own nametag, through
-- MPVehicleGE.setPlayerNickSuffix(guestName, tagSource, text). Never take over
-- the render (hideNicknames): BeamMP owns the fade, occlusion and player
-- settings. The tagSource key keeps other mods' suffixes separate.
-- Never write getPlayers()[pid].name: it is BeamMP's lookup key, and
-- onPlayerLeft matches on it, so a renamed player is never cleaned up.
local nametag = {
  -- Namespaced so BeamMP files our suffix separately from every other mod's.
  SOURCE  = 'raceManager',
  -- [guest name] = the suffix we last set, keyed by name as the API is.
  applied = {},
  on      = false,     -- mirrored from the server broadcast
  sig     = nil,       -- last applied alias set, to skip unchanged broadcasts
}

-- CLEARING PASSES '' NEVER nil: BeamMP's setter shifts its arguments on a nil
-- text and writes 'raceManager' under the 'default' source, where we cannot
-- find it again.
function nametag.set(guestName, text)
  if type(guestName) ~= 'string' or guestName == '' then return end
  if not (MPVehicleGE and type(MPVehicleGE.setPlayerNickSuffix) == 'function') then
    return
  end
  pcall(MPVehicleGE.setPlayerNickSuffix, guestName, nametag.SOURCE, text or '')
end

-- Take every suffix back off: rule off, session end, extension unload.
function nametag.clearAll()
  for guestName in pairs(nametag.applied) do nametag.set(guestName, '') end
  nametag.applied = {}
  nametag.sig = nil
end

-- Apply the aliases from the latest broadcast: `name` is the guest name the
-- setter matches on, `alias` what an admin typed. Skipped when unchanged: the
-- setter searches BeamMP's player list per call, three broadcasts a second.
function nametag.apply(drivers)
  if not nametag.on then
    if next(nametag.applied) ~= nil then nametag.clearAll() end
    return
  end
  if type(drivers) ~= 'table' then return end

  local parts = {}
  for i = 1, #drivers do
    local row = drivers[i]
    if type(row) == 'table' and type(row.name) == 'string' and row.alias then
      parts[#parts + 1] = row.name .. '=' .. tostring(row.alias)
    end
  end
  table.sort(parts)
  local sig = table.concat(parts, '\1')
  if sig == nametag.sig then return end
  nametag.sig = sig

  local wanted = {}
  for i = 1, #drivers do
    local row = drivers[i]
    if type(row) == 'table' and type(row.name) == 'string' and row.alias then
      wanted[row.name] = ' (' .. tostring(row.alias) .. ')'
    end
  end
  -- Off first, so a removed or renamed alias loses its old suffix.
  for guestName in pairs(nametag.applied) do
    if not wanted[guestName] then
      nametag.set(guestName, '')
      nametag.applied[guestName] = nil
    end
  end
  for guestName, text in pairs(wanted) do
    if nametag.applied[guestName] ~= text then
      nametag.set(guestName, text)
      nametag.applied[guestName] = text
    end
  end
end

-- Pit stalls: an AREA a driver may choose to use, kept out of `route` so it is
-- never mandatory and never inside lap or split validation. Driving into one
-- stops the car, repairs it in place and releases it.
local pit = {
  active   = false,  -- a stop is running
  left     = 0,      -- seconds until release
  -- Seconds left of re-asserting the freeze and ghost after servicing: the
  -- repair reloads the vehicle VM asynchronously and takes both with it.
  settleLeft = 0,
  cooldown = 0,      -- a short delay before the same stall is live again
  -- The car has to LEAVE a stall before it can serve another stop. A cooldown
  -- alone re-caught a car still parked in it (a reset in place leaves it there),
  -- freezing and ghosting it for the rest of the race.
  mustLeave = false,
  -- In the pit lane: the stalls are drawn only then. Set by an entry gate,
  -- cleared by an exit gate or by clearing any route checkpoint.
  inLane = false,
  -- Previous sampled position; see pit.update for why not session.prevPos.
  prevPos = nil,
  stops    = 0,      -- how many this session, for the log
  -- Throttles the "stop in the box" prompt while a car creeps through.
  promptLeft = 0,
  -- The car this stop ghosted, so it can be un-ghosted after a VM reload.
  ghostVeh = nil,
  -- Whether this stop announced the ghost (false if a reset ghost owns it).
  ghostSent = false,
}

-- Local lap tracking (reset on every session change)
local localTime    = 0

-- FREE PRACTICE: timed on this client, never reported (no RM_Lap, progress,
-- leaderboard or cup). The server hears only practice ending and the ghost
-- choice. NOT a session: sessionRunning() stays false, so grid, hold, resets,
-- flags and spectating ignore it. It ENDS when a session starts (practice.stop).
--   on        practising right now
--   layout    the track pulled up, for the readout
--   lapTarget how many laps the driver asked for, 0 = unlimited
--   lapsDone  laps completed since practice started
--   ghost     the driver's choice: a ghost to everybody while practising
--   complete  the lap target was reached; the panel keeps the laps up
local practice = { on = false, layout = nil, lapTarget = 0, lapsDone = 0,
                   ghost = true, complete = false }

-- SELF-TIMING: this driver's lap and sector deltas, entirely local: a delta to
-- your own previous lap needs no server and no other car.
--   sectorStart  localTime the current sector began
--   prevLap      the last TIMED lap, which the lap delta is measured against
--   bestSector   [n] = fastest time seen for sector n this session
--   sectors      [n] = this lap's sector times, for the readout
local timing = { sectorStart = 0, prevLap = nil, bestSector = {}, sectors = {} }

-- Wiped on every session change.
local function timingReset()
  timing.sectorStart = localTime
  timing.prevLap     = nil
  timing.bestSector  = {}
  timing.sectors     = {}
end

-- Seconds until the next live-position report.
local progressLeft = 0

-- Countdown to the state request after joining a server. nil = none pending.
local joinRequestLeft = nil

-- Reset rules (Module 1). Past the allowance a reset is BLOCKED: the car goes
-- straight back to `snapshot`, the rolling last good position.
local snapshot = {
  pos   = nil,    -- vec3-ish { x, y, z } sampled while driving
  rot   = nil,    -- quaternion { x, y, z, w } for the same sample
  left  = 0,      -- seconds until the next sample is due
  EVERY = 0.25,   -- seconds between "last good position" samples
  -- Where the car crossed `wp` (lastGate): a height known to be on the track.
  crossed = { wp = nil, x = 0, y = 0, z = 0 },
}

-- What a LEGAL reset does while racing (mirrored from the server):
--   'inplace'    -- BeamNG's normal repair-where-you-stand (the default)
--   'checkpoint' -- the car is moved to the last checkpoint it crossed
local lastGate       = nil       -- last checkpoint the local car crossed (a wp table)
-- Was that crossing BACKWARDS? A gate driven both ways stores one heading, so
-- the direction is recorded per crossing for relocateToGate.
local lastGateBack   = false

-- Reset and teleport blocking: the two action groups, their filter state, the
-- echo window for our own teleports, and the blocked-attempt throttle.
local block = {}

-- Past the allowance the reset INPUTS are filtered off. The onVehicleResetted
-- restore still covers what the filter cannot see, such as v0.39's Pause menu
-- "repair and reset".
block.RESET_ACTIONS = {
  'reset_physics', 'reset_all_physics', 'recover_vehicle', 'recover_vehicle_alt',
  'recover_to_last_road', 'reload_vehicle', 'reload_all_vehicles',
  'loadHome', 'dropPlayerAtCamera',
}
block.resetInputs = false

-- THE TELEPORTS, blocked for the whole session: Home and drop-at-camera MOVE the
-- car and never report as a reset, so the reset hook cannot undo them. Per-frame
-- jump detection was withdrawn: without a reliable speed it dragged fast
-- leaders backwards. Binding Home to Recover Vehicle makes it a normal reset.
block.TELEPORT_ACTIONS = { 'loadHome', 'dropPlayerAtCamera' }
block.teleportInputs = false

-- BeamNG reports a teleport as a vehicle reset, including ours. Each of our
-- teleports is recorded (where and when); a reset from that spot inside the
-- window is our echo. Without this a blocked reset looped forever.
block.selfTeleport = { left = 0, x = 0, y = 0, z = 0 }
block.TELEPORT_WINDOW = 0.6      -- seconds an echo of our own teleport can arrive in
block.TELEPORT_RADIUS = 2.0      -- meters from where we put the car
-- A held key fires reset repeatedly: feedback is throttled, the block is not.
block.noticeLeft = 0
block.NOTICE_EVERY = 1.0   -- seconds between blocked-reset reports


-- Qualifying, mirrored from the server. finalLap: the clock ran out and this
-- lap is the driver's last.
local finalLap       = false
-- Holder of the session's fastest lap, so they are congratulated once.
local lastBestLapPid  = nil
-- ...and the time they set, so beating your OWN fastest lap is announced too.
local lastBestLapTime = nil
local ghostQuali     = false
local qualiLapLimit  = 0         -- 0 = unlimited
local qualiTimeLimit = 0         -- seconds, 0 = unlimited
-- Does this session open with an untimed out lap? Server's call, mirrored for
-- the driver's readout.
local qualiOutLap    = false
-- Joined mid-session: flagged by the server and ghosted so they cannot affect
-- a race they are not in. Cleared when the next grid forms.
local isBystander    = false

-- Forced spectator source ('race' | 'derby'), so neither can release the
-- other's spectators.
local spectatorReason = nil

local function inMultiplayer()
  return MPGameNetwork ~= nil and TriggerServerEvent ~= nil
end

-- The attached vehicle, via getPlayerVehicle(0) where it exists: be:* accessors
-- cross into C++ every call. Decided once.
local vehicleAccessor = nil    -- nil = undecided, 'ge' | 'engine'
local function playerVehicle()
  if vehicleAccessor == nil then
    if type(getPlayerVehicle) == 'function' and pcall(getPlayerVehicle, 0) then
      vehicleAccessor = 'ge'
    else
      vehicleAccessor = 'engine'
    end
  end
  if vehicleAccessor == 'ge' then return getPlayerVehicle(0) end
  if be then return be:getPlayerVehicle(0) end
  return nil
end

-- ---------------------------------------------------------------------------
-- "Our" vehicle, in a world full of other people's
-- ---------------------------------------------------------------------------
-- playerVehicle() is the ATTACHED vehicle, which is not "ours": when our car is
-- deleted BeamNG attaches the camera to the nearest car, a rival's. Anything
-- that removes, respawns, places or points a camera at our car goes through
-- ownVehicle(). nil here means no ownership API (singleplayer): all ours.
local function ownershipFn()
  if MPVehicleGE and type(MPVehicleGE.isOwn) == 'function' then return MPVehicleGE.isOwn end
  return nil
end

local function isOwnVehicle(vehId)
  if vehId == nil then return false end
  local isOwn = ownershipFn()
  if not isOwn then return true end   -- singleplayer: it is all ours
  local ok, own = pcall(isOwn, vehId)
  return ok and own == true
end

-- THE CLOSURE IS NOT WASTE: pcall(veh.getID, veh) indexes the userdata OUTSIDE
-- the protection, so a deleted vehicle whose __index raises throws instead of
-- returning nil. Verified.
local function vehicleId(veh)
  if not veh then return nil end
  local ok, id = pcall(function () return veh:getID() end)
  if ok then return id end
  return nil
end

-- IS THIS THING TOWED RATHER THAN RACED? info.json Type Trailer or Prop. A
-- driver can own a car and a trailer and sit in either; a trailer must never
-- be gridded, timed or declared to the Garage List (which deleted it and took
-- every watcher's camera with it). Cached per model. UNKNOWN IS NOT A TRAILER.
local towed = { cache = {} }

function towed.is(veh)
  if not veh then return false end
  local model = nil
  pcall(function () model = tostring(veh:getJBeamFilename()) end)
  if not model or model == '' then return false end
  local known = towed.cache[model]
  if known ~= nil then return known end
  local kind = nil
  pcall(function ()
    if not (core_vehicles and core_vehicles.getModel) then return end
    local info = core_vehicles.getModel(model)
    kind = info and info.model and info.model.Type or nil
  end)
  local is = (kind == 'Trailer' or kind == 'Prop')
  towed.cache[model] = is
  return is
end

-- The car this driver last sat in. A search over owned vehicles answers with
-- whichever is listed first (the trailer, sometimes). Written only from the
-- attached vehicle; re-verified on every use, since vehicle ids are reused.
local ownVehId = nil

-- Our own RACE CAR, or nil. A driver can own a car and a trailer: the attached
-- vehicle when it is ours and not towed, else the last one that was. The blind
-- scan is a last resort (it can return a trailer) and never seeds the cache.
-- sampledVehicle calls this every frame, so the remembered id keeps a driver
-- tabbed onto a rival from building a vehicle list per frame.
local function ownVehicle()
  local veh = playerVehicle()
  if not ownershipFn() then return veh end
  if veh then
    local id = vehicleId(veh)
    -- Ours and not a trailer: tabbing into your own trailer is a camera move.
    if id ~= nil and isOwnVehicle(id) and not towed.is(veh) then
      ownVehId = id
      return veh
    end
  end
  -- Re-verified, not trusted: see the note on ownVehId.
  if ownVehId ~= nil then
    local got, found = pcall(getObjectByID, ownVehId)
    if got and found and isOwnVehicle(ownVehId) then return found end
    ownVehId = nil
  end
  if type(getAllVehicles) == 'function' then
    local ok, list = pcall(getAllVehicles)
    if ok and type(list) == 'table' then
      for _, v in ipairs(list) do
        if v and isOwnVehicle(vehicleId(v)) and not towed.is(v) then return v end
      end
    end
  end
  return nil
end

-- Per-frame sample of OUR car and its position, taken lazily (localTime is the
-- frame stamp), so getPosition crosses into C++ once a frame. Our car, not the
-- camera's: sampling the watched car credited spectators with a rival's laps.
local sample = { at = -1, veh = nil, pos = nil }

local function sampledVehicle()
  if sample.at == localTime then return sample.veh, sample.pos end
  sample.at  = localTime
  sample.veh = ownVehicle()
  sample.pos = sample.veh and sample.veh:getPosition() or nil
  return sample.veh, sample.pos
end

-- This client's BeamMP session id, so a broadcast that carries every driver can
-- be narrowed down to our own row. nil offline.
local function localServerId()
  if MPConfig and MPConfig.getPlayerServerID then
    local ok, id = pcall(MPConfig.getPlayerServerID)
    if ok then return tonumber(id) end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Nudge mode: move and turn placed gates with the mouse, from free cam
-- ---------------------------------------------------------------------------
-- Move and turn placed gates with the mouse from free cam, for fixing a driven
-- gate afterwards. A MODE, because in free cam the mouse is the camera: a stray
-- click while flying around must never move a gate.
local nudge = {
  on       = false,   -- mode active: cursor released, picking live
  sel      = nil,     -- index into the ACTIVE editor list, not always `route`
  -- The list `sel` indexes, remembered for the drawing.
  list     = nil,
  dragging = false,
  -- Where the cursor ray landed at the grab (nil: nothing grabbed). A drag moves
  -- the gate BY the cursor's travel, never TO the ray hit, which passes through
  -- the gate to the ground behind it.
  grabX    = nil,
  grabY    = nil,
  -- Frames in which a click is assumed to come from the PANEL: ImGui cannot see
  -- the CEF overlay, so every M.nudge* call sets this.
  uiGrace  = 0,
  -- Engine bits, resolved once (false when absent: the mode is unavailable).
  im       = nil,
  cv       = nil,
  ready    = nil,
  -- Was the cursor free before this mode took it? true / false / nil = unknown.
  wasFree  = nil,
}

-- Pick radius in meters, measured to a gate's CENTER so overlapping wide gates
-- pick the right one.
nudge.PICK_RADIUS  = 8
nudge.TURN_PER_STEP = math.rad(5)   -- one scroll notch

-- Placement uses our own car, not whichever car the camera is watching.
local function vehiclePlacement()
  local veh = ownVehicle()
  if not veh then return nil end
  local pos = veh:getPosition()
  local dir = veh:getDirectionVector()
  local len = math.sqrt(dir.x * dir.x + dir.y * dir.y)
  local hx, hy = 0, 1
  if len > 1e-4 then hx, hy = dir.x / len, dir.y / len end
  return { x = pos.x, y = pos.y, z = pos.z, hx = hx, hy = hy }
end

local function clampWidth(w)
  w = tonumber(w) or TUNE.DEFAULT_WIDTH
  if w < TUNE.MIN_WIDTH then w = TUNE.MIN_WIDTH elseif w > TUNE.MAX_WIDTH then w = TUNE.MAX_WIDTH end
  return w
end

local function clampHeight(h)
  h = tonumber(h) or TUNE.DEFAULT_HEIGHT
  if h < TUNE.MIN_HEIGHT then h = TUNE.MIN_HEIGHT elseif h > TUNE.MAX_HEIGHT then h = TUNE.MAX_HEIGHT end
  return h
end

local function clampDepth(d)
  d = tonumber(d) or TUNE.DEFAULT_DEPTH
  if d < TUNE.MIN_DEPTH then d = TUNE.MIN_DEPTH elseif d > TUNE.MAX_DEPTH then d = TUNE.MAX_DEPTH end
  return d
end

-- Width across, height ABOVE the placement point, depth BELOW it. A legacy gate
-- with a height and no depth meant the full span, centered: split in half.
local function gateDims(wp)
  local w = clampWidth(wp.width or track.checkpointWidth)
  if wp.depth == nil and wp.height ~= nil then
    local half = wp.height * 0.5
    return w, clampHeight(half), clampDepth(half)
  end
  return w, clampHeight(wp.height or track.checkpointHeight),
         clampDepth(wp.depth or track.checkpointDepth)
end

-- ---------------------------------------------------------------------------
-- UI push helpers
-- ---------------------------------------------------------------------------
-- Last start-position count reported, so it is sent only on a change.
local lastReportedStarts = nil
-- Report the grid's count and positions; the server polices the hold by
-- distance itself.
local function reportStartCount()
  if not inMultiplayer() then return end
  local n = #track.startPositions
  if n == lastReportedStarts then return end
  lastReportedStarts = n
  local positions = {}
  for i, sp in ipairs(track.startPositions) do
    positions[i] = { x = sp.x, y = sp.y, z = sp.z, hx = sp.hx, hy = sp.hy }
  end
  -- Branch gates are not reported: they clear the same checkpoint as the main one.
  TriggerServerEvent('RM_StartPositionCount', jsonEncode({
    count = n, positions = positions,
    gridOffLine = branch.gridIsOff(),
    -- The server refuses a joker rule on a track with no joker route.
    jokerGates  = #track.jokerRoute,
  }))
end

-- Which RACING lap this driver is on: behind the pace car the formation lap is
-- localLap 1. One function, so the joker is enforced and drawn on one rule.
local function racingLap()
  return (session.localLap or 0) - (session.paceLap and 1 or 0)
end

-- Is the joker still shut for this driver? True on the pace lap and on racing
-- lap 1, which is the rule the crossing test enforces.
local function jokerClosed()
  return racingLap() <= 1
end

-- The lap number that ends this driver's race, or nil (a timed race before the
-- leader has been past). Flags are per-driver, so this client decides them.
-- lastLapNum wins whenever it is set.
local function effectiveLapTarget()
  if track.pointToPoint then return 1 end
  if session.lastLapNum then return session.lastLapNum end
  -- A timed race has no lap target at all until the leader has been past.
  -- Endurance keeps one: it is the other half of "whichever comes first".
  if session.raceMode == 'timed' then return nil end
  -- A heat may run its own distance (the server's raceDistance rule).
  local laps = session.totalLaps
  if session.heatCount > 0 and session.heatCurrent > 0 and session.heatLaps > 0 then
    laps = session.heatLaps
  end
  if laps <= 0 then return nil end
  -- The pace lap is an unscored crossing on top of the distance, as the
  -- server's sessionLapTarget adds it.
  return laps + (session.paceLap and 1 or 0)
end

-- This driver's flag right now. Yellow is the server's; white is per-driver,
-- so it is decided here. A sprint stage never shows white.
local function driverFlag()
  -- CHECKERED outranks everything until the session ends: a finished driver's
  -- race does not resume under a caution or a red. Not for a derby.
  if session.spectatorLock and session.spectatorLock ~= 'derby' then return 'checkered' end
  -- RED: held on the grid or called by an admin. A condition, not a phase.
  if session.raceFlag == 'red' or session.phase == 'grid' or session.gridFrozen then return 'red' end
  if session.raceFlag == 'yellow' then return 'yellow' end
  local target = effectiveLapTarget()
  if session.phase == 'racing' and not track.pointToPoint and target
     and session.localLap >= target then
    return 'white'
  end
  -- BLUE: under white (your race ending outranks moving over) and under yellow
  -- (nobody lets anybody by under a caution).
  if session.beingLapped then return 'blue' end
  return 'green'
end

-- Fingerprint of everything an admin can author, so a drifted editor buffer
-- can be told from one exactly as it arrived. Centimeter resolution: raw floats
-- would drift on physics noise and refuse every layout.
function edit.fingerprint()
  local n = 0
  local function fold(list)
    n = (n * 31 + #list) % 2147483647
    for i = 1, #list do
      local w = list[i]
      n = (n * 31
        + math.floor((w.x or 0) * 100)
        + math.floor((w.y or 0) * 100)
        + math.floor((w.z or 0) * 100)) % 2147483647
    end
  end
  fold(track.route)
  fold(track.jokerRoute)
  fold(track.pitRoute)
  fold(track.startPositions)
  fold(branch.list)
  fold(props.list)
  return n
end

-- RUNNING A RACE OR CONFIGURING ONE. 'grid' counts: the field is on its slots.
-- The derby is not consulted: `derby` is required far below and would resolve
-- as a nil global here.
function edit.running()
  return session.phase == 'grid' or session.phase == 'countdown'
      or session.phase == 'racing' or session.phase == 'qualifying'
end

-- The capability the editor is gated on. MODE, not identity: the server checks
-- admin on save, load and delete; checking here would break offline building.
function edit.canConfigure()
  return not edit.running()
end

-- Is the editor holding work an incoming layout would destroy? Open, drifted
-- from the server's copy, and no session running (a race layout wins).
function edit.holdsBuffer()
  if not edit.open then return false end
  if edit.stamp == nil then return false end
  if edit.running() then return false end
  return edit.fingerprint() ~= edit.stamp
end

local function pushRouteState()
  reportStartCount()
  guihooks.trigger('RaceManagerRoute', {
    clientBuild  = RM_BUILD,
    waypoints    = track.route,
    nextWp       = session.armedWp,
    width        = track.checkpointWidth,
    height       = track.checkpointHeight,
    depth        = track.checkpointDepth,
    visualize    = edit.visualize,
    -- Free practice. lapsLeft is computed here: the target may be 0 (unlimited).
    practice       = practice.on,
    practiceLayout = practice.layout,
    practiceLaps   = practice.lapTarget,
    practiceDone   = practice.lapsDone,
    practiceLeft   = (practice.on and practice.lapTarget > 0)
                     and math.max(0, practice.lapTarget - practice.lapsDone) or nil,
    practiceGhost    = practice.ghost,
    practiceComplete = practice.complete,
    -- Starting grid
    startPositions = track.startPositions,
    pointToPoint   = track.pointToPoint,
    dragStrip      = track.dragStrip,
    gridSlot       = session.gridSlot,
    gridFrozen     = session.gridFrozen,
    -- Admin session, so a freshly mounted app knows it is still logged in...
    isAdmin      = session.isAdmin,
    -- ...and at which tier (the app is rebuilt on every pause menu).
    role         = session.role,
    -- Pit lane and joker route
    pitRoute     = track.pitRoute,
    pitEntry     = track.pitEntry,
    pitExit      = track.pitExit,
    pitInLane    = pit.inLane,
    pitActive    = pit.active,
    pitLeft      = pit.left,
    jokerRoute   = track.jokerRoute,
    jokerNext    = session.jokerArmed,
    jokerTaken   = session.jokerTaken,
    jokerLap     = session.jokerLapUsed,
    jokerEnabled = session.jokerEnabled,
    -- Also here so the panel has it offline and the instant it is switched.
    paceLap      = session.paceLap,
    pacing       = session.pacing,
    editorTarget = edit.target,
    -- Which flag is out FOR THIS DRIVER: white depends on their own lap.
    driverFlag   = driverFlag(),
    nudgeOn      = nudge.on,
    nudgeSel     = nudge.sel,
    -- Direction markers: signage, armed by nothing.
    markers      = marker.list,
    markerKind   = marker.kind,
    markerKinds  = marker.KINDS,
    markerLabels = marker.LABEL,
    -- Props: static scenery.
    props        = props.list,
    propKind     = props.kind,
    propKinds    = props.IDS,
    propLabels   = props.LABEL,
    -- Branch gates (the other ways through a checkpoint)
    branches     = branch.list,
    branchSlot   = branch.editSlot,
    gridOffLine  = branch.gridIsOff(),
    -- A generated grid the spacing sliders may move; hand-placed is left alone.
    gridGenerated = branch.gridTool.generated,
    gridSpacing   = branch.gridTool.spacing,
    gridStagger   = branch.gridTool.stagger,
    gridWidth     = branch.gridTool.width,
    -- Reset ruleset (Module 1)
    maxResets    = session.maxResets,
    resetsUsed   = session.resetsUsed,
    resetMode    = session.resetMode,
    -- Car taken away (finished or penalised), kept apart from "sitting this one
    -- out" so one route push cannot overwrite the other.
    carTaken     = session.spectatorLock ~= nil,
  })
end

-- BeamNG's own Messages HUD, on screen for everybody: a driver with the app
-- minimised and chat closed must still see "RED FLAG". The category is PER KIND,
-- so a repeat replaces its own message and a pit call never wipes a red flag.
-- Icons per kind; anything unlisted shows the flag.
local HUD_ICON = {
  vehicle = 'directions_car', spectate = 'visibility', resetsout = 'block',
  pit = 'build', finish = 'emoji_events', grid = 'grid_on',
  session = 'timer', joker = 'alt_route', derby = 'warning', stage = 'traffic',
}

-- Ten seconds: read at racing speed, out of the corner of an eye.
local HUD_TTL = 10
local function hudMessage(kind, text, ttl)
  kind = tostring(kind or 'info')
  local category = 'raceManager_' .. kind
  local icon = HUD_ICON[kind] or 'flag'
  if type(ui_message) == 'function' then
    if pcall(ui_message, text, ttl or HUD_TTL, category, icon) then return end
  end
  pcall(guihooks.trigger, 'Message', {
    ttl = ttl or HUD_TTL, msg = text, category = category, icon = icon,
  })
end


-- Which notices also go to the HUD: only what a driver must ACT on. Commentary
-- (reset tallies, fastest lap, ghost, server, alias) stays in the app.
local HUD_NOTICE = {
  flag = true, session = true, spectate = true, resetsout = true,
  vehicle = true, joker = true, finish = true, grid = true,
  pit = true, derby = true,
}

local function pushNotice(kind, msg, extra)
  local payload = { kind = kind, msg = msg }
  if type(extra) == 'table' then
    payload.sub    = extra.sub
    payload.color = extra.color
  end
  guihooks.trigger('RaceManagerNotice', payload)
  -- One funnel: the HUD copy is decided here by kind, not at each call site.
  if HUD_NOTICE[kind] then
    hudMessage(kind, payload.sub and (msg .. ': ' .. payload.sub) or msg)
  end
end

-- Latches that turn a standing flag STATE into a one-time flash.
local flags = {
  -- Lap each approach flag was shown for; the approach is sampled every frame.
  whiteLap     = nil,
  checkeredLap = nil,
  -- The approach flash happened, so taking the flag says the placing instead.
  checkeredSeen = false,
  -- Shown this session, by whichever path got there first.
  checkered = false,
}

-- Every current broadcast carries this stamp. An unstamped one comes from an
-- outdated server plugin copy installed alongside (two copies alternating made
-- the UI flicker), so it is dropped and reported once.
local RM_PROTOCOL = 2
local staleServerWarned = false
local function fromCurrentServer(data)
  if type(data) == 'table' and data.rmProtocol == RM_PROTOCOL then return true end
  if not staleServerWarned then
    staleServerWarned = true
    pushNotice('server', 'Ignoring broadcasts from an outdated Race Manager server plugin: '
      .. 'remove old copies from the server\'s Resources/Server folder')
    log('W', 'raceManager', 'Dropped a state broadcast without the current protocol stamp: '
      .. 'an outdated copy of the server plugin appears to be installed alongside this one')
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Gate geometry
-- ---------------------------------------------------------------------------
-- Flat rectangle crossing test. A gate is an upright rectangle at (x, y, z),
-- perpendicular to its heading f = (hx, hy); lateral r = (hy, -hx). The car's
-- frame-to-frame SEGMENT is tested against it, so it never tunnels. Dimensions
-- are passed in for tests/gate_test.lua.
-- EITHER DIRECTION COUNTS unless the gate is `oneWay` (hairpins, figure-8
-- crossovers): a gate is armed once, which is what stops a double score.
-- Returns (crossed, backwards): a shared gate cannot tell the car's direction.
local function rectCrossesGate(wp, prev, cur, w, h, d)
  local fx, fy = wp.hx, wp.hy

  -- Signed distance to the gate plane before and after this frame's movement.
  local dPrev = (prev.x - wp.x) * fx + (prev.y - wp.y) * fy
  local dCur  = (cur.x  - wp.x) * fx + (cur.y  - wp.y) * fy
  local forward  = (dPrev < 0 and dCur >= 0)
  local backward = (not wp.oneWay) and (dPrev > 0 and dCur <= 0)
  if not (forward or backward) then return false end

  local t  = dPrev / (dPrev - dCur)
  local ix = prev.x + (cur.x - prev.x) * t
  local iy = prev.y + (cur.y - prev.y) * t
  local iz = prev.z + (cur.z - prev.z) * t
  local lateral = (ix - wp.x) * fy - (iy - wp.y) * fx
  if math.abs(lateral) > w * 0.5 then return false end
  -- `h` above the placement point, `d` below it.
  local dz = iz - wp.z
  if dz > h or dz < -d then return false end
  return true, backward
end

-- Live wrapper: the gate's own dimensions, then the crossing test.
local function segmentCrossesGate(wp, prev, cur)
  local w, h, d = gateDims(wp)
  return rectCrossesGate(wp, prev, cur, w, h, d)
end

-- ---------------------------------------------------------------------------
-- Lap logic
-- ---------------------------------------------------------------------------
-- A session is running: lights out, laps count. Qualifying and racing detect
-- laps identically; the SERVER declines to score qualifying's out lap.
local function sessionRunning()
  return session.phase == 'racing' or session.phase == 'qualifying'
end

-- ---------------------------------------------------------------------------
-- STICKY HUD STATE
-- ---------------------------------------------------------------------------
-- CONDITIONS (forming up, neutralised, green coming) held on the HUD by
-- re-asserting a message in one category. Expires after two LAPS, the unit the
-- condition is measured in, so it never becomes furniture; the seconds cap
-- covers a driver who completes no laps.
local sticky = {
  key = nil, lap = 0, left = 0, due = 0,
  LAPS    = 2,
  MAX_SEC = 180,
  REFRESH = 2.0,
}

-- What the HUD should hold now, or nil: the one a driver must act on first.
local function stickyMessage()
  if not sessionRunning() or session.spectatorLock then return nil end
  if session.greenReady then
    return 'ready', 'GET READY - green flag coming. Hold position until it falls.'
  end
  if session.pacing then
    return 'pace', 'PACE LAP - hold position, 50 MPH or 80 KMH. GET READY comes before the green.'
  end
  if session.restartPending then
    return 'restart', 'RESTART THIS LAP - hold position. GET READY comes before the green.'
  end
  if session.cautionPending then
    return 'caution', 'CAUTION - race back to the line. Positions lock as you complete this lap.'
  end
  if session.caution then
    return 'caution', 'CAUTION - hold position, no overtaking. Places are frozen.'
  end
  return nil
end

local function stickyUpdate(dt)
  local key, text = stickyMessage()
  if not key then
    sticky.key = nil
    return
  end
  if key ~= sticky.key then
    -- A new condition restarts the allowance: it is a different instruction.
    sticky.key, sticky.lap = key, session.localLap or 0
    sticky.left, sticky.due = sticky.MAX_SEC, 0
  end
  sticky.left = sticky.left - dt
  sticky.due  = sticky.due - dt
  local lapsShown = (session.localLap or 0) - sticky.lap
  if sticky.left <= 0 or lapsShown > sticky.LAPS then return end
  if sticky.due > 0 then return end
  sticky.due = sticky.REFRESH
  -- Outlives the refresh, so it never blinks out on a late frame.
  hudMessage('flag', text, sticky.REFRESH + 2)
end

local function resetLapTracking()
  session.timingActive = false
  session.lapStart     = localTime
  session.localLap     = 1
  timingReset()
  session.prevPos      = nil
  -- The flag latches go with the session.
  flags.whiteLap      = nil
  flags.checkeredLap  = nil
  flags.checkeredSeen = false
  flags.checkered     = false
  -- Joker credit and the reset allowance are per session.
  session.jokerArmed   = 1
  session.jokerTaken   = false
  session.jokerLapUsed = nil
  session.resetsUsed   = 0
  lastGate     = nil
  lastGateBack = false
  block.noticeLeft = 0   -- a fresh session may report its first blocked attempt at once
  -- Report a distance on the next frame.
  progressLeft = 0
  -- Live from GO: the first target is checkpoint 1, qualifying included.
  -- Outside a session the S/F line is armed, for sensible gate colors.
  if sessionRunning() then
    session.armedWp = 1
    session.timingActive = true
  elseif session.phase == 'grid' or session.phase == 'countdown' then
    -- On the grid the gate ahead is checkpoint 1, as it will be at GO.
    -- Presentation only: checkGates does not run outside a session.
    session.armedWp = 1
  else
    session.armedWp = math.max(#track.route, 1)
  end
  pushRouteState()
end

-- Purge every route table and reset lap tracking. Gates are redrawn from the
-- tables every frame, so emptying them removes them from the world.
local function clearTrackState(reason)
  track.appliedRaw   = nil
  track.route        = {}
  track.jokerRoute   = {}
  -- The pit lane too, or it rides into the next track and the next save.
  track.pitRoute     = {}
  track.pitEntry     = {}
  track.pitExit      = {}
  track.startPositions = {}
  session.gridSlot     = nil
  session.armedWp      = 1
  session.jokerArmed   = 1
  session.jokerTaken   = false
  session.jokerLapUsed = nil
  session.timingActive = false
  session.localLap     = 1
  session.lapStart     = localTime
  timingReset()
  session.prevPos      = nil
  progressLeft = 0
  lastGate     = nil
  lastGateBack = false
  -- Markers too: a stale sign is worse than none.
  marker.list   = {}
  -- And props: the frame loop takes them out of the world.
  props.list    = {}
  -- Branch gates too, or they arm gates from a track no longer loaded.
  branch.list   = {}
  branch.bySlot = {}
  branch.gridOffLine = false
  branch.editSlot    = 1
  pushRouteState()
  log('I', 'raceManager', 'Track state cleared (' .. tostring(reason or 'local') .. ')')
end

-- Console entry point: purge locally and ask the server to purge everyone.
function M.clearTrackState()
  clearTrackState('ui request')
  if inMultiplayer() then TriggerServerEvent('RM_ClearTrackState', '') end
end

-- Unload the track and the derby arena. On a server the SERVER makes it stick
-- (and refuses during a session or derby); the local purge is for offline.
function M.clearEverything()
  clearTrackState('clear everything')
  if inMultiplayer() then
    TriggerServerEvent('RM_ClearEverything', '')
  else
    -- pushNotice, not editorMsg: editorMsg is declared far below and would be a
    -- nil global here.
    pushNotice('session', 'Cleared: nothing is loaded')
  end
end

-- Is this driver on the given-away out lap? Worked out locally: the server's
-- row lags up to a third of a second, which would say NOT TIMED after the line.
-- qualiOutLap is the server's rule for races too (grid off the line); the
-- name stayed. A finished driver is never on an out lap.
local function onOutLap()
  return qualiOutLap and sessionRunning() and session.localLap <= 1 and not session.spectatorLock
end

local function onLapCompleted()
  local lapTime = localTime - session.lapStart
  if session.timingActive and lapTime < TUNE.LAP_DEBOUNCE then return end  -- double-fire guard

  -- Hand the time to the driver's HUD to hold on screen. Display only.
  local function announceLap(n)
    -- Delta to the PREVIOUS lap ("am I still improving"); sectors compare to
    -- best. nil on the first timed lap rather than a false 0.000.
    local delta = timing.prevLap and (lapTime - timing.prevLap) or nil
    timing.prevLap = lapTime
    guihooks.trigger('RaceManagerLapDone', { lapTime = lapTime, lap = n, delta = delta })
  end

  -- ONE report for every lap, out lap included: the server decides what it
  -- scores, and needs the crossing either way.
  -- A PRACTICE LAP IS ANNOUNCED AND NEVER REPORTED, and has no out lap.
  if practice.on then
    practice.lapsDone = practice.lapsDone + 1
    announceLap(practice.lapsDone)
    log('I', 'raceManager', string.format('Practice lap %d: %.3fs',
      practice.lapsDone, lapTime))
    session.lapStart = localTime
    timing.sectors = {}
    -- Reaching the target ends the run; the panel keeps the laps up.
    if practice.lapTarget > 0 and practice.lapsDone >= practice.lapTarget then
      practice.stop('complete')
    end
    return
  end
  if not sessionRunning() then return end
  local outLap = onOutLap()
  if inMultiplayer() then
    TriggerServerEvent('RM_Lap', jsonEncode({ lapTime = lapTime }))
  end
  if outLap then
    -- No time for an untimed lap; say that timing has started instead.
    guihooks.trigger('RaceManagerLapDone', { outLap = true, lap = session.localLap })
    -- Qualifying only: in a race the first lap is scored anyway.
    if session.phase == 'qualifying' then
      pushNotice('session', 'OUT LAP COMPLETE: you are on a TIMED lap now')
    end
    log('I', 'raceManager', string.format('Out lap done: %.3fs (not timed)', lapTime))
  else
    announceLap(session.localLap)
    log('I', 'raceManager', string.format('Lap %d done: %.3fs (%s)',
      session.localLap, lapTime, session.phase))
  end
  session.localLap = session.localLap + 1
  session.lapStart = localTime
  -- New sectors. The stamp is not reset: the crossing already moved it.
  timing.sectors = {}
end

-- ---------------------------------------------------------------------------
-- Joker route detection (Module 2)
-- ---------------------------------------------------------------------------
-- Joker gates, armed in their own order so a driver keeps main-route progress.
--   * Racing lap 1 (racingLap(), not the raw counter: behind the pace car the
--     formation lap is localLap 1): any attempt is invalidated.
--   * Once per race: a completed joker is reported once; later runs are not.
local function checkJokerGates(prev, cur)
  if not session.jokerEnabled or #track.jokerRoute == 0 then return end
  if session.phase ~= 'racing' then return end
  local wp = track.jokerRoute[session.jokerArmed]
  if not wp or not segmentCrossesGate(wp, prev, cur) then return end

  -- The racing lap, the same rule the gates are drawn with; also what the
  -- results file prints.
  local lapNow = racingLap()
  if jokerClosed() then
    -- Re-armed from the first joker gate so a later lap can still take it.
    session.jokerArmed = 1
    pushNotice('joker', 'JOKER LAP NOT ALLOWED ON LAP 1: attempt invalidated')
    log('W', 'raceManager', 'Joker route attempted on lap 1: attempt invalidated')
    pushRouteState()
    return
  end

  if session.jokerTaken then
    session.jokerArmed = 1
    pushNotice('joker', 'Joker Lap already taken: this run does not count')
    pushRouteState()
    return
  end

  if session.jokerArmed >= #track.jokerRoute then
    session.jokerTaken   = true
    session.jokerLapUsed = lapNow
    session.jokerArmed   = 1
    if inMultiplayer() then
      TriggerServerEvent('RM_JokerLap', jsonEncode({ lap = lapNow }))
    end
    pushNotice('joker', 'JOKER LAP COMPLETE (lap ' .. lapNow .. ')')
    log('I', 'raceManager', 'Joker route completed on lap ' .. lapNow)
  else
    session.jokerArmed = session.jokerArmed + 1
  end
  pushRouteState()
end

-- ---------------------------------------------------------------------------
-- Branching routes. On a track with no branch gates bySlot[i] is nil, so this
-- costs one index more than testing the main gate alone.
-- Does this track grid away from the S/F line? Inferred, never a switch:
--   * a start position facing AGAINST the line (a head-on layout), or
--   * one further from it than any grid is long (GRID_ON_LINE_RANGE).
function branch.gridIsOff()
  local sf = track.route[#track.route]
  if not sf or #track.startPositions == 0 then return false end
  local r2 = TUNE.GRID_ON_LINE_RANGE * TUNE.GRID_ON_LINE_RANGE
  for _, sp in ipairs(track.startPositions) do
    if (sp.hx or 0) * (sf.hx or 0) + (sp.hy or 1) * (sf.hy or 1) < 0 then return true end
    local dx, dy = sp.x - sf.x, sp.y - sf.y
    if dx * dx + dy * dy > r2 then return true end
  end
  return false
end

function branch.crossedAt(i, p0, p1)
  local wp = track.route[i]
  if wp then
    local crossed, backwards = segmentCrossesGate(wp, p0, p1)
    if crossed then return wp, backwards end
  end
  local alts = branch.bySlot[i]
  if alts then
    for k = 1, #alts do
      local crossed, backwards = segmentCrossesGate(alts[k], p0, p1)
      if crossed then return alts[k], backwards end
    end
  end
  return nil, false
end

-- The gate for slot i nearest this position: the one this car is driving
-- towards on a branched slot (head-on fields rank by it).
function branch.nearestAt(i, pos)
  local best = track.route[i]
  local alts = branch.bySlot[i]
  if not alts then return best end
  local bd = math.huge
  if best then
    local dx, dy, dz = pos.x - best.x, pos.y - best.y, pos.z - best.z
    bd = dx * dx + dy * dy + dz * dz
  end
  for k = 1, #alts do
    local g = alts[k]
    local dx, dy, dz = pos.x - g.x, pos.y - g.y, pos.z - g.z
    local d = dx * dx + dy * dy + dz * dz
    if d < bd then best, bd = g, d end
  end
  return best
end

-- Run `fn` over slot i's gates. A callback, not a list: the drawing pass calls
-- it every frame.
function branch.eachAt(i, fn, arg)
  local wp = track.route[i]
  if wp then fn(wp, arg) end
  local alts = branch.bySlot[i]
  if alts then
    for k = 1, #alts do fn(alts[k], arg) end
  end
end

local function checkGates()
  if session.spectatorLock then return end     -- out of the session: no more timing
  if #track.route == 0 and #track.jokerRoute == 0 then return end
  -- ...or while practising, which is what makes practice timed.
  if not practice.on
     and session.phase ~= 'qualifying' and session.phase ~= 'racing' then return end
  local veh, pos = sampledVehicle()
  if not veh or not pos then return end
  if session.prevPos then
    -- The checkpoint this car must clear next, by whichever of its gates.
    -- THE OUT LAP IS AN ORDINARY LAP THAT IS NOT SCORED: same gates, same order,
    -- and it ends on armedWp like any lap. NO S/F SHORTCUT: two versions let
    -- the line end it early, which ended out laps seconds after the green and
    -- dropped pace laps as the leader rolled over the line. A car gridded past
    -- slot 1 just runs a longer out lap.
    local wp, backwards = branch.crossedAt(session.armedWp, session.prevPos, pos)
    local crossed = wp ~= nil

    if crossed then
      lastGate     = wp   -- the "Last Checkpoint" reset mode respawns here
      lastGateBack = backwards
      do
        local c = snapshot.crossed
        c.wp, c.x, c.y, c.z = wp, pos.x, pos.y, pos.z
      end
      -- Back on the racing line: the pit lane is behind us however we left it.
      if pit.inLane then pit.leaveLane('cleared a checkpoint') end

      -- SECTOR CLOSED (sector number = gate number). Taken before onLapCompleted
      -- moves lapStart. The out lap is stamped but never scored.
      do
        local n = session.armedWp
        local sectorTime = localTime - timing.sectorStart
        timing.sectorStart = localTime
        -- Not on a backwards crossing: it clears the gate but is no time anybody
        -- drove, and would poison the best.
        if sectorTime > 0 and not backwards and not onOutLap() then
          timing.sectors[n] = sectorTime
          local best = timing.bestSector[n]
          local delta = best and (sectorTime - best) or nil
          if not best or sectorTime < best then timing.bestSector[n] = sectorTime end
          guihooks.trigger('RaceManagerSector', {
            sector = n, count = #track.route, time = sectorTime,
            delta = delta, best = not best or sectorTime <= timing.bestSector[n],
          })
        end
      end
      if session.armedWp >= #track.route then
        onLapCompleted()
        session.armedWp = 1
      else
        session.armedWp = session.armedWp + 1
      end
      -- A position may have changed hands: report on the next frame.
      progressLeft = 0
      pushRouteState()
    end
    checkJokerGates(session.prevPos, pos)
  end
  -- MUTATED IN PLACE, so a steady frame allocates nothing. Every consumer reads
  -- .x/.y/.z only; vec3 arithmetic on prevPos must copy it first.
  local pp = session.prevPos
  if pp then
    pp.x, pp.y, pp.z = pos.x, pos.y, pos.z
  else
    session.prevPos = { x = pos.x, y = pos.y, z = pos.z }
  end
end

-- ---------------------------------------------------------------------------
-- Live lap clock (display only)
-- ---------------------------------------------------------------------------
-- HUD feed only; the scored time is measured at the crossing. The UI
-- interpolates between pushes.
local lapTimeLeft    = 0
local lapTimerArmed  = false     -- was the clock running on the previous tick?

local function lapTimerUpdate(dt)
  -- Runs in any session from GO and in free practice (the app draws sectors
  -- inside the lap-time block, so without a clock they only showed at the line).
  local running = sessionRunning() or practice.on
  if not running then
    -- Tell the UI once, so it drops the readout rather than freezing it.
    if lapTimerArmed then
      lapTimerArmed = false
      guihooks.trigger('RaceManagerLapTime', { running = false })
    end
    return
  end
  lapTimerArmed = true
  lapTimeLeft = lapTimeLeft - dt
  if lapTimeLeft > 0 then return end
  lapTimeLeft = TUNE.LAP_TIME_EVERY
  guihooks.trigger('RaceManagerLapTime', {
    running = true,
    -- Practice counts in practice.lapsDone; session.localLap stays at 1.
    lap     = practice.on and (practice.lapsDone + 1) or session.localLap,
    elapsed = localTime - session.lapStart,
    -- On the out lap the app shows the lap for what it is, not a time.
    outLap  = onOutLap(),
  })
end

-- ---------------------------------------------------------------------------
-- Live position telemetry
-- ---------------------------------------------------------------------------
-- The server has no physics, so the distance to the next checkpoint (the
-- running order's third tie-break) is measured here and sent with the lap and
-- checkpoint count every PROGRESS_EVERY. The distance is computed only then.
-- THE WHITE FLAG, per driver, on the approach to the line that starts their
-- last lap. Every frame, not off the throttled report (12 m between samples at
-- 90 mph); the early-outs reject on integer compares before touching the car.
local function whiteFlagWatch()
  if session.phase ~= 'racing' or session.spectatorLock then return end
  -- Driving at the S/F line: the last checkpoint IS the line.
  if session.armedWp ~= #track.route or #track.route == 0 then return end

  -- Which flag on this approach: white before the last lap, checkered before
  -- the finish, one watcher so they agree on the line. A sprint has no white.
  local which, latch
  if track.pointToPoint then
    -- A sprint's only approach is to the finish, and its counter never reaches
    -- a lap target.
    which, latch = 'checkered', 'checkeredLap'
  else
    -- nil: a timed race before the leader has been past. No lap to wave at.
    local target = effectiveLapTarget()
    if not target then return end
    if session.localLap >= target then
      which, latch = 'checkered', 'checkeredLap'
    elseif target > 1 and session.localLap == target - 1 then
      -- The lap before the last: white on the approach that starts the final
      -- lap (how a car behind the leader learns lastLapNum landed).
      which, latch = 'white', 'whiteLap'
    else
      return
    end
  end
  if flags[latch] == session.localLap then return end

  local _, pos = sampledVehicle()
  if not pos then return end
  local wp = track.route[#track.route]
  if not wp then return end
  local dx, dy, dz = pos.x - wp.x, pos.y - wp.y, pos.z - wp.z
  local limit = TUNE.WHITE_FLAG_AT * TUNE.WHITE_FLAG_AT
  if (dx * dx + dy * dy + dz * dz) > limit then return end

  flags[latch] = session.localLap
  if which == 'checkered' then
    -- The approach flash, latched apart from the flag-taken notice that follows.
    flags.checkeredSeen = true
    pushNotice('flag', 'CHECKERED FLAG', { sub = 'Finish line', color = 'checkered' })
    if M.lightsMoment then M.lightsMoment('checkered') end
  else
    pushNotice('flag', 'WHITE FLAG', { sub = 'Last lap', color = 'white' })
    if M.lightsMoment then M.lightsMoment('white') end
  end
end

local function reportProgress(dt)
  if not sessionRunning() or session.spectatorLock then return end
  if #track.route == 0 then return end

  progressLeft = progressLeft - dt
  if progressLeft > 0 then return end

  local veh, pos = sampledVehicle()
  if not veh or not pos then return end
  progressLeft = TUNE.PROGRESS_EVERY

  -- The gate this car is driving towards (nearest, on a branched slot).
  -- ON AN OUT LAP IT IS THE S/F LINE, ON PURPOSE: paceLapWatch waves the green
  -- off this as meters-to-the-line, and pointed at the armed gate the formation
  -- lap ended at checkpoint 1. `cp` is progress round the route; `dist` is to
  -- the line on the lap that is given away.
  local wp = onOutLap() and track.route[#track.route] or branch.nearestAt(session.armedWp, pos)
  if not wp then return end

  local dx, dy, dz = pos.x - wp.x, pos.y - wp.y, pos.z - wp.z

  -- armedWp is the gate ahead, so the count cleared on this lap is one less.
  local payload = {
    lap  = session.localLap,
    cp   = session.armedWp - 1,
    dist = math.sqrt(dx * dx + dy * dy + dz * dz),
  }
  if inMultiplayer() then
    TriggerServerEvent('RM_Progress', jsonEncode(payload))
  end
  -- Same cadence to the driver's own header readout.
  guihooks.trigger('RaceManagerProgress', payload)
end

-- ===========================================================================
-- Vehicle & setup capture (Module 4)
-- ===========================================================================
-- The server sees only the jbeam model, so the exact build is fingerprinted
-- here (model, parts, tuning) for the Garage List.

-- The setup's name. Since v0.39 the .pc filename is only a sanitised derivative
-- of it, so the config's own name keys come first; the stem is the fallback.
local function configDisplayName(cfg)
  if type(cfg) ~= 'table' then return nil end
  for _, key in ipairs({ 'configName', 'name', 'title' }) do
    local v = cfg[key]
    if type(v) == 'string' and v ~= '' then return v end
  end
  if type(cfg.partConfigFilename) == 'string' then
    return cfg.partConfigFilename:match('([^/\\]+)%.pc$')
  end
  return nil
end

-- The BeamNG build, reported so the server can explain a Garage List that stops
-- matching after a game update renames parts (v0.39 did). nil = unknown, never
-- a mismatch.
local function gameVersion()
  for _, name in ipairs({ 'beamng_versionb', 'beamng_version', 'beamng_buildinfo' }) do
    local ok, v = pcall(function () return _G[name] end)
    if ok and type(v) == 'string' and v ~= '' then return v end
  end
  return nil
end

-- GARAGE: one table for the Garage List state (the locals ceiling).
--   pcCache       the spawn configuration, digested once per car (an edited
--                 car's partConfig is the whole build inline, ~73 KB: hashing
--                 it every poll hitched the game every two seconds)
--   vehParts      the digests the car itself reported
--   vehProbe      what the car last said about itself, for the panel
--   probeLeft     cooldown between questions to the vehicle
--   probesLeft    hard cap, so a silent car is not asked forever
--   settleSig     the signature we have been seeing
--   settleCount   how many polls running it has been the same
--   SETTLE_POLLS  how many it takes to be believed
--   lastDeclared  the previous declaration, for the log only
local garage = {
  pcCache = nil, vehParts = nil, vehProbe = nil,
  probeLeft = 0, probesLeft = 3,
  settleSig = nil, settleCount = 0, SETTLE_POLLS = 3,
  lastDeclared = nil,
  -- The last signature this client captured, so a rejection can say whether
  -- the car's identity moved since it was approved.
  lastCaptured = nil,
  -- Parts from BeamMP's spawn event, by vehicle id (see watchMPSpawns).
  spawnParts = {},
  spawnHooked = false,
  -- Vehicles BeamMP announced an edit for: their spawn parts are fresh.
  editPc = {},
  -- Vehicles whose spawn parts were dropped as stale. They must not fall back
  -- to the spawn config, which keys differently (see readSpawnConfig).
  mpDropped = {},
  -- The UI router timed out entering "play" (see garage.unstickUi).
  uiPlayStuck = false,
}

-- Livery slots (paint, plates, decals) are not part of the build: changing one
-- must never read as a part change. Matched on the slot name, narrowly:
-- `skidplate` is a real part, so plates are matched as `licenseplate` in full.
local function isCosmeticSlot(name)
  name = tostring(name):lower()
  return name:find('paint', 1, true) ~= nil
      or name:find('licenseplate', 1, true) ~= nil
      or name:find('license_plate', 1, true) ~= nil
      or name:find('livery', 1, true) ~= nil
      or name:find('decal', 1, true) ~= nil
      or name:find('skin', 1, true) ~= nil
end

-- THE DIGEST: `count:length:hashA:hashB` over the sorted "key=value;" form,
-- computed IDENTICALLY here and in the vehicle VM so a car's identity does not
-- depend on which source answered. `skipCosmetic` for the parts half only.
local function digestOf(t, skipCosmetic)
  if type(t) ~= 'table' then return '0:0:0:0' end
  local keys, n = {}, 0
  for k in pairs(t) do
    if not (skipCosmetic and isCosmeticSlot(k)) then
      keys[#keys + 1] = tostring(k); n = n + 1
    end
  end
  table.sort(keys)
  local out = {}
  for i = 1, #keys do
    local v = t[keys[i]]
    -- QUANTIZED to three decimals: %.6g wrote float noise in the last digits,
    -- so one untouched car hashed differently across spawns.
    if type(v) == 'number' then v = string.format('%.3f', v) else v = tostring(v) end
    out[#out + 1] = keys[i] .. '=' .. v
  end
  local str = table.concat(out, ';')
  local h1, h2 = 5381, 0
  for i = 1, #str do
    local c = str:byte(i)
    h1 = (h1 * 33 + c) % 4294967296
    h2 = (h2 * 65599 + c) % 4294967296
  end
  return n .. ':' .. #str .. ':' .. h1 .. ':' .. h2
end

-- The same digest for a plain string. An edited car's partConfig is the whole
-- configuration inline, past the server's 4000-byte signature limit.
local function digestText(str)
  if type(str) ~= 'string' or str == '' then return '-' end
  local h1, h2 = 5381, 0
  for i = 1, #str do
    local c = str:byte(i)
    h1 = (h1 * 33 + c) % 4294967296
    h2 = (h2 * 65599 + c) % 4294967296
  end
  return #str .. ':' .. h1 .. ':' .. h2
end

-- THE PARTS, DUG OUT OF THE SPAWN CONFIG, for an edited car whose partConfig
-- is the whole configuration. Three traps:
--   * It is a Lua table literal, not JSON: jsonDecode only when it looks like it.
--   * Load it with loadstring: LuaJIT's `load` rejects a string (the 5.3 test
--     harness accepts one, so tests cannot catch this).
--   * There is no flat `parts`: walk partsTree.children, keyed by SLOT NAME
--     (as BeamMP's spawn record and BeamJoy's convertPartsTree are), or one car
--     digests two ways depending on the source.
local function collectPartsTree(node, path, out, depth)
  if type(node) ~= 'table' or depth > 24 then return end
  local kids = node.children
  if type(kids) ~= 'table' then return end
  for slot, child in pairs(kids) do
    if type(child) == 'table' then
      local chosen = child.chosenPartName
      -- An empty slot is recorded ('-'): "no roof rack" differs from a rack.
      out[tostring(slot)] = (type(chosen) == 'string' and chosen ~= '') and chosen or '-'
      collectPartsTree(child, path, out, depth + 1)
    end
  end
end

-- The parts live in config.partsTree; config.parts is empty. nil when there is
-- no tree, so callers keep their "not loaded yet" handling.
function garage.partsFromTree(cfg)
  if type(cfg) ~= 'table' or type(cfg.partsTree) ~= 'table' then return nil end
  local out = {}
  collectPartsTree(cfg.partsTree, '', out, 0)
  if next(out) == nil then return nil end
  return out
end

-- THE PAINT, read off the vehicle: a .pc's `paints` is only written when an
-- admin ticks "save paints", so an entry built from parts alone came back in the
-- model's default colour. Never part of any signature.
function garage.paintsFrom(veh)
  if not veh or type(createVehiclePaint) ~= 'function' then return nil end
  local out = {}
  -- The three layers, read off the fields spawn.setVehicleObject writes them to
  -- (color, colorPalette0, colorPalette1), so they round trip. getColorFTable
  -- returned nothing here. `paintField`, not `field`: that shadows a top-level
  -- local (tests/scope_test.lua).
  for i, paintField in ipairs({ 'color', 'colorPalette0', 'colorPalette1' }) do
    local got = nil
    pcall(function ()
      local c = veh[paintField]
      -- createVehiclePaint substitutes WHITE for a missing .x; skip instead.
      if type(c.x) ~= 'number' then return end
      local md = nil
      pcall(function ()
        if type(stringToTable) == 'function' then
          md = stringToTable(veh:getField('metallicPaintData', i - 1))
        end
      end)
      if type(md) ~= 'table' then md = nil end
      local paint = createVehiclePaint(c, md)
      if type(validateVehiclePaint) == 'function' then pcall(validateVehiclePaint, paint) end
      got = paint
    end)
    -- Stop at the first missing layer: the list is positional.
    if not got then break end
    out[#out + 1] = got
  end
  return (#out > 0) and out or nil
end

-- The car as BeamNG will spawn it: the parts themselves, not a .pc path only
-- the capturing admin has (a missing file spawns the model's default, which
-- then failed enforcement). '-' (empty slot in a signature) becomes '' for the
-- loader.
function garage.spawnConfigFrom(cfg)
  local parts = garage.partsFromTree(cfg)
  if not parts and type(cfg) == 'table' and type(cfg.parts) == 'table'
     and next(cfg.parts) ~= nil then
    parts = cfg.parts
  end
  if not parts then return nil end
  local out = {}
  for slot, part in pairs(parts) do
    out[slot] = (part == '-') and '' or part
  end
  return { parts = out,
           vars = (type(cfg) == 'table' and type(cfg.vars) == 'table') and cfg.vars or {} }
end

-- CATCH THE PARTS AS THEY GO PAST. A car spawned from a saved config exposes
-- nothing afterwards (partConfig is a path; partmgmt, vehData and the car report
-- 0), but BeamMP's spawn and edit events carry a flat `parts` table. Wrap them
-- and keep it. The original is always called; the payload shape is not assumed.
local function watchMPSpawns()
  if garage.spawnHooked then return end
  if not (MPVehicleGE and type(MPVehicleGE.onServerVehicleSpawned) == 'function') then
    return
  end

  -- Shared by both wrappers; `what` is 'spawn' or 'edit'.
  local function catch(args, argc, what)
    pcall(function ()
      for i = 1, argc do
        local a = args[i]
        if type(a) == 'string' and a:sub(1, 1) == '{' and type(jsonDecode) == 'function' then
          local okD, decoded = pcall(jsonDecode, a)
          if okD and type(decoded) == 'table' then a = decoded end
        end
        if type(a) == 'table' then
          local cfg = type(a.vcf) == 'table' and a.vcf or a
          if type(cfg.parts) == 'table' and next(cfg.parts) ~= nil then
            local id = a.vid or a.gameVehicleID or cfg.vid
            if id ~= nil then
              local n = 0
              for _ in pairs(cfg.parts) do n = n + 1 end
              local pc = cfg.partConfigFilename
              if what == 'spawn' then
                garage.spawnParts[tostring(id)] = cfg.parts
              else
                -- An edit refills the parts: the spawn event fires once.
                garage.spawnParts[tostring(id)] = cfg.parts
                -- Always truthy: an edit payload need not name a config.
                garage.editPc[tostring(id)] = pc or '(unnamed)'
              end
              garage.mpDropped[tostring(id)] = nil
              log('I', 'raceManager', 'Caught ' .. n .. ' parts from the BeamMP '
                .. what .. ' event for vehicle ' .. tostring(id)
                .. ' (' .. tostring(pc or '?') .. ')')
            end
          end
        end
      end
    end)
  end

  local original = MPVehicleGE.onServerVehicleSpawned
  MPVehicleGE.onServerVehicleSpawned = function (...)
    -- `...` does not reach inside the pcall's function.
    local args, argc = { ... }, select('#', ...)
    catch(args, argc, 'spawn')
    return original(...)
  end

  -- Edits refresh the caught parts; logged when absent, since silence reads as
  -- "no edit happened".
  if type(MPVehicleGE.onServerVehicleEdited) == 'function' then
    local originalEdit = MPVehicleGE.onServerVehicleEdited
    MPVehicleGE.onServerVehicleEdited = function (...)
      local args, argc = { ... }, select('#', ...)
      catch(args, argc, 'edit')
      return originalEdit(...)
    end
  else
    log('W', 'raceManager', 'MPVehicleGE.onServerVehicleEdited is ABSENT on '
      .. 'this build, so no edit can ever be announced')
  end

  garage.spawnHooked = true
  log('I', 'raceManager', 'Watching BeamMP spawn events for vehicle parts')
end

local function partsFromMP(vid)
  -- The spawn event first: the only source for a car spawned from a saved config.
  local caught = garage.spawnParts[tostring(vid)]
  if type(caught) == 'table' and next(caught) ~= nil then
    return caught, 'spawn event'
  end

  if not (MPVehicleGE and type(MPVehicleGE.getVehicles) == 'function') then
    return nil, 'no MPVehicleGE'
  end
  local list = nil
  pcall(function () list = MPVehicleGE.getVehicles() end)
  if type(list) ~= 'table' then return nil, 'no vehicle list' end
  for _, v in pairs(list) do
    if type(v) == 'table' and tostring(v.gameVehicleID) == tostring(vid) then
      for _, key in ipairs({ 'vcf', 'vehicleConfig', 'config', 'spawnData', 'data' }) do
        local c = v[key]
        if type(c) == 'table' then
          if type(c.parts) == 'table' and next(c.parts) ~= nil then
            return c.parts, key
          end
          if type(c.vcf) == 'table' and type(c.vcf.parts) == 'table'
              and next(c.vcf.parts) ~= nil then
            return c.vcf.parts, key .. '.vcf'
          end
        end
      end
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      return nil, 'no parts on the MP record; it has: ' .. table.concat(keys, ' ')
    end
  end
  return nil, 'vehicle ' .. tostring(vid) .. ' is not in the MP list'
end

local function partsFromConfigString(str)
  if type(str) ~= 'string' or #str < 2 then return nil end
  if str:match('%.pc$') then return nil end

  local cfg = nil
  -- jsonDecode only when it looks like JSON; BeamNG writes Lua ({["key"]=...}).
  if str:sub(1, 2) == '{"' and type(jsonDecode) == 'function' then
    pcall(function () cfg = jsonDecode(str) end)
  end
  if type(cfg) ~= 'table' and type(deserialize) == 'function' then
    cfg = nil
    pcall(function () cfg = deserialize(str) end)
  end
  if type(cfg) ~= 'table' then
    cfg = nil
    -- loadstring first: on LuaJIT it is the only one that takes source.
    local mk = loadstring or load
    pcall(function ()
      local fn = mk('return ' .. str, 'partConfig')
      if fn then
        -- No environment: it only needs to build a table.
        if setfenv then setfenv(fn, {}) end
        cfg = fn()
      end
    end)
  end
  if type(cfg) ~= 'table' then return nil end

  -- The tree is the real shape; a flat `parts` is accepted too.
  if type(cfg.partsTree) == 'table' then
    local out = {}
    collectPartsTree(cfg.partsTree, '', out, 0)
    if next(out) ~= nil then return out end
  end
  if type(cfg.parts) ~= 'table' and type(cfg.config) == 'table' then
    cfg = cfg.config
  end
  if type(cfg.parts) ~= 'table' or next(cfg.parts) == nil then return nil end
  return cfg.parts
end

-- Ask the car for its DIGEST, never its configuration (compiling a whole config
-- as Lua every poll froze the game once a part changed). No bitwise operators:
-- the vehicle VM's Lua is not ours to choose. `userAsked` (Whitelist pressed)
-- bypasses the poll's budget, which is usually spent by then.
local function requestVehicleParts(veh, userAsked)
  if not veh then return end
  if userAsked then
    if garage.probeLeft > 13.0 then return end        -- asked less than 2s ago
  elseif garage.probeLeft > 0 or garage.probesLeft <= 0 then
    return
  end
  -- Fifteen seconds: this runs in the vehicle VM on the PHYSICS THREAD. A part
  -- change respawns the car and re-arms this; the timer only catches a re-tune.
  garage.probeLeft = 15.0
  if not userAsked then garage.probesLeft = garage.probesLeft - 1 end
  if not garage.vehProbe then garage.vehProbe = 'asked' end
  pcall(function ()
    veh:queueLuaCommand([==[
      pcall(function ()
        -- `rmDigest`, not `D`: tests/scope_test.lua scans this string too.
        -- Hashed incrementally, so no config-sized string is built on the
        -- physics thread; the result equals digestOf() byte for byte.
        -- rmCosmetic must match isCosmeticSlot exactly, or a car digests two
        -- ways and stops matching its own whitelist entry.
        local function rmCosmetic(name)
          name = tostring(name):lower()
          return name:find('paint', 1, true) ~= nil
              or name:find('licenseplate', 1, true) ~= nil
              or name:find('license_plate', 1, true) ~= nil
              or name:find('livery', 1, true) ~= nil
              or name:find('decal', 1, true) ~= nil
              or name:find('skin', 1, true) ~= nil
        end
        local function rmDigest(t, skipCosmetic)
          if type(t) ~= 'table' then return '0:0:0:0' end
          local k, n = {}, 0
          for a in pairs(t) do
            if not (skipCosmetic and rmCosmetic(a)) then
              k[#k+1] = tostring(a); n = n + 1
            end
          end
          table.sort(k)
          local h1, h2, len = 5381, 0, 0
          local function feed(str)
            for i = 1, #str do
              local c = str:byte(i)
              h1 = (h1 * 33 + c) % 4294967296
              h2 = (h2 * 65599 + c) % 4294967296
            end
            len = len + #str
          end
          for i = 1, #k do
            if i > 1 then feed(';') end
            local val = t[k[i]]
            -- Quantized as digestOf does (three decimals, fixed width).
            if type(val) == 'number' then val = string.format('%.3f', val)
            else val = tostring(val) end
            feed(k[i]); feed('='); feed(val)
          end
          return n .. ':' .. len .. ':' .. h1 .. ':' .. h2
        end
        -- `v.config` first: partmgmt.getConfig() assembles the config, real
        -- work on the physics thread every poll.
        local cfg
        if type(v) == 'table' and type(v.config) == 'table'
            and type(v.config.parts) == 'table' and next(v.config.parts) ~= nil then
          cfg = v.config
        elseif partmgmt and partmgmt.getConfig then
          local c = partmgmt.getConfig()
          if type(c) == 'table' then cfg = c end
        end
        cfg = cfg or (type(v) == 'table' and v.config) or {}
        obj:queueGameEngineLua('raceManager.onVehicleDigest("'
          .. rmDigest(cfg.parts, true) .. '","' .. rmDigest(cfg.vars) .. '")')
      end)
    ]==])
  end)
end

local function localVehicleConfig(userAsked)
  local veh = ownVehicle()
  if not veh then return nil, 'Get in a vehicle first' end
  local attached = playerVehicle()
  if attached and vehicleId(attached) ~= vehicleId(veh) then
    return nil, 'Switch back to your own car first'
  end
  local model = '?'
  pcall(function () model = tostring(veh:getJBeamFilename()) end)
  local vid = vehicleId(veh)

  -- configPc is the saved config's PATH (opts.config for replaceVehicle), nil
  -- for a car edited in the session.
  local parts, vars, configName, source, configPc = {}, {}, nil, nil, nil
  -- The car in the shape another client can spawn it from (spawnConfigFrom).
  local spawnCfg = nil
  local offered, notes = 0, {}

  -- First non-empty answer wins. No vehicle has zero parts, so empty means the
  -- source could not see this car.
  local function take(cfg, from)
    if next(parts) ~= nil or type(cfg) ~= 'table' then return end
    -- partsTree first; `parts` is empty on a live client.
    local got = garage.partsFromTree(cfg)
    if not got and type(cfg.parts) == 'table' and next(cfg.parts) ~= nil then
      got = cfg.parts
    end
    if not got then return end
    parts      = got
    vars       = type(cfg.vars) == 'table' and cfg.vars or {}
    -- From the same table as the signature parts, so the entry spawns this car.
    spawnCfg   = garage.spawnConfigFrom(cfg)
    -- The colour, read off the vehicle (garage.paintsFrom).
    if spawnCfg then spawnCfg.paints = garage.paintsFrom(veh) end
    configName = configDisplayName(cfg)
    if type(cfg.partConfigFilename) == 'string' and cfg.partConfigFilename ~= '' then
      configPc = cfg.partConfigFilename
    end
    source     = from
  end

  -- What each source answered, for the refusal shown in the panel: 'absent' is
  -- no API; a number is an API that found that many parts (0: not this car).
  local function note(from, ok, cfg)
    if not ok then notes[#notes + 1] = from .. '=error'; return end
    if type(cfg) ~= 'table' then
      notes[#notes + 1] = from .. '=' .. type(cfg)
      return
    end
    -- Counted the same way `take` resolves, or the panel misreports.
    local n, seen = 0, garage.partsFromTree(cfg)
    if not seen and type(cfg.parts) == 'table' then seen = cfg.parts end
    if type(seen) == 'table' then for _ in pairs(seen) do n = n + 1 end end
    notes[#notes + 1] = from .. '=' .. n
  end

  -- THE PER-VEHICLE STORE FIRST, pinned to this vehicle id. partmgmt answers
  -- about whichever car is current and gave one untouched car two alternating
  -- digests, so a whitelisted car was refused on the other answer.
  if core_vehicle_manager and core_vehicle_manager.getVehicleData and vid then
    offered = offered + 1
    local ok, data = pcall(core_vehicle_manager.getVehicleData, vid)
    if ok and type(data) == 'table' then take(data.config, 'vehicleData') end
    note('vehData', ok, type(data) == 'table' and data.config or data)
  else
    notes[#notes + 1] = 'vehData=absent'
  end

  -- Fallback: on a build with an empty per-vehicle store it is the only source.
  -- Named in the log, so a wandering signature can be recognised.
  if core_vehicle_partmgmt and core_vehicle_partmgmt.getConfig then
    offered = offered + 1
    local ok, cfg = pcall(core_vehicle_partmgmt.getConfig)
    if ok then take(cfg, 'partmgmt') end
    note('partmgmt', ok, cfg)
  else
    notes[#notes + 1] = 'partmgmt=absent'
  end

  -- EACH SOURCE FOR WHAT IT IS GOOD AT: tuning always from the car (it reports
  -- a re-tune live, and no parts), parts always from the config. Preferring
  -- either "when available" changes a signature's shape under a stored entry.
  local pd, vd = nil, nil
  if garage.vehParts and garage.vehParts.vid == vid and garage.vehParts.pd then
    pd, vd = garage.vehParts.pd, garage.vehParts.vd
    notes[#notes + 1] = 'car=' .. (pd:match('^(%d+)') or '?')
  else
    notes[#notes + 1] = 'car=' .. (garage.vehProbe or 'none')
  end

  -- The car never supplies the parts: '0:0:0:0' is cleared here so a real parts
  -- list below can fill it.
  if pd == '0:0:0:0' then pd = nil end

  -- A parts table read here is digested exactly as the car does it, so both
  -- routes produce one signature shape.
  if not pd and next(parts) ~= nil then
    pd, vd = digestOf(parts, true), digestOf(vars)
  end

  -- The spawn config, read and digested ONCE per car: it can be tens of KB.
  local function readSpawnConfig()
    local raw = nil
    pcall(function () raw = veh:getField('partConfig', 0) end)

    -- THE PARTS CAUGHT AT SPAWN CAN BE OLDER THAN THE CAR: with no edit event,
    -- an inline partConfig proves a rebuild, so the caught parts are dropped.
    local key = tostring(vid)
    if type(raw) == 'string' and raw ~= '' and not raw:match('%.pc$')
        and garage.spawnParts[key] and not garage.editPc[key] then
      garage.spawnParts[key] = nil
      garage.mpDropped[key] = true
      log('W', 'raceManager', 'The parts caught at spawn are older than this '
        .. 'car (its configuration is now inline, ' .. #raw .. ' bytes) and '
        .. 'BeamMP announced no edit, so they are dropped rather than left to '
        .. 'answer for a build they no longer describe')
    end

    -- BeamMP's record first: the only source for a car from a saved config.
    local mpParts, mpWhy = partsFromMP(vid)
    if mpParts then
      local c = 0
      for _ in pairs(mpParts) do c = c + 1 end
      local freed, n = {}, 0
      for slot in pairs(mpParts) do
        if isCosmeticSlot(slot) then
          n = n + 1
          if n <= 12 then freed[#freed + 1] = slot end
        end
      end
      garage.pcCache = {
        vid = vid, digest = '-', len = 0,
        parts = digestOf(mpParts, true), count = c, from = 'mp',
      }
      log('I', 'raceManager', 'Read ' .. c .. ' parts from the BeamMP spawn '
        .. 'record (' .. tostring(mpWhy) .. '); ' .. n .. ' left free as '
        .. 'livery: ' .. (n > 0 and table.concat(freed, ' ') or 'NONE'))
      return
    end

    -- BeamMP's vehicle record carries no configuration (only the spawn EVENT
    -- does); kept, guarded, in case a future build keeps it.
    log('D', 'raceManager', 'BeamMP spawn record has no configuration ('
      .. tostring(mpWhy) .. '); using the spawn configuration instead')

    -- NO FALLING BACK ACROSS SOURCES: the tree enumerates different slots than
    -- the spawn record, so the digest would move on a respray and the car be
    -- removed. Declare nothing instead (never an offender), cached as a refusal
    -- so an inline configuration is not re-read every poll.
    if garage.mpDropped[key] then
      garage.pcCache = { vid = vid, digest = '-', len = 0, parts = nil,
                         count = 0, from = 'dropped' }
      log('W', 'raceManager', 'This car was known through the BeamMP spawn '
        .. 'event and that answer is now stale, so it is UNJUDGED until it '
        .. 'respawns rather than being re-identified from a source that '
        .. 'enumerates different slots')
      return
    end

    if type(raw) ~= 'string' or raw == '' then
      -- NOT CACHED: a car one frame old has no configuration yet. Caching the
      -- miss blocked that vehicle permanently.
      garage.pcCache = nil
    else
      local fromCfg = partsFromConfigString(raw)
      garage.pcCache = {
        vid = vid, digest = digestText(raw), len = #raw,
        parts = fromCfg and digestOf(fromCfg, true) or nil,
        count = fromCfg and (function ()
          local c = 0
          for _ in pairs(fromCfg) do c = c + 1 end
          return c
        end)() or 0,
        from = 'tree',
      }
      if fromCfg then
        -- Name the slots the livery filter freed: if the paint slot is not
        -- listed, it is not called what this code thinks.
        local freed, n = {}, 0
        for slot in pairs(fromCfg) do
          if isCosmeticSlot(slot) then
            n = n + 1
            if n <= 12 then freed[#freed + 1] = slot end
          end
        end
        log('I', 'raceManager', 'Read ' .. garage.pcCache.count
          .. ' parts out of the spawn configuration; ' .. n
          .. ' left free as livery: ' .. (n > 0 and table.concat(freed, ' ')
            or 'NONE -- a paint or plate change will be treated as a part'))
      else
        -- Not silent: an empty parts digest matches every car, so log why.
        log('W', 'raceManager', 'Could not read parts out of the spawn '
          .. 'configuration (' .. #raw .. ' bytes), and BeamMP had none either ('
          .. tostring(mpWhy) .. ') -- the Parts lock has nothing to compare. '
          .. 'It begins: ' .. raw:sub(1, 120))
      end
    end
  end
  if not (garage.pcCache and garage.pcCache.vid == vid) then readSpawnConfig() end
  notes[#notes + 1] = 'pc=' .. (garage.pcCache and garage.pcCache.len > 0 and garage.pcCache.len or 'none')
    .. ((garage.pcCache and garage.pcCache.parts) and ('/' .. garage.pcCache.count .. 'p') or '')

  local detail = ' [' .. table.concat(notes, ', ') .. ']'

  -- No source at all is a different failure from every source being empty:
  -- "try again" would be wrong advice.
  if offered == 0 then
    log('E', 'raceManager', 'No vehicle configuration source on this build')
    return nil, 'This game build exposes no vehicle configuration to read' .. detail
  end

  -- The spawn config is a FALLBACK: a spawn-time snapshot that outranked the
  -- live tree hid a part swapped afterwards. Only used when the tree is unread.
  if not pd and garage.pcCache and garage.pcCache.parts then
    pd = garage.pcCache.parts
  end

  -- BOTH HALVES OR NEITHER, and '0:0:0:0' is not a parts digest. The parts
  -- arrive first and the tuning a moment later, so declaring early produced two
  -- signatures for one untouched car, and an approved car was removed. Declare
  -- nothing until both are real: no declaration is "no verdict", never an
  -- offender.
  if pd == '0:0:0:0' then pd = nil end

  if not pd or not vd then
    -- Ask the car to report, so the next press has something to read.
    requestVehicleParts(veh, userAsked)
    -- Silent: the two-second poll runs this too, and logging buried the
    -- vehicle-side answers. The caller tells a person who pressed something.
    return nil, 'Reading the vehicle, press again in a moment' .. detail
  end

  -- partsSig is Parts mode, which promises free tuning: the parts digest and
  -- nothing a re-tune can move. The byte layout matches entries already on disk.
  local partsSig = 'model=' .. model .. '|pd=' .. pd
  -- STRICT IS PARTS PLUS TUNING, NOTHING ELSE. A hash of the raw partConfig
  -- (which includes livery) made Strict block paint and plates.
  local sig = partsSig .. '|vd=' .. (vd or '0:0:0:0')
  source = source or 'digest'
  configName = configName or nil
  return {
    model    = model,
    label    = configName and (model .. ' - ' .. configName) or model,
    partsSig = partsSig,
    sig      = sig,
    vid      = vid,
    -- Which source answered, for the log.
    source   = source,
    -- The saved config, for the log and a client that has the same file.
    pc       = configPc,
    -- What the car IS: the only field another machine can build it from.
    cfg      = spawnCfg,
  }
end

-- A SIGNATURE HAS TO HOLD STILL BEFORE ANYBODY IS JUDGED ON IT. Every source
-- (spawn config parts, the car's tuning, BeamMP's record) reads empty for a
-- moment after a car appears, and each transition is a new signature the server
-- would refuse. So nothing is judged until it repeats SETTLE_POLLS polls
-- running; meanwhile nothing is declared, which is never an offender.

-- The current signature once it has stopped moving, else nil and a reason.
local function settledConfig(userAsked)
  local cfg, why = localVehicleConfig(userAsked)
  if not cfg then
    garage.settleSig, garage.settleCount = nil, 0
    return nil, why
  end
  if cfg.sig == garage.settleSig then
    garage.settleCount = garage.settleCount + 1
  else
    garage.settleSig, garage.settleCount = cfg.sig, 1
  end
  if garage.settleCount < garage.SETTLE_POLLS then
    return nil, 'Reading the vehicle, press again in a moment [settling '
      .. garage.settleCount .. '/' .. garage.SETTLE_POLLS .. ']'
  end
  return cfg
end

-- Last signature declared to the server, so the poll only talks on a change.
local lastReportedSig = nil
local configCheckLeft = 0

-- Exposed for tests/garage_test.lua: the digest decides whether a car may race.
function M.digestForTest(t, skipCosmetic) return digestOf(t, skipCosmetic) end

-- THE CAR'S ANSWER: two digests, called by name from the vehicle VM. Anything
-- not shaped like four colon-separated numbers is discarded.
function M.onVehicleDigest(partsDigest, varsDigest)
  local function clean(d)
    d = tostring(d or '')
    return d:match('^%d+:%d+:%d+:%d+$') and d or nil
  end
  local pd, vd = clean(partsDigest), clean(varsDigest)
  if not pd then return end
  local veh = ownVehicle()
  local before = garage.vehParts and garage.vehParts.pd
  garage.vehParts = {
    vid = veh and vehicleId(veh),
    pd  = pd,
    vd  = vd or '0:0:0:0',
  }
  garage.vehProbe = 'digest'
  -- A car that answers keeps its budget, so a part change shows up.
  garage.probesLeft = 3
  if before ~= pd then
    log('I', 'raceManager', 'Vehicle build digest: ' .. pd
      .. (before and (' (was ' .. before .. ')') or ''))
    -- The server holds the OLD build: re-declare now.
    lastReportedSig = nil
  end
end

function M.onVehicleProbe(status)
  garage.vehProbe = tostring(status or '?')
  log('I', 'raceManager', 'Vehicle probe: ' .. garage.vehProbe)
end

-- Retained entry point: a queued call from an older client build must not land
-- on a nil. Stores exactly what onVehicleDigest does, through digestOf.
function M.onVehicleParts(cfg)
  if type(cfg) ~= 'table' or type(cfg.parts) ~= 'table' then return end
  if next(cfg.parts) == nil then return end      -- still nothing: keep waiting
  M.onVehicleDigest(digestOf(cfg.parts, true), digestOf(cfg.vars))
end

local function reportVehicleConfig(force)
  if not inMultiplayer() then return end
  local cfg = settledConfig()
  if not cfg then return end
  -- Keyed on the FULL signature: the client is not told the mode, and an admin
  -- may switch to strict mid-evening.
  if not force and cfg.sig == lastReportedSig then return end
  lastReportedSig = cfg.sig
  -- Logged on every CHANGE, with WHAT MOVED: parts moving on a paint change is a
  -- missed livery slot; nothing moving while refused is a stale garage entry.
  local moved = 'first'
  if garage.lastDeclared then
    local wasP, nowP = garage.lastDeclared:match('|pd=([^|]*)'), cfg.sig:match('|pd=([^|]*)')
    local wasV, nowV = garage.lastDeclared:match('|vd=([^|]*)'), cfg.sig:match('|vd=([^|]*)')
    local bits = {}
    if wasP ~= nowP then bits[#bits + 1] = 'PARTS' end
    if wasV ~= nowV then bits[#bits + 1] = 'TUNING' end
    moved = #bits > 0 and table.concat(bits, '+') or 'nothing'
  end
  garage.lastDeclared = cfg.sig
  log('I', 'raceManager', 'Declared to the server [' .. tostring(cfg.source)
    .. ', changed: ' .. moved .. ']: ' .. tostring(cfg.sig))
  TriggerServerEvent('RM_VehicleConfig', jsonEncode({
    vid = cfg.vid, model = cfg.model, label = cfg.label,
    sig = cfg.sig, partsSig = cfg.partsSig,
    game = gameVersion(),
  }))
end

-- A car appeared: re-declare it shortly, not on this frame (its parts are not
-- loaded yet). lastReportedSig is cleared so a respawn counts as a change.
local function armVehicleConfigReport()
  lastReportedSig = nil
  configCheckLeft = 1.0
  -- Everything cached belongs to the car that went away; ids get reused.
  garage.vehParts = nil
  garage.pcCache = nil
  garage.settleSig, garage.settleCount = nil, 0
  -- A fresh question budget per car.
  garage.probesLeft = 3
  -- Not asked here: a part change rebuilds the vehicle and can fire this more
  -- than once; the poll asks a second later, when the car can answer.
  garage.probeLeft = 1.0
end

-- Polls the configuration on a slow timer: no single reliable GE event covers
-- spawns, swaps and re-tunes across BeamNG versions.
local function vehicleConfigUpdate(dt)
  if not inMultiplayer() then return end
  -- Installed from the poll: MPVehicleGE may not exist at load. No-op once hooked.
  watchMPSpawns()
  if garage.probeLeft > 0 then garage.probeLeft = garage.probeLeft - dt end
  configCheckLeft = configCheckLeft - dt
  if configCheckLeft > 0 then return end
  configCheckLeft = 2.0
  reportVehicleConfig(false)
end

-- Admin action: capture the car being driven right now and add it to the
-- server's Garage List.
function M.whitelistCurrentVehicle()
  if not inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'The Garage List needs a BeamMP server' })
    return
  end
  -- userAsked: may question the car past the poll's budget. Settled too, or the
  -- entry stops matching the car a second later.
  local cfg, why = settledConfig(true)
  if not cfg then
    guihooks.trigger('RaceManagerEditorMsg', { msg = why or 'Get in a vehicle first' })
    -- Logged per press, not per poll.
    log('W', 'raceManager', 'Whitelist refused: ' .. tostring(why))
    return
  end
  -- The car travels with the capture. The server stores it but never puts it on
  -- the state broadcast (garageSnapshot ships a flag).
  TriggerServerEvent('RM_WhitelistVehicle', jsonEncode({
    model = cfg.model, label = cfg.label,
    sig = cfg.sig, partsSig = cfg.partsSig, game = gameVersion(),
    pc = cfg.pc, cfg = cfg.cfg,
  }))
  if type(cfg.cfg) ~= 'table' then
    -- Said out loud: without parts only the capturing admin can spawn it.
    log('W', 'raceManager', 'Whitelisted without a spawnable configuration: '
      .. 'drivers on other machines cannot take this car')
  else
    -- The paint layers are counted: a silent empty read cost the colour once.
    local layers = type(cfg.cfg.paints) == 'table' and #cfg.cfg.paints or 0
    log('I', 'raceManager', 'Captured configuration: '
      .. tostring(cfg.cfg.parts and (function ()
           local n = 0
           for _ in pairs(cfg.cfg.parts) do n = n + 1 end
           return n
         end)() or 0) .. ' parts, ' .. layers .. ' paint layer(s)')
    if layers == 0 then
      log('W', 'raceManager', 'No paint could be read off this car, so the entry '
        .. 'will spawn in the model default colour. Run '
        .. 'raceManager.diagnoseVehicleConfig() to see which colour fields this '
        .. 'build exposes')
    end
  end
  -- The captured signature in full, beside the "Declared to the server" lines:
  -- same string means the list is at fault, a different one shows which half.
  log('I', 'raceManager', 'Whitelisting current vehicle: ' .. cfg.label
    .. ' (read from ' .. tostring(cfg.source) .. ')')
  garage.lastCaptured = cfg.sig
  log('I', 'raceManager', 'Captured signature: ' .. tostring(cfg.sig))
end

-- Console diagnosis for a refused Whitelist: raceManager.diagnoseVehicleConfig()
-- Prints what every configuration source answers, which the panel cannot.
function M.diagnoseVehicleConfig()
  local function line(s) log('I', 'raceManager', s); print('[RaceManager] ' .. s) end
  local function describe(cfg)
    if type(cfg) ~= 'table' then return 'not a table (' .. type(cfg) .. ')' end
    local np, nv = 0, 0
    if type(cfg.parts) == 'table' then for _ in pairs(cfg.parts) do np = np + 1 end end
    if type(cfg.vars)  == 'table' then for _ in pairs(cfg.vars)  do nv = nv + 1 end end
    return np .. ' parts, ' .. nv .. ' vars, name=' .. tostring(configDisplayName(cfg))
  end

  line('--- vehicle configuration diagnosis ---')
  line('multiplayer: ' .. tostring(inMultiplayer()))
  local veh = ownVehicle()
  line('ownVehicle: ' .. (veh and 'yes' or 'NO -- nothing to read'))
  local attached = playerVehicle()
  line('attached vehicle id: ' .. tostring(attached and vehicleId(attached))
    .. ', own vehicle id: ' .. tostring(veh and vehicleId(veh)))

  if core_vehicle_partmgmt and core_vehicle_partmgmt.getConfig then
    local ok, cfg = pcall(core_vehicle_partmgmt.getConfig)
    line('core_vehicle_partmgmt.getConfig: ' .. (ok and describe(cfg)
      or ('RAISED: ' .. tostring(cfg))))
  else
    line('core_vehicle_partmgmt.getConfig: ABSENT on this build')
  end

  local vid = veh and vehicleId(veh)
  if core_vehicle_manager and core_vehicle_manager.getVehicleData then
    if vid then
      local ok, data = pcall(core_vehicle_manager.getVehicleData, vid)
      line('core_vehicle_manager.getVehicleData(' .. tostring(vid) .. '): '
        .. (ok and (type(data) == 'table' and describe(data.config)
                    or 'not a table (' .. type(data) .. ')')
            or ('RAISED: ' .. tostring(data))))
    else
      line('core_vehicle_manager.getVehicleData: no vehicle id to ask about')
    end
  else
    line('core_vehicle_manager.getVehicleData: ABSENT on this build')
  end

  local cfg, why = localVehicleConfig()
  if cfg then
    line('RESOLVED via ' .. tostring(cfg.source) .. ': ' .. cfg.label)
    line('signature: ' .. cfg.sig:sub(1, 200))
  else
    line('REFUSED: ' .. tostring(why))
  end

  -- The source that answered for the parts.
  local pcc = garage.pcCache
  -- The colour, field by field: an absent field and a rejected read look the
  -- same from the panel.
  do
    local bits = {}
    for _, paintField in ipairs({ 'color', 'colorPalette0', 'colorPalette1' }) do
      local got = nil
      pcall(function ()
        local c = veh and veh[paintField]
        got = (type(c) == 'nil') and 'absent' or (type(c.x) == 'number' and 'ok' or ('no .x (' .. type(c) .. ')'))
      end)
      bits[#bits + 1] = paintField .. '=' .. tostring(got or 'raised')
    end
    local paints = garage.paintsFrom(veh)
    line('paint: ' .. (paints and (#paints .. ' layer(s)') or 'NONE -- the car will '
      .. 'spawn in the model default colour') .. '  [' .. table.concat(bits, ', ') .. ']')
    line('  createVehiclePaint: ' .. type(createVehiclePaint)
      .. ', stringToTable: ' .. type(stringToTable))
  end
  line('spawn config: ' .. tostring(pcc and pcc.from or 'none')
    .. ', ' .. tostring(pcc and pcc.count or 0) .. ' parts')
  line('--- end ---')
end

-- This client's results copies, inside BeamNG's user folder: exploreFolder
-- refuses anything outside the virtual filesystem. On M for the locals ceiling.
M.RESULTS_LOCAL_DIR = 'settings/raceManager/results'

-- A copy of the results for an admin who is not the server owner. The server's
-- copy stays the record.
function M.onResultsFile(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local text = tostring(data.text or '')
  if text == '' then return end
  -- Sanitised: this arrives over the wire and becomes a filename.
  local name = tostring(data.name or 'results.txt'):gsub('[^%w%-_%.]', '_')
  if name == '' then name = 'results.txt' end

  if FS and FS.directoryCreate then pcall(function () FS:directoryCreate(M.RESULTS_LOCAL_DIR, true) end) end
  local path = M.RESULTS_LOCAL_DIR .. '/' .. name
  local wrote = false
  if type(writeFile) == 'function' then
    wrote = pcall(writeFile, path, text) and true or false
  else
    local f = io.open(path, 'w')
    if f then f:write(text); f:close(); wrote = true end
  end
  if not wrote then
    log('W', 'raceManager', 'Could not write a local results copy to ' .. path)
    return
  end
  log('I', 'raceManager', 'Results saved locally: ' .. path .. ' (' .. #text .. ' bytes)')
  pushNotice('session', 'Results saved to your own copy: ' .. name)
end

-- Open this client's results folder (inside BeamNG's files, so it can).
function M.openLocalResults()
  if FS and FS.directoryCreate then pcall(function () FS:directoryCreate(M.RESULTS_LOCAL_DIR, true) end) end
  local real = nil
  if FS and FS.getFileRealPath then
    local okR, r = pcall(function () return FS:getFileRealPath(M.RESULTS_LOCAL_DIR) end)
    if okR then real = r end
  end
  if Engine and Engine.Platform and Engine.Platform.exploreFolder then
    pcall(Engine.Platform.exploreFolder, '/' .. M.RESULTS_LOCAL_DIR .. '/')
  end
  log('I', 'raceManager', 'Local results folder: ' .. tostring(real or M.RESULTS_LOCAL_DIR))
  pushNotice('session', 'Your results copies: ' .. tostring(real or M.RESULTS_LOCAL_DIR))
end

-- Delete THIS PC's results copies, and nothing else: the server's record is
-- untouched, so this needs no admin. Depth 0 and *.txt only.
function M.clearLocalResults()
  if not (FS and FS.findFiles and FS.removeFile) then
    pushNotice('session', 'This build has no file access, so the copies cannot be removed')
    log('W', 'raceManager', 'clearLocalResults: FS:findFiles/removeFile unavailable')
    return
  end
  local okList, files = pcall(function ()
    return FS:findFiles(M.RESULTS_LOCAL_DIR, '*.txt', 0, false, false)
  end)
  if not okList or type(files) ~= 'table' then
    pushNotice('session', 'Could not read your results folder')
    log('W', 'raceManager', 'clearLocalResults: findFiles failed: ' .. tostring(files))
    return
  end
  -- pairs and a counter: the list from C is not promised to be hole-free, and
  -- ipairs would stop at a hole and leave files behind.
  local found, removed = 0, 0
  for _, path in pairs(files) do
    found = found + 1
    if pcall(function () FS:removeFile(path) end) then removed = removed + 1 end
  end
  log('I', 'raceManager', 'Local results cleared: ' .. removed .. ' of ' .. found .. ' file(s)')
  -- Counted, not assumed.
  if found == 0 then
    pushNotice('session', 'You had no saved results copies to clear')
  elseif removed == found then
    pushNotice('session', 'Your results copies cleared: ' .. removed
      .. ' file' .. (removed == 1 and '' or 's') .. ' removed from this PC')
  else
    pushNotice('session', 'Cleared ' .. removed .. ' of ' .. found
      .. ' results copies: the rest could not be deleted')
  end
end

-- The server's results folder is SHOWN, not opened: exploreFolder fails
-- internally (no raise) for a path outside the virtual filesystem.
function M.openResultsFolder(path)
  path = tostring(path or '')
  if path == '' then
    pushNotice('session', 'The server did not report where its results are kept')
    return
  end
  log('I', 'raceManager', 'Results folder: ' .. path)
  pushNotice('session', 'Results are on the server at: ' .. path)
end

function M.clearGarage()
  if inMultiplayer() then TriggerServerEvent('RM_ClearGarage', '') end
end

function M.removeGarageEntry(index)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_RemoveGarageEntry', jsonEncode({ index = index }))
  end
end

function M.setGarageEnforce(enabled)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetGarageEnforce', jsonEncode({ enabled = enabled and true or false }))
  end
end

-- Which half of the signature the server matches on: 'parts' (tuning and paint
-- free) or 'strict' (parts plus tuning).
function M.setGarageMode(mode)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetGarageMode', jsonEncode({ mode = tostring(mode or '') }))
  end
end

-- An entry's class. Empty clears it.
function M.setGarageClass(index, class)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetGarageClass', jsonEncode({
      index = math.floor(tonumber(index) or 0),
      class = tostring(class or ''),
    }))
  end
end

-- The Garage List, sent on its own when it changes.
function M.onGarage(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  if not fromCurrentServer(data) then return end
  guihooks.trigger('RaceManagerGarage', data)
end

-- A Garage List entry's display name. Empty shows the captured label again.
-- `was` is the name on screen, so the server can refuse if the list moved.
function M.setGarageName(index, name, was)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetGarageName', jsonEncode({
      index = math.floor(tonumber(index) or 0),
      name = tostring(name or ''), was = tostring(was or ''),
    }))
  end
end

-- TAKE A CAR OFF THE GARAGE LIST (anyone may). Asked for by index; the server
-- sends the car back on RM_GarageCar. The parts never ride the state broadcast,
-- which carries the list three times a second.
function M.takeGarageCar(index, replace)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if not inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'The Garage List needs a BeamMP server' })
    return
  end
  if not (core_vehicles and core_vehicles.replaceVehicle and core_vehicles.spawnNewVehicle) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'This game build cannot spawn a vehicle' })
    return
  end
  -- Swap or add is a local question, so it is remembered rather than sent.
  garage.takeReplace = (replace == true or replace == 1)
  TriggerServerEvent('RM_TakeGarageCar', jsonEncode({ index = index }))
end

-- The server's answer: one entry with its car. `cfg` (parts and tuning) builds
-- it anywhere; `pc` is the fallback for older entries and spawns the model
-- default on a machine without the file.
local function onGarageCar(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  if not fromCurrentServer(data) then return end
  if type(data.message) == 'string' and data.message ~= '' then
    guihooks.trigger('RaceManagerEditorMsg', { msg = data.message })
    return
  end
  local model = tostring(data.model or '')
  if model == '' then return end

  -- Encoded or already decoded, depending on the BeamMP build.
  local config, fromParts = nil, false
  local raw = data.cfg
  if type(raw) == 'string' and raw ~= '' then
    local okC, decoded = pcall(jsonDecode, raw)
    raw = okC and decoded or nil
  end
  if type(raw) == 'table' and type(raw.parts) == 'table' then
    config, fromParts = raw, true
  end
  if not config and type(data.pc) == 'string' and data.pc ~= '' then
    config = data.pc
  end
  if not config then
    guihooks.trigger('RaceManagerEditorMsg',
      { msg = 'That garage entry has no configuration to spawn' })
    return
  end

  -- THE PAINT GOES IN THE OPTIONS: spawn.setVehicleObject reads options.paint,
  -- paint2 and paint3 and never the config's paints.
  local opts = { config = config }
  if type(config) == 'table' and type(config.paints) == 'table' then
    opts.paint  = config.paints[1]
    opts.paint2 = config.paints[2]
    opts.paint3 = config.paints[3]
  end
  local replace = garage.takeReplace == true
  local spawned, err = pcall(function ()
    if replace then
      core_vehicles.replaceVehicle(model, opts)
    else
      core_vehicles.spawnNewVehicle(model, opts)
    end
  end)
  if not spawned then
    log('E', 'raceManager', 'Could not take garage car ' .. model .. ': ' .. tostring(err))
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'The game refused that spawn' })
    return
  end
  log('I', 'raceManager', (replace and 'Replaced with ' or 'Spawned ') .. model
    .. ' from ' .. (fromParts and 'its stored parts' or ('the saved file ' .. tostring(config))))
  if not fromParts then
    -- A missing file spawns a stock car, which looks like the wrong car.
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'That entry predates stored parts: '
      .. 'if this is not the right car, an admin should re-capture it' })
  end
  garage.unstickUi()
  -- The new car re-declares itself through the config poll.
end

-- A GAMEPAD THAT ONLY HAS PEDALS. Joining a server, the UI router's "play"
-- transition can time out (route_mounted_not_acknowledged), leaving UINav with
-- the pad: only the triggers reach the car. The vehicle selector ends with
-- navigate("play"), which fixes it; a garage spawn does the same, but only when
-- the router is stuck, since navigating a healthy UI bounces what is open.
function garage.unstickUi()
  if not garage.uiPlayStuck then return end
  local router = extensions and extensions.ui_router
  if not (router and router.navigate) then return end
  garage.uiPlayStuck = false
  local ok = pcall(router.navigate, 'play')
  log('I', 'raceManager', 'UI was stuck short of "play" after joining; re-entered it'
    .. (ok and '' or ' (navigate threw)'))
end

-- Router hooks. A timed-out "play" marks the UI stuck; any transition that
-- commits afterwards means it is not. The commit hook fires before the mount
-- ack, so the timeout that follows it still lands last and wins.
function M.routeChangeCancelled(payload)
  local to = type(payload) == 'table' and payload.toRoute
  if type(to) == 'table' and to.name == 'play'
     and payload.reason ~= 'navigation_replaced' then
    garage.uiPlayStuck = true
  end
end

function M.onAfterRouteChange()
  garage.uiPlayStuck = false
end

-- Named garage sets: one click restores a series' approved list. The server
-- owns the naming rules.
function M.saveGarageSet(name)
  if inMultiplayer() then
    TriggerServerEvent('RM_SaveGarageSet', jsonEncode({ name = tostring(name or '') }))
  end
end

-- `append` MERGES the set into the list (a multi-class night). The server owns
-- matching modes, duplicates and the cap.
function M.loadGarageSet(name, append)
  if inMultiplayer() then
    TriggerServerEvent('RM_LoadGarageSet', jsonEncode({
      name = tostring(name or ''), append = append == true,
    }))
  end
end

function M.deleteGarageSet(name)
  if inMultiplayer() then
    TriggerServerEvent('RM_DeleteGarageSet', jsonEncode({ name = tostring(name or '') }))
  end
end

-- The server ordered this client to drop a refused car. The server cannot:
-- MP.RemoveVehicle wants BeamMP's own vehicle id, not veh:getID(). Not
-- removeLocalVehicle(), which would respawn the car at session end.
local function deleteOwnVehicleNow()
  local veh = ownVehicle()
  if not veh then return false end
  local attached = playerVehicle()
  -- removeCurrent deletes the ATTACHED car, so only once it is known to be ours.
  if core_vehicles and core_vehicles.removeCurrent
      and attached and vehicleId(attached) == vehicleId(veh) then
    if pcall(core_vehicles.removeCurrent) then return true end
  end
  return pcall(function () veh:delete() end)
end

-- ===========================================================================
-- Vehicle reset control & forced spectating (Module 1)
-- ===========================================================================
-- The reset allowance is the server's rule but only the client sees a reset.
-- Past the allowance a reset is BLOCKED by putting the car straight back.

-- The car removed by removeLocalVehicle, to put back at session end.
local removedVehicle = nil   -- { model, config, pos, rot }

-- Everything needed to put this exact car back.
local function captureVehicleSnapshot()
  local veh = ownVehicle()
  if not veh then return nil end
  local snap = {}
  pcall(function () snap.model = tostring(veh:getJBeamFilename()) end)
  pcall(function ()
    local pos = veh:getPosition()
    snap.pos = vec3(pos.x, pos.y, pos.z)
  end)
  pcall(function ()
    local rot = veh:getRotation()
    snap.rot = quat(rot.x, rot.y, rot.z, rot.w)
  end)
  if core_vehicle_partmgmt and core_vehicle_partmgmt.getConfig then
    local ok, cfg = pcall(core_vehicle_partmgmt.getConfig)
    if ok and type(cfg) == 'table' then snap.config = cfg end
  end
  -- The grid slot, recorded now: the 'finished' phase clears gridSlot before
  -- the release, and the respawn would otherwise land the field on the line.
  snap.slot = session.gridSlot
  if not snap.model then return nil end
  return snap
end

-- DELIBERATELY UNREACHABLE, AND DELIBERATELY KEPT. Finishing a race ghosts the
-- car in place now, so nothing sets `removedVehicle`; releaseSpectator guards
-- the respawn branch on it, so the subsystem is inert. It is the way back if
-- ghosting (obj:setGhostEnabled) is ever lost to a game update. Never for a
-- derby: deleting in BeamMP deletes the car for every client.
local function removeLocalVehicle()
  local veh = ownVehicle()
  if not veh then return end
  removedVehicle = captureVehicleSnapshot() or removedVehicle
  local attached = playerVehicle()
  if core_vehicles and core_vehicles.removeCurrent
      and attached and vehicleId(attached) == vehicleId(veh) then
    if pcall(core_vehicles.removeCurrent) then return end
  end
  pcall(function () veh:delete() end)
end

-- Put this client back on its OWN car (after a placement the game picks one
-- arbitrarily). Switches the vehicle, never the camera mode.
local function bindCameraToOwnVehicle()
  local veh = ownVehicle()
  if not veh then return false end
  local bound = false
  if be and be.enterVehicle then
    bound = pcall(function () be:enterVehicle(0, veh) end)
  end
  log('I', 'raceManager', 'Attached to own vehicle ' .. tostring(vehicleId(veh))
    .. (bound and '' or ' (enterVehicle unavailable)'))
  return true
end

-- Forward declarations: the respawn needs both, defined with the placement code.
local headingRot
local placeOnStartPosition

local function respawnRemovedVehicle()
  local snap = removedVehicle
  if not snap or not snap.model then return false end
  -- OWN car, not the attached one, which may be a rival's.
  if ownVehicle() then
    removedVehicle = nil
    return false
  end
  removedVehicle = nil
  local opts = { config = snap.config }
  if snap.pos then opts.pos = snap.pos end
  if snap.rot then opts.rot = snap.rot end
  -- SPAWN ON A GRID SLOT: cars removed at the line respawned interpenetrated and
  -- welded. Our slot, then any slot, then the snapshot. Position only:
  -- headingRot's half-turn is right for setPositionRotation and wrong for
  -- spawnNewVehicle, so placeOnStartPosition turns it afterwards.
  local slot = snap.slot or session.gridSlot
  local sp = slot and track.startPositions[slot]
  if not (type(sp) == 'table' and sp.x) then sp = track.startPositions[1] end
  if type(sp) == 'table' and sp.x and sp.y and sp.z then
    opts.pos = vec3(sp.x, sp.y, sp.z)
    opts.rot = nil          -- set below, by the call that knows the convention
    log('I', 'raceManager', 'Respawning on grid slot ' .. tostring(slot or 1)
      .. ' rather than where the car was removed')
  else
    -- Say so: a car back in the wrong place with nothing logged is undiagnosable.
    log('W', 'raceManager', 'Respawning where the car was removed: no start '
      .. 'position to use (slot=' .. tostring(slot) .. ', grid has '
      .. tostring(#track.startPositions) .. ' placed)')
  end
  local spawned = false
  if core_vehicles and core_vehicles.spawnNewVehicle then
    spawned = pcall(core_vehicles.spawnNewVehicle, snap.model, opts)
  end
  if not spawned and core_vehicles and core_vehicles.replaceVehicle then
    spawned = pcall(core_vehicles.replaceVehicle, snap.model, opts)
  end
  if spawned then
    -- Not placed here: the spawn is asynchronous and the car does not exist yet.
    -- The placement scheduler places it after a grace (releaseSpectator).
    log('I', 'raceManager', 'Respawned ' .. tostring(snap.model) .. ' after the session ended')
  else
    -- Keep the snapshot for another attempt: it is the only record of the car.
    removedVehicle = snap
    log('W', 'raceManager', 'Could not respawn ' .. tostring(snap.model)
      .. ' automatically: spawn a vehicle manually')
  end
  return spawned
end



-- ---------------------------------------------------------------------------
-- Being out of a session: freeze the INPUT, never the existence
-- ---------------------------------------------------------------------------
-- The car stays where it is and only DRIVING it is blocked: deleting it removed
-- it for every BeamMP client, and respawning a field welded cars together. The
-- camera is the driver's own.
local spectate = {
  -- Every input that drives a car, NOT the vehicle-switch actions: tabbing
  -- between cars is the point of spectating.
  DRIVE = {
    'accelerate', 'brake', 'throttle', 'steering', 'steer_left', 'steer_right',
    'parkingbrake', 'parkingbrake_toggle', 'clutch',
    'shiftUp', 'shiftDown', 'shiftToggle', 'toggleGearboxMode',
    'nitrousOxideActive', 'toggleWalkingMode',
  },
  blocked = false,
  -- What a derby wreck is set to (see releaseControls): zero across the board,
  -- handbrake and steering included, so survivors can shove it straight.
  NEUTRAL = {
    'throttle', 'brake', 'steering', 'clutch', 'parkingbrake',
    'nitrousOxideActive',
  },
  -- What makes a car go, filtered only while a derby stands its cars down. A
  -- single input.event cannot beat a pedal still held down; the filter can.
  -- Brakes and steering are absent: a blocked input LATCHES its value, and the
  -- stand-down has already applied full brake.
  PROPULSION = {
    'accelerate', 'throttle', 'nitrousOxideActive',
  },
  propulsionBlocked = false,
  -- Guarded down to the function: a trailer has no mainController, and the
  -- error would surface in the vehicle VM where our pcall cannot see it.
  IGNITION_OFF = 'if controller and controller.mainController '
    .. 'and controller.mainController.setEngineIgnition then '
    .. 'controller.mainController.setEngineIgnition(false) end',
  IGNITION_ON  = 'if controller and controller.mainController '
    .. 'and controller.mainController.setEngineIgnition then '
    .. 'controller.mainController.setEngineIgnition(true) end',
  -- Only an ignition we cut is ours to put back.
  engineCut = false,
  -- The node grabber and funStuff (fire, explosions, flings) decide a derby,
  -- so they are off for its length. These are the game's own names from
  -- actionFilter's actionTemplates: a wrong name blocks nothing, silently.
  GRAB = {
    -- actionTemplates.nodegrabber
    'nodegrabberAction', 'nodegrabberGrab', 'nodegrabberRender',
    'nodegrabberStrength', 'nodegrabberPadGrab', 'nodegrabberPadMode',
    -- actionTemplates.funStuff
    'forceField', 'funBoom', 'funBreak', 'funExtinguish', 'funFire',
    'funHinges', 'funTires', 'funRandomTire', 'latchesOpen', 'latchesClose',
    'funBoost', 'funBoostBackwards', 'funFling', 'funFlingDownward',
  },
  grabBlocked = false,
}

-- Arm or disarm one input-filter group. core_input_actionFilter can be absent
-- or renamed, so every caller does nothing rather than throw. Returns whether
-- the engine took it.
local function setActionGroupBlocked(group, actions, blocked)
  if not (core_input_actionFilter and core_input_actionFilter.setGroup
      and core_input_actionFilter.addAction) then
    return false
  end
  return (pcall(function ()
    core_input_actionFilter.setGroup(group, actions)
    core_input_actionFilter.addAction(0, group, blocked)
  end))
end

function spectate.setGrabberBlocked(blocked)
  blocked = blocked and true or false
  if blocked == spectate.grabBlocked then return end
  if setActionGroupBlocked('raceManagerGrabber', spectate.GRAB, blocked) then
    spectate.grabBlocked = blocked
    log('I', 'raceManager', 'Node grabber ' .. (blocked and 'BLOCKED' or 'released'))
  end
end

-- An eliminated derby driver's driving keys, dead at the source.
function spectate.setInputsBlocked(blocked)
  blocked = blocked and true or false
  if blocked == spectate.blocked then return end
  if setActionGroupBlocked('raceManagerSpectate', spectate.DRIVE, blocked) then
    spectate.blocked = blocked
    log('I', 'raceManager', 'Driving inputs ' .. (blocked and 'BLOCKED' or 'released'))
  end
end

-- HAND THE CAR BACK AS A ROLLING CHASSIS. The filter freezes each input at its
-- value when it armed, so every covered input is zeroed ONCE after it arms.
-- The handbrake is RELEASED and the ignition CUT: a derby wreck is an obstacle
-- that coasts to a stop and can be shoved, solid, never driven.
function spectate.releaseControls()
  -- ownVehicle(): the camera may already be on somebody else's car.
  local veh = ownVehicle()
  if not veh then return false end
  local ok = pcall(function ()
    for _, input in ipairs(spectate.NEUTRAL) do
      veh:queueLuaCommand(('input.event("%s", 0, 1)'):format(input))
    end
    veh:queueLuaCommand(spectate.IGNITION_OFF)
  end)
  -- Remembered, so the release restores only an ignition we cut.
  spectate.engineCut = ok or spectate.engineCut
  log('I', 'raceManager', ok
    and 'Derby elimination: controls neutralised, ignition off, free to roll'
    or  'Derby elimination: could not neutralise controls')
  return ok
end

-- Restore the ignition at release, only if we cut it (race finishers never
-- lose theirs).
function spectate.restoreEngine()
  if not spectate.engineCut then return end
  spectate.engineCut = false
  local veh = ownVehicle()
  if not veh then return end
  pcall(function () veh:queueLuaCommand(spectate.IGNITION_ON) end)
  log('I', 'raceManager', 'Spectator released: ignition restored')
end

-- Put the camera on a MOVING car that is not ours, once, by switching vehicle
-- (not camera mode). After that the target is the driver's.
function spectate.attachToRunner()
  if type(getAllVehicles) ~= 'function' or not (be and be.enterVehicle) then return false end
  local ok, list = pcall(getAllVehicles)
  if not ok or type(list) ~= 'table' then return false end
  local best, bestSpeed = nil, 0.5      -- m/s; below this a car is parked
  for _, v in ipairs(list) do
    -- Never a trailer: it moves exactly as fast as the car towing it.
    if v and not isOwnVehicle(vehicleId(v)) and not towed.is(v) then
      local moving = 0
      pcall(function ()
        local vel = v:getVelocity()
        if vel then moving = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z) end
      end)
      if moving > bestSpeed then best, bestSpeed = v, moving end
    end
  end
  -- Nothing moving: stay put rather than flick between parked cars.
  if not best then return false end
  local switched = pcall(function () be:enterVehicle(0, best) end)
  log('I', 'raceManager', switched
    and ('Spectating a moving car (%.0f m/s)'):format(bestSpeed)
    or 'Could not switch to a moving car')
  return switched
end

local function enterSpectator(reason, source)
  session.spectatorLock   = source or 'race'
  spectatorReason = reason or 'You are out of this session'
  -- DRIVING IS BLOCKED FOR A DERBY AND KEPT FOR A RACE. A finisher is a ghost
  -- that is no longer scored, so driving their car cannot affect the race.
  spectate.setInputsBlocked(session.spectatorLock == 'derby')
  if session.spectatorLock == 'derby' then
    -- Eliminated in a derby: the wreck stays where it is, driver in it. After
    -- the filter, never before, or a held pedal puts the value straight back.
    spectate.releaseControls()
    log('I', 'raceManager', 'Derby elimination: the wreck stays in the arena')
  else
    -- Finished or out of a race: the car STAYS and is ghosted (ghost.setFinished),
    -- instead of a delete and respawn burst per driver as the field finishes.
    ghost.setFinished(true)
  end
  guihooks.trigger('RaceManagerSpectator', {
    spectating = true, reason = spectatorReason, source = session.spectatorLock,
  })
  pushNotice('spectate', spectatorReason)
  pushRouteState()
  log('I', 'raceManager', 'Spectator mode (' .. tostring(session.spectatorLock)
    .. '): ' .. tostring(spectatorReason))
end

-- Only the source that imposed the lock can lift it, so a derby can never hand
-- a race DNF their car back. A respawn (retained path only) is QUEUED, so a
-- whole field is not spawned on one tick. Forward-declared below.
local queueFieldPlacement

local function releaseSpectator(source, order, count)
  if not session.spectatorLock then return end
  if source and source ~= session.spectatorLock then return end
  session.spectatorLock   = nil
  spectatorReason = nil
  -- Driving first, and the ignition with it.
  spectate.setInputsBlocked(false)
  spectate.restoreEngine()
  -- The finished ghost comes off, here and on everyone else's car.
  ghost.setFinished(false)
  -- NOTHING IS RESPAWNED AND NOTHING IS PLACED: the car was never removed, so
  -- the driver is released where they are. The branch below only runs for a
  -- snapshot left by the retained removal path.
  if removedVehicle then
    local slot = nil
    if source ~= 'derby' then
      slot = removedVehicle.slot or session.gridSlot or (track.startPositions[1] and 1 or nil)
    end
    if queueFieldPlacement then
      queueFieldPlacement({ respawn = true, slot = slot, order = order, count = count })
    else
      respawnRemovedVehicle()
      bindCameraToOwnVehicle()
    end
  end
  guihooks.trigger('RaceManagerSpectator', { spectating = false })
  pushRouteState()
  log('I', 'raceManager', 'Spectator mode released (' .. tostring(source or 'any')
    .. ', order ' .. tostring(order or 1) .. '/' .. tostring(count or 1) .. ')')
end

-- NOTHING RE-ASSERTS THE CAMERA: forcing freecam made spectating impossible.
-- The watched car is followed, and only its ceasing to EXIST (gone, not parked)
-- triggers a re-acquire.
local function spectatorUpdate(dt)
  if not session.spectatorLock then
    spectate.target = nil
    return
  end
  spectate.recheck = (spectate.recheck or 0) - dt
  if spectate.recheck > 0 then return end
  spectate.recheck = 0.25

  local now = playerVehicle()
  local id  = now and vehicleId(now) or nil
  -- Still on something the driver chose: record it. The common branch.
  if id and getObjectByID and getObjectByID(id) then
    spectate.target = id
    return
  end
  -- The watched car is gone: advance once to the next moving car. No guard on a
  -- recorded target: in a bunched finish the car is removed before one tick runs.
  if spectate.attachToRunner() then
    local v = playerVehicle()
    spectate.target = v and vehicleId(v) or nil
    log('I', 'raceManager', 'Spectate target gone: moved to the next moving car')
  end
end

-- The reset allowance applies in any live session and its countdown.
local function resetsEnforced()
  return session.maxResets >= 0 and (sessionRunning() or session.phase == 'countdown')
end

-- Derby reset state, ONE TABLE shared with the derby module, so neither side
-- reads a copy. `active` is filled in by the module.
local derbyResets = { max = -1, used = 0, active = function () return false end }
-- "Is a derby standing its cars down?" Assigned by the derby module; read by
-- the reset-input block, which would otherwise undo it a frame later.
spectate.derbyStoodDown = function () return false end

-- NO RESETS AT ALL WHILE A DERBY IS RUNNING: a reset repairs the car, which
-- undoes a derby. Being wrecked is final.
local function derbyResetsEnforced()
  return derbyResets.active()
end

-- Reset/recover keys off via the input action filter; older builds fall back to
-- the restore in onVehicleResetted.
local function setResetInputsBlocked(blocked)
  blocked = blocked and true or false
  if blocked == block.resetInputs then return end
  if setActionGroupBlocked('raceManagerResets', block.RESET_ACTIONS, blocked) then
    block.resetInputs = blocked
    log('I', 'raceManager', 'Reset inputs ' .. (blocked and 'BLOCKED' or 'released'))
  end
end

-- Kill propulsion while a derby stands its cars down. NOT for a grid hold: see
-- below.
function spectate.setPropulsionBlocked(blocked)
  blocked = blocked and true or false
  if blocked == spectate.propulsionBlocked then return end
  if setActionGroupBlocked('raceManagerPropulsion', spectate.PROPULSION, blocked) then
    spectate.propulsionBlocked = blocked
    log('I', 'raceManager', 'Propulsion ' .. (blocked and 'BLOCKED' or 'released'))
  end
end

-- Driving inputs are NOT filtered while a car is held: setFreeze leaves the
-- drivetrain live so drivers can rev and pick a gear before the lights.
-- Teleports get their own filter group: blocked for the whole session, even
-- for a driver with resets to spare.
local function setTeleportInputsBlocked(blocked)
  blocked = blocked and true or false
  if blocked == block.teleportInputs then return end
  if setActionGroupBlocked('raceManagerTeleport', block.TELEPORT_ACTIONS, blocked) then
    block.teleportInputs = blocked
    log('I', 'raceManager', 'Teleport inputs ' .. (blocked and 'BLOCKED' or 'released'))
  end
end

local function resetInputBlockUpdate()
  -- Teleports off for the whole session; a driver OUT of it keeps them.
  setTeleportInputsBlocked(sessionRunning() and not session.spectatorLock)
  local wantBlocked = not session.spectatorLock
    and ((resetsEnforced() and session.resetsUsed >= session.maxResets)
      or (derbyResetsEnforced() and derbyResets.used >= derbyResets.max))
  -- ...and while a derby stands its cars down: a reset would reload the car out
  -- from under the freeze.
  setResetInputsBlocked(wantBlocked or spectate.derbyStoodDown())
  -- Recomputed every frame, so a missed broadcast cannot leave it armed. Covers
  -- a derby WRECK too: one put out for leaving the arena may still have a pedal
  -- held, and only the filter beats a held pedal.
  spectate.setPropulsionBlocked(spectate.derbyStoodDown()
    or session.spectatorLock == 'derby')
end

-- Rolling "last good position", for the whole of a live session: the recovery
-- undo needs it even with unlimited resets.
local function snapshotUpdate(dt)
  local wanted = resetsEnforced() or derbyResetsEnforced() or sessionRunning()
  if not wanted or session.spectatorLock or session.gridFrozen then return end
  snapshot.left = snapshot.left - dt
  if snapshot.left > 0 then return end
  snapshot.left = snapshot.EVERY
  -- OUR car: a reset refusal teleports to this sample.
  local veh = ownVehicle()
  if not veh then return end
  local ok = pcall(function ()
    local pos = veh:getPosition()
    local rot = veh:getRotation()
    snapshot.pos = vec3(pos.x, pos.y, pos.z)
    snapshot.rot = quat(rot.x, rot.y, rot.z, rot.w)
  end)
  if not ok then snapshot.pos, snapshot.rot = nil, nil end
end

-- Remember a teleport this mod just performed, so the vehicle-reset hook it
-- provokes can be recognized as our own doing rather than a driver reset.
local function noteSelfTeleport(x, y, z)
  block.selfTeleport.left = block.TELEPORT_WINDOW
  block.selfTeleport.x, block.selfTeleport.y, block.selfTeleport.z = x, y, z
  -- Whether a trailer was coupled, recorded BEFORE the car moves: a teleport
  -- uncouples it, and by the echo there is nothing left to ask. Inline for the
  -- locals ceiling. attachedCouplers pairs are { vehA, vehB, nodeA, nodeB }.
  block.selfTeleport.hadRig = false
  local veh = ownVehicle()
  if veh then
    local id = vehicleId(veh)
    pcall(function ()
      if not (core_vehicles and type(core_vehicles.attachedCouplers) == 'table') then return end
      for _, pair in ipairs(core_vehicles.attachedCouplers) do
        if pair[1] == id or pair[2] == id then
          block.selfTeleport.hadRig = true; return
        end
      end
    end)
  end
end

-- True when the reset just reported is our own teleport's echo: inside the
-- window AND the car is where we put it (so a driver reset right after a block
-- is still caught). Since v0.39 the echo can lag a frame or two, so the radius
-- grows with the car's speed times the time elapsed.
local function isSelfTeleportEcho()
  if block.selfTeleport.left <= 0 then return false end
  -- OUR car, not the watched one.
  local veh = ownVehicle()
  if not veh then return false end
  local elapsed = block.TELEPORT_WINDOW - block.selfTeleport.left
  if elapsed < 0 then elapsed = 0 end
  local ok, near = pcall(function ()
    local p = veh:getPosition()
    local st = block.selfTeleport
    local dx, dy, dz = p.x - st.x, p.y - st.y, p.z - st.z
    local v = veh:getVelocity()
    local speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    local allowed = block.TELEPORT_RADIUS + speed * elapsed
    return (dx * dx + dy * dy + dz * dz) <= allowed * allowed
  end)
  return ok and near == true
end

-- Is this car standing IN the stall? A box on the stall's own axes, not a
-- crossing: clipping a stall at speed must not trigger a stop.
function pit.inside(wp, pos)
  local _, h, d = gateDims(wp)
  local w, len = pit.dims(wp)
  local dx, dy, dz = pos.x - wp.x, pos.y - wp.y, pos.z - wp.z
  local fx, fy = wp.hx or 0, wp.hy or 1
  local lat = dx * fy - dy * fx          -- across the stall
  local fwd = dx * fx + dy * fy          -- along it
  return math.abs(lat) <= w * 0.5
     and math.abs(fwd) <= len * 0.5
     and dz <= h and dz >= -d
end

-- A stall's clamped footprint (its own fields, never a gate width). The
-- renderer reads this too, so what is drawn is what is tested.
function pit.dims(wp)
  local w = tonumber(wp.width) or TUNE.PIT_BOX_WIDTH
  local l = tonumber(wp.length) or TUNE.PIT_BOX_LENGTH
  if w < TUNE.PIT_BOX_MIN_W then w = TUNE.PIT_BOX_MIN_W elseif w > TUNE.PIT_BOX_MAX_W then w = TUNE.PIT_BOX_MAX_W end
  if l < TUNE.PIT_BOX_MIN_L then l = TUNE.PIT_BOX_MIN_L elseif l > TUNE.PIT_BOX_MAX_L then l = TUNE.PIT_BOX_MAX_L end
  return w, l
end

-- A new stall takes the size of the one it follows, like a gate does; the
-- first takes the default. Overwrites the checkpoint width editorAdd gave it.
function pit.sizeFrom(place, prev)
  place.width, place.length = pit.dims(prev or {})
end

-- Ghosted for the stop: a frozen car in a stall cannot get out of the way.
-- Gated on the SERVER's reset-ghost switch so every client agrees (a ghost only
-- to its own driver is worse than none); broadcast for the stop's length.
function pit.setGhost(on)
  if on then
    if pit.ghostVeh then return end
    if not ghost.rules.onReset then return end   -- server has ghosting off
    -- The server ignores a ghost outside a session: it would be ours alone.
    if not sessionRunning() then return end
    local veh = ownVehicle()
    local vehId = veh and vehicleId(veh) or nil
    if not vehId then return end
    pit.ghostVeh = vehId
    -- reasonRig: a trailer on the hitch is part of the car.
    ghost.reasonRig(vehId, 'pit', true, veh)
    -- Only broadcast if no RESET ghost is running: they share one ghost per
    -- player on the server, and a 5 s pit ghost would cut a 15 s one short.
    pit.ghostSent = inMultiplayer() and ghost.own.vehId == nil
    if pit.ghostSent then
      TriggerServerEvent('RM_GhostStart', jsonEncode({ duration = TUNE.PIT_HOLD_SEC }))
    end
    log('I', 'raceManager', string.format('Pit ghost on for vehicle %s (%.1fs)%s',
      tostring(vehId), TUNE.PIT_HOLD_SEC,
      pit.ghostSent and '' or ' (local only: a reset ghost already owns the broadcast)'))
  else
    local vehId = pit.ghostVeh
    if not vehId then return end
    pit.ghostVeh = nil
    ghost.reasonRig(vehId, 'pit', false)
    -- Only end what we started.
    if pit.ghostSent and inMultiplayer() and ghost.own.vehId == nil then
      TriggerServerEvent('RM_GhostEnd', '')
    end
    pit.ghostSent = false
  end
end

-- OUT OF THE LANE, by the exit gate or by clearing any route checkpoint (a
-- driver who missed the exit must not carry the stalls to the flag).
function pit.leaveLane(reason)
  if not pit.inLane then return end
  pit.inLane = false
  log('I', 'raceManager', 'Left the pit lane (' .. tostring(reason or 'exit') .. ')')
  pushRouteState()
end

function pit.release(reason)
  if not pit.active then return end
  pit.active   = false
  pit.left     = 0
  pit.settleLeft = 0
  pit.cooldown = TUNE.PIT_COOLDOWN
  -- It may not stop in this box again until it has driven out of it.
  pit.mustLeave = true
  pit.setGhost(false)
  setLocalVehicleFrozen(false)
  pushRouteState()
  log('I', 'raceManager', 'Pit stop ended (' .. tostring(reason or 'complete') .. ')')
end

-- Stalls work in a session and in practice. Practice is local: no ghost, no report.
function pit.live()
  if session.spectatorLock then return false end
  return sessionRunning() or practice.on
end

-- The pit stop: hold, repair in place, hand back. Never a respawn anchor.
function pit.update(dt)
  if pit.cooldown > 0 then pit.cooldown = pit.cooldown - dt end

  -- A stop cannot outlive its session or its practice.
  if pit.active and not pit.live() then
    pit.release('session or practice ended')
    return
  end

  if pit.active then
    pit.left = pit.left - dt
    -- The hold is only a clock; the service happened on entry. recoverInPlace
    -- reloads the vehicle VM, which drops the freeze and the ghost, so both are
    -- re-asserted until the car settles rather than once at a guessed moment.
    if pit.settleLeft > 0 then
      pit.settleLeft = pit.settleLeft - dt
      local veh = ownVehicle()
      if veh then
        setLocalVehicleFrozen(true, 'pit')
        if pit.ghostVeh then ghost.apply(pit.ghostVeh, veh, true, TUNE.GHOST_ALPHA) end
        -- And the echo window: the reload's reset hook can land several frames
        -- later under load and must not be charged as a driver reset.
        local ok, p2 = pcall(function () return veh:getPosition() end)
        if ok and p2 then noteSelfTeleport(p2.x, p2.y, p2.z) end
      end
    end
    if pit.left <= 0 then
      pit.release('complete')
      pushNotice('pit', 'GO!')
    end
    return
  end

  if pit.promptLeft > 0 then pit.promptLeft = pit.promptLeft - dt end

  if #track.pitRoute == 0 then return end
  if not pit.live() or session.gridFrozen then return end
  local veh, pos = sampledVehicle()
  if not veh or not pos then return end

  -- The lane's mouth and exit: crossing an entry gate puts the stalls on
  -- screen. ITS OWN previous position: checkGates has already set
  -- session.prevPos to this frame's sample, so that segment has zero length.
  local prev = pit.prevPos
  if prev then
    for _, wp in ipairs(track.pitEntry) do
      if segmentCrossesGate(wp, prev, pos) then
        if not pit.inLane then
          pit.inLane = true
          log('I', 'raceManager', 'Entered the pit lane')
          pushRouteState()
        end
        break
      end
    end
    if pit.inLane then
      for _, wp in ipairs(track.pitExit) do
        if segmentCrossesGate(wp, prev, pos) then
          pit.leaveLane('exit gate')
          break
        end
      end
    end
    -- In place, after the tests: a steady frame allocates nothing.
    prev.x, prev.y, prev.z = pos.x, pos.y, pos.z
  else
    pit.prevPos = { x = pos.x, y = pos.y, z = pos.z }
  end

  -- Which stall, worked out before the cooldown so driving out re-arms it.
  local inStall = nil
  for i, wp in ipairs(track.pitRoute) do
    if pit.inside(wp, pos) then inStall = i; break end
  end
  if not inStall then
    pit.mustLeave = false
    return
  end
  if pit.mustLeave or pit.cooldown > 0 then return end

  -- The car must be STOPPED in the stall: a driver performs a stop. Running
  -- through costs the lap and nothing else.
  local ok, speed = pcall(function ()
    local v = veh:getVelocity()
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  end)
  if not ok or not speed then return end

  if speed > TUNE.PIT_STOP_SPEED then
    -- In the box and still rolling: prompt, throttled.
    if pit.promptLeft <= 0 then
      pit.promptLeft = TUNE.PIT_PROMPT_EVERY
      pushNotice('pit', 'PIT STALL: come to a stop inside the box')
    end
    return
  end
  pit.active   = true
  pit.left     = TUNE.PIT_HOLD_SEC
  pit.stops    = pit.stops + 1
  pit.promptLeft = 0
  pit.settleLeft = TUNE.PIT_SETTLE_SEC
  -- SERVICE THE CAR, ONCE, ON ENTRY: straighten it on the stall, repair, freeze,
  -- ghost. Straight BEFORE repaired, because recoverInPlace repairs where the car
  -- is; cars arrive sideways. Noted as our own teleport first, or the reset hook
  -- charges an allowance.
  local stallWp = track.pitRoute[inStall]
  if stallWp then
    local wp = stallWp
    -- The car's own height: it is already on the stall's surface. (groundAt is
    -- declared below and would be a nil global here.)
    local okPlace = pcall(function ()
      noteSelfTeleport(wp.x, wp.y, pos.z)
      local r = headingRot(wp.hx or 0, wp.hy or 1)
      veh:setPositionRotation(wp.x, wp.y, pos.z, r.x, r.y, r.z, r.w)
    end)
    if not okPlace then
      log('W', 'raceManager', 'Pit stall: could not straighten the car, leaving it as it landed')
    end
  end
  -- The repair reports as a vehicle reset; noteSelfTeleport above covers it.
  pcall(function () veh:queueLuaCommand('recovery.recoverInPlace()') end)
  setLocalVehicleFrozen(true, 'pit')
  pit.setGhost(true)
  pushNotice('pit', string.format('PIT STOP: %.0fs', TUNE.PIT_HOLD_SEC))
  pushRouteState()
  log('I', 'raceManager', string.format(
    'Pit stop %d started in stall %d', pit.stops, inStall))
  if inMultiplayer() and sessionRunning() then
    TriggerServerEvent('RM_PitStop', jsonEncode({ stall = inStall }))
  end
end

-- Age out both reset-side timers.
local function resetGuardUpdate(dt)
  local st = block.selfTeleport
  if st.left           > 0 then st.left           = st.left           - dt end
  if block.noticeLeft  > 0 then block.noticeLeft  = block.noticeLeft  - dt end
end

-- Heading (hx, hy) to a quaternion standing a VEHICLE facing it. Vehicles face
-- -Y at identity, so a half-turn is baked in.
headingRot = function (hx, hy)
  local yaw  = math.atan2(hx, hy) + math.pi
  local half = yaw * 0.5
  return quat(0, 0, math.sin(half), math.cos(half))
end

-- THE GROUND UNDER A POINT, or nil (leave the height alone rather than guess).
-- One probe for grid generation, click placement, drags and reset relocation.
local function groundAt(x, y, z)
  if type(castRayStatic) ~= 'function' then return nil end
  z = tonumber(z) or 0
  -- STRAIGHT DOWN FROM THE POINT first: probing from high above returns the
  -- HIGHEST surface (a bridge deck, a roof, a canopy), and liftAboveGround then
  -- stranded gates in the sky. The epsilon catches a gate resting on the surface.
  local ok, dist = pcall(castRayStatic, vec3(x, y, z + 0.05), vec3(0, 0, -1),
    TUNE.GROUND_PROBE_DOWN)
  if ok and type(dist) == 'number' and dist < TUNE.GROUND_PROBE_DOWN then
    return z + 0.05 - dist
  end
  -- Nothing below: the point is buried. Walk UP in short steps, each ray only
  -- long enough to reach back down, so the LOWEST surface above it wins and a
  -- bridge or roof overhead is never reached.
  for _, up in ipairs(TUNE.GROUND_RESCUE_STEPS) do
    local from = z + up
    ok, dist = pcall(castRayStatic, vec3(x, y, from), vec3(0, 0, -1), up + 0.1)
    if ok and type(dist) == 'number' and dist <= up then
      return from - dist
    end
  end
  return nil
end

-- Lift a point so it clears the ground under it by at least `clear` meters.
-- Points already higher than that are left exactly where they are: this rescues
-- a buried thing without flattening a gate deliberately placed up on a bridge.
local function liftAboveGround(x, y, z, clear)
  local g = groundAt(x, y, z)
  if not g then return z end
  local floor = g + (clear or TUNE.GROUND_CLEAR)
  return (z < floor) and floor or z
end

-- Lower a gate by `step`, never past the ground and never into ground we cannot
-- see: the probe happens BEFORE the move, so no ground means no drop.
local function lowerToGround(x, y, z, step, clear)
  clear = clear or TUNE.GROUND_CLEAR
  local g = groundAt(x, y, z)
  if not g then return z end
  local floor = g + clear
  local want = z - math.abs(step)
  return (want < floor) and floor or want
end

-- Respawn height for `wp` from the road the car drove at the crossing, never
-- the gate's z (a clicked gate can sit ON an arch over the road). nil when
-- unknown. A table field for the locals ceiling.
function snapshot.trackZ(wp)
  local c = snapshot.crossed
  if not wp or c.wp ~= wp or type(castRayStatic) ~= 'function' then return nil end
  local road = groundAt(c.x, c.y, c.z)
  if not road then return nil end
  -- The surface at the gate's center NEAREST the road, both ways: a probe down
  -- would miss a banking crossed low and find the terrain under a mesh track.
  local below, above
  local ok, dist = pcall(castRayStatic, vec3(wp.x, wp.y, road + 0.05),
    vec3(0, 0, -1), TUNE.GROUND_PROBE_DOWN)
  if ok and type(dist) == 'number' and dist < TUNE.GROUND_PROBE_DOWN then
    below = road + 0.05 - dist
  end
  for _, up in ipairs(TUNE.RESPAWN_SEARCH_UP) do
    ok, dist = pcall(castRayStatic, vec3(wp.x, wp.y, road + up), vec3(0, 0, -1), up + 0.1)
    if ok and type(dist) == 'number' and dist <= up then
      above = road + up - dist
      break
    end
  end
  local g = below
  if above and (not g or (above - road) < (road - g)) then g = above end
  if not g then return nil end
  -- At the height the car rode through the gate (a truck is taller), capped.
  local ride = c.z - road
  if ride < TUNE.GROUND_CLEAR then ride = TUNE.GROUND_CLEAR end
  if ride > TUNE.RESPAWN_RIDE_MAX then ride = TUNE.RESPAWN_RIDE_MAX end
  return g + ride
end

-- "Last Checkpoint": stand the car on a gate's center facing the direction of
-- travel, flagged as our own teleport, and make it the last good position.
local function relocateToGate(wp)
  -- ownVehicle(), as every teleport here: moving a rival's car on this client
  -- fights BeamMP's sync and tears the car apart.
  local veh = ownVehicle()
  if not veh or not wp then return false end
  -- Facing the way the car was GOING: a gate driven both ways stores one
  -- heading, and a head-on layout would respawn half the field into the other.
  local hx, hy = wp.hx, wp.hy
  if lastGateBack and wp == lastGate then hx, hy = -hx, -hy end
  local rot = headingRot(hx, hy)
  -- trackZ answers from where the car drove; the lift is the fallback for an
  -- old layout's gate sitting on the surface (a car's origin there is half
  -- underground).
  local z = snapshot.trackZ(wp) or liftAboveGround(wp.x, wp.y, wp.z, TUNE.GROUND_CLEAR)
  noteSelfTeleport(wp.x, wp.y, z)
  local ok = pcall(function ()
    veh:setPositionRotation(wp.x, wp.y, z, rot.x, rot.y, rot.z, rot.w)
  end)
  if ok then
    snapshot.pos = vec3(wp.x, wp.y, z)
    snapshot.rot = rot
  else
    block.selfTeleport.left = 0
  end
  return ok
end

-- Toward the gate along BeamNG's road route, as a unit (x, y), or nil: no road
-- graph, off the road, or no route. A straight line to a gate past a hairpin
-- points backwards; the route goes round it.
function snapshot.pathDir(pos, wp)
  if not (map and type(map.getPointToPointPath) == 'function' and type(map.getMap) == 'function') then
    return nil
  end
  local dx, dy
  pcall(function ()
    local nodes = map.getMap().nodes
    if type(map.findClosestRoad) == 'function' then
      local n1, n2, dist = map.findClosestRoad(vec3(pos.x, pos.y, pos.z), 20)
      local a, b = n1 and nodes[n1], n2 and nodes[n2]
      if not (a and b and dist) then return end
      if dist > math.max(a.radius or 0, b.radius or 0) + TUNE.RESET_ROAD_MARGIN then return end
    end
    local path = map.getPointToPointPath(vec3(pos.x, pos.y, pos.z), vec3(wp.x, wp.y, wp.z))
    if type(path) ~= 'table' or #path < 2 then return end
    -- The node nearest the car among the first few, then the first one past it
    -- far enough to aim at. path[1] can be behind the car.
    local near, nearD = 1, math.huge
    for i = 1, math.min(#path, 4) do
      local n = nodes[path[i]]
      if n then
        local ex, ey = n.pos.x - pos.x, n.pos.y - pos.y
        local e = ex * ex + ey * ey
        if e < nearD then near, nearD = i, e end
      end
    end
    local ahead = TUNE.RESET_PATH_AHEAD * TUNE.RESET_PATH_AHEAD
    for i = near + 1, #path do
      local n = nodes[path[i]]
      if n then
        local ex, ey = n.pos.x - pos.x, n.pos.y - pos.y
        if ex * ex + ey * ey >= ahead then dx, dy = ex, ey; break end
      end
    end
  end)
  if not dx then return nil end
  local d = math.sqrt(dx * dx + dy * dy)
  if d < 1e-6 then return nil end
  return dx / d, dy / d
end

-- KEPT, OFF: the 0.18.5 aim, the road under the car signed by the straight line
-- to the gate (cx, cy). Called from nowhere: on a hairpin the sign flips it
-- backwards. courseDir would call it in place of pathDir if a build loses
-- map.getPointToPointPath but keeps findClosestRoad.
function snapshot.roadTangentDir(pos, cx, cy)
  if not (map and type(map.findClosestRoad) == 'function' and type(map.getMap) == 'function') then
    return nil
  end
  local tx, ty
  pcall(function ()
    local n1, n2, dist = map.findClosestRoad(vec3(pos.x, pos.y, pos.z), 20)
    if not n1 or not n2 or not dist then return end
    local nodes = map.getMap().nodes
    local a, b = nodes[n1], nodes[n2]
    if not a or not b then return end
    if dist > math.max(a.radius or 0, b.radius or 0) + TUNE.RESET_ROAD_MARGIN then return end
    local x, y = b.pos.x - a.pos.x, b.pos.y - a.pos.y
    local l = math.sqrt(x * x + y * y)
    if l < 1e-6 then return end
    x, y = x / l, y / l
    local dot = x * cx + y * cy
    if math.abs(dot) < 0.5 then return end
    if dot < 0 then x, y = -x, -y end
    tx, ty = x, y
  end)
  return tx, ty
end

-- The way to the checkpoint this car must clear next, as a unit (x, y), or nil
-- with no route. Wherever the car is, it points at THAT gate: along the road
-- route where the map has one, else straight at it. Never a road direction
-- flipped to match, which turned cars round on a hairpin.
-- A table field rather than a local: see the locals ceiling note on `block`.
function snapshot.courseDir(pos)
  if #track.route == 0 then return nil end
  local wp = branch.nearestAt(session.armedWp, pos)
  if not wp then return nil end
  local cx, cy = wp.x - pos.x, wp.y - pos.y
  local d = math.sqrt(cx * cx + cy * cy)
  if d < TUNE.RESET_FACE_NEAR then
    -- On top of the gate: its heading, turned to agree with the way in.
    cx, cy = wp.hx or 0, wp.hy or 1
    local from = lastGate ~= wp and lastGate or nil
    if from and cx * (wp.x - from.x) + cy * (wp.y - from.y) < 0 then cx, cy = -cx, -cy end
    d = math.sqrt(cx * cx + cy * cy)
    if d < 1e-6 then return nil end
    return cx / d, cy / d
  end
  local px, py = snapshot.pathDir(pos, wp)
  if px then return px, py end
  return cx / d, cy / d
end

-- Turn the car where it stands to face the course, after an in-place reset.
-- Left alone inside TUNE.RESET_FACE_TOLERANCE. Position is untouched. `at` is
-- where a teleport this frame just put it, which getPosition may not show yet.
function snapshot.faceCourse(veh, at)
  if not veh then return false end
  local pos, fwd, up
  pcall(function ()
    pos = at or veh:getPosition()
    fwd = veh:getDirectionVector()
  end)
  if not pos or not fwd then return false end
  local cx, cy = snapshot.courseDir(pos)
  if not cx then return false end
  local fl = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y)
  if fl > 1e-6
    and (fwd.x * cx + fwd.y * cy) / fl >= math.cos(math.rad(TUNE.RESET_FACE_TOLERANCE)) then
    return false
  end
  -- Keep the car's own up on a slope or banking: yaw alone would level it and
  -- dig a bumper into the hill. Same call BeamNG's recovery uses.
  local rot = nil
  if type(quatFromDir) == 'function' then
    pcall(function ()
      up = veh:getDirectionVectorUp()
      local k = cx * up.x + cy * up.y
      local dx, dy, dz = cx - up.x * k, cy - up.y * k, -up.z * k
      local dl = math.sqrt(dx * dx + dy * dy + dz * dz)
      if dl > 1e-6 then
        rot = quatFromDir(vec3(-dx / dl, -dy / dl, -dz / dl), vec3(up.x, up.y, up.z))
      end
    end)
  end
  rot = rot or headingRot(cx, cy)
  noteSelfTeleport(pos.x, pos.y, pos.z)
  local ok = pcall(function ()
    veh:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  end)
  if ok then
    snapshot.pos = vec3(pos.x, pos.y, pos.z)
    snapshot.rot = rot
    log('I', 'raceManager', 'In-place reset turned to face the course')
  else
    block.selfTeleport.left = 0
  end
  return ok
end

-- Undo a reset the driver was not entitled to: put the car back where it was.
local function restoreLastGoodPosition()
  local veh = ownVehicle()      -- a teleport: see relocateToGate
  if not veh or not snapshot.pos then return false end
  local rot = snapshot.rot or quat(0, 0, 0, 1)
  -- Armed BEFORE the teleport: its hook can arrive on this frame (the old loop).
  noteSelfTeleport(snapshot.pos.x, snapshot.pos.y, snapshot.pos.z)
  local ok = pcall(function ()
    veh:setPositionRotation(snapshot.pos.x, snapshot.pos.y, snapshot.pos.z,
      rot.x, rot.y, rot.z, rot.w)
  end)
  if not ok then block.selfTeleport.left = 0 end
  return ok
end

-- BeamNG hook, for every vehicle: filter to our own first.
function M.onVehicleResetted(vehId)
  -- A reset reloads the VM a practice ghost lives in: put it back at once.
  if vehId ~= nil and vehId == ghost.practiceOwn then
    ghost.practiceCar(vehId, true)
  else
    for _, id in pairs(ghost.practiceRemote) do
      if id == vehId then ghost.practiceCar(vehId, true) break end
    end
  end
  -- Ours only: the attached car may be a rival's.
  if not isOwnVehicle(vehId) then return end
  local veh = ownVehicle()
  if not veh or vehicleId(veh) ~= vehId then return end
  -- Our own teleport's echo: never counted, blocked or reported.
  if isSelfTeleportEcho() then
    -- ...but it reloaded the VM and dropped the freeze: put a wanted hold back
    -- here, the one moment it is known to be lost.
    if holdWanted then
      setLocalVehicleFrozen(true, holdWanted)
      log('I', 'raceManager', 'Hold re-applied after placement reset (' .. tostring(holdWanted) .. ')')
    end
    return
  end
  if session.spectatorLock then
    -- Out of the session: a spectator may recover their car, free. The reset
    -- reloads the VM, so the finished ghost and the input block are re-applied
    -- (forced, since the action set may have been re-registered).
    spectate.setInputsBlocked(false)   -- force the next call to re-apply
    spectate.setInputsBlocked(session.spectatorLock == 'derby')
    if session.spectatorLock ~= 'derby' then ghost.setFinished(true) end
    return
  end

  -- A driver reset on the grid dropped the freeze: back on the slot, pinned,
  -- this frame.
  if holdWanted then
    hold.restore('driver reset while held on the grid')
    pushNotice('grid', 'Reset on the grid: you are back on your slot and held')
    return
  end

  -- Ghost armed HERE, before deciding what the reset was worth: every branch
  -- below (in place, checkpoint, even a blocked restore) can put the car inside
  -- another. Qualifying too: welding is physics, not regulations.
  if ghost.rules.onReset and (session.phase == 'racing' or session.phase == 'qualifying') then
    ghost.arm()
  end

  if resetsEnforced() and session.resetsUsed >= session.maxResets then
    -- Over the allowance. The inputs are already filtered, so this is a path the
    -- filter cannot see: put the car back and tell the server.
    local restored = restoreLastGoodPosition()
    -- A held key fires this repeatedly: the block runs every time, the talk is
    -- throttled.
    if block.noticeLeft <= 0 then
      block.noticeLeft = block.NOTICE_EVERY
      if inMultiplayer() then TriggerServerEvent('RM_ResetDenied', '') end
      -- Said on the refusal, not when the last one is spent: being refused is
      -- what changes the driver's options. Every attempt says it again.
      if session.maxResets == 0 then
        pushNotice('resetsout', 'No resets in this session',
          { sub = 'You are on your own out there', color = 'amber' })
      else
        pushNotice('resetsout', "Uh oh! You're out of resets",
          { sub = 'All ' .. session.maxResets .. ' used', color = 'amber' })
      end
      log('W', 'raceManager', 'Reset blocked: allowance of ' .. session.maxResets
        .. ' exhausted (position ' .. (restored and 'restored' or 'NOT restored') .. ')')
    end
    -- No pushRouteState: a blocked reset changes nothing in it.
    return
  end

  -- Allowed. "Last Checkpoint" moves the car to the last gate crossed (before
  -- the first gate it falls back to in place).
  if session.resetMode == 'checkpoint' and session.phase == 'racing' and lastGate and not session.gridFrozen then
    relocateToGate(lastGate)
  elseif sessionRunning() and not session.gridFrozen then
    -- BOTH RESET KEYS MEAN THE SAME THING: the recovery key's teleport to a
    -- spawn point is undone. Measured against prevPos (snapshot.pos is up to
    -- 0.25 s old: a fast car looks teleported), read DIRECTLY (sampledVehicle
    -- caches the pre-teleport position this frame), and on ownVehicle().
    local was = session.prevPos
    local veh = ownVehicle()
    local pos, undone = nil, nil
    if veh then pcall(function () pos = veh:getPosition() end) end
    if pos and was then
      local dx, dy, dz = pos.x - was.x, pos.y - was.y, pos.z - was.z
      if (dx * dx + dy * dy + dz * dz) > (TUNE.RECOVER_SNAP_RANGE * TUNE.RECOVER_SNAP_RANGE) then
        noteSelfTeleport(was.x, was.y, was.z)
        pcall(function ()
          local rot = veh:getRotation()
          veh:setPositionRotation(was.x, was.y, was.z, rot.x, rot.y, rot.z, rot.w)
        end)
        undone = vec3(was.x, was.y, was.z)
        pushNotice('reset', 'Recovered in place: a race reset does not move you off the track')
        log('I', 'raceManager', 'Undid a recovery teleport during a session')
      end
    end
    -- And facing the course: both keys keep a heading that can be backwards.
    snapshot.faceCourse(veh, undone)
  elseif practice.on and not session.gridFrozen then
    -- Practice resets are free and may go anywhere; they still face the next gate.
    snapshot.faceCourse(ownVehicle())
  end

  -- EVERY legal reset makes the new position the good one, unlimited resets
  -- included, or the next press drags the car back to the first reset. prevPos
  -- is RE-SEEDED, never cleared: a nil leaves the next recovery nothing to undo.
  snapshot.left = 0
  do
    local _, nowPos = sampledVehicle()
    if nowPos then
      -- In place, as checkGates does.
      local pp = session.prevPos
      if pp then
        pp.x, pp.y, pp.z = nowPos.x, nowPos.y, nowPos.z
      else
        session.prevPos = { x = nowPos.x, y = nowPos.y, z = nowPos.z }
      end
    end
  end
  if resetsEnforced() then
    session.resetsUsed = session.resetsUsed + 1
    if inMultiplayer() then TriggerServerEvent('RM_VehicleReset', '') end
    local left = session.maxResets - session.resetsUsed
    -- The last one is still just a tally; "out" is said on the next refusal.
    pushNotice('reset', string.format('Reset %d/%d used: %d left', session.resetsUsed, session.maxResets, left))
    pushRouteState()
    return
  end

  -- Demo derby: no resets at all while one is running and we are in it.
  if derbyResetsEnforced() then
    if true then
      local restored = restoreLastGoodPosition()
      if block.noticeLeft <= 0 then
        block.noticeLeft = block.NOTICE_EVERY
        if inMultiplayer() then TriggerServerEvent('RM_DerbyResetDenied', '') end
        pushNotice('reset', 'RESET BLOCKED: no resets in a derby')
        log('W', 'raceManager', 'Derby reset blocked (position '
          .. (restored and 'restored' or 'NOT restored') .. ')')
      end
      return
    end
  end
end

-- BeamNG hook: a vehicle appeared.
function M.onVehicleSpawned(vehId)
  -- A new car re-declares its configuration, shortly (not knowable yet).
  armVehicleConfigReport()
  -- A car appearing under a field-wide ghost is ghosted now, not at the next
  -- sweep: a mass respawn is exactly when cars appear.
  if next(ghost.field) ~= nil and not isOwnVehicle(vehId) then
    local got, veh = pcall(getObjectByID, vehId)
    for reason in pairs(ghost.field) do
      ghost.reason(vehId, reason, true, got and veh or nil)
    end
  end
  -- A car reloaded on a held grid arrives unfrozen: back on the slot, held.
  if holdWanted and isOwnVehicle(vehId) then
    hold.restore('vehicle respawned while held on the grid')
    pushNotice('grid', 'Back on your grid slot, held for the countdown')
  end
  if not session.spectatorLock then return end
  if not isOwnVehicle(vehId) then return end
  -- A spectator spawned a fresh car: re-apply the input block (the spawn may
  -- re-register the action set) and, for a race finisher, the ghost: a new car
  -- starts solid and could be driven into the race.
  spectate.setInputsBlocked(false)
  spectate.setInputsBlocked(session.spectatorLock == 'derby')
  if session.spectatorLock ~= 'derby' then
    ghost.setFinished(true)
    pushNotice('spectate', 'Your car is a ghost: nobody still racing can touch it')
  else
    pushNotice('spectate', 'You are spectating until the session ends')
  end
  log('W', 'raceManager', 'Vehicle spawned in spectator mode ('
    .. tostring(session.spectatorLock) .. ')')
end

-- BeamNG hook: a vehicle is removed. Id-keyed state is dropped: ids are REUSED,
-- and the next car would inherit a ghost (or the belief it is ghosted).
function M.onVehicleDestroyed(vehId)
  if vehId == nil then return end
  if ownVehId == vehId then ownVehId = nil end
  ghost.veh[vehId]     = nil
  ghost.applied[vehId] = nil
  ghost.left[vehId]    = nil
  ghost.alpha[vehId]   = nil
  for pid, id in pairs(ghost.remoteVeh) do
    if id == vehId then ghost.remoteVeh[pid] = nil end
  end
  for key, id in pairs(ghost.practiceRemote) do
    if id == vehId then ghost.practiceRemote[key] = false end
  end
  if ghost.practiceOwn == vehId then ghost.practiceOwn = nil end
  if M.radarForget then M.radarForget(vehId) end
  -- Our own car gone ends our ghost: nothing is left to restore.
  if ghost.own.vehId == vehId then
    ghost.own.vehId    = nil
    ghost.own.settling = false
    ghost.own.left     = 0
    ghost.own.total    = 0
    ghost.own.blocked  = 0
    ghost.own.warned   = false
    if inMultiplayer() then TriggerServerEvent('RM_GhostEnd', '') end
  end
end

-- ===========================================================================
-- Starting grid: placement, assignment and the hold until GO
-- ===========================================================================
-- Slots travel with the layout; the server assigns each driver a slot and this
-- client places and holds its own car (the server has no physics).

-- Who imposed the hold: 'race' (grid) or 'derby' (form-up), so a race phase
-- change never releases a car held for a derby, or the other way round.
local freezeSource = nil

-- Freezing a car, through core_vehicleBridge.executeAction(veh, 'setFreeze')
-- as BeamNG's career code does: a queued `controller.setFreeze(1)` reported
-- success and did nothing. The direct call is the fallback for older builds.
setLocalVehicleFrozen = function (frozen, source)
  -- OUR car: freezing a rival's on this client fights BeamMP's sync and the car
  -- detonates for everyone watching it.
  local veh = ownVehicle()
  if not veh then return false end
  local want = frozen and true or false
  local ok = false
  if core_vehicleBridge and core_vehicleBridge.executeAction then
    ok = pcall(core_vehicleBridge.executeAction, veh, 'setFreeze', want)
  end
  if not ok then
    ok = pcall(function ()
      veh:queueLuaCommand('controller.setFreeze(' .. (want and '1' or '0') .. ')')
    end)
  end
  if ok then
    session.gridFrozen = want
    freezeSource = want and (source or 'race') or nil
  end
  return ok
end

-- Put our car on a start position, facing down the track (headingRot).
placeOnStartPosition = function (sp)
  local veh = ownVehicle()      -- a teleport: see relocateToGate
  if not veh or not sp then return false end
  local rot = headingRot(sp.hx, sp.hy)
  -- Our own teleport: being gridded never costs an allowance.
  noteSelfTeleport(sp.x, sp.y, sp.z)
  local ok = pcall(function ()
    veh:setPositionRotation(sp.x, sp.y, sp.z, rot.x, rot.y, rot.z, rot.w)
  end)
  if not ok then block.selfTeleport.left = 0 end
  return ok
end

-- Holding a car for a standing start: place it, freeze ONCE, leave it alone.
-- Each freeze re-pins the car and resets the drivetrain, so repeating it
-- bleeds the revs and drops a pre-selected gear. One path for both modes.
local function requestHold(source)
  holdWanted = source
  local ok = setLocalVehicleFrozen(true, source)
  if ok then
    pushRouteState()
    log('I', 'raceManager', 'Hold requested (' .. tostring(source) .. ')')
  else
    -- Never quietly: an unheld car looks like a start that has not begun.
    log('W', 'raceManager', 'Hold (' .. tostring(source) .. ') could not be applied')
  end
  return ok
end

-- Put a held car back on its slot, facing down the track, frozen. Shared by the
-- drift watch, a grid reset, a grid respawn and the server's correction. A
-- table field: onVehicleResetted, far above, calls it.
function hold.restore(reason)
  if not holdWanted then return false end
  local veh = ownVehicle()
  if not veh then return false end
  -- Where it settled, or the slot itself during the settle window.
  local to = hold.anchor or hold.slot
  if to then
    local rot = hold.rot or quat(0, 0, 0, 1)
    noteSelfTeleport(to.x, to.y, to.z)
    local ok = pcall(function ()
      veh:setPositionRotation(to.x, to.y, to.z, rot.x, rot.y, rot.z, rot.w)
    end)
    if not ok then block.selfTeleport.left = 0 end
    -- Dropped again, so it settles again before anything measures it.
    hold.anchor = nil
    hold.settleLeft = TUNE.HOLD_SETTLE_GRACE
  end
  -- After the teleport: its reset echo would reload the VM and drop the freeze.
  setLocalVehicleFrozen(true, holdWanted)
  hold.corrections = hold.corrections + 1
  -- Logged on the cooldown; the count keeps the total honest.
  if hold.correctLeft <= 0 then
    log('W', 'raceManager', string.format(
      'Grid hold restored (%s): correction #%d', tostring(reason), hold.corrections))
  end
  hold.correctLeft = TUNE.HOLD_CORRECT_COOLDOWN
  return true
end

-- Watch a held car and report where it is. Locally a car off its slot is put
-- back (fix the symptom, not each cause); the server is told on a steady
-- cadence, so a modified client still has the server behind it. Nothing is
-- enforced until the car has SETTLED onto its suspension. A car merely moving
-- is re-frozen where it stands (no teleport, no reset); one that has LEFT its
-- slot is teleported back.
local function holdUpdate(dt)
  if hold.correctLeft > 0 then hold.correctLeft = hold.correctLeft - dt end
  if not holdWanted then
    hold.reportLeft = 0
    return
  end
  local veh = ownVehicle()
  if not veh then return end
  local ok, pos, vel = pcall(function ()
    return veh:getPosition(), veh:getVelocity()
  end)
  if not ok or not pos then return end

  local speed = 0
  if vel then speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z) end

  -- Reported whatever enforcement decides, settling included, every
  -- HOLD_REPORT_EVERY.
  if inMultiplayer() then
    hold.reportLeft = hold.reportLeft - dt
    if hold.reportLeft <= 0 then
      hold.reportLeft = TUNE.HOLD_REPORT_EVERY
      TriggerServerEvent('RM_HoldPos', jsonEncode({
        x = pos.x, y = pos.y, z = pos.z, slot = session.gridSlot,
      }))
    end
  end

  -- Settling: left alone until it stops moving or the grace runs out.
  if hold.settleLeft > 0 then
    hold.settleLeft = hold.settleLeft - dt
    -- Settling is vertical. Moving ACROSS the ground is leaving, measured from
    -- the slot (there is no anchor yet).
    local away = 0
    if hold.slot then
      local ax, ay = pos.x - hold.slot.x, pos.y - hold.slot.y
      away = math.sqrt(ax * ax + ay * ay)
    end
    if away > TUNE.HOLD_DRIFT then
      -- The notice is throttled (restore re-arms the settle window, so a shoved
      -- car stays in this branch: unthrottled it was 120 UI pushes a second).
      -- The correction itself runs every frame: it is idempotent.
      local announce = hold.correctLeft <= 0
      if announce then
        hold.correctLeft = TUNE.HOLD_CORRECT_COOLDOWN
        hold.corrections = hold.corrections + 1
      end
      hold.restore(string.format('left the slot (%.2fm) before settling', away))
      if announce then
        pushNotice('grid', 'Hold the car, the countdown has not finished')
      end
      return
    end
    local waited = TUNE.HOLD_SETTLE_GRACE - hold.settleLeft
    if hold.settleLeft > 0
       and (waited < TUNE.HOLD_SETTLE_MIN or speed > TUNE.HOLD_SETTLED_SPEED) then
      return
    end
    hold.settleLeft = 0
    hold.anchor = vec3(pos.x, pos.y, pos.z)
    log('I', 'raceManager', string.format(
      'Grid hold settled at (%.2f, %.2f, %.2f)', pos.x, pos.y, pos.z))
    return
  end

  if hold.anchor then
    -- HORIZONTAL distance only: sagging and kerbs move a car vertically.
    local dx = pos.x - hold.anchor.x
    local dy = pos.y - hold.anchor.y
    local drift = math.sqrt(dx * dx + dy * dy)
    if drift > TUNE.HOLD_DRIFT then
      -- Off the slot: put it back every frame (idempotent; a car whose freeze
      -- will not take must not ratchet forward). Only the notice is throttled,
      -- and the throttle has to be armed here too.
      local announce = hold.correctLeft <= 0
      if announce then
        hold.correctLeft = TUNE.HOLD_CORRECT_COOLDOWN
        hold.corrections = hold.corrections + 1
      end
      hold.restore(string.format('%.2fm off the slot at %.1f m/s', drift, speed))
      if announce then
        pushNotice('grid', 'Hold the car, the countdown has not finished')
      end
      return
    end
    if speed > TUNE.HOLD_CREEP_SPEED then
      -- Moving on its slot: the freeze is lost. Re-pin it where it stands.
      setLocalVehicleFrozen(true, holdWanted)
      if hold.correctLeft <= 0 then
        hold.correctLeft = TUNE.HOLD_CORRECT_COOLDOWN
        hold.corrections = hold.corrections + 1
        log('W', 'raceManager', string.format(
          'Grid hold re-pinned a car moving at %.2f m/s on its slot', speed))
      end
      return
    end
  end

end

-- GO, or any exit from the start procedure: release the car. `source` names the
-- mode letting go; nil forces it (session end, unload).
local function releaseGridHold(source)
  -- Intent first: a late reset echo checks holdWanted before re-freezing.
  if not source or not holdWanted or holdWanted == source then
    holdWanted = nil
  end
  -- A stale anchor would drag a racing car back onto its grid slot.
  if not holdWanted then
    hold.anchor = nil
    hold.slot = nil
    hold.rot = nil
    hold.settleLeft = 0
    hold.reportLeft = 0
  end
  if not session.gridFrozen then return end
  if source and freezeSource and freezeSource ~= source then return end
  setLocalVehicleFrozen(false)
  session.gridFrozen = false
  freezeSource = nil
  pushRouteState()
end

-- ===========================================================================
-- Field placement: one ghosted, staggered queue
-- ===========================================================================
-- Everything that moves this client's car as part of a FIELD (forming a grid,
-- putting cars back) goes through here, so cars arriving together never land
-- inside each other:
--   * Ghosting for the whole operation.
--   * A stagger: each client waits (its order) x STAGGER; the server hands out
--     the order with the slot.
--   * A settle TIMER sized for the whole field (cars on a grid are frozen, so
--     a motion test would fire at once or never), plus a hard timeout.
local FIELD = {
  STAGGER     = 0.18,   -- seconds between one car landing and the next
  SETTLE      = 1.2,    -- seconds after the last car lands
  SPAWN_GRACE = 0.5,    -- seconds for a spawned vehicle to exist
  TIMEOUT     = 15.0,   -- hard cap: collisions come back regardless
  -- Re-coupling a trailer after the placement ghost lifts; the lift is itself
  -- queued, so the attempt is retried over a window.
  COUPLE_FOR   = 3.0,   -- seconds the retry window stays open
  COUPLE_EVERY = 0.4,   -- seconds between attempts inside it
}

local field = {
  active  = false,
  -- Trailer re-coupling: had one when queued, window left, next attempt.
  hadRig     = false,
  coupleLeft = 0,
  coupleNext = 0,
  step    = nil,     -- wait | spawn | grace | place | settle
  delay   = 0,       -- until OUR car is placed
  grace   = 0,       -- until a just-spawned vehicle is usable
  settle  = 0,       -- until collisions come back
  timeout = 0,
  respawn = false,   -- put our removed car back as part of this operation
  slot    = nil,     -- slot to stand on
  slots   = nil,     -- which slot list that indexes (race grid or derby arena)
  hold    = false,   -- freeze once placed
  holdSource = nil,  -- 'race' | 'derby': only the owner releases the hold
}

-- Stand the car on its slot. Only from the scheduler: placing is what has to be
-- staggered and ghosted.
local function placeOnAssignedSlot()
  local slot = field.slot
  local list = field.slots or track.startPositions
  local sp = slot and list[slot]
  -- Any placed slot beats wherever the car appeared.
  if not sp then sp = list[1] end
  if not sp then
    pushNotice('grid', 'Start position ' .. tostring(slot) .. ' is not placed on this track')
    log('W', 'raceManager', 'Grid slot ' .. tostring(slot) .. ' has no start position')
    return
  end
  if not placeOnStartPosition(sp) then
    log('W', 'raceManager', 'Could not place the car on grid slot ' .. tostring(slot))
    return
  end
  -- Where the hold is measured from, kept apart from snapshot.pos (the reset
  -- rules' sample, which moves as the driver laps).
  if field.hold then
    -- The slot is the DROP point; the anchor is captured once the car settles.
    hold.anchor = nil
    hold.slot   = vec3(sp.x, sp.y, sp.z)
    hold.rot    = headingRot(sp.hx, sp.hy)
    hold.settleLeft  = TUNE.HOLD_SETTLE_GRACE
    hold.corrections = 0
  end
  if field.hold then requestHold(field.holdSource or 'race') end
  -- The slot is also where a blocked reset restores to, facing down the track.
  snapshot.pos = vec3(sp.x, sp.y, sp.z)
  snapshot.rot = headingRot(sp.hx, sp.hy)
  pushNotice('grid', 'You start from P' .. slot .. ': hold for the countdown')
  log('I', 'raceManager', 'Placed on start slot ' .. slot
    .. ' (' .. tostring(field.holdSource or 'race') .. ')')
end

local function endFieldOperation()
  field.active = false
  field.step   = nil
  field.slot   = nil
  field.slots  = nil
  field.respawn = false
  field.holdSource = nil
  if setGhostReason then setGhostReason('placement', false) end
  -- The trailer goes back on from HERE, as collisions come back: a ghosted car
  -- has nothing for a coupler to find. Retried, since the lift is queued.
  if field.hadRig then
    field.coupleLeft = FIELD.COUPLE_FOR
    field.coupleNext = 0
  end
end

-- Queue a placement. A release and a grid slot arriving on one tick are ONE
-- operation under a single ghost.
queueFieldPlacement = function (opts)
  local order = math.max(math.floor(tonumber(opts.order) or 1), 1)
  local count = math.max(math.floor(tonumber(opts.count) or order), order)
  local delay  = (order - 1) * FIELD.STAGGER
  local settle = (count - 1) * FIELD.STAGGER + FIELD.SETTLE

  -- Coalesce only before the car is placed: once settling, a new request is a
  -- new placement, or its slot would never be stood on.
  if field.active and field.step ~= 'settle' then
    field.respawn = field.respawn or (opts.respawn == true)
    if opts.slot then
      field.slot  = opts.slot
      field.slots = opts.slots
      field.hold  = opts.hold == true
      field.holdSource = opts.holdSource
    end
    if field.step == 'wait' then field.delay = math.max(field.delay, delay) end
    field.settle  = math.max(field.settle, settle)
    field.timeout = math.max(field.timeout, FIELD.TIMEOUT)
    return
  end

  field.active  = true
  field.step    = 'wait'
  field.delay   = delay
  field.grace   = 0
  field.settle  = settle
  field.timeout = FIELD.TIMEOUT
  field.respawn = opts.respawn == true
  field.slot    = opts.slot
  field.slots   = opts.slots
  field.hold    = opts.hold == true
  field.holdSource = opts.holdSource
  if setGhostReason then setGhostReason('placement', true) end
  -- Was a trailer on the back? Asked before anything moves (see the same check
  -- in noteSelfTeleport).
  field.hadRig = false
  do
    local rigVeh = ownVehicle()
    if rigVeh then
      local rigId = vehicleId(rigVeh)
      pcall(function ()
        if not (core_vehicles and type(core_vehicles.attachedCouplers) == 'table') then return end
        for _, pair in ipairs(core_vehicles.attachedCouplers) do
          if pair[1] == rigId or pair[2] == rigId then field.hadRig = true; return end
        end
      end)
    end
  end
  log('I', 'raceManager', string.format(
    'Field placement queued (order %d/%d, +%.2fs, respawn=%s, slot=%s)',
    order, count, delay, tostring(field.respawn), tostring(field.slot)))
end

local function fieldUpdate(dt)
  -- Runs whether or not a placement is active: the re-couple window opens as
  -- one ENDS.
  if field.coupleLeft > 0 then
    field.coupleLeft = field.coupleLeft - dt
    field.coupleNext = field.coupleNext - dt
    if field.coupleNext <= 0 then
      field.coupleNext = FIELD.COUPLE_EVERY
      local rigVeh = ownVehicle()
      local rigId  = rigVeh and vehicleId(rigVeh) or nil
      -- ALREADY COUPLED IS THE NORMAL CASE, AND THEN THIS MUST NOT FIRE.
      -- beamstate.attachCouplers arms EVERY coupler node to latch anything in
      -- reach at a strength of 1,000,000, with no already-attached test: on a
      -- packed grid that latched cars to their neighbours, which then came apart
      -- violently at the green. Kept, guarded, for a rig that really is loose.
      local coupled = false
      if rigId then coupled = next(ghost.rigMates(rigId)) ~= nil end
      if coupled then
        field.coupleLeft = 0
        field.coupleNext = 0
      elseif rigVeh then
        pcall(function () rigVeh:queueLuaCommand('beamstate.attachCouplers()') end)
      end
    end
    if field.coupleLeft <= 0 then
      field.hadRig = false
      log('I', 'raceManager', 'Trailer re-couple window closed')
    end
  end
  if not field.active then return end
  field.timeout = field.timeout - dt

  -- Timeout: whatever is stuck, the driver gets their car and collisions back.
  if field.timeout <= 0 then
    if field.step ~= 'settle' then
      if field.respawn then respawnRemovedVehicle() end
      if field.slot then placeOnAssignedSlot() end
      bindCameraToOwnVehicle()
      log('W', 'raceManager', 'Field placement timed out: finishing it anyway')
    end
    endFieldOperation()
    pushRouteState()
    return
  end

  if field.step == 'wait' then
    field.delay = field.delay - dt
    if field.delay > 0 then return end
    field.step = 'spawn'
    return
  end

  if field.step == 'spawn' then
    if field.respawn then
      field.respawn = false
      if respawnRemovedVehicle() then
        field.grace = FIELD.SPAWN_GRACE
        field.step  = 'grace'
        return
      end
    end
    field.step = 'place'
    return
  end

  if field.step == 'grace' then
    field.grace = field.grace - dt
    if field.grace > 0 and not ownVehicle() then return end
    field.step = 'place'
    return
  end

  if field.step == 'place' then
    if field.slot then placeOnAssignedSlot() end
    -- Explicitly: after a mass placement the game's camera pick is arbitrary.
    bindCameraToOwnVehicle()
    field.step = 'settle'
    pushRouteState()
    return
  end

  -- 'settle': collisions come back once the whole field has landed.
  field.settle = field.settle - dt
  if field.settle > 0 then return end
  endFieldOperation()
  pushRouteState()
end

-- Finish a queued placement now, for paths with no more ticks coming (unload,
-- leaving the server).
local function flushFieldPlacement()
  if not field.active then return end
  if field.respawn then respawnRemovedVehicle() end
  if field.slot then placeOnAssignedSlot() end
  bindCameraToOwnVehicle()
  endFieldOperation()
end

-- The server assigned a grid slot: stand on it and hold. `order`/`count`
-- stagger the placement.
local function applyGridSlot(slot, order, count)
  session.gridSlot = slot
  -- No direction is assigned: the slot points the car, and whichever gate for
  -- the next checkpoint it reaches clears it.
  if not slot then
    -- Standing down: nothing to place, and nothing should hold this car.
    releaseGridHold('race')
    pushRouteState()
    return
  end
  queueFieldPlacement({
    slot = slot, hold = true, order = order or slot, count = count,
  })
  pushRouteState()
end

-- ===========================================================================
-- Ghosting: qualifying, field placement, and reset
-- ===========================================================================
-- A ghosted car has no vehicle-to-vehicle collision. Reasons are refcounted
-- PER VEHICLE: 'quali' (rivals during a flying lap), 'placement' (a field
-- landing through itself), 'reset' (intangible until provably clear), plus pit,
-- finished, practice and derby respawn.
-- The toggle is BeamNG's own vehicle-side obj:setGhostEnabled(bool), reached
-- through queueLuaCommand (MPVehicleGE has no ghost API). It leaves world and
-- terrain collision alone. Every client must ghost the SAME car, so RM_Ghost
-- carries the BeamMP player id (MPVehicleGE's ownerID); vehicle ids are local.

-- Walk vehicles via getAllVehicles(), falling back to the scene-object walk.
-- `skipId` drops one car, usually ours.
local function forEachVehicle(skipId, fn)
  if type(getAllVehicles) == 'function' then
    local ok, list = pcall(getAllVehicles)
    if ok and type(list) == 'table' then
      for _, veh in ipairs(list) do
        if veh then
          -- Closure, for vehicleId's reason.
          local gotId, id = pcall(function () return veh:getID() end)
          if gotId and id ~= skipId then fn(veh, id) end
        end
      end
      return
    end
  end
  if not be then return end
  local count = be:getObjectCount() or 0
  for i = 0, count - 1 do
    local veh = be:getObject(i)
    if veh then
      local ok, id = pcall(function () return veh:getID() end)
      if ok and id ~= skipId then fn(veh, id) end
    end
  end
end

-- Which local vehicle belongs to a player id (different on every client).
function ghost.vehicleForPid(pid)
  if pid == nil or not (MPVehicleGE and type(MPVehicleGE.getVehicles) == 'function') then
    return nil, nil
  end
  local ok, list = pcall(MPVehicleGE.getVehicles)
  if not ok or type(list) ~= 'table' then return nil, nil end
  for _, v in pairs(list) do
    if type(v) == 'table' and tostring(v.ownerID) == tostring(pid) and v.gameVehicleID then
      local got, obj = pcall(getObjectByID, v.gameVehicleID)
      if got and obj then return obj, v.gameVehicleID end
    end
  end
  return nil, nil
end

-- Set one car's mesh alpha, only when it has moved: the fade runs every frame
-- and setMeshAlpha crosses into the engine per car.
function ghost.fade(vehId, veh, alpha)
  if not veh then return end
  local was = ghost.alpha[vehId]
  if was and math.abs(was - alpha) < 0.01 then return end
  ghost.alpha[vehId] = alpha
  -- Closure, for vehicleId's reason.
  pcall(function () veh:setMeshAlpha(alpha, '', false) end)
end

-- Apply or lift the ghost on one car: collision, then the fade. On TRANSITIONS
-- only: queueLuaCommand marshals a string into the vehicle VM.
function ghost.apply(vehId, veh, on, alpha)
  if not veh then return end
  pcall(function ()
    veh:queueLuaCommand('obj:setGhostEnabled(' .. (on and 'true' or 'false') .. ')')
  end)
  ghost.fade(vehId, veh, on and (alpha or TUNE.GHOST_ALPHA) or 1)
  ghost.applied[vehId] = on or nil
end

-- A per-car reason applied to the WHOLE RIG: a trailer must be intangible with
-- its car (half a rig passing through a rival while the other half hits them
-- is worse than no ghost). Same named reason, so both go solid on one tick.
-- Field-wide reasons do not come through here: they walk every vehicle anyway
-- and skip our own rig by id.
function ghost.reasonRig(vehId, reason, on, veh)
  ghost.reason(vehId, reason, on, veh)
  for id in pairs(ghost.rigMates(vehId)) do
    ghost.reason(id, reason, on, nil)
  end
end

-- Add or drop one reason on one vehicle and make the car match. `veh` when the
-- caller already holds it, to skip a scene lookup.
function ghost.reason(vehId, reason, on, veh)
  if vehId == nil then return end
  local set = ghost.veh[vehId]
  if on then
    set = set or {}
    set[reason] = true
    ghost.veh[vehId] = set
  elseif set then
    set[reason] = nil
    if next(set) == nil then ghost.veh[vehId] = nil end
  end
  local want = ghost.veh[vehId] ~= nil
  if want then ghost.pending[vehId] = nil end
  if want == (ghost.applied[vehId] == true) then return end
  if not veh then
    local got, found = pcall(getObjectByID, vehId)
    veh = got and found or nil
  end
  -- THE GATE back to solid, for every reason: no car gets its collisions back
  -- while another car is inside it. It waits in `pending`, retried each update;
  -- ghosts can drive apart, so it cannot deadlock.
  if not want and veh and ghost.wouldWeld(vehId, veh) then
    ghost.pending[vehId] = true
    return
  end
  ghost.pending[vehId] = nil
  ghost.apply(vehId, veh, want, ghost.alphaFor(vehId))
end

-- Is another car inside this one (ghost or not)? For cars we do not own: no
-- countdown, no driver to warn. ghost.occupied does this for our own car.
function ghost.wouldWeld(vehId, veh)
  local c1, x1, y1, z1 = ghost.bounds(veh, TUNE.GHOST_OVERLAP_MARGIN)
  local mine = ghost.center(veh)
  -- A car that cannot be located does not block here (unlike occupied, where
  -- it is our own car): "ghost until measured" once left a car intangible all race.
  if not c1 and not mine then return false end
  local weld = false
  -- Our own rig is not a hazard: a coupled trailer is inside the box by design,
  -- and both checks need this or the rig stays ghosted forever.
  local mates = ghost.rigMates(vehId)
  forEachVehicle(vehId, function (other, otherId)
    if weld then return end
    if mates[otherId] then return end
    local c2, x2, y2, z2 = ghost.bounds(other, 0)
    if c1 and c2 and type(overlapsOBB_OBB) == 'function' then
      local okHit, hit = pcall(overlapsOBB_OBB, c1, x1, y1, z1, c2, x2, y2, z2)
      if not okHit or hit then weld = true end
      return
    end
    local theirs = ghost.center(other)
    if not (mine and theirs) then return end
    local dx, dy, dz = mine.x - theirs.x, mine.y - theirs.y, mine.z - theirs.z
    if (dx * dx + dy * dy + dz * dz)
        <= (TUNE.GHOST_FALLBACK_RADIUS * TUNE.GHOST_FALLBACK_RADIUS) then
      weld = true
    end
  end)
  return weld
end

-- Alpha mid-ghost: translucent, fading to solid over the last second. An
-- occupancy block does not fade: a stuck car stays visibly a ghost.
function ghost.alphaFor(vehId)
  -- Our own finished or practising car is never faded on our screen: its
  -- collision is off, but alpha is a separate call. Decided only here.
  if vehId ~= nil and vehId == ghost.finishedOwn then return 1 end
  if vehId ~= nil and vehId == ghost.practiceOwn then return 1 end
  local left = ghost.left[vehId]
  local fade = TUNE.GHOST_FADE_OUT_SEC
  if not left or fade <= 0 or left >= fade then return TUNE.GHOST_ALPHA end
  if left <= 0 then return TUNE.GHOST_ALPHA end
  local t = 1 - (left / fade)          -- 0 at fade start, 1 at contact
  return TUNE.GHOST_ALPHA + (1 - TUNE.GHOST_ALPHA) * t
end

-- A car's oriented bounding box, as overlapsOBB_OBB wants it, with `margin`
-- added to each half-extent.
function ghost.bounds(veh, margin)
  if not veh then return nil end
  -- getSpawnWorldOOBB first (BeamNG's spawn-occupancy box): oriented, so a car
  -- lying crossways through another is caught.
  local ok, c, x, y, z = pcall(function ()
    local bb = veh:getSpawnWorldOOBB()
    if not bb then return nil end
    local he = bb:getHalfExtents()
    return bb:getCenter(),
      bb:getAxis(0) * (he.x + margin),
      bb:getAxis(1) * (he.y + margin),
      bb:getAxis(2) * (he.z + margin)
  end)
  if ok and c then return c, x, y, z end
  -- Then the axis-aligned world box. getSpawnWorldOOBB can return nil, and
  -- "nil means occupied" once ghosted a driver for a whole race.
  ok, c, x, y, z = pcall(function ()
    local bb = veh:getWorldBox()
    if not bb then return nil end
    local he = bb:getExtents()
    return bb:getCenter(),
      vec3(he.x * 0.5 + margin, 0, 0),
      vec3(0, he.y * 0.5 + margin, 0),
      vec3(0, 0, he.z * 0.5 + margin)
  end)
  if ok and c then return c, x, y, z end
  -- Then the car's own dimensions, oriented by its heading: below this is only
  -- a radius wide enough that somebody is nearly always inside it.
  ok, c, x, y, z = pcall(function ()
    local p = veh:getPosition()
    local dir = veh:getDirectionVector()
    local up = veh:getDirectionVectorUp()
    local len = veh:getInitialLength() * 0.5
    local wid = veh:getInitialWidth() * 0.5
    local hgt = veh:getInitialHeight() * 0.5
    if not (p and dir and up and len and wid and hgt) then return nil end
    local fwd   = vec3(dir.x, dir.y, dir.z)
    local upv   = vec3(up.x, up.y, up.z)
    local right = fwd:cross(upv)
    return vec3(p.x, p.y, p.z) + upv * hgt,
      right * (wid + margin),
      fwd * (len + margin),
      upv * (hgt + margin)
  end)
  if ok and c then return c, x, y, z end
  return nil
end

-- Where a car is, for the last-resort distance test.
function ghost.center(veh)
  if not veh then return nil end
  local ok, p = pcall(function () return veh:getPosition() end)
  if not ok or not p then return nil end
  return p
end

-- Every vehicle coupled to this one, transitively (car, dolly, trailer).
-- Without it our own trailer counts as a rival: ghosted as one, and occupying
-- our space forever. Guarded: core_vehicles may be absent.
function ghost.rigMates(vehId)
  local mates = {}
  if not vehId then return mates end
  pcall(function ()
    if not (core_vehicles and type(core_vehicles.attachedCouplers) == 'table') then return end
    local seen = { [vehId] = true }
    local grew = true
    while grew do
      grew = false
      for _, pair in ipairs(core_vehicles.attachedCouplers) do
        local a, b = pair[1], pair[2]
        if seen[a] and b and not seen[b] then seen[b] = true; mates[b] = true; grew = true end
        if seen[b] and a and not seen[a] then seen[a] = true; mates[a] = true; grew = true end
      end
    end
  end)
  return mates
end

-- Is anything sharing this car's space? THE HARD INVARIANT: restoring collision
-- on overlapping cars welds them, which ends both races. Every way of failing
-- to know returns BLOCKED; a long ghost is a nuisance, an early one is a wreck.
function ghost.occupied(vehId, veh)
  local c1, x1, y1, z1 = ghost.bounds(veh, TUNE.GHOST_OVERLAP_MARGIN)
  local mine = ghost.center(veh)
  -- Our own car cannot be located: stay ghosted (it is being deleted).
  if not c1 and not mine then
    ghost.blockReason = 'this car cannot be located'
    return true
  end

  local blocked, sawAny, reason = false, false, nil
  -- Our own rig is not somebody else's car.
  local mates = ghost.rigMates(vehId)
  forEachVehicle(vehId, function (other, otherId)
    if blocked then return end
    if mates[otherId] then return end
    -- Another car blocks whether or not it is a ghost: its ghost ends on its
    -- own client's clock, and after a mass respawn every car is one. Two ghosts
    -- can always drive apart, so waiting cannot deadlock.
    sawAny = true
    local c2, x2, y2, z2 = ghost.bounds(other, 0)
    -- The precise test. The margin is on OUR box only.
    if c1 and c2 and type(overlapsOBB_OBB) == 'function' then
      local okHit, hit = pcall(overlapsOBB_OBB, c1, x1, y1, z1, c2, x2, y2, z2)
      if not okHit then
        reason = 'overlap test failed'
        blocked = true
      elseif hit then
        reason = 'another car is in this space'
        blocked = true
      end
      return
    end
    -- Unmeasurable is not overlapping: a blunt radius test, not a verdict, or a
    -- far-off unmeasurable car blocks forever.
    local theirs = ghost.center(other)
    if not (mine and theirs) then
      reason = 'a nearby car cannot be located'
      blocked = true
      return
    end
    local dx, dy, dz = mine.x - theirs.x, mine.y - theirs.y, mine.z - theirs.z
    if (dx * dx + dy * dy + dz * dz)
        <= (TUNE.GHOST_FALLBACK_RADIUS * TUNE.GHOST_FALLBACK_RADIUS) then
      reason = 'a car that cannot be measured is close by'
      blocked = true
    end
  end)
  -- Nothing else on track is a clear frame.
  if not sawAny then
    ghost.blockReason = nil
    return false
  end
  ghost.blockReason = blocked and reason or nil
  return blocked
end

-- Field-wide reasons: ghost every car this client sees except its own rig.
setGhostReason = function (reason, on)
  -- ON skips our own car (ownVehicle: the attached car may be a rival's; with
  -- none, everything is ghosted, right for a mass respawn). OFF skips NOTHING:
  -- ON can reach our car while ownership is unresolved, and an OFF that skipped
  -- it would leave the reason on forever. Clearing a missing reason is free.
  local skipId, skipRig = nil, nil
  if on then
    local mine = ownVehicle()
    skipId = mine and vehicleId(mine) or nil
    -- ...and anything coupled to it: our own trailer is not a rival.
    skipRig = skipId and ghost.rigMates(skipId) or nil
  end
  forEachVehicle(skipId, function (veh, id)
    if skipRig and skipRig[id] then return end
    ghost.reason(id, reason, on, veh)
  end)
  if on then ghost.field[reason] = true else ghost.field[reason] = nil end
end

local function clearGhostReasons()
  ghost.field = {}
  ghost.remote = {}
  ghost.pending = {}
  ghost.left = {}
  ghost.blockReason = nil
  ghost.own = { settling = false, left = 0, total = 0, blocked = 0, warned = false }
  ghost.veh = {}
  ghost.finishedOwn = nil
  ghost.finishedRemote = {}
  ghost.practiceOwn = nil
  ghost.practiceList = {}
  ghost.practiceRemote = {}
  ghost.respawn = {}
  -- Swept over EVERY car, whatever the bookkeeping thinks: an entry lost to a
  -- reused id or a reloaded extension would otherwise stay intangible.
  ghost.applied = {}
  ghost.alpha = {}
  ghost.remoteVeh = {}
  forEachVehicle(nil, function (veh, id) ghost.apply(id, veh, false) end)
  ghost.applied = {}
  ghost.alpha = {}
  ghost.pending = {}
end

-- Arm our own reset ghost, LOCALLY at once (the dangerous frame is this one),
-- then broadcast. A repeat reset RESTARTS the timer, never stacks: the
-- occupancy check is what really decides when collision comes back.
function ghost.arm()
  local veh = ownVehicle()
  local vehId = veh and vehicleId(veh) or nil
  if not vehId then return end
  local rules = ghost.rules
  local base = rules.minSec
  ghost.own.pid      = localServerId()
  ghost.own.vehId    = vehId
  ghost.own.total    = base
  ghost.own.left     = base
  ghost.own.blocked  = 0
  ghost.own.warned   = false
  -- The timer starts once the car reports a usable bounding box.
  ghost.own.settling   = true
  ghost.own.settleLeft = TUNE.GHOST_SETTLE_MAX
  ghost.left[vehId]  = base
  ghost.reasonRig(vehId, 'reset', true)
  -- A held key re-arms the ghost every time, but the server is only told on a
  -- change of duration or every half second.
  local changed = base ~= ghost.own.sentBase
  local stale   = (localTime - (ghost.own.sentAt or -math.huge)) >= 0.5
  if inMultiplayer() and (changed or stale) then
    ghost.own.sentBase = base
    ghost.own.sentAt   = localTime
    TriggerServerEvent('RM_GhostStart', jsonEncode({ duration = base }))
  end
  log('I', 'raceManager', string.format(
    'Reset ghost armed on vehicle %s for %.1fs', tostring(vehId), base))
end

-- Lift our own ghost and tell the server. `why` 'clear' (the occupancy check
-- passed) is the only case the driver is told about.
function ghost.release(why)
  local vehId = ghost.own.vehId
  if vehId then
    ghost.left[vehId] = nil
    ghost.reasonRig(vehId, 'reset', false)
  end
  ghost.own.vehId    = nil
  ghost.own.settling = false
  ghost.own.left     = 0
  ghost.own.total    = 0
  ghost.own.blocked  = 0
  ghost.own.warned   = false
  -- Forget what was reported, so the next ghost reports its duration.
  ghost.own.sentBase = nil
  ghost.own.sentAt   = nil
  if inMultiplayer() then TriggerServerEvent('RM_GhostEnd', '') end
  if why == 'clear' then pushNotice('ghost', 'Contact restored') end
  log('I', 'raceManager', 'Reset ghost released on vehicle ' .. tostring(vehId)
    .. ' (' .. tostring(why or 'clear') .. ')')
end

-- Someone else's ghost. `endsAt` is on the SERVER clock, so a late client
-- ghosts for less, never more. Only nil clears it, never elapsed time: the
-- owner may still be inside somebody, and un-ghosting here on our own clock
-- welds the pair in OUR physics. Elapsed time drives the fade only.
function ghost.applyRemote(pid, endsAt)
  if pid == nil then return end
  ghost.remote[pid] = endsAt
  local veh, vehId = ghost.vehicleForPid(pid)
  -- Cached: resolving builds a table, fine here, not in the per-frame fade.
  ghost.remoteVeh[pid] = vehId
  -- Not in our world yet: the refresh sweep applies it when it appears.
  if not vehId then return end
  if endsAt ~= nil then
    local left = endsAt - ghost.serverTime
    ghost.left[vehId] = left > 0 and left or nil
    -- Their trailer too: coupling is simulated on every client.
    ghost.reasonRig(vehId, 'reset', true)
    ghost.apply(vehId, veh, true, ghost.alphaFor(vehId))
  else
    ghost.left[vehId] = nil
    -- Lifted rig-wide, the same reach it was applied with, or the trailer keeps
    -- a reason nothing clears.
    ghost.reasonRig(vehId, 'reset', false)
  end
end

-- ---------------------------------------------------------------------------
-- The FINISHED ghost: a driver who has taken the flag, still in their own car
-- ---------------------------------------------------------------------------
-- A finisher keeps their car, ghosted, instead of a delete and respawn per
-- driver as the field finishes.
-- APPLIED TO OUR OWN CAR TOO: our car is simulated here, so a local collision
-- would shove a racer and that shove would sync to everyone. The driver keeps
-- the LOOK (alpha 1 for them, via ghost.alphaFor). Finished cars pass through
-- each other. Nothing here writes a position, so finishing mid-contact cannot
-- teleport anyone: removing a constraint injects no energy, which is why the
-- weld gate is only on the way BACK to solid.
function ghost.setFinished(on)
  local veh = ownVehicle()
  local vehId = veh and vehicleId(veh) or nil
  if on then
    if not vehId then return end
    ghost.finishedOwn = vehId
    -- Re-asserted: the ways back in here are a reset and a respawn, which reload
    -- the VM and drop setGhostEnabled while the bookkeeping says "ghosted".
    ghost.applied[vehId] = nil
    ghost.reasonRig(vehId, 'finished', true, veh)
  else
    -- Off the RECORDED id: the driver may be in a different car by now.
    local id = ghost.finishedOwn
    ghost.finishedOwn = nil
    if id then
      local got, found = pcall(getObjectByID, id)
      ghost.reasonRig(id, 'finished', false, got and found or nil)
    end
    if vehId and vehId ~= id then ghost.reasonRig(vehId, 'finished', false, veh) end
  end
end

-- Everyone else's finished cars, from the broadcast's authoritative list: a
-- client that missed the moment still converges.
function ghost.applyFinishedRoster(list)
  local mine = localServerId()
  local seen = {}
  for _, pid in ipairs(list or {}) do
    if pid ~= nil and tostring(pid) ~= tostring(mine) then
      seen[tostring(pid)] = true
      local veh, vehId = ghost.vehicleForPid(pid)
      ghost.remoteVeh[pid] = vehId
      if vehId and not (ghost.finishedRemote[tostring(pid)]) then
        ghost.reasonRig(vehId, 'finished', true, veh)
      end
      ghost.finishedRemote[tostring(pid)] = vehId or true
    end
  end
  -- Walked off what we applied, so a disconnect is noticed.
  for pid, vehId in pairs(ghost.finishedRemote) do
    if not seen[pid] then
      ghost.finishedRemote[pid] = nil
      if type(vehId) == 'number' then
        local got, found = pcall(getObjectByID, vehId)
        ghost.reasonRig(vehId, 'finished', false, got and found or nil)
      end
    end
  end
end

-- PRACTICE GHOSTS, on every client including the driver's own (setFinished's
-- reason). Ours is decided locally, everyone else's from `ghostPractice` on the
-- broadcast. Re-issued on every call: practice is where drivers reset most.
function ghost.practiceCar(vehId, on, veh)
  if on then ghost.applied[vehId] = nil end
  if not veh then
    local got, found = pcall(getObjectByID, vehId)
    veh = got and found or nil
  end
  ghost.reasonRig(vehId, 'practice', on, veh)
end

function ghost.practiceSync(list)
  if type(list) == 'table' then ghost.practiceList = list end
  local own = (practice.on and practice.ghost) and ownVehicle() or nil
  local ownId = own and vehicleId(own) or nil
  if ghost.practiceOwn and ghost.practiceOwn ~= ownId then
    ghost.practiceCar(ghost.practiceOwn, false)
  end
  ghost.practiceOwn = ownId
  if ownId then ghost.practiceCar(ownId, true, own) end
  local mine = tostring(localServerId())
  local seen = {}
  for _, pid in ipairs(ghost.practiceList) do
    local key = tostring(pid)
    if key ~= mine then
      seen[key] = true
      local veh, vehId = ghost.vehicleForPid(pid)
      local was = ghost.practiceRemote[key]
      if was and was ~= vehId then ghost.practiceCar(was, false) end
      ghost.practiceRemote[key] = vehId or false
      if vehId then ghost.practiceCar(vehId, true, veh) end
    end
  end
  -- Walked off what we applied, so a driver who stopped goes solid.
  for key, vehId in pairs(ghost.practiceRemote) do
    if not seen[key] then
      ghost.practiceRemote[key] = nil
      if vehId then ghost.practiceCar(vehId, false) end
    end
  end
end

-- The server's ghost roster, { { pid, endsAt } }. Authoritative: a pid not in
-- it has no ghost. Our own row is skipped: only we can tell our space is clear.
function ghost.applyRoster(list)
  local mine = localServerId()
  local seen = {}
  for _, row in ipairs(list) do
    local pid = row and row.pid
    if pid ~= nil and tostring(pid) ~= tostring(mine) then
      seen[pid] = true
      ghost.applyRemote(pid, tonumber(row.endsAt))
    end
  end
  for pid in pairs(ghost.remote) do
    if not seen[pid] then ghost.applyRemote(pid, nil) end
  end
end

-- The driver's own countdown and "you are stuck" warning, on its own channel,
-- ~10 Hz and silent with no ghost; the UI interpolates.
function ghost.pushHud(dt)
  local active = ghost.own.vehId ~= nil
  if not active and not ghost.hudShown then return end
  ghost.hudLeft = ghost.hudLeft - dt
  if active and ghost.hudShown and ghost.hudLeft > 0 then return end
  ghost.hudLeft  = 0.1
  ghost.hudShown = active
  guihooks.trigger('RaceManagerGhost', {
    active  = active,
    left    = ghost.own.left,
    total   = ghost.own.total,
    blocked = ghost.own.blocked > 0,
    warn    = ghost.own.blocked >= TUNE.GHOST_OVERLAP_WARN_SEC,
  })
end

-- One update for the ghost reasons, in order: qualifying, our own reset ghost
-- and its occupancy check, everyone else's ghosts and the fade, then the sweep
-- that re-asserts reasons onto cars that appeared since.
local function ghostUpdate(dt)
  -- Only on a change: setGhostReason walks every vehicle.
  local wantQuali = ghostQuali and session.phase == 'qualifying' and not session.spectatorLock
  if wantQuali ~= (ghost.field.quali == true) then
    setGhostReason('quali', wantQuali)
  end

  -- --- joined mid-session (or sitting out) ----------------------------------
  -- The server flags a mid-session arrival instead of entering them; their car
  -- is ghosted for as long as the flag lasts (cleared when the next grid forms).
  if isBystander ~= (ghost.field.bystander == true) then
    setGhostReason('bystander', isBystander)
  end
  -- Said when the session RUNS, not when the ghost goes on: forming a grid
  -- calls everyone, and a called car is a ghost until Ready.
  local sayOut = isBystander and sessionRunning()
  if sayOut ~= (ghost.outSaid == true) then
    ghost.outSaid = sayOut
    if sayOut then
      -- Three ways to be one, three sentences: waiting out another heat (tested
      -- first), spectating by choice, or a mid-session arrival.
      local why
      if session.myHeat and session.heatCurrent > 0
         and session.myHeat ~= session.heatCurrent then
        why = 'Heat ' .. session.heatCurrent .. ' is running and you are in heat '
          .. session.myHeat .. '. Drive where you like: your car is a ghost, so '
          .. 'you cannot touch the race or be touched by it.'
      elseif selfSpectating then
        why = 'You are spectating: your car is a ghost, so nobody can hit it.'
      else
        why = 'A session is already running: you are a ghost until it ends'
      end
      pushNotice('spectate', why)
    end
  end

  -- --- this client's own reset ghost -------------------------------------
  local own = ghost.own
  -- Ends with the race (flag, stood down, session over): nothing left to be
  -- careful around.
  if own.vehId and not ((session.phase == 'racing' or session.phase == 'qualifying') and not session.spectatorLock) then
    ghost.release('session ended')
  end
  if own.vehId then
    local got, veh = pcall(getObjectByID, own.vehId)
    veh = got and veh or nil
    if not veh then
      -- The car is gone: nothing to un-ghost.
      ghost.release('vehicle gone')
    else
      if own.settling then
        -- Settled: the first frame with a usable box, or a short fixed wait (a
        -- car that never reports one must still start its timer).
        own.settleLeft = own.settleLeft - dt
        if ghost.bounds(veh, 0) or own.settleLeft <= 0 then own.settling = false end
      else
        if own.left > 0 then
          own.left = math.max(own.left - dt, 0)
          ghost.left[own.vehId] = own.left
          -- The fade only: the car is already ghosted.
          ghost.fade(own.vehId, veh, ghost.alphaFor(own.vehId))
        else
          -- Timer done: collision comes back on the first CLEAR frame. No limit.
          if ghost.occupied(own.vehId, veh) then
            own.blocked = own.blocked + dt
            ghost.left[own.vehId] = nil     -- blocked cars stay visibly ghosts
            ghost.fade(own.vehId, veh, TUNE.GHOST_ALPHA)
            if not own.warned and own.blocked >= TUNE.GHOST_OVERLAP_WARN_SEC then
              own.warned = true
              pushNotice('ghost', 'Still ghosted, MOVE CLEAR of the other car')
              if inMultiplayer() then
                TriggerServerEvent('RM_GhostBlocked',
                  jsonEncode({ seconds = own.blocked }))
              end
              log('W', 'raceManager', string.format(
                'Reset ghost blocked for %.1fs: %s', own.blocked,
                tostring(ghost.blockReason or 'another car is in this space')))
            end
          else
            ghost.release('clear')
          end
        end
      end
    end
  end
  ghost.pushHud(dt)

  -- --- other people's ghosts ---------------------------------------------
  -- The server clock runs on between pushes (each broadcast re-anchors it), so
  -- the fade is smooth.
  ghost.serverTime = ghost.serverTime + dt
  for pid, endsAt in pairs(ghost.remote) do
    local vehId = ghost.remoteVeh[pid]
    if vehId then
      -- A lapsed ghost stays flat translucent: it is still intangible.
      local left = endsAt - ghost.serverTime
      ghost.left[vehId] = left > 0 and left or nil
      local got, veh = pcall(getObjectByID, vehId)
      if got and veh then ghost.fade(vehId, veh, ghost.alphaFor(vehId)) end
    end
  end

  -- --- re-assert sweep ----------------------------------------------------
  -- --- cars waiting to go solid -------------------------------------------
  -- Retried every 0.2 s until clear: wouldWeld measures every car on track.
  ghost.pendingIn = (ghost.pendingIn or 0) - dt
  if ghost.pendingIn <= 0 then
    ghost.pendingIn = 0.2
    for vehId in pairs(ghost.pending) do
      local got, veh = pcall(getObjectByID, vehId)
      veh = got and veh or nil
      if not veh then
        ghost.pending[vehId] = nil
      elseif ghost.veh[vehId] then
        -- A reason came back: it is a ghost on its own account again.
        ghost.pending[vehId] = nil
      elseif not ghost.wouldWeld(vehId, veh) then
        ghost.pending[vehId] = nil
        ghost.apply(vehId, veh, false, 1)
      end
    end
  end

  -- --- re-assert sweep -----------------------------------------------------
  -- Cars appear (a join, a respawn) after the event that ghosted them.
  ghost.refresh = ghost.refresh - dt
  if ghost.refresh > 0 then return end
  ghost.refresh = 2.0
  for reason in pairs(ghost.field) do setGhostReason(reason, true) end
  for pid, endsAt in pairs(ghost.remote) do ghost.applyRemote(pid, endsAt) end
  ghost.practiceSync()
end

-- ---------------------------------------------------------------------------
-- In-world gate visualization: one flat rectangle per checkpoint
-- ---------------------------------------------------------------------------
-- THE RENDERER, in its own module. Everything it needs is handed over ONCE, as
-- stable tables or plain functions: `track.route` is rebound, `track` is not.
local render = require('raceManager/render')

render.init({
  track = track, session = session, edit = edit, TUNE = TUNE,
  marker = marker, nudge = nudge, branch = branch, pit = pit,
  gateDims = gateDims, sampledVehicle = sampledVehicle,
  sessionRunning = sessionRunning, jokerClosed = jokerClosed,
})

-- The two this file calls directly. palette and drawStartPosition go straight
-- to the derby, not through locals.
local drawStartPositions = render.drawStartPositions
local drawGates          = render.drawGates

local derby = require('raceManager/derby')

-- Which editor targets belong to the ARENA (the server owns it). Declared here,
-- under the module: the derby init table below closes over it, and a local
-- declared further down would be a nil global to it.
local DERBY_TARGETS = { derbyMarker = true, derbyStart = true, derbyCenter = true }

-- Console: raceManager.inputDiag(). Every filter group here is recomputed from
-- live state each frame, so dead inputs mean wrong STATE, not a stuck filter.
-- Prints what this mod armed AND what the engine reports: an action blocked
-- that none of ours covers is BeamNG's or BeamMP's filter, not this mod.
function M.inputDiag()
  local function line(s) log('I', 'raceManager', s); print('[RaceManager] ' .. s) end
  line('--- input diagnosis ---')
  line('phase: ' .. tostring(session.phase)
    .. ', spectatorLock: ' .. tostring(session.spectatorLock)
    .. ', derby phase: ' .. tostring(derby.derbyState and derby.derbyState.phase)
    .. ', derby out: ' .. tostring(derby.derbyState and derby.derbyState.out)
    .. ', derby stood down: ' .. tostring(derby.derbyState and derby.derbyState.stoodDown))
  line('resets: ' .. tostring(session.resetsUsed) .. '/' .. tostring(session.maxResets)
    .. ', derby resets: ' .. tostring(derbyResets.used) .. '/' .. tostring(derbyResets.max))

  -- What THIS FILE believes it has armed.
  local groups = {
    { 'raceManagerSpectate',   spectate.blocked,           spectate.DRIVE },
    { 'raceManagerPropulsion', spectate.propulsionBlocked, spectate.PROPULSION },
    { 'raceManagerGrabber',    spectate.grabBlocked,       spectate.GRAB },
    { 'raceManagerResets',     block.resetInputs,          block.RESET_ACTIONS },
    { 'raceManagerTeleport',   block.teleportInputs,       block.TELEPORT_ACTIONS },
  }
  for _, g in ipairs(groups) do
    line(string.format('  %-22s %s (%d action%s)', g[1],
      g[2] and 'BLOCKED' or 'released', #g[3], #g[3] == 1 and '' or 's'))
  end

  -- ...and what the engine says. Blocked while ours is released: somebody else.
  if not (core_input_actionFilter and core_input_actionFilter.isActionBlocked) then
    line('core_input_actionFilter.isActionBlocked is absent: this build cannot be '
      .. 'asked, and every filter call this mod makes may be doing nothing')
    return
  end
  local blocked, n = {}, 0
  for _, g in ipairs(groups) do
    for _, action in ipairs(g[3]) do
      local ok, is = pcall(core_input_actionFilter.isActionBlocked, action)
      if ok and is then blocked[#blocked + 1] = action; n = n + 1 end
    end
  end
  table.sort(blocked)
  line('engine reports blocked (' .. n .. '): '
    .. (n > 0 and table.concat(blocked, ', ') or 'nothing this mod covers'))
  -- Steering and reset by name: pad and keyboard use different actions.
  for _, pair in ipairs({
    { 'steering (pad/wheel)', 'steering' },
    { 'steer left (kbd)',     'steer_left' },
    { 'steer right (kbd)',    'steer_right' },
    { 'throttle (pad)',       'throttle' },
    { 'accelerate (kbd)',     'accelerate' },
    { 'recover_vehicle',      'recover_vehicle' },
    { 'reset_physics',        'reset_physics' },
    { 'recover_to_last_road', 'recover_to_last_road' },
  }) do
    local ok, is = pcall(core_input_actionFilter.isActionBlocked, pair[2])
    line(string.format('  %-22s %s', pair[1],
      (not ok) and 'could not be asked' or (is and 'BLOCKED' or 'free')))
  end
end

derby.init({
  -- Plain functions.
  palette = render.palette, drawStartPosition = render.drawStartPosition,
  -- The countdown for the Lights app. Through M: lights.lua installs further down.
  lightsCountdown = function (n) if M.lightsCountdown then M.lightsCountdown(n, true) end end,
  -- ownVehicle() for anything that moves, freezes, measures or places;
  -- playerVehicle() only for questions about the camera.
  playerVehicle = playerVehicle, ownVehicle = ownVehicle,
  vehiclePlacement = vehiclePlacement,
  -- The arena point the mouse holds, or nil (always nil for track targets). The
  -- derby draws its own highlight so its cached geometry is not rebuilt.
  nudgePick = function ()
    if not (nudge.on and nudge.sel and DERBY_TARGETS[edit.target]) then return nil end
    local list = derby.editList(edit.target)
    return list and list[nudge.sel] or nil
  end,
  placeOnStartPosition = placeOnStartPosition,
  setLocalVehicleFrozen = setLocalVehicleFrozen,
  queueFieldPlacement = queueFieldPlacement, pushNotice = pushNotice,
  inMultiplayer = inMultiplayer, localServerId = localServerId,
  fromCurrentServer = fromCurrentServer,
  releaseGridHold = releaseGridHold, requestHold = requestHold,
  -- A derby forming ends practice (assigned further down).
  practiceStop = function (why) practice.stop(why) end,
  -- Mutable scalars this file owns: getters, never values.
  phase = function () return session.phase end,
  isAdmin = function () return session.isAdmin end,
  editorOpen = function () return edit.open end,
  visualize = function () return edit.visualize end,
  maxResets = function () return session.maxResets end,
  -- Tables, by reference, so both halves see the same object.
  spectate = spectate,
  -- A getter: track.startPositions is reassigned when a layout loads.
  startPositions = function () return track.startPositions end,
  -- Shared by reference: the reset code polices both through one path.
  resets = derbyResets,
})

-- Not aliased into locals: each alias costs a slot and captures the function at
-- load time. The UI reaches the module's entry points through M.
for _, name in ipairs({
  'derbyAddMarker', 'derbyAddStartPosition', 'derbyClearBoundary',
  'derbyClearStartPositions', 'derbyDeleteLayout', 'derbyEnd',
  'derbyFormUp', 'derbyLoadLayout', 'derbyMoveMarker',
  'derbyMoveStartPosition', 'derbyPreviewMarker', 'derbyPreviewStartPosition',
  'derbyRemoveMarker', 'derbyRemoveStartPosition', 'derbyRequestLayouts',
  'derbyRequestState', 'derbySaveLayout', 'derbySetBoundaryMode',
  'derbySetConfig', 'derbySetShape',
  'derbySetShapeCenter', 'derbyStart', 'derbyToggleVisualize',
  'setDerbyEditorOpen', 'derbyReady', 'derbyReadyDriver', 'derbyReadyAll',
}) do
  M[name] = derby[name]
end


local drag = require('raceManager/drag')

drag.init({
  -- Plain functions.
  inMultiplayer = inMultiplayer, fromCurrentServer = fromCurrentServer,
  -- The tree for the Lights app. Through M: lights.lua installs further down.
  lightsTree = function (t) if M.lightsTree then M.lightsTree(t) end end,
  localServerId = localServerId,
  sampledVehicle = sampledVehicle, pushNotice = pushNotice,
  -- The staging steps, straight to the game's Messages app (drag.lua).
  hudMessage = hudMessage,
  ownVehicle = ownVehicle,
  queueFieldPlacement = queueFieldPlacement,
  releaseGridHold = releaseGridHold, requestHold = requestHold,
  segmentCrossesGate = segmentCrossesGate,
  -- Is this car still landing? A getter: `field` is this file's alone.
  placementActive = function () return field.active end,
  -- Getters, not references: track.route and track.startPositions are
  -- REASSIGNED when a layout loads (tests/wiring_test.lua checks this).
  finishGate = function ()
    local n = #track.route
    return n > 0 and track.route[n] or nil
  end,
  startPositions = function () return track.startPositions end,
})

-- Not aliased into locals (see the derby).
for _, name in ipairs({
  'dragAbort', 'dragBuild', 'dragClear', 'dragPractice', 'dragRequestState',
  'dragRun', 'dragSetConfig', 'dragSetDial', 'dragSetStaging', 'dragStage',
  'dragWithdraw', 'dragReady', 'dragReadyDriver', 'dragReadyAll',
}) do
  M[name] = drag[name]
end

-- Map switching, in a block so the handle is not a top-level local.
do
  local maps = require('raceManager/maps')
  maps.init({ inMultiplayer = inMultiplayer })
  for _, name in ipairs({
    'mapRequest', 'mapSwitch', 'mapCancel', 'onMaps',
    'mapVoteStart', 'mapVote', 'mapVoteCancel', 'mapVoteConfig', 'mapRename',
  }) do
    M[name] = maps[name]
  end
end

-- Lap records, the same way. onRecords is the RM_Records handler.
do
  local records = require('raceManager/records')
  records.init({ inMultiplayer = inMultiplayer })
  for _, name in ipairs({
    'recordsRequest', 'recordsClear', 'recordsRemove', 'onRecords',
  }) do
    M[name] = records[name]
  end
end

-- The Lights app's light and the start sounds, the same way. See lights.lua.
do
  local lights = require('raceManager/lights')
  lights.init({
    session = session,
    -- Behind the pace car GO is not a green. paceLap is the rule; the server
    -- arms it for a race only, and never on a point-to-point stage.
    pacedStart = function ()
      return session.paceLap and session.sessionKind == 'race' and not track.pointToPoint
    end,
  })
  for _, name in ipairs({
    'lightsSync', 'lightsCountdown', 'lightsMoment', 'lightsTree',
    'lightsResend', 'lightsSetSound',
  }) do
    M[name] = lights[name]
  end
end

-- The Radar app's cars, the same way. See radar.lua.
do
  local radar = require('raceManager/radar')
  radar.init({
    ownVehicle = ownVehicle, forEachVehicle = forEachVehicle, myPid = localServerId,
    isTowed = function (veh) return towed.is(veh) end,
    -- Getters: these tables are all reassigned.
    isGhost = function (id) return ghost.applied[id] == true end,
    rows = function () return session.drivers end,
    slots = function () return #track.route end,
    racing = function () return session.phase == 'racing' and session.sessionKind ~= 'quali' end,
    -- Nothing to show around a car that is gone or parked as a finished ghost.
    quiet = function () return session.spectatorLock ~= nil or ghost.finishedOwn ~= nil end,
  })
  M.radarUpdate = radar.radarUpdate
  M.radarForget = radar.forget
end

-- The welcome splash, the same way. See splash.lua.
do
  local splash = require('raceManager/splash')
  for _, name in ipairs({ 'splashOffer', 'splashReset', 'splashShow', 'splashUpdate' }) do
    M[name] = splash[name]
  end
end

-- Props get their host here, once groundAt and the renderer exist.
props.init({
  groundAt = groundAt, ownVehicle = ownVehicle, palette = render.palette,
  -- Ghosts while being edited, so the ground probes see the road.
  editing = function ()
    return edit.open and session.isAdmin and edit.target == 'prop'
  end,
  -- No collision rebuild (a hitch) while anybody is racing.
  busy = function ()
    local d = derby.derbyState.phase
    local g = drag.dragState and drag.dragState.phase
    return edit.running() or d == 'forming' or d == 'countdown' or d == 'running'
      or g == 'staging' or g == 'tree' or g == 'running'
  end,
  overlay = function ()
    return edit.open and session.isAdmin and edit.visualize and edit.target == 'prop'
  end,
  selected = function (i)
    return nudge.on and nudge.sel == i and nudge.list == props.list
  end,
})

-- After joining, ask for the live state once the socket is up.
local function joinRequestUpdate(dt)
  if not joinRequestLeft then return end
  joinRequestLeft = joinRequestLeft - dt
  if joinRequestLeft > 0 then return end
  joinRequestLeft = nil
  M.requestState()
  -- The drag ladder too: its own channel, pushed only on a change.
  drag.dragRequestState()
  -- And whether a map vote is running or voting is locked, for the vote band.
  M.mapRequest(false)
end

function M.onUpdate(dt)
  localTime = localTime + dt
  stickyUpdate(dt)          -- conditions held on the HUD: pace lap, caution, restart
  joinRequestUpdate(dt)     -- deferred state request after joining a server
  checkGates()
  lapTimerUpdate(dt)        -- live lap clock for this driver's own HUD
  whiteFlagWatch()          -- the last-lap flag, waved on the approach
  reportProgress(dt)        -- live position telemetry (distance to next gate)
  drawGates(derby.derbyState.phase == 'running')
  drawStartPositions()      -- starting grid slots
  nudge.update()            -- mouse editing, only while the mode is on
  fieldUpdate(dt)           -- ghosted, staggered grid placement / mass respawn
  holdUpdate(dt)            -- grid hold: verify it is holding, report position
  pit.update(dt)            -- pit stalls: hold, repair in place, release
  snapshotUpdate(dt)        -- Module 1: rolling "last good position"
  resetGuardUpdate(dt)      -- Module 1: teleport-echo window + notice throttle
  resetInputBlockUpdate()   -- Module 1: dead reset keys once the allowance is gone
  spectatorUpdate(dt)       -- Module 1: follow the spectate target when it goes
  -- The node grabber is off for the whole of a derby -- form-up, countdown and
  -- running -- not just while the cars are moving. Dragging a car into position
  -- on the grid before GO is the same cheat with better timing.
  spectate.setGrabberBlocked(derby.derbyState.phase == 'forming'
    or derby.derbyState.phase == 'countdown' or derby.derbyState.phase == 'running')
  ghostUpdate(dt)           -- ghost mode qualifying
  ghost.respawnUpdate(dt)   -- derby respawn ghosts, on the local clock
  vehicleConfigUpdate(dt)   -- Module 4: declare setup changes to the server
  derby.derbyUpdate(dt)
  derby.derbyDrawBoundary()
  -- The drag pass: the tree, the launch, the finish line and the trap speed.
  -- Costs one comparison a frame when no ladder is running.
  drag.dragUpdate(dt)
  -- The Radar app: a scan four times a second alone, twenty with a car near.
  if M.radarUpdate then M.radarUpdate(dt) end
  M.splashUpdate(dt)        -- the welcome splash, only while it is up
  -- Props: the world follows props.list; the overlay only on the Props tab.
  props.update(dt)
  props.draw()
end

-- Checkpoint editor API (called by the UI app)
-- ---------------------------------------------------------------------------
-- Console: dump(raceManager.ghostStatus()). Why is this car still a ghost:
-- which source measures the space around it (`boundsFrom`), and what blocks
-- the restore.
function M.ghostStatus()
  local veh = ownVehicle()
  local measured, how = false, 'no vehicle'
  if veh then
    if ghost.bounds(veh, 0) then measured = true end
    local okA, bbA = pcall(function () return veh:getSpawnWorldOOBB() end)
    local okB, bbB = pcall(function () return veh:getWorldBox() end)
    local okC = pcall(function () return veh:getInitialLength() end)
    how = (okA and bbA and 'spawnWorldOOBB')
      or (okB and bbB and 'worldBox')
      or (okC and 'vehicle dimensions')
      or 'nothing - falling back to a plain radius'
  end
  local ghosted = 0
  for _ in pairs(ghost.veh) do ghosted = ghosted + 1 end
  local reasons = {}
  for r in pairs(ghost.field) do reasons[#reasons + 1] = r end
  return {
    ownGhosted     = ghost.own.vehId ~= nil,
    settling       = ghost.own.settling,
    secondsLeft    = ghost.own.left,
    blockedFor     = ghost.own.blocked,
    blockReason    = ghost.blockReason,
    boundsMeasured = measured,
    boundsFrom     = how,
    carsGhosted    = ghosted,
    fieldReasons   = table.concat(reasons, ','),
    phase          = session.phase,
    ghostQuali     = ghostQuali,
  }
end

function M.setEditorOpen(open)
  edit.open = open == true
  -- A closed editor cannot keep the mouse.
  if not edit.open then nudge.release() end
end

-- Sprint or circuit, and whether the sprint is a drag strip. Told to the
-- server, which owns the lap count.
function M.setPointToPoint(on, drag)
  track.pointToPoint = on == true
  track.dragStrip    = track.pointToPoint and drag == true
  render.invalidateLabels()      -- the gate labels say which mode this is
  if inMultiplayer() then
    TriggerServerEvent('RM_SetPointToPoint', jsonEncode({
      enabled = track.pointToPoint, drag = track.dragStrip,
    }))
  end
  pushRouteState()
  log('I', 'raceManager', 'Track mode: ' .. (track.dragStrip and 'DRAG STRIP'
    or track.pointToPoint and 'POINT TO POINT' or 'circuit'))
end

function M.setEditorTarget(target)
  target = tostring(target or 'main')
  if target ~= 'joker' and target ~= 'start' and target ~= 'pit'
     and target ~= 'pitEntry' and target ~= 'pitExit'
     and target ~= 'branch' and target ~= 'marker' and target ~= 'prop'
     and not DERBY_TARGETS[target] then target = 'main' end
  edit.target = target
  pushRouteState()
  log('I', 'raceManager', 'Editor target: ' .. edit.target)
end

local function activeEditorRoute()
  -- The arena's lists first (the derby module answers nil for track targets).
  if DERBY_TARGETS[edit.target] then
    return derby.editList(edit.target) or {}
  end
  if edit.target == 'joker' then return track.jokerRoute end
  if edit.target == 'pit'   then return track.pitRoute end
  if edit.target == 'pitEntry' then return track.pitEntry end
  if edit.target == 'pitExit'  then return track.pitExit end
  if edit.target == 'start' then return track.startPositions end
  if edit.target == 'branch' then return branch.list end
  if edit.target == 'marker' then return marker.list end
  if edit.target == 'prop' then return props.list end
  return track.route
end

-- Nudge mode's behavior (the table is declared at the top: the frame loop and
-- the drawing reach it from above here).
-- The cursor helpers are lua/ge/client/canvas.lua, reached with
-- require('client/canvas'); there is NO core_canvas global. Resolved once and
-- remembered as false: a failed require walks the whole package path.
function nudge.canvas()
  if nudge.cv ~= nil then return nudge.cv or nil end
  local ok, mod = pcall(require, 'client/canvas')
  nudge.cv = (ok and type(mod) == 'table' and type(mod.showCursor) == 'function')
    and mod or false
  return nudge.cv or nil
end

-- Was the cursor free when we arrived? No Lua getter exists, so this probes the
-- Canvas; nil means unknown (see nudge.release).
function nudge.cursorFree()
  local ok, on = pcall(function ()
    local c = scenetree and scenetree.findObject('Canvas')
    return c and c:isCursorOn()
  end)
  if ok and type(on) == 'boolean' then return on end
  return nil
end

-- Show or hide the cursor; lockMouse alone still frees the mouse from the
-- camera, which is the half that matters.
function nudge.cursor(show)
  local cv = nudge.canvas()
  if cv then
    local ok = pcall(function ()
      if show then cv.showCursor() else cv.hideCursor() end
    end)
    if ok then return true end
  end
  if type(lockMouse) == 'function' then
    return pcall(lockMouse, not show) and true or false
  end
  return false
end

-- Which pieces are missing, named, so a refusal says what.
function nudge.missing()
  local gaps = {}
  local okIm, im = pcall(function () return ui_imgui end)
  nudge.im = (okIm and type(im) == 'table' and type(im.IsMouseDown) == 'function')
    and im or nil
  if not nudge.im then gaps[#gaps + 1] = 'ui_imgui' end
  if type(cameraMouseRayCast) ~= 'function' then gaps[#gaps + 1] = 'cameraMouseRayCast' end
  if not (nudge.canvas() or type(lockMouse) == 'function') then
    gaps[#gaps + 1] = 'the cursor lock'
  end
  return gaps
end

function nudge.available()
  if nudge.ready ~= nil then return nudge.ready end
  local gaps = nudge.missing()
  nudge.ready = (#gaps == 0)
  if not nudge.ready then
    log('W', 'raceManager', 'Nudge mode unavailable, missing: '
      .. table.concat(gaps, ', '))
  end
  return nudge.ready
end

-- Give the mouse back, on every exit. RE-LOCK ONLY when the probe positively
-- said it was locked when we arrived: re-locking a cursor the admin already had
-- free left them unable to click anything. Unknown leaves it free.
function nudge.release()
  if not nudge.on then return end
  -- Send anything un-sent, or the panel and the arena disagree.
  nudge.flush()
  if nudge.routeDirty then nudge.routeDirty = false; pushRouteState() end
  nudge.on, nudge.sel, nudge.dragging, nudge.list = false, nil, false, nil
  if nudge.wasFree == false then
    nudge.cursor(false)
    log('I', 'raceManager', 'Nudge mode off, mouse handed back to the camera')
  else
    log('I', 'raceManager', 'Nudge mode off, cursor left free (it was not ours to take)')
  end
  nudge.wasFree = nil
end

function nudge.set(on)
  on = on and true or false
  if on == nudge.on then return end
  if not on then nudge.release(); pushRouteState(); return end
  if not nudge.available() then
    guihooks.trigger('RaceManagerEditorMsg', {
      msg = 'Place mode cannot start, missing: ' .. table.concat(nudge.missing(), ', ') })
    return
  end
  nudge.on, nudge.sel, nudge.dragging = true, nil, false
  -- Recorded BEFORE the cursor is touched.
  nudge.wasFree = nudge.cursorFree()
  nudge.cursor(true)
  log('I', 'raceManager', 'Nudge mode on, mouse released from the camera')
  pushRouteState()
end

-- Nearest gate to the cursor ray by perpendicular distance to its center; not
-- behind the camera.
function nudge.pick(list, ray)
  if not (ray and ray.pos and ray.dir) then return nil end
  local ox, oy, oz = ray.pos.x, ray.pos.y, ray.pos.z
  local dx, dy, dz = ray.dir.x, ray.dir.y, ray.dir.z
  local dlen = math.sqrt(dx * dx + dy * dy + dz * dz)
  if dlen < 1e-6 then return nil end
  dx, dy, dz = dx / dlen, dy / dlen, dz / dlen
  local best, bestD = nil, nudge.PICK_RADIUS
  for i, wp in ipairs(list) do
    local vx, vy, vz = wp.x - ox, wp.y - oy, wp.z - oz
    local along = vx * dx + vy * dy + vz * dz
    if along > 0 then
      local px, py, pz = vx - dx * along, vy - dy * along, vz - dz * along
      local d = math.sqrt(px * px + py * py + pz * pz)
      if d < bestD then best, bestD = i, d end
    end
  end
  return best
end

-- Turn a gate in place, renormalized: a drifted heading changes the gate width.
function nudge.turn(wp, radians)
  if not wp then return end
  local hx, hy = tonumber(wp.hx) or 0, tonumber(wp.hy) or 1
  local c, s = math.cos(radians), math.sin(radians)
  local nx, ny = hx * c - hy * s, hx * s + hy * c
  local len = math.sqrt(nx * nx + ny * ny)
  if len < 1e-6 then return end
  wp.hx, wp.hy = nx / len, ny / len
end

-- Where the cursor ray crosses the horizontal plane at `z`. A DRAG FOLLOWS THIS,
-- not the world raycast, which jumps between ground and canopy over trees. The
-- drag moves a gate at its own height; height is the wheel's and buttons' job.
-- nil when the ray is too flat to meet the plane.
function nudge.planeAt(ray, z)
  if not (ray and ray.pos and ray.dir) then return nil end
  local dz = ray.dir.z
  if not dz or math.abs(dz) < 1e-4 then return nil end
  local t = (z - ray.pos.z) / dz
  if t <= 0 or t > TUNE.NUDGE_MAX_REACH * 4 then return nil end
  return ray.pos.x + ray.dir.x * t, ray.pos.y + ray.dir.y * t
end

-- Move a gate keeping its height above the ground. `newGround` is probed from
-- the gate's own height (below any canopy) by the caller; hit.z over trees is
-- the treetops.
function nudge.moveTo(wp, hit, ground, newGround)
  if not (wp and hit) then return end
  local lift = wp.z - (ground or wp.z)
  wp.x, wp.y = hit.x, hit.y
  wp.z = (newGround or hit.z) + lift
end

-- Heading for a clicked gate: from the gate it follows toward the new point, so
-- clicking along a road faces each gate down it. The first gate takes the
-- camera's flattened direction.
function nudge.headingFor(list, x, y, ray, after)
  local prev = after or list[#list]
  if prev then
    local dx, dy = x - prev.x, y - prev.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 1e-3 then return dx / len, dy / len end
  end
  if ray and ray.dir then
    local dx, dy = ray.dir.x, ray.dir.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 1e-3 then return dx / len, dy / len end
  end
  return 0, 1
end

-- Ctrl+click: a new gate there, appended, or inserted after the selected gate.
-- Goes through the ordinary editor entry points.
function nudge.place(list, hit, ray)
  if not (hit and hit.pos) then return end
  local x, y = hit.pos.x, hit.pos.y
  -- The ray lands on the ground; a gate clears it like a driven one.
  local z = liftAboveGround(x, y, hit.pos.z, TUNE.GROUND_CLEAR)
  -- Headed from the gate it goes AFTER (an insert with a selection), not the
  -- last gate of the route.
  local after = (nudge.sel and edit.target ~= 'branch') and list[nudge.sel] or list[#list]
  local hx, hy = nudge.headingFor(list, x, y, ray, after)
  local place = { x = x, y = y, z = z, hx = hx, hy = hy }
  -- The arena is the server's: request it and draw what the broadcast returns.
  -- The selection is left alone; the new index is unknown until then.
  if DERBY_TARGETS[edit.target] then
    derby.editPlace(edit.target, place)
    nudge.dragging = false
    return
  end
  -- A branch gate belongs to a slot, not an order: always an add.
  if nudge.sel and edit.target ~= 'branch' then
    local at = nudge.sel + 1
    M.insertCheckpoint(at, place)
    nudge.sel = at
  else
    M.editorAdd(place)
    nudge.sel = #list
  end
  nudge.dragging = false
  pushRouteState()
end

-- Send an arena edit ONCE, when it stops moving: a drag moves the local copy
-- every frame, and every frame to the server would be a lobby broadcast.
-- `nudge.pending` is the index that moved, which the selection may not be.
function nudge.flush()
  local i = nudge.pending
  nudge.pending = nil
  if not i then return end
  if not DERBY_TARGETS[edit.target] then return end
  local list = derby.editList(edit.target)
  local wp = list and list[i]
  if wp then derby.editMove(edit.target, i, wp) end
end

-- Turn the picked gate from the panel (for a mouse with no wheel). `dir` -1 or 1.
function M.nudgeTurn(dir)
  -- Only from the panel: ignore the world click this CEF click also produced.
  nudge.uiGrace = TUNE.NUDGE_UI_GRACE
  if not (nudge.on and nudge.sel and nudge.list) then return end
  local wp = nudge.list[nudge.sel]
  if not wp then return end
  nudge.turn(wp, (tonumber(dir) or 1) >= 0 and nudge.TURN_PER_STEP or -nudge.TURN_PER_STEP)
  if edit.target == 'branch' then branch.rebuild() end
  -- One discrete change: send it now.
  if DERBY_TARGETS[edit.target] then
    nudge.pending = nudge.sel
    nudge.flush()
  end
  pushRouteState()
end

-- Raise or lower the picked gate from the panel, floored like shift+scroll so
-- it can dig a gate out but never bury one.
function M.nudgeLift(dir)
  -- Only from the panel (see nudgeTurn).
  nudge.uiGrace = TUNE.NUDGE_UI_GRACE
  if not (nudge.on and nudge.sel and nudge.list) then return end
  local wp = nudge.list[nudge.sel]
  if not wp then return end
  -- A prop rests ON the ground; a gate clears it.
  local clear = (edit.target == 'prop') and 0 or TUNE.GROUND_CLEAR
  if (tonumber(dir) or 1) >= 0 then
    wp.z = liftAboveGround(wp.x, wp.y, wp.z + TUNE.NUDGE_LIFT_PER_PRESS, clear)
  else
    wp.z = lowerToGround(wp.x, wp.y, wp.z, TUNE.NUDGE_LIFT_PER_PRESS, clear)
  end
  if edit.target == 'branch' then branch.rebuild() end
  if DERBY_TARGETS[edit.target] then
    nudge.pending = nudge.sel
    nudge.flush()
  end
  pushRouteState()
end

-- Delete the picked gate, from the panel rather than a guessed keybind.
function M.nudgeDelete()
  -- Reached only from the panel: see the note on nudgeTurn.
  nudge.uiGrace = TUNE.NUDGE_UI_GRACE
  if not (nudge.on and nudge.sel) then return end
  local i = nudge.sel
  nudge.sel, nudge.dragging = nil, false
  if DERBY_TARGETS[edit.target] then
    derby.editRemove(edit.target, i)
    pushRouteState()
    return
  end
  if edit.target == 'start' then
    M.removeStartPosition(i)
  else
    M.removeCheckpoint(i)
  end
  pushRouteState()
end

-- One frame of the mode, fully guarded: a throw here takes the mod down.
function nudge.update()
  if not nudge.on then return end
  -- Ends when its editor closes, the admin logs out or a session starts. The
  -- arena's targets need the Derby Editor open, the track's the track editor.
  local ownerOpen
  if DERBY_TARGETS[edit.target] then
    ownerOpen = derby.derbyState.editorOpen
  else
    ownerOpen = edit.open
  end
  if not (ownerOpen and session.isAdmin) or sessionRunning() then
    nudge.release()
    return
  end
  local im = nudge.im
  if not im then return end
  -- Never steal a click meant for a UI panel.
  local wantsUi = false
  pcall(function () wantsUi = im.GetIO().WantCaptureMouse end)
  -- A panel press cannot become a drag (the grace may arrive a frame late; a
  -- drag needs several frames of held movement anyway).
  if nudge.uiGrace > 0 then
    nudge.uiGrace = nudge.uiGrace - 1
    nudge.dragging = false
    nudge.grabX, nudge.grabY = nil, nil
  end

  local list = activeEditorRoute()
  nudge.list = list
  local ray, hit
  pcall(function () ray = getCameraMouseRay() end)
  pcall(function () hit = cameraMouseRayCast(false) end)

  local down, held, up = false, false, false
  pcall(function ()
    down = im.IsMouseClicked(0)
    held = im.IsMouseDown(0)
    up   = im.IsMouseReleased(0)
  end)

  local ctrl = false
  pcall(function () ctrl = im.GetIO().KeyCtrl == true end)

  -- Ctrl+click PLACES, checked first so one click never places and then drags.
  if down and ctrl and not wantsUi then
    nudge.place(list, hit, ray)
    return
  end

  -- A click that picks nothing keeps the selection: a panel press arrives here
  -- as a world click too, and clearing on a miss greyed out the buttons.
  if down and not wantsUi and nudge.uiGrace <= 0 then
    local picked = nudge.pick(list, ray)
    if picked and picked ~= nudge.sel then
      nudge.sel = picked
      pushRouteState()
    end
    nudge.dragging = picked ~= nil
    -- Where the cursor was at the grab. A drag moves the gate BY the cursor's
    -- travel, never TO the ray hit (it passes through the gate to the ground
    -- behind, which teleported gates under the map; a click is several frames).
    local wpSel = picked and list[picked]
    if wpSel then
      nudge.grabX, nudge.grabY = nudge.planeAt(ray, wpSel.z)
    else
      nudge.grabX, nudge.grabY = nil, nil
    end
  end
  if up then
    nudge.dragging = false
    nudge.grabX, nudge.grabY = nil, nil
    -- A drag ending is when the arena's owner is told.
    nudge.flush()
  end

  local wp = nudge.sel and list[nudge.sel]
  if not wp then
    if nudge.sel ~= nil then
      nudge.sel, nudge.dragging = nil, false
      pushRouteState()
    end
    nudge.dragging = false
    return
  end

  -- No early returns: the scroll handling shares this frame. A drag is purely
  -- horizontal on the gate's own plane; the floor can only lift it out of a hill.
  if nudge.dragging and held and nudge.grabX then
    local cx, cy = nudge.planeAt(ray, wp.z)
    if cx then
      local dx, dy = cx - nudge.grabX, cy - nudge.grabY
      local d2 = dx * dx + dy * dy
      if d2 > TUNE.NUDGE_MAX_REACH * TUNE.NUDGE_MAX_REACH then
        -- The plane crossing shot off past the horizon: re-anchor, do not apply.
        nudge.grabX, nudge.grabY = cx, cy
      elseif d2 >= TUNE.NUDGE_DRAG_MIN * TUNE.NUDGE_DRAG_MIN then
        nudge.grabX, nudge.grabY = cx, cy
        wp.x, wp.y = wp.x + dx, wp.y + dy
        -- Dragged into rising ground: lift only. A prop follows the ground.
        if edit.target == 'prop' then
          props.seat(wp)
        else
          wp.z = liftAboveGround(wp.x, wp.y, wp.z, TUNE.GROUND_CLEAR)
        end
        if edit.target == 'branch' then branch.rebuild() end
        if edit.target == 'start' then branch.gridTool.generated = false end
        -- Noted, not sent: nudge.flush sends it on release.
        if DERBY_TARGETS[edit.target] then nudge.pending = nudge.sel end
        nudge.routeDirty = true
      end
    end
  end
  -- The world draws the local copy every frame; the panel hears a drag every
  -- few frames and once more when it ends.
  if nudge.routeDirty then
    nudge.pushIn = (nudge.pushIn or 0) - 1
    if nudge.pushIn <= 0 or not nudge.dragging then
      nudge.routeDirty, nudge.pushIn = false, TUNE.NUDGE_PUSH_FRAMES
      pushRouteState()
    end
  end

  -- Scroll turns the selected gate; SHIFT+SCROLL raises and lowers it, the only
  -- control that moves a gate vertically (the size sliders set its extent, not
  -- its position, and cannot dig a buried gate out).
  local wheel, shift = 0, false
  pcall(function ()
    local io_ = im.GetIO()
    wheel = io_.MouseWheel or 0
    shift = io_.KeyShift == true
  end)
  if wheel ~= 0 and not wantsUi then
    if shift then
      -- Floored at ground clearance; see lowerToGround for the two helpers.
      local clear = (edit.target == 'prop') and 0 or TUNE.GROUND_CLEAR
      if wheel > 0 then
        wp.z = liftAboveGround(wp.x, wp.y,
          wp.z + wheel * TUNE.NUDGE_LIFT_PER_STEP, clear)
      else
        wp.z = lowerToGround(wp.x, wp.y, wp.z,
          -wheel * TUNE.NUDGE_LIFT_PER_STEP, clear)
      end
    else
      nudge.turn(wp, wheel * nudge.TURN_PER_STEP)
    end
    if edit.target == 'branch' then branch.rebuild() end
    pushRouteState()
  end
end

-- Rebuild slot -> branch gates after every edit, so the editor and the crossing
-- code agree. A slot with none gets no entry (the crossing path tests for nil).
function branch.rebuild()
  local bySlot = {}
  for _, g in ipairs(branch.list) do
    local slot = tonumber(g.slot)
    if slot then
      slot = math.floor(slot)
      local at = bySlot[slot]
      if not at then at = {}; bySlot[slot] = at end
      at[#at + 1] = g
    end
  end
  branch.bySlot = bySlot
end

-- The lowest checkpoint with no branch gate yet, for drive-and-click mirror laps.
function branch.nextFreeSlot()
  for i = 1, math.max(#track.route, 1) do
    if not branch.bySlot[i] then return i end
  end
  return math.max(#track.route, 1)
end

-- Which checkpoint the next placed branch gate belongs to.
function M.setBranchSlot(slot)
  slot = math.floor(tonumber(slot) or 1)
  if slot < 1 then slot = 1 end
  if #track.route > 0 and slot > #track.route then slot = #track.route end
  branch.editSlot = slot
  pushRouteState()
end

-- Re-point a placed branch gate at another checkpoint (two on one is fine).
function M.setBranchGateSlot(index, slot)
  index = math.floor(tonumber(index) or 0)
  local g = branch.list[index]
  if not g then return end
  slot = math.floor(tonumber(slot) or 1)
  if slot < 1 then slot = 1 end
  if #track.route > 0 and slot > #track.route then slot = #track.route end
  g.slot = slot
  branch.rebuild()
  pushRouteState()
end

-- Drop one branch gate; its checkpoint keeps its other gates.
function M.removeBranchGate(index)
  index = math.floor(tonumber(index) or 0)
  if not branch.list[index] then return end
  table.remove(branch.list, index)
  branch.rebuild()
  pushRouteState()
  log('I', 'raceManager', 'Branch gate ' .. index .. ' removed')
end

-- Place at the car (or `place`). A gate's size is fixed HERE, inherited from
-- the gate before it, never read live from a global (a slider once resized a
-- whole circuit retroactively). Start positions get no dimensions.
function M.editorAdd(place)
  local driven = place == nil
  place = place or vehiclePlacement()
  if not place then
    log('W', 'raceManager', 'Editor: no player vehicle, cannot place')
    return
  end
  local target = activeEditorRoute()
  -- A prop has no gate size; a driven one goes in front of the car.
  if edit.target == 'prop' then
    target[#target + 1] = props.fromPlace(place, driven)
    pushRouteState()
    return
  end
  if edit.target ~= 'start' then
    local prev = target[#target]
    place.width  = clampWidth(prev and prev.width  or track.checkpointWidth)
    place.height = clampHeight(prev and prev.height or track.checkpointHeight)
    place.depth  = clampDepth(prev and prev.depth  or track.checkpointDepth)
    if edit.target == 'pit' then pit.sizeFrom(place, prev) end
  end
  -- A branch gate is placed AGAINST a checkpoint, and a second one ADDS another
  -- way through it (moving is Nudge or Move Here).
  if edit.target == 'branch' then
    if #track.route == 0 then
      guihooks.trigger('RaceManagerEditorMsg', { msg = 'Place the main route first' })
      return
    end
    local slot = math.floor(branch.editSlot or 1)
    if slot < 1 then slot = 1 end
    if slot > #track.route then slot = #track.route end
    place.slot = slot
    branch.list[#branch.list + 1] = place
    branch.rebuild()
    branch.editSlot = branch.nextFreeSlot()
    pushRouteState()
    log('I', 'raceManager', 'Branch gate added for CP ' .. slot)
    return
  end
  -- A marker takes the editor's current symbol, changeable afterwards.
  if edit.target == 'marker' then
    place.kind = marker.validKind(marker.kind) or 'right'
  end
  target[#target + 1] = place
  -- A hand-placed slot ends the generator's ownership of the grid.
  if edit.target == 'start' then branch.gridTool.generated = false end
  pushRouteState()
end

-- `index` nil sets the symbol for the next marker; a number re-labels that
-- placed marker without moving it.
function M.setMarkerKind(kind, index)
  local k = marker.validKind(kind)
  if not k then return end
  local i = tonumber(index)
  if i then
    i = math.floor(i)
    local m = marker.list[i]
    if not m then return end
    m.kind = k
    log('I', 'raceManager', 'Marker ' .. i .. ' set to ' .. k)
  else
    marker.kind = k
    log('I', 'raceManager', 'Next marker will be ' .. k)
  end
  pushRouteState()
end

-- `index` nil sets what the next prop is; a number swaps that placed prop.
function M.setPropKind(kind, index)
  if props.setKind(kind, index) then pushRouteState() end
end

-- A ghost prop is drawn and never collides: a guide, not a wall.
function M.setPropSolid(index, on)
  if props.setSolid(index, on) then pushRouteState() end
end

-- Half a turn, for a board whose face came out on the far side.
function M.flipProp(index)
  if props.flip(index) then pushRouteState() end
end

function M.editorUndo()
  local target = activeEditorRoute()
  if #target > 0 then
    target[#target] = nil
    if edit.target == 'joker' then
      if session.jokerArmed > #track.jokerRoute then session.jokerArmed = math.max(#track.jokerRoute, 1) end
    elseif edit.target == 'main' and session.armedWp > #track.route then
      session.armedWp = math.max(#track.route, 1)
    elseif edit.target == 'branch' then
      branch.rebuild()
      branch.editSlot = branch.nextFreeSlot()
    end
    pushRouteState()
  end
end

function M.editorClear()
  -- Each target clears its own list; only main clears the track.
  if edit.target == 'pit' then
    track.pitRoute = {}
    pushRouteState()
    log('I', 'raceManager', 'Pit stalls cleared')
    return
  end
  -- Without this, clearing on the Marker tab wiped the main route.
  if edit.target == 'marker' then
    marker.list = {}
    pushRouteState()
    log('I', 'raceManager', 'Markers cleared')
    return
  end
  if edit.target == 'prop' then
    props.list = {}
    pushRouteState()
    log('I', 'raceManager', 'Props cleared')
    return
  end
  if edit.target == 'joker' then
    track.jokerRoute   = {}
    session.jokerArmed   = 1
    session.jokerTaken   = false
    session.jokerLapUsed = nil
    pushRouteState()
    log('I', 'raceManager', 'Joker route cleared')
    return
  end
  if edit.target == 'start' then
    track.startPositions = {}
    session.gridSlot = nil
    branch.gridTool.generated = false
    pushRouteState()
    log('I', 'raceManager', 'Start positions cleared')
    return
  end
  -- Branch gates only: the lap they branch off survives.
  if edit.target == 'branch' then
    branch.list   = {}
    branch.bySlot = {}
    branch.editSlot = 1
    pushRouteState()
    log('I', 'raceManager', 'Branch gates cleared')
    return
  end
  clearTrackState('editor clear')
end

-- --- Start position editing -------------------------------------------------
-- Placed slots stay editable: move one to where the car is standing now, or
-- drop it and let the rest of the grid close up.
function M.moveStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  if not track.startPositions[index] then
    log('W', 'raceManager', 'moveStartPosition: no start position at ' .. tostring(index))
    return
  end
  local place = vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  track.startPositions[index] = place
  -- Hand-placed now: the grid sliders let go of it.
  branch.gridTool.generated = false
  pushRouteState()
  log('I', 'raceManager', 'Start position ' .. index .. ' moved to the current vehicle')
end

function M.removeStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  if not track.startPositions[index] then return end
  table.remove(track.startPositions, index)
  if session.gridSlot and session.gridSlot > #track.startPositions then session.gridSlot = nil end
  branch.gridTool.generated = false
  pushRouteState()
end

-- Preview: stand the car on a placed slot so the creator can check spacing
-- without starting a race. Never freezes - this is an editor convenience.
function M.previewStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  local sp = track.startPositions[index]
  if not sp then return end
  if not placeOnStartPosition(sp) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Could not move the vehicle' })
  end
end

-- Move a placed gate (any editor list) to where the car is, keeping its size.
function M.moveCheckpoint(index)
  index = math.floor(tonumber(index) or 0)
  local list = activeEditorRoute()
  local wp = list[index]
  if not wp then
    log('W', 'raceManager', 'moveCheckpoint: nothing at index ' .. tostring(index))
    return
  end
  local place = vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  -- A prop goes in front of the car, as when placed, keeping its kind.
  if edit.target == 'prop' then place = props.fromPlace(place, true, wp.kind) end
  wp.x, wp.y, wp.z = place.x, place.y, place.z
  wp.hx, wp.hy = place.hx, place.hy
  pushRouteState()
  log('I', 'raceManager', string.format('%s %d moved to the current vehicle',
    edit.target, index))
end

-- Stand the car on a placed gate, facing the way through it, so the creator can
-- see what a driver will see. Never freezes: this is an editor convenience.
function M.previewCheckpoint(index)
  index = math.floor(tonumber(index) or 0)
  local wp = activeEditorRoute()[index]
  if not wp then return end
  -- On a prop is inside it: stand back and face it instead.
  if edit.target == 'prop' then wp = props.viewpoint(wp) end
  if not placeOnStartPosition(wp) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Could not move the vehicle' })
  end
end

-- --- Taking things back -----------------------------------------------------
-- Remove, insert and reorder on whichever list the editor is pointed at. Each
-- must renumber the BRANCH GATES in step: they address a checkpoint by number.
function branch.shiftSlots(from, delta)
  for _, g in ipairs(branch.list) do
    local s = tonumber(g.slot)
    if s and s >= from then g.slot = s + delta end
  end
end

-- Drop the branch gates of a checkpoint that is going away.
function branch.dropSlot(slot)
  local dropped = 0
  for i = #branch.list, 1, -1 do
    if tonumber(branch.list[i].slot) == slot then
      table.remove(branch.list, i)
      dropped = dropped + 1
    end
  end
  return dropped
end

function M.removeCheckpoint(index)
  index = math.floor(tonumber(index) or 0)
  local list = activeEditorRoute()
  if not list[index] then
    log('W', 'raceManager', 'removeCheckpoint: nothing at index ' .. tostring(index))
    return
  end
  table.remove(list, index)
  if edit.target == 'main' then
    local dropped = branch.dropSlot(index)
    branch.shiftSlots(index + 1, -1)
    branch.rebuild()
    if dropped > 0 then
      guihooks.trigger('RaceManagerEditorMsg', {
        msg = 'Checkpoint ' .. index .. ' removed: ' .. dropped
          .. ' branch gate(s) on that slot dropped with it',
      })
    end
    if session.armedWp > #track.route then session.armedWp = math.max(#track.route, 1) end
  elseif edit.target == 'joker' then
    if session.jokerArmed > #track.jokerRoute then session.jokerArmed = math.max(#track.jokerRoute, 1) end
  elseif edit.target == 'branch' then
    branch.rebuild()
    branch.editSlot = branch.nextFreeSlot()
  end
  pushRouteState()
  log('I', 'raceManager', string.format('%s %d removed', edit.target, index))
end

-- Place a gate BEFORE an existing one, at the car.
function M.insertCheckpoint(index, place)
  index = math.floor(tonumber(index) or 0)
  local list = activeEditorRoute()
  if index < 1 then index = 1 end
  if index > #list + 1 then index = #list + 1 end
  local driven = place == nil
  place = place or vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  if edit.target == 'prop' then
    place = props.fromPlace(place, driven)
  elseif edit.target ~= 'start' then
    local prev = list[index] or list[#list]
    place.width  = clampWidth(prev and prev.width  or track.checkpointWidth)
    place.height = clampHeight(prev and prev.height or track.checkpointHeight)
    place.depth  = clampDepth(prev and prev.depth  or track.checkpointDepth)
    if edit.target == 'pit' then pit.sizeFrom(place, prev) end
  end
  if edit.target == 'branch' then
    guihooks.trigger('RaceManagerEditorMsg', {
      msg = 'Branch gates are placed against a slot, not in an order',
    })
    return
  end
  table.insert(list, index, place)
  if edit.target == 'main' then
    branch.shiftSlots(index, 1)
    branch.rebuild()
  end
  pushRouteState()
  log('I', 'raceManager', string.format('%s inserted at %d', edit.target, index))
end

-- Move one gate (or grid slot) in the order; slot 1 of a grid is pole.
function M.reorderCheckpoint(from, to)
  from = math.floor(tonumber(from) or 0)
  to   = math.floor(tonumber(to) or 0)
  local list = activeEditorRoute()
  if not list[from] or from == to then return end
  if to < 1 then to = 1 end
  if to > #list then to = #list end
  local item = table.remove(list, from)
  table.insert(list, to, item)
  if edit.target == 'main' then
    -- Branch slots follow: `from` goes to `to`, everything between shifts one.
    local lo, hi, step = math.min(from, to), math.max(from, to), (from < to) and -1 or 1
    for _, g in ipairs(branch.list) do
      local s = tonumber(g.slot)
      if s == from then g.slot = to
      elseif s and s >= lo and s <= hi then g.slot = s + step end
    end
    branch.rebuild()
  end
  pushRouteState()
  log('I', 'raceManager', string.format('%s %d moved to %d', edit.target, from, to))
end

-- --- Building a grid without driving it -------------------------------------

-- The grid generator's state: what was generated, from where, how far apart,
-- so the sliders can re-lay it.
branch.gridTool = {
  generated = false,   -- was this grid laid out by the generator?
  anchor    = nil,     -- { x, y, z, hx, hy } the row-1 slot it was built from
  count     = 0,
  spacing   = 8,       -- meters between rows
  stagger   = 6,       -- meters between the cars ACROSS a row
  width     = 2,       -- cars per row
}

-- Lay N slots back down an anchor's heading, `width` abreast, each row CENTERED
-- on the anchor (so changing the width does not walk the grid sideways).
-- `stagger` is the gap between adjacent cars across a row.
function branch.layOutGrid(anchor, count, spacing, stagger, width, replace)
  local fx, fy = anchor.hx, anchor.hy
  local rx, ry = fy, -fx        -- the right-hand perpendicular
  width = math.floor(tonumber(width) or 2)
  if width < 1 then width = 1 end
  if width > TUNE.GRID_MAX_WIDTH then width = TUNE.GRID_MAX_WIDTH end
  if replace then track.startPositions = {} end
  local mid = (width - 1) * 0.5
  -- Every slot finds its own ground, keeping the anchor's height ABOVE the
  -- ground (a flat plane through a hill buries rows; a bridge grid stays up).
  local anchorGround = groundAt(anchor.x, anchor.y, anchor.z)
  local lift = anchorGround and (anchor.z - anchorGround) or TUNE.GROUND_CLEAR
  if lift < TUNE.GROUND_CLEAR then lift = TUNE.GROUND_CLEAR end
  for i = 0, count - 1 do
    local row  = math.floor(i / width)
    local col  = i % width
    local back = row * spacing
    local side = (col - mid) * stagger
    local x = anchor.x - fx * back + rx * side
    local y = anchor.y - fy * back + ry * side
    -- Probed from the anchor's height: the slot has none yet.
    local g = groundAt(x, y, anchor.z)
    track.startPositions[#track.startPositions + 1] = {
      x  = x,
      y  = y,
      z  = g and (g + lift) or anchor.z,
      hx = fx, hy = fy,
    }
  end
end

-- Generate start positions. `from` names a placed slot to anchor on (its
-- heading too), else the car. NOT M.generateGrid: that later definition forms
-- the race grid, and last-assignment-wins erased this one.
function M.generateStartPositions(count, spacing, stagger, from, width)
  count   = math.floor(tonumber(count) or 0)
  spacing = tonumber(spacing) or 8
  stagger = tonumber(stagger) or 6
  width   = math.floor(tonumber(width) or 2)
  if width < 1 then width = 1 end
  if width > TUNE.GRID_MAX_WIDTH then width = TUNE.GRID_MAX_WIDTH end
  if count < 1 then return end
  if count > 60 then count = 60 end

  local anchor, replace
  local slot = math.floor(tonumber(from) or 0)
  if track.startPositions[slot] then
    -- Rebuild the grid from an existing slot, keeping everything before it.
    local sp = track.startPositions[slot]
    anchor = { x = sp.x, y = sp.y, z = sp.z, hx = sp.hx, hy = sp.hy }
    for i = #track.startPositions, slot, -1 do table.remove(track.startPositions, i) end
    replace = false
  else
    anchor = vehiclePlacement()
    if not anchor then
      guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
      return
    end
    replace = false
  end

  branch.layOutGrid(anchor, count, spacing, stagger, width, replace)
  -- Remembered for the sliders.
  branch.gridTool.generated = true
  branch.gridTool.anchor    = anchor
  branch.gridTool.count     = count
  branch.gridTool.spacing   = spacing
  branch.gridTool.stagger   = stagger
  branch.gridTool.width     = width
  pushRouteState()
  guihooks.trigger('RaceManagerEditorMsg', {
    msg = 'Generated ' .. count .. ' start positions, ' .. width .. ' abreast ('
      .. spacing .. 'm between rows, ' .. stagger .. 'm across)',
  })
  log('I', 'raceManager', 'Generated ' .. count .. ' start positions, '
    .. width .. ' abreast')
end

-- Re-lay the generated grid (the sliders). Only the slots it built; a hand-built
-- grid is never respaced.
function M.respaceGrid(spacing, stagger, width)
  if not branch.gridTool.generated or not branch.gridTool.anchor then return end
  spacing = tonumber(spacing) or branch.gridTool.spacing
  stagger = tonumber(stagger) or branch.gridTool.stagger
  width   = math.floor(tonumber(width) or branch.gridTool.width)
  if spacing < 1 then spacing = 1 end
  if spacing > 60 then spacing = 60 end
  if stagger < 0 then stagger = 0 end
  if stagger > 30 then stagger = 30 end
  if width < 1 then width = 1 end
  if width > TUNE.GRID_MAX_WIDTH then width = TUNE.GRID_MAX_WIDTH end
  -- The generator owns the last `count` slots.
  local keep = #track.startPositions - branch.gridTool.count
  if keep < 0 then keep = 0 end
  -- Headings survive the move: on a head-on grid the way a car faces is the
  -- only thing saying which direction it races.
  local held = {}
  for i = keep + 1, #track.startPositions do
    local sp = track.startPositions[i]
    held[i - keep] = sp and { hx = sp.hx, hy = sp.hy } or nil
  end
  for i = #track.startPositions, keep + 1, -1 do table.remove(track.startPositions, i) end
  branch.layOutGrid(branch.gridTool.anchor, branch.gridTool.count,
    spacing, stagger, width, false)
  for i = 1, branch.gridTool.count do
    local sp, was = track.startPositions[keep + i], held[i]
    if sp and was and was.hx and was.hy then sp.hx, sp.hy = was.hx, was.hy end
  end
  -- Headings follow the slot, not the row, when the width re-flows them.
  branch.gridTool.spacing = spacing
  branch.gridTool.stagger = stagger
  branch.gridTool.width   = width
  pushRouteState()
end

-- Turn a range of grid slots around: a head-on grid from one generated block.
function M.flipStartPositions(from, to)
  from = math.floor(tonumber(from) or 1)
  to   = math.floor(tonumber(to) or #track.startPositions)
  if from < 1 then from = 1 end
  if to > #track.startPositions then to = #track.startPositions end
  local n = 0
  for i = from, to do
    local sp = track.startPositions[i]
    if sp then
      sp.hx, sp.hy = -(sp.hx or 0), -(sp.hy or 1)
      n = n + 1
    end
  end
  pushRouteState()
  guihooks.trigger('RaceManagerEditorMsg', { msg = 'Turned ' .. n .. ' start position(s) around' })
end

-- No slot carries a direction: the slot points the car, and Flip splits a
-- head-on field.

function M.setCheckpointWidth(w)
  track.checkpointWidth = clampWidth(w)
  pushRouteState()
end

function M.setCheckpointHeight(h)
  track.checkpointHeight = clampHeight(h)
  pushRouteState()
end

function M.setCheckpointDepth(d)
  track.checkpointDepth = clampDepth(d)
  pushRouteState()
end

-- Per-gate size. Blank (or zero) width or height inherits the default.
function M.setCheckpointOverride(index, w, h, d)
  index = math.floor(tonumber(index) or 0)
  local wp = activeEditorRoute()[index]
  if not wp then
    log('W', 'raceManager', 'setCheckpointOverride: no checkpoint at index ' .. tostring(index))
    return
  end
  local function opt(v, clamp)
    v = tonumber(v)
    if not v or v <= 0 then return nil end
    return clamp(v)
  end
  wp.width  = opt(w, clampWidth)
  wp.height = opt(h, clampHeight)
  -- Depth zero is real (a gate that stops at the surface): only nil inherits.
  local dv = tonumber(d)
  wp.depth = dv and clampDepth(dv) or clampDepth(track.checkpointDepth)
  pushRouteState()
end

-- A pit stall's box: car-sized, so not setCheckpointOverride's ranges.
function M.setPitStallSize(index, w, l)
  local wp = track.pitRoute[math.floor(tonumber(index) or 0)]
  if not wp then
    log('W', 'raceManager', 'setPitStallSize: no pit stall at index ' .. tostring(index))
    return
  end
  w, l = tonumber(w), tonumber(l)
  wp.width  = (w and w > 0) and w or nil
  wp.length = (l and l > 0) and l or nil
  wp.width, wp.length = pit.dims(wp)
  pushRouteState()
end

-- Console: dump(raceManager.nudgeStatus()). Why Place mode will not turn on.
function M.nudgeStatus()
  local gaps = nudge.missing()
  return {
    on          = nudge.on,
    selected    = nudge.sel,
    usable      = #gaps == 0,
    missing     = gaps,
    imgui       = nudge.im ~= nil,
    rayCast     = type(cameraMouseRayCast) == 'function',
    mouseRay    = type(getCameraMouseRay) == 'function',
    canvas      = nudge.canvas() ~= nil,
    lockMouse   = type(lockMouse) == 'function',
    -- nil: no isCursorOn to ask, so leaving the mode leaves the cursor free.
    cursorProbe = nudge.cursorFree(),
    cursorWasFree = nudge.wasFree,
    editorOpen  = edit.open,
    isAdmin     = session.isAdmin,
  }
end

-- Retire: a classified DNF, not a disappearance.
function M.retire()
  if inMultiplayer() then TriggerServerEvent('RM_Retire', '') end
end

function M.setSpectating(on)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetSpectating', jsonEncode({ spectating = on == true }))
  end
end

-- Ready for the grid. Refused with no car to place.
function M.setReady(on)
  if not inMultiplayer() then return end
  if on ~= false and not ownVehicle() then
    pushNotice('grid', 'Get in a car first', { sub = 'Then press Ready' })
    return
  end
  TriggerServerEvent('RM_SetReady', jsonEncode({ ready = on ~= false }))
end

-- Admin: ready somebody else (their panel is closed or broken), or everyone.
function M.readyDriver(pid)
  pid = tonumber(pid)
  if pid and inMultiplayer() then
    TriggerServerEvent('RM_SetReady', jsonEncode({ ready = true, pid = pid }))
  end
end

function M.readyAll()
  if inMultiplayer() then TriggerServerEvent('RM_ReadyAll', '') end
end

function M.setReadyCheck(on)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetReadyCheck', jsonEncode({ on = on == true }))
  end
end

-- ---------------------------------------------------------------------------
-- Broadcast camera: put the view on a named driver
-- ---------------------------------------------------------------------------
-- The spectator board sends a BeamMP PLAYER id (vehicle ids are local), and only
-- this client can resolve it to a car. The ONE place that sets the camera MODE:
-- a broadcaster clicking a name is asking for a chase view of that car.
function M.spectateDriver(pid)
  pid = tonumber(pid)
  if pid == nil then return false end
  -- Our own row through ownVehicle(), which also works offline.
  local veh = nil
  if pid == localServerId() then veh = ownVehicle() end
  if not veh then veh = ghost.vehicleForPid(pid) end
  if not veh then
    -- Not loaded here yet: say so, rather than a dead row.
    pushNotice('spectate', 'No car on this client for that driver yet')
    guihooks.trigger('RaceManagerWatch', { pid = pid, ok = false })
    return false
  end
  -- Out of free cam first, or enterVehicle appears to do nothing.
  if commands and commands.isFreeCamera and commands.setGameCamera then
    local inFree = false
    pcall(function () inFree = commands.isFreeCamera() == true end)
    if inFree then pcall(commands.setGameCamera) end
  end
  local switched = false
  if be and be.enterVehicle then
    switched = pcall(function () be:enterVehicle(0, veh) end)
  end
  if switched and core_camera and core_camera.setByName then
    pcall(core_camera.setByName, 0, 'orbit')
  end
  -- Reported either way, so the board marks where the camera actually landed.
  guihooks.trigger('RaceManagerWatch', { pid = pid, ok = switched })
  log('I', 'raceManager', 'Broadcast camera -> pid ' .. tostring(pid)
    .. (switched and '' or ' FAILED (enterVehicle unavailable)'))
  return switched
end

function M.setFlag(f)
  f = tostring(f or '')
  if f ~= 'green' and f ~= 'yellow' and f ~= 'red' then return end
  if inMultiplayer() then TriggerServerEvent('RM_SetFlag', jsonEncode({ flag = f })) end
end

function M.setNudgeMode(on)
  nudge.set(on == true or on == 'true')
end

function M.editorToggleVisualize()
  edit.visualize = not edit.visualize
  pushRouteState()
end

-- ---------------------------------------------------------------------------
-- Track layouts (server-side, persistent, per-map)
-- ---------------------------------------------------------------------------
-- Named layouts live on the server, per map; a load is pushed to every client.
local function editorMsg(msg)
  guihooks.trigger('RaceManagerEditorMsg', { msg = msg })
end

-- `confirmDrop`: the admin accepted that this save empties a section the
-- stored layout has (otherwise the server holds it with RM_SaveHeld).
function M.saveLayout(name, confirmDrop)
  name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
  print('[raceManager] saveLayout("' .. name .. '") with ' .. #track.route .. ' checkpoint(s)')
  if name == '' then
    log('W', 'raceManager', 'saveLayout: no layout name given, nothing sent')
    editorMsg('Enter a layout name first')
    return
  end
  if #track.route == 0 then
    log('W', 'raceManager', 'saveLayout: no checkpoints placed, nothing sent')
    editorMsg('Place checkpoints before saving a layout')
    return
  end
  if not inMultiplayer() then
    log('W', 'raceManager', 'saveLayout: not connected to a BeamMP server, nothing sent')
    editorMsg('Layouts need a BeamMP server (use Save/Load for offline routes)')
    return
  end
  -- A sanitized copy: plain numeric fields only, the shape the server expects.
  local function bundle(src, what)
    local out = {}
    for i, wp in ipairs(src) do
      local x, y, z = tonumber(wp.x), tonumber(wp.y), tonumber(wp.z)
      if not (x and y and z) then
        log('E', 'raceManager', 'saveLayout: ' .. what .. ' checkpoint ' .. i
          .. ' has non-numeric coordinates, aborting')
        editorMsg('Save failed: ' .. what .. ' checkpoint ' .. i .. ' is invalid')
        return nil
      end
      out[i] = { x = x, y = y, z = z, hx = tonumber(wp.hx) or 0, hy = tonumber(wp.hy) or 1 }
      -- Carry per-checkpoint overrides through only when set.
      if tonumber(wp.width)  then out[i].width  = clampWidth(wp.width)   end
      if tonumber(wp.height) then out[i].height = clampHeight(wp.height) end
      if tonumber(wp.depth)  then out[i].depth  = clampDepth(wp.depth)   end
      if tonumber(wp.length) then out[i].length = tonumber(wp.length)    end  -- pit stalls
      if wp.oneWay == true   then out[i].oneWay = true end
      -- A marker's symbol travels too, validated (a bad kind draws nothing).
      if wp.kind ~= nil then out[i].kind = marker.validKind(wp.kind) or 'right' end
    end
    return out
  end
  local cps = bundle(track.route, 'route')
  if not cps then return end
  -- The joker route, grid and branch gates travel with the layout too.
  local jokerCps = nil
  if #track.jokerRoute > 0 then
    jokerCps = bundle(track.jokerRoute, 'joker')
    if not jokerCps then return end
  end
  local starts = nil
  if #track.startPositions > 0 then
    starts = bundle(track.startPositions, 'start position')
    if not starts then return end
  end
  -- Bundled by hand: a branch gate carries its slot.
  local alts = nil
  if #branch.list > 0 then
    alts = {}
    for i, g in ipairs(branch.list) do
      local x, y, z, slot = tonumber(g.x), tonumber(g.y), tonumber(g.z), tonumber(g.slot)
      if not (x and y and z and slot) then
        log('E', 'raceManager', 'saveLayout: branch gate ' .. i .. ' is invalid, aborting')
        editorMsg('Save failed: branch gate ' .. i .. ' is invalid')
        return
      end
      local out = {
        slot = math.floor(slot), x = x, y = y, z = z,
        hx = tonumber(g.hx) or 0, hy = tonumber(g.hy) or 1,
      }
      if tonumber(g.width)  then out.width  = clampWidth(g.width)   end
      if tonumber(g.height) then out.height = clampHeight(g.height) end
      if tonumber(g.depth)  then out.depth  = clampDepth(g.depth)   end
      if g.oneWay == true   then out.oneWay = true end
      alts[#alts + 1] = out
    end
    if #alts == 0 then alts = nil end
  end
  local payload = jsonEncode({
    name        = name,
    width       = clampWidth(track.checkpointWidth),
    height      = clampHeight(track.checkpointHeight),
    depth       = clampDepth(track.checkpointDepth),
    checkpoints = cps,
    joker       = jokerCps,
    startPositions = starts,
    branches       = alts,
    -- Inferred, never asked for (see branch.gridIsOff).
    gridOffLine    = branch.gridIsOff(),
    pits           = bundle(track.pitRoute, 'pit stall') or {},
    -- Empty tables, not nil, so a re-save never drops the lane's gates.
    pitEntry       = bundle(track.pitEntry, 'pit entry') or {},
    pitExit        = bundle(track.pitExit, 'pit exit') or {},
    markers        = bundle(marker.list, 'marker') or {},
    -- Empty, not nil, for the same reason as the pit gates.
    props          = props.bundle(),
    pointToPoint   = track.pointToPoint,
    drag           = track.pointToPoint and track.dragStrip,
    confirmDrop    = confirmDrop == true,
  })
  print('[raceManager] saveLayout: sending RM_SaveLayout (' .. #payload .. ' bytes) to server')
  TriggerServerEvent('RM_SaveLayout', payload)
end

function M.loadLayout(name, forEditing)
  name = tostring(name or '')
  if name == '' then return end
  if not inMultiplayer() then
    editorMsg('Layouts need a BeamMP server')
    return
  end
  -- Pressing Load is the admin saying yes: the buffer guard only stops someone
  -- ELSE's layout landing on unsaved work.
  edit.stamp   = nil
  edit.refused = nil
  -- `forEditing` asks for a PRIVATE load to this client only; the raced track
  -- does not move. nil when unset, so an older server sees the old payload.
  TriggerServerEvent('RM_LoadLayout', jsonEncode({
    name       = name,
    forEditing = forEditing and true or nil,
  }))
end

-- Admin: open or close a saved layout for practice. Allowed mid-session: it
-- changes nothing about the running race.
function M.setLayoutPractice(name, on)
  name = tostring(name or '')
  if name == '' then return end
  if not inMultiplayer() then
    editorMsg('Layouts need a BeamMP server')
    return
  end
  TriggerServerEvent('RM_SetLayoutPractice', jsonEncode({
    name = name, practice = on == true,
  }))
end

-- --- Free practice ---------------------------------------------------------

-- Pull up an approved track to practice on (anyone). The server decides what a
-- practice load may do; this end cannot approve its own layout.
function M.practiceLayout(name)
  name = tostring(name or '')
  if name == '' then return end
  if not inMultiplayer() then
    editorMsg('Practice needs a BeamMP server')
    return
  end
  -- `ghost` only when true, so an older server ignores it.
  TriggerServerEvent('RM_LoadLayout', jsonEncode({
    name = name, forPractice = true, ghost = practice.ghost or nil,
  }))
end

-- Practice lap target; 0 is unlimited (the default).
function M.setPracticeLaps(n)
  practice.lapTarget = math.max(0, math.floor(tonumber(n) or 0))
  pushRouteState()
end

-- Ghosted or solid while practising. One ghost in a pair passes through, so both
-- must pick solid to touch.
function M.setPracticeGhost(on)
  on = on ~= false
  if practice.ghost == on then return end
  practice.ghost = on
  if practice.on then
    ghost.practiceSync()
    if inMultiplayer() then
      TriggerServerEvent('RM_PracticeGhost', jsonEncode({ on = on }))
    end
  end
  pushRouteState()
end

-- Every way practice stops. The gates stay drawn: the track is still loaded.
function practice.stop(why)
  if not practice.on then
    -- A completed run's laps close on every way out.
    if practice.complete then
      practice.complete = false
      practice.lapsDone = 0
      pushRouteState()
    end
    return
  end
  local done = practice.lapsDone
  practice.on = false
  practice.complete = why == 'complete'
  if not practice.complete then practice.lapsDone = 0 end
  timingReset()
  ghost.practiceSync()
  if why ~= 'idle' and inMultiplayer() then
    TriggerServerEvent('RM_PracticeEnd', '')
  end
  if why == 'complete' then
    pushNotice('session', 'PRACTICE COMPLETE: ' .. done .. (done == 1 and ' lap' or ' laps'))
  elseif why == 'session' or why == 'derby' then
    pushNotice('session', 'Practice ended: a ' .. why .. ' is starting')
  elseif why ~= 'idle' then
    pushNotice('session', 'Practice ended')
  end
  pushRouteState()
end

-- Stop practising, or close a finished run's laps.
function M.endPractice()
  practice.stop('driver')
end

-- The server has put this client on a practice track.
local function onPractice(rawData)
  -- rawData: every DISPATCH handler decodes the wire string itself (a table
  -- argument failed the type check and practice never switched on).
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  practice.on     = data.on == true
  practice.layout = data.layout
  practice.lapsDone = 0
  practice.complete = false
  session.localLap  = 1
  session.lapStart  = localTime
  session.armedWp   = 1
  timingReset()
  ghost.practiceSync()
  if practice.on then
    -- Stand the car on start position 1 first, so lap one is a lap and not the
    -- drive out to the circuit. Through the field queue, ghosted, NOT held.
    -- A layout with no start positions leaves the driver where they are.
    if #track.startPositions > 0 then
      queueFieldPlacement({
        slot  = 1,
        slots = track.startPositions,
        hold  = false,
        holdSource = 'practice',
        order = 1, count = 1,     -- one car, no field to stagger behind
      })
    end
    pushNotice('session', 'PRACTICE: ' .. tostring(data.layout or 'track')
      .. ' -- your laps are timed for you only')
  end
  pushRouteState()
end

function M.deleteLayout(name)
  name = tostring(name or '')
  if name == '' then return end
  if not inMultiplayer() then
    editorMsg('Layouts need a BeamMP server')
    return
  end
  TriggerServerEvent('RM_DeleteLayout', jsonEncode({ name = name }))
end

-- Console helper: creates a one-gate circuit (a bare start/finish line).
-- raceManager.setFinishLine(x, y, z [, headingX, headingY])
function M.setFinishLine(x, y, z, hx, hy)
  local len = math.sqrt((hx or 0) ^ 2 + (hy or 0) ^ 2)
  if len > 1e-4 then hx, hy = hx / len, hy / len else hx, hy = 0, 1 end
  track.route = { { x = x, y = y, z = z, hx = hx, hy = hy } }
  session.armedWp = 1
  pushRouteState()
end

-- ---------------------------------------------------------------------------
-- The editor is closed while a session is running
-- ---------------------------------------------------------------------------
-- ENFORCED: every action below mutates the route buffer, and the panel's own
-- guards once missed qualifying everywhere. One wrapper pass, so a new editor
-- action is covered by adding its name. Previews and the visualise toggle are
-- deliberately absent; so are save, load and delete, which the SERVER refuses
-- mid-session on its own (slightly different) terms.
for _, name in ipairs({
  'editorAdd', 'editorUndo', 'editorClear', 'setFinishLine',
  'moveCheckpoint', 'removeCheckpoint', 'insertCheckpoint', 'reorderCheckpoint',
  'setCheckpointWidth', 'setCheckpointHeight', 'setCheckpointDepth',
  'setCheckpointOverride', 'setPitStallSize', 'setPointToPoint',
  'moveStartPosition', 'removeStartPosition',
  'generateStartPositions', 'respaceGrid', 'flipStartPositions',
  'setBranchSlot', 'setBranchGateSlot', 'removeBranchGate',
  'nudgeTurn', 'nudgeLift', 'nudgeDelete',
}) do
  local inner = M[name]
  -- A missing name is a typo here: say so at load rather than wrap nil.
  if type(inner) ~= 'function' then
    log('E', 'raceManager', 'editor guard: no such action "' .. name .. '"')
  else
    M[name] = function (...)
      if not edit.canConfigure() then
        editorMsg('Not while a session is running: end it first.')
        return
      end
      return inner(...)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Server -> client
-- ---------------------------------------------------------------------------
-- SCOPED in a do-block: a block's locals are released at `end` (the 200-local
-- limit counts active locals) while the closures inside keep them. Nothing above
-- names these handlers: they are reached through DISPATCH and M.
do
local function onServerUpdate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  if not fromCurrentServer(data) then return end

  -- League regulations arrive with every state broadcast (Modules 1 & 2).
  if type(data.maxResets) == 'number' then session.maxResets = math.floor(data.maxResets) end
  if data.resetMode == 'checkpoint' or data.resetMode == 'inplace' then
    session.resetMode = data.resetMode
  end
  if type(data.youSpectating) == 'boolean' then selfSpectating = data.youSpectating end
  session.jokerEnabled = data.jokerEnabled == true
  -- The pace lap is the racing phase under yellow, so its notice is pushed on
  -- its own edge, after the YELLOW FLAG one, to be the one left on screen.
  local wasPacing = session.pacing
  local wasReady  = session.greenReady
  session.paceLap = data.paceLap == true
  session.pacing  = data.pacing == true
  -- For the lights: a pace-lap start is a race's alone.
  if data.sessionKind then session.sessionKind = data.sessionKind end
  -- For the radar: positions and laps of the cars around this one.
  if type(data.drivers) == 'table' then session.drivers = data.drivers end
  -- GET READY: the leader is on the run to the line and the green is coming.
  session.greenReady = data.greenReady == true
  -- The caution has its own notices too (see below).
  local wasCaution = session.caution
  local wasPending = session.cautionPending
  local wasRestart = session.restartPending
  session.caution = data.caution == true
  session.cautionPending = data.cautionPending == true
  session.restartPending = data.restartPending == true
  if type(data.cautionLaps) == 'number' then session.cautionLaps = data.cautionLaps end
  -- The heat program: only what the lap target needs.
  session.heatCount   = tonumber(data.heatCount) or 0
  session.heatCurrent = tonumber(data.heatCurrent) or 0
  session.heatLaps    = tonumber(data.heatLaps) or 0
  -- The flag, and a notice the moment it CHANGES.
  local wasFlag = session.raceFlag
  if data.flag == 'green' or data.flag == 'yellow' or data.flag == 'red' then
    session.raceFlag = data.flag
  end
  if session.raceFlag ~= wasFlag and sessionRunning() then
    -- The flag is the headline; the instruction is the second line.
    if session.raceFlag == 'red' then
      pushNotice('flag', 'RED FLAG',
        { sub = 'Stop where you are and wait', color = 'red' })
    elseif session.raceFlag == 'yellow' then
      pushNotice('flag', 'YELLOW FLAG',
        { sub = 'Caution: race back to the line', color = 'yellow' })
    else
      pushNotice('flag', 'GREEN FLAG', { sub = 'Racing', color = 'green' })
    end
  end
  -- ...and the pace lap's, over the yellow. Both units: a league on both sides
  -- of the Atlantic.
  if session.pacing and not wasPacing then
    pushNotice('flag', 'PACE LAP',
      { sub = 'Hold position - 50 MPH or 80 KMH', color = 'yellow' })
  end
  -- AMBER, never green: green means go.
  if session.greenReady and not wasReady then
    pushNotice('flag', 'GET READY',
      { sub = 'Green flag coming - hold position until it falls', color = 'amber' })
  end
  -- Three edges, three instructions, in the order a driver meets them.
  if session.cautionPending and not wasPending then
    pushNotice('flag', 'CAUTION - RACE BACK TO THE LINE',
      { sub = 'Positions lock as you complete this lap', color = 'yellow' })
  end
  if session.caution and not wasCaution then
    pushNotice('flag', 'CAUTION',
      { sub = 'Hold position, no overtaking - places are frozen', color = 'yellow' })
  elseif session.restartPending and not wasRestart then
    -- The green is coming, at the line.
    pushNotice('flag', 'RESTART THIS LAP',
      { sub = 'Hold position - GET READY comes before the green', color = 'yellow' })
  elseif wasRestart and not session.restartPending and session.caution then
    pushNotice('flag', 'RESTART WAVED OFF',
      { sub = 'Stay under caution, hold your position', color = 'yellow' })
  elseif wasCaution and not session.caution and sessionRunning() then
    -- The restart gets its own word: the one green a driver must be READY for.
    pushNotice('flag', 'RESTART - GREEN FLAG',
      { sub = 'Racing resumes', color = 'green' })
  end
  -- youAreAdmin is only on a targeted reply, so this is a join or a panel open.
  if type(data.youAreAdmin) == 'boolean' then M.splashOffer() end
  -- Admin status, only on a targeted reply (RM_RequestState). The server is the
  -- authority: a mismatch corrects the local flag.
  if type(data.youAreAdmin) == 'boolean' and data.youAreAdmin ~= session.isAdmin then
    session.isAdmin = data.youAreAdmin
    session.role = session.isAdmin and (data.youRole or 'admin') or nil
    guihooks.trigger('RaceManagerAuth', {
      success = session.isAdmin, role = session.role, restored = true,
    })
    pushRouteState()
  -- The tier can change while the flag does not (logged back in as moderator).
  elseif session.isAdmin and type(data.youRole) == 'string'
      and data.youRole ~= session.role then
    session.role = data.youRole
    guihooks.trigger('RaceManagerAuth', {
      success = true, role = session.role, restored = true,
    })
    pushRouteState()
  end
  -- Final lap, from the broadcast so a reconnecting client is told too; notice
  -- on the edge only.
  local wasFinalLap = finalLap
  finalLap = data.finalLap == true
  if finalLap and not wasFinalLap then
    -- Qualifying: the clock expired. A race: the winner is home.
    pushNotice('session', session.phase == 'qualifying'
      and 'TIME EXPIRED: FINAL LAP. Your session ends as you cross the line.'
      or  'CHECKERED FLAG: the winner is home. Your race ends as you cross the line.')
  end

  -- Timed race, both edges, from the broadcast for the same reason.
  local wasExpired, wasLastLap = session.raceExpired, session.lastLapNum
  session.raceExpired = data.raceExpired == true
  session.lastLapNum  = (type(data.lastLapNum) == 'number') and data.lastLapNum or nil
  if type(data.raceMode) == 'string' then session.raceMode = data.raceMode end
  if session.raceExpired and not wasExpired and not session.lastLapNum then
    pushNotice('session', 'TIME UP: the FINAL LAP starts when the leader takes the line.')
  end
  if session.lastLapNum and not wasLastLap then
    pushNotice('session', 'FINAL LAP: finish lap ' .. session.lastLapNum .. ' to take the flag.')
  end
  -- Race entry + qualifying rules.
  if type(data.pointToPoint) == 'boolean' then track.pointToPoint = data.pointToPoint end
  if type(data.dragStrip) == 'boolean' then track.dragStrip = data.dragStrip end
  ghostQuali = data.ghostQuali == true
  qualiOutLap = data.qualiOutLap == true
  if type(data.qualiLapLimit)  == 'number' then qualiLapLimit  = data.qualiLapLimit  end
  if type(data.qualiTimeLimit) == 'number' then qualiTimeLimit = data.qualiTimeLimit end
  -- Ghost rules are the server's, so the whole league runs the same numbers.
  -- The clock is re-anchored every push: ghost end times are on it.
  if type(data.raceTime) == 'number' then ghost.serverTime = data.raceTime end
  if type(data.ghostOnReset) == 'boolean' then ghost.rules.onReset = data.ghostOnReset end
  if type(data.ghostMinSec)  == 'number'  then ghost.rules.minSec  = data.ghostMinSec  end
  if type(data.ghostMaxSec)  == 'number'  then ghost.rules.maxSec  = data.ghostMaxSec  end
  -- The authoritative ghost roster, so a client that joined mid-ghost sees it.
  if type(data.ghosts) == 'table' then ghost.applyRoster(data.ghosts) end
  -- Finished ghosts, applied even when EMPTY: empty is the un-ghost.
  if type(data.ghostFinished) == 'table' then
    ghost.applyFinishedRoster(data.ghostFinished)
  end
  -- Drivers practising ghosted. Empty during a session: practice is between them.
  if type(data.ghostPractice) == 'table' then
    ghost.practiceSync(data.ghostPractice)
  end
  -- Our own row: bystander, blue flag, heat, status.
  local myId = localServerId()
  local wasLapped  = session.beingLapped
  local wasLapping = session.lappingAhead
  session.beingLapped, session.lappingAhead = false, false
  session.myHeat = nil
  -- Our status and slot, for the Ready button ('called': the grid waits on us).
  local wasStatus = session.myStatus
  session.myStatus, session.myGridPos = nil, nil
  if myId and type(data.drivers) == 'table' then
    for _, d in ipairs(data.drivers) do
      if tonumber(d.id) == myId then
        session.myStatus  = d.status
        session.myGridPos = tonumber(d.gridPos)
        isBystander = d.bystander == true
        -- The blue flag rides on the row: a fact about one driver.
        session.beingLapped  = d.blue == true
        session.lappingAhead = d.lapping == true
        session.myHeat       = tonumber(d.heat)
        break
      end
    end
  end
  -- Told on the edge: the header shows it, but a driver about to be caught is
  -- watching the road.
  if session.beingLapped and not wasLapped and sessionRunning() then
    pushNotice('flag', 'BLUE FLAG',
      { sub = 'Faster car a lap up behind you - let them by', color = 'blue' })
    if M.lightsMoment then M.lightsMoment('blue') end
  end
  -- The other half is a heads-up, not a flag: on the strip.
  if session.lappingAhead and not wasLapping and sessionRunning() then
    pushNotice('session', 'Backmarker ahead: they are being shown the blue flag')
  end
  -- Called to the grid: on the HUD (the app may be closed), on the edge, and
  -- not after pressing Not ready.
  if session.myStatus == 'called' and wasStatus ~= 'called' and wasStatus ~= 'gridded' then
    pushNotice('grid', 'The grid is forming', {
      sub = 'Press READY in PRM - Main to take '
        .. (session.myGridPos and ('slot P' .. session.myGridPos) or 'your slot'),
    })
  end

  -- Nametag aliases: the switch is the server's, the suffix is applied locally.
  if type(data.nametags) == 'boolean' and data.nametags ~= nametag.on then
    nametag.on = data.nametags
    if not nametag.on then nametag.clearAll() end
  end
  if type(data.drivers) == 'table' then nametag.apply(data.drivers) end

  -- Fastest lap, told once to the driver who set it. Keyed on the TIME as well,
  -- so beating your own fastest lap is announced too.
  local bestPid  = tonumber(data.bestLapPid)
  local bestTime = tonumber(data.bestLapTime)
  if bestPid ~= lastBestLapPid or bestTime ~= lastBestLapTime then
    if bestPid and myId and bestPid == myId and bestTime then
      local mins = math.floor(bestTime / 60)
      pushNotice('fastest', 'FASTEST LAP', {
        sub = string.format('%d:%06.3f', mins, bestTime - mins * 60),
      })
    end
    lastBestLapPid  = bestPid
    lastBestLapTime = bestTime
  end

  local newPhase = data.phase or 'waiting'
  if newPhase ~= session.phase then
    session.phase = newPhase
    -- Any session change re-arms lap detection from a clean slate.
    resetLapTracking()
    -- Practice ends, or every lap would take the practice branch.
    if newPhase ~= 'waiting' then practice.stop('session') end
    -- Qualifying's out lap is announced as the lights go out.
    if qualiOutLap and newPhase == 'qualifying' then
      pushNotice('session',
        'OUT LAP: this lap is NOT timed. Timing starts as you cross the line.')
    end
    -- The racing notice was removed on purpose (it described the results table,
    -- not when to go). Restore the `elseif qualiOutLap and newPhase == 'racing'`
    -- arm and the server's notifyField line together to bring it back.
    -- Leaving the start procedure must never leave a car frozen.
    if newPhase ~= 'grid' and newPhase ~= 'countdown' then releaseGridHold('race') end
    if newPhase ~= 'grid' and newPhase ~= 'countdown' and not sessionRunning() then
      session.gridSlot = nil
    end
  end
  session.totalLaps = data.totalLaps or session.totalLaps

  -- The flag rides this 3 Hz broadcast: on pushRouteState alone a caution
  -- did not reach the panel until something unrelated pushed.
  data.driverFlag = driverFlag()
  data.myStatus   = session.myStatus
  data.myGridPos  = session.myGridPos
  guihooks.trigger('RaceManagerUpdate', data)
  if M.lightsSync then M.lightsSync() end
end

-- The server assigned a starting slot: stand on it and hold for the countdown.
local function onGridAssign(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local slot = tonumber(data.slot)
  applyGridSlot(slot and math.floor(slot) or nil, tonumber(data.order), tonumber(data.count))
end

-- A car is coming back on a derby life: ghosted for a few seconds on THIS
-- client, our own car included. Going solid still passes the weld gate, so the
-- seconds are a floor.
function ghost.onDerbyRespawn(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local pid = data.pid
  if pid == nil then return end
  local seconds = tonumber(data.seconds) or 0
  if seconds <= 0 then return end
  local veh, vehId
  if tostring(pid) == tostring(localServerId()) then
    veh = ownVehicle()
    vehId = veh and vehicleId(veh) or nil
  else
    veh, vehId = ghost.vehicleForPid(pid)
  end
  if not vehId then return end
  ghost.respawn[vehId] = seconds
  ghost.reasonRig(vehId, 'derbyRespawn', true, veh)
  log('I', 'raceManager', ('Derby respawn ghost: vehicle %s for %.1fs')
    :format(tostring(vehId), seconds))
end

-- Tick those countdowns, on the LOCAL clock (race.time is frozen in a derby);
-- kept apart from the server-clock ghost machinery.
function ghost.respawnUpdate(dt)
  if next(ghost.respawn) == nil then return end
  for vehId, left in pairs(ghost.respawn) do
    left = left - dt
    if left <= 0 then
      ghost.respawn[vehId] = nil
      ghost.reasonRig(vehId, 'derbyRespawn', false)
    else
      ghost.respawn[vehId] = left
    end
  end
end

-- A ghost started or ended: the one-shot companion to the roster, for latency
-- (a third of a second is long enough to be hit). Our own is ignored: we
-- applied it at once and only we may end it.
local function onGhost(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local pid = data.pid
  if pid == nil then return end
  if tostring(pid) == tostring(localServerId()) then return end
  local startedAt = tonumber(data.startedAt)
  local duration  = tonumber(data.duration)
  local endsAt    = nil
  if data.active ~= false and startedAt and duration then
    endsAt = startedAt + duration
  end
  ghost.applyRemote(pid, endsAt)
end

-- The server pulls a car back onto its slot: it owns the hold.
local function onHoldCorrect(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then data = {} end
  if not holdWanted then return end
  -- Prefer the server's slot coordinates (ours may be stale).
  if tonumber(data.x) and tonumber(data.y) and tonumber(data.z) then
    -- The SLOT, not the anchor: the car settles onto it again.
    hold.slot   = vec3(tonumber(data.x), tonumber(data.y), tonumber(data.z))
    hold.anchor = nil
    if tonumber(data.hx) and tonumber(data.hy) then
      hold.rot = headingRot(tonumber(data.hx), tonumber(data.hy))
    end
  end
  hold.correctLeft = 0        -- a server correction is never rate-limited away
  hold.restore('server correction: ' .. tostring(data.reason or 'moved off the grid'))
  pushNotice('grid', 'Held on the grid, wait for the lights')
end

-- The server credited a lap (the caution's free pass). A CORRECTION, not a
-- notice: localLap stamps progress reports (the server drops mismatches),
-- numbers the joker and times the flags. It sends the lap, not a delta, so a
-- lost message is corrected by the next.
local function onLapCredit(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local lap = math.floor(tonumber(data.lap) or 0)
  if lap <= 0 or lap == session.localLap then return end
  session.localLap = lap
  if data.reason == 'luckydog' then
    pushNotice('flag', 'FREE PASS - YOU GET YOUR LAP BACK',
      { sub = 'Restart at the tail of the lead lap', color = 'green' })
  else
    pushNotice('session', 'Lap credited: you are on lap ' .. lap)
  end
  log('I', 'raceManager', 'Server credited a lap: now on lap ' .. lap
    .. ' (' .. tostring(data.reason or 'no reason given') .. ')')
end

-- A server notice, through pushNotice like every local one.
local function onNotice(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local msg = data.msg and tostring(data.msg) or ''
  if msg == '' then return end
  -- The color only from a known set: it becomes a CSS class name.
  local color = data.color and tostring(data.color) or nil
  if color and not color:match('^%a+$') then color = nil end
  pushNotice(tostring(data.kind or 'session'), msg,
    { sub = data.sub and tostring(data.sub) or nil, color = color })
end

-- --- Module 1: forced spectator mode (server -> client) --------------------
-- 1st, 2nd, 3rd: the teens (11th to 13th) take "th".
local function ordinal(n)
  n = math.floor(tonumber(n) or 0)
  if n <= 0 then return tostring(n) end
  local suffix = 'th'
  local last, teen = n % 10, n % 100
  if teen < 11 or teen > 13 then
    if last == 1 then suffix = 'st'
    elseif last == 2 then suffix = 'nd'
    elseif last == 3 then suffix = 'rd' end
  end
  return tostring(n) .. suffix
end

-- Exposed for tests/ghost_test.lua.
M.ordinalForTest = ordinal

local function onForceSpectate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then data = {} end
  local source = data.source and tostring(data.source) or 'race'
  enterSpectator(data.reason and tostring(data.reason) or nil, source)
  -- THE CHECKERED FLAG for this driver, once, as they leave the session (a
  -- backmarker too). Not for a derby. The placing rides as the second line.
  if source ~= 'derby' and not flags.checkered then
    flags.checkered = true
    local place = tonumber(data.place)
    local placed = (place and place > 0) and ('You placed ' .. ordinal(place)) or nil
    if flags.checkeredSeen then
      -- The flag was waved on the approach: say only the placing.
      if placed then
        pushNotice('finish', placed)
      end
    else
      -- No approach flash (time expired, DNF, admin): this is the only one.
      pushNotice('flag', 'CHECKERED FLAG', { sub = placed, color = 'checkered' })
    end
  end
end

local function onReleaseSpectate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then data = {} end
  local source = data.source and tostring(data.source) or nil
  local order, count = tonumber(data.order), tonumber(data.count)
  -- `order`/`count` stagger the field.
  if session.spectatorLock then
    releaseSpectator(source, order, count)
    return
  end
  -- Still running at session end: nothing to put back, but the field may land
  -- around us, so we take the placement ghost too.
  if queueFieldPlacement then
    queueFieldPlacement({ order = order, count = count })
  end
end

-- --- Module 4: the server refused this client's vehicle/setup --------------
-- `remove`: the car goes, here (the server cannot delete it). Without it (an
-- admin racing) the driver is told and listed but keeps the car, since an
-- unapproved car must be drivable to be captured.
local function onVehicleRejected(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  local msg = (ok and type(data) == 'table' and data.message)
    and tostring(data.message) or 'Vehicle/Setup not allowed in this session.'
  local detail = (ok and type(data) == 'table' and data.detail) and tostring(data.detail) or ''
  local remove = ok and type(data) == 'table' and data.remove == true
  guihooks.trigger('RaceManagerVehicleError', { message = msg, detail = detail })
  -- The detail rides as `sub` for the HUD copy.
  pushNotice('vehicle', msg, { sub = detail ~= '' and detail or nil })
  local gone = false
  if remove then gone = deleteOwnVehicleNow() end
  log('W', 'raceManager', 'Vehicle rejected by the server: ' .. msg .. ' (' .. detail .. ')'
    .. (remove and (gone and ' [car deleted]' or ' [CAR NOT DELETED]') or ' [advisory only]'))

  -- Which rejection? Declaring exactly what was captured: the list lacks this
  -- car (re-capture). Moved since capture: the identity is drifting, and
  -- re-capturing will not hold.
  if garage.lastCaptured then
    if garage.lastDeclared == garage.lastCaptured then
      log('W', 'raceManager', 'The car is declaring exactly what was captured ('
        .. tostring(garage.lastCaptured) .. '), so its identity is STABLE: this '
        .. 'is a Garage List that does not contain this car')
    else
      log('E', 'raceManager', 'THE SIGNATURE MOVED since it was captured. '
        .. 'captured: ' .. tostring(garage.lastCaptured)
        .. ' | declaring: ' .. tostring(garage.lastDeclared)
        .. ' -- re-capturing will not hold while it keeps moving')
    end
  else
    log('W', 'raceManager', 'Nothing was captured from this client, so there is '
      .. 'nothing to compare: whitelist this car (with enforcing OFF) and the '
      .. 'next rejection will say whether its identity holds still')
  end
end

-- The server's ruling on an alias change, always surfaced.
local function onAliasResult(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local msg = tostring(data.message or '')
  if msg == '' then return end
  pushNotice(data.success == true and 'alias' or 'vehicle', msg)
  log('I', 'raceManager', 'Alias result: ' .. msg)
end

local function onGarageResult(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  editorMsg(tostring(data.message or ''))
  guihooks.trigger('RaceManagerGarageResult', data)
end

local function onServerCountdown(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  -- GO (0) or an abort (-1) releases the hold: the same broadcast for everyone.
  local count = tonumber(data.count)
  if count and count <= 0 then releaseGridHold('race') end
  guihooks.trigger('RaceManagerCountdown', data)
  if M.lightsCountdown then M.lightsCountdown(count) end
end

-- The map's layouts, with checkpoint arrays for the panel's preview.
local function onLayoutList(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    log('E', 'raceManager', 'RM_Layouts: undecodable payload: ' .. tostring(rawData):sub(1, 120))
    return
  end
  -- An empty list can arrive as {}: hand the UI a real array.
  if type(data.layouts) ~= 'table' or #data.layouts == 0 then data.layouts = {} end
  log('I', 'raceManager', 'RM_Layouts: ' .. #data.layouts .. ' layout(s) for map ' .. tostring(data.map))
  guihooks.trigger('RaceManagerLayouts', data)
end

-- Cup standings and rules: a pure relay, the server decides everything.
local function onCupUpdate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    log('E', 'raceManager', 'RM_CupUpdate: undecodable payload')
    return
  end
  if not fromCurrentServer(data) then return end
  -- Empty arrays can arrive as {}: hand the UI real arrays.
  for _, key in ipairs({ 'standings', 'presets', 'bonuses', 'roster', 'connected',
                         'racePoints', 'derbyPoints', 'qualiPoints' }) do
    if type(data[key]) ~= 'table' or #data[key] == 0 then data[key] = {} end
  end
  guihooks.trigger('RaceManagerCup', data)
end

-- The server pushed a layout: purge, then apply.
local function onApplyLayout(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' or type(data.checkpoints) ~= 'table' then
    log('E', 'raceManager', 'RM_ApplyLayout: undecodable payload: ' .. tostring(rawData):sub(1, 120))
    return
  end
  -- THE SAME TRACK AGAIN IS A NO-OP. Re-applying resets lap tracking, and a UI
  -- reload (radial menu, HUD Apps) re-requests state: mid-race that sent the
  -- driver back to checkpoint 1 and lost the lap.
  if rawData == track.appliedRaw and #track.route > 0 and edit.fingerprint() == edit.stamp then
    log('I', 'raceManager', 'Layout "' .. tostring(data.name) .. '" re-sent unchanged: kept as is')
    return
  end
  local function unbundle(src, what)
    local out = {}
    for i, cp in ipairs(src) do
      local x, y, z = tonumber(cp.x), tonumber(cp.y), tonumber(cp.z)
      if not (x and y and z) then
        log('E', 'raceManager', 'RM_ApplyLayout: ' .. what .. ' checkpoint ' .. i
          .. ' has invalid coordinates, layout rejected')
        return nil
      end
      out[i] = { x = x, y = y, z = z, hx = tonumber(cp.hx) or 0, hy = tonumber(cp.hy) or 1 }
      -- A gate without its own size takes the layout's stored default.
      if what ~= 'start position' then
        out[i].width = clampWidth(tonumber(cp.width) or data.width or track.checkpointWidth)
        local h = tonumber(cp.height) or data.height
        local d = tonumber(cp.depth)  or data.depth
        if d == nil and h ~= nil then
          -- Legacy full-span height, centered: split in half, once, on load.
          out[i].height = clampHeight(h * 0.5)
          out[i].depth  = clampDepth(h * 0.5)
        else
          out[i].height = clampHeight(h or track.checkpointHeight)
          out[i].depth  = clampDepth(d or track.checkpointDepth)
        end
      end
    end
    return out
  end
  local cps = unbundle(data.checkpoints, 'route')
  if not cps or #cps == 0 then
    log('E', 'raceManager', 'RM_ApplyLayout: empty or invalid checkpoint list, layout rejected')
    return
  end
  local jokerCps = {}
  if type(data.joker) == 'table' and #data.joker > 0 then
    jokerCps = unbundle(data.joker, 'joker') or {}
  end
  local starts = {}
  if type(data.startPositions) == 'table' and #data.startPositions > 0 then
    starts = unbundle(data.startPositions, 'start position') or {}
  end
  local pits = {}
  if type(data.pits) == 'table' and #data.pits > 0 then
    pits = unbundle(data.pits, 'pit stall') or {}
    -- A stall with no length inherited a checkpoint's width: default box.
    local migrated = 0
    for i, s in ipairs(pits) do
      s.length = tonumber(data.pits[i].length)
      if not s.length then s.width = nil; migrated = migrated + 1 end
      s.width, s.length = pit.dims(s)
    end
    if migrated > 0 then
      log('I', 'raceManager', migrated .. ' pit stall(s) from an older layout set to the default box size')
    end
  end
  local pitIn, pitOut = {}, {}
  if type(data.pitEntry) == 'table' and #data.pitEntry > 0 then
    pitIn = unbundle(data.pitEntry, 'pit entry') or {}
  end
  if type(data.pitExit) == 'table' and #data.pitExit > 0 then
    pitOut = unbundle(data.pitExit, 'pit exit') or {}
  end
  -- Markers, with their symbols validated.
  local marks = {}
  if type(data.markers) == 'table' and #data.markers > 0 then
    marks = unbundle(data.markers, 'marker') or {}
    for i = 1, #marks do
      marks[i].kind = marker.validKind(data.markers[i] and data.markers[i].kind) or 'right'
    end
  end
  -- Branch gates, resolved ONCE into slot -> gates. A gate whose checkpoint is
  -- not in this layout is DROPPED, never clamped onto another corner.
  local alts, bySlot = {}, {}
  if type(data.branches) == 'table' then
    for _, g in ipairs(data.branches) do
      local slot = tonumber(g.slot)
      local x, y, z = tonumber(g.x), tonumber(g.y), tonumber(g.z)
      if slot and x and y and z and slot >= 1 and slot <= #cps then
        slot = math.floor(slot)
        local gate = {
          slot = slot, x = x, y = y, z = z,
          hx = tonumber(g.hx) or 0, hy = tonumber(g.hy) or 1,
          width  = clampWidth(tonumber(g.width) or data.width or track.checkpointWidth),
          height = clampHeight(tonumber(g.height) or data.height or track.checkpointHeight),
          depth  = clampDepth(tonumber(g.depth) or data.depth
            or ((tonumber(g.height) or data.height or 0) * 0.5)),
        }
        if g.oneWay == true then gate.oneWay = true end
        alts[#alts + 1] = gate
        local at = bySlot[slot]
        if not at then at = {}; bySlot[slot] = at end
        at[#at + 1] = gate
      end
    end
  end

  -- REFUSED while the local editor holds unsaved work (edit.holdsBuffer),
  -- checked after validation. Nothing is queued: the admin saves, or presses
  -- Load to take the server's copy.
  if edit.holdsBuffer() then
    edit.refused = tostring(data.name or '')
    editorMsg('"' .. edit.refused .. '" was loaded on the server. Your unsaved '
      .. 'editor work has been kept: Save it, or press Load to take the server\'s.')
    log('W', 'raceManager', 'RM_ApplyLayout("' .. edit.refused
      .. '") refused: the local editor buffer has unsaved changes')
    return
  end

  clearTrackState('applying layout "' .. tostring(data.name) .. '"')
  track.route      = cps
  track.jokerRoute = jokerCps
  track.pitRoute   = pits
  track.pitEntry   = pitIn
  track.pitExit    = pitOut
  -- A new track: not in its pit lane until we drive into it.
  pit.inLane = false
  marker.list = marks
  props.list  = props.unbundle(data.props)
  track.startPositions = starts
  branch.list   = alts
  branch.bySlot = bySlot
  branch.gridOffLine = data.gridOffLine == true
  track.checkpointWidth  = clampWidth(data.width or track.checkpointWidth)
  -- The layout's default is migrated the same way, or new gates stand twice
  -- as tall as the loaded ones.
  if data.depth == nil and data.height ~= nil then
    track.checkpointHeight = clampHeight(data.height * 0.5)
    track.checkpointDepth  = clampDepth(data.height * 0.5)
  else
    track.checkpointHeight = clampHeight(data.height or track.checkpointHeight)
    track.checkpointDepth  = clampDepth(data.depth or track.checkpointDepth)
  end
  track.pointToPoint     = data.pointToPoint == true
  track.dragStrip        = track.pointToPoint and data.drag == true
  resetLapTracking()
  track.appliedRaw = rawData
  -- The baseline for drift, stamped AFTER the whole apply.
  edit.stamp   = edit.fingerprint()
  edit.refused = nil
  editorMsg('Loaded layout "' .. tostring(data.name) .. '" ('
    .. (track.dragStrip and 'drag strip, ' or track.pointToPoint and 'point to point, ' or '')
    .. #track.route .. ' gates'
    .. (#track.jokerRoute > 0 and (' + ' .. #track.jokerRoute .. ' joker') or '')
    .. (#track.startPositions > 0 and (', ' .. #track.startPositions .. ' grid slots') or '')
    .. (#props.list > 0 and (', ' .. #props.list .. ' props') or '') .. ')')
  log('I', 'raceManager', 'Applied server layout "' .. tostring(data.name)
    .. '" with ' .. #track.route .. ' checkpoints, ' .. #track.jokerRoute .. ' joker gates and '
    .. #track.startPositions .. ' start positions')
end

-- The server refused an overwrite that would have emptied part of a layout. The
-- UI asks the admin and re-sends confirmed if that is what they meant.
local function onSaveHeld(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local lost = type(data.lost) == 'table' and data.lost or {}
  local label = {
    joker = 'joker gates', pits = 'pit stalls',
    pitEntry = 'pit entry gates', pitExit = 'pit exit gates',
    startPositions = 'start positions', branches = 'branch gates',
    markers = 'direction markers', props = 'props',
  }
  local parts = {}
  for key, n in pairs(lost) do
    parts[#parts + 1] = tostring(n) .. ' ' .. (label[key] or key)
  end
  table.sort(parts)
  guihooks.trigger('RaceManagerSaveHeld', {
    name = tostring(data.name or ''),
    lost = lost,
    summary = table.concat(parts, ', '),
  })
  log('W', 'raceManager', 'Save held back: overwriting "' .. tostring(data.name)
    .. '" would drop ' .. table.concat(parts, ', '))
end

-- The server ordered a full purge (startup, before a layout load, a clear).
local function onClearTrack(rawData)
  local reason = 'server'
  local ok, data = pcall(jsonDecode, rawData)
  if ok and type(data) == 'table' and data.reason then reason = tostring(data.reason) end
  -- Refused while the editor holds unsaved work too: a load purges before it
  -- applies, and guarding only the apply would leave an EMPTY editor.
  if edit.holdsBuffer() then
    log('W', 'raceManager', 'RM_ClearTrack (' .. reason
      .. ') refused: the local editor buffer has unsaved changes')
    return
  end
  clearTrackState('server: ' .. reason)
  -- The buffer is the server's again: drop the stamp, or a clean editor reads
  -- as dirty and refuses the layout it was waiting for.
  edit.stamp = nil
end

-- The login result, for the UI.
local function onLoginResult(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  -- Kept here too: the UI's copy dies with the app.
  session.isAdmin = data.success == true
  -- The tier granted, cleared with the flag on a failure.
  session.role = session.isAdmin and (data.role or 'admin') or nil
  -- `lapsed`: a command was refused because the login expired. Said out loud,
  -- or it looks like the mod stopped working.
  guihooks.trigger('RaceManagerAuth', {
    success = session.isAdmin, role = session.role, lapsed = data.lapsed == true,
  })
  if data.lapsed == true then
    pushNotice('server', 'Admin session expired: log in again to run the session')
  end
  log('I', 'raceManager', 'Login result: ' .. tostring(session.isAdmin)
    .. (data.lapsed == true and ' (session lapsed)' or ''))
end

-- A command refused on the TIER, not the login: not RM_LoginResult, which
-- carries the admin flag and would log a moderator out. On M for the ceiling.
function M.onDenied(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  local why = (ok and type(data) == 'table' and data.reason) and tostring(data.reason)
    or 'The server refused that command'
  editorMsg(why)
  pushNotice('server', why)
  log('W', 'raceManager', 'Command refused: ' .. why)
end

-- An admin rotated one of the two master passwords (never the value); which one
-- is named.
local function onPasswordChanged(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  data = (ok and type(data) == 'table') and data or {}
  local by = data.changedBy and tostring(data.changedBy) or 'an admin'
  local what = 'Admin password'
  if data.role == 'moderator' then
    what = data.cleared == true and 'Moderator login turned off' or 'Moderator password'
  end
  local said = data.cleared == true and (what .. ' by ' .. by)
    or (what .. ' changed by ' .. by)
  editorMsg(said)
  -- Its own channel, so the admin bar confirms it with the editor closed.
  guihooks.trigger('RaceManagerPasswordChanged', {
    by = by, role = data.role, cleared = data.cleared == true,
  })
  log('I', 'raceManager', said)
end

-- ---------------------------------------------------------------------------
-- Admin authentication (called by the UI app)
-- ---------------------------------------------------------------------------
-- Submit the password; RM_LoginResult answers.
function M.login(password)
  if inMultiplayer() then
    TriggerServerEvent('RM_Login', jsonEncode({ password = tostring(password or '') }))
  else
    -- Offline: local admin outright, so the editor works single-player.
    session.isAdmin = true
    session.role = 'admin'
    guihooks.trigger('RaceManagerAuth', { success = true, role = 'admin', offline = true })
    pushRouteState()
  end
end

-- Log out.
function M.logout()
  -- The durable copy first, or the next route push hands admin back.
  session.isAdmin = false
  session.role = nil
  if inMultiplayer() then TriggerServerEvent('RM_Logout', '') end
  pushRouteState()
end

-- Rotate a master password: `role` 'moderator', else the admin's. An EMPTY
-- moderator password switches the tier off and is sent; an empty admin
-- password has no way back and is refused.
function M.changePassword(newPassword, role)
  newPassword = tostring(newPassword or '')
  local moderator = role == 'moderator'
  if newPassword == '' and not moderator then
    editorMsg('Enter a new password first')
    return
  end
  if inMultiplayer() then
    TriggerServerEvent('RM_ChangePassword', jsonEncode({
      password = newPassword, role = moderator and 'moderator' or 'admin',
    }))
  end
end

-- ---------------------------------------------------------------------------
-- Session commands (called by the UI app) -- all go to the server
-- ---------------------------------------------------------------------------
function M.startQualifying()
  if inMultiplayer() then TriggerServerEvent('RM_StartQualifying', '') end
end

function M.generateGrid()
  if inMultiplayer() then TriggerServerEvent('RM_GenerateGrid', '') end
end

-- An admin sets or clears a driver's display alias; the server owns it.
function M.setAlias(targetId, alias)
  -- BeamMP player ids are ZERO-BASED: only a negative id is invalid.
  targetId = tonumber(targetId)
  if not targetId then
    log('W', 'raceManager', 'setAlias: no target driver id')
    return
  end
  targetId = math.floor(targetId)
  if targetId < 0 then
    log('W', 'raceManager', 'setAlias: invalid target driver id ' .. tostring(targetId))
    return
  end
  if not inMultiplayer() then
    editorMsg('Display names need a BeamMP server')
    return
  end
  -- Logged on the way out: with no result notice after it, the server did not
  -- answer.
  log('I', 'raceManager', string.format('setAlias -> driver %d = "%s"', targetId, tostring(alias or '')))
  TriggerServerEvent('RM_SetAlias', jsonEncode({
    target = targetId,
    alias  = tostring(alias or ''),
  }))
end

-- Laps alone. The panel sends setRaceLimits now; kept as a console command and
-- the fallback if the combined limits ever go.
function M.setTotalLaps(n)
  n = math.floor(tonumber(n) or 0)
  if n < 1 then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_SetTotalLaps', jsonEncode({ laps = n }))
  end
end

-- Resets per driver per session: negative is unlimited, 0 forbids them.
function M.setMaxResets(n)
  n = math.floor(tonumber(n) or -1)
  if n < 0 then n = -1 end
  if inMultiplayer() then
    TriggerServerEvent('RM_SetMaxResets', jsonEncode({ maxResets = n }))
  else
    session.maxResets = n
    pushRouteState()
  end
end

-- What a legal reset does: repair in place, or respawn at the last checkpoint.
function M.setResetMode(mode)
  mode = (tostring(mode or 'inplace') == 'checkpoint') and 'checkpoint' or 'inplace'
  if inMultiplayer() then
    TriggerServerEvent('RM_SetResetMode', jsonEncode({ mode = mode }))
  else
    session.resetMode = mode
    pushRouteState()
  end
end

-- The pace lap: the race is started with Start Race, released under yellow.
function M.setPaceLap(enabled)
  enabled = enabled and true or false
  if inMultiplayer() then
    TriggerServerEvent('RM_SetPaceLap', jsonEncode({ enabled = enabled }))
  else
    session.paceLap = enabled
    pushRouteState()
  end
end

-- The joker lap requirement for the next race.
function M.setJokerEnabled(enabled)
  enabled = enabled and true or false
  if inMultiplayer() then
    TriggerServerEvent('RM_SetJokerEnabled', jsonEncode({ enabled = enabled }))
  else
    session.jokerEnabled = enabled
    pushRouteState()
  end
end

-- --- Settings relayed to the server ------------------------------------------
function M.setNametags(enabled)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetNametags',
      jsonEncode({ enabled = enabled and true or false }))
  end
end

function M.setGhostQuali(enabled)
  enabled = enabled and true or false
  if inMultiplayer() then
    TriggerServerEvent('RM_SetGhostQuali', jsonEncode({ enabled = enabled }))
  else
    ghostQuali = enabled
    pushRouteState()
  end
end

-- Race length. `mode` is sent explicitly: endurance sets both numbers, so the
-- numbers alone cannot say which mode it is.
function M.setRaceLimits(laps, seconds, mode)
  laps    = math.max(math.floor(tonumber(laps) or 0), 0)
  seconds = math.max(math.floor(tonumber(seconds) or 0), 0)
  mode    = tostring(mode or '')
  if mode ~= 'laps' and mode ~= 'timed' and mode ~= 'endurance' then mode = 'laps' end
  if inMultiplayer() then
    TriggerServerEvent('RM_SetRaceLimits',
      jsonEncode({ laps = laps, seconds = seconds, mode = mode }))
  end
end

function M.setQualiLimits(laps, seconds)
  laps    = math.max(math.floor(tonumber(laps) or 0), 0)
  seconds = math.max(math.floor(tonumber(seconds) or 0), 0)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetQualiLimits', jsonEncode({ laps = laps, seconds = seconds }))
  end
end

-- --- Starting grid ---------------------------------------------------------
-- How the server fills the grid.
function M.setGridMode(mode)
  mode = tostring(mode or 'quali')
  -- Every mode the server accepts must be listed here, or it normalizes to quali.
  if mode ~= 'random' and mode ~= 'custom' and mode ~= 'reverse'
     and mode ~= 'heats' and mode ~= 'points' and mode ~= 'pointsrev' then
    mode = 'quali'
  end
  if inMultiplayer() then
    TriggerServerEvent('RM_SetGridMode', jsonEncode({ mode = mode }))
  end
end

-- Custom grid: put one driver on one slot (the rest shuffle around them).
function M.setDriverGridSlot(pid, slot)
  -- Player ids are zero-based; slots are 1-based (1 is pole).
  pid  = tonumber(pid)
  slot = tonumber(slot)
  if not pid or not slot then
    log('W', 'raceManager', 'setDriverGridSlot: missing driver id or slot')
    return
  end
  pid, slot = math.floor(pid), math.floor(slot)
  if pid < 0 or slot < 1 then
    log('W', 'raceManager', string.format(
      'setDriverGridSlot: invalid driver id %d or slot %d', pid, slot))
    return
  end
  if inMultiplayer() then
    TriggerServerEvent('RM_SetDriverGrid', jsonEncode({ pid = pid, slot = slot }))
  end
end

function M.startCountdown()
  if inMultiplayer() then TriggerServerEvent('RM_StartCountdown', '') end
end

-- Start behind the pace car (instead of a countdown); refused unless armed.
function M.startRace()
  if inMultiplayer() then TriggerServerEvent('RM_StartRace', '') end
end

-- Full-course yellow and restart; the server polices both.
function M.caution()
  if inMultiplayer() then TriggerServerEvent('RM_Caution', '') end
end

function M.restart()
  if inMultiplayer() then TriggerServerEvent('RM_Restart', '') end
end

-- Wave a called restart off; the race stays neutralised.
function M.cancelRestart()
  if inMultiplayer() then TriggerServerEvent('RM_CancelRestart', '') end
end

-- The free pass rule: whether the first car a lap down takes its lap back.
function M.setLuckyDog(enabled)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetLuckyDog', jsonEncode({ enabled = enabled == true }))
  end
end

-- The heat program: count, transfer, and the heat distance.
function M.setHeats(count, transfer, laps)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetHeats', jsonEncode({
      count    = math.max(0, math.floor(tonumber(count) or 0)),
      transfer = math.max(0, math.floor(tonumber(transfer) or 0)),
      -- 0 is the race distance; nil leaves the server's value alone.
      laps     = laps ~= nil and math.max(0, math.floor(tonumber(laps) or 0)) or nil,
    }))
  end
end

function M.drawHeats()
  if inMultiplayer() then TriggerServerEvent('RM_DrawHeats', '') end
end

-- What the next draw is seeded on: 'quali', 'random' or 'points'.
function M.setHeatDraw(mode)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetHeatDraw', jsonEncode({ mode = tostring(mode or '') }))
  end
end

function M.setHeatCurrent(heat)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetHeatCurrent',
      jsonEncode({ heat = math.max(0, math.floor(tonumber(heat) or 0)) }))
  end
end

function M.endRace()
  if inMultiplayer() then TriggerServerEvent('RM_EndRace', '') end
end

function M.resetLeaderboard()
  if inMultiplayer() then TriggerServerEvent('RM_ResetLeaderboard', '') end
end

-- Delete the server's saved result files.
function M.clearResults()
  if inMultiplayer() then TriggerServerEvent('RM_ClearResults', '') end
end

-- ---------------------------------------------------------------------------
-- Cup / series points (called by the UI app) -- all go to the server
-- ---------------------------------------------------------------------------
-- Thin relays: the cup lives on the server.
function M.cupRequestState()
  if inMultiplayer() then TriggerServerEvent('RM_CupRequestState', '') end
end

function M.cupSetEnabled(enabled)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetEnabled',
      jsonEncode({ enabled = enabled and true or false }))
  end
end

function M.cupStart(name)
  if not inMultiplayer() then
    editorMsg('Cup points need a BeamMP server')
    return
  end
  TriggerServerEvent('RM_CupStart', jsonEncode({ name = tostring(name or '') }))
end

function M.cupReset()
  if inMultiplayer() then TriggerServerEvent('RM_CupReset', '') end
end

-- `target`: 'race' (default) or 'derby' table.
function M.cupSetPreset(preset, target)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetPreset', jsonEncode({
      preset = tostring(preset or ''),
      target = (tostring(target or 'race') == 'derby') and 'derby' or 'race',
    }))
  end
end

-- Named scoring systems, kept in cup.json; End Cup does not clear them.
function M.cupSavePreset(name)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSavePreset', jsonEncode({ name = tostring(name or '') }))
  end
end

function M.cupDeletePreset(key)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupDeletePreset', jsonEncode({ preset = tostring(key or '') }))
  end
end

-- "30,27,25,..." from the app to an array. Shape only: the server clamps.
local function cupParsePoints(csv)
  local out = {}
  for field in tostring(csv or ''):gmatch('[^,]+') do
    local n = tonumber(field)
    out[#out + 1] = n and math.floor(n) or 0
  end
  return out
end

-- Each sends ONE part of the rules; the server replaces only that part.
function M.cupSetRacePoints(csv)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetScoring', jsonEncode({ race = cupParsePoints(csv) }))
  end
end

-- Empty switches derby scoring off, as for qualifying.
function M.cupSetDerbyPoints(csv)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetScoring', jsonEncode({ derby = cupParsePoints(csv) }))
  end
end

-- Empty switches drag scoring off completely, bonuses included.
function M.cupSetDragPoints(csv)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetScoring', jsonEncode({ drag = cupParsePoints(csv) }))
  end
end

-- Empty switches qualifying points off: an empty table is "does not score".
function M.cupSetQualiPoints(csv)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetScoring', jsonEncode({ quali = cupParsePoints(csv) }))
  end
end

function M.cupSetBonus(key, value)
  key = tostring(key or '')
  if key == '' then return end
  local n = math.floor(tonumber(value) or 0)
  if n < 0 then n = 0 end
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetScoring', jsonEncode({ bonus = { [key] = n } }))
  end
end

-- What a DNF is worth: 'none', 'classified' (final order) or 'held' (the place
-- it was running when it stopped).
function M.cupSetDnfScoring(mode)
  mode = tostring(mode or 'none')
  if mode ~= 'none' and mode ~= 'classified' and mode ~= 'held' then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetScoring', jsonEncode({ dnfScoring = mode }))
  end
end

function M.cupSetFastestLapRule(required)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetScoring',
      jsonEncode({ fastestLapRequiresFinish = required and true or false }))
  end
end

-- --- Driver identity (admin-controlled) ------------------------------------
-- Add a not-yet-connected driver to the roster.
function M.rosterAdd(name)
  name = tostring(name or '')
  if name == '' then return end
  if not inMultiplayer() then
    editorMsg('The roster needs a BeamMP server')
    return
  end
  TriggerServerEvent('RM_RosterAdd', jsonEncode({ name = name }))
end

function M.cupBindDriver(targetPid, entryId)
  targetPid = tonumber(targetPid)
  if not targetPid or targetPid < 0 then return end
  if not inMultiplayer() then
    editorMsg('Driver assignment needs a BeamMP server')
    return
  end
  TriggerServerEvent('RM_CupBindDriver', jsonEncode({
    pid     = math.floor(targetPid),
    entryId = math.floor(tonumber(entryId) or 0),
  }))
end

function M.cupForgetDriver(entryId)
  entryId = tonumber(entryId)
  if not entryId then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_CupForgetDriver', jsonEncode({ entryId = math.floor(entryId) }))
  end
end

-- --- Manual adjustments ----------------------------------------------------
-- Correcting a cup by hand, keyed on the CUP ENTRY so it lands on the driver,
-- not on whoever holds that connection now.
function M.cupAdjust(entryId, delta, reason)
  entryId = tonumber(entryId)
  delta   = tonumber(delta)
  if not entryId or not delta or delta == 0 then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_CupAdjust', jsonEncode({
      entryId = math.floor(entryId),
      delta   = math.floor(delta),
      reason  = tostring(reason or ''),
    }))
  end
end

function M.cupRemoveAdjust(entryId, index)
  entryId = tonumber(entryId)
  index   = tonumber(index)
  if not entryId or not index then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_CupRemoveAdjust', jsonEncode({
      entryId = math.floor(entryId), index = math.floor(index),
    }))
  end
end

-- Drop a whole round from a driver (the server's honest fix for a mis-scored
-- race). No panel control calls this yet: console only.
function M.cupDropRound(entryId, round)
  entryId = tonumber(entryId)
  round   = tonumber(round)
  if not entryId or not round then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_CupDropRound', jsonEncode({
      entryId = math.floor(entryId), round = math.floor(round),
    }))
  end
end

function M.requestState()
  pushRouteState()
  if inMultiplayer() then
    -- haveTrack: the server keeps the track to itself, or a UI reload would swap
    -- a practice or private editor track for the public one.
    TriggerServerEvent('RM_RequestState',
      #track.route > 0 and jsonEncode({ haveTrack = true }) or '')
    TriggerServerEvent('RM_RequestLayouts', '')
    TriggerServerEvent('RM_CupRequestState', '')
  else
    -- Offline: push a state so the UI renders, and grant local admin so the
    -- editor works. The flag itself, or the next route push takes it away.
    session.isAdmin = true
    guihooks.trigger('RaceManagerUpdate', { phase = 'waiting', raceTime = 0, totalLaps = session.totalLaps, drivers = {} })
    guihooks.trigger('RaceManagerAuth', { success = true, offline = true })
    log('W', 'raceManager', 'Racing is multiplayer-only; the checkpoint editor works offline')
  end
end

-- Server -> client wiring through a GLOBAL dispatch table that each (re)load
-- overwrites: older BeamMP builds cannot remove a handler, so binding closures
-- directly left a stale instance's handlers alive (one cause of the UI
-- flickering between two states). Bound once per game session. A fixed SOURCE
-- makes re-registration idempotent on builds that key handlers by it.
local HANDLER_SOURCE = 'raceManager'
local DISPATCH = {
  RM_Practice        = onPractice,
  RM_Update          = onServerUpdate,
  RM_Countdown       = onServerCountdown,
  RM_Layouts         = onLayoutList,
  RM_ApplyLayout     = onApplyLayout,
  RM_SaveHeld        = onSaveHeld,
  RM_ClearTrack      = onClearTrack,
  RM_LoginResult     = onLoginResult,
  RM_PasswordChanged = onPasswordChanged,
  -- A command refused on the moderator tier (not a lapsed login).
  RM_Denied          = M.onDenied,
  -- Module 1: forced spectator mode (used by racing and, separately, by derby)
  RM_ForceSpectate   = onForceSpectate,
  RM_ReleaseSpectate = onReleaseSpectate,
  -- Module 4: garage list enforcement feedback
  RM_VehicleRejected = onVehicleRejected,
  RM_GarageResult    = onGarageResult,
  -- One garage entry with its car in it, answering a press of Take.
  RM_GarageCar       = onGarageCar,
  -- The Garage List itself, when it changes.
  RM_Garage          = M.onGarage,
  RM_AliasResult     = onAliasResult,
  -- Starting grid: the server hands out slots, this client places the car.
  RM_GridAssign      = onGridAssign,
  -- Reset ghosting: someone's car went intangible (or came back).
  RM_Ghost           = onGhost,
  -- A derby car coming back on a life: everyone ghosts it while it lands.
  RM_DerbyGhost      = ghost.onDerbyRespawn,
  -- Grid hold: the server pulling a car back onto its slot.
  RM_HoldCorrect     = onHoldCorrect,
  -- Something the FIELD needs to read, pushed by the server.
  RM_Notice          = onNotice,
  -- A lap handed to this driver without a crossing (the caution's free pass).
  RM_LapCredit       = onLapCredit,
  -- Cup / series points
  RM_CupUpdate       = onCupUpdate,
  -- A copy of a results file, for an admin who cannot reach the server's.
  RM_ResultsFile     = M.onResultsFile,
  -- Demo Derby module
  RM_DerbyUpdate     = derby.onDerbyUpdate,
  RM_DerbyLayouts    = derby.onDerbyLayoutList,
  RM_DerbyGridAssign = derby.onDerbyGridAssign,
  RM_DerbyLifeLost   = derby.onDerbyLifeLost,
  RM_DerbyCountdown  = derby.onDerbyCountdown,
  -- Drag racing module
  RM_DragUpdate      = drag.onDragUpdate,
  RM_DragLane        = drag.onDragLane,
  RM_DragTree        = drag.onDragTree,
  RM_DragTreeWatch   = drag.onDragTreeWatch,
  RM_DragAborted     = drag.onDragAborted,
  -- Map switching module: the map list and the switch in progress.
  RM_Maps            = M.onMaps,
  -- Lap records module: one map's boards, asked for or changed.
  RM_Records         = M.onRecords,
}

local function bindServerHandlers()
  if not (inMultiplayer() and AddEventHandler) then return false end
  rawset(_G, 'raceManagerDispatch', DISPATCH)
  if rawget(_G, 'raceManagerHandlersBound') then return true end
  rawset(_G, 'raceManagerHandlersBound', true)
  for name in pairs(DISPATCH) do
    AddEventHandler(name, function (rawData)
      local d = rawget(_G, 'raceManagerDispatch')
      local fn = d and d[name]
      if fn then fn(rawData) end
    end, HANDLER_SOURCE)
  end
  return true
end

-- A RESET THE INPUT FILTER SWALLOWED. INERT ON THE CURRENT BUILD, KEPT: BeamNG
-- drops a filtered action in C++ before any Lua hook, so this never sees one.
-- It is the shape the answer would take if a build ever routes blocked actions
-- here. The panel's OUT marker covers it today. Guarded on block.resetInputs
-- first: an analog axis fires this constantly.
function M.onFilteredInputChanged(devName, action, value)
  if not block.resetInputs then return end
  -- Presses only: a release arrives as 0.
  if not value or value <= 0 then return end
  if type(action) ~= 'string' then return end
  local wanted = false
  for i = 1, #block.RESET_ACTIONS do
    if block.RESET_ACTIONS[i] == action then wanted = true; break end
  end
  if not wanted then return end
  if block.noticeLeft > 0 then return end
  block.noticeLeft = block.NOTICE_EVERY
  -- Recorded on the server too, like any refused reset.
  if inMultiplayer() then TriggerServerEvent('RM_ResetDenied', '') end
  if derbyResetsEnforced() then
    pushNotice('resetsout', "Uh oh! You're out of resets",
      { sub = 'All ' .. derbyResets.max .. ' derby resets used', color = 'amber' })
  elseif session.maxResets == 0 then
    pushNotice('resetsout', 'No resets in this session',
      { sub = 'You are on your own out there', color = 'amber' })
  else
    pushNotice('resetsout', "Uh oh! You're out of resets",
      { sub = 'All ' .. session.maxResets .. ' used', color = 'amber' })
  end
  log('W', 'raceManager', 'Reset key pressed with no allowance left (input filtered)')
end

function M.onExtensionLoaded()
  bindServerHandlers()
  log('I', 'raceManager', 'Race Manager client bridge loaded (build ' .. RM_BUILD
    .. ', multiplayer=' .. tostring(inMultiplayer()) .. ')')
end

-- Everything this client enforces, switched off, on unload and at session end:
-- each is a rule the SERVER owns, and with no server left nothing lifts it.
local function resetToIdle(reason)
  session.phase = 'waiting'
  -- The admin login (and tier) ends with the session.
  session.isAdmin = false
  session.role = nil
  edit.open = false
  clearTrackState(reason)
  releaseSpectator(nil)
  -- No ticks are coming: settle whatever the placement queue still owes.
  flushFieldPlacement()
  releaseGridHold()
  practice.stop('idle')
  clearGhostReasons()
  setResetInputsBlocked(false)   -- never leave the reset keys dead after unload
  spectate.setPropulsionBlocked(false)  -- nor the throttle
  -- And the driving and grabber filters: nothing loaded could give them back.
  spectate.setInputsBlocked(false)
  spectate.setGrabberBlocked(false)
  holdWanted = nil               -- nothing is meant to be held any more
  session.maxResets       = -1
  session.resetsUsed      = 0
  session.resetMode       = 'inplace'
  lastGate        = nil
  block.selfTeleport.left = 0
  block.noticeLeft = 0
  session.jokerEnabled    = false
  -- Both halves of the pace lap: the next server's races are not one lap long.
  session.paceLap         = false
  session.pacing          = false
  session.caution         = false
  session.cautionLaps     = 0
  session.cautionPending  = false
  session.restartPending  = false
  session.beingLapped     = false
  session.lappingAhead    = false
  session.heatCount       = 0
  session.heatCurrent     = 0
  session.heatLaps        = 0
  session.myHeat          = nil
  track.pitRoute        = {}
  pit.active      = false
  pit.left        = 0
  pit.settleLeft  = 0
  pit.cooldown    = 0
  pit.promptLeft  = 0
  -- The cars are already swept clean; this drops our record of the pit ghost.
  pit.ghostVeh    = nil
  pit.ghostSent   = false
  edit.target    = 'main'
  lastReportedSig = nil
  session.gridSlot        = nil
  finalLap        = false
  ghostQuali      = false
  -- The derby module's state too.
  derby.derbyState.phase    = 'idle'
  derby.derbyState.boundary = {}
  derby.derbyState.boundaryMode = 'polygon'
  derby.derbyState.shape    = nil
  derby.derbyState.editorOpen = false
  -- Drops the cache's reference to the old arena so it can be collected.
  derby.derbyState.draw     = nil
  derby.derbyState.starts   = {}
  derby.derbyState.slot     = nil
  derby.derbyState.out      = false
  derbyResets.max  = -1
  derbyResets.used = 0
  derby.derbyClearWarnings()
  -- Push again: clearTrackState pushed before the values below were reset.
  pushRouteState()
end

function M.onExtensionUnloaded()
  -- Resident across sessions (manual unload), so purge explicitly.
  resetToIdle('extension unloaded')
  -- No frame is coming to take the props out.
  props.destroy()
end

-- The level's objects die with it; drop the ids so none is deleted by mistake
-- once the next level reuses them.
function M.onClientEndMission()
  props.forget()
end

-- ---------------------------------------------------------------------------
-- BeamMP session lifecycle
-- ---------------------------------------------------------------------------
-- Leaving a BeamMP server: every rule the server applied here (dead reset
-- keys, a grid freeze, a spectator lock) is lifted by a broadcast that is never
-- coming, so the session hooks purge. v4.22.0 renamed them with an onBeamMP*
-- prefix; both names are registered and only one fires.
local function onSessionLeave()
  log('I', 'raceManager', 'BeamMP session ended: clearing local race state')
  nametag.clearAll()
  M.splashReset()
  resetToIdle('BeamMP session ended')
end

M.onBeamMPServerLeave = onSessionLeave   -- BeamMP v4.22.0+
M.onServerLeave       = onSessionLeave   -- BeamMP v4.21.1 and earlier

-- Joining: the extension may have loaded before BeamMP's network was ready and
-- bound nothing, so bind again (guarded) and ask for state a beat later, once
-- the launcher socket is up.
local function onSessionJoin()
  bindServerHandlers()
  joinRequestLeft = 1.0
  log('I', 'raceManager', 'BeamMP session joined: handlers bound, requesting state')
end

M.onBeamMPPostJoin = onSessionJoin       -- BeamMP v4.22.0+
M.runPostJoin      = onSessionJoin       -- BeamMP v4.21.1 and earlier
end

return M
