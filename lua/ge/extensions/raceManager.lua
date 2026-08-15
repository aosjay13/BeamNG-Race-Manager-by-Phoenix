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
-- One table rather than a local apiece, and that is not a style preference:
-- Lua allows at most 200 locals in a function, the top level of this file IS a
-- function, and it was already within a handful of that ceiling. Going over is
-- not a warning -- the file does not compile, and the whole mod is simply
-- absent. Constants are the cheapest thing to group, so they are grouped.
local TUNE = {
  DEFAULT_WIDTH = 20,    -- meters across the gate (lateral span)
  MIN_WIDTH = 2,
  MAX_WIDTH = 120,
  DEFAULT_HEIGHT = 10,    -- meters the trigger extends up/down (vertical)
  MIN_HEIGHT = 1,
  MAX_HEIGHT = 100,
  EDGE_RADIUS = 0.15,  -- meters; thickness of the drawn rectangle edge
  -- Thickness of a race POLE. Fatter than an editor edge -- this is the one a
  -- driver reads at a hundred miles an hour -- but only just: the first attempt
  -- at 0.35 read as a pair of pillars rather than a gate.
  POLE_RADIUS = 0.18,
  GHOST_ALPHA = 0.35,  -- mesh alpha applied to a ghosted car
  -- Reset ghosting. The DURATIONS are not here: they are a league rule, so the
  -- server owns them and broadcasts them (see ghost.rules). What is left is
  -- local presentation and local geometry, which no other client has an opinion
  -- about and which must never differ between two clients in a way that matters.
  GHOST_FADE_OUT_SEC     = 1.0,   -- fade back to solid over the last second
  GHOST_OVERLAP_MARGIN   = 0.25,  -- metres added to every bound before testing
  GHOST_OVERLAP_WARN_SEC = 10.0,  -- blocked this long: warn the driver, tell the server
  -- Last-resort separation when a car cannot be measured at all. Comfortably
  -- larger than the longest vehicle pair, so it is conservative -- but finite,
  -- which is the point: an unmeasurable car far away must not block a ghost
  -- forever.
  GHOST_FALLBACK_RADIUS = 9.0,
  -- Longest a ghost will wait for its car to report a bounding box before
  -- starting the timer anyway.
  GHOST_SETTLE_MAX = 1.0,
  -- Seconds; double-fire guard on the S/F gate. Kept low so even very short
  -- circuits report: this only needs to swallow same-crossing re-fires, not
  -- bound real lap times.
  LAP_DEBOUNCE = 2.0,
  -- Metres a start position may be from the start/finish line and still count as
  -- a grid stretching back from it. Sixty cars at eight metres a row is under
  -- 250, so past this the grid is somewhere else on the circuit and the first
  -- crossing is a part lap (see branch.gridIsOff).
  GRID_ON_LINE_RANGE = 250,
  -- Most cars a generated grid may put in one row. Two is a road-race grid and
  -- an oval's; three and four are short-track and dirt formats.
  GRID_MAX_WIDTH = 8,
  -- Metres a legal reset may move a car before it is treated as a RECOVERY
  -- teleport and undone. A repair in place moves it centimetres; BeamNG's
  -- recover/load-home drops it at a spawn point that is never this close.
  RECOVER_SNAP_RANGE = 25,
  PROGRESS_EVERY = 0.3,   -- seconds between live-position reports
  -- Live lap clock for the driver's own HUD. Pushed on a slow cadence and
  -- INTERPOLATED in the UI between pushes, which keeps the readout smooth
  -- without a guihook every frame. ~3.3 Hz: responsive enough to resolve a
  -- side-by-side fight, light enough that a full grid does not flood the server.
  LAP_TIME_EVERY = 0.25,
  -- Grid hold enforcement. The client tolerance is deliberately TIGHTER than the
  -- server's 0.5 m: the client checks every frame and the server four times a
  -- second, so the client should normally have pulled the car back before the
  -- server ever sees it move. A correction that reaches the server means the
  -- local guard did not fire, which is worth knowing about.
  HOLD_DRIFT       = 0.75,  -- metres off the settled slot before putting it back
  HOLD_CREEP_SPEED = 0.60,  -- m/s on the slot: a lost freeze, re-pin where it is
  -- A car dropped onto a start position falls onto its suspension. None of the
  -- enforcement above runs until that has finished, or it fights the settling
  -- and the car never comes to rest.
  HOLD_SETTLE_GRACE = 3.0,  -- seconds allowed for a placed car to come to rest
  HOLD_SETTLED_SPEED = 0.20, -- m/s under which a car counts as settled
  -- ...but not before this much of the grace has passed. A car reports no
  -- velocity on the frame it is placed, because it has not started falling yet,
  -- so "it is not moving" means nothing that early and would anchor the car at
  -- the height it was dropped from -- the very thing the settle window exists
  -- to avoid.
  HOLD_SETTLE_MIN  = 1.0,   -- seconds before stillness counts as settled
  HOLD_REPORT_EVERY = 0.25, -- seconds between position reports while held
  HOLD_CORRECT_COOLDOWN = 0.5, -- seconds after a correction before another
  -- Pit stalls. The dwell is what makes a stop cost something: long enough to
  -- be a real decision against carrying damage, short enough not to be a
  -- punishment. The repair lands part-way through so the car is whole before
  -- the driver gets it back.
  PIT_HOLD_SEC   = 5.0,
  PIT_REPAIR_AT  = 2.0,   -- seconds remaining when the repair is issued
  PIT_COOLDOWN   = 8.0,   -- before the same stall can trigger again
  PIT_DEPTH      = 3.0,   -- metres along the stall a car counts as being in it
  -- m/s below which the car counts as stopped IN the stall. A pit stop is
  -- something a driver performs, not something that happens to them: the stall
  -- used to trigger on the box alone, so clipping a corner of it at racing
  -- speed froze the car mid-lane. Now you have to bring it to a stop in the box
  -- yourself, and driving through without stopping simply misses the stop.
  -- Same threshold the derby uses for a stationary car, and generous enough to
  -- swallow physics jiggle.
  PIT_STOP_SPEED = 0.7,
  PIT_PROMPT_EVERY = 1.5, -- seconds between "stop in the box" reminders
  -- The joker gate's pole colour, and its colour once the joker has been taken.
  -- Pole colours set outright rather than lifted, because their stock value is
  -- black and there is no brighter version of black to compute.
  --
  -- `next` is the gate AFTER the one being aimed at. The engine ships it black
  -- because in its own races that gate is not your concern yet; this mod puts a
  -- marker there on purpose, so the line through the corner reads before the
  -- driver gets there. Orange, matching the editor's colour for the route
  -- ahead, and a shade under the gate actually being aimed at so the two are
  -- never confused for one another.
  POLE_MODE_RGB = {
    next = { 0.95, 0.45, 0.12 },
  },
  ROUTE_FILE = 'settings/raceManager/route.json',
}

-- Build stamp, pushed to the UI. Must match the server plugin and app.js -- see
-- the note in main.lua for why a mismatch is otherwise invisible.
local RM_BUILD = '0.8.0'

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local phase     = 'waiting'  -- mirrored from server broadcasts
local totalLaps = 5          -- mirrored from server broadcasts

-- Checkpoints: ordered list of { x, y, z, hx, hy } where (hx, hy) is the
-- normalized direction of travel captured at placement. The gate rectangle runs
-- perpendicular to it; the last checkpoint is the start/finish line. A gate may
-- also carry per-checkpoint width/height overrides; absent, it inherits the
-- global defaults below. Each checkpoint is a flat, upright rectangle:
-- width = lateral span, height = vertical extent (covers banking).
local route            = {}
-- Is this track a circuit or a sprint?
--
-- A point-to-point stage is driven once, from the first gate to the last, and
-- the last gate is a FINISH rather than a line you come back round to. Setting
-- a circuit to one lap gets the same timing, which is why it worked as a
-- workaround -- but it reads as a one-lap circuit everywhere it is shown, and a
-- driver on a sprint stage wants to be told they are on a sprint stage. It
-- belongs to the TRACK, so it travels with the layout.
local pointToPoint     = false

-- BRANCHING ROUTES (the other ways round this track).
--
-- A branch is a sparse set of per-slot gate overrides on `route`. Read the main
-- route's indices as SLOTS: at slot i, a driver on a branch must cross that
-- branch's gate for slot i, or the main gate when the branch has none. Slots a
-- branch does not override are shared, and crossed by everybody.
--
-- A branch therefore cannot add or remove slots, only substitute gates into the
-- ones that exist, and that is the whole design: every lane has the same number
-- of slots, so `armedWp` stays an integer index bounded by #route, the lap still
-- completes on armedWp >= #route whichever way round a driver went, and the
-- checkpoint count reported to the server means the same thing for all of them.
-- The running order needed no changes at all.
--
-- ONE TABLE, not eight locals. The top level of this file is a function and Lua
-- allows it 200 of them; this chunk is close enough to that ceiling that the tail
-- of the file is already scoped into a do...end block to get its registers back
-- (see the note above the server -> client handlers). `pit` is grouped the same
-- way for the same reason.
local branch = {
  -- As authored: { { id, name, gates = { { slot, x, y, z, hx, hy, ... }, ... } } }
  list   = {},
  -- Resolved once, when a layout is applied: id -> { [slot] = gate }. The
  -- per-frame path is one table index into this and nothing else -- no search,
  -- no allocation, and no work at all on a track with no branches.
  bySlot = {},
  -- Which lane THIS car is on: a branch id, or nil for the main route.
  lane   = nil,
  -- Was that lane assigned by the grid rather than chosen by driving? A head-on
  -- race locks it for the session; a rally-style split leaves it free per lap.
  lock   = false,
  -- Does this track grid its cars away from the start/finish line? Mirrored from
  -- the layout. Decides whether the first crossing is an out lap, and -- until it
  -- happens -- that the ONLY armed gate is the line itself (see armedGate).
  gridOffLine = false,
  -- Editor: the branch being edited, and the slot the next placed gate overrides.
  editId   = nil,
  editSlot = 1,
}
local checkpointWidth  = TUNE.DEFAULT_WIDTH
local checkpointHeight = TUNE.DEFAULT_HEIGHT
local visualize        = true

-- Starting grid: ordered list of { x, y, z, hx, hy } placed by the race
-- creator. Slot 1 is pole. Travels with the track layout; the server assigns a
-- slot number per driver and this client puts its own car on that slot.
local startPositions = {}
local gridSlot       = nil       -- slot the server assigned us for this race
local gridFrozen     = false     -- true while the freeze command has been issued
-- What the session WANTS held ('race' | 'derby' | nil), as opposed to whether
-- the freeze is currently applied. Separating intent from state is what lets the
-- freeze be put back at the one moment it is known to be lost: the vehicle reset
-- that a placement teleport causes. Forward-declared with the setter because
-- onVehicleResetted sits above the hold code and needs both.
local holdWanted     = nil
local setLocalVehicleFrozen      -- forward declaration, assigned further down

-- Grid hold enforcement.
--
-- The freeze used to be issued ONCE, at placement, and never checked again. That
-- is fine while it sticks and silently wrong when it does not, and there were
-- four ways for it not to stick: the placement teleport reports back as a
-- vehicle reset which reloads the vehicle's Lua VM and takes the freeze with it,
-- and the re-apply only happened when that report was recognised as our own echo
-- -- so a report arriving later than the 0.6 s echo window, a driver pressing
-- reset on the grid, and a vehicle reloaded or respawned on the grid all left
-- the car free. Nothing re-asserted it and nothing noticed, so any one of those
-- was permanent, and the driver simply drove away during the countdown.
--
-- So intent is now separated from effect and the effect is VERIFIED: while a
-- hold is wanted the car's distance from the slot it was put on is watched, and
-- drift is corrected. Correction is driven by observed movement and never by a
-- timer, which matters -- re-applying the freeze re-pins the car and resets the
-- drivetrain, so a car that is behaving has to be left completely alone or
-- revving against the hold and pre-selecting a gear (the point of a standing
-- start) would stop working.
--
-- Declared up here because onVehicleResetted, several hundred lines above the
-- hold code, is one of the places that has to put the hold back.
local hold = {
  -- Where the car came to REST after being placed. Captured once it has stopped
  -- moving, and it is what drift is measured against -- the slot coordinates are
  -- where the car was dropped, which is above the ground by however far it then
  -- falls onto its suspension.
  anchor      = nil,
  -- The slot itself, as a fallback for putting a car back before it has ever
  -- settled (a reset on the grid during the settle window).
  slot        = nil,
  rot         = nil,   -- the rotation it was placed with
  settleLeft  = 0,     -- seconds of grace left for a just-placed car to rest
  reportLeft  = 0,     -- seconds until the next position report to the server
  correctLeft = 0,     -- cooldown after a correction, so one slip is not a storm
  corrections = 0,     -- how many times this car has been pulled back
}
-- Ghosting is defined with the qualifying rules further down, but the placement
-- scheduler above it needs to switch it on: a field of cars being teleported
-- into position has to pass through each other on the way in. Forward-declared
-- rather than moved so the ghost code stays beside the rule it was built for.
local setGhostReason             -- forward declaration, assigned further down

-- Everything ghosting knows, in ONE table: its state, its mirrored rules and
-- its functions. Two reasons, and neither is a style preference.
--
-- The first is the local ceiling this file's TUNE table already exists for --
-- 194 of the 200 a function may hold are spoken for, and a module that needed a
-- local apiece for its state and another for each of its eight functions simply
-- would not compile. Hanging them off one table costs one.
--
-- The second is that it has to be declared HERE, above onVehicleResetted, which
-- is what arms a reset ghost -- while the ghost code itself belongs beside the
-- qualifying rule it grew out of, several hundred lines below. A table can be
-- declared early and filled in late; a local function cannot.
local ghost = {
  -- Per-VEHICLE ghost reasons: veh[gameVehId] = { reason = true, ... }, and a
  -- vehicle is ghosted while that set is non-empty. Per vehicle and not one
  -- global flag, because two drivers resetting a second apart are two
  -- independent ghosts and neither may end the other's.
  veh     = {},
  applied = {},   -- [gameVehId] = true while the ghost is actually applied
  -- Cars whose reasons have all gone but which still had another car inside
  -- them when the moment came. They stay ghosts and are retried until the space
  -- is clear -- no car is handed its collisions back with something in it.
  pending = {},
  -- Seconds of ghost left per vehicle, which is what the fade reads. Only reset
  -- ghosts have a remaining time; a quali or placement ghost has no clock and
  -- sits at a flat alpha until the reason is dropped.
  left    = {},
  -- Last mesh alpha actually pushed to each car, so the per-frame fade can skip
  -- the engine call when nothing moved.
  alpha   = {},
  -- The field-wide reasons currently in force ('quali', 'placement'), kept so
  -- the sweep can re-assert them onto cars that appeared since.
  field   = {},
  -- This client's own reset ghost. Only ever one: a repeat reset restarts this
  -- timer rather than stacking a second ghost beside it.
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
  -- Ghosts other clients told us about, so their cars are ghosts on OUR screen
  -- too: remote[pid] = the SERVER-CLOCK time the ghost ends.
  --
  -- An absolute end time and not a countdown, because a countdown starts the
  -- moment the message is opened -- so 200 ms of latency would buy the sender
  -- 200 ms of extra ghost on every other screen, and every receiver would
  -- disagree slightly about when the car goes solid. An end time on a clock both
  -- ends share means a late message produces a SHORTER remainder, never a longer
  -- one, and every receiver lands on the same instant.
  remote = {},
  -- Our best estimate of the server clock (race.time). Set from every state
  -- broadcast and advanced locally in between, so the remainder above is still
  -- meaningful on the frames between pushes.
  serverTime = 0,
  -- League rules, mirrored from the server broadcast. Defaults match the
  -- documented ones so a client that has not heard from the server yet still
  -- behaves sanely rather than ghosting forever.
  rules = { onReset = true, minSec = 5.0, maxSec = 15.0 },
  -- Why the local ghost is currently held past its timer, for the log. nil when
  -- it is not blocked.
  blockReason = nil,
  refresh  = 0,       -- seconds until the next re-assert sweep
  -- [pid] = the local vehicle id that player owns, resolved when a ghost is
  -- applied and re-checked on the sweep. Cached because the lookup builds a
  -- table and the fade below runs every frame.
  remoteVeh = {},
  hudLeft  = 0,       -- seconds until the next HUD push is due
  hudShown = false,   -- a HUD push has been sent that the UI is still showing
}

-- Rallycross joker route (Module 2): a second, completely separate gate set
-- describing the alternate route. Same checkpoint format as `route`; it travels
-- with the track layout and is only policed when the server arms the rule.
-- Pit stalls: a pit-lane AREA, deliberately kept out of `route`.
--
-- A pit stall is somewhere a driver may choose to go, not a checkpoint they
-- must pass in order. Putting one in the main route would make it mandatory
-- every lap and would put it inside lap and split validation, which is exactly
-- the contamination this is meant to avoid -- so pit stalls live in their own
-- list, like the joker route, and the checkpoint sequence never sees them.
--
-- Driving into one stops the car, repairs it in place and lets it go again.
local pitRoute     = {}
local pit = {
  active   = false,  -- a stop is running
  left     = 0,      -- seconds until release
  repaired = false,  -- the repair has been issued for this stop
  cooldown = 0,      -- a short delay before the same stall is live again
  -- The car has to LEAVE a stall before it can serve another stop in one.
  --
  -- The cooldown above was meant to be what stopped the box you are standing in
  -- re-triggering, but a timer only delays that: a car still parked in the
  -- stall when it expires is simply caught again, and again, forever -- frozen
  -- and ghosted each time, which reads from the driver's seat as "my car is
  -- stuck as a ghost for the rest of the race". Resetting in the pits puts you
  -- there, because a reset in place leaves the car exactly where it stood.
  --
  -- A stop is something a driver DRIVES INTO. Arriving is the trigger, so
  -- having left is the thing that re-arms it.
  mustLeave = false,
  stops    = 0,      -- how many this session, for the log
  -- Standing in a stall but still rolling. Held so the "stop in the box"
  -- reminder can be throttled: without it the prompt is a push per frame for
  -- as long as a car creeps through the box.
  promptLeft = 0,
  -- The vehicle this stop ghosted, so it can be un-ghosted again even if the
  -- car has since been replaced under us (a repair reloads the vehicle VM).
  ghostVeh = nil,
  -- Whether THIS stop is the thing that announced the ghost to the server. False
  -- when a reset ghost was already running and owns that broadcast.
  ghostSent = false,
}
local jokerRoute   = {}
local jokerEnabled = false       -- mirrored from the server broadcast
local jokerArmed   = 1           -- next joker gate the local car must cross
local jokerTaken   = false       -- joker route already completed this race
local jokerLapUsed = nil         -- lap the joker was taken on (for the UI)
local editorTarget = 'main'      -- which route the editor appends to: main | joker
-- Is the editor panel open in the UI app? Mirrored here because the start-slot
-- markers are drawn from Lua (debugDrawer) and the panel's open/closed state
-- only exists in the UI. Pushed by the app whenever its admin tab changes, on
-- mount, and on teardown -- so a closed app means a closed editor.
local editorOpen   = false

-- Local lap tracking (reset on every session change)
local armedWp      = 1           -- next gate the local car must cross
local timingActive = false       -- quali: false until the first S/F crossing (out-lap)
local lapStart     = 0           -- localTime at the start of the current lap
local localLap     = 1
local localTime    = 0
local prevPos      = nil         -- vehicle position last frame (crossing segment)

-- Live position telemetry: seconds until the next report of this car's distance
-- to the next checkpoint is due. The distance itself is computed inside that
-- report and nowhere else, so it needs no state up here.
local progressLeft = 0

-- Countdown to the state request fired after joining a BeamMP server (see the
-- session lifecycle hooks at the bottom of the file). nil = nothing pending.
local joinRequestLeft = nil

-- Vehicle reset ruleset (Module 1). maxResets mirrors the server: -1 unlimited,
-- 0 none, N allowed per session. resetsUsed counts what this client has spent.
-- Once the allowance is gone the reset is BLOCKED rather than punished: the car
-- is put straight back where it was, so pressing R buys nothing and costs
-- nothing. lastGood* is the rolling snapshot that restore uses.
local maxResets      = -1
local resetsUsed     = 0
local lastGoodPos    = nil       -- vec3-ish { x, y, z } sampled while driving
local lastGoodRot    = nil       -- quaternion { x, y, z, w } for the same sample
local snapshotLeft   = 0         -- seconds until the next snapshot is taken
local SNAPSHOT_EVERY = 0.25      -- seconds between "last good position" samples

-- What a LEGAL reset does while racing (mirrored from the server):
--   'inplace'    -- BeamNG's normal repair-where-you-stand (the default)
--   'checkpoint' -- the car is moved to the last checkpoint it crossed
local resetMode      = 'inplace'
local lastGate       = nil       -- last checkpoint the local car crossed (a wp table)
-- Was that crossing made BACKWARDS through the gate?
--
-- A gate shared between two lanes is stored with one heading and driven both
-- ways, so which way a car was actually going cannot be read off the gate
-- afterwards -- and relocateToGate stands the car facing the gate's heading. On a
-- head-on layout that would respawn half the field pointing into the oncoming
-- one. Recorded per crossing rather than declared per gate, so it is right for
-- shared gates, branch gates and ordinary gates alike.
local lastGateBack   = false

-- Once the allowance is spent the reset INPUTS themselves are switched off via
-- BeamNG's input action filter, so pressing R/Insert does nothing at all - the
-- car never resets, not even in place. The onVehicleResetted restore below
-- stays as a fallback for reset paths the filter cannot see.
--
-- That fallback is not optional any more: BeamNG v0.39 added a Vehicle
-- Management flow to the Pause menu with its own "repair and reset" buttons,
-- which is a reset the driver can reach without ever triggering one of the
-- input actions below. The filter still covers the keys and pads; the restore
-- in onVehicleResetted is what covers the Pause menu.
local RESET_ACTIONS = {
  'reset_physics', 'reset_all_physics', 'recover_vehicle', 'recover_vehicle_alt',
  'recover_to_last_road', 'reload_vehicle', 'reload_all_vehicles',
  'loadHome', 'dropPlayerAtCamera',
}
local resetInputsBlocked = false

-- BeamNG reports a teleport as a vehicle reset, and this mod teleports the car
-- itself (blocked-reset restore, grid placement, editor preview). Without a way
-- to tell those apart from the driver pressing reset, a blocked reset restored
-- the car, heard its own restore back as a fresh reset, restored again... an
-- endless loop that pinned the car in place and flooded the UI until the game
-- locked up. Every teleport we perform is recorded here (where and when), and a
-- reset reported from that spot inside the window is our own echo.
local selfTeleport   = { left = 0, x = 0, y = 0, z = 0 }
local TELEPORT_WINDOW = 0.6      -- seconds an echo of our own teleport can arrive in
local TELEPORT_RADIUS = 2.0      -- metres from where we put the car
-- Reset fires repeatedly while the key is held, so the feedback for a blocked
-- attempt (notice, log line, server report) is rate limited. The block itself
-- is applied on every single attempt.
local blockNoticeLeft = 0
local BLOCK_NOTICE_EVERY = 1.0   -- seconds between blocked-reset reports

-- Admin session. This lives HERE, not in the UI app, and that is the whole
-- point: BeamNG tears the HUD layer down and rebuilds it whenever the pause
-- menu opens, which destroys the app's Angular scope and everything in it. The
-- server session survives that (it is keyed by BeamMP player id and only
-- dropped on disconnect or an explicit logout), so the client's copy has to
-- survive it too, or every pause reads as a logout. This extension is resident
-- across the pause menu -- modScript sets it to manual unload -- so it is the
-- durable place to keep it. Pushed to the UI with every route state, and
-- re-confirmed by the server on RM_RequestState (which the app sends on mount).
local isAdmin   = false

-- Race entry (opt-in). Mirrored from the server so the UI can show a Join /
-- Leave button and whether entry is open to everyone or by request.
local entryMode = 'all'          -- 'all' (everyone races, the default) | 'join' (opt-in)
local joined    = false          -- this client is on the entry list

-- Qualifying: ghost mode + session limits, all mirrored from the server.
-- finalLap is the timed session's post-expiry state: the clock has run out and
-- the lap this driver is on is their last.
local finalLap       = false
-- Who holds the session's fastest lap, as of the last broadcast. Remembered so
-- the driver who sets it is congratulated once rather than on every broadcast
-- that carries the same pid afterwards.
local lastBestLapPid  = nil
-- ...and the time they set, so beating your OWN fastest lap is announced too.
local lastBestLapTime = nil
local ghostQuali     = false
local qualiLapLimit  = 0         -- 0 = unlimited
local qualiTimeLimit = 0         -- seconds, 0 = unlimited
-- Does this session open with an out lap -- one trip past the line that is not
-- timed and not scored? The server decides (it is off on a sprint stage, which
-- is driven once), and this client mirrors the answer so it can say so on the
-- driver's own readout before they have crossed anything.
local qualiOutLap    = false
-- Connected while somebody else's session was already running. Mirrored from
-- this client's own driver row: the server refuses to enter a mid-session
-- arrival and flags them instead, and the flag is what ghosts their car so they
-- cannot interfere with a race they are not in. Cleared when the next grid forms.
local isBystander    = false

-- Forced spectator mode (Module 1). Non-nil while this client is out of the
-- session: it holds the source ('race' or 'derby') that imposed the penalty, so
-- the isolated derby module and the racing state machine can never release each
-- other's spectators.
local spectatorLock   = nil
local spectatorReason = nil

local function inMultiplayer()
  return MPGameNetwork ~= nil and TriggerServerEvent ~= nil
end

-- The local player's vehicle. This is called several times per frame (gate
-- crossing, telemetry, the reset snapshot, the derby checks), so it goes
-- through the GE-side accessor BeamNG recommends: getPlayerVehicle(0) hands
-- back the object with no garbage collector churn, while be:getPlayerVehicle(0)
-- crosses into C++ and back on every call. v0.39 added a startup warning for
-- extensions that cost too much time, and BeamNG's own performance guide names
-- be:* accessors as the thing to stop doing, so the fast path is preferred and
-- the old call is kept only as the fallback for builds without it.
-- Which accessor exists is decided once, not per call.
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
-- playerVehicle() answers "which vehicle is this client currently attached to",
-- and in multiplayer that is NOT the same question as "which vehicle is ours".
-- The moment our own car is deleted -- which is exactly what happens to a driver
-- who takes the flag -- BeamNG hands the camera (and getPlayerVehicle) to
-- whatever vehicle is nearest to hand, which is another player's car.
--
-- Every consequence of that was in this session's bug report. The respawn is
-- guarded by "do I already have a car?", so a finisher watching a rival's car
-- was told yes and never got their own back. The camera was left wherever the
-- game had put it, so the whole field ended up watching the one driver whose
-- car still existed. And removeLocalVehicle would happily have deleted the
-- rival's car instead of ours.
--
-- So ownership is asked about explicitly, and everything that removes, respawns
-- or points a camera at "our" vehicle goes through ownVehicle() below.
-- nil when this BeamMP build (or singleplayer) cannot tell us who owns what, in
-- which case the attached vehicle is the best answer available and is used as-is.
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

local function vehicleId(veh)
  if not veh then return nil end
  local ok, id = pcall(function () return veh:getID() end)
  if ok then return id end
  return nil
end

-- The local player's OWN vehicle, or nil when they genuinely have none.
-- Falls back to a scan when the attached vehicle turns out to belong to someone
-- else: our car may still exist, we are simply not looking at it.
local function ownVehicle()
  local veh = playerVehicle()
  if not ownershipFn() then return veh end
  if veh and isOwnVehicle(vehicleId(veh)) then return veh end
  if type(getAllVehicles) == 'function' then
    local ok, list = pcall(getAllVehicles)
    if ok and type(list) == 'table' then
      for _, v in ipairs(list) do
        if v and isOwnVehicle(vehicleId(v)) then return v end
      end
    end
  end
  return nil
end

-- Per-frame vehicle sample.
--
-- Several update steps want the same two things in the same frame -- the local
-- car and where it is -- and each used to go and fetch them itself. getPosition()
-- crosses into C++ and back, so the gate-crossing test and the position
-- telemetry were paying for that round trip twice a frame to read one value that
-- cannot have changed between them.
--
-- Sampled LAZILY, not at the top of onUpdate: outside a session nothing asks,
-- and querying a vehicle every frame while sitting in the menus would be a
-- worse deal than the one this replaces. `localTime` advances exactly once per
-- frame, which makes it the frame stamp.
local sample = { at = -1, veh = nil, pos = nil }

local function sampledVehicle()
  if sample.at == localTime then return sample.veh, sample.pos end
  sample.at  = localTime
  sample.veh = playerVehicle()
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

-- Position + normalized heading of the local car, the one measurement every
-- editor placement (checkpoints, start positions, derby markers) is built from.
-- ---------------------------------------------------------------------------
-- Nudge mode: move and turn placed gates with the mouse, from free cam
-- ---------------------------------------------------------------------------
-- The second way into the editor, beside driving to a gate and pressing the
-- button. Driving is still how a track gets built: it puts the gate exactly
-- where a car fits and facing exactly the way one travels, which no amount of
-- clicking from above can work out for you. This is for the pass afterwards,
-- where a gate is ten metres late or a couple of degrees off and re-driving the
-- whole corner to fix it is the expensive part.
--
-- ONE top-level local, like `branch` and `spectate`. This file sits at Lua's
-- 200-active-locals ceiling and going over it does not warn: the file simply
-- stops compiling and the whole mod is gone.
--
-- THE MOUSE IS BORROWED, NOT TAKEN. In free cam the mouse IS the camera, so
-- there is no way to drag anything without first releasing it (core_canvas
-- wraps lockMouse for exactly this). That is why this is a mode you turn on and
-- off rather than something always live: a stray click while flying around
-- looking at a track must never move a gate.
local nudge = {
  on       = false,   -- mode active: cursor released, picking live
  sel      = nil,     -- index into the ACTIVE editor list, not always `route`
  -- The list `sel` indexes. Remembered rather than looked up, because the
  -- drawing asks about it and the drawing runs above activeEditorRoute.
  list     = nil,
  dragging = false,
  -- Engine bits, resolved once and remembered as false when a build has none.
  -- Everything here is optional: a build without them leaves the mode simply
  -- unavailable rather than erroring in the frame loop.
  im       = nil,
  ready    = nil,
}

-- How close the cursor ray has to pass to a gate to pick it, in metres. Gates
-- are up to 120m wide but are PICKED BY THEIR CENTRE, because two gates whose
-- rectangles overlap are exactly the case where a generous radius picks the
-- wrong one.
nudge.PICK_RADIUS  = 8
nudge.TURN_PER_STEP = math.rad(5)   -- one scroll notch

local function vehiclePlacement()
  local veh = playerVehicle()
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

-- Effective rectangle dimensions for a checkpoint: a per-gate override wins,
-- otherwise the global default. Always returned clamped so bad stored data
-- can't produce a degenerate (zero/negative) trigger surface.
-- A gate's size. Every gate placed or loaded now carries its own, so the
-- fallback is only reached by a gate from a layout saved before sizes were
-- per-gate -- and onApplyLayout fills those in from the layout's own stored
-- width/height as it loads, so even they only pass through here once.
local function gateDims(wp)
  return clampWidth(wp.width   or checkpointWidth),
         clampHeight(wp.height or checkpointHeight)
end

-- ---------------------------------------------------------------------------
-- UI push helpers
-- ---------------------------------------------------------------------------
-- The server needs to know how big this track's grid is so it can warn when
-- there are more drivers than start positions, but it has no way to see the
-- placements. Report the count whenever it actually changes - placing a slot,
-- deleting one, loading a layout - and never more often than that.
local lastReportedStarts = nil
-- Tell the server how many start positions this track has -- and, now, WHERE
-- they are.
--
-- The count alone was enough while the grid was purely a client-side affair: the
-- server handed out slot numbers and only needed to know how many existed. It
-- cannot police the hold with that, though, because "is this car on its slot" is
-- a question about coordinates. So the positions travel too, and the server
-- judges distance itself rather than trusting a client's arithmetic about its
-- own compliance.
--
-- Only sent on a change, which in practice means once when a track is loaded or
-- edited: the payload is a few dozen numbers, not something to repeat.
local function reportStartCount()
  if not inMultiplayer() then return end
  local n = #startPositions
  if n == lastReportedStarts then return end
  lastReportedStarts = n
  local positions = {}
  for i, sp in ipairs(startPositions) do
    positions[i] = { x = sp.x, y = sp.y, z = sp.z, hx = sp.hx, hy = sp.hy }
  end
  -- The lane NAMES ride along, but never the branch gates: the server has no
  -- physics and never tests a crossing, so the only thing it wants a lane for is
  -- the name in the results file. Sending gates it would have to validate against
  -- a route length it does not hold would be validation theatre.
  local laneNames = nil
  if #branch.list > 0 then
    laneNames = {}
    for i, b in ipairs(branch.list) do
      laneNames[i] = { id = b.id, name = b.name or b.id }
    end
  end
  TriggerServerEvent('RM_StartPositionCount', jsonEncode({
    count = n, positions = positions,
    laneNames = laneNames,
    gridOffLine = branch.gridIsOff(),
    -- The joker lap cannot be armed on a track with no joker route: the rule
    -- disqualifies anyone who did not complete it, and with no route that is
    -- everyone. The server needs the count to refuse it.
    jokerGates  = #jokerRoute,
  }))
end

local function pushRouteState()
  reportStartCount()
  guihooks.trigger('RaceManagerRoute', {
    clientBuild  = RM_BUILD,
    waypoints    = route,
    nextWp       = armedWp,
    width        = checkpointWidth,
    height       = checkpointHeight,
    visualize    = visualize,
    -- Starting grid
    startPositions = startPositions,
    pointToPoint   = pointToPoint,
    gridSlot       = gridSlot,
    gridFrozen     = gridFrozen,
    -- Admin session, so a freshly mounted UI app knows straight away that this
    -- client is still logged in (see the isAdmin declaration above).
    isAdmin      = isAdmin,
    -- Race entry (opt-in)
    entryMode    = entryMode,
    joined       = joined,
    -- Joker route (Module 2)
    pitRoute     = pitRoute,
    pitActive    = pit.active,
    pitLeft      = pit.left,
    jokerRoute   = jokerRoute,
    jokerNext    = jokerArmed,
    jokerTaken   = jokerTaken,
    jokerLap     = jokerLapUsed,
    jokerEnabled = jokerEnabled,
    editorTarget = editorTarget,
    nudgeOn      = nudge.on,
    nudgeSel     = nudge.sel,
    -- Branching routes (the other ways round this track)
    branches     = branch.list,
    branchEdit   = branch.editId,
    branchSlot   = branch.editSlot,
    lane         = branch.lane,
    laneLocked   = branch.lock,
    laneName     = branch.nameOf(branch.lane),
    gridOffLine  = branch.gridIsOff(),
    -- Is there a GENERATED grid the spacing sliders may move? They only ever
    -- touch slots the generator laid out; a grid placed by hand is left alone.
    gridGenerated = branch.gridTool.generated,
    gridSpacing   = branch.gridTool.spacing,
    gridStagger   = branch.gridTool.stagger,
    gridWidth     = branch.gridTool.width,
    -- Reset ruleset (Module 1)
    maxResets    = maxResets,
    resetsUsed   = resetsUsed,
    resetMode    = resetMode,
    spectating   = spectatorLock ~= nil,
  })
end

-- Dedicated, dismissable notice channel for regulation events (reset denied,
-- joker invalidated, vehicle rejected) so they don't get lost among the
-- editor's transient messages.
local function pushNotice(kind, msg)
  guihooks.trigger('RaceManagerNotice', { kind = kind, msg = msg })
end

-- Every state broadcast from the current server plugin carries this stamp. A
-- broadcast without it comes from an OUTDATED copy of the server plugin still
-- installed alongside this one - two copies alternating broadcasts is exactly
-- what made every UI element flicker between two states on each tick - so
-- unstamped payloads are dropped (and the problem reported once).
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
-- Flat rectangle crossing test. A checkpoint is an upright rectangle centered
-- on (wp.x, wp.y, wp.z), standing perpendicular to the stored heading:
--   forward f = (hx, hy)      the direction the car must be travelling
--   lateral r = (hy, -hx)     span = width
--   up      z                 span = height  (covers the banking)
-- The car scores the gate when its frame-to-frame movement segment crosses the
-- rectangle's plane and the intersection point lands inside the width/height
-- half-extents. Sampling the segment rather than the position means the test
-- never tunnels, no matter how fast the car is going or how thin the gate is.
-- Dimensions are passed in so the same math can be unit-tested headlessly
-- (see tests/gate_test.lua); the live caller feeds gateDims(wp).
--
-- EITHER DIRECTION COUNTS, unless the gate is marked one-way. A driver who
-- missed a checkpoint is already driving back to it, and the forward-only rule
-- made them pass through, turn, and come back. Nothing was protected by it: a
-- gate is ARMED once, and that is what stops it scoring twice, with
-- TUNE.LAP_DEBOUNCE guarding the one-gate route.
--
-- `oneWay` is the per-gate escape hatch for geometry where direction IS the
-- separation: a hairpin or a figure-8 crossover.
--
-- Returns (crossed, backwards). The second matters because a gate shared between
-- two lanes is stored with one heading and driven both ways, so relocateToGate
-- cannot read the car's direction off the gate afterwards.
local function rectCrossesGate(wp, prev, cur, w, h)
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
  if math.abs(iz - wp.z) > h * 0.5 then return false end
  return true, backward
end

-- Live wrapper: resolve the gate's effective rectangle dimensions, then run the
-- crossing test. Keeps callers unchanged (segmentCrossesGate(wp, a, b)), and
-- passes the backwards flag straight back out.
local function segmentCrossesGate(wp, prev, cur)
  local w, h = gateDims(wp)
  return rectCrossesGate(wp, prev, cur, w, h)
end

-- ---------------------------------------------------------------------------
-- Lap logic
-- ---------------------------------------------------------------------------
-- One session is running (the lights are out and laps count). Qualifying and
-- racing are the same thing here on purpose: both start from the grid, both
-- report a lap per completed circuit of the route, and both report it upstream
-- on the same event. Qualifying used to have detection of its own -- an out-lap
-- before the clock started, and no defined starting point because there was no
-- grid -- which is why a three-lap session took five or six laps to get through.
--
-- Qualifying's first lap is given away again (see onOutLap), and deliberately
-- not by going back to that: the crossing is still detected here, still reported
-- on the same event, and the SERVER decides it does not count. What this file
-- does about it is presentation -- it does not show the driver a time for a lap
-- that was not timed.
local function sessionRunning()
  return phase == 'racing' or phase == 'qualifying'
end

local function resetLapTracking()
  timingActive = false
  lapStart     = localTime
  localLap     = 1
  prevPos      = nil
  -- Joker credit and the reset allowance are per-session too: a new phase means
  -- a clean sheet on both.
  jokerArmed   = 1
  jokerTaken   = false
  jokerLapUsed = nil
  resetsUsed   = 0
  lastGate     = nil
  lastGateBack = false
  -- A lane chosen by driving starts undecided; one that came from the grid slot
  -- is set again below, once the slot for this session is known.
  if not branch.lock then branch.lane = nil end
  blockNoticeLeft = 0   -- a fresh session may report its first blocked attempt at once
  -- Telemetry restarts with the session; report immediately on the next frame
  -- so the leaderboard has a distance for this driver from the first moments.
  progressLeft = 0
  -- Cars launch from the grid at the line, so the first target is checkpoint 1
  -- and detection is live from GO - for a qualifying session exactly as much as
  -- for a race. (In qualifying that first circuit is the out lap: it is detected
  -- and reported like any other, and the server is what declines to score it.
  -- Nothing here stops timing, because a lap the client did not measure is a lap
  -- the client cannot report.) Outside a running session the start/finish line is
  -- armed, so a driver pottering about before the lights still gets sensible
  -- gate colours.
  if sessionRunning() then
    armedWp = 1
    timingActive = true
  else
    armedWp = math.max(#route, 1)
  end
  pushRouteState()
end

-- Strict track-state purge: throw away every checkpoint table and reset lap
-- tracking to a virgin state. The 3D gate poles are immediate-mode
-- debugDrawer shapes redrawn from `route` every frame, so emptying the table
-- removes them from the world on the next update tick - nothing else holds a
-- reference to them. Runs before any new layout is applied and whenever the
-- server broadcasts RM_ClearTrack, so ghost checkpoints from an earlier
-- session cannot survive.
local function clearTrackState(reason)
  route        = {}
  jokerRoute   = {}
  -- The pit lane goes too. Stalls used to survive a purge, stay standing on the
  -- next track, and ride along into the next save.
  pitRoute     = {}
  startPositions = {}
  gridSlot     = nil
  armedWp      = 1
  jokerArmed   = 1
  jokerTaken   = false
  jokerLapUsed = nil
  timingActive = false
  localLap     = 1
  lapStart     = localTime
  prevPos      = nil
  progressLeft = 0
  lastGate     = nil
  lastGateBack = false
  -- The lanes go with the gates. A branch left standing after a purge would arm
  -- gates from a track that is no longer loaded.
  branch.list   = {}
  branch.bySlot = {}
  branch.lane   = nil
  branch.lock   = false
  branch.gridOffLine = false
  branch.editId      = nil
  branch.editSlot    = 1
  pushRouteState()
  log('I', 'raceManager', 'Track state cleared (' .. tostring(reason or 'local') .. ')')
end

-- UI/console entry point: purge locally and, when on a BeamMP server, ask the
-- server to broadcast the purge to every client.
function M.clearTrackState()
  clearTrackState('ui request')
  if inMultiplayer() then TriggerServerEvent('RM_ClearTrackState', '') end
end

-- Is the lap this driver is on the out lap -- the one that is given away?
--
-- Worked out locally rather than read off this client's own driver row, and the
-- distinction matters: the row is authoritative but arrives on a broadcast three
-- times a second, so a readout driven by it would go on saying NOT TIMED for up
-- to a third of a second after the driver had crossed the line and started a
-- lap that very much was. The two agree by construction - both count crossings
-- from the grid, and the server's rule (qualiOutLap) is what gates this.
--
-- The server's flag is no longer qualifying's alone: a RACE on a track that grids
-- its cars away from the start/finish line owes one for the same reason, so the
-- phase test is gone and the session rule is the only thing deciding it. The wire
-- field kept its old name; what it means widened underneath.
-- The spectator test is here rather than at the two call sites because it is true
-- of both of them: a driver who has taken the flag is neither on an out lap for
-- the HUD's purposes nor owed an armed gate for the crossing code's.
local function onOutLap()
  return qualiOutLap and sessionRunning() and localLap <= 1 and not spectatorLock
end

local function onLapCompleted()
  local lapTime = localTime - lapStart
  if timingActive and lapTime < TUNE.LAP_DEBOUNCE then return end  -- double-fire guard

  -- Hand the finished time to this driver's own HUD so it can hold it on screen
  -- long enough to read. Display only, and deliberately separate from the
  -- reports above: the server is still told the same lapTime it always was, and
  -- lapStart is reset either way, so the lap clock never pauses for the hold.
  local function announceLap(n)
    guihooks.trigger('RaceManagerLapDone', { lapTime = lapTime, lap = n })
  end

  -- ONE report, for both kinds of session, and for the out lap as much as for a
  -- scored one. The server knows which session is running and scores the lap
  -- accordingly (best lap in qualifying, running order and laps led in a race,
  -- nothing at all for the out lap); the client's job is only to say "that was a
  -- lap, and it took this long". The separate RM_QualiLap channel this replaced
  -- is what let qualifying's lap counting drift away from the race's, and a
  -- client that withheld the out lap because it knew it would not be scored
  -- would be the same mistake in a new place -- the server needs the crossing
  -- either way, to advance the lap counter and clear the checkpoint telemetry.
  if not sessionRunning() then return end
  local outLap = onOutLap()
  if inMultiplayer() then
    TriggerServerEvent('RM_Lap', jsonEncode({ lapTime = lapTime }))
  end
  if outLap then
    -- No time is presented for a lap that was not timed. The readout says what
    -- happened instead, and the notice channel says what happens next -- this is
    -- the moment the driver most needs to know their timing has started, and it
    -- is the moment they are least able to go looking for it.
    guihooks.trigger('RaceManagerLapDone', { outLap = true, lap = localLap })
    pushNotice('session', 'OUT LAP COMPLETE: you are on a TIMED lap now')
    log('I', 'raceManager', string.format('Out lap done: %.3fs (not timed)', lapTime))
  else
    announceLap(localLap)
    log('I', 'raceManager', string.format('Lap %d done: %.3fs (%s)',
      localLap, lapTime, phase))
  end
  localLap = localLap + 1
  lapStart = localTime
end

-- ---------------------------------------------------------------------------
-- Joker route detection (Module 2)
-- ---------------------------------------------------------------------------
-- The joker gates are crossed in their own order, tracked independently of the
-- main route so a driver diverting onto the alternate loop keeps their main
-- checkpoint progress. Two rules are enforced here, on the only side that can
-- see the car move:
--   * Lap 1 restriction - any joker attempt started on lap 1 is invalidated
--     outright (progress thrown away, nothing reported to the server).
--   * Once per race - a completed joker route is reported exactly once; every
--     later run is ignored and flagged to the driver.
local function checkJokerGates(prev, cur)
  if not jokerEnabled or #jokerRoute == 0 then return end
  if phase ~= 'racing' then return end
  local wp = jokerRoute[jokerArmed]
  if not wp or not segmentCrossesGate(wp, prev, cur) then return end

  if localLap <= 1 then
    -- Lap 1: the attempt never counts. Re-arm from the first joker gate so a
    -- legal run on a later lap still works.
    jokerArmed = 1
    pushNotice('joker', 'JOKER LAP NOT ALLOWED ON LAP 1: attempt invalidated')
    log('W', 'raceManager', 'Joker route attempted on lap 1: attempt invalidated')
    pushRouteState()
    return
  end

  if jokerTaken then
    jokerArmed = 1
    pushNotice('joker', 'Joker Lap already taken: this run does not count')
    pushRouteState()
    return
  end

  if jokerArmed >= #jokerRoute then
    jokerTaken   = true
    jokerLapUsed = localLap
    jokerArmed   = 1
    if inMultiplayer() then
      TriggerServerEvent('RM_JokerLap', jsonEncode({ lap = localLap }))
    end
    pushNotice('joker', 'JOKER LAP COMPLETE (lap ' .. localLap .. ')')
    log('I', 'raceManager', 'Joker route completed on lap ' .. localLap)
  else
    jokerArmed = jokerArmed + 1
  end
  pushRouteState()
end

-- ---------------------------------------------------------------------------
-- Branching routes: which gate is slot i, for this car?
-- ---------------------------------------------------------------------------
-- The main gate, unless the lane this car is on overrides that slot. One table
-- index on the hot path, and the `lane` test short-circuits the whole thing on a
-- track with no branches -- which is every track that existed before this, and
-- most of the ones that come after.
--
-- Hung off the branch table rather than given a local of its own, for the
-- register budget noted where that table is declared.
-- A lane's display name, falling back to its id so a lane is never blank.
function branch.nameOf(id)
  if not id then return nil end
  for _, b in ipairs(branch.list) do
    if b.id == id then return b.name or b.id end
  end
  return id
end

-- Does this track grid its cars somewhere other than the start/finish line?
--
-- Inferred rather than asked for. An admin who put the grid somewhere else has
-- already said so by putting it there, and a switch they have to remember to set
-- is a switch they will forget -- which here costs the whole field a fastest lap
-- nobody drove.
--
-- Two signals, either of which settles it:
--   * A start position facing AGAINST the start/finish line. That is a head-on
--     layout, where one row of slots on the line is impossible by construction.
--   * A start position further from the line than any grid is long. A sixty-car
--     grid at eight metres a row is under 250m, so beyond that it is not a grid
--     stretching back from the line, it is a grid somewhere else on the circuit.
function branch.gridIsOff()
  local sf = route[#route]
  if not sf or #startPositions == 0 then return false end
  local r2 = TUNE.GRID_ON_LINE_RANGE * TUNE.GRID_ON_LINE_RANGE
  for _, sp in ipairs(startPositions) do
    if (sp.hx or 0) * (sf.hx or 0) + (sp.hy or 1) * (sf.hy or 1) < 0 then return true end
    local dx, dy = sp.x - sf.x, sp.y - sf.y
    if dx * dx + dy * dy > r2 then return true end
  end
  return false
end

function branch.gateFor(i, lane)
  if lane then
    local bySlot = branch.bySlot[lane]
    local g = bySlot and bySlot[i]
    if g then return g end
  end
  return route[i]
end

local function checkGates()
  if spectatorLock then return end     -- out of the session: no more timing
  if #route == 0 and #jokerRoute == 0 then return end
  if phase ~= 'qualifying' and phase ~= 'racing' then return end
  local veh, pos = sampledVehicle()
  if not veh or not pos then return end
  if prevPos then
    -- The gate this car must cross next. Still ONE gate, which is what keeps the
    -- crossing test as cheap as it was: a lane is decided before the lap starts
    -- (from the grid) or on the first branched slot, not re-evaluated per frame.
    --
    -- THE OUT LAP ARMS THE CHECKPOINTS LIKE ANY OTHER LAP. An earlier version
    -- armed only the start/finish line on the reasoning that a lap nobody is
    -- scoring has nothing to police -- which is true, and which also took the
    -- checkpoints off the driver's screen for the whole of their first lap. The
    -- out lap is the lap where a driver least knows the circuit; it is the worst
    -- possible one to hide the gates on.
    --
    -- The line is accepted as well, further down, so a car gridded PAST slot 1
    -- (which a head-on layout does, spreading its grid round the circuit) can
    -- still end the out lap by reaching the line rather than being sent most of
    -- the way round backwards to arm a gate behind it.
    local onOut = onOutLap()
    local wp = branch.gateFor(armedWp, branch.lane)
    local crossed, backwards = false, false
    if wp then crossed, backwards = segmentCrossesGate(wp, prevPos, pos) end

    -- On the out lap the LINE ends the lap from wherever the driver has got to,
    -- even with slots still uncleared. Nothing on this lap is scored, so there is
    -- nothing to protect by making them go back for a gate.
    local lineEndedOutLap = false
    if onOut and not crossed and armedWp < #route then
      local line = route[#route]
      if line then
        crossed, backwards = segmentCrossesGate(line, prevPos, pos)
        if crossed then wp, lineEndedOutLap = line, true end
      end
    end

    -- Undecided lane: the branch gates for this slot are armed alongside the main
    -- one, and whichever the car actually drives through is the line it is on.
    -- Only reached on a track that HAS branches, whose lane is not locked to the
    -- grid, and only on a slot that is actually branched -- so a head-on race
    -- (locked at the grid) never walks this, and nor does an ordinary circuit.
    local took = nil
    if not crossed and not onOut and not branch.lane and not branch.lock then
      for _, b in ipairs(branch.list) do
        local g = branch.bySlot[b.id] and branch.bySlot[b.id][armedWp]
        if g then
          crossed, backwards = segmentCrossesGate(g, prevPos, pos)
          if crossed then wp, took = g, b end
        end
        if crossed then break end
      end
    end

    if crossed then
      lastGate     = wp   -- the "Last Checkpoint" reset mode respawns here
      lastGateBack = backwards
      if took then
        branch.lane = took.id
        pushNotice('branch', 'You are on the ' .. (took.name or took.id) .. ' line')
      end
      if lineEndedOutLap then
        -- Reached the line with slots still owing. The out lap is over; slot 1
        -- arms behind it with timing running. onLapCompleted reports the crossing
        -- like any other -- the SERVER is what declines to score it, exactly as
        -- it always has for qualifying.
        onLapCompleted()
        armedWp = 1
      elseif armedWp >= #route then
        onLapCompleted()
        armedWp = 1
        -- A lane chosen by driving is chosen again next lap; one assigned by the
        -- grid is the direction this car is racing in and does not change.
        if not branch.lock then branch.lane = nil end
      else
        armedWp = armedWp + 1
      end
      -- Clearing a checkpoint is exactly when a position can change hands, so
      -- jump the throttle and report the new count on the next frame.
      progressLeft = 0
      pushRouteState()
    end
    checkJokerGates(prevPos, pos)
  end
  prevPos = vec3(pos.x, pos.y, pos.z)
end

-- ---------------------------------------------------------------------------
-- Live lap clock (display only)
-- ---------------------------------------------------------------------------
-- Strictly a HUD feed. The lap time that counts is still the one measured at
-- the crossing in onLapCompleted and scored by the server; nothing here is ever
-- reported upstream or used for timing. The UI interpolates forward from the
-- last push with its own clock, so this cadence sets the correction rate, not
-- the visible frame rate of the readout.
local lapTimeLeft    = 0
local lapTimerArmed  = false     -- was the clock running on the previous tick?

local function lapTimerUpdate(dt)
  -- Running whenever this client's own lap clock is, which is now any session
  -- from GO onwards: both kinds start from the grid with the clock already on.
  local running = sessionRunning()
  if not running then
    -- Tell the UI once on the way down so it can drop the readout instead of
    -- leaving the last value frozen on screen looking like a stalled clock.
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
    lap     = localLap,
    elapsed = localTime - lapStart,
    -- The clock still runs and is still sent; what changes is what the app is
    -- allowed to do with it. On the out lap it shows the lap for what it is
    -- instead of a number that looks like a time being taken -- a driver
    -- watching a lap clock tick has every reason to think it counts.
    outLap  = onOutLap(),
  })
end

-- ---------------------------------------------------------------------------
-- Live position telemetry
-- ---------------------------------------------------------------------------
-- The server decides the running order but has no physics access, so the third
-- tie-break metric - how far a car is from the next checkpoint - can only be
-- measured here. A few times a second that distance goes up to the server
-- together with the lap and the number of checkpoints already cleared on it. The
-- send is throttled (TUNE.PROGRESS_EVERY) so a full grid costs the server a
-- handful of small events per second, not one per frame per driver.
--
-- The DISTANCE is throttled with it. It used to be recomputed every frame -- a
-- vehicle query and a square root -- for a value that is only ever read by the
-- payload below, so ~55 out of every 60 were thrown away unused.
local function reportProgress(dt)
  if not sessionRunning() or spectatorLock then return end
  -- The gate THIS car is driving towards, which on a branching track is not
  -- necessarily the main route's. Reporting the distance to a gate on the other
  -- lane would rank a head-on field by how close each car was to a gate it is
  -- driving away from.
  local wp = onOutLap() and route[#route] or branch.gateFor(armedWp, branch.lane)
  if not wp then return end

  progressLeft = progressLeft - dt
  if progressLeft > 0 then return end

  local veh, pos = sampledVehicle()
  if not veh or not pos then return end
  progressLeft = TUNE.PROGRESS_EVERY

  -- Distance from the car to the centre of the next checkpoint, in metres.
  local dx, dy, dz = pos.x - wp.x, pos.y - wp.y, pos.z - wp.z

  -- armedWp is the gate we are driving TOWARDS, so the count already cleared on
  -- this lap is one less (and 0 right after crossing the start/finish line).
  local payload = {
    lap  = localLap,
    cp   = armedWp - 1,
    dist = math.sqrt(dx * dx + dy * dy + dz * dz),
  }
  if inMultiplayer() then
    TriggerServerEvent('RM_Progress', jsonEncode(payload))
  end
  -- Same cadence to the local UI, so the driver's own header readout ticks
  -- along with what the server is being told.
  guihooks.trigger('RaceManagerProgress', payload)
end

-- ===========================================================================
-- Vehicle & setup capture (Module 4)
-- ===========================================================================
-- The server cannot see what a player is driving beyond the jbeam model name,
-- so the exact configuration is fingerprinted here: model + every part in the
-- part config + every tuning variable, flattened into one deterministic string.
-- The admin's "Whitelist Current Vehicle" sends that signature to build the
-- Garage List; every client sends its own signature whenever its vehicle
-- changes, and the server removes anything that doesn't match.

-- Deterministic flattening: keys sorted, numbers fixed to 4 decimals, so two
-- identical setups always produce byte-identical signatures.
local function stableSerialize(tbl)
  if type(tbl) ~= 'table' then return '' end
  local entries = {}
  for k, v in pairs(tbl) do
    local val
    if type(v) == 'number' then
      val = string.format('%.4f', v)
    elseif type(v) == 'table' then
      val = 'table'
    else
      val = tostring(v)
    end
    entries[#entries + 1] = tostring(k) .. '=' .. val
  end
  table.sort(entries)
  return table.concat(entries, ';')
end

-- Human-readable name of a saved setup. Until BeamNG v0.39 the .pc filename WAS
-- the name the player typed, so reading the filename stem was enough. v0.39
-- changed that ("Changed naming of the custom config files": the name now lives
-- in the vehicle's info.json and the .pc filename is only a sanitised
-- derivative of it), which left the Garage List showing a mangled filename
-- instead of the setup's actual name. The real name is looked for on the config
-- table first - under whichever key the build carries it - and the filename stem
-- is kept as the last resort so older builds behave exactly as before.
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

-- The BeamNG build this client is running. A game update can rename vehicle
-- parts (v0.39 did: "Renamed a bunch of parts on some vehicles to unify part
-- names with other vehicles"), and a renamed part changes the configuration
-- signature below without the car itself changing at all - so every Garage List
-- entry captured on an older build silently stops matching. Reporting the
-- version lets the server say THAT, instead of leaving drivers rejected with no
-- explanation. nil when the build cannot be identified; the server treats that
-- as "unknown", never as a mismatch.
local function gameVersion()
  for _, name in ipairs({ 'beamng_versionb', 'beamng_version', 'beamng_buildinfo' }) do
    local ok, v = pcall(function () return _G[name] end)
    if ok and type(v) == 'string' and v ~= '' then return v end
  end
  return nil
end

-- Snapshot of the vehicle the local player is currently driving.
local function localVehicleConfig()
  local veh = playerVehicle()
  if not veh then return nil end
  local model = '?'
  pcall(function () model = tostring(veh:getJBeamFilename()) end)

  local parts, vars, configName = {}, {}, nil
  if core_vehicle_partmgmt and core_vehicle_partmgmt.getConfig then
    local ok, cfg = pcall(core_vehicle_partmgmt.getConfig)
    if ok and type(cfg) == 'table' then
      if type(cfg.parts) == 'table' then parts = cfg.parts end
      if type(cfg.vars)  == 'table' then vars  = cfg.vars  end
      configName = configDisplayName(cfg)
    end
  end

  local sig = 'model=' .. model
    .. '|parts=' .. stableSerialize(parts)
    .. '|vars='  .. stableSerialize(vars)
  local vid
  pcall(function () vid = veh:getID() end)
  return {
    model = model,
    label = configName and (model .. ' - ' .. configName) or model,
    sig   = sig,
    vid   = vid,
  }
end

-- Last signature this client told the server about, so the periodic check only
-- talks when something actually changed (spawn, swap, or a re-tune).
local lastReportedSig = nil
local configCheckLeft = 0

local function reportVehicleConfig(force)
  if not inMultiplayer() then return end
  local cfg = localVehicleConfig()
  if not cfg then return end
  if not force and cfg.sig == lastReportedSig then return end
  lastReportedSig = cfg.sig
  TriggerServerEvent('RM_VehicleConfig', jsonEncode({
    vid = cfg.vid, model = cfg.model, label = cfg.label, sig = cfg.sig,
    game = gameVersion(),
  }))
end

-- Polls the local vehicle configuration. Applying a tune does not raise a
-- single reliable GE event across BeamNG versions, so the signature is
-- re-derived on a slow timer and reported the moment it differs - that covers
-- spawns, vehicle switches and setup changes with one code path.
local function vehicleConfigUpdate(dt)
  if not inMultiplayer() then return end
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
  local cfg = localVehicleConfig()
  if not cfg then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  TriggerServerEvent('RM_WhitelistVehicle', jsonEncode({
    model = cfg.model, label = cfg.label, sig = cfg.sig, game = gameVersion(),
  }))
  log('I', 'raceManager', 'Whitelisting current vehicle: ' .. cfg.label)
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

-- ===========================================================================
-- Vehicle reset control & forced spectating (Module 1)
-- ===========================================================================
-- The reset allowance is a league regulation the server owns but only the
-- client can police: BeamNG fires the reset locally and the BeamMP server never
-- sees it. Every local reset is counted here. Once the allowance is spent the
-- reset is BLOCKED rather than punished: BeamNG has already teleported the car
-- by the time we hear about it, so "blocking" means putting the car straight
-- back on its last known good position and orientation. The driver keeps
-- racing, they simply cannot use the reset button any more.
--
-- The forced-spectator machinery below is still used, but only where a driver
-- genuinely leaves the session: a derby elimination, or crossing the finish
-- line (a finished car is taken off track so it can't interfere with the
-- drivers still racing). Both are lifted - and the car respawned - when the
-- session ends.

-- Snapshot of the vehicle removed by enterSpectator, so the same car can be put
-- back when the session releases the lock.
local removedVehicle = nil   -- { model, config, pos, rot }

-- Everything BeamNG needs to put this exact car back: jbeam model, the part
-- config, and where it was standing.
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
  -- THE GRID SLOT THIS DRIVER OWNS, recorded here because here is the last
  -- moment it exists. The phase change to 'finished' clears gridSlot, and that
  -- lands BEFORE the release that puts the car back -- so a respawn asking for
  -- the slot at release time always found nothing and fell back to respawning
  -- on the finish line, which is where the whole field had just been removed
  -- from, on top of each other. A snapshot records where to put a car back, and
  -- the slot is part of that.
  snap.slot = gridSlot
  if not snap.model then return nil end
  return snap
end

-- Delete the local player's OWN vehicle. BeamNG exposes several ways to do this
-- depending on version, so try them in order and never let a failure escape.
--
-- core_vehicles.removeCurrent deletes whatever the client is attached to, which
-- is only safe once we know that is ours -- otherwise a driver taking the flag
-- deletes a rival's car out from under them.
--
-- WHO THIS IS FOR IS THE WHOLE POINT, and getting that wrong was a live bug in
-- both directions. A RACE finisher is taken off the track: they have nothing
-- left to gain and a parked car on the racing line is an obstacle for everyone
-- still running. A DERBY elimination is NOT -- the wreck is the arena's
-- furniture and the other drivers are still fighting around it, and deleting it
-- in BeamMP deletes it for every client in the server, which is how eliminated
-- drivers vanished from everybody's screen.
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

-- Put this client back on its OWN car.
--
-- Doing it explicitly is the point: after a placement the game picks a vehicle
-- for the camera on its own, and with five cars moving at once its pick is
-- arbitrary -- which is how every client in the session ended up watching the
-- same driver.
--
-- It switches the VEHICLE and not the camera MODE. It used to force the game
-- camera (orbit) as well, which threw away whatever view the driver had chosen
-- -- a cockpit driver was put in orbit every time the mod handed their car back.
-- Which car you are attached to is the mod's business; how you are looking at it
-- is the driver's.
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

-- Put back the car removed when this client was pushed into spectator mode.
-- Called when the session that imposed the penalty ends, so a driver who
-- finished (or was knocked out of a derby) is back in their car for the next
-- one instead of stranded in freecam with nothing to drive.
-- Forward-declared: respawnRemovedVehicle below needs both to stand a respawned
-- car on its grid slot, and both are defined further down beside the placement
-- code they were written for. Declared rather than moved, so the placement
-- section keeps reading in the order it was built.
local headingRot
local placeOnStartPosition

local function respawnRemovedVehicle()
  local snap = removedVehicle
  if not snap or not snap.model then return false end
  -- OWN car, not "a car". Asking playerVehicle() here is what stopped a
  -- finisher's respawn: the camera had already been handed to a rival's vehicle,
  -- so the answer was "you have one" and the driver stayed on foot for good.
  if ownVehicle() then
    removedVehicle = nil
    return false
  end
  removedVehicle = nil
  local opts = { config = snap.config }
  if snap.pos then opts.pos = snap.pos end
  if snap.rot then opts.rot = snap.rot end
  -- SPAWN ON THE GRID SLOT, not where the car was taken away.
  --
  -- This is what welded the field together. A race removes cars AS THEY TAKE THE
  -- FLAG, all within a few metres of the line, so respawning each at its own
  -- snapshot put the whole field down interpenetrated and BeamNG welds what it
  -- finds inside itself. The grid is spaced by construction. Falls back to the
  -- snapshot only when the track has no grid placed, covered by the ghosting
  -- around this call.
  -- Spawn on the slot's POSITION only, then turn it with placeOnStartPosition.
  -- headingRot bakes in a half-turn for BeamNG's -Y vehicle forward, which is
  -- what setPositionRotation wants and spawnNewVehicle does NOT: handing it the
  -- same quaternion put every respawned car on its slot facing backwards. One
  -- place knows about the two conventions, and this is not it.
  -- ANY start position beats the finish line.
  --
  -- gridSlot is cleared by the phase change to 'finished', a mid-session joiner
  -- never had one, and a slot can outlive the grid it indexed. Falling straight
  -- back to the snapshot puts a finisher back on the start/finish line facing
  -- however they crossed it: the reported "near the start/finish, sideways". So
  -- their slot, then any placed slot, then the snapshot. Sharing someone else's
  -- slot for a moment is harmless while the ghosting holds.
  local slot = snap.slot or gridSlot
  local sp = slot and startPositions[slot]
  if not (type(sp) == 'table' and sp.x) then sp = startPositions[1] end
  if type(sp) == 'table' and sp.x and sp.y and sp.z then
    opts.pos = vec3(sp.x, sp.y, sp.z)
    opts.rot = nil          -- set below, by the call that knows the convention
    log('I', 'raceManager', 'Respawning on grid slot ' .. tostring(slot or 1)
      .. ' rather than where the car was removed')
  else
    -- Say so. A car that comes back in the wrong place with nothing in the log
    -- is the position this took two rounds to get out of.
    log('W', 'raceManager', 'Respawning where the car was removed: no start '
      .. 'position to use (slot=' .. tostring(slot) .. ', grid has '
      .. tostring(#startPositions) .. ' placed)')
  end
  local spawned = false
  if core_vehicles and core_vehicles.spawnNewVehicle then
    spawned = pcall(core_vehicles.spawnNewVehicle, snap.model, opts)
  end
  if not spawned and core_vehicles and core_vehicles.replaceVehicle then
    spawned = pcall(core_vehicles.replaceVehicle, snap.model, opts)
  end
  if spawned then
    -- NOT placed or turned here. BeamNG spawns asynchronously and the vehicle
    -- does not exist on this frame, so a placement call made now finds nothing
    -- and silently does nothing -- which is why cars kept coming back facing
    -- whichever way they finished. The placement scheduler already has a step
    -- for this: it waits out a spawn grace and THEN calls placeOnAssignedSlot,
    -- which is the same call the grid itself uses. releaseSpectator hands it the
    -- slot so that step has something to place onto.
    log('I', 'raceManager', 'Respawned ' .. tostring(snap.model) .. ' after the session ended')
  else
    -- Keep the snapshot: a failed spawn is worth another attempt when the
    -- placement scheduler comes back round, and losing it means losing the only
    -- record of what this driver was in.
    removedVehicle = snap
    log('W', 'raceManager', 'Could not respawn ' .. tostring(snap.model)
      .. ' automatically: spawn a vehicle manually')
  end
  return spawned
end

-- Free camera is the DRIVER'S control now, not the mod's. It is still there --
-- BeamNG's own key still works, and a spectator is welcome in it -- but nothing
-- here puts them in it or keeps them there. Forcing it was Bug 3.


-- ---------------------------------------------------------------------------
-- Being out of a session: freeze the INPUT, never the existence
-- ---------------------------------------------------------------------------
-- This used to delete the car and force freecam, which was three live bugs:
--
--   * in BeamMP a deleted vehicle is deleted FOR EVERY CLIENT, so an eliminated
--     driver went missing from everyone's screen rather than quiet.
--   * freecam was re-asserted once a second, so tabbing to watch somebody was
--     undone within the second, over and over.
--   * letting anyone back in then meant RESPAWNING a whole field at once, which
--     is how cars came back interpenetrated and welded.
--
-- The car now stays where it is as a physical object and only the ability to
-- DRIVE it is taken away, which removes the weld problem at its cause. The
-- camera is not touched: tabbing between cars is BeamNG's own control.
local spectate = {
  -- Every input that drives a car. Deliberately NOT the vehicle-switch actions:
  -- tabbing between cars is the whole point of spectating and must keep working.
  DRIVE = {
    'accelerate', 'brake', 'throttle', 'steering', 'steer_left', 'steer_right',
    'parkingbrake', 'parkingbrake_toggle', 'clutch',
    'shiftUp', 'shiftDown', 'shiftToggle', 'toggleGearboxMode',
    'nitrousOxideActive', 'toggleWalkingMode',
  },
  blocked = false,
  -- BeamNG's node grabber: click a car and drag its physics nodes around. In a
  -- demolition derby that is not a debug tool, it is a winning move -- drag your
  -- own wreck back onto its wheels, or drag somebody else's into the wall
  -- without touching them. Off for the length of a derby.
  --
  -- THESE ARE THE GAME'S OWN NAMES, read out of its actionFilter's
  -- `actionTemplates.nodegrabber` rather than guessed. The first version of this
  -- list guessed, in snake_case, and every name was wrong -- so the filter armed
  -- a group of actions that do not exist and the grabber went on working. A
  -- filter group made of names nothing answers to fails completely silently:
  -- there is no error and no log line, it simply blocks nothing.
  --
  -- funStuff goes with it for the same reason. Fire, explosions, the tyre
  -- poppers and the flings are one keypress each and every one of them decides a
  -- derby; they are exactly as much a cheat as dragging a node, and the game
  -- groups them for exactly this purpose.
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

-- Same shape as the two blocks either side of it. Kept separate from the driving
-- block because they answer to different things: driving is filtered while a
-- driver is OUT of a session, the grabber while a derby is ON, and an eliminated
-- driver in a running derby is both at once.
function spectate.setGrabberBlocked(blocked)
  blocked = blocked and true or false
  if blocked == spectate.grabBlocked then return end
  if not (core_input_actionFilter and core_input_actionFilter.setGroup
      and core_input_actionFilter.addAction) then
    return
  end
  local ok = pcall(function ()
    core_input_actionFilter.setGroup('raceManagerGrabber', spectate.GRAB)
    core_input_actionFilter.addAction(0, 'raceManagerGrabber', blocked)
  end)
  if ok then
    spectate.grabBlocked = blocked
    log('I', 'raceManager', 'Node grabber ' .. (blocked and 'BLOCKED' or 'released'))
  end
end

-- Same shape as setResetInputsBlocked, and for the same reason: with the filter
-- armed the keys are dead at the source, so an eliminated driver cannot drive
-- their wreck no matter what the physics would otherwise allow.
function spectate.setInputsBlocked(blocked)
  blocked = blocked and true or false
  if blocked == spectate.blocked then return end
  if not (core_input_actionFilter and core_input_actionFilter.setGroup
      and core_input_actionFilter.addAction) then
    return
  end
  local ok = pcall(function ()
    core_input_actionFilter.setGroup('raceManagerSpectate', spectate.DRIVE)
    core_input_actionFilter.addAction(0, 'raceManagerSpectate', blocked)
  end)
  if ok then
    spectate.blocked = blocked
    log('I', 'raceManager', 'Driving inputs ' .. (blocked and 'BLOCKED' or 'released'))
  end
end

-- Put the camera on somebody still racing.
--
-- A driver who has just taken the flag is parked, and leaving them looking at
-- their own stationary car is the least interesting view on the track. Pick a
-- car that is MOVING and is not ours, and hand the camera to it the same way
-- bindCameraToOwnVehicle does -- by switching vehicle, not by changing camera
-- MODE, so the driver keeps whatever view they had and tab keeps working from
-- there.
--
-- Once. There is no loop re-asserting this: after the first attach the target is
-- the driver's to change.
function spectate.attachToRunner()
  if type(getAllVehicles) ~= 'function' or not (be and be.enterVehicle) then return false end
  local ok, list = pcall(getAllVehicles)
  if not ok or type(list) ~= 'table' then return false end
  local best, bestSpeed = nil, 0.5      -- m/s; below this a car is parked
  for _, v in ipairs(list) do
    if v and not isOwnVehicle(vehicleId(v)) then
      local moving = 0
      pcall(function ()
        local vel = v:getVelocity()
        if vel then moving = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z) end
      end)
      if moving > bestSpeed then best, bestSpeed = v, moving end
    end
  end
  -- Nothing moving (everybody finished, or a one-car session): stay where we
  -- are rather than flicking through parked cars looking for one that is not
  -- there. A sane still view beats a search that never settles.
  if not best then return false end
  local switched = pcall(function () be:enterVehicle(0, best) end)
  log('I', 'raceManager', switched
    and ('Spectating a moving car (%.0f m/s)'):format(bestSpeed)
    or 'Could not switch to a moving car')
  return switched
end

local function enterSpectator(reason, source)
  spectatorLock   = source or 'race'
  spectatorReason = reason or 'You are out of this session'
  -- Driving goes either way, and it is the ONLY thing that goes for a derby.
  spectate.setInputsBlocked(true)
  if spectatorLock == 'derby' then
    -- ELIMINATED IN A DERBY: the car stays exactly where it is, as a visible,
    -- physical wreck, and the driver stays in it. The arena is the show and they
    -- are sitting in it; being moved somewhere else the instant you are knocked
    -- out reads as the bug this replaced. Tab takes them anywhere they like.
    log('I', 'raceManager', 'Derby elimination: the wreck stays in the arena')
  else
    -- FINISHED OR OUT OF A RACE: the car comes off the track. It has nothing
    -- left to gain and a parked one on the racing line is an obstacle for
    -- everyone still running.
    --
    -- Which is exactly why the camera has to be given somewhere to go in the
    -- same breath: with the car gone BeamNG hands the view to whatever vehicle
    -- is nearest, and with a field finishing together its pick is arbitrary --
    -- which is how every client ended up watching the same driver. Put them on
    -- something that is actually MOVING, once, and let tab do the rest.
    removeLocalVehicle()
    spectate.attachToRunner()
  end
  guihooks.trigger('RaceManagerSpectator', {
    spectating = true, reason = spectatorReason, source = spectatorLock,
  })
  pushNotice('spectate', spectatorReason)
  pushRouteState()
  log('I', 'raceManager', 'Spectator mode (' .. tostring(spectatorLock)
    .. '): ' .. tostring(spectatorReason))
end

-- Only the source that imposed the lock can lift it, so a derby finishing can
-- never hand a race DNF their car back (and vice versa). Releasing puts the
-- removed vehicle back and hands the camera to it, so the driver is ready for
-- the next session instead of stuck in freecam.
--
-- The respawn is QUEUED rather than done here. Every driver in the field is
-- released by the same broadcast, so doing it on the spot means the whole grid
-- spawning on one tick - refused spawns and interpenetrated cars. `order` and
-- `count` come from the server's snapshot of the participant list and put this
-- client in the queue; a release without them (a lone spectator, a derby
-- elimination) is simply order 1 of 1.
--
-- Forward-declared: the placement scheduler lives further down, beside the grid
-- placement it shares its ghosting and its stagger with.
local queueFieldPlacement

local function releaseSpectator(source, order, count)
  if not spectatorLock then return end
  if source and source ~= spectatorLock then return end
  spectatorLock   = nil
  spectatorReason = nil
  -- Driving comes back first, so a driver is never released into a car they
  -- cannot move.
  spectate.setInputsBlocked(false)
  -- And they go back to their OWN car, wherever they left it. Nothing is
  -- respawned: the car was never removed, so there is nothing to put back and
  -- nothing to interpenetrate. respawnRemovedVehicle stays in the placement path
  -- as a safety net for a snapshot taken by an older build -- with nothing
  -- removed it is a no-op.
  -- The slot this driver owned, taken from the snapshot rather than gridSlot:
  -- the phase change to 'finished' clears gridSlot and lands BEFORE this. The
  -- scheduler places the car on it after the spawn grace, which is the only
  -- moment the vehicle actually exists to be placed.
  -- ...and if neither is available, slot 1, so long as a grid exists at all.
  -- The placement step is gated on field.slot, so leaving it nil means the car
  -- is spawned and never stood up -- it keeps whatever heading the spawn gave it,
  -- which is the "sideways" half of the report. Any placed slot is a spaced,
  -- road-level, correctly-facing piece of track.
  local slot = (removedVehicle and removedVehicle.slot) or gridSlot
    or (startPositions[1] and 1 or nil)
  if queueFieldPlacement then
    queueFieldPlacement({ respawn = true, slot = slot, order = order, count = count })
  else
    respawnRemovedVehicle()
    bindCameraToOwnVehicle()
  end
  guihooks.trigger('RaceManagerSpectator', { spectating = false })
  pushRouteState()
  log('I', 'raceManager', 'Spectator mode released (' .. tostring(source or 'any')
    .. ', order ' .. tostring(order or 1) .. '/' .. tostring(count or 1) .. ')')
end

-- NOTHING RE-ASSERTS THE CAMERA, and that is the fix. Forcing freecam back on
-- once a second meant spectating did not work at all: pick something to watch
-- and the next tick took it away. Being in a car is no longer a way back into a
-- race anyway, because the inputs are filtered.
--
-- The one exception is an EVENT, not a timer: the car being watched can stop
-- existing. Finishers are removed back to back, so a spectator attached to the
-- car in front loses it seconds later and BeamNG hands the view wherever it
-- likes. So the target is followed rather than enforced, recorded every tick
-- including a car the driver tabbed to themselves, and only its ceasing to exist
-- triggers a re-acquire. Gone, not stopped: a parked car is still a car.
local function spectatorUpdate(dt)
  if not spectatorLock then
    spectate.target = nil
    return
  end
  spectate.recheck = (spectate.recheck or 0) - dt
  if spectate.recheck > 0 then return end
  spectate.recheck = 0.25

  local now = playerVehicle()
  local id  = now and vehicleId(now) or nil
  -- Still on something, and it is whatever the driver last chose. Record it and
  -- do nothing -- this is the branch that runs almost every tick.
  if id and getObjectByID and getObjectByID(id) then
    spectate.target = id
    return
  end
  -- The car being watched is gone. Advance ONCE to the next moving one; if the
  -- field has all finished there is nothing to advance to, and the view is left
  -- alone rather than flicked between cars that are not there.
  --
  -- No guard on having recorded a target first. An earlier version only
  -- re-acquired when `spectate.target` was already set, which reads as caution
  -- and is exactly backwards: in a bunched finish the car in front is removed
  -- within a frame or two of being attached to, often before a single tick has
  -- run to record it -- so the one case this exists for was the one case it
  -- refused to act on. Reaching here already means the lock is held and the car
  -- being watched is not there, and that is the whole of the question.
  if spectate.attachToRunner() then
    local v = playerVehicle()
    spectate.target = v and vehicleId(v) or nil
    log('I', 'raceManager', 'Spectate target gone: moved to the next moving car')
  end
end

-- The reset allowance applies for the whole of a live session - qualifying as
-- well as a race, now that qualifying is one - and the countdown that starts it.
-- The setup phases stay free.
local function resetsEnforced()
  return maxResets >= 0 and (sessionRunning() or phase == 'countdown')
end

-- Derby reset allowance (mirrored from the derby broadcast). The derby module
-- further down owns its phase; it fills in derbyResetsActive so this module
-- can ask "is a derby policing resets right now?" without reaching into
-- derby state directly.
local derbyMaxResets    = -1
local derbyResetsUsed   = 0
local derbyResetsActive = function () return false end
-- "Is a derby standing its cars down right now?" Assigned by the derby module,
-- which is scoped further down this file, and read by the reset-input block up
-- here -- without it resetInputBlockUpdate would recompute the block from the
-- reset ALLOWANCE every tick and undo the derby's one a frame after it was
-- applied.
--
-- Hung off the spectate table, which already carries this file's other
-- input-filter state, rather than taking a register of its own (see
-- docs/ARCHITECTURE.md on the 200-local ceiling).
spectate.derbyStoodDown = function () return false end

local function derbyResetsEnforced()
  return derbyMaxResets >= 0 and derbyResetsActive()
end

-- Switch the reset/recover input actions off (or back on) via BeamNG's input
-- action filter. With the filter armed the keys are dead at the source: the
-- vehicle never resets at all. Older builds without the filter fall back to
-- the restore in onVehicleResetted.
local function setResetInputsBlocked(blocked)
  blocked = blocked and true or false
  if blocked == resetInputsBlocked then return end
  if not (core_input_actionFilter and core_input_actionFilter.setGroup
      and core_input_actionFilter.addAction) then
    return
  end
  local ok = pcall(function ()
    core_input_actionFilter.setGroup('raceManagerResets', RESET_ACTIONS)
    core_input_actionFilter.addAction(0, 'raceManagerResets', blocked)
  end)
  if ok then
    resetInputsBlocked = blocked
    log('I', 'raceManager', 'Reset inputs ' .. (blocked and 'BLOCKED' or 'released'))
  end
end

-- NOTE: driving inputs are deliberately NOT filtered while a car is held.
-- controller.setFreeze pins the car in place but leaves the drivetrain live, and
-- that is the point: revving against the hold and pre-selecting a gear before
-- the lights is how a standing start is supposed to work. A previous build
-- blocked throttle/clutch/shift here as a "second mechanism" and took that away
-- from every driver; the freeze alone is the correct primitive.

-- Recomputed every frame (cheap: only acts on a change): the reset keys go
-- dead the moment the allowance is spent and come back the moment the session
-- lets go of the rule.
local function resetInputBlockUpdate()
  local wantBlocked = not spectatorLock
    and ((resetsEnforced() and resetsUsed >= maxResets)
      or (derbyResetsEnforced() and derbyResetsUsed >= derbyMaxResets))
  -- ...and while a derby is standing its cars down. A reset there would reload
  -- the vehicle out from under the freeze and hand somebody a driveable car in
  -- the middle of a settled result.
  setResetInputsBlocked(wantBlocked or spectate.derbyStoodDown())
end

-- Rolling "last good position" sample. Taken a few times a second while the
-- driver is out on track and NOT frozen on the grid, so a blocked reset always
-- has somewhere sane to put the car back.
-- Sampled for the whole of a live session, not only when resets are LIMITED.
--
-- It used to run only while an allowance was being enforced, which is the one
-- case it was written for -- putting a car back after a reset it was not
-- entitled to. Undoing a recovery teleport needs the same sample and has nothing
-- to do with allowances: a server running unlimited resets had no snapshot at
-- all, so there was nowhere to put a driver back to.
local function snapshotUpdate(dt)
  local wanted = resetsEnforced() or derbyResetsEnforced() or sessionRunning()
  if not wanted or spectatorLock or gridFrozen then return end
  snapshotLeft = snapshotLeft - dt
  if snapshotLeft > 0 then return end
  snapshotLeft = SNAPSHOT_EVERY
  local veh = playerVehicle()
  if not veh then return end
  local ok = pcall(function ()
    local pos = veh:getPosition()
    local rot = veh:getRotation()
    lastGoodPos = vec3(pos.x, pos.y, pos.z)
    lastGoodRot = quat(rot.x, rot.y, rot.z, rot.w)
  end)
  if not ok then lastGoodPos, lastGoodRot = nil, nil end
end

-- Remember a teleport this mod just performed, so the vehicle-reset hook it
-- provokes can be recognised as our own doing rather than a driver reset.
local function noteSelfTeleport(x, y, z)
  selfTeleport.left = TELEPORT_WINDOW
  selfTeleport.x, selfTeleport.y, selfTeleport.z = x, y, z
end

-- True when the reset just reported is the echo of our own teleport: it arrived
-- inside the window AND the car is sitting where we put it. Both halves matter -
-- the window alone would swallow a driver reset pressed immediately after a
-- block, and a driver reset always moves the car somewhere else.
--
-- "Where we put it" cannot be a fixed radius, though. BeamNG v0.39 reworked the
-- teleport detector (objectTeleported(): "improved detection to reduce false
-- positives/negatives in extreme cases (such as ... really fast vehicles)"), so
-- an echo we used to hear on the same frame can now arrive a frame or two later
-- - and a car doing 250 km/h covers 2 metres in a frame and a half. Judged
-- against a fixed 2 m the car would already be "somewhere else", the echo would
-- be read as a driver reset, and a legitimately gridded or restored driver would
-- be charged an allowance (or dragged back again). So the tolerance grows with
-- how far the car could actually have travelled since we moved it: its own
-- speed times the time elapsed. At the instant of the teleport that is exactly
-- the old 2 m test, which is why a reset pressed right after a block is still
-- caught as a real attempt.
local function isSelfTeleportEcho()
  if selfTeleport.left <= 0 then return false end
  local veh = playerVehicle()
  if not veh then return false end
  local elapsed = TELEPORT_WINDOW - selfTeleport.left
  if elapsed < 0 then elapsed = 0 end
  local ok, near = pcall(function ()
    local p = veh:getPosition()
    local dx, dy, dz = p.x - selfTeleport.x, p.y - selfTeleport.y, p.z - selfTeleport.z
    local v = veh:getVelocity()
    local speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    local allowed = TELEPORT_RADIUS + speed * elapsed
    return (dx * dx + dy * dy + dz * dz) <= allowed * allowed
  end)
  return ok and near == true
end

-- Is this car standing in that pit stall?
--
-- A box, not a plane. A checkpoint is crossed; a pit stall is DRIVEN INTO and
-- occupied, so the test is "am I in it", measured on the stall's own axes so a
-- stall angled to the lane still reads correctly. Using the crossing test here
-- would let a car trigger a pit stop by clipping the box at racing speed, which
-- is the opposite of what a pit stop is.
function pit.inside(wp, pos)
  local w, h = gateDims(wp)
  local dx, dy, dz = pos.x - wp.x, pos.y - wp.y, pos.z - wp.z
  local fx, fy = wp.hx or 0, wp.hy or 1
  local lat = dx * fy - dy * fx          -- across the stall
  local fwd = dx * fx + dy * fy          -- along it
  return math.abs(lat) <= w * 0.5
     and math.abs(fwd) <= TUNE.PIT_DEPTH
     and math.abs(dz)  <= h * 0.5
end

-- Ghosting for the duration of a stop.
--
-- A stopped car in a stall is a hazard placed in the one part of the track
-- everybody else arrives at slowly and off-line, and it cannot move out of the
-- way -- it is frozen by the stop. So it stops being something to hit.
--
-- Rides the SERVER's reset-ghost switch rather than a rule of its own. Ghosting
-- is per vehicle and applied by each client separately (see COMPATIBILITY.md),
-- so every client has to agree about the same car: ghosting locally while the
-- server refuses to relay it produces a car that is a ghost to its driver and
-- solid to everyone else, which is worse than not ghosting at all. Gating both
-- halves on the same switch keeps them in step, and the broadcast duration is
-- the stop's own length so the ghost ends everywhere at the same moment.
function pit.setGhost(on)
  if on then
    if pit.ghostVeh then return end
    if not ghost.rules.onReset then return end   -- server has ghosting off
    local veh = ownVehicle()
    local vehId = veh and vehicleId(veh) or nil
    if not vehId then return end
    pit.ghostVeh = vehId
    ghost.reason(vehId, 'pit', true, veh)
    -- Only tell the server if a RESET ghost is not already running on this car.
    -- The two share one per-player ghost on the server, so announcing a 5 s pit
    -- ghost over a 15 s reset ghost would cut the longer one short for everyone
    -- else -- and the car is already ghosted on every client anyway, which is
    -- the only thing the broadcast is for. Locally the two are separate reasons,
    -- so whichever ends last is what actually restores collision.
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
    ghost.reason(vehId, 'pit', false)
    -- Symmetrically: only end what we started. Ending a broadcast we did not
    -- send would drop a reset ghost that is still running.
    if pit.ghostSent and inMultiplayer() and ghost.own.vehId == nil then
      TriggerServerEvent('RM_GhostEnd', '')
    end
    pit.ghostSent = false
  end
end

-- Let a car go again, and forget the stop.
function pit.release(reason)
  if not pit.active then return end
  pit.active   = false
  pit.left     = 0
  pit.repaired = false
  pit.cooldown = TUNE.PIT_COOLDOWN
  -- The car is standing in the box it just used. It does not get another stop
  -- out of that box until it has driven out of it.
  pit.mustLeave = true
  pit.setGhost(false)
  setLocalVehicleFrozen(false)
  pushRouteState()
  log('I', 'raceManager', 'Pit stop ended (' .. tostring(reason or 'complete') .. ')')
end

-- The pit stop itself: hold the car, repair it, hand it back.
--
-- Deliberately NOT a respawn anchor. A stall repairs the car where it stands
-- and nothing more -- it does not become the place a later reset returns to,
-- which keeps it clear of the reset ruleset entirely.
function pit.update(dt)
  if pit.cooldown > 0 then pit.cooldown = pit.cooldown - dt end

  -- A stop cannot outlive the session it started in, or a driver is handed a
  -- frozen car in the lobby.
  if pit.active and not (sessionRunning() and not spectatorLock) then
    pit.release('session ended')
    return
  end

  if pit.active then
    pit.left = pit.left - dt
    if not pit.repaired and pit.left <= TUNE.PIT_REPAIR_AT then
      pit.repaired = true
      local veh = ownVehicle()
      if veh then
        -- The repair is a vehicle reset as far as BeamNG is concerned, and the
        -- reset hook must recognise it as ours: a pit stop is not a driver
        -- reset and must never spend a reset allowance or be reported as one.
        local ok, p = pcall(function () return veh:getPosition() end)
        if ok and p then noteSelfTeleport(p.x, p.y, p.z) end
        pcall(function () veh:queueLuaCommand('recovery.recoverInPlace()') end)
        -- The reset reloads the vehicle VM and takes the freeze with it, so it
        -- goes straight back on -- the car must not be free to leave early.
        setLocalVehicleFrozen(true, 'pit')
        -- The VM reload takes the GHOST with it too, for the same reason and
        -- just as silently: setGhostEnabled is a vehicle-side call, so the
        -- repair would quietly hand collision back with seconds of the stop
        -- still to run. Re-assert it against the id we ghosted, not a fresh
        -- lookup, so this is the same car either way.
        if pit.ghostVeh then
          ghost.apply(pit.ghostVeh, veh, true, TUNE.GHOST_ALPHA)
        end
      end
      pushNotice('pit', 'Repaired, hold for the release')
    end
    if pit.left <= 0 then
      pit.release('complete')
      pushNotice('pit', 'GO!')
    end
    return
  end

  if pit.promptLeft > 0 then pit.promptLeft = pit.promptLeft - dt end

  if #pitRoute == 0 then return end
  if not sessionRunning() or spectatorLock or gridFrozen then return end
  local veh, pos = sampledVehicle()
  if not veh or not pos then return end

  -- Which stall the car is standing in, if any. Worked out BEFORE the cooldown
  -- is consulted, so driving out during it still re-arms the stall: leaving is
  -- what makes the next entry a fresh visit, and a driver who has left and come
  -- back has done the thing a stop asks for.
  local inStall = nil
  for i, wp in ipairs(pitRoute) do
    if pit.inside(wp, pos) then inStall = i; break end
  end
  if not inStall then
    pit.mustLeave = false
    return
  end
  if pit.mustLeave or pit.cooldown > 0 then return end

  -- Being in the box is no longer enough to be serving a stop.
  --
  -- A pit stop is something a driver PERFORMS. The trigger used to be the box
  -- alone, so a car that clipped a corner of a stall at racing speed was seized
  -- and frozen where it stood -- the stop happened TO them, in the middle of the
  -- lane, at whatever angle they were travelling. Now the car has to actually be
  -- stopped in the stall, which is the thing a pit stop is, and which puts the
  -- decision back with the driver: come in slowly enough to stop in the box, or
  -- run through it and go round again. Missing it costs nothing but the lap --
  -- no stop is started, so no cooldown is spent and the stall is live on the
  -- next visit.
  local ok, speed = pcall(function ()
    local v = veh:getVelocity()
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  end)
  if not ok or not speed then return end

  if speed > TUNE.PIT_STOP_SPEED then
    -- In the box and still rolling. Say so, throttled -- unthrottled this is a
    -- UI push every frame for as long as a car creeps across the stall.
    if pit.promptLeft <= 0 then
      pit.promptLeft = TUNE.PIT_PROMPT_EVERY
      pushNotice('pit', 'PIT STALL: come to a stop inside the box')
    end
    return
  end
  pit.active   = true
  pit.left     = TUNE.PIT_HOLD_SEC
  pit.repaired = false
  pit.stops    = pit.stops + 1
  pit.promptLeft = 0
  setLocalVehicleFrozen(true, 'pit')
  -- Ghost before the notice, so a car that is about to sit frozen in the lane
  -- stops being solid on the same frame it stops being able to move.
  pit.setGhost(true)
  pushNotice('pit', string.format('PIT STOP: %.0fs', TUNE.PIT_HOLD_SEC))
  pushRouteState()
  log('I', 'raceManager', string.format(
    'Pit stop %d started in stall %d', pit.stops, inStall))
  if inMultiplayer() then
    TriggerServerEvent('RM_PitStop', jsonEncode({ stall = inStall }))
  end
end

-- Age out both reset-side timers.
local function resetGuardUpdate(dt)
  if selfTeleport.left  > 0 then selfTeleport.left  = selfTeleport.left  - dt end
  if blockNoticeLeft    > 0 then blockNoticeLeft    = blockNoticeLeft    - dt end
end

-- Heading (hx, hy) -> yaw about Z, expressed as a quaternion that stands a
-- VEHICLE facing down that heading. BeamNG vehicle models point down -Y at
-- identity, so a half-turn is baked in on top of the heading yaw - without it
-- every placement came out exactly 180° backwards.
headingRot = function (hx, hy)
  local yaw  = math.atan2(hx, hy) + math.pi
  local half = yaw * 0.5
  return quat(0, 0, math.sin(half), math.cos(half))
end

-- "Last Checkpoint" reset mode: stand the car on a gate's centre, facing the
-- gate's direction of travel. The teleport is flagged as our own so the
-- vehicle-reset echo it provokes is never miscounted, and the gate becomes the
-- new "last good position" so a blocked follow-up reset restores there.
local function relocateToGate(wp)
  local veh = playerVehicle()
  if not veh or not wp then return false end
  -- Facing the way the car was GOING, not the way the gate points.
  --
  -- A gate shared between two lanes carries one heading and is driven both ways.
  -- Standing a counter-clockwise driver on it facing the stored heading turns them
  -- to face the clockwise field -- on a layout built around head-on collisions,
  -- that is a respawn pointing into oncoming traffic. lastGateBack is recorded at
  -- the crossing itself, so it is right for shared gates, branch gates and
  -- ordinary gates without any of them having to declare anything.
  local hx, hy = wp.hx, wp.hy
  if lastGateBack and wp == lastGate then hx, hy = -hx, -hy end
  local rot = headingRot(hx, hy)
  noteSelfTeleport(wp.x, wp.y, wp.z)
  local ok = pcall(function ()
    veh:setPositionRotation(wp.x, wp.y, wp.z, rot.x, rot.y, rot.z, rot.w)
  end)
  if ok then
    lastGoodPos = vec3(wp.x, wp.y, wp.z)
    lastGoodRot = rot
  else
    selfTeleport.left = 0
  end
  return ok
end

-- Undo a reset the driver was not entitled to. BeamNG has already teleported
-- the car by the time onVehicleResetted fires, so the block is applied after
-- the fact: put the car back exactly where it was standing a moment ago.
local function restoreLastGoodPosition()
  local veh = playerVehicle()
  if not veh or not lastGoodPos then return false end
  local rot = lastGoodRot or quat(0, 0, 0, 1)
  -- Armed BEFORE the teleport: the hook it triggers may arrive on this very
  -- frame, and hearing it back as a driver reset is what caused the loop.
  noteSelfTeleport(lastGoodPos.x, lastGoodPos.y, lastGoodPos.z)
  local ok = pcall(function ()
    veh:setPositionRotation(lastGoodPos.x, lastGoodPos.y, lastGoodPos.z,
      rot.x, rot.y, rot.z, rot.w)
  end)
  if not ok then selfTeleport.left = 0 end
  return ok
end

-- BeamNG hook: the local player reset/recovered a vehicle. Registered as an
-- extension hook, so it fires for every vehicle - filter to our own first.
function M.onVehicleResetted(vehId)
  -- Ours, or there is nothing here to do. The attached vehicle can be another
  -- player's car - that is precisely the situation a driver who has just been
  -- taken off the track is in - and treating their reset as ours is how a rival
  -- ends up having their vehicle removed.
  if not isOwnVehicle(vehId) then return end
  local veh = ownVehicle()
  if not veh or vehicleId(veh) ~= vehId then return end
  -- Our own teleport coming back at us (a restore, a grid placement, a preview).
  -- Never a driver reset, so it must not be counted, blocked or reported.
  if isSelfTeleportEcho() then
    -- ...but this IS the moment a placement teleport wipes the freeze, because
    -- the reset reloads the vehicle's Lua VM and controller state with it. If a
    -- hold is wanted, put it straight back here rather than polling for it: this
    -- fires exactly when it is needed and nowhere else, so the drivetrain is
    -- left alone afterwards and a driver can still rev and pick a gear against
    -- the hold.
    if holdWanted then
      setLocalVehicleFrozen(true, holdWanted)
      log('I', 'raceManager', 'Hold re-applied after placement reset (' .. tostring(holdWanted) .. ')')
    end
    return
  end
  if spectatorLock then
    -- Out of the session: a reset must never put a spectator back on track.
    -- It cannot. The driving inputs are filtered off for as long as the lock is
    -- held, so a reset car is a car that still will not move -- and re-asserting
    -- the filter here covers the one thing a reset does that could undo it,
    -- which is reload the vehicle's Lua VM out from under the block.
    --
    -- This used to DELETE the car instead, which in BeamMP deleted it for every
    -- client in the session.
    spectate.setInputsBlocked(false)   -- force the next call to re-apply
    spectate.setInputsBlocked(true)
    return
  end

  -- A DRIVER reset while held on the grid. This is not the echo above -- the car
  -- really has been reset -- and the reset has just reloaded the vehicle's Lua
  -- VM, taking the freeze with it. Nothing used to put it back, so pressing
  -- reset on the grid was a way to be the only unfrozen car on it.
  --
  -- Handled here and not left to the drift watch because the driver should not
  -- get even the fraction of a second of movement that noticing drift costs:
  -- the car goes back on its slot and is pinned again on this frame.
  if holdWanted then
    hold.restore('driver reset while held on the grid')
    pushNotice('grid', 'Reset on the grid: you are back on your slot and held')
    return
  end

  -- The car has already been moved by the time this hook runs, so ghosting is
  -- armed HERE -- above the allowance rules and before anything decides what the
  -- reset was worth. Every branch below leaves the car somewhere it was not a
  -- moment ago: an allowed reset in place, a checkpoint-mode relocation, and a
  -- BLOCKED reset too, which teleports the car back to its last good position
  -- and can just as easily put it inside somebody. Ghosting is not a reward for
  -- a legal reset, it is a guard against a car appearing inside another one, so
  -- it does not care which of those happened.
  --
  -- Deliberately armed during qualifying as well as racing: the welding hazard
  -- is physics, not regulations, and cars are on track in both.
  if ghost.rules.onReset and (phase == 'racing' or phase == 'qualifying') then
    ghost.arm()
  end

  if resetsEnforced() and resetsUsed >= maxResets then
    -- Over the allowance. The reset INPUTS are already switched off at this
    -- point (resetInputBlockUpdate), so this branch only fires for a reset
    -- path the input filter cannot see; the car goes straight back where it
    -- was, the driver stays in the race, and the server is told so the
    -- attempt shows up in the live table and the results.
    local restored = restoreLastGoodPosition()
    -- Holding the reset key fires this hook over and over. The block above runs
    -- every time; the talking about it does not, or the notice channel, the
    -- console and the server all get flooded by one held key.
    if blockNoticeLeft <= 0 then
      blockNoticeLeft = BLOCK_NOTICE_EVERY
      if inMultiplayer() then TriggerServerEvent('RM_ResetDenied', '') end
      pushNotice('reset', maxResets == 0
        and 'RESET BLOCKED: no resets allowed in this session'
        or  ('RESET BLOCKED: all ' .. maxResets .. ' resets used'))
      log('W', 'raceManager', 'Reset blocked: allowance of ' .. maxResets
        .. ' exhausted (position ' .. (restored and 'restored' or 'NOT restored') .. ')')
    end
    -- Nothing in the pushed state changed (a blocked reset spends no allowance),
    -- so there is deliberately no pushRouteState here: it would be one more UI
    -- message per attempt for no new information.
    return
  end

  -- The reset is allowed to happen. "Last Checkpoint" mode: the repair itself
  -- already happened where the car stands (BeamNG did it before this hook
  -- fired), but the driver races on from the last checkpoint they crossed
  -- rather than from the crash site. Applies whether or not resets are
  -- limited; before the first gate of a session it falls back to in-place.
  if resetMode == 'checkpoint' and phase == 'racing' and lastGate and not gridFrozen then
    relocateToGate(lastGate)
  elseif sessionRunning() and not gridFrozen and prevPos then
    -- BOTH RESET KEYS HAVE TO MEAN THE SAME THING DURING A SESSION.
    --
    -- BeamNG ships two and they are not the same action: one repairs in place,
    -- the other is a RECOVERY that teleports the car to a spawn point. In a race
    -- that second one is a free ride, and drivers find it by pressing the key
    -- they normally press. Blocking it would leave a dead key, so the teleport is
    -- undone instead and both keys do the in-place repair.
    --
    -- Two references, and BOTH have been got wrong once:
    --   * prevPos ONLY, never the rolling lastGoodPos. That one is up to a
    --     quarter of a second old, and a car at racing speed covers more ground
    --     in that time than the threshold allows, so an ordinary reset looks like
    --     a teleport and gets undone. Two tests catch it, and have twice.
    --   * The car is read DIRECTLY, not through sampledVehicle(). That caches for
    --     the frame and a reset arrives mid-frame, so it returns the position
    --     from before the teleport, the distance comes out as nothing, and the
    --     undo stands down. That is why a recovery key still stranded drivers on
    --     their start position.
    local was = prevPos
    local veh = playerVehicle()
    local pos = nil
    if veh then pcall(function () pos = veh:getPosition() end) end
    if pos and was then
      local dx, dy, dz = pos.x - was.x, pos.y - was.y, pos.z - was.z
      if (dx * dx + dy * dy + dz * dz) > (TUNE.RECOVER_SNAP_RANGE * TUNE.RECOVER_SNAP_RANGE) then
        noteSelfTeleport(was.x, was.y, was.z)
        pcall(function ()
          local rot = veh:getRotation()
          veh:setPositionRotation(was.x, was.y, was.z, rot.x, rot.y, rot.z, rot.w)
        end)
        pushNotice('reset', 'Recovered in place: a race reset does not move you off the track')
        log('I', 'raceManager', 'Undid a recovery teleport during a session')
      end
    end
  end

  -- EVERY legal reset makes the new position the good one, immediately.
  --
  -- This lived inside the allowance check below, so on a server running unlimited
  -- resets -- the default -- it never ran. The position references then still
  -- described where the car was before the FIRST reset, and the next press
  -- dragged it back there: press one key, drive on, press the other, and land
  -- where you reset a minute ago. It read as the two keys disagreeing, and they
  -- were not: they were both measuring against the same stale sample.
  --
  -- prevPos is RE-SEEDED, not cleared. It is the per-frame sample the crossing
  -- test carries forward, and after a teleport it describes a position on the far
  -- side of one -- but clearing it leaves a hole, and the next reset to land in
  -- that hole has no reference to undo itself with. BeamNG's teleport then simply
  -- stands, which is a recovery key putting a driver back on their start position
  -- in the middle of a lap.
  --
  -- Seeded from where the car actually is now, which is both fresh and true.
  snapshotLeft = 0
  do
    local _, nowPos = sampledVehicle()
    prevPos = nowPos and vec3(nowPos.x, nowPos.y, nowPos.z) or prevPos
  end
  if resetsEnforced() then
    resetsUsed = resetsUsed + 1
    if inMultiplayer() then TriggerServerEvent('RM_VehicleReset', '') end
    local left = maxResets - resetsUsed
    pushNotice('reset', string.format('Reset %d/%d used: %d left', resetsUsed, maxResets, left))
    pushRouteState()
    return
  end

  -- Demo derby (isolated ruleset): the same policing against the derby's own
  -- allowance while a derby is running and this driver is still in it.
  if derbyResetsEnforced() then
    if derbyResetsUsed >= derbyMaxResets then
      local restored = restoreLastGoodPosition()
      if blockNoticeLeft <= 0 then
        blockNoticeLeft = BLOCK_NOTICE_EVERY
        if inMultiplayer() then TriggerServerEvent('RM_DerbyResetDenied', '') end
        pushNotice('reset', derbyMaxResets == 0
          and 'RESET BLOCKED: no resets allowed in this derby'
          or  ('RESET BLOCKED: all ' .. derbyMaxResets .. ' derby resets used'))
        log('W', 'raceManager', 'Derby reset blocked: allowance of ' .. derbyMaxResets
          .. ' exhausted (position ' .. (restored and 'restored' or 'NOT restored') .. ')')
      end
      return
    end
    derbyResetsUsed = derbyResetsUsed + 1
    snapshotLeft = 0
    if inMultiplayer() then TriggerServerEvent('RM_DerbyVehicleReset', '') end
    pushNotice('reset', string.format('Derby reset %d/%d used: %d left',
      derbyResetsUsed, derbyMaxResets, derbyMaxResets - derbyResetsUsed))
  end
end

-- BeamNG hook: a vehicle appeared. A driver serving a spectator penalty must
-- not be able to spawn a replacement until the session ends, so their new car
-- is removed immediately. Other players' vehicles are left alone.
function M.onVehicleSpawned(vehId)
  -- Module 4: a new car means a new configuration to declare to the server.
  reportVehicleConfig(true)
  -- A car that appears while a field-wide ghost is in force is ghosted NOW, not
  -- whenever the two-second sweep next comes round. A mass respawn is precisely
  -- the moment cars appear, and a car that spawns solid in the middle of one --
  -- for up to two seconds, or for good if the operation finishes first -- is the
  -- thing the ghost exists to prevent.
  if next(ghost.field) ~= nil and not isOwnVehicle(vehId) then
    local got, veh = pcall(getObjectByID, vehId)
    for reason in pairs(ghost.field) do
      ghost.reason(vehId, reason, true, got and veh or nil)
    end
  end
  -- A car reloaded or respawned while the grid is held arrives with no freeze on
  -- it - it is a new vehicle, and the old one's freeze died with it. Put the
  -- driver back on their slot, held, rather than leaving them the only car on
  -- the grid that can move.
  if holdWanted and isOwnVehicle(vehId) then
    hold.restore('vehicle respawned while held on the grid')
    pushNotice('grid', 'Back on your grid slot, held for the countdown')
  end
  if not spectatorLock then return end
  if not isOwnVehicle(vehId) then return end
  -- A spectator spawned themselves a fresh car to get back on track. The block
  -- is an INPUT filter rather than a property of the old vehicle, so the new one
  -- is just as undriveable -- but the spawn may have re-registered the action
  -- set, so it is re-applied here.
  --
  -- Deleting the car was the old answer, and it is what made an eliminated
  -- driver vanish from everybody's screen.
  spectate.setInputsBlocked(false)
  spectate.setInputsBlocked(true)
  pushNotice('spectate', 'You are spectating until the session ends')
  log('W', 'raceManager', 'Vehicle spawned in spectator mode: driving stays blocked')
end

-- BeamNG hook: a vehicle is being removed. Ghost bookkeeping is keyed by vehicle
-- id and vehicle ids are REUSED, so an entry left behind for a deleted car is not
-- merely stale -- the next car to be handed that id inherits a ghost nobody
-- armed, and (worse) inherits the belief that it is already ghosted, so the next
-- real ghost on it does nothing at all. Dropped here rather than aged out.
function M.onVehicleDestroyed(vehId)
  if vehId == nil then return end
  ghost.veh[vehId]     = nil
  ghost.applied[vehId] = nil
  ghost.left[vehId]    = nil
  ghost.alpha[vehId]   = nil
  -- The pid -> vehicle cache points at this id too. Left behind, the next car to
  -- be handed the id would be treated as belonging to whoever owned the old one.
  for pid, id in pairs(ghost.remoteVeh) do
    if id == vehId then ghost.remoteVeh[pid] = nil end
  end
  -- Our own car going away ends our ghost outright: there is nothing left to
  -- restore collision to, and holding the timer open would leave the next car
  -- this driver spawns waiting on a countdown that belonged to a deleted one.
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
-- The race creator drives to each grid slot and presses "Place Start Position
-- Here"; slot 1 is pole. The list travels with the track layout. When a race is
-- formed the server hands every driver a slot number (from qualifying, at
-- random, or hand-picked by the admin) and this client puts its own car on that
-- slot and holds it there - the server has no physics access, so only the
-- client can do either half.

-- Freeze/unfreeze the local car. BeamNG's vehicle-side controller exposes
-- setFreeze; queueLuaCommand is the GE-side way in, and it is pcall'd because
-- a vehicle without that controller must not break the start procedure.
-- Who imposed the current hold: 'race' (the grid, before the lights) or 'derby'
-- (form-up, before the derby countdown). Scoped for exactly the reason the
-- spectator lock is: the two modes run their start procedures independently, and
-- a racing phase change must never let go of a car being held for a derby, or
-- the other way round. Without this a race ending would turn every held derby
-- car loose in the middle of its countdown.
local freezeSource = nil

-- Freezing a car in place.
--
-- Through core_vehicleBridge, which is how BeamNG's own career code does it
-- (cargoScreen.lua, general.lua, progress.lua all call
-- executeAction(veh, 'setFreeze', ...)). The bridge routes the call through
-- gameplayInterface inside the vehicle VM instead of poking `controller`
-- directly, and that difference matters: queueLuaCommand only QUEUES a string,
-- so `controller.setFreeze(1)` was accepted, reported success, and then quietly
-- did nothing -- which is exactly what the logs showed, a hold requested
-- successfully and a car that drove away regardless.
--
-- The direct call is kept as a fallback for builds without the bridge; it is
-- still what the game's older exploration.lua uses.
setLocalVehicleFrozen = function (frozen, source)
  local veh = playerVehicle()
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
    gridFrozen = want
    freezeSource = want and (source or 'race') or nil
  end
  return ok
end

-- Put the local car on a placed start position, facing down the track.
-- Rotation comes from headingRot (Module 1), which bakes in the half-turn for
-- BeamNG's -Y vehicle forward - placements used to come out 180° backwards.
placeOnStartPosition = function (sp)
  local veh = playerVehicle()
  if not veh or not sp then return false end
  local rot = headingRot(sp.hx, sp.hy)
  -- Same story as the blocked-reset restore: this teleport comes back as a
  -- vehicle reset, and being gridded must never cost a driver an allowance.
  noteSelfTeleport(sp.x, sp.y, sp.z)
  local ok = pcall(function ()
    veh:setPositionRotation(sp.x, sp.y, sp.z, rot.x, rot.y, rot.z, rot.w)
  end)
  if not ok then selfTeleport.left = 0 end
  return ok
end

-- Holding a car for a standing start.
--
-- ONE path, shared by both modes: place the car, freeze it once, leave it alone.
-- The race hold has always behaved correctly doing exactly this, so the derby
-- does the same rather than anything of its own -- every derby-specific variant
-- tried here (re-asserting on a timer, deferring the first application, adding a
-- second one as a backstop) made it worse, and all of them were really working
-- around a freeze call that did nothing.
--
-- Applying it more than once is not harmless: each call re-pins the car at
-- whatever state it is in and resets the drivetrain, so revs bleed away and a
-- pre-selected gear will not stick. Revving and shifting against the hold is the
-- point of a standing start, so the freeze is issued once and never repeated.
local function requestHold(source)
  holdWanted = source
  local ok = setLocalVehicleFrozen(true, source)
  if ok then
    pushRouteState()
    log('I', 'raceManager', 'Hold requested (' .. tostring(source) .. ')')
  else
    -- Never fail quietly: a car that should be held and is not looks exactly
    -- like a start procedure that has not begun.
    log('W', 'raceManager', 'Hold (' .. tostring(source) .. ') could not be applied')
  end
  return ok
end

-- Put a held car back exactly where it was placed and pin it again.
--
-- Used by every path that can lose the hold: the local drift watch, a driver
-- reset on the grid, a vehicle reloaded on the grid, and the server's
-- correction. All four want the same thing -- the car back on its slot, facing
-- down the track, frozen -- so they share one implementation and one log line.
--
-- The teleport is flagged as our own so the vehicle-reset report it provokes is
-- not read as a driver reset and does not cost anyone a reset allowance.
--
-- A field of the hold table rather than a local function, for the same two
-- reasons the ghost module is: this file is close to Lua's 200-local ceiling,
-- and onVehicleResetted -- several hundred lines above here -- has to be able to
-- call it. A table field is resolved when it is called, not when it is compiled.
function hold.restore(reason)
  if not holdWanted then return false end
  local veh = ownVehicle()
  if not veh then return false end
  -- Back to where it settled if it ever did, and to the slot itself if it has
  -- not (a reset during the settle window).
  local to = hold.anchor or hold.slot
  if to then
    local rot = hold.rot or quat(0, 0, 0, 1)
    noteSelfTeleport(to.x, to.y, to.z)
    local ok = pcall(function ()
      veh:setPositionRotation(to.x, to.y, to.z, rot.x, rot.y, rot.z, rot.w)
    end)
    if not ok then selfTeleport.left = 0 end
    -- The car has just been dropped again, so it has to settle again -- and
    -- until it has, nothing may measure it. Without this a restore is followed
    -- immediately by the drift it caused, which is the loop this guard is for.
    hold.anchor = nil
    hold.settleLeft = TUNE.HOLD_SETTLE_GRACE
  end
  -- After the teleport, never before: the reset that a teleport reports back
  -- would otherwise reload the vehicle VM and take this freeze with it.
  setLocalVehicleFrozen(true, holdWanted)
  hold.corrections = hold.corrections + 1
  -- One line per correction would be one line per frame for a car whose freeze
  -- cannot be applied at all, which is exactly the case worth being able to read
  -- the log for. The count keeps the total honest.
  if hold.correctLeft <= 0 then
    log('W', 'raceManager', string.format(
      'Grid hold restored (%s): correction #%d', tostring(reason), hold.corrections))
  end
  hold.correctLeft = TUNE.HOLD_CORRECT_COOLDOWN
  return true
end

-- Watch a held car and report where it is.
--
-- Locally: a car that has moved off its slot is put back, correcting the
-- SYMPTOM rather than enumerating every cause of a lost freeze. Upward: the
-- server owns the hold and is told where the car is on a steady cadence, so a
-- client modified to skip the local guard still has the server behind it.
--
-- Nothing happens until the car has SETTLED, and the resting position becomes
-- the anchor. A car dropped on a slot falls onto its suspension, which is both
-- movement and displacement: enforcing against that teleported it back up to
-- spawn height, the teleport was reported as a reset, and it hovered there being
-- reset every frame instead of settling.
--
-- Graded response: a car merely MOVING is re-frozen where it stands, which
-- provokes no reset. Only one that has LEFT its slot is teleported back.
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

  -- Position reporting, and it happens whatever the enforcement below decides.
  -- Telemetry is not enforcement: a car that is still settling is exactly the
  -- car the server most wants to be able to see, and going quiet during the
  -- grace would be a window in which it was flying blind. A quarter-second
  -- cadence, because a full grid reporting every frame would be eleven messages
  -- a frame about cars that are meant not to be moving.
  if inMultiplayer() then
    hold.reportLeft = hold.reportLeft - dt
    if hold.reportLeft <= 0 then
      hold.reportLeft = TUNE.HOLD_REPORT_EVERY
      TriggerServerEvent('RM_HoldPos', jsonEncode({
        x = pos.x, y = pos.y, z = pos.z, slot = gridSlot,
      }))
    end
  end

  -- Settling. The car is left completely alone until it stops moving, or until
  -- the grace runs out for a car that never quite stops (resting on a kerb, an
  -- idle shake). Whatever it is doing then is the baseline.
  if hold.settleLeft > 0 then
    hold.settleLeft = hold.settleLeft - dt
    -- Settling is a car dropping onto its suspension: vertical, and going
    -- nowhere. A car that has moved ACROSS the ground is not settling, it is
    -- leaving -- so the grace is not a window in which the hold is off. It is
    -- measured from the slot here because there is no resting position yet.
    local away = 0
    if hold.slot then
      local ax, ay = pos.x - hold.slot.x, pos.y - hold.slot.y
      away = math.sqrt(ax * ax + ay * ay)
    end
    if away > TUNE.HOLD_DRIFT then
      hold.restore(string.format('left the slot (%.2fm) before settling', away))
      pushNotice('grid', 'Hold the car, the countdown has not finished')
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
    -- HORIZONTAL distance only. Creeping off the line is a move across the
    -- ground; a car dropping onto its suspension, sagging as it cools, or
    -- resting on a kerb moves vertically and is not creeping. Measuring in
    -- three dimensions makes ordinary settling indistinguishable from jumping
    -- the start, and the car gets dragged back for standing still.
    local dx = pos.x - hold.anchor.x
    local dy = pos.y - hold.anchor.y
    local drift = math.sqrt(dx * dx + dy * dy)
    if drift > TUNE.HOLD_DRIFT then
      -- Off the slot: put it back. Not rate-limited, because landing on the same
      -- anchor every time is idempotent and a car whose freeze cannot be applied
      -- at all must not be allowed to ratchet forward between corrections. Only
      -- the talking about it is throttled.
      local announce = hold.correctLeft <= 0
      hold.restore(string.format('%.2fm off the slot at %.1f m/s', drift, speed))
      if announce then
        pushNotice('grid', 'Hold the car, the countdown has not finished')
      end
      return
    end
    if speed > TUNE.HOLD_CREEP_SPEED then
      -- Moving but still on its slot: the freeze has been lost and the car is
      -- about to leave. Re-pin it where it stands. No teleport, so no vehicle
      -- reset and none of the loop that came with one.
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

-- GO (or any exit from the start procedure): release the car.
-- `source` names the mode letting go. A hold imposed by the other mode is left
-- alone. Passing nil forces the release, which is what a session ending or the
-- extension unloading wants: with no server left to lift it, a held car would
-- stay held forever.
local function releaseGridHold(source)
  -- Intent goes first. A reset echo that has yet to arrive checks holdWanted
  -- before re-applying, so clearing it here is what stops a car being frozen a
  -- moment after it was deliberately let go.
  if not source or not holdWanted or holdWanted == source then
    holdWanted = nil
  end
  -- The anchor goes with the intent. A stale one would have the drift watch
  -- pulling a racing car back onto a grid slot it left at the lights.
  if not holdWanted then
    hold.anchor = nil
    hold.slot = nil
    hold.rot = nil
    hold.settleLeft = 0
    hold.reportLeft = 0
  end
  if not gridFrozen then return end
  if source and freezeSource and freezeSource ~= source then return end
  setLocalVehicleFrozen(false)
  gridFrozen = false
  freezeSource = nil
  pushRouteState()
end

-- ===========================================================================
-- Field placement: one ghosted, staggered queue
-- ===========================================================================
-- Everything that moves this client's car as part of a FIELD goes through here:
-- forming a grid, and putting every car back when a session ends. Both are the
-- same physical problem -- several vehicles arriving at nearly the same place at
-- nearly the same instant -- and both used to be done immediately, on the tick
-- the server event arrived. That is how a spawn gets refused for an occupied
-- location, and how two cars land inside each other and are thrown apart by the
-- solver the moment they exist.
--
-- Three things fix it, and all three are needed:
--   * Ghosting. Collisions with other players' cars are off for the whole
--     operation, so a car landing on top of another is a non-event.
--   * A stagger. Each client waits (its order in the field) x STAGGER before
--     placing its own car, so the field lands as a sequence, not a pile. No
--     coordination is needed: the server hands out the order with the slot.
--   * A settle window before collisions come back, sized for the WHOLE field
--     rather than our own car, plus a hard timeout so a client that somehow
--     never finishes still gets its collisions back.
--
-- The settle is deliberately a TIMER and not a "wait until the cars stop
-- moving" test. On a grid the cars are frozen for the standing start, so they
-- are already still; a motion test would either fire instantly or never, and
-- collisions have to come back on a held car exactly as reliably as on a rolling
-- one.
local FIELD = {
  STAGGER     = 0.18,   -- seconds between one car landing and the next
  SETTLE      = 1.2,    -- seconds after the last car lands
  SPAWN_GRACE = 0.5,    -- seconds for a spawned vehicle to exist
  TIMEOUT     = 15.0,   -- hard cap: collisions come back regardless
}

local field = {
  active  = false,
  step    = nil,     -- wait | spawn | grace | place | settle
  delay   = 0,       -- until OUR car is placed
  grace   = 0,       -- until a just-spawned vehicle is usable
  settle  = 0,       -- until collisions come back
  timeout = 0,
  respawn = false,   -- put our removed car back as part of this operation
  slot    = nil,     -- slot to stand on
  slots   = nil,     -- which slot list that indexes (race grid or derby arena)
  hold    = false,   -- freeze once placed
  holdSource = nil,  -- 'race' | 'derby' -- who owns the hold, so the other mode
                     -- can never release it
}

-- Stand the car on its assigned slot. Called from the scheduler, never directly:
-- placing a car is the part that has to be staggered and ghosted.
local function placeOnAssignedSlot()
  local slot = field.slot
  local list = field.slots or startPositions
  local sp = slot and list[slot]
  -- Same fallback as the respawn above, and for the same reason: any placed slot
  -- is a better place to stand than wherever the car happened to appear.
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
  -- Where this car is meant to be standing, remembered before the hold is asked
  -- for. Everything that verifies or restores the hold measures against this:
  -- the local drift watch, the reset/respawn restores, and the server's
  -- correction. Kept separately from lastGoodPos below because that one belongs
  -- to the reset ruleset and moves as the driver laps.
  if field.hold then
    -- The slot's coordinates are where the car is DROPPED, not where it will
    -- come to rest -- it still has to fall onto its suspension. Anchoring here
    -- would mean every correction teleported the car back up to the drop height,
    -- so the anchor is left unset and captured once the car has settled.
    hold.anchor = nil
    hold.slot   = vec3(sp.x, sp.y, sp.z)
    hold.rot    = headingRot(sp.hx, sp.hy)
    hold.settleLeft  = TUNE.HOLD_SETTLE_GRACE
    hold.corrections = 0
  end
  if field.hold then requestHold(field.holdSource or 'race') end
  -- The grid slot is where the car legitimately stands, so it is also the
  -- position a blocked reset should restore to - facing down the track, not
  -- at whatever identity rotation happens to mean on this circuit.
  lastGoodPos = vec3(sp.x, sp.y, sp.z)
  lastGoodRot = headingRot(sp.hx, sp.hy)
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
end

-- Queue a placement. A release and a grid slot that arrive on the same tick --
-- which is exactly what forming a grid sends to a driver who was spectating --
-- are ONE operation: put the car back, then stand it on its slot, under a single
-- ghost.
queueFieldPlacement = function (opts)
  local order = math.max(math.floor(tonumber(opts.order) or 1), 1)
  local count = math.max(math.floor(tonumber(opts.count) or order), order)
  local delay  = (order - 1) * FIELD.STAGGER
  local settle = (count - 1) * FIELD.STAGGER + FIELD.SETTLE

  -- Coalesce only while the operation has not placed the car yet. Once it has
  -- (step 'settle', which is just the wait for collisions to come back), a new
  -- request is a NEW placement and has to run from the start -- folding it into
  -- a settling operation would set a slot that nothing ever stands the car on.
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
  log('I', 'raceManager', string.format(
    'Field placement queued (order %d/%d, +%.2fs, respawn=%s, slot=%s)',
    order, count, delay, tostring(field.respawn), tostring(field.slot)))
end

local function fieldUpdate(dt)
  if not field.active then return end
  field.timeout = field.timeout - dt

  -- Timeout: whatever is stuck, the driver gets their car and their collisions
  -- back rather than being left ghosted for the rest of the session.
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
        -- BeamNG spawns asynchronously: the vehicle is not usable on this frame.
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
    -- Explicitly, every time. After a mass respawn the game picks a camera
    -- target on its own, and with a whole field appearing at once its pick is
    -- arbitrary - which is how everyone ended up watching the same car.
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

-- Run a queued placement to completion right now. For the paths that have no
-- more update ticks coming (the extension unloading, a BeamMP session ending):
-- a car left un-ghosted and unspawned there would stay that way.
local function flushFieldPlacement()
  if not field.active then return end
  if field.respawn then respawnRemovedVehicle() end
  if field.slot then placeOnAssignedSlot() end
  bindCameraToOwnVehicle()
  endFieldOperation()
end

-- Server assigned this client a grid slot: stand the car on it and hold it.
-- `order`/`count` place this driver in the field so the placement can be
-- staggered; they default to the slot number, which is the same thing whenever
-- the grid is complete.
local function applyGridSlot(slot, order, count)
  gridSlot = slot
  -- WHICH WAY ROUND THIS CAR IS GOING, taken from the slot it was just given.
  --
  -- The tag rides on the start position, so both halves of the mod work it out
  -- from the same data without a message passing between them: the server sets
  -- rec.lane when it hands out the slot, this sets the local one when the slot
  -- arrives. Nothing is reported upstream, so a driver cannot ask for a lane.
  --
  -- Locked for the session. A head-on race is not a line a driver picks per lap,
  -- it is the direction they were entered in -- and a car spun round by a
  -- collision must still be scored on the lap it is actually running.
  local sp = slot and startPositions[slot]
  local lane = (type(sp) == 'table' and type(sp.branch) == 'string' and sp.branch ~= '')
    and sp.branch or nil
  branch.lane = lane
  -- LOCKED FOR EVERYONE ON A GRID-ASSIGNED TRACK, including the drivers on the
  -- main route.
  --
  -- Locking only the tagged half would leave a clockwise driver "undecided", and
  -- an undecided car is moved onto whichever lane's gate it crosses first. Spin
  -- one round on a head-on oval and it would pick up the oncoming lane and start
  -- scoring laps the other way. If the track assigns lanes at the grid at all,
  -- then no lane on it is a choice -- untagged means the main route, and that is
  -- just as much an assignment as the tag is.
  local assigned = false
  for _, s in ipairs(startPositions) do
    if type(s.branch) == 'string' and s.branch ~= '' then assigned = true; break end
  end
  branch.lock = assigned
  if lane then
    pushNotice('branch', 'You are racing the ' .. branch.nameOf(lane) .. ' line')
    log('I', 'raceManager', 'Grid slot ' .. tostring(slot) .. ' puts this car on lane ' .. lane)
  end
  if not slot then
    -- Standing down (withdrawn, or not entered): nothing to place, and nothing
    -- should still be holding this car.
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
-- A ghosted car has no vehicle-to-vehicle collision. Three things want that,
-- and they overlap in time, so they are refcounted BY REASON and PER VEHICLE:
--
--   'quali'      -- rivals stop being obstacles during a flying lap
--   'placement'  -- a field being teleported onto a grid has to land through
--                   itself rather than pile up
--   'reset'      -- a driver who reset mid-race is intangible until the space
--                   around them is provably clear (the rest of this section)
--
-- Per vehicle, not one global flag: two drivers resetting a second apart are
-- two independent ghosts, and neither may end the other's.
--
-- HOW COLLISION IS ACTUALLY DROPPED. This used to probe MPVehicleGE for
-- setGhostMode/setGhosts/enableGhostMode, find none of them on any build, and
-- fall back to fading rival cars while leaving them solid -- so ghost
-- qualifying looked like it worked and never did. The toggle is not BeamMP's
-- at all: it is BeamNG's own `obj:setGhostEnabled(bool)`, a VEHICLE-side call
-- reached from here through queueLuaCommand, the same bridge the grid freeze
-- uses. It is per vehicle, it leaves world and terrain collision alone, and the
-- engine drives it itself for instability recovery (lua/ge/main.lua) -- BeamNG's
-- own multiplayer has `ghostOnReset`/`ghostOnTp` vehicle globals that do
-- precisely this feature.
--
-- Because it is per vehicle, every client must ghost the SAME car, which is
-- what the RM_Ghost broadcast is for. A vehicle id is meaningless across
-- clients (it is a local scene-object id), so the wire carries the BeamMP
-- player id -- which MPVehicleGE reports as `ownerID`, and which is the same
-- key the server files everyone under.

-- Walk vehicles. getAllVehicles() is the GE-side, allocation-free way to do it
-- and hands back vehicles only, where be:getObject(i) walks every scene object
-- and has to be filtered; the old loop stays as the fallback. `skipId` drops one
-- car from the walk -- usually ours, sometimes the one being tested.
local function forEachVehicle(skipId, fn)
  if type(getAllVehicles) == 'function' then
    local ok, list = pcall(getAllVehicles)
    if ok and type(list) == 'table' then
      for _, veh in ipairs(list) do
        if veh then
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

-- Which local vehicle belongs to a given player id. This is the whole reason the
-- broadcast carries a pid: the answer is different on every client.
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

-- Set one car's mesh alpha, and only when it has actually moved. The fade runs
-- every frame for a second, and setMeshAlpha is a call across into the engine
-- per car -- with eleven cars on track, re-sending a value that has not changed
-- is the difference between a fade that is free and one that is measurable.
function ghost.fade(vehId, veh, alpha)
  if not veh then return end
  local was = ghost.alpha[vehId]
  if was and math.abs(was - alpha) < 0.01 then return end
  ghost.alpha[vehId] = alpha
  pcall(function () veh:setMeshAlpha(alpha, '', false) end)
end

-- Apply (or lift) the ghost on one car: the collision toggle, then the fade that
-- makes it visible. Both are pcall'd -- a vehicle that has just been deleted
-- must not take the update loop down with it.
--
-- Called on TRANSITIONS only. queueLuaCommand marshals a string into the
-- vehicle's own Lua VM, which is not something to do sixty times a second per
-- car for a value that changes twice per ghost; the per-frame fade goes through
-- ghost.fade above and never touches collision.
function ghost.apply(vehId, veh, on, alpha)
  if not veh then return end
  pcall(function ()
    veh:queueLuaCommand('obj:setGhostEnabled(' .. (on and 'true' or 'false') .. ')')
  end)
  ghost.fade(vehId, veh, on and (alpha or TUNE.GHOST_ALPHA) or 1)
  ghost.applied[vehId] = on or nil
end

-- Add or drop one reason on one vehicle, and make the car match.
--
-- `veh` is the vehicle object when the caller already has it -- which the field
-- sweep does, holding it from the walk it is in the middle of. Looking it up
-- again by id would be a scene lookup per car per sweep for a value already in
-- hand, and with eleven cars on a two-second sweep that adds up for nothing.
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
  -- THE gate every ghost passes through on its way back to solid, and the only
  -- one: no car is handed its collisions back while another car is inside it.
  --
  -- Every reason funnels through here -- the driver's own reset ghost, the pit
  -- stop, and the field-wide ones that ghost rivals during a mass respawn or
  -- qualifying -- so the rule holds for all of them without each having to
  -- remember it. The reason itself is already gone from the set above; what is
  -- deferred is only the moment the car stops being intangible.
  --
  -- A car that cannot go solid yet is parked in `pending` and retried by the
  -- update loop. It cannot get stuck: the cars involved are ghosts, which is
  -- precisely what lets them drive out of each other.
  if not want and veh and ghost.wouldWeld(vehId, veh) then
    ghost.pending[vehId] = true
    return
  end
  ghost.pending[vehId] = nil
  ghost.apply(vehId, veh, want, ghost.alphaFor(vehId))
end

-- Is another car inside this one? Ghost status is deliberately not consulted:
-- see the note in ghost.occupied for why an intangible car in the same space is
-- still a car in the same space.
--
-- Used for cars this client does not own, where there is no countdown and no
-- driver to warn -- just "not yet". ghost.occupied does the same job for our own
-- car and additionally explains itself, because that one has a driver waiting.
function ghost.wouldWeld(vehId, veh)
  local c1, x1, y1, z1 = ghost.bounds(veh, TUNE.GHOST_OVERLAP_MARGIN)
  local mine = ghost.centre(veh)
  -- A car the engine will not place at all is no evidence that anything is
  -- inside it, so it does not block. That asymmetry with ghost.occupied is
  -- deliberate: there, the car that cannot be located is OUR OWN and a driver
  -- is waiting on the answer, so the conservative reading is the safe one and a
  -- retry next frame will resolve it. Here the subject is somebody else's car,
  -- usually one mid-spawn or mid-delete, and "stay a ghost until we can measure
  -- you" is how a car ends up intangible for a whole race with nothing able to
  -- undo it -- which is the failure this file has already been through once.
  if not c1 and not mine then return false end
  local weld = false
  forEachVehicle(vehId, function (other)
    if weld then return end
    local c2, x2, y2, z2 = ghost.bounds(other, 0)
    if c1 and c2 and type(overlapsOBB_OBB) == 'function' then
      local okHit, hit = pcall(overlapsOBB_OBB, c1, x1, y1, z1, c2, x2, y2, z2)
      if not okHit or hit then weld = true end
      return
    end
    local theirs = ghost.centre(other)
    if not (mine and theirs) then return end
    local dx, dy, dz = mine.x - theirs.x, mine.y - theirs.y, mine.z - theirs.z
    if (dx * dx + dy * dy + dz * dz)
        <= (TUNE.GHOST_FALLBACK_RADIUS * TUNE.GHOST_FALLBACK_RADIUS) then
      weld = true
    end
  end)
  return weld
end

-- Alpha for a car mid-ghost. Translucent for most of the ghost, then fading
-- back to solid over the last second -- the warning that contact is about to
-- resume. The occupancy block deliberately does NOT fade: a car that is stuck
-- inside another stays visibly a ghost for as long as that lasts.
function ghost.alphaFor(vehId)
  local left = ghost.left[vehId]
  local fade = TUNE.GHOST_FADE_OUT_SEC
  if not left or fade <= 0 or left >= fade then return TUNE.GHOST_ALPHA end
  if left <= 0 then return TUNE.GHOST_ALPHA end
  local t = 1 - (left / fade)          -- 0 at fade start, 1 at contact
  return TUNE.GHOST_ALPHA + (1 - TUNE.GHOST_ALPHA) * t
end

-- The oriented bounding box of a car, as the four vectors overlapsOBB_OBB wants,
-- with `margin` metres added to every half-extent.
--
-- getSpawnWorldOOBB is the box BeamNG's own spawn-occupancy test uses
-- (lua/ge/spawn.lua). It is an ORIENTED box: a car lying crossways through
-- another is caught, where a distance between origins reports it as clear.
function ghost.bounds(veh, margin)
  if not veh then return nil end
  -- Preferred: the ORIENTED box. A car lying crossways through another is
  -- caught by it, where an axis-aligned box or a radius would report clear.
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
  -- Fallback: the axis-aligned world box, which is what BeamNG's own spawn
  -- occupancy test uses for vehicles that already exist (lua/ge/spawn.lua).
  -- getSpawnWorldOOBB can return nil -- shipping code nil-guards it -- and a
  -- single nil used to mean "assume occupied", which is how one unmeasurable
  -- car anywhere on the map left a driver ghosted for the rest of the race.
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
  -- Last measurement: the car's own dimensions, oriented by where it is facing.
  -- Every vehicle knows how big it is even when neither bounding box will say
  -- where it is, and these are physics-side calls that answer for another
  -- player's car as readily as for ours.
  --
  -- This tier matters more than a third fallback usually would. Below it there
  -- is only a flat radius, and a radius wide enough to contain the largest
  -- vehicle pair is several times wider than a car -- in a full field somebody
  -- is nearly always inside it, so a ghost that reached that fallback would stay
  -- up for most of the race. Measuring the actual car keeps the answer the size
  -- of a car.
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

-- Where a car is, when nothing will say how big it is. Used only by the
-- last-resort distance test below.
function ghost.centre(veh)
  if not veh then return nil end
  local ok, p = pcall(function () return veh:getPosition() end)
  if not ok or not p then return nil end
  return p
end

-- Is anything solid sharing this car's space?
--
-- THE HARD INVARIANT LIVES HERE. Restoring collision on two overlapping cars
-- welds their node structures together, which ends both races and cannot be
-- undone -- so this answers "am I certain it is clear", not "do I think it is".
-- Every way of failing to know (no bounding box, no vehicle list, an engine call
-- that threw) returns BLOCKED. A ghost that lasts too long is a nuisance; a
-- ghost lifted one frame too early is two ruined races.
--
-- Cars that are THEMSELVES ghosts are skipped, and that is load-bearing rather
-- than an optimisation: a ghost cannot weld to anything, so it is not a hazard,
-- and counting it as one would deadlock two overlapping ghosts against each
-- other forever -- which is exactly the three-cars-stacked case.
function ghost.occupied(vehId, veh)
  local c1, x1, y1, z1 = ghost.bounds(veh, TUNE.GHOST_OVERLAP_MARGIN)
  local mine = ghost.centre(veh)
  -- Nothing to measure ourselves against and nowhere to stand: we genuinely
  -- know nothing, so we stay ghosted. This is the only remaining way to be
  -- blocked without another car being involved, and a car with no position at
  -- all is a car that is being deleted -- which the teardown paths handle.
  if not c1 and not mine then
    ghost.blockReason = 'this car cannot be located'
    return true
  end

  local blocked, sawAny, reason = false, false, nil
  forEachVehicle(vehId, function (other, otherId)
    if blocked then return end
    -- A car inside this one blocks the restore whether or not it is ITSELF a
    -- ghost right now.
    --
    -- This used to skip ghosts, on the reasoning that a ghost cannot weld: an
    -- intangible car inside ours cannot hit us, so why wait for it. The flaw is
    -- that the other car's ghost is not ours to rely on -- it ends on its own
    -- clock, decided by its own client, and the instant it does there are two
    -- solid bodies in the same space. It also made the rule unusable in the one
    -- place it is needed most: after a race everybody is respawned at once, so
    -- every car is a ghost, so every car looked clear to every other one.
    --
    -- The rule is now simply that a car does not become solid while another car
    -- is inside it, for any ghosted condition. Two ghosts overlapping can always
    -- separate -- being ghosts is exactly what lets them drive apart -- so
    -- waiting for that cannot deadlock.
    sawAny = true
    local c2, x2, y2, z2 = ghost.bounds(other, 0)
    -- The precise test, when both cars can be measured. The margin is on OUR
    -- box only; inflating both would demand double the configured clearance.
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
    -- One of the two cannot be measured. That is NOT the same as being inside
    -- it: a car we cannot size up but which is fifty metres away is plainly not
    -- overlapping anything. Treating every measurement failure as an overlap is
    -- what left drivers ghosted for a whole race, because it could never
    -- resolve -- so the fallback is a real (if blunt) test rather than a
    -- verdict. The radius comfortably contains the largest vehicle pair.
    local theirs = ghost.centre(other)
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
  -- Nothing else on track at all is a clear frame, not an unknown one.
  if not sawAny then
    ghost.blockReason = nil
    return false
  end
  ghost.blockReason = blocked and reason or nil
  return blocked
end

-- Fills the forward declaration made beside the grid hold at the top of the
-- file. These two reasons are field-wide: they ghost every car this client can
-- see other than its own, which is what "rivals are ghosts" means locally.
setGhostReason = function (reason, on)
  -- Turning a reason ON skips our own car: these reasons mean "rivals are
  -- ghosts", and ghosting ourselves is the opposite. ownVehicle() and not
  -- playerVehicle(): once our car is deleted the game attaches us to somebody
  -- else's, and "the car I am attached to" would then exclude a RIVAL. With no
  -- car of our own the answer is nil and everything is ghosted, which is right
  -- for a mass respawn.
  --
  -- Turning a reason OFF skips NOTHING, and that asymmetry is the point. The ON
  -- path can reach our own car whenever ownVehicle() cannot name it, which is
  -- exactly the window a respawn opens. If the OFF path then skipped it because
  -- ownership HAS resolved, the reason would stay on forever with nothing able
  -- to clear it: a car that flashes solid as its reset ghost expires and goes
  -- straight back to being a ghost for the rest of the race. Clearing a reason a
  -- car never had is free.
  local skipId = nil
  if on then
    local mine = ownVehicle()
    skipId = mine and vehicleId(mine) or nil
  end
  forEachVehicle(skipId, function (veh, id) ghost.reason(id, reason, on, veh) end)
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
  -- Swept over EVERY car in the world, not just the ones this client believes
  -- it ghosted. A session ending has to leave nothing ghosted whatever the
  -- bookkeeping thinks -- an entry lost to a vehicle id being reused, or a ghost
  -- applied by an instance of this extension that has since been reloaded, would
  -- otherwise leave a car intangible with nothing left that could ever undo it.
  -- This runs once per session end, so walking the field costs nothing.
  ghost.applied = {}
  ghost.alpha = {}
  ghost.remoteVeh = {}
  forEachVehicle(nil, function (veh, id) ghost.apply(id, veh, false) end)
  ghost.applied = {}
  ghost.alpha = {}
  ghost.pending = {}
end

-- Arm this client's own reset ghost. Called straight from the reset hook and
-- applied LOCALLY on the spot -- no round trip -- because the dangerous frame is
-- this one, not the one the server's acknowledgement arrives on. The broadcast
-- follows so everyone else ghosts the same car.
--
-- A repeat reset while already ghosted RESTARTS the timer rather than stacking a
-- second ghost, and the restart is capped: a driver holding the reset key can
-- reach ghostMaxDurationSec of base timer and no further. The cap applies to the
-- base timer ONLY -- it has no bearing on the occupancy check, which has no time
-- limit in either direction.
function ghost.arm()
  local veh = ownVehicle()
  local vehId = veh and vehicleId(veh) or nil
  if not vehId then return end
  local rules = ghost.rules
  local base = rules.minSec
  if ghost.own.vehId == vehId and ghost.own.total > 0 then
    base = math.min(ghost.own.total + rules.minSec, rules.maxSec)
  end
  ghost.own.pid      = localServerId()
  ghost.own.vehId    = vehId
  ghost.own.total    = base
  ghost.own.left     = base
  ghost.own.blocked  = 0
  ghost.own.warned   = false
  -- The timer must not start on a car that is still being put down. It starts
  -- once the vehicle reports a usable bounding box, which is also the first
  -- moment the occupancy check could mean anything.
  ghost.own.settling   = true
  ghost.own.settleLeft = TUNE.GHOST_SETTLE_MAX
  ghost.left[vehId]  = base
  ghost.reason(vehId, 'reset', true)
  -- Holding the reset key fires the vehicle-reset hook over and over -- the same
  -- reason the blocked-reset notice further up is throttled. The ghost itself is
  -- re-armed every time (it is local, and free), but the SERVER is not told
  -- every time: only when the duration actually changes, which it stops doing
  -- once the repeat extension hits its cap, plus a floor of half a second so a
  -- held key cannot turn into a message per frame either way.
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

-- Lift our own ghost and tell the server, so every other client drops it too.
--
-- `why` is 'clear' when the occupancy check passed -- the only route that
-- restores collision to a car still on track, and the only one the driver is
-- told about. Every other caller is a teardown (the session ended, the driver
-- was stood down, the car was deleted) where there is no longer a race to be
-- careful about, and announcing "contact restored" would be noise.
function ghost.release(why)
  local vehId = ghost.own.vehId
  if vehId then
    ghost.left[vehId] = nil
    ghost.reason(vehId, 'reset', false)
  end
  ghost.own.vehId    = nil
  ghost.own.settling = false
  ghost.own.left     = 0
  ghost.own.total    = 0
  ghost.own.blocked  = 0
  ghost.own.warned   = false
  -- Forget what was last reported, so the NEXT ghost reports its duration even
  -- though it opens with the same number this one did.
  ghost.own.sentBase = nil
  ghost.own.sentAt   = nil
  if inMultiplayer() then TriggerServerEvent('RM_GhostEnd', '') end
  if why == 'clear' then pushNotice('ghost', 'Contact restored') end
  log('I', 'raceManager', 'Reset ghost released on vehicle ' .. tostring(vehId)
    .. ' (' .. tostring(why or 'clear') .. ')')
end

-- Someone else's ghost. `endsAt` is on the SERVER clock, so what gets applied
-- here is whatever is left of it by our reckoning of that clock -- a client
-- 250 ms behind ghosts the car for 250 ms less, never 250 ms more.
--
-- Only an `endsAt` of nil clears the ghost, and an elapsed one does NOT. The
-- server sends nil when the owning client has reported the space around its car
-- clear; until then the ghost stands however long ago its timer nominally ran
-- out, because the owner may be sitting inside somebody and still intangible.
-- Un-ghosting a car here on our own clock would make it solid in OUR physics
-- world while it was still a ghost in its owner's -- and a solid car overlapping
-- another solid car on this client welds the pair on this client. The elapsed
-- time is allowed to drive the fade and nothing else.
function ghost.applyRemote(pid, endsAt)
  if pid == nil then return end
  ghost.remote[pid] = endsAt
  local veh, vehId = ghost.vehicleForPid(pid)
  -- Cache which local car this player owns. Resolving it means asking BeamMP for
  -- its whole vehicle map, which builds a table -- fine here (an event, or the
  -- two-second sweep), not fine on the per-frame fade below, which is why that
  -- reads the cache instead.
  ghost.remoteVeh[pid] = vehId
  -- The car is not in this client's world yet (a join mid-ghost, or a vehicle
  -- still spawning). The intent is remembered above and the refresh sweep
  -- applies it as soon as the car appears.
  if not vehId then return end
  if endsAt ~= nil then
    local left = endsAt - ghost.serverTime
    ghost.left[vehId] = left > 0 and left or nil
    ghost.reason(vehId, 'reset', true)
    ghost.apply(vehId, veh, true, ghost.alphaFor(vehId))
  else
    ghost.left[vehId] = nil
    ghost.reason(vehId, 'reset', false)
  end
end

-- The server's whole ghost roster, off the state broadcast:
-- { { pid = ..., endsAt = ... }, ... }, end times on the server clock.
-- Authoritative, so a pid that is NOT in it has no ghost -- which is how a
-- client that missed an RM_Ghost clear (or was not connected for it) stops
-- showing a car as a ghost forever.
--
-- Our own row is skipped. Only this client can know whether the space around our
-- car is clear, so our own ghost is ours to end; the server's copy of it is for
-- everyone else's benefit.
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

-- The driver's own countdown, and the "you are stuck" warning. Its own guihook
-- channel rather than the notice channel: a countdown moves continuously and the
-- notice channel is for things that are said once.
--
-- Throttled to ~10 Hz, and silent entirely when there is no ghost. A guihook per
-- frame is a message per frame to the UI for a readout a driver cannot read that
-- fast, and this feature is meant to cost nothing with a full grid on track. The
-- UI interpolates between pushes, exactly as it does for the lap clock.
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

-- One update for all three ghost reasons, in the order they can affect each
-- other: the qualifying rule (armed by the phase, dropped the moment the session
-- changes, so nobody races ghosts), then this client's own reset ghost and the
-- occupancy check that ends it, then everyone else's ghosts and the fade. The
-- sweep at the end re-asserts whatever is wanted onto cars that have appeared
-- since -- a rival who joined or respawned mid-session is ghosted too, rather
-- than showing up solid.
local function ghostUpdate(dt)
  -- Only on a CHANGE. setGhostReason walks every vehicle on track, and calling
  -- it unconditionally would rebuild the vehicle list once a frame to tell it
  -- the same thing it was told last frame. The sweep at the bottom of this
  -- function is what catches cars that appeared since.
  local wantQuali = ghostQuali and phase == 'qualifying' and not spectatorLock
  if wantQuali ~= (ghost.field.quali == true) then
    setGhostReason('quali', wantQuali)
  end

  -- --- connected in the middle of somebody else's session -----------------
  -- The server refuses to enter a mid-session arrival (see RM_onPlayerJoin) and
  -- flags them instead. A driver who turns up halfway through a race has a car,
  -- a spawn point and no idea a race is running; without this they can put a
  -- leader into a wall before they have finished reading the chat line telling
  -- them not to.
  --
  -- An untimed reason rather than the timed ghost roster, which exists for reset
  -- ghosting and caps out at fifteen seconds. This one lasts exactly as long as
  -- the flag does, and the flag is cleared when the next grid forms.
  if isBystander ~= (ghost.field.bystander == true) then
    setGhostReason('bystander', isBystander)
    if isBystander then
      pushNotice('spectate', 'A session is already running: you are a ghost until it ends')
    end
  end

  -- --- this client's own reset ghost -------------------------------------
  local own = ghost.own
  -- Ends the moment the race does. Taking the flag, being stood down, the
  -- session finishing and a return to the lobby all land here, and none of them
  -- leaves a car to be careful around: the field is about to be respawned or
  -- removed wholesale, and the placement ghost covers that.
  if own.vehId and not ((phase == 'racing' or phase == 'qualifying') and not spectatorLock) then
    ghost.release('session ended')
  end
  if own.vehId then
    local got, veh = pcall(getObjectByID, own.vehId)
    veh = got and veh or nil
    if not veh then
      -- The car is gone (deleted, or the driver was stood down). Nothing to
      -- un-ghost, and nothing to keep counting.
      ghost.release('vehicle gone')
    else
      if own.settling then
        -- "Placed and settled": the first frame the car reports a usable box --
        -- or, failing that, a short fixed wait. Waiting on the box ALONE is
        -- another way to be ghosted forever: a car that never reports one would
        -- never start its timer, so the ghost would have nothing to count down
        -- and no way to end. The occupancy check is what actually guards the
        -- restore, and it copes with an unmeasurable car on its own.
        own.settleLeft = own.settleLeft - dt
        if ghost.bounds(veh, 0) or own.settleLeft <= 0 then own.settling = false end
      else
        if own.left > 0 then
          own.left = math.max(own.left - dt, 0)
          ghost.left[own.vehId] = own.left
          -- Drive the fade while it is running. Alpha only: the car is already
          -- ghosted and re-sending that every frame would be a vehicle-VM
          -- command per frame for no change.
          ghost.fade(own.vehId, veh, ghost.alphaFor(own.vehId))
        else
          -- Base timer done: collision comes back on the first CLEAR frame and
          -- not one before it. There is no time limit on this and no force.
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
  -- The shared clock runs on between server pushes so the last-second fade is
  -- smooth at 60 fps instead of stepping three times a second. Every state
  -- broadcast re-anchors it, so drift cannot accumulate -- the same
  -- interpolate-and-correct arrangement the live lap clock uses.
  ghost.serverTime = ghost.serverTime + dt
  for pid, endsAt in pairs(ghost.remote) do
    local vehId = ghost.remoteVeh[pid]
    if vehId then
      -- A lapsed ghost drops back to a flat translucent rather than staying
      -- opaque: the fade said "contact is coming", and if the ghost is still
      -- standing after it, contact did not come. Showing the car as solid while
      -- it is still intangible would be the more confusing of the two lies.
      local left = endsAt - ghost.serverTime
      ghost.left[vehId] = left > 0 and left or nil
      local got, veh = pcall(getObjectByID, vehId)
      if got and veh then ghost.fade(vehId, veh, ghost.alphaFor(vehId)) end
    end
  end

  -- --- re-assert sweep ----------------------------------------------------
  -- Cars appear (a join, a respawn) after the event that ghosted them, so what
  -- is wanted is re-applied on a slow timer rather than assumed to have stuck.
  -- --- cars still waiting to go solid ------------------------------------
  -- A ghost whose reasons have all gone but which had a car inside it when the
  -- moment came. Retried until the space is clear, because "not while somebody
  -- is inside you" is the whole rule and a timer cannot honour it.
  --
  -- Faster than the re-assert sweep below and slower than a frame: a driver
  -- rolling clear should get their collisions back promptly, and the check
  -- measures every car on track, so it is not something to do sixty times a
  -- second with a full grid.
  ghost.pendingIn = (ghost.pendingIn or 0) - dt
  if ghost.pendingIn <= 0 then
    ghost.pendingIn = 0.2
    for vehId in pairs(ghost.pending) do
      local got, veh = pcall(getObjectByID, vehId)
      veh = got and veh or nil
      if not veh then
        ghost.pending[vehId] = nil
      elseif ghost.veh[vehId] then
        -- A reason came back while it waited; it is a ghost again on its own
        -- account and no longer pending anything.
        ghost.pending[vehId] = nil
      elseif not ghost.wouldWeld(vehId, veh) then
        ghost.pending[vehId] = nil
        ghost.apply(vehId, veh, false, 1)
      end
    end
  end

  ghost.refresh = ghost.refresh - dt
  if ghost.refresh > 0 then return end
  ghost.refresh = 2.0
  for reason in pairs(ghost.field) do setGhostReason(reason, true) end
  for pid, endsAt in pairs(ghost.remote) do ghost.applyRemote(pid, endsAt) end
end

-- ---------------------------------------------------------------------------
-- In-world gate visualization: one flat rectangle per checkpoint
-- ---------------------------------------------------------------------------
-- A checkpoint IS its rectangle, so that is exactly what gets drawn: the four
-- edges of the width x height surface the crossing test uses, standing upright
-- and perpendicular to the direction of travel. Nothing else - no poles, no
-- cage - so what an admin sees on track is the real trigger, and raising the
-- height visibly grows the box up the banking.
-- Colours, built once on the first draw rather than at file scope.
--
-- ColorF/ColorI are engine constructors and do not exist while this file is
-- being loaded (nor in the headless tests), so they cannot be plain constants --
-- but rebuilding six of them per gate per frame, which is what the draw loop
-- used to do, is the same waste with extra steps.
local PALETTE = nil

local function palette()
  if PALETTE then return PALETTE end
  -- Every gate colour is at FULL VALUE: the brightest form of its own hue,
  -- rather than that hue mixed with black. The hues themselves are unchanged --
  -- green next, orange route, white line, violet joker, amber pit -- because
  -- what a colour means here is learned, and a driver who has learned that
  -- green is the gate they are heading for should not have to learn it twice.
  --
  -- What moved is value and alpha. These are drawn over whatever the map
  -- happens to be, in whatever light the level has: a gate at 70% alpha in a
  -- hue two thirds of the way to black is legible against tarmac at noon and
  -- close to invisible against a bright desert, a snow map, or a low sun. There
  -- is no cost to being certain here -- the shapes are thin cylinder edges, not
  -- fills, so a fully opaque gate still shows the track through the middle of
  -- itself, which is the part that matters.
  PALETTE = {
    finish    = ColorF(1, 1, 1, 1),            -- start/finish: white
    armed     = ColorF(0.25, 1, 0.45, 1),      -- next target: green
    route     = ColorF(1, 0.45, 0.05, 0.95),   -- rest of route: orange
    -- The gate AFTER the armed one, in a driver's view. Same orange, dimmed, so
    -- the corner after this one reads without competing with the one they are
    -- actually driving at.
    routeNext = ColorF(1, 0.45, 0.05, 0.45),
    -- The gate nudge mode has hold of. Magenta because it is not a state the
    -- track itself can be in, so it collides with nothing already learned.
    nudged    = ColorF(1, 0.2, 0.9, 1),
    joker     = ColorF(0.72, 0.35, 1, 1),      -- joker route: violet
    -- Still visibly duller than the rest, because "already taken" is what it
    -- has to say at a glance -- but lifted with everything else, so it reads as
    -- a gate that is spent rather than one that failed to draw.
    jokerUsed = ColorF(0.62, 0.62, 0.7, 0.6),  -- joker already taken: dimmed
    pit       = ColorF(1, 0.78, 0.15, 1),      -- pit stalls: amber
    -- Branch gates: cyan. Far enough from the joker's violet to be told apart at
    -- a glance, and from the route's orange, which is the pair that actually
    -- matters -- a branch gate substitutes for a main one and must never look
    -- like an extra checkpoint on the same lap.
    branch      = ColorF(0.2, 0.85, 0.95, 1),
    -- A lane the editor is not currently pointed at, dimmed so the one being
    -- worked on stands out of a track carrying several.
    branchOther = ColorF(0.2, 0.6, 0.68, 0.55),
    text      = ColorF(1, 1, 1, 1),
    -- The editor gate's filled surface. Deliberately faint: it has to show the
    -- gate's extent without hiding the road it is judged against.
    fill      = ColorF(0.35, 0.65, 1, 0.16),
    textBg    = ColorI(0, 0, 0, 160),
    -- The joker label's own backing, violet rather than the neutral black every
    -- other label uses. A driver reads this one at speed to decide whether the
    -- route beside them is one they still owe, and it has to be tellable from a
    -- checkpoint label at a glance.
    jokerLabelBg = ColorI(70, 20, 110, 190),
    -- Demo derby arena. Its own entries rather than its own table: the derby
    -- module keeps its state and its logic separate, but a colour is a colour,
    -- and building these per frame is what this exists to stop.
    derbyLive    = ColorF(0.9, 0.15, 0.15, 0.9),  -- live arena edges: red
    derbySetup   = ColorF(0.9, 0.6, 0.1, 0.8),    -- setup/finished edges: amber
    derbyLabelBg = ColorI(120, 0, 0, 180),
    -- The arena WALL panels, and the pair of alphas that separate an editor
    -- arena from a live one. The editor's is a surface you can see is there; the
    -- live one is a haze you read the edge of. Anything much heavier than this
    -- while driving turns a demo arena into a room with the lights off -- the
    -- wall is a boundary marker, not scenery, and there is another car on the
    -- far side of it that still has to be visible through it.
    derbyWallEdit = ColorF(0.95, 0.55, 0.1, 0.30),
    derbyWallLive = ColorF(0.9, 0.2, 0.15, 0.12),
    -- Editor floor: the same near-transparent blue the authoring gate fill uses,
    -- for the same reason -- show the extent without hiding the ground.
    derbyFloor   = ColorF(0.35, 0.65, 1, 0.10),
  }
  return PALETTE
end

-- Per-gate geometry cache.
--
-- A gate's four corners are fixed by its placement and its dimensions, and a
-- placed gate never moves -- yet all four were recomputed, and four vec3
-- allocated, for every gate on every frame. On a twenty-gate circuit that is
-- ~100 tables a frame thrown straight at the collector, which was the single
-- largest source of GC pressure in the mod.
--
-- Keyed on the waypoint table with WEAK keys, so a gate that is deleted or
-- replaced takes its entry with it. Deliberately not stored on the waypoint
-- itself: editorSave serialises those tables verbatim, and a cache of vec3s
-- would end up in the saved route file.
local gateCache = setmetatable({}, { __mode = 'k' })

-- Rebuilt only when something the geometry depends on has actually moved. The
-- dimensions are re-derived every frame because they are two clamps and a table
-- read, and that is far cheaper than the allocation it guards against -- a
-- global width change has to be picked up without anything telling us about it.
local function gateGeometry(wp)
  local w, h = gateDims(wp)
  local g = gateCache[wp]
  if g and g.w == w and g.h == h
      and g.x == wp.x and g.y == wp.y and g.z == wp.z
      and g.hx == wp.hx and g.hy == wp.hy then
    return g
  end

  local hw, hh = w * 0.5, h * 0.5
  local rx, ry = wp.hy, -wp.hx          -- lateral (width) axis
  -- corner(sr, su): center + lateral*sr*hw + up*su*hh
  local function corner(sr, su)
    return vec3(wp.x + rx * sr * hw, wp.y + ry * sr * hw, wp.z + su * hh)
  end
  g = {
    w = w, h = h,
    x = wp.x, y = wp.y, z = wp.z, hx = wp.hx, hy = wp.hy,
    bl = corner(-1, -1), br = corner(1, -1),
    tl = corner(-1,  1), tr = corner(1,  1),
  }
  g.mid = (g.tl + g.tr) * 0.5 + vec3(0, 0, 0.8)
  -- The authoring direction arrow, cached with the corners for the same reason
  -- they are: it is fixed by the gate's placement, and rebuilding four vec3 per
  -- gate per frame is precisely the garbage this cache exists to stop.
  local ax, ay = wp.hx or 0, wp.hy or 1
  g.arrowBase = vec3(wp.x, wp.y, wp.z + 0.35)
  g.arrowTip  = vec3(wp.x + ax * 3.5, wp.y + ay * 3.5, wp.z + 0.35)
  local hx, hy = ay * 0.9, -ax * 0.9
  g.arrowL = vec3(g.arrowTip.x - ax * 1.1 + hx, g.arrowTip.y - ay * 1.1 + hy, g.arrowTip.z)
  g.arrowR = vec3(g.arrowTip.x - ax * 1.1 - hx, g.arrowTip.y - ay * 1.1 - hy, g.arrowTip.z)
  gateCache[wp] = g
  return g
end

-- A gate, drawn for whoever is looking at it.
--
-- `authoring` is the editor's view of a checkpoint and a driver's view of one
-- are different jobs, not different systems. An admin laying out a circuit needs
-- to see the trigger itself -- how wide it is, how high it reaches, which number
-- it is, which way through it counts -- across the whole track at once. A driver
-- needs to know where the next gate is and nothing else; labels and a filled box
-- across the racing line are clutter at speed, which is what the gate poles
-- replace during a session.
--
-- Both read the same checkpoint. Only the drawing differs.
local function drawGate(wp, color, label, authoring)
  local g = gateGeometry(wp)

  if authoring then
    -- The surface the crossing test actually uses, filled so its extent is
    -- unmistakable, and translucent so the road underneath stays visible --
    -- an admin is judging the gate against the track, not instead of it.
    local p = palette()
    debugDrawer:drawQuadSolid(g.bl, g.br, g.tr, g.tl, p.fill)
  end

  -- Verticals a touch thicker than the horizontals so the gate still reads as
  -- a gate at distance.
  debugDrawer:drawCylinder(g.bl, g.tl, TUNE.EDGE_RADIUS, color)
  debugDrawer:drawCylinder(g.br, g.tr, TUNE.EDGE_RADIUS, color)
  debugDrawer:drawCylinder(g.bl, g.br, TUNE.EDGE_RADIUS * 0.6, color)
  debugDrawer:drawCylinder(g.tl, g.tr, TUNE.EDGE_RADIUS * 0.6, color)

  local p = palette()
  debugDrawer:drawTextAdvanced(g.mid, String(label), p.text, true, false, p.textBg)

  if authoring then
    -- Which way through the gate counts. A rectangle alone is symmetrical and
    -- says nothing about direction, and a gate placed facing backwards is the
    -- classic way to build a circuit that cannot be completed. All four points
    -- come out of the cache above.
    debugDrawer:drawCylinder(g.arrowBase, g.arrowTip, 0.10, color)
    debugDrawer:drawCylinder(g.arrowL, g.arrowTip, 0.10, color)
    debugDrawer:drawCylinder(g.arrowR, g.arrowTip, 0.10, color)
  end
end

-- Starting grid markers: a flat slot outline on the ground with a short arrow
-- pointing the way the car will face, numbered from pole. Drawn while the
-- editor is visible and during the grid/countdown phases so drivers can see
-- where they are being placed.
local START_SLOT_LEN  = 4.6      -- meters; roughly one car long
local START_SLOT_WIDE = 2.2

local function drawStartPosition(sp, index, mine)
  local fx, fy = sp.hx, sp.hy
  local rx, ry = sp.hy, -sp.hx
  local hl, hw = START_SLOT_LEN * 0.5, START_SLOT_WIDE * 0.5
  local function corner(sf, sr)
    return vec3(sp.x + fx * sf * hl + rx * sr * hw,
                sp.y + fy * sf * hl + ry * sr * hw,
                sp.z + 0.05)
  end
  local color = mine and ColorF(0.2, 0.85, 0.35, 0.95)
    or (index == 1 and ColorF(1, 0.85, 0.2, 0.85) or ColorF(0.35, 0.65, 1, 0.75))
  local c = { corner(-1, -1), corner(-1, 1), corner(1, 1), corner(1, -1) }
  for i = 1, 4 do
    debugDrawer:drawCylinder(c[i], c[i % 4 + 1], 0.08, color)
  end
  -- Direction arrow down the middle of the slot.
  local tail = vec3(sp.x - fx * hl * 0.6, sp.y - fy * hl * 0.6, sp.z + 0.06)
  local head = vec3(sp.x + fx * hl * 0.9, sp.y + fy * hl * 0.9, sp.z + 0.06)
  debugDrawer:drawCylinder(tail, head, 0.06, color)

  debugDrawer:drawTextAdvanced(vec3(sp.x, sp.y, sp.z + 1.4),
    String('P' .. index .. (mine and ' (YOU)' or '')),
    ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 160))
end

local function drawStartPositions()
  if #startPositions == 0 or not debugDrawer then return end
  -- Editor-only furniture. These markers exist to lay out and check a grid, so
  -- they are drawn only while the editor panel is open -- they used to render
  -- for every racer, including drivers who can't edit anything. This is purely
  -- a render gate: `startPositions` itself is untouched and still drives grid
  -- placement (applyGridSlot), the slot count reported to the server, and the
  -- saved layout, for every client whether the editor is open or not.
  if not editorOpen then return end
  -- Inside the editor, the same Hide/Show Gates toggle the checkpoints use.
  if not visualize then return end
  for i, sp in ipairs(startPositions) do
    drawStartPosition(sp, i, gridSlot == i)
  end
end

-- Gate visibility (Module 3). The checkpoint boxes are drawn by every client,
-- admin or not: during an active session (countdown / qualifying / race) the
-- drawing is unconditional, because a driver who cannot see the gates cannot
-- race. The Hide/Show Gates toggle only applies outside a session, where it
-- exists to keep the editor view clean.
-- Gate labels, built once per route rather than per gate per frame.
--
-- Every label was a fresh string every frame, and the joker ones were three
-- concatenations each. The text does not depend on anything that changes between
-- frames -- only on the gate's index and the length of its route -- except for
-- the two joker suffixes, which have exactly three states, so all three are
-- precomputed and selected by lookup.
local labelCache = { routeLen = -1, jokerLen = -1, route = {}, joker = {} }

local function routeLabel(i, n)
  if labelCache.routeLen ~= n or labelCache.p2p ~= pointToPoint then
    labelCache.routeLen = n
    labelCache.p2p = pointToPoint
    labelCache.route = {}
  end
  local l = labelCache.route[i]
  if not l then
    if pointToPoint then
      -- A sprint stage has a start and a finish, not a line crossed twice.
      l = (i == n) and (i .. ' FINISH') or (i == 1 and '1 START' or ('CP ' .. i))
    else
      l = (i == n) and (i .. ' START/FINISH') or ('CP ' .. i)
    end
    labelCache.route[i] = l
  end
  return l
end

-- `state`: 'open' | 'used' | 'closed' (lap 1).
local function jokerLabel(i, n, state)
  if labelCache.jokerLen ~= n then
    labelCache.jokerLen = n
    labelCache.joker = {}
  end
  local set = labelCache.joker[i]
  if not set then
    local base = (i == n) and 'JOKER EXIT' or ('JOKER ' .. i .. '/' .. n)
    set = {
      open   = base,
      used   = base .. ' (used)',
      closed = base .. ' (lap 1: closed)',
    }
    labelCache.joker[i] = set
  end
  return set[state]
end

-- The stock BeamNG race markers (scenario/race_marker) are gone.
--
-- They were the driver's view of a gate until drawPoleGate took that over, and
-- they had been dead code since: the only sync call passed editorView = true,
-- so the module resolved nothing, built nothing and ticked an empty table every
-- frame. They could not be made bright or solid enough to see, and could not be
-- widened either, because their spacing IS the gate's width and wider poles
-- would mark a target that does not score. drawPoleGate draws the same two-pole
-- shape out of the editor's own cylinders instead.

-- The joker route's LABEL, for a driver.
--
-- Split from the pole above because the two cannot come from the same place:
-- sideColumnMarker renders no text whatsoever (every drawTextAdvanced in it is
-- commented out), so a pole can say where the joker is and never what state it
-- is in. For the joker that is the half that matters -- "used" and
-- "lap 1: closed" are the difference between a route you must take and one you
-- must not, and taking it wrong is a disqualification either way.
--
-- Deliberately the same text the editor shows, from the same jokerLabel cache,
-- so an admin and a driver are reading the identical words about the identical
-- gate. Only the label is drawn here: the pole is the shape, and repeating the
-- editor's filled rectangle over it would be the clutter the poles replaced.
-- `derbyLive` is passed in rather than read, because the derby module is scoped
-- further down this file and its state does not exist yet up here. A running
-- derby is a different game mode on the same map: whatever race track happens to
-- be loaded is not what anyone in the arena is driving, and a JOKER ROUTE label
-- hanging over a demolition derby is exactly the authoring-debris problem the
-- arena visuals were just cleaned up for.
local function drawJokerLabel(derbyLive)
  if not debugDrawer then return end
  -- The editor draws its own, for every joker gate at once and with the
  -- rectangle attached. This is the other view of the same thing.
  if editorOpen and isAdmin then return end
  if spectatorLock or derbyLive then return end
  local jn = #jokerRoute
  if not jokerEnabled or jn == 0 then return end
  local j = jokerArmed
  if j < 1 or j > jn then j = 1 end
  local wp = jokerRoute[j]
  if not wp then return end
  local active = sessionRunning() or phase == 'countdown' or phase == 'grid'
  local state = jokerTaken and 'used'
    or ((active and localLap <= 1) and 'closed' or 'open')
  local p = palette()
  debugDrawer:drawTextAdvanced(gateGeometry(wp).mid,
    String(jokerLabel(j, jn, state)), p.text, true, false, p.jokerLabelBg)
end

-- THE DRIVER'S VIEW OF THE GATE THEY ARE AIMING AT.
--
-- Reported live as "racers cannot see the default BeamNG checkpoints". The stock
-- poles cannot just be widened: their spacing IS the gate's width, so poles
-- further apart than the trigger would show a target that does not score.
--
-- Only the gate being aimed at plus the next one dimmed, never the whole
-- circuit. `derbyLive` suppresses it entirely: a checkpoint hanging over a
-- demolition derby is authoring debris.
-- TWO POLES, IN THE EDITOR'S OWN STYLE.
--
-- The stock markers are the right shape but could not be made bright enough, so
-- the shape is redrawn out of the editor's own cylinders: full opacity, this
-- mod's colours, the gate's own height, label floating between them.
--
-- TWO VERTICALS AND NOTHING ELSE. No top bar, because a hoop reads as something
-- to aim through at one height and what is marked is the LINE between the poles
-- at any height. No fill or bottom edge either: a bar at road height is a thing
-- to drive into.
local function drawPoleGate(wp, color, label)
  local g = gateGeometry(wp)
  local r = TUNE.POLE_RADIUS
  debugDrawer:drawCylinder(g.bl, g.tl, r, color)
  debugDrawer:drawCylinder(g.br, g.tr, r, color)
  if label then
    local p = palette()
    debugDrawer:drawTextAdvanced(g.mid, String(label), p.text, true, false, p.textBg)
  end
end

local function drawDriverGate(derbyLive)
  if not debugDrawer or not visualize then return end
  if derbyLive or spectatorLock then return end
  if #route == 0 then return end
  -- EVERY PHASE, not just a running session. A driver who loads a track and
  -- looks at it wants to see where the gates are as much as one racing through
  -- them, and the joker LABEL is drawn on those terms already, so gating the
  -- poles on the phase left a label floating over an invisible gate until the
  -- lights went out. The stock markers this replaced had no phase gate either.
  local p = palette()
  local n = #route
  local lane = branch.lane

  -- NO TEXT ON A RACE CHECKPOINT. The poles say where the gate is and the colour
  -- says which one is next; a driver reading "CP 3" at speed learns nothing they
  -- can act on, and it is one more thing painted across the racing line.
  --
  -- The JOKER keeps its label, and it is the only one that does, because it is
  -- the only gate whose text changes what a driver should DO -- owed, taken, or
  -- forbidden on lap 1 -- and getting it wrong is a disqualification. The editor
  -- still numbers everything: that is where the numbers are worth reading.
  local a = armedWp
  if a < 1 or a > n then a = 1 end
  local armed = branch.gateFor(a, lane)
  if armed then drawPoleGate(armed, p.armed, nil) end

  -- The one after it, dimmed, so a corner reads before it arrives. Skipped on a
  -- one-gate route, where "the next one" is the one already drawn.
  if n > 1 then
    local b = a % n + 1
    local nxt = branch.gateFor(b, lane)
    if nxt then drawPoleGate(nxt, p.routeNext or p.route, nil) end
  end

  -- The joker and the nearest pit stall, in the same style and the same colours
  -- they have always had. They used to be the stock markers' job (slots 3 and 4)
  -- and are drawn here now so a track has ONE checkpoint visual rather than two
  -- that do not match.
  if jokerEnabled and #jokerRoute > 0 then
    local j = jokerArmed
    if j < 1 or j > #jokerRoute then j = 1 end
    local wp = jokerRoute[j]
    if wp then
      local state = jokerTaken and 'used'
        or ((sessionRunning() and localLap <= 1) and 'closed' or 'open')
      drawPoleGate(wp, jokerTaken and p.jokerUsed or p.joker,
        jokerLabel(j, #jokerRoute, state))
    end
  end
  if #pitRoute > 0 then
    local _, ppos = sampledVehicle()
    local best, bestD = 1, math.huge
    if ppos then
      for i, wp in ipairs(pitRoute) do
        local dx, dy = wp.x - ppos.x, wp.y - ppos.y
        local d = dx * dx + dy * dy
        if d < bestD then best, bestD = i, d end
      end
    end
    -- Amber, and unlabelled like the rest: a pit stall is somewhere you either
    -- meant to go or did not.
    if pitRoute[best] then drawPoleGate(pitRoute[best], p.pit, nil) end
  end
end

-- Is this the gate the mouse has hold of? Only ever true for the list the
-- editor is actually on, so a slot 2 selection on the grid does not light up
-- checkpoint 2 as well.
local function nudgeSelected(list, i)
  return nudge.on and nudge.sel == i and nudge.list == list
end

local function drawGates(derbyLive)
  if not debugDrawer then return end
  -- The full circuit of numbered rectangles is the EDITOR's view and only the
  -- editor's. A driver gets drawDriverGate above: the gate they are aiming at
  -- and the one after it, which is what they can act on. `visualize` still hides
  -- both for an admin who wants the unobstructed view while placing gates.
  if not (editorOpen and isAdmin) then
    drawDriverGate(derbyLive)
    return
  end
  if not visualize then return end
  local authoring = true
  -- Still needed below: which gate is armed, and whether the joker is open,
  -- only mean anything while a session is under way.
  local active = sessionRunning() or phase == 'countdown' or phase == 'grid'
  local p = palette()

  local n = #route
  for i, wp in ipairs(route) do
    local color
    if i == n then
      color = p.finish
    elseif active and i == armedWp then
      color = p.armed
    else
      color = p.route
    end
    -- A slot some lane overrides is labelled with the fact, so an admin can see
    -- at a glance which corners are shared and which are taken two ways.
    local label = routeLabel(i, n)
    local alts = 0
    for _, b in ipairs(branch.list) do
      if branch.bySlot[b.id] and branch.bySlot[b.id][i] then alts = alts + 1 end
    end
    if alts > 0 then label = label .. ' (+' .. alts .. ')' end
    if nudgeSelected(route, i) then color = p.nudged end
    drawGate(wp, color, label, authoring)
  end

  -- Branch gates: cyan, so they never read as part of the main lap, and labelled
  -- with the SLOT they override rather than their position in the branch's own
  -- list -- a branch gate is not a checkpoint of its own, it is the other way of
  -- taking one that already exists, and the number has to say so.
  for _, b in ipairs(branch.list) do
    local editing = (b.id == branch.editId)
    for gi, g in ipairs(b.gates) do
      local slot = tonumber(g.slot) or 0
      local color = p.branch or p.joker
      if active and branch.lane == b.id and slot == armedWp then
        color = p.armed
      elseif not editing then
        color = p.branchOther or p.jokerUsed
      end
      if nudgeSelected(b.gates, gi) then color = p.nudged end
      drawGate(g, color, 'CP ' .. slot .. ': ' .. (b.name or b.id), authoring)
    end
  end

  -- Pit stalls. Amber, and labelled as stalls rather than numbered gates: they
  -- are not part of the checkpoint sequence and must not look as though they
  -- are. Editor only -- a driver gets a pole on the nearest one instead.
  for i, wp in ipairs(pitRoute) do
    drawGate(wp, nudgeSelected(pitRoute, i) and p.nudged or p.pit, 'PIT ' .. i, authoring)
  end

  -- Joker route: violet, so it never reads as part of the main lap. The next
  -- joker gate lights up green like the main route, and the whole set greys out
  -- once the joker has been used (or while it is still forbidden on lap 1).
  local jn = #jokerRoute
  local state = jokerTaken and 'used'
    or ((active and localLap <= 1) and 'closed' or 'open')
  for i, wp in ipairs(jokerRoute) do
    local color
    if jokerTaken then
      color = p.jokerUsed
    elseif active and jokerEnabled and i == jokerArmed then
      color = p.armed
    else
      color = p.joker
    end
    if nudgeSelected(jokerRoute, i) then color = p.nudged end
    drawGate(wp, color, jokerLabel(i, jn, state), authoring)
  end
end

-- Forward declarations for the eight names the scoped derby block below has
-- to expose: the dispatch table routes to its four handlers, onUpdate drives
-- its two per-frame functions, and the idle purge clears its state. Everything
-- else it owns stays inside the block and hands its register back at `end`.
local derbyState, derbyClearWarnings, derbyUpdate, derbyDrawBoundary
local onDerbyUpdate, onDerbyGridAssign, onDerbyCountdown, onDerbyLayoutList
do
-- ===========================================================================
-- DEMO DERBY (isolated module)
-- ===========================================================================
-- Fully independent of the circuit racing logic above: separate state, its
-- own server events (RM_Derby*), its own guihooks channels and its own
-- update/draw functions. It never touches `route`, `phase`, `armedWp` or any
-- other racing variable, so a derby can never disturb qualifying/racing.
--
-- Client responsibilities (only the client has physics access):
--   * Place boundary markers at the local vehicle's position (admin action;
--     the server owns the ordered marker list and broadcasts it to everyone).
--   * Ray-casting point-in-polygon test of the local vehicle against the
--     arena polygon every frame; leaving it starts the out-of-bounds
--     countdown and a flashing full-screen warning. Re-entering clears it;
--     reaching zero reports RM_DerbyDisqualified.
--   * Track the local vehicle's speed; sitting below the jiggle threshold
--     starts the demolished countdown ("keep moving or you're out");
--     reaching zero reports RM_DerbyDemolished.
--   * Draw the boundary poles + perimeter rope in the 3D world.

local DERBY_STOP_SPEED    = 0.7   -- m/s; below this the car counts as stopped
                                  -- (generous enough to swallow physics jiggle)
-- Seconds after GO before the stopped-vehicle check arms. This used to exist
-- because there was no start procedure at all: cars sat parked waiting for
-- someone to say go, and would have been on the demolished clock immediately.
-- Form-up and the countdown removed that reason, but the timer is kept for the
-- one that is left -- a car released at GO takes a moment to actually move, and
-- nobody should be eliminated for reaction time. Deliberately unchanged rather
-- than retuned: it is a gameplay value, and shortening it is a balance call for
-- an admin to ask for, not a side effect of adding a countdown.
local DERBY_START_GRACE   = 5
local DERBY_POLE_HEIGHT   = 6     -- fallback wall height, until the server says
local DERBY_POLE_RADIUS   = 0.2

-- One table rather than a dozen file-scope locals, for the same reason the
-- tunables at the top of the file are one table: Lua caps a function at 200
-- locals, the top level of this file is a function, and going over does not warn
-- -- the file fails to compile and the mod is simply not there. This block was
-- the largest cohesive group left.
derbyState = {
  phase     = 'idle',   -- idle | running | finished (mirrored from server)
  -- The derby is decided and running out its cool-down. The cars are stood down
  -- for it -- see derbyStandDown.
  over      = false,
  boundary  = {},       -- ordered polygon vertices { x, y, z }
  -- Which editor authored the polygon above, mirrored from the server. Gameplay
  -- reads `boundary` in both cases and nothing else -- these only decide what
  -- the ARENA IS DRAWN LIKE, and which controls the admin panel offers.
  boundaryMode = 'polygon',  -- polygon | rect
  shape     = nil,      -- { cx, cy, cz, halfW, halfL, rot } while mode is 'rect'
  wallHeight = DERBY_POLE_HEIGHT,
  -- True while an admin has the Derby Editor sub-tab open. The editor's arena
  -- and a driver's arena are different drawings of the same boundary, exactly
  -- the way an authoring checkpoint and a race one are (see drawGate).
  editorOpen = false,
  oobLimit  = 5,        -- seconds (mirrored from server config)
  demoLimit = 10,
  starts    = {},       -- derby starting grid { x, y, z, hx, hy } (mirrored)
  slot      = nil,      -- start slot the server assigned us for this derby
  visualize = true,     -- Hide/Show toggle for the boundary + grid visuals
  oobLeft   = nil,      -- active out-of-bounds countdown, nil = inside
  demoLeft  = nil,      -- active stopped countdown, nil = moving
  -- true once we reported our own elimination (or we're a spectator, not a
  -- participant)
  out       = false,
  runTime   = 0,        -- local seconds since this derby went running
  warnShown = false,    -- whether the UI currently shows a warning
}

-- Module 1 asks this before policing the derby reset allowance: only a live
-- derby with this driver still in it spends (or blocks) derby resets.
derbyResetsActive = function ()
  return derbyState.phase == 'running' and not derbyState.out
end

-- STAND THE CAR DOWN AT THE END OF A DERBY.
--
-- The result is settled and the arena stays up for a few seconds so it can be
-- seen; a wreck still being driven into people for those seconds is not a
-- cool-down, it is extra time nobody was given.
--
-- Freezing ALONE is not enough, and that is the whole of this function. The grid
-- hold uses the same freeze and gets away with it because a car on the grid is
-- stationary with nothing pressed. A derby ends with somebody's foot flat to the
-- floor, and a freeze applied over that captures the throttle: the engine sits
-- screaming against a locked car and lets go the instant the freeze lifts. So
-- the inputs are neutralised FIRST -- throttle off, brakes on -- and the freeze
-- goes over the top of a car that is already trying to stop.
--
-- Controls are deliberately left ENABLED. There is nothing left to win, the car
-- cannot move, and taking someone's steering away as a prize for having been in
-- a derby is worse than pointless. What IS taken away is the reset: a reset would
-- reload the vehicle out from under the freeze and hand them a driveable car in
-- the middle of a settled result.
spectate.derbyStoodDown = function () return derbyState.stoodDown == true end

local function derbyStandDown(down)
  if down == derbyState.stoodDown then return end
  derbyState.stoodDown = down
  local veh = playerVehicle()
  if down then
    if veh then
      -- Order matters: let go of the throttle before anything locks.
      pcall(function ()
        veh:queueLuaCommand('input.event("throttle", 0, 1)')
        veh:queueLuaCommand('input.event("brake", 1, 1)')
        veh:queueLuaCommand('input.event("parkingbrake", 1, 1)')
      end)
    end
    setLocalVehicleFrozen(true, 'derby')
    pushNotice('derby', 'Derby over, hold still')
  else
    setLocalVehicleFrozen(false, 'derby')
    if veh then
      pcall(function ()
        veh:queueLuaCommand('input.event("brake", 0, 1)')
        veh:queueLuaCommand('input.event("parkingbrake", 0, 1)')
      end)
    end
  end
end

local function derbyPushWarning()
  guihooks.trigger('RaceManagerDerbyWarning', {
    oob     = derbyState.oobLeft,
    stopped = derbyState.demoLeft,
  })
  derbyState.warnShown = (derbyState.oobLeft ~= nil) or (derbyState.demoLeft ~= nil)
end

derbyClearWarnings = function ()
  derbyState.oobLeft, derbyState.demoLeft = nil, nil
  if derbyState.warnShown then derbyPushWarning() end
end

-- Standard ray-casting point-in-polygon test on the XY plane (the arena is a
-- 2D perimeter; height is ignored so jumps/ramps don't false-positive).
local function derbyPointInPolygon(px, py, poly)
  local inside = false
  local n = #poly
  local j = n
  for i = 1, n do
    local xi, yi = poly[i].x, poly[i].y
    local xj, yj = poly[j].x, poly[j].y
    if ((yi > py) ~= (yj > py))
        and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
      inside = not inside
    end
    j = i
  end
  return inside
end

-- Local pid, so we can tell whether the server already eliminated us.
local derbyLocalServerId = localServerId

derbyUpdate = function (dt)
  if derbyState.phase ~= 'running' or derbyState.out then
    derbyClearWarnings()
    return
  end
  derbyState.runTime = derbyState.runTime + dt
  local veh = playerVehicle()
  if not veh then
    derbyClearWarnings()
    return
  end
  local changed = false

  -- Out-of-bounds check (needs a real polygon: at least 3 markers).
  if #derbyState.boundary >= 3 then
    local pos = veh:getPosition()
    if derbyPointInPolygon(pos.x, pos.y, derbyState.boundary) then
      if derbyState.oobLeft then derbyState.oobLeft = nil; changed = true end
    else
      if not derbyState.oobLeft then
        derbyState.oobLeft = derbyState.oobLimit
      else
        derbyState.oobLeft = derbyState.oobLeft - dt
      end
      changed = true
      if derbyState.oobLeft <= 0 then
        derbyState.out = true
        derbyClearWarnings()
        if inMultiplayer() then TriggerServerEvent('RM_DerbyDisqualified', '') end
        log('I', 'raceManager', 'Derby: out-of-bounds timer expired, reported disqualification')
        return
      end
    end
  end

  -- Stopped-vehicle ("demolished") check. Held off for the start grace
  -- period so a grid of cars parked for the start isn't counting down
  -- before anyone has had a chance to move.
  local vel = veh:getVelocity()
  local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
  if speed > DERBY_STOP_SPEED or derbyState.runTime < DERBY_START_GRACE then
    if derbyState.demoLeft then derbyState.demoLeft = nil; changed = true end
  else
    if not derbyState.demoLeft then
      derbyState.demoLeft = derbyState.demoLimit
    else
      derbyState.demoLeft = derbyState.demoLeft - dt
    end
    changed = true
    if derbyState.demoLeft <= 0 then
      derbyState.out = true
      derbyClearWarnings()
      if inMultiplayer() then TriggerServerEvent('RM_DerbyDemolished', '') end
      log('I', 'raceManager', 'Derby: stopped timer expired, reported demolition')
      return
    end
  end

  if changed then derbyPushWarning() end
end

-- Arena walls. The perimeter is drawn as a closed run of vertical panels -- one
-- quad per edge, standing from the boundary up to the wall height -- rather than
-- the poles and rope it used to be. The same builder serves both arena kinds,
-- because by the time it runs a rectangle is just a four-vertex polygon.
--
-- Two things about the geometry are worth knowing before changing it:
--
--   * A rectangle's corners all sit at the CENTRE's z (see the server's
--     derbyShapeToBoundary), so on sloped ground the ring is a flat plane cut
--     through the hill. The walls therefore start BELOW the boundary z and run
--     up from there: dropping the base by a skirt means the panel intersects the
--     terrain on the uphill side instead of hovering over it, and the arena
--     still reads as enclosed. A hand-placed polygon takes its z from the car
--     that placed each marker, so it follows the ground already -- the skirt
--     costs it nothing.
--   * Every panel is emitted TWICE, with the winding reversed the second time.
--     Drivers stand inside this box looking out, which is the one view a
--     single-sided quad would be invisible from.
local DERBY_WALL_SKIRT = 1.5   -- metres the wall drops below the boundary plane

local function derbyBuildWalls(boundary, height)
  local n = #boundary
  local walls = {}
  if n < 2 then return walls end
  for i = 1, n do
    local a = boundary[i]
    local b = boundary[i % n + 1]
    -- Two markers is a line, not a ring: draw the single panel once rather than
    -- the same panel twice back to back.
    if not (n == 2 and i == 2) then
      local a0 = vec3(a.x, a.y, a.z - DERBY_WALL_SKIRT)
      local b0 = vec3(b.x, b.y, b.z - DERBY_WALL_SKIRT)
      local a1 = vec3(a.x, a.y, a.z + height)
      local b1 = vec3(b.x, b.y, b.z + height)
      walls[#walls + 1] = { bl = a0, br = b0, tr = b1, tl = a1 }
    end
  end
  return walls
end

-- Boundary visualization. Mirrors the race editor's Hide/Show Gates rule:
-- unconditional while the derby runs (drivers must see the arena), the toggle
-- only applies outside of one.
derbyDrawBoundary = function ()
  if not debugDrawer then return end
  if derbyState.phase ~= 'running' and not derbyState.visualize then return end

  -- Who is looking. An admin with the Derby Editor open is judging the arena and
  -- needs its exact limits, its corners and its numbers; everyone else is
  -- driving in it and needs to know where the edge is and nothing more. A derby
  -- from form-up onward is always the driving view, even for that admin -- by
  -- then cars are standing on the grid and the panel is not what anyone is
  -- looking at.
  local authoring = derbyState.editorOpen and isAdmin
    and derbyState.phase ~= 'running' and derbyState.phase ~= 'countdown'
    and derbyState.phase ~= 'forming'

  -- Derby starting grid slots, numbered from slot 1. Authoring furniture: they
  -- exist to lay the slots out and check spacing, so they belong to an admin
  -- with the editor open -- the same rule drawStartPositions applies to the race
  -- grid, which this used to be the exception to. Every driver on the server got
  -- a field of numbered outlines whether or not a derby was anywhere near
  -- starting, and they stayed up through form-up and the countdown.
  --
  -- The one case that is not authoring: a driver being PUT on a slot. While the
  -- field forms up, your own slot is drawn for you and nobody else's is, so you
  -- can see where you have been placed without the other nineteen outlines.
  -- Once the derby runs, nothing here is drawn at all -- every car has left its
  -- slot by then. The boundary below is NOT hidden: leaving it is what
  -- eliminates you, so a driver has to be able to see it.
  if derbyState.phase ~= 'running' then
    if authoring then
      for i, sp in ipairs(derbyState.starts) do
        drawStartPosition(sp, i, derbyState.slot == i)
      end
    elseif derbyState.slot and derbyState.starts[derbyState.slot] then
      drawStartPosition(derbyState.starts[derbyState.slot], derbyState.slot, true)
    end
  end
  local boundary = derbyState.boundary
  local n = #boundary
  if n == 0 then return end

  -- Same story as the race gates: an arena perimeter is fixed geometry redrawn
  -- every frame, and it was rebuilding all of it each time.
  --
  -- The cache lives on derbyState rather than in a new file-scope local, because
  -- this file is close enough to Lua's 200-local ceiling that a new one there is
  -- a cost of its own. It is keyed on the boundary table itself: onDerbyUpdate
  -- keeps the existing table when the markers have not moved, so identity is
  -- enough to say "nothing about this arena has changed". Wall height and the
  -- authoring flag are part of the key too -- both change the geometry without
  -- the boundary moving, and a cache that missed them would draw a resized
  -- arena at its old height, or keep the editor's floor through a live derby.
  local height = derbyState.wallHeight or DERBY_POLE_HEIGHT
  local cache = derbyState.draw
  if not cache or cache.src ~= boundary or cache.height ~= height
      or cache.authoring ~= authoring then
    cache = { src = boundary, height = height, authoring = authoring }
    cache.walls = derbyBuildWalls(boundary, height)
    -- Corner posts, the full height of the wall. Both views draw them -- they
    -- are what stops a translucent wall from disappearing against a bright sky
    -- -- but the driving view draws them thinner, so they mark the corners
    -- without becoming scenery.
    cache.posts = {}
    for i, m in ipairs(boundary) do
      local base = vec3(m.x, m.y, m.z - DERBY_WALL_SKIRT)
      cache.posts[i] = { a = base, b = vec3(m.x, m.y, m.z + height) }
    end
    -- A rail along the top of the wall, and one along the ground. The ground
    -- rail is the line a driver actually judges the edge by at speed.
    cache.topRail, cache.baseRail = {}, {}
    if n > 1 then
      for i = 1, n do
        local a, b = boundary[i], boundary[i % n + 1]
        if not (n == 2 and i == 2) then
          cache.topRail[#cache.topRail + 1] = {
            a = vec3(a.x, a.y, a.z + height), b = vec3(b.x, b.y, b.z + height) }
          cache.baseRail[#cache.baseRail + 1] = {
            a = vec3(a.x, a.y, a.z + 0.05), b = vec3(b.x, b.y, b.z + 0.05) }
        end
      end
    end
    if authoring then
      -- Editor-only furniture, built once with everything else: a numbered label
      -- over each corner, the arena's headline label, and -- for a rectangle --
      -- the centre crosshair and a readout of what the sliders currently say.
      local first = boundary[1]
      cache.labelAt = vec3(first.x, first.y, first.z + height + 0.8)
      local s = derbyState.shape
      if derbyState.boundaryMode == 'rect' and s then
        cache.label = string.format('DERBY ARENA: %.0f x %.0f m', s.halfW * 2, s.halfL * 2)
        -- A rectangle is convex and has exactly four corners, so its floor is
        -- one quad with no triangulation to get wrong.
        if n == 4 then
          cache.floor = {}
          for i, m in ipairs(boundary) do
            cache.floor[i] = vec3(m.x, m.y, m.z + 0.06)
          end
        end
        cache.centre = {
          at = vec3(s.cx, s.cy, s.cz),
          -- A cross through the centre, turned with the rectangle, so the
          -- rotation slider has something to visibly turn.
          armA = { a = vec3(s.cx - math.cos(s.rot) * 3, s.cy - math.sin(s.rot) * 3, s.cz + 0.1),
                   b = vec3(s.cx + math.cos(s.rot) * 3, s.cy + math.sin(s.rot) * 3, s.cz + 0.1) },
          armB = { a = vec3(s.cx + math.sin(s.rot) * 3, s.cy - math.cos(s.rot) * 3, s.cz + 0.1),
                   b = vec3(s.cx - math.sin(s.rot) * 3, s.cy + math.cos(s.rot) * 3, s.cz + 0.1) },
          label = string.format('CENTRE: %.0f deg', math.deg(s.rot)),
          labelAt = vec3(s.cx, s.cy, s.cz + 1.6),
        }
      else
        cache.label = 'DERBY BOUNDARY (' .. n .. ')'
      end
      cache.cornerLabels = {}
      for i, m in ipairs(boundary) do
        cache.cornerLabels[i] = { at = vec3(m.x, m.y, m.z + height + 0.2), text = 'M' .. i }
      end
    end
    derbyState.draw = cache
  end

  local p = palette()
  local edge = (derbyState.phase == 'running') and p.derbyLive or p.derbySetup
  local face = authoring and p.derbyWallEdit or p.derbyWallLive

  -- The walls themselves. Twice each, winding reversed, so the panel is there
  -- from inside the arena as well as outside it.
  for _, w in ipairs(cache.walls) do
    debugDrawer:drawQuadSolid(w.bl, w.br, w.tr, w.tl, face)
    debugDrawer:drawQuadSolid(w.tl, w.tr, w.br, w.bl, face)
  end

  if authoring then
    -- The enclosed area, filled, so the extent is unmistakable. Editor-only: a
    -- translucent floor over the whole playing surface is the last thing a
    -- driver needs.
    --
    -- Rectangles only, and deliberately so. Filling an arbitrary polygon means
    -- triangulating it, and the cheap way (a fan from vertex 1) paints OUTSIDE
    -- the arena the moment the shape is concave -- which a hand-driven demo
    -- arena very often is. A floor that lies about the limits is worse than no
    -- floor, and the walls, posts and rails already state them exactly.
    if cache.floor then
      debugDrawer:drawQuadSolid(cache.floor[1], cache.floor[2],
        cache.floor[3], cache.floor[4], p.derbyFloor)
    end
    for _, post in ipairs(cache.posts) do
      debugDrawer:drawCylinder(post.a, post.b, DERBY_POLE_RADIUS, edge)
    end
    for _, r in ipairs(cache.topRail) do
      debugDrawer:drawCylinder(r.a, r.b, DERBY_POLE_RADIUS * 0.5, edge)
    end
    for _, r in ipairs(cache.baseRail) do
      debugDrawer:drawCylinder(r.a, r.b, DERBY_POLE_RADIUS * 0.5, edge)
    end
    debugDrawer:drawTextAdvanced(cache.labelAt, String(cache.label),
      p.text, true, false, p.derbyLabelBg)
    for _, cl in ipairs(cache.cornerLabels) do
      debugDrawer:drawTextAdvanced(cl.at, String(cl.text), p.text, true, false, p.derbyLabelBg)
    end
    if cache.centre then
      debugDrawer:drawCylinder(cache.centre.armA.a, cache.centre.armA.b, 0.12, edge)
      debugDrawer:drawCylinder(cache.centre.armB.a, cache.centre.armB.b, 0.12, edge)
      debugDrawer:drawTextAdvanced(cache.centre.labelAt, String(cache.centre.label),
        p.text, true, false, p.derbyLabelBg)
    end
  else
    -- Driving view: no labels, no corner numbers, no floor. Just enough edge to
    -- read the wall against the sky and the ground.
    for _, r in ipairs(cache.baseRail) do
      debugDrawer:drawCylinder(r.a, r.b, DERBY_POLE_RADIUS * 0.4, edge)
    end
    for _, post in ipairs(cache.posts) do
      debugDrawer:drawCylinder(post.a, post.b, DERBY_POLE_RADIUS * 0.5, edge)
    end
  end
end

-- --- Derby UI commands (called by the UI app) ------------------------------

function M.derbyAddMarker()
  local veh = playerVehicle()
  if not veh then
    log('W', 'raceManager', 'Derby: no player vehicle, cannot place boundary marker')
    return
  end
  if not inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local pos = veh:getPosition()
  TriggerServerEvent('RM_DerbyAddMarker', jsonEncode({ x = pos.x, y = pos.y, z = pos.z }))
end

function M.derbyClearBoundary()
  if inMultiplayer() then TriggerServerEvent('RM_DerbyClearBoundary', '') end
end

-- --- Rectangle arena (the other boundary editor) ---------------------------
-- Switch between driving the perimeter marker by marker and pulling a rectangle
-- out from a centre. Neither loses the other's work: see the server handler.
-- The vehicle position rides along as the centre to use when there is no
-- existing arena to fit a rectangle around.
function M.derbySetBoundaryMode(mode)
  if not inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  mode = (mode == 'rect') and 'rect' or 'polygon'
  local payload = { mode = mode }
  local veh = playerVehicle()
  if veh then
    local pos = veh:getPosition()
    payload.cx, payload.cy, payload.cz = pos.x, pos.y, pos.z
  elseif mode == 'rect' and #derbyState.boundary < 3 then
    guihooks.trigger('RaceManagerEditorMsg', {
      msg = 'Get in a vehicle first: the rectangle needs a centre' })
    return
  end
  TriggerServerEvent('RM_DerbySetBoundaryMode', jsonEncode(payload))
end

-- Re-centre the rectangle on the car. The derby's "Move Here", and the same
-- gesture every other placement in this mod uses.
function M.derbySetShapeCenter()
  if not inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local veh = playerVehicle()
  if not veh then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  local pos = veh:getPosition()
  TriggerServerEvent('RM_DerbySetShape',
    jsonEncode({ cx = pos.x, cy = pos.y, cz = pos.z }))
end

-- Size, turn and wall height, straight off the sliders. Every argument is
-- optional: the server keeps whatever this payload leaves out, so a slider only
-- ever sends the thing it moved. Width and length arrive as the FULL span an
-- admin reads off the panel; the server stores half-extents.
function M.derbySetShape(width, length, rotDeg, wallHeight)
  if not inMultiplayer() then return end
  local payload = {}
  local w, l = tonumber(width), tonumber(length)
  local r, h = tonumber(rotDeg), tonumber(wallHeight)
  if w then payload.halfW = w * 0.5 end
  if l then payload.halfL = l * 0.5 end
  if r then payload.rot = math.rad(r) end
  if h then payload.wallHeight = h end
  if next(payload) == nil then return end
  TriggerServerEvent('RM_DerbySetShape', jsonEncode(payload))
end

function M.derbySetConfig(oobLimit, demoLimit, maxResets)
  if inMultiplayer() then
    TriggerServerEvent('RM_DerbySetConfig', jsonEncode({
      oobLimit = tonumber(oobLimit), demoLimit = tonumber(demoLimit),
      maxResets = tonumber(maxResets),
    }))
  end
end

-- --- Derby starting grid (admin) -------------------------------------------
-- Same workflow as the race grid: drive to each slot, press the button, slot 1
-- first. The server owns the list and hands each participant a slot number at
-- Start Derby; this client puts its own car there.
function M.derbyAddStartPosition()
  if not inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local place = vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  TriggerServerEvent('RM_DerbyAddStart', jsonEncode(place))
end

function M.derbyClearStartPositions()
  if inMultiplayer() then TriggerServerEvent('RM_DerbyClearStarts', '') end
end

-- --- Derby marker / start slot editing -------------------------------------
-- The derby's answer to moveStartPosition / removeStartPosition / preview,
-- with one difference that decides the whole shape of these: the race grid is
-- this client's own list, while the SERVER owns the arena. So a move sends the
-- index plus the placement the car is standing on and waits for the broadcast
-- to come back; only the preview is answered locally, because standing your own
-- car somewhere is nobody else's business.
function M.derbyMoveMarker(index)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if not inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local veh = playerVehicle()
  if not veh then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  local pos = veh:getPosition()
  TriggerServerEvent('RM_DerbyMoveMarker',
    jsonEncode({ index = index, x = pos.x, y = pos.y, z = pos.z }))
end

function M.derbyRemoveMarker(index)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_DerbyRemoveMarker', jsonEncode({ index = index }))
  end
end

function M.derbyMoveStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if not inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local place = vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  place.index = index
  TriggerServerEvent('RM_DerbyMoveStart', jsonEncode(place))
end

function M.derbyRemoveStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_DerbyRemoveStart', jsonEncode({ index = index }))
  end
end

-- Preview, the race editor's "Go": stand the car on a placed entry so the
-- creator can see where it actually is. Purely local and never freezes -- this
-- is editor convenience, exactly like previewStartPosition.
function M.derbyPreviewStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  local sp = derbyState.starts[index]
  if not sp then return end
  if not placeOnStartPosition(sp) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Could not move the vehicle' })
  end
end

-- A boundary marker is a position with no facing of its own, so the car keeps
-- the heading it already has rather than being spun to an arbitrary one.
function M.derbyPreviewMarker(index)
  index = math.floor(tonumber(index) or 0)
  local m = derbyState.boundary[index]
  if not m then return end
  local place = vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  if not placeOnStartPosition({ x = m.x, y = m.y, z = m.z, hx = place.hx, hy = place.hy }) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Could not move the vehicle' })
  end
end

-- The Derby Editor sub-tab opening and closing. Client-local and purely a
-- render gate, exactly like setEditorOpen for the race checkpoints: it decides
-- whether this client draws the arena's authoring view or its driving view, and
-- touches no derby state the server owns.
function M.setDerbyEditorOpen(open)
  derbyState.editorOpen = open == true
end

-- Hide/Show the derby boundary + start grid visuals (client-local, like the
-- race editor's gate toggle). Pushed to the UI so the button label follows.
function M.derbyToggleVisualize()
  derbyState.visualize = not derbyState.visualize
  guihooks.trigger('RaceManagerDerbyVisual', { visualize = derbyState.visualize })
end

-- Who takes part in the next derby: everyone connected, or only drivers who
-- pressed Join Race. Server-owned like every other derby rule.
function M.derbySetEntryMode(mode)
  if not inMultiplayer() then return end
  TriggerServerEvent('RM_DerbySetEntryMode', jsonEncode({
    mode = (mode == 'join') and 'join' or 'all',
  }))
end

-- Form up: stand every participant on their slot and hold them there, ready
-- for the countdown. The derby equivalent of Generate Grid.
function M.derbyFormUp()
  if inMultiplayer() then TriggerServerEvent('RM_DerbyFormUp', '') end
end

function M.derbyStart()
  if inMultiplayer() then TriggerServerEvent('RM_DerbyStart', '') end
end

function M.derbyEnd()
  if inMultiplayer() then TriggerServerEvent('RM_DerbyEnd', '') end
end

function M.derbyRequestState()
  if inMultiplayer() then
    TriggerServerEvent('RM_DerbyRequestState', '')
    TriggerServerEvent('RM_DerbyRequestLayouts', '')
  else
    guihooks.trigger('RaceManagerDerby', {
      derbyPhase = 'idle', oobLimit = derbyState.oobLimit, demoLimit = derbyState.demoLimit,
      maxResets = derbyMaxResets, derbyTime = 0, boundary = {},
      boundaryMode = 'polygon', shape = nil, wallHeight = derbyState.wallHeight,
      startPositions = {}, players = {},
    })
  end
end

-- --- Derby arena layouts (server-side, persistent, per-map) ----------------
-- The same save/load workflow the race layouts use, kept inside the derby
-- module: an arena is its boundary polygon plus the two timers, stored on the
-- server under a name and broadcast to every client when loaded.
function M.derbySaveLayout(name)
  name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Enter an arena name first' })
    return
  end
  if #derbyState.boundary < 3 then
    guihooks.trigger('RaceManagerEditorMsg', {
      msg = 'Place at least 3 boundary markers before saving an arena' })
    return
  end
  if not inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Arena layouts need a BeamMP server' })
    return
  end
  local markers = {}
  for i, m in ipairs(derbyState.boundary) do
    local x, y, z = tonumber(m.x), tonumber(m.y), tonumber(m.z)
    if not (x and y and z) then
      guihooks.trigger('RaceManagerEditorMsg', {
        msg = 'Save failed: boundary marker ' .. i .. ' is invalid' })
      return
    end
    markers[i] = { x = x, y = y, z = z }
  end
  -- The derby starting grid travels with the arena, exactly the way the race
  -- grid travels with a track layout.
  local starts = nil
  if #derbyState.starts > 0 then
    starts = {}
    for i, sp in ipairs(derbyState.starts) do
      starts[i] = { x = sp.x, y = sp.y, z = sp.z, hx = sp.hx, hy = sp.hy }
    end
  end
  -- A rectangle is saved as its shape AND the polygon it produced, so the arena
  -- comes back editable by slider rather than as four loose markers -- and stays
  -- loadable by anything that only knows about the polygon.
  TriggerServerEvent('RM_DerbySaveLayout', jsonEncode({
    name = name, boundary = markers,
    boundaryMode = derbyState.boundaryMode,
    shape = derbyState.shape,
    wallHeight = derbyState.wallHeight,
    oobLimit = derbyState.oobLimit, demoLimit = derbyState.demoLimit,
    maxResets = derbyMaxResets, startPositions = starts,
  }))
end

function M.derbyRequestLayouts()
  if inMultiplayer() then TriggerServerEvent('RM_DerbyRequestLayouts', '') end
end

function M.derbyLoadLayout(name)
  name = tostring(name or '')
  if name == '' then return end
  if not inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Arena layouts need a BeamMP server' })
    return
  end
  TriggerServerEvent('RM_DerbyLoadLayout', jsonEncode({ name = name }))
end

function M.derbyDeleteLayout(name)
  name = tostring(name or '')
  if name == '' then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_DerbyDeleteLayout', jsonEncode({ name = name }))
  end
end

-- --- Derby server -> client ------------------------------------------------

onDerbyUpdate = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  if not fromCurrentServer(data) then return end

  local newPhase = data.derbyPhase or 'idle'
  -- Decided and running out the cool-down. Stood down while that is true, and
  -- released the moment the derby is no longer running -- so a car is never left
  -- frozen by a derby that has ended, whatever order the broadcasts arrive in.
  derbyState.over = data.derbyOver == true
  derbyStandDown(derbyState.over and newPhase == 'running')
  if newPhase == 'running' and derbyState.phase ~= 'running' then
    -- Fresh derby: re-arm local detection from a clean slate. The derby reset
    -- allowance is per-derby, so it starts over too.
    derbyState.out = false
    derbyState.runTime = 0
    derbyResetsUsed = 0
    derbyClearWarnings()
  elseif newPhase ~= 'running' then
    if derbyState.phase == 'running' then derbyState.slot = nil end
    derbyClearWarnings()
  end
  -- A derby that ends or is reset while cars are still held on the form-up grid
  -- has to let them go. Only ever releases a hold this module imposed.
  if newPhase == 'idle' or newPhase == 'finished' then
    releaseGridHold('derby')
  end
  derbyState.phase = newPhase

  derbyState.oobLimit  = tonumber(data.oobLimit)  or derbyState.oobLimit
  derbyState.demoLimit = tonumber(data.demoLimit) or derbyState.demoLimit
  if type(data.maxResets) == 'number' then
    derbyMaxResets = math.floor(data.maxResets)
  end

  local boundary = {}
  if type(data.boundary) == 'table' then
    for i, m in ipairs(data.boundary) do
      local x, y, z = tonumber(m.x), tonumber(m.y), tonumber(m.z)
      if x and y and z then boundary[#boundary + 1] = { x = x, y = y, z = z } end
    end
  end
  -- Keep the table we already have when the markers have not actually moved.
  -- Every broadcast used to install a brand new one -- once a second while a
  -- derby runs, and on every marker drop while an admin builds an arena -- which
  -- is garbage on its own, and would also throw away the draw cache below on
  -- every push for an arena that had not changed at all.
  --
  -- Swapping the table IS the invalidation, and deliberately the only one: the
  -- cache is keyed on this table's identity, so a new arena can never be drawn
  -- with an old one's geometry, and there is no second rule here to forget to
  -- apply somewhere else.
  local same = #boundary == #derbyState.boundary
  if same then
    for i, m in ipairs(boundary) do
      local o = derbyState.boundary[i]
      if o.x ~= m.x or o.y ~= m.y or o.z ~= m.z then same = false; break end
    end
  end
  if not same then derbyState.boundary = boundary end

  -- Which editor authored that polygon, and how tall to draw its walls. Both are
  -- server-owned so every client draws the same arena; neither affects the
  -- out-of-bounds test, which reads `boundary` and nothing else.
  derbyState.boundaryMode = (data.boundaryMode == 'rect') and 'rect' or 'polygon'
  if type(data.wallHeight) == 'number' then derbyState.wallHeight = data.wallHeight end
  if derbyState.boundaryMode == 'rect' and type(data.shape) == 'table' then
    local s = data.shape
    local cx, cy, cz = tonumber(s.cx), tonumber(s.cy), tonumber(s.cz)
    if cx and cy and cz then
      derbyState.shape = {
        cx = cx, cy = cy, cz = cz,
        halfW = tonumber(s.halfW) or 0, halfL = tonumber(s.halfL) or 0,
        rot   = tonumber(s.rot) or 0,
      }
    end
  else
    derbyState.shape = nil
  end

  -- Derby starting grid (a placement + a facing per slot, like the race grid).
  local starts = {}
  if type(data.startPositions) == 'table' then
    for _, sp in ipairs(data.startPositions) do
      local x, y, z = tonumber(sp.x), tonumber(sp.y), tonumber(sp.z)
      if x and y and z then
        starts[#starts + 1] = { x = x, y = y, z = z,
          hx = tonumber(sp.hx) or 0, hy = tonumber(sp.hy) or 1 }
      end
    end
  end
  derbyState.starts = starts

  -- If the server already knows we're out (e.g. reconnect race), stop
  -- policing. Same if we're not in the participant list at all: we joined
  -- after Start Derby and are a spectator - a parked spectator must not get
  -- OUT OF BOUNDS / VEHICLE STOPPED overlays for a derby they aren't in.
  local myId = derbyLocalServerId()
  if myId and type(data.players) == 'table' then
    local mine = nil
    for _, p in ipairs(data.players) do
      if tonumber(p.id) == myId then mine = p; break end
    end
    if mine then
      if mine.status ~= 'alive' then derbyState.out = true end
    elseif derbyState.phase == 'running' then
      derbyState.out = true
    end
  end

  guihooks.trigger('RaceManagerDerby', data)
end

-- Start Derby handed this client a start slot: stand the car on it, facing
-- the placed heading. No freeze/hold - the derby's start grace period covers
-- the line-up, and the teleport is flagged so it never counts as a reset.
onDerbyGridAssign = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local slot = tonumber(data.slot)
  derbyState.slot = slot and math.floor(slot) or nil

  -- Through the same placement queue the race grid uses. A derby form-up is a
  -- whole field being teleported onto adjacent slots at once, which is the same
  -- physical problem: ghosted, staggered by slot number, collisions back once
  -- the field has settled. The derby assigns slots 1..N in order, so the slot
  -- number IS this car's place in the sequence.
  --
  -- Form-up holds every participant until the countdown lets them go, whether
  -- or not a slot was placed for them: a car with nowhere to line up still has
  -- to wait for GO rather than getting a free run at everyone else. Tagged
  -- 'derby' so a racing phase change can never release it.
  if derbyState.slot then
    queueFieldPlacement({
      slot  = derbyState.slot,
      slots = derbyState.starts,
      hold  = data.hold == true,
      holdSource = 'derby',
      order = derbyState.slot,
      count = math.max(#derbyState.starts, derbyState.slot),
    })
  elseif data.hold == true then
    -- No slot placed for this driver: hold them where they stand.
    requestHold('derby')
  end
end

-- Derby countdown, on its own channel so the racing countdown and this one can
-- never release each other's cars. GO (0) or an abort (-1) ends the hold; the
-- overlay itself is the shared UI one, since a countdown looks the same either
-- way and there is nothing mode-specific about drawing 3, 2, 1.
onDerbyCountdown = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local count = tonumber(data.count)
  if count and count <= 0 then releaseGridHold('derby') end
  guihooks.trigger('RaceManagerCountdown', data)
end

-- Map-filtered arena list from the server.
onDerbyLayoutList = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    log('E', 'raceManager', 'RM_DerbyLayouts: undecodable payload')
    return
  end
  if type(data.layouts) ~= 'table' or #data.layouts == 0 then data.layouts = {} end
  guihooks.trigger('RaceManagerDerbyLayouts', data)
end

-- ===========================================================================
-- End of DEMO DERBY module
-- ===========================================================================
end

-- Post-join: ask the server for the current state once its socket has had a
-- moment to come up, so a driver who joins a server mid-session sees the live
-- race without having to open the app and press anything.
local function joinRequestUpdate(dt)
  if not joinRequestLeft then return end
  joinRequestLeft = joinRequestLeft - dt
  if joinRequestLeft > 0 then return end
  joinRequestLeft = nil
  M.requestState()
end

function M.onUpdate(dt)
  localTime = localTime + dt
  joinRequestUpdate(dt)     -- deferred state request after joining a server
  checkGates()
  lapTimerUpdate(dt)        -- live lap clock for this driver's own HUD
  reportProgress(dt)        -- live position telemetry (distance to next gate)
  drawGates(derbyState.phase == 'running')
  -- The one label a driver gets: the gate poles carry no text at all.
  drawJokerLabel(derbyState.phase == 'running')
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
  spectate.setGrabberBlocked(derbyState.phase == 'forming'
    or derbyState.phase == 'countdown' or derbyState.phase == 'running')
  ghostUpdate(dt)           -- ghost mode qualifying
  vehicleConfigUpdate(dt)   -- Module 4: declare setup changes to the server
  derbyUpdate(dt)
  derbyDrawBoundary()
end

-- ---------------------------------------------------------------------------
-- Checkpoint editor API (called by the UI app)
-- ---------------------------------------------------------------------------
-- Which route the editor is currently building: the main lap or the joker
-- route. Everything below (+ Checkpoint Here, Undo, the list) follows it.
-- Three targets now: the main lap, the joker route, and the starting grid.
-- The UI app tells us whether its editor panel is on screen. Drives the
-- start-slot markers, which are editor furniture rather than driver
-- information. Sent when the admin tab changes, when the app mounts, and when
-- it is torn down (a closed app cannot have an open editor).
-- Diagnostic for the in-game Lua console:
--   dump(raceManager.ghostStatus())
-- Answers "why is this car still a ghost" without needing the log: whether it
-- is ghosted, WHICH source is measuring the space around it, and what is
-- currently blocking the restore. `boundsFrom` is the one that matters -- a
-- field where no bounding box ever resolves behaves very differently from one
-- where they do, and until now there was no way to tell which you had.
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
    phase          = phase,
    ghostQuali     = ghostQuali,
  }
end

function M.setEditorOpen(open)
  editorOpen = open == true
  -- A closed editor cannot have a mouse mode, and a cursor left released with
  -- nothing to use it is a camera that has stopped answering for no reason.
  if not editorOpen then nudge.release() end
end

-- Editor toggle: is this track a sprint or a circuit?
--
-- Told to the server as well as kept locally, because the lap count is the
-- server's and a sprint stage is one traversal by definition -- leaving an
-- admin to also remember "and set laps to 1" is the workaround this replaces.
function M.setPointToPoint(on)
  pointToPoint = on == true
  labelCache.route = {}          -- the gate labels say which mode this is
  if inMultiplayer() then
    TriggerServerEvent('RM_SetPointToPoint', jsonEncode({ enabled = pointToPoint }))
  end
  pushRouteState()
  log('I', 'raceManager', 'Track mode: ' .. (pointToPoint and 'POINT TO POINT' or 'circuit'))
end

function M.setEditorTarget(target)
  target = tostring(target or 'main')
  if target ~= 'joker' and target ~= 'start' and target ~= 'pit'
     and target ~= 'branch' then target = 'main' end
  editorTarget = target
  pushRouteState()
  log('I', 'raceManager', 'Editor target: ' .. editorTarget)
end

-- The branch the editor is pointed at, or nil when there is none yet.
function branch.editing()
  if not branch.editId then return nil end
  for _, b in ipairs(branch.list) do
    if b.id == branch.editId then return b end
  end
  return nil
end

local function activeEditorRoute()
  if editorTarget == 'joker' then return jokerRoute end
  if editorTarget == 'pit'   then return pitRoute end
  if editorTarget == 'start' then return startPositions end
  if editorTarget == 'branch' then
    local b = branch.editing()
    return b and b.gates or {}
  end
  return route
end

-- Nudge mode's behaviour. The table itself is declared at the top of the file,
-- beside `branch`, because the frame loop and the drawing code both reach it and
-- both run above this point: a local declared here would be a nil GLOBAL to
-- them, which compiles cleanly and fails only when somebody drags a gate.
--
-- Are the engine pieces this needs present? Resolved once. `ui_imgui` is how
-- every stock tool reads the mouse, and cameraMouseRayCast is the same call the
-- world editor's own object placement uses.
function nudge.available()
  if nudge.ready ~= nil then return nudge.ready end
  local okIm, im = pcall(function () return ui_imgui end)
  nudge.im = (okIm and type(im) == 'table' and im.IsMouseDown) and im or nil
  nudge.ready = (nudge.im ~= nil)
    and (type(cameraMouseRayCast) == 'function')
    and (core_canvas ~= nil)
  if not nudge.ready then
    log('W', 'raceManager', 'Nudge mode unavailable: this build has no '
      .. (nudge.im and 'cameraMouseRayCast/core_canvas' or 'ui_imgui'))
  end
  return nudge.ready
end

-- Give the mouse back. Called from every exit, including the ones that are not
-- the admin pressing the button: closing the editor, changing tab, unloading.
-- A cursor left released with no mode to use it is a camera that has stopped
-- answering the mouse for no visible reason.
function nudge.release()
  if not nudge.on then return end
  nudge.on, nudge.sel, nudge.dragging, nudge.list = false, nil, false, nil
  pcall(function () core_canvas.hideCursor() end)
  log('I', 'raceManager', 'Nudge mode off, mouse returned to the camera')
end

function nudge.set(on)
  on = on and true or false
  if on == nudge.on then return end
  if not on then nudge.release(); pushRouteState(); return end
  if not nudge.available() then
    guihooks.trigger('RaceManagerEditorMsg', {
      msg = 'Nudge mode needs a newer BeamNG build' })
    return
  end
  nudge.on, nudge.sel, nudge.dragging = true, nil, false
  pcall(function () core_canvas.showCursor() end)
  log('I', 'raceManager', 'Nudge mode on, mouse released from the camera')
  pushRouteState()
end

-- Nearest gate to the cursor ray, by perpendicular distance from the ray to the
-- gate's centre. Behind the camera does not count: a gate at your back is
-- geometrically close to the ray running through it and is never what you meant.
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

-- Turn a gate in place. Heading is a unit vector on the ground plane, and the
-- gate's rectangle is built perpendicular to it, so rotating this rotates the
-- gate. Renormalised every time because repeated rotation of a stored pair
-- drifts off the unit circle, and a heading that is not unit length silently
-- changes how wide the gate tests.
function nudge.turn(wp, radians)
  if not wp then return end
  local hx, hy = tonumber(wp.hx) or 0, tonumber(wp.hy) or 1
  local c, s = math.cos(radians), math.sin(radians)
  local nx, ny = hx * c - hy * s, hx * s + hy * c
  local len = math.sqrt(nx * nx + ny * ny)
  if len < 1e-6 then return end
  wp.hx, wp.hy = nx / len, ny / len
end

-- Move a gate to a point on the ground, keeping the height it was authored at.
-- The raycast lands ON the terrain, and a gate dropped to ground level is a gate
-- whose lower half is buried: what matters is the height of its CENTRE above the
-- road, which is what the original placement captured from the car.
function nudge.moveTo(wp, hit, ground)
  if not (wp and hit) then return end
  local lift = wp.z - (ground or wp.z)
  wp.x, wp.y = hit.x, hit.y
  wp.z = hit.z + lift
end

-- One frame of the mode. Everything here is guarded: a mode that throws inside
-- the frame loop takes the whole mod down with it.
function nudge.update()
  if not nudge.on then return end
  -- The editor closing, the admin logging out, or a session starting all end it.
  -- Authoring a track while it is being raced on is not a thing to allow, and
  -- the cursor has to go back either way.
  if not (editorOpen and isAdmin) or sessionRunning() then
    nudge.release()
    return
  end
  local im = nudge.im
  if not im then return end
  -- Never steal a click meant for a UI panel. The HUD app is a real window over
  -- the world and the admin is clicking its buttons with this same cursor.
  local wantsUi = false
  pcall(function () wantsUi = im.GetIO().WantCaptureMouse end)

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

  if down and not wantsUi then
    local picked = nudge.pick(list, ray)
    -- Tell the panel whenever the selection CHANGES, including to nothing.
    -- Pushing only on a drag left the UI showing a gate the mouse had already
    -- let go of.
    if picked ~= nudge.sel then
      nudge.sel = picked
      pushRouteState()
    end
    nudge.dragging = picked ~= nil
  end
  if up then nudge.dragging = false end

  local wp = nudge.sel and list[nudge.sel]
  if not wp then
    if nudge.sel ~= nil then
      nudge.sel, nudge.dragging = nil, false
      pushRouteState()
    end
    nudge.dragging = false
    return
  end

  if nudge.dragging and held and hit and hit.pos then
    -- The ground under the gate NOW, so the lift it was authored with survives
    -- being dragged across a crest or into a dip.
    local under = wp.z
    if type(castRayStatic) == 'function' then
      local okR, d = pcall(castRayStatic, vec3(wp.x, wp.y, wp.z + 50), vec3(0, 0, -1), 100)
      if okR and type(d) == 'number' and d < 100 then under = wp.z + 50 - d end
    end
    nudge.moveTo(wp, hit.pos, under)
    if editorTarget == 'branch' then branch.rebuild() end
    if editorTarget == 'start' then branch.gridTool.generated = false end
    pushRouteState()
  end

  -- Scroll turns the selected gate. The tedious half of a fine adjustment is the
  -- heading, because re-driving a corner is the only other way to change it.
  local wheel = 0
  pcall(function () wheel = im.GetIO().MouseWheel or 0 end)
  if wheel ~= 0 and not wantsUi then
    nudge.turn(wp, wheel * nudge.TURN_PER_STEP)
    if editorTarget == 'branch' then branch.rebuild() end
    pushRouteState()
  end
end

-- Rebuild the per-slot lookup from the authored gate lists. Called after every
-- edit, so what the editor shows and what the crossing code arms are the same
-- thing -- an admin standing on a branch gate sees it go green.
function branch.rebuild()
  local bySlot = {}
  for _, b in ipairs(branch.list) do
    local slots = {}
    for _, g in ipairs(b.gates) do
      local slot = tonumber(g.slot)
      if slot then slots[math.floor(slot)] = g end
    end
    bySlot[b.id] = slots
  end
  branch.bySlot = bySlot
end

-- The lowest slot this branch has not overridden yet, so placing a full mirror
-- lap is drive-and-click without touching the slot picker once.
function branch.nextFreeSlot(b)
  if not b then return 1 end
  local used = {}
  for _, g in ipairs(b.gates) do
    local s = tonumber(g.slot)
    if s then used[math.floor(s)] = true end
  end
  for i = 1, math.max(#route, 1) do
    if not used[i] then return i end
  end
  return math.max(#route, 1)
end

-- Create a lane. The id is derived from the name so an admin types one thing,
-- and collisions are settled with a suffix rather than a rejection -- naming two
-- lanes "Left" is a mistake worth absorbing, not one worth stopping on.
function M.addBranch(name)
  name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then name = 'Lane ' .. (#branch.list + 1) end
  local base = name:lower():gsub('[^%w]+', ''):sub(1, 20)
  if base == '' then base = 'lane' end
  local id, n = base, 1
  local function taken(x)
    for _, b in ipairs(branch.list) do if b.id == x then return true end end
    return false
  end
  while taken(id) do n = n + 1; id = base .. n end
  branch.list[#branch.list + 1] = { id = id, name = name, gates = {} }
  branch.editId   = id
  branch.editSlot = 1
  branch.rebuild()
  pushRouteState()
  log('I', 'raceManager', 'Branch added: ' .. name .. ' (' .. id .. ')')
end

function M.selectBranch(id)
  id = tostring(id or '')
  branch.editId = (id ~= '') and id or nil
  branch.editSlot = branch.nextFreeSlot(branch.editing())
  pushRouteState()
end

function M.removeBranch(id)
  id = tostring(id or '')
  for i, b in ipairs(branch.list) do
    if b.id == id then
      table.remove(branch.list, i)
      if branch.editId == id then branch.editId = branch.list[1] and branch.list[1].id or nil end
      branch.rebuild()
      pushRouteState()
      log('I', 'raceManager', 'Branch removed: ' .. id)
      return
    end
  end
end

-- Which slot the next placed branch gate overrides.
function M.setBranchSlot(slot)
  slot = math.floor(tonumber(slot) or 1)
  if slot < 1 then slot = 1 end
  if #route > 0 and slot > #route then slot = #route end
  branch.editSlot = slot
  pushRouteState()
end

-- Re-point an already-placed branch gate at a different slot.
function M.setBranchGateSlot(index, slot)
  local b = branch.editing()
  if not b then return end
  index = math.floor(tonumber(index) or 0)
  local g = b.gates[index]
  if not g then return end
  slot = math.floor(tonumber(slot) or 1)
  if slot < 1 then slot = 1 end
  if #route > 0 and slot > #route then slot = #route end
  -- Two gates on one slot would make the lane ambiguous, so the slot is taken
  -- from whichever gate held it: the admin asked for this one to have it.
  for i, other in ipairs(b.gates) do
    if i ~= index and tonumber(other.slot) == slot then
      other.slot = tonumber(g.slot)
      break
    end
  end
  g.slot = slot
  branch.rebuild()
  pushRouteState()
end

-- Place a marker where the car is standing.
--
-- A gate is given its size HERE, once, and keeps it. It inherits from the gate
-- placed before it, so a creator sets the size once and drives the rest of the
-- route; the first gate of a fresh route takes the standard default.
--
-- This replaced a global width/height that every gate without an override read
-- live. That setting was a footgun: nudging a slider resized the entire circuit
-- at once, retroactively, with nothing to undo it -- and the gates it hit were
-- exactly the ones the creator had never thought about. A size that is decided
-- when a gate is placed can only ever be wrong for that gate.
--
-- Start positions are placements, not gates, so they get no dimensions.
function M.editorAdd()
  local place = vehiclePlacement()
  if not place then
    log('W', 'raceManager', 'Editor: no player vehicle, cannot place')
    return
  end
  local target = activeEditorRoute()
  if editorTarget ~= 'start' then
    local prev = target[#target]
    place.width  = clampWidth(prev and prev.width  or checkpointWidth)
    place.height = clampHeight(prev and prev.height or checkpointHeight)
  end
  -- A branch gate is placed AGAINST A SLOT: it is not a new checkpoint, it is the
  -- other way of taking one that already exists. Placing it is what makes the
  -- track a head-on layout rather than a longer lap.
  if editorTarget == 'branch' then
    local b = branch.editing()
    if not b then
      guihooks.trigger('RaceManagerEditorMsg', { msg = 'Add a lane first' })
      return
    end
    if #route == 0 then
      guihooks.trigger('RaceManagerEditorMsg', { msg = 'Place the main route first' })
      return
    end
    local slot = math.floor(branch.editSlot or 1)
    if slot < 1 then slot = 1 end
    if slot > #route then slot = #route end
    -- One gate per slot per lane. Placing on a slot that already has one moves it
    -- rather than quietly making the lane ambiguous.
    for _, g in ipairs(b.gates) do
      if tonumber(g.slot) == slot then
        g.x, g.y, g.z, g.hx, g.hy = place.x, place.y, place.z, place.hx, place.hy
        branch.rebuild()
        pushRouteState()
        log('I', 'raceManager', 'Branch ' .. b.id .. ' slot ' .. slot .. ' moved')
        return
      end
    end
    place.slot = slot
    b.gates[#b.gates + 1] = place
    branch.editSlot = branch.nextFreeSlot(b)
    branch.rebuild()
    pushRouteState()
    return
  end
  target[#target + 1] = place
  -- A slot placed by hand after a generate leaves the generator's block no
  -- longer the last `count` of them, so it stops claiming to own one.
  if editorTarget == 'start' then branch.gridTool.generated = false end
  pushRouteState()
end

function M.editorUndo()
  local target = activeEditorRoute()
  if #target > 0 then
    target[#target] = nil
    if editorTarget == 'joker' then
      if jokerArmed > #jokerRoute then jokerArmed = math.max(#jokerRoute, 1) end
    elseif editorTarget == 'main' and armedWp > #route then
      armedWp = math.max(#route, 1)
    elseif editorTarget == 'branch' then
      branch.editSlot = branch.nextFreeSlot(branch.editing())
      branch.rebuild()
    end
    pushRouteState()
  end
end

function M.editorClear()
  -- Clearing the joker route or the grid on its own must not wipe the main lap.
  if editorTarget == 'pit' then
    pitRoute = {}
    pushRouteState()
    log('I', 'raceManager', 'Pit stalls cleared')
    return
  end
  if editorTarget == 'joker' then
    jokerRoute   = {}
    jokerArmed   = 1
    jokerTaken   = false
    jokerLapUsed = nil
    pushRouteState()
    log('I', 'raceManager', 'Joker route cleared')
    return
  end
  if editorTarget == 'start' then
    startPositions = {}
    gridSlot = nil
    branch.gridTool.generated = false
    pushRouteState()
    log('I', 'raceManager', 'Start positions cleared')
    return
  end
  -- Clears the LANE being edited, not every lane and certainly not the main
  -- route: the other way round a track is a thing an admin iterates on.
  if editorTarget == 'branch' then
    local b = branch.editing()
    if b then
      b.gates = {}
      branch.editSlot = 1
      branch.rebuild()
      pushRouteState()
      log('I', 'raceManager', 'Branch ' .. b.id .. ' gates cleared')
    end
    return
  end
  clearTrackState('editor clear')
end

-- --- Start position editing -------------------------------------------------
-- Placed slots stay editable: move one to where the car is standing now, or
-- drop it and let the rest of the grid close up.
function M.moveStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  if not startPositions[index] then
    log('W', 'raceManager', 'moveStartPosition: no start position at ' .. tostring(index))
    return
  end
  local place = vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  startPositions[index] = place
  -- Hand-placed now, so the sliders let go of it: they own a block of slots by
  -- count, and a slot moved by hand is no longer where that count says it is.
  branch.gridTool.generated = false
  pushRouteState()
  log('I', 'raceManager', 'Start position ' .. index .. ' moved to the current vehicle')
end

function M.removeStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  if not startPositions[index] then return end
  table.remove(startPositions, index)
  if gridSlot and gridSlot > #startPositions then gridSlot = nil end
  branch.gridTool.generated = false
  pushRouteState()
end

-- Preview: stand the car on a placed slot so the creator can check spacing
-- without starting a race. Never freezes - this is an editor convenience.
function M.previewStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  local sp = startPositions[index]
  if not sp then return end
  if not placeOnStartPosition(sp) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Could not move the vehicle' })
  end
end

-- Move a placed gate to where the car is standing, and stand the car on a
-- placed gate. The same pair the starting grid has had all along -- an editor
-- where a marker can be placed but never adjusted means deleting and re-driving
-- the whole route to fix one gate that landed a metre wide.
--
-- Both work on whichever list the editor is pointed at, so they serve the main
-- route, the joker route and the pit stalls without three copies of the code.
-- The gate keeps its own width/height override: this moves it, nothing else.
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
  wp.x, wp.y, wp.z = place.x, place.y, place.z
  wp.hx, wp.hy = place.hx, place.hy
  pushRouteState()
  log('I', 'raceManager', string.format('%s %d moved to the current vehicle',
    editorTarget, index))
end

-- Stand the car on a placed gate, facing the way through it, so the creator can
-- see what a driver will see. Never freezes: this is an editor convenience.
function M.previewCheckpoint(index)
  index = math.floor(tonumber(index) or 0)
  local wp = activeEditorRoute()[index]
  if not wp then return end
  if not placeOnStartPosition(wp) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Could not move the vehicle' })
  end
end

-- --- Taking things back -----------------------------------------------------
-- Undo removes the LAST gate, which for a while was the only way to remove one
-- at all: a gate placed out of order, or one missing from the middle, meant
-- undoing back to it and re-driving everything after. These are the three
-- operations that were missing, and they work on whichever list the editor is
-- pointed at, so one implementation serves the main route, the joker route and
-- the pit stalls -- the same reasoning moveCheckpoint is written under.
--
-- Every one of them has to renumber the BRANCHES in step. A branch addresses
-- slots by number, so inserting, deleting or moving a main gate changes what
-- those numbers mean; a lane left un-renumbered silently comes to describe a
-- different corner of the track.
function branch.shiftSlots(from, delta)
  for _, b in ipairs(branch.list) do
    for _, g in ipairs(b.gates) do
      local s = tonumber(g.slot)
      if s and s >= from then g.slot = s + delta end
    end
  end
end

-- Drop the overrides for a slot that is going away, and say so rather than
-- leaving a lane pointing at a gate that no longer exists.
function branch.dropSlot(slot)
  local dropped = 0
  for _, b in ipairs(branch.list) do
    for i = #b.gates, 1, -1 do
      if tonumber(b.gates[i].slot) == slot then
        table.remove(b.gates, i)
        dropped = dropped + 1
      end
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
  if editorTarget == 'main' then
    local dropped = branch.dropSlot(index)
    branch.shiftSlots(index + 1, -1)
    branch.rebuild()
    if dropped > 0 then
      guihooks.trigger('RaceManagerEditorMsg', {
        msg = 'Checkpoint ' .. index .. ' removed: ' .. dropped
          .. ' branch gate(s) on that slot dropped with it',
      })
    end
    if armedWp > #route then armedWp = math.max(#route, 1) end
  elseif editorTarget == 'joker' then
    if jokerArmed > #jokerRoute then jokerArmed = math.max(#jokerRoute, 1) end
  elseif editorTarget == 'branch' then
    branch.editSlot = branch.nextFreeSlot(branch.editing())
    branch.rebuild()
  end
  pushRouteState()
  log('I', 'raceManager', string.format('%s %d removed', editorTarget, index))
end

-- Place a gate BEFORE an existing one, at the car. The missing half of "add":
-- a route is driven in order, and noticing a gap after the fact used to cost
-- every gate placed since.
function M.insertCheckpoint(index)
  index = math.floor(tonumber(index) or 0)
  local list = activeEditorRoute()
  if index < 1 then index = 1 end
  if index > #list + 1 then index = #list + 1 end
  local place = vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  if editorTarget ~= 'start' then
    local prev = list[index] or list[#list]
    place.width  = clampWidth(prev and prev.width  or checkpointWidth)
    place.height = clampHeight(prev and prev.height or checkpointHeight)
  end
  if editorTarget == 'branch' then
    guihooks.trigger('RaceManagerEditorMsg', {
      msg = 'Branch gates are placed against a slot, not in an order',
    })
    return
  end
  table.insert(list, index, place)
  if editorTarget == 'main' then
    branch.shiftSlots(index, 1)
    branch.rebuild()
  end
  pushRouteState()
  log('I', 'raceManager', string.format('%s inserted at %d', editorTarget, index))
end

-- Move one gate (or grid slot) to a different place in the order. Slot 1 of the
-- grid is pole, so this is also how a grid built in the wrong order is fixed.
function M.reorderCheckpoint(from, to)
  from = math.floor(tonumber(from) or 0)
  to   = math.floor(tonumber(to) or 0)
  local list = activeEditorRoute()
  if not list[from] or from == to then return end
  if to < 1 then to = 1 end
  if to > #list then to = #list end
  local item = table.remove(list, from)
  table.insert(list, to, item)
  if editorTarget == 'main' then
    -- The main route's slots moved, so every branch override addressing one of
    -- them has to move with it. Worked out from the shift the item made rather
    -- than re-derived: exactly one slot changed position, everything between
    -- `from` and `to` shifted one step the other way.
    local lo, hi, step = math.min(from, to), math.max(from, to), (from < to) and -1 or 1
    for _, b in ipairs(branch.list) do
      for _, g in ipairs(b.gates) do
        local s = tonumber(g.slot)
        if s == from then g.slot = to
        elseif s and s >= lo and s <= hi then g.slot = s + step end
      end
    end
    branch.rebuild()
  end
  pushRouteState()
  log('I', 'raceManager', string.format('%s %d moved to %d', editorTarget, from, to))
end

-- --- Building a grid without driving it -------------------------------------
-- A head-on layout needs two blocks of slots facing opposite ways, and placing
-- them one car at a time is the tedious part of authoring one.

-- The grid generator's own state. One table for the register budget, and
-- because these three genuinely travel together: what was generated, from where,
-- and how far apart -- which is exactly what the sliders need to re-lay it out
-- without the creator driving anywhere again.
branch.gridTool = {
  generated = false,   -- was this grid laid out by the generator?
  anchor    = nil,     -- { x, y, z, hx, hy } the row-1 slot it was built from
  count     = 0,
  spacing   = 8,       -- metres between rows
  stagger   = 6,       -- metres between the cars ACROSS a row
  width     = 2,       -- cars per row
}

-- Lay N slots out from an anchor, back down its heading, `width` cars abreast.
-- Nothing here is novel geometry: it is a placement plus arithmetic on the
-- heading it already carries.
--
-- The row is CENTRED on the anchor, whatever it is made of. Two abreast puts a
-- car half a gap either side of where the creator stood; three puts one on that
-- spot and one either side; one puts every car on it, single file. Centring is
-- what makes the width a free choice -- a row that grew off one edge would walk
-- the whole grid sideways every time it changed, and on an oval it would walk it
-- into the wall.
--
-- `stagger` is the gap between ADJACENT cars across a row, not the distance from
-- some centre line. That is the measurement a creator can actually check against
-- the track: it is how much room each car has beside the one next to it.
function branch.layOutGrid(anchor, count, spacing, stagger, width, replace)
  local fx, fy = anchor.hx, anchor.hy
  local rx, ry = fy, -fx        -- the right-hand perpendicular
  width = math.floor(tonumber(width) or 2)
  if width < 1 then width = 1 end
  if width > TUNE.GRID_MAX_WIDTH then width = TUNE.GRID_MAX_WIDTH end
  if replace then startPositions = {} end
  local mid = (width - 1) * 0.5
  for i = 0, count - 1 do
    local row  = math.floor(i / width)
    local col  = i % width
    local back = row * spacing
    local side = (col - mid) * stagger
    startPositions[#startPositions + 1] = {
      x  = anchor.x - fx * back + rx * side,
      y  = anchor.y - fy * back + ry * side,
      z  = anchor.z,
      hx = fx, hy = fy,
    }
  end
end

-- Generate a grid.
--
-- `from` picks the anchor: a slot number uses that ALREADY PLACED start position
-- and its heading, and anything else uses the car. Anchoring on a placed slot is
-- what makes the sliders below work -- pole is a decision the creator makes once,
-- by standing on it, and everything after it is arithmetic.
-- NOT M.generateGrid. That name belongs to the admin control further down this
-- file which asks the SERVER to form the race grid -- it teleports the whole
-- field onto its slots and holds them for the countdown. Lua assignment is
-- last-one-wins and that one is defined later, so a start-position generator
-- called generateGrid was simply erased at load: pressing Generate Slots sent
-- RM_GenerateGrid and started the race instead.
--
-- The same collision happened one layer up, in app.js, and was renamed there
-- first -- which fixed nothing, because both layers had it.
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
  if startPositions[slot] then
    -- Rebuild the grid from an existing slot, keeping everything before it.
    local sp = startPositions[slot]
    anchor = { x = sp.x, y = sp.y, z = sp.z, hx = sp.hx, hy = sp.hy }
    for i = #startPositions, slot, -1 do table.remove(startPositions, i) end
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
  -- Remembered so the sliders can re-lay the same grid out without the creator
  -- driving back to pole to do it.
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

-- Re-lay the generated grid out at a new spacing. What the sliders drive.
--
-- Only ever touches a grid this generator built, and only the slots it built:
-- respacing a grid somebody placed by hand would throw their work away, and the
-- sliders are hidden until there is a generated one to move.
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
  -- The slots this generator owns are the last `count` of them; anything placed
  -- before the generate stays exactly where the creator put it.
  local keep = #startPositions - branch.gridTool.count
  if keep < 0 then keep = 0 end
  -- LANE TAGS AND HEADINGS SURVIVE THE MOVE. Both belong to the slot, and
  -- respacing moves slots rather than replacing them.
  --
  -- The heading matters as much as the tag, and for the same layout: a head-on
  -- grid is generated as one block, half of it turned around, and half of it
  -- tagged. Re-laying it from the anchor alone would face every car the anchor's
  -- way again, so nudging a slider would silently un-turn half the field and the
  -- two directions would set off together.
  local held = {}
  for i = keep + 1, #startPositions do
    local sp = startPositions[i]
    held[i - keep] = sp and { branch = sp.branch, hx = sp.hx, hy = sp.hy } or nil
  end
  for i = #startPositions, keep + 1, -1 do table.remove(startPositions, i) end
  branch.layOutGrid(branch.gridTool.anchor, branch.gridTool.count,
    spacing, stagger, width, false)
  for i = 1, branch.gridTool.count do
    local sp, was = startPositions[keep + i], held[i]
    if sp and was then
      sp.branch = was.branch
      if was.hx and was.hy then sp.hx, sp.hy = was.hx, was.hy end
    end
  end
  -- Changing the width re-flows the SAME slots into different rows -- slot 5 of a
  -- three-wide grid is row 2 where it was row 3 two-wide -- and the tag and
  -- heading above follow the slot, not the row. That is the right way round: a
  -- head-on grid is tagged "slots 7 to 12 go the other way", and it stays that
  -- way whatever shape the rows are.
  branch.gridTool.spacing = spacing
  branch.gridTool.stagger = stagger
  branch.gridTool.width   = width
  pushRouteState()
end

-- Turn a range of grid slots around. Build one block, then flip half of it: the
-- head-on grid without driving the second half of it.
function M.flipStartPositions(from, to)
  from = math.floor(tonumber(from) or 1)
  to   = math.floor(tonumber(to) or #startPositions)
  if from < 1 then from = 1 end
  if to > #startPositions then to = #startPositions end
  local n = 0
  for i = from, to do
    local sp = startPositions[i]
    if sp then
      sp.hx, sp.hy = -(sp.hx or 0), -(sp.hy or 1)
      n = n + 1
    end
  end
  pushRouteState()
  guihooks.trigger('RaceManagerEditorMsg', { msg = 'Turned ' .. n .. ' start position(s) around' })
end

-- Put a range of grid slots on a lane. This is how a field is split in half --
-- tag slots 1-6 one way and 7-12 the other -- and it is the only place a
-- driver's direction is ever decided. An empty id puts them back on the main
-- route.
-- Deal the lanes out across the grid, one slot at a time, instead of in blocks.
--
-- P1 main, P2 the next lane, P3 back to main, and so on. On a grid as many cars
-- abreast as there are lanes that puts each lane in its own COLUMN -- two abreast
-- with two lanes is one car of each direction in every row, side by side, facing
-- opposite ways, which is the head-on grid as it is actually lined up.
--
-- It also splits the field evenly without the admin working out where the middle
-- is, and stays even when the entry list changes size: tagging slots 1-6 and
-- 7-12 by hand is right for twelve drivers and wrong for the eleven who turn up.
--
-- The cycle is main first, then each branch in the order they were created, so
-- pole is always the main route.
function M.stripeStartLanes()
  local lanes = { false }        -- false = the main route, no tag
  for _, b in ipairs(branch.list) do lanes[#lanes + 1] = b.id end
  if #lanes < 2 then
    guihooks.trigger('RaceManagerEditorMsg', {
      msg = 'Add a lane first: there is nothing to alternate with',
    })
    return
  end
  for i, sp in ipairs(startPositions) do
    local pick = lanes[((i - 1) % #lanes) + 1]
    sp.branch = pick or nil
  end
  pushRouteState()
  local names = {}
  for _, l in ipairs(lanes) do names[#names + 1] = l and branch.nameOf(l) or 'Main' end
  guihooks.trigger('RaceManagerEditorMsg', {
    msg = 'Alternated ' .. #startPositions .. ' slots across: ' .. table.concat(names, ', '),
  })
  log('I', 'raceManager', 'Start positions striped across ' .. #lanes .. ' lanes')
end

function M.setStartLane(from, to, id)
  from = math.floor(tonumber(from) or 1)
  to   = math.floor(tonumber(to) or #startPositions)
  id   = tostring(id or '')
  if id == '' then id = nil end
  if from < 1 then from = 1 end
  if to > #startPositions then to = #startPositions end
  local n = 0
  for i = from, to do
    local sp = startPositions[i]
    if sp then sp.branch = id; n = n + 1 end
  end
  pushRouteState()
  guihooks.trigger('RaceManagerEditorMsg', {
    msg = n .. ' start position(s) set to ' .. (id and ('lane ' .. id) or 'the main route'),
  })
end

function M.setCheckpointWidth(w)
  checkpointWidth = clampWidth(w)
  pushRouteState()
end

function M.setCheckpointHeight(h)
  checkpointHeight = clampHeight(h)
  pushRouteState()
end

-- Per-checkpoint override editor. index is 1-based into the placed route; a
-- nil/blank/non-positive value for a dimension clears that override so the gate
-- falls back to the global default. Pass both blank to fully reset a gate.
function M.setCheckpointOverride(index, w, h)
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
  pushRouteState()
end

-- The local scratch route file (editorSave/editorLoad) is gone. Loading it
-- rebuilt the route while emptying the joker route and the grid, so a Load there
-- followed by a Save here overwrote a server layout with a partial one. Server
-- layouts are the only copy now.
function M.setNudgeMode(on)
  nudge.set(on == true or on == 'true')
end

function M.editorToggleVisualize()
  visualize = not visualize
  pushRouteState()
end

-- ---------------------------------------------------------------------------
-- Track layouts (server-side, persistent, per-map)
-- ---------------------------------------------------------------------------
-- Unlike editorSave/editorLoad (a single local scratch file), named layouts
-- live on the BeamMP server in layouts.json, keyed by map, and survive server
-- restarts. Saving bundles the currently placed checkpoints; loading is pushed
-- by the server to every client at once via RM_ApplyLayout.
local function editorMsg(msg)
  guihooks.trigger('RaceManagerEditorMsg', { msg = msg })
end

-- `confirmDrop` is the admin having accepted that this save empties a section
-- the stored layout has. Without it the server holds the save and answers with
-- RM_SaveHeld. See the silent-drop guard there.
function M.saveLayout(name, confirmDrop)
  name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
  print('[raceManager] saveLayout("' .. name .. '") with ' .. #route .. ' checkpoint(s)')
  if name == '' then
    log('W', 'raceManager', 'saveLayout: no layout name given, nothing sent')
    editorMsg('Enter a layout name first')
    return
  end
  if #route == 0 then
    log('W', 'raceManager', 'saveLayout: no checkpoints placed, nothing sent')
    editorMsg('Place checkpoints before saving a layout')
    return
  end
  if not inMultiplayer() then
    log('W', 'raceManager', 'saveLayout: not connected to a BeamMP server, nothing sent')
    editorMsg('Layouts need a BeamMP server (use Save/Load for offline routes)')
    return
  end
  -- Bundle a sanitized copy of the route: plain numeric fields only, so the
  -- payload always JSON-encodes as the flat checkpoint array the server's
  -- sanitizeCheckpoints expects (never vec3 userdata or stray keys).
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
      if wp.oneWay == true   then out[i].oneWay = true end
      -- Start positions only: the lane a car on this slot races. Dropping it here
      -- would save a head-on grid as an ordinary one, and the field would all set
      -- off the same way round.
      if type(wp.branch) == 'string' and wp.branch ~= '' then out[i].branch = wp.branch end
    end
    return out
  end
  local cps = bundle(route, 'route')
  if not cps then return end
  -- The joker route rides along with the layout so a rallycross track is a
  -- single saved object. Omitted entirely when no joker gates are placed.
  local jokerCps = nil
  if #jokerRoute > 0 then
    jokerCps = bundle(jokerRoute, 'joker')
    if not jokerCps then return end
  end
  -- The starting grid travels with the layout too: a track is its gates AND
  -- where the cars line up.
  local starts = nil
  if #startPositions > 0 then
    starts = bundle(startPositions, 'start position')
    if not starts then return end
  end
  -- The lanes travel with the layout, like the joker route and the grid: a
  -- head-on oval is one saved object, not a circuit an admin has to remember to
  -- rebuild the other half of. Bundled by hand rather than through `bundle`
  -- because a branch gate carries the slot it overrides, which is the whole
  -- point of it.
  local lanes = nil
  if #branch.list > 0 then
    lanes = {}
    for _, b in ipairs(branch.list) do
      local gates = {}
      for _, g in ipairs(b.gates) do
        local x, y, z, slot = tonumber(g.x), tonumber(g.y), tonumber(g.z), tonumber(g.slot)
        if not (x and y and z and slot) then
          log('E', 'raceManager', 'saveLayout: branch ' .. b.id .. ' has an invalid gate, aborting')
          editorMsg('Save failed: lane "' .. (b.name or b.id) .. '" has an invalid gate')
          return
        end
        local out = {
          slot = math.floor(slot), x = x, y = y, z = z,
          hx = tonumber(g.hx) or 0, hy = tonumber(g.hy) or 1,
        }
        if tonumber(g.width)  then out.width  = clampWidth(g.width)   end
        if tonumber(g.height) then out.height = clampHeight(g.height) end
        if g.oneWay == true   then out.oneWay = true end
        gates[#gates + 1] = out
      end
      -- A lane with no gates is the main route wearing a different name, and the
      -- server rejects the whole save for one. Dropped here instead, so an admin
      -- who added a lane and has not placed its gates yet can still save.
      if #gates > 0 then
        lanes[#lanes + 1] = { id = b.id, name = b.name or b.id, gates = gates }
      end
    end
    if #lanes == 0 then lanes = nil end
  end
  local payload = jsonEncode({
    name        = name,
    width       = clampWidth(checkpointWidth),
    height      = clampHeight(checkpointHeight),
    checkpoints = cps,
    joker       = jokerCps,
    startPositions = starts,
    branches       = lanes,
    -- Does this grid sit away from the start/finish line? Inferred rather than
    -- asked for: an admin who placed the grid somewhere else has already said so
    -- by placing it there, and a switch they have to remember is one they will
    -- forget. A head-on layout always trips it, because two directions cannot
    -- share one row of slots.
    gridOffLine    = branch.gridIsOff(),
    pits           = bundle(pitRoute, 'pit stall') or {},
    -- Whether this track is a sprint stage or a circuit is a property of the
    -- TRACK, so it is stored with it. An admin who built a point-to-point stage
    -- should not have to remember to set it again every race night.
    pointToPoint   = pointToPoint,
    confirmDrop    = confirmDrop == true,
  })
  print('[raceManager] saveLayout: sending RM_SaveLayout (' .. #payload .. ' bytes) to server')
  TriggerServerEvent('RM_SaveLayout', payload)
end

function M.requestLayouts()
  if inMultiplayer() then TriggerServerEvent('RM_RequestLayouts', '') end
end

function M.loadLayout(name)
  name = tostring(name or '')
  if name == '' then return end
  if not inMultiplayer() then
    editorMsg('Layouts need a BeamMP server')
    return
  end
  TriggerServerEvent('RM_LoadLayout', jsonEncode({ name = name }))
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
  route = { { x = x, y = y, z = z, hx = hx, hy = hy } }
  armedWp = 1
  pushRouteState()
end

-- ---------------------------------------------------------------------------
-- Server -> client
-- ---------------------------------------------------------------------------
-- SCOPED, and that is not cosmetic. Lua allows 200 locals per function, the top
-- level of this file IS a function, and it was within a couple of that ceiling
-- -- going over is not a warning, the file does not compile and the whole mod is
-- simply absent. The limit counts locals that are ACTIVE AT ONCE, so a `do ...
-- end` block hands its registers back at `end` while the closures defined inside
-- keep the values alive as upvalues.
--
-- Everything from here to the bottom of the file is the server -> client half:
-- twenty-odd handlers, the dispatch table that routes to them, the teardown and
-- the session hooks. Nothing above needs any of it by name -- the handlers are
-- reached through DISPATCH and the lifecycle through M -- so the whole tail
-- costs the outer function nothing.
do
local function onServerUpdate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  if not fromCurrentServer(data) then return end

  -- League regulations arrive with every state broadcast (Modules 1 & 2).
  if type(data.maxResets) == 'number' then maxResets = math.floor(data.maxResets) end
  if data.resetMode == 'checkpoint' or data.resetMode == 'inplace' then
    resetMode = data.resetMode
  end
  jokerEnabled = data.jokerEnabled == true
  -- Per-player admin status. Present only on a targeted reply (RM_RequestState),
  -- so the global broadcast never disturbs it. The server is the authority here:
  -- if it says this session is not authenticated, the local flag is wrong and
  -- gets corrected (server restart, or an admin logged out from elsewhere).
  if type(data.youAreAdmin) == 'boolean' and data.youAreAdmin ~= isAdmin then
    isAdmin = data.youAreAdmin
    guihooks.trigger('RaceManagerAuth', { success = isAdmin, restored = true })
    pushRouteState()
  end
  -- The qualifying clock has expired and this driver is on their last lap. Read
  -- off the state broadcast rather than a one-shot event, so a client that joins
  -- or reconnects mid-final-lap is told too - but announced only on the EDGE, or
  -- a 3 Hz broadcast would repeat the notice several times a second.
  local wasFinalLap = finalLap
  finalLap = data.finalLap == true
  if finalLap and not wasFinalLap then
    pushNotice('session', 'TIME EXPIRED: FINAL LAP. Your session ends as you cross the line.')
  end
  -- Race entry + qualifying rules.
  if type(data.entryMode) == 'string' then entryMode = data.entryMode end
  if type(data.pointToPoint) == 'boolean' then pointToPoint = data.pointToPoint end
  ghostQuali = data.ghostQuali == true
  qualiOutLap = data.qualiOutLap == true
  if type(data.qualiLapLimit)  == 'number' then qualiLapLimit  = data.qualiLapLimit  end
  if type(data.qualiTimeLimit) == 'number' then qualiTimeLimit = data.qualiTimeLimit end
  -- Reset-ghosting rules are the server's, so every client in a league runs the
  -- same numbers rather than whatever its own copy of the mod was shipped with.
  -- Re-anchor the shared clock every push. Ghost end times are expressed on it.
  if type(data.raceTime) == 'number' then ghost.serverTime = data.raceTime end
  if type(data.ghostOnReset) == 'boolean' then ghost.rules.onReset = data.ghostOnReset end
  if type(data.ghostMinSec)  == 'number'  then ghost.rules.minSec  = data.ghostMinSec  end
  if type(data.ghostMaxSec)  == 'number'  then ghost.rules.maxSec  = data.ghostMaxSec  end
  -- Authoritative per-vehicle ghost state, carried on the state broadcast for
  -- the same reason finalLap is: it is what makes a client that joined (or
  -- reconnected) DURING a ghost see it, instead of only clients that happened to
  -- be listening when the one-shot event went out.
  if type(data.ghosts) == 'table' then ghost.applyRoster(data.ghosts) end
  -- Whether THIS client is on the entry list, read off its own driver row.
  local wasJoined = joined
  local myId = localServerId()
  if myId and type(data.drivers) == 'table' then
    for _, d in ipairs(data.drivers) do
      if tonumber(d.id) == myId then
        joined = d.joined == true
        -- ...and whether we turned up in the middle of somebody else's session.
        -- ghostUpdate acts on this: a car that is not in the race is a ghost to
        -- the cars that are.
        isBystander = d.bystander == true
        break
      end
    end
  end

  -- Fastest lap of the session. The leaderboard paints that driver's time gold
  -- for everyone; the driver who set it is told, once, on the notice channel the
  -- reset and joker rulings already use.
  --
  -- Keyed on the TIME as well as the holder. Keying on the holder alone meant a
  -- driver who beat their own fastest lap was told nothing -- the pid had not
  -- changed -- which is the one case where the driver is most likely to want to
  -- know they did it. Every state broadcast carries the standing best, so what
  -- distinguishes "they set a new one" from "this is the same one again" is the
  -- time moving, and that is what is compared.
  local bestPid  = tonumber(data.bestLapPid)
  local bestTime = tonumber(data.bestLapTime)
  if bestPid ~= lastBestLapPid or bestTime ~= lastBestLapTime then
    if bestPid and myId and bestPid == myId and bestTime then
      local mins = math.floor(bestTime / 60)
      pushNotice('fastest',
        string.format('FASTEST LAP: %d:%06.3f', mins, bestTime - mins * 60))
    end
    lastBestLapPid  = bestPid
    lastBestLapTime = bestTime
  end

  local newPhase = data.phase or 'waiting'
  local phaseChanged = newPhase ~= phase
  if newPhase ~= phase then
    phase = newPhase
    -- Any session transition re-arms local detection from a clean slate:
    -- lap 1 starts at the line, from the grid, for both kinds of session.
    resetLapTracking()
    -- Qualifying opens on the out lap, so say so at the moment the lights go
    -- out. The lap readout carries it for the whole lap; this is the one push
    -- that arrives while the driver is still stationary and reading.
    if newPhase == 'qualifying' and qualiOutLap then
      pushNotice('session',
        'OUT LAP: this lap is NOT timed. Timing starts as you cross the line.')
    end
    -- Leaving the start procedure must never leave a car frozen.
    if newPhase ~= 'grid' and newPhase ~= 'countdown' then releaseGridHold('race') end
    if newPhase ~= 'grid' and newPhase ~= 'countdown' and not sessionRunning() then
      gridSlot = nil
    end
  end
  totalLaps = data.totalLaps or totalLaps

  -- State broadcasts arrive several times a second while racing; only re-push
  -- the route/entry state to the UI when something in it actually moved.
  -- (resetLapTracking already pushes on a phase change.)
  if not phaseChanged and joined ~= wasJoined then pushRouteState() end
  guihooks.trigger('RaceManagerUpdate', data)
end

-- Server assigned this client a starting slot (Generate Grid, or an admin
-- editing the order). Stand the car on it and hold it for the countdown.
local function onGridAssign(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local slot = tonumber(data.slot)
  applyGridSlot(slot and math.floor(slot) or nil, tonumber(data.order), tonumber(data.count))
end

-- A ghost started or ended on some client. This is the one-shot companion to the
-- roster carried on the state broadcast, and it exists for latency alone: the
-- state push runs three times a second, and a third of a second is long enough
-- for a car to teleport into a pack and be hit before anyone's client had been
-- told it was a ghost. The roster is what makes the state RIGHT; this is what
-- makes it right IN TIME.
--
-- Our own ghost is ignored here. We applied it locally the instant the reset
-- fired, without waiting for this round trip, and only we can decide when it
-- ends.
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

-- The server has seen this car off its grid slot and is pulling it back. The
-- server owns the hold; this is it exercising that, and it arrives whether or
-- not the local guard did its job - which is the point of having it.
local function onHoldCorrect(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then data = {} end
  if not holdWanted then return end
  -- The server may know the slot coordinates when this client's view of them is
  -- stale (a layout loaded after this client joined). Prefer what it sends.
  if tonumber(data.x) and tonumber(data.y) and tonumber(data.z) then
    -- The SLOT, not the anchor: this is a drop position, and the car has to be
    -- allowed to settle onto it exactly as it did when it was first placed.
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

-- --- Module 1: forced spectator mode (server -> client) --------------------
local function onForceSpectate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then data = {} end
  enterSpectator(data.reason and tostring(data.reason) or nil,
    data.source and tostring(data.source) or 'race')
end

local function onReleaseSpectate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then data = {} end
  local source = data.source and tostring(data.source) or nil
  local order, count = tonumber(data.order), tonumber(data.count)
  -- The server snapshots the participant list before releasing anyone and hands
  -- each driver its place in it, so the field respawns as a sequence.
  if spectatorLock then
    releaseSpectator(source, order, count)
    return
  end
  -- Nothing of OURS to put back -- this driver never lost their car, because
  -- they were still running when the session ended. They are released all the
  -- same, and the rest of the field is about to materialise around them, so
  -- they get the placement ghost for the same window everyone else does.
  --
  -- Without this the only cars ghosted through an end-of-session respawn were
  -- the ones being respawned. A driver sitting on track was the one solid
  -- object in the middle of a field landing on top of them.
  if queueFieldPlacement then
    queueFieldPlacement({ order = order, count = count })
  end
end

-- --- Module 4: the server refused this client's vehicle/setup --------------
local function onVehicleRejected(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  local msg = (ok and type(data) == 'table' and data.message)
    and tostring(data.message) or 'Vehicle/Setup not allowed in this session.'
  local detail = (ok and type(data) == 'table' and data.detail) and tostring(data.detail) or ''
  guihooks.trigger('RaceManagerVehicleError', { message = msg, detail = detail })
  pushNotice('vehicle', msg)
  log('W', 'raceManager', 'Vehicle rejected by the server: ' .. msg .. ' (' .. detail .. ')')
end

-- Server confirmed (or refused) a Whitelist Current Vehicle capture.
-- Server ruled on an alias change. Surfaced as a notice so the admin always
-- gets an answer -- the name applied, or why it did not.
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
  -- GO (0) or an aborted countdown (-1): the grid hold ends here. This is the
  -- authoritative release - everyone's car is let go by the same broadcast, so
  -- nobody can creep away early or be held a moment longer than their rivals.
  local count = tonumber(data.count)
  if count and count <= 0 then releaseGridHold('race') end
  guihooks.trigger('RaceManagerCountdown', data)
end

-- Map-filtered layout list from the server (includes checkpoint arrays so the
-- UI can draw the 2D track preview before anything is loaded).
local function onLayoutList(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    log('E', 'raceManager', 'RM_Layouts: undecodable payload: ' .. tostring(rawData):sub(1, 120))
    return
  end
  -- An empty list can arrive JSON-encoded as {} instead of []; hand the UI a
  -- real array either way so its iteration/preview code never breaks.
  if type(data.layouts) ~= 'table' or #data.layouts == 0 then data.layouts = {} end
  log('I', 'raceManager', 'RM_Layouts: ' .. #data.layouts .. ' layout(s) for map ' .. tostring(data.map))
  guihooks.trigger('RaceManagerLayouts', data)
end

-- Cup standings and scoring rules, on their own channel.
--
-- A pure relay, and it stays one: the cup is decided entirely on the server,
-- this client owns nothing about it and caches nothing. There is no physics
-- here to police and no local rule to mirror, which is exactly why the cup
-- needs none of the machinery the derby needs.
local function onCupUpdate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    log('E', 'raceManager', 'RM_CupUpdate: undecodable payload')
    return
  end
  if not fromCurrentServer(data) then return end
  -- Empty arrays can arrive JSON-encoded as {} rather than []; hand the UI a
  -- real array either way so an ng-repeat never sees an object.
  for _, key in ipairs({ 'standings', 'presets', 'bonuses', 'roster', 'connected',
                         'racePoints', 'derbyPoints', 'qualiPoints' }) do
    if type(data[key]) ~= 'table' or #data[key] == 0 then data[key] = {} end
  end
  guihooks.trigger('RaceManagerCup', data)
end

-- Server pushed a layout to everyone: purge the current track state, then
-- spawn the saved gates immediately.
local function onApplyLayout(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' or type(data.checkpoints) ~= 'table' then
    log('E', 'raceManager', 'RM_ApplyLayout: undecodable payload: ' .. tostring(rawData):sub(1, 120))
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
      -- A gate saved before sizes were per-gate has none of its own; it is
      -- given the layout's stored default here, so it keeps exactly the size it
      -- was drawn with and never depends on a live setting again.
      if what ~= 'start position' then
        out[i].width  = clampWidth(tonumber(cp.width)  or data.width  or checkpointWidth)
        out[i].height = clampHeight(tonumber(cp.height) or data.height or checkpointHeight)
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
  end
  -- Branching routes, resolved into the per-slot lookup the crossing code reads.
  -- Done ONCE, here, rather than searched per frame: the gate for a slot has to
  -- be found sixty times a second and this is what makes that one table index.
  local lanes, bySlot = {}, {}
  if type(data.branches) == 'table' then
    for _, b in ipairs(data.branches) do
      local id = type(b.id) == 'string' and b.id or nil
      if id and type(b.gates) == 'table' then
        local slots = {}
        for _, g in ipairs(b.gates) do
          local slot = tonumber(g.slot)
          local x, y, z = tonumber(g.x), tonumber(g.y), tonumber(g.z)
          if slot and x and y and z and slot >= 1 and slot <= #cps then
            local gate = {
              x = x, y = y, z = z,
              hx = tonumber(g.hx) or 0, hy = tonumber(g.hy) or 1,
              width  = clampWidth(tonumber(g.width)  or data.width  or checkpointWidth),
              height = clampHeight(tonumber(g.height) or data.height or checkpointHeight),
            }
            if g.oneWay == true then gate.oneWay = true end
            slots[math.floor(slot)] = gate
          end
        end
        if next(slots) then
          lanes[#lanes + 1] = { id = id, name = tostring(b.name or id), gates = b.gates }
          bySlot[id] = slots
        end
      end
    end
  end

  clearTrackState('applying layout "' .. tostring(data.name) .. '"')
  route      = cps
  jokerRoute = jokerCps
  pitRoute   = pits
  startPositions = starts
  branch.list   = lanes
  branch.bySlot = bySlot
  branch.gridOffLine = data.gridOffLine == true
  checkpointWidth  = clampWidth(data.width or checkpointWidth)
  checkpointHeight = clampHeight(data.height or checkpointHeight)
  pointToPoint     = data.pointToPoint == true
  resetLapTracking()
  editorMsg('Loaded layout "' .. tostring(data.name) .. '" ('
    .. (pointToPoint and 'point to point, ' or '') .. #route .. ' gates'
    .. (#jokerRoute > 0 and (' + ' .. #jokerRoute .. ' joker') or '')
    .. (#startPositions > 0 and (', ' .. #startPositions .. ' grid slots') or '') .. ')')
  log('I', 'raceManager', 'Applied server layout "' .. tostring(data.name)
    .. '" with ' .. #route .. ' checkpoints, ' .. #jokerRoute .. ' joker gates and '
    .. #startPositions .. ' start positions')
end

-- The server refused an overwrite that would have emptied part of a layout. The
-- UI asks the admin and re-sends confirmed if that is what they meant.
local function onSaveHeld(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local lost = type(data.lost) == 'table' and data.lost or {}
  local label = {
    joker = 'joker gates', pits = 'pit stalls',
    startPositions = 'start positions', branches = 'lanes',
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

-- Server ordered a full purge (server startup, pre-layout-load, or an
-- explicit clear): delete every checkpoint and its 3D poles right now.
local function onClearTrack(rawData)
  local reason = 'server'
  local ok, data = pcall(jsonDecode, rawData)
  if ok and type(data) == 'table' and data.reason then reason = tostring(data.reason) end
  clearTrackState('server: ' .. reason)
end

-- Server replied to a login attempt: forward the success flag to the UI, which
-- reveals the admin controls on success and shows a rejection otherwise.
local function onLoginResult(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  -- Remember it here as well as telling the UI: the UI's copy dies with the
  -- app, this one outlives the pause menu.
  isAdmin = data.success == true
  guihooks.trigger('RaceManagerAuth', { success = isAdmin })
  log('I', 'raceManager', 'Login result: ' .. tostring(isAdmin))
end

-- Server broadcast that an admin rotated the master password (never the value).
local function onPasswordChanged(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  local by = (ok and type(data) == 'table' and data.changedBy) and tostring(data.changedBy) or 'an admin'
  editorMsg('Admin password changed by ' .. by)
  -- Dedicated channel so the admin bar can confirm the change even when the
  -- editor panel (where editorMsg is shown) isn't open.
  guihooks.trigger('RaceManagerPasswordChanged', { by = by })
  log('I', 'raceManager', 'Master password changed by ' .. by)
end

-- ---------------------------------------------------------------------------
-- Admin authentication (called by the UI app)
-- ---------------------------------------------------------------------------
-- Submit the master password to the server. The reply (RM_LoginResult) drives
-- the UI show/hide of the admin controls via the RaceManagerAuth guihook.
function M.login(password)
  if inMultiplayer() then
    TriggerServerEvent('RM_Login', jsonEncode({ password = tostring(password or '') }))
  else
    -- Offline: no server to authenticate against, but the checkpoint editor is
    -- meant to stay usable single-player, so grant local admin outright. Recorded
    -- here too, so the offline editor also survives the pause menu.
    isAdmin = true
    guihooks.trigger('RaceManagerAuth', { success = true, offline = true })
    pushRouteState()
  end
end

-- Drop admin rights (UI "Log out" / back-to-login). Offline there is no server
-- session to clear, so this is purely a UI-side action there.
function M.logout()
  -- Clear the durable copy FIRST. If it stayed set, the next route push would
  -- hand admin straight back to the UI that just logged out.
  isAdmin = false
  if inMultiplayer() then TriggerServerEvent('RM_Logout', '') end
  pushRouteState()
end

-- Authenticated admin rotates the master password on the server.
function M.changePassword(newPassword)
  newPassword = tostring(newPassword or '')
  if newPassword == '' then
    editorMsg('Enter a new password first')
    return
  end
  if inMultiplayer() then
    TriggerServerEvent('RM_ChangePassword', jsonEncode({ password = newPassword }))
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

-- Admin sets or clears a driver's display alias (presentation only). Passed
-- straight through to the server, which validates it and owns the result; this
-- client keeps no alias state of its own and never uses one as a key.
function M.setAlias(targetId, alias)
  -- BeamMP player ids are ZERO-BASED: the first player on the server is id 0.
  -- Rejecting `<= 0` therefore throws away a perfectly real driver, which is
  -- exactly what made Set do nothing at all for the first player to join --
  -- the row rendered, the click fired, and the command died here. Only a
  -- missing/non-numeric id or a negative one is invalid.
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
  -- Logged on the way out so the game console (~) shows the attempt. If this
  -- line appears and no result notice follows, the request left this client and
  -- the server plugin did not answer -- which points at the server side, not
  -- the app.
  log('I', 'raceManager', string.format('setAlias -> driver %d = "%s"', targetId, tostring(alias or '')))
  TriggerServerEvent('RM_SetAlias', jsonEncode({
    target = targetId,
    alias  = tostring(alias or ''),
  }))
end

function M.setTotalLaps(n)
  n = math.floor(tonumber(n) or 0)
  if n < 1 then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_SetTotalLaps', jsonEncode({ laps = n }))
  end
end

-- Module 1: how many vehicle resets each driver gets this session.
-- A negative value (or nil) means unlimited; 0 forbids resets entirely.
function M.setMaxResets(n)
  n = math.floor(tonumber(n) or -1)
  if n < 0 then n = -1 end
  if inMultiplayer() then
    TriggerServerEvent('RM_SetMaxResets', jsonEncode({ maxResets = n }))
  else
    maxResets = n
    pushRouteState()
  end
end

-- Module 1: what a legal reset does while racing - repair in place (default)
-- or respawn at the last checkpoint the driver crossed.
function M.setResetMode(mode)
  mode = (tostring(mode or 'inplace') == 'checkpoint') and 'checkpoint' or 'inplace'
  if inMultiplayer() then
    TriggerServerEvent('RM_SetResetMode', jsonEncode({ mode = mode }))
  else
    resetMode = mode
    pushRouteState()
  end
end

-- Module 2: arm/disarm the joker lap requirement for the next race.
function M.setJokerEnabled(enabled)
  enabled = enabled and true or false
  if inMultiplayer() then
    TriggerServerEvent('RM_SetJokerEnabled', jsonEncode({ enabled = enabled }))
  else
    jokerEnabled = enabled
    pushRouteState()
  end
end

-- --- Race entry (opt-in) ---------------------------------------------------
-- Players opt into the race instead of every session on the server being
-- assumed to be racing. Admins switch the mode between opt-in and everyone.
function M.joinRace(join)
  join = (join == nil) and true or (join and true or false)
  if inMultiplayer() then
    TriggerServerEvent('RM_JoinRace', jsonEncode({ join = join }))
  else
    joined = join
    pushRouteState()
  end
end

function M.leaveRace() M.joinRace(false) end

function M.setEntryMode(mode)
  mode = (tostring(mode or 'join') == 'all') and 'all' or 'join'
  if inMultiplayer() then
    TriggerServerEvent('RM_SetEntryMode', jsonEncode({ mode = mode }))
  else
    entryMode = mode
    pushRouteState()
  end
end

-- --- Qualifying rules ------------------------------------------------------
-- Ghost mode: rivals stop being obstacles during qualifying.
function M.setGhostQuali(enabled)
  enabled = enabled and true or false
  if inMultiplayer() then
    TriggerServerEvent('RM_SetGhostQuali', jsonEncode({ enabled = enabled }))
  else
    ghostQuali = enabled
    pushRouteState()
  end
end

-- Session length: a lap count, a time limit, or neither (0 = unlimited).
function M.setQualiLimits(laps, seconds)
  laps    = math.max(math.floor(tonumber(laps) or 0), 0)
  seconds = math.max(math.floor(tonumber(seconds) or 0), 0)
  if inMultiplayer() then
    TriggerServerEvent('RM_SetQualiLimits', jsonEncode({ laps = laps, seconds = seconds }))
  end
end

-- --- Starting grid ---------------------------------------------------------
-- How the server fills the grid: quali order, a random draw, or an order the
-- admin sets by hand.
function M.setGridMode(mode)
  mode = tostring(mode or 'quali')
  -- Every mode the server accepts has to be named here too. This list was left
  -- behind when reverse grids were added, so pressing Reverse normalised to
  -- 'quali' on the way out and the panel lit Quali back up -- a dead button that
  -- looked like it had picked the wrong one.
  if mode ~= 'random' and mode ~= 'custom' and mode ~= 'reverse' then mode = 'quali' end
  if inMultiplayer() then
    TriggerServerEvent('RM_SetGridMode', jsonEncode({ mode = mode }))
  end
end

-- Custom grid: put one driver on one slot (the rest shuffle around them).
function M.setDriverGridSlot(pid, slot)
  -- BeamMP player ids are ZERO-BASED, so `pid <= 0` threw away whoever joined
  -- the server first -- the box accepted a slot number and nothing was ever
  -- sent. Slots themselves genuinely are 1-based (slot 1 is pole), so that
  -- half of the guard stays. The server accepts target 0 either way.
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

function M.endRace()
  if inMultiplayer() then TriggerServerEvent('RM_EndRace', '') end
end

function M.resetLeaderboard()
  if inMultiplayer() then TriggerServerEvent('RM_ResetLeaderboard', '') end
end

-- Clear the server-side results cache (deletes the saved .txt result files).
function M.clearResults()
  if inMultiplayer() then TriggerServerEvent('RM_ClearResults', '') end
end

-- ---------------------------------------------------------------------------
-- Cup / series points (called by the UI app) -- all go to the server
-- ---------------------------------------------------------------------------
-- Thin relays with no local state behind them. The cup is scored, stored and
-- decided entirely on the server; this client only forwards the admin's
-- intention and renders whatever comes back on RM_CupUpdate.
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

-- `target` picks which points table the preset fills: 'race' (the default) or
-- 'derby'. A cup can be all races, all derbies or a mixture, and the two score
-- on separate tables.
function M.cupSetPreset(preset, target)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetPreset', jsonEncode({
      preset = tostring(preset or ''),
      target = (tostring(target or 'race') == 'derby') and 'derby' or 'race',
    }))
  end
end

-- A points table arrives from the app as "30,27,25,..." and goes up as an
-- array. A comma-separated string rather than a structure because every other
-- command in this bridge takes numbers and strings, and the app would otherwise
-- have to hand-build a Lua table literal.
--
-- Only the shape is fixed here. Range clamping stays on the server, which has
-- to do it anyway for anything arriving from a client it did not write.
local function cupParsePoints(csv)
  local out = {}
  for field in tostring(csv or ''):gmatch('[^,]+') do
    local n = tonumber(field)
    out[#out + 1] = n and math.floor(n) or 0
  end
  return out
end

-- Each of these sends ONE part of the scoring rules. The server replaces just
-- the part it is given, so a panel that edits the bonus values never has to
-- resend the position table it did not touch.
function M.cupSetRacePoints(csv)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetScoring', jsonEncode({ race = cupParsePoints(csv) }))
  end
end

-- Derbies score on a table of their own. An empty string switches derby scoring
-- off, exactly as it does for qualifying.
function M.cupSetDerbyPoints(csv)
  if inMultiplayer() then
    TriggerServerEvent('RM_CupSetScoring', jsonEncode({ derby = cupParsePoints(csv) }))
  end
end

-- An empty string is how qualifying points are switched OFF: it sends an empty
-- table, and on the server an empty table is what "qualifying does not score"
-- means. One representation, no separate flag to disagree with it.
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

-- What a DNF is worth: 'none', 'classified' (its place in the final order) or
-- 'held' (the place it was running in when it stopped).
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
-- Assign a connected player to a roster entry, which is how a driver gets
-- their name and their accumulated points back after a reconnect. An admin has
-- to do this: BeamMP issues a fresh random guest name on every join, so nothing
-- on either side can tell a returning regular from a stranger.
--
-- entryId 0 unassigns.
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
-- Correcting a cup by hand: a penalty, a driver who dropped out through no
-- fault of their own, a race administered badly. Keyed on the CUP ENTRY, not on
-- a session id, so an adjustment lands on the driver rather than on whoever
-- currently holds that connection.
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
    TriggerServerEvent('RM_RequestState', '')
    TriggerServerEvent('RM_RequestLayouts', '')
    TriggerServerEvent('RM_CupRequestState', '')
  else
    -- Not on a BeamMP server: still push a state so the UI renders, and the
    -- editor remains fully usable for building circuits offline. Grant local
    -- admin so the (offline) editor controls are visible without a password.
    -- The flag has to be set here too, not just announced to the UI: every
    -- later route push carries it, and a push saying "not admin" would take the
    -- offline editor's own controls away again on the next gate placed.
    isAdmin = true
    guihooks.trigger('RaceManagerUpdate', { phase = 'waiting', raceTime = 0, totalLaps = totalLaps, drivers = {} })
    guihooks.trigger('RaceManagerAuth', { success = true, offline = true })
    log('W', 'raceManager', 'Racing is multiplayer-only; the checkpoint editor works offline')
  end
end

-- Server -> client event wiring. Handlers are reached through a GLOBAL
-- dispatch table that every (re)load of this extension overwrites: older
-- BeamMP builds have an AddEventHandler with no matching remove, so registering
-- the local closures directly left every previous instance's handlers alive
-- across a reload - a stale instance pushing its own (empty) state to the UI
-- between the live instance's pushes is one way the UI ends up flickering
-- between two states. With the indirection the bridge binds to BeamMP exactly
-- once per game session and always dispatches into the newest instance's
-- handlers.
--
-- Recent BeamMP builds also key handlers by a SOURCE and replace (rather than
-- stack) a re-registration from the same source. That source defaults to
-- whatever debug.getinfo() makes of the calling file, so it is passed
-- explicitly below: with a fixed source the binding is idempotent on those
-- builds even if the global guard is lost, and older builds simply ignore the
-- extra argument.
local HANDLER_SOURCE = 'raceManager'
local DISPATCH = {
  RM_Update          = onServerUpdate,
  RM_Countdown       = onServerCountdown,
  RM_Layouts         = onLayoutList,
  RM_ApplyLayout     = onApplyLayout,
  RM_SaveHeld        = onSaveHeld,
  RM_ClearTrack      = onClearTrack,
  RM_LoginResult     = onLoginResult,
  RM_PasswordChanged = onPasswordChanged,
  -- Module 1: forced spectator mode (used by racing and, separately, by derby)
  RM_ForceSpectate   = onForceSpectate,
  RM_ReleaseSpectate = onReleaseSpectate,
  -- Module 4: garage list enforcement feedback
  RM_VehicleRejected = onVehicleRejected,
  RM_GarageResult    = onGarageResult,
  RM_AliasResult     = onAliasResult,
  -- Starting grid: the server hands out slots, this client places the car.
  RM_GridAssign      = onGridAssign,
  -- Reset ghosting: someone's car went intangible (or came back).
  RM_Ghost           = onGhost,
  -- Grid hold: the server pulling a car back onto its slot.
  RM_HoldCorrect     = onHoldCorrect,
  -- Cup / series points
  RM_CupUpdate       = onCupUpdate,
  -- Demo Derby module
  RM_DerbyUpdate     = onDerbyUpdate,
  RM_DerbyLayouts    = onDerbyLayoutList,
  RM_DerbyGridAssign = onDerbyGridAssign,
  RM_DerbyCountdown  = onDerbyCountdown,
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

function M.onExtensionLoaded()
  bindServerHandlers()
  log('I', 'raceManager', 'Race Manager client bridge loaded (build ' .. RM_BUILD
    .. ', multiplayer=' .. tostring(inMultiplayer()) .. ')')
end

-- Everything this client enforces locally, switched off. Called both when the
-- extension is unloaded and when the BeamMP session ends (see below), because
-- every one of these is a rule the SERVER owns and only this client can apply -
-- with no server left to lift them they would otherwise stay applied.
local function resetToIdle(reason)
  phase = 'waiting'
  -- The server drops authenticatedPlayers on disconnect, so a session that has
  -- ended takes the admin rights with it. Forget them here or the next server
  -- would inherit an admin flag it never granted.
  isAdmin = false
  editorOpen = false
  clearTrackState(reason)
  releaseSpectator(nil)
  -- No more update ticks are coming, so anything the placement queue still owes
  -- this driver -- their car, their camera, their collisions -- is settled now.
  flushFieldPlacement()
  releaseGridHold()
  clearGhostReasons()
  setResetInputsBlocked(false)   -- never leave the reset keys dead after unload
  -- Same rule for the two filters this mod added. Unloading with the driving or
  -- the node grabber still filtered off would leave the player in a car they
  -- cannot drive with nothing on screen explaining why -- and nothing left
  -- loaded that could give it back.
  spectate.setInputsBlocked(false)
  spectate.setGrabberBlocked(false)
  holdWanted = nil               -- nothing is meant to be held any more
  maxResets       = -1
  resetsUsed      = 0
  resetMode       = 'inplace'
  lastGate        = nil
  selfTeleport.left = 0
  blockNoticeLeft = 0
  jokerEnabled    = false
  pitRoute        = {}
  pit.active      = false
  pit.left        = 0
  pit.repaired    = false
  pit.cooldown    = 0
  pit.promptLeft  = 0
  -- clearGhostReasons above has already swept every car in the world clean, so
  -- this is only dropping our record of what we ghosted -- left set, the next
  -- stop would think it was already ghosted and never ghost at all.
  pit.ghostVeh    = nil
  pit.ghostSent   = false
  editorTarget    = 'main'
  lastReportedSig = nil
  gridSlot        = nil
  joined          = false
  finalLap        = false
  ghostQuali      = false
  -- Same purge for the isolated derby module: markers and warnings must not
  -- survive into the next session.
  derbyState.phase    = 'idle'
  derbyState.boundary = {}
  derbyState.boundaryMode = 'polygon'
  derbyState.shape    = nil
  derbyState.editorOpen = false
  -- Not invalidation (the empty table above already is that) -- this drops the
  -- cache's reference to the arena that has just gone, so it can be collected.
  derbyState.draw     = nil
  derbyState.starts   = {}
  derbyState.slot     = nil
  derbyState.out      = false
  derbyMaxResets  = -1
  derbyResetsUsed = 0
  derbyClearWarnings()
  -- clearTrackState pushed a state part-way through the purge, while the
  -- regulation values below it were still the old ones. Push again now that
  -- everything is actually idle, or the UI keeps showing the allowance and the
  -- entry status of a session that has ended.
  pushRouteState()
end

function M.onExtensionUnloaded()
  -- The extension stays resident across sessions (manual unload mode), so an
  -- explicit purge here is what stops checkpoints leaking into the next one.
  resetToIdle('extension unloaded')
end

-- ---------------------------------------------------------------------------
-- BeamMP session lifecycle
-- ---------------------------------------------------------------------------
-- Leaving a BeamMP server used to leave this client mid-race forever. Every
-- regulation the server owns is APPLIED here - the reset keys are switched off
-- at the input filter, the car is frozen on its grid slot, a finished or
-- eliminated driver is held in freecam - and all of them are lifted by a
-- server broadcast that is never coming once the session is gone. A driver who
-- disconnected mid-race was dropped back into singleplayer with a dead reset
-- key and, if they had finished or been knocked out, no car and a camera that
-- reasserted freecam every second.
--
-- BeamMP hooks every extension when a session starts and ends, so that is the
-- signal to purge. v4.22.0 renamed those hooks with an onBeamMP* prefix
-- (onServerLeave -> onBeamMPServerLeave, runPostJoin -> onBeamMPPostJoin);
-- both names are registered, so whichever BeamMP build is installed, the mod
-- hears it. Only one of the pair fires on any given build, and a second purge
-- would be harmless anyway.
local function onSessionLeave()
  log('I', 'raceManager', 'BeamMP session ended: clearing local race state')
  resetToIdle('BeamMP session ended')
end

M.onBeamMPServerLeave = onSessionLeave   -- BeamMP v4.22.0+
M.onServerLeave       = onSessionLeave   -- BeamMP v4.21.1 and earlier

-- Joining is the other half: the extension can be mounted and loaded before
-- BeamMP's own network extension is ready, in which case onExtensionLoaded
-- bound nothing and the mod would sit deaf for the whole session. Binding again
-- here closes that race (the bind is guarded, and on builds that key handlers
-- by source it is idempotent regardless). The state request is deferred a beat
-- rather than sent immediately, because the launcher socket is still being
-- brought up as this hook runs.
local function onSessionJoin()
  bindServerHandlers()
  joinRequestLeft = 1.0
  log('I', 'raceManager', 'BeamMP session joined: handlers bound, requesting state')
end

M.onBeamMPPostJoin = onSessionJoin       -- BeamMP v4.22.0+
M.runPostJoin      = onSessionJoin       -- BeamMP v4.21.1 and earlier
end

return M
