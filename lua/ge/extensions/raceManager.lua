-- Race Manager - client GE extension (BeamMP bridge + checkpoint editor)
--
-- Multiplayer-only for racing. The BeamMP server (server/RaceManager/main.lua)
-- owns the session state; this extension does what only a client can do:
--   1. Checkpoint editor: place gate-style checkpoints at the local vehicle's
--      position AND heading. Each checkpoint is a FLAT RECTANGLE standing
--      perpendicular to the travel direction — a width (lateral span) by a
--      height (vertical extent, so high banking still gets covered). Both are
--      adjustable globally and per checkpoint from the UI.
--   2. Detect the LOCAL vehicle crossing each gate, in order, by intersecting
--      the frame-to-frame movement segment with that rectangle (the server has
--      no physics access). The last checkpoint placed is the start/finish line;
--      completing the checkpoint sequence and crossing it again scores a lap,
--      which is timed locally and reported upstream (RM_QualiLap during
--      qualifying, RM_Lap in race).
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
  ROUTE_FILE = 'settings/raceManager/route.json',
}

-- Build stamp, pushed to the UI. Must match the server plugin and app.js -- see
-- the note in main.lua for why a mismatch is otherwise invisible.
local RM_BUILD = '0.5.4'

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

-- Once the allowance is spent the reset INPUTS themselves are switched off via
-- BeamNG's input action filter, so pressing R/Insert does nothing at all — the
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
local entryMode = 'join'         -- 'join' (opt-in) | 'all' (everyone races)
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

-- Forced spectator mode (Module 1). Non-nil while this client is out of the
-- session: it holds the source ('race' or 'derby') that imposed the penalty, so
-- the isolated derby module and the racing state machine can never release each
-- other's spectators.
local spectatorLock   = nil
local spectatorReason = nil
local spectatorRecheck = 0       -- seconds until the camera is re-asserted

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
local function gateDims(wp)
  return clampWidth(wp.width   or checkpointWidth),
         clampHeight(wp.height or checkpointHeight)
end

-- ---------------------------------------------------------------------------
-- UI push helpers
-- ---------------------------------------------------------------------------
-- The server needs to know how big this track's grid is so it can warn when
-- there are more drivers than start positions, but it has no way to see the
-- placements. Report the count whenever it actually changes — placing a slot,
-- deleting one, loading a layout — and never more often than that.
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
  TriggerServerEvent('RM_StartPositionCount',
    jsonEncode({ count = n, positions = positions }))
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
    jokerRoute   = jokerRoute,
    jokerNext    = jokerArmed,
    jokerTaken   = jokerTaken,
    jokerLap     = jokerLapUsed,
    jokerEnabled = jokerEnabled,
    editorTarget = editorTarget,
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
-- installed alongside this one — two copies alternating broadcasts is exactly
-- what made every UI element flicker between two states on each tick — so
-- unstamped payloads are dropped (and the problem reported once).
local RM_PROTOCOL = 2
local staleServerWarned = false
local function fromCurrentServer(data)
  if type(data) == 'table' and data.rmProtocol == RM_PROTOCOL then return true end
  if not staleServerWarned then
    staleServerWarned = true
    pushNotice('server', 'Ignoring broadcasts from an outdated Race Manager server plugin — '
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
-- rectangle's plane in the FORWARD direction (so a reversing car can never
-- score one) and the intersection point lands inside the width/height
-- half-extents. Sampling the segment rather than the position means the test
-- never tunnels, no matter how fast the car is going or how thin the gate is.
-- Dimensions are passed in so the same math can be unit-tested headlessly
-- (see tests/gate_test.lua); the live caller feeds gateDims(wp).
local function rectCrossesGate(wp, prev, cur, w, h)
  local fx, fy = wp.hx, wp.hy

  -- Signed distance to the gate plane before and after this frame's movement.
  local dPrev = (prev.x - wp.x) * fx + (prev.y - wp.y) * fy
  local dCur  = (cur.x  - wp.x) * fx + (cur.y  - wp.y) * fy
  -- Forward crossing only: behind the plane last frame, on/past it now.
  if not (dPrev < 0 and dCur >= 0) then return false end

  local t  = dPrev / (dPrev - dCur)
  local ix = prev.x + (cur.x - prev.x) * t
  local iy = prev.y + (cur.y - prev.y) * t
  local iz = prev.z + (cur.z - prev.z) * t
  local lateral = (ix - wp.x) * fy - (iy - wp.y) * fx
  if math.abs(lateral) > w * 0.5 then return false end
  if math.abs(iz - wp.z) > h * 0.5 then return false end
  return true
end

-- Live wrapper: resolve the gate's effective rectangle dimensions, then run the
-- crossing test. Keeps callers unchanged (segmentCrossesGate(wp, a, b)).
local function segmentCrossesGate(wp, prev, cur)
  local w, h = gateDims(wp)
  return rectCrossesGate(wp, prev, cur, w, h)
end

-- ---------------------------------------------------------------------------
-- Lap logic
-- ---------------------------------------------------------------------------
-- One session is running (the lights are out and laps count). Qualifying and
-- racing are the same thing here on purpose: both start from the grid, both
-- count a lap per completed circuit of the route, and both report it upstream on
-- the same event. Qualifying used to have detection of its own -- an out-lap
-- before the clock started, and no defined starting point because there was no
-- grid -- which is why a three-lap session took five or six laps to get through.
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
  blockNoticeLeft = 0   -- a fresh session may report its first blocked attempt at once
  -- Telemetry restarts with the session; report immediately on the next frame
  -- so the leaderboard has a distance for this driver from the first moments.
  progressLeft = 0
  -- Cars launch from the grid at the line, so the first target is checkpoint 1
  -- and the clock is already running — for a qualifying session exactly as much
  -- as for a race. Outside a running session the start/finish line is armed, so
  -- a driver pottering about before the lights still gets sensible gate colours.
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
-- removes them from the world on the next update tick — nothing else holds a
-- reference to them. Runs before any new layout is applied and whenever the
-- server broadcasts RM_ClearTrack, so ghost checkpoints from an earlier
-- session cannot survive.
local function clearTrackState(reason)
  route        = {}
  jokerRoute   = {}
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
  pushRouteState()
  log('I', 'raceManager', 'Track state cleared (' .. tostring(reason or 'local') .. ')')
end

-- UI/console entry point: purge locally and, when on a BeamMP server, ask the
-- server to broadcast the purge to every client.
function M.clearTrackState()
  clearTrackState('ui request')
  if inMultiplayer() then TriggerServerEvent('RM_ClearTrackState', '') end
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

  -- ONE report, for both kinds of session. The server knows which one is
  -- running and scores the lap accordingly (best lap in qualifying, running
  -- order and laps led in a race); the client's job is only to say "that was a
  -- lap, and it took this long". The separate RM_QualiLap channel this replaced
  -- is what let qualifying's lap counting drift away from the race's.
  if not sessionRunning() then return end
  if inMultiplayer() then
    TriggerServerEvent('RM_Lap', jsonEncode({ lapTime = lapTime }))
  end
  announceLap(localLap)
  log('I', 'raceManager', string.format('Lap %d done: %.3fs (%s)',
    localLap, lapTime, phase))
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
--   * Lap 1 restriction — any joker attempt started on lap 1 is invalidated
--     outright (progress thrown away, nothing reported to the server).
--   * Once per race — a completed joker route is reported exactly once; every
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
    pushNotice('joker', 'JOKER LAP NOT ALLOWED ON LAP 1 — attempt invalidated')
    log('W', 'raceManager', 'Joker route attempted on lap 1: attempt invalidated')
    pushRouteState()
    return
  end

  if jokerTaken then
    jokerArmed = 1
    pushNotice('joker', 'Joker Lap already taken — this run does not count')
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

local function checkGates()
  if spectatorLock then return end     -- out of the session: no more timing
  if #route == 0 and #jokerRoute == 0 then return end
  if phase ~= 'qualifying' and phase ~= 'racing' then return end
  local veh, pos = sampledVehicle()
  if not veh or not pos then return end
  if prevPos then
    local wp = route[armedWp]
    if wp and segmentCrossesGate(wp, prevPos, pos) then
      lastGate = wp   -- the "Last Checkpoint" reset mode respawns here
      if armedWp >= #route then
        onLapCompleted()
        armedWp = 1
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
  })
end

-- ---------------------------------------------------------------------------
-- Live position telemetry
-- ---------------------------------------------------------------------------
-- The server decides the running order but has no physics access, so the third
-- tie-break metric — how far a car is from the next checkpoint — can only be
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
  local wp = route[armedWp]
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
-- table first — under whichever key the build carries it — and the filename stem
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
-- signature below without the car itself changing at all — so every Garage List
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
    label = configName and (model .. ' — ' .. configName) or model,
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
-- re-derived on a slow timer and reported the moment it differs — that covers
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
-- drivers still racing). Both are lifted — and the car respawned — when the
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
  if not snap.model then return nil end
  return snap
end

-- Delete the local player's OWN vehicle. BeamNG exposes several ways to do this
-- depending on version, so try them in order and never let a failure escape.
--
-- core_vehicles.removeCurrent deletes whatever the client is attached to, which
-- is only safe once we know that is ours -- otherwise a driver taking the flag
-- deletes a rival's car out from under them.
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

-- Put the camera on our own car and give control back to it.
--
-- Doing this explicitly is the point: after a mass respawn the game picks a
-- vehicle for the camera on its own, and with five cars appearing at once its
-- pick is arbitrary -- which is how every client in the session ended up
-- watching the same driver.
local function bindCameraToOwnVehicle()
  local veh = ownVehicle()
  if not veh then return false end
  local bound = false
  if be and be.enterVehicle then
    bound = pcall(function () be:enterVehicle(0, veh) end)
  end
  if commands and commands.setGameCamera then
    pcall(commands.setGameCamera)
  elseif core_camera and core_camera.setByName then
    pcall(core_camera.setByName, 0, 'orbit')
  end
  log('I', 'raceManager', 'Camera bound to own vehicle ' .. tostring(vehicleId(veh))
    .. (bound and '' or ' (enterVehicle unavailable)'))
  return true
end

-- Put back the car removed when this client was pushed into spectator mode.
-- Called when the session that imposed the penalty ends, so a driver who
-- finished (or was knocked out of a derby) is back in their car for the next
-- one instead of stranded in freecam with nothing to drive.
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
  local spawned = false
  if core_vehicles and core_vehicles.spawnNewVehicle then
    spawned = pcall(core_vehicles.spawnNewVehicle, snap.model, opts)
  end
  if not spawned and core_vehicles and core_vehicles.replaceVehicle then
    spawned = pcall(core_vehicles.replaceVehicle, snap.model, opts)
  end
  if spawned then
    log('I', 'raceManager', 'Respawned ' .. tostring(snap.model) .. ' after the session ended')
  else
    -- Keep the snapshot: a failed spawn is worth another attempt when the
    -- placement scheduler comes back round, and losing it means losing the only
    -- record of what this driver was in.
    removedVehicle = snap
    log('W', 'raceManager', 'Could not respawn ' .. tostring(snap.model)
      .. ' automatically — spawn a vehicle manually')
  end
  return spawned
end

-- Put the camera into freecam/spectator. Same story: prefer the documented
-- command, fall back to the camera module.
local function forceFreeCamera()
  if commands and commands.setFreeCamera then
    if pcall(commands.setFreeCamera) then return true end
  end
  if core_camera and core_camera.setByName then
    if pcall(core_camera.setByName, 0, 'free') then return true end
  end
  return false
end

local function isFreeCamera()
  if commands and commands.isFreeCamera then
    local ok, free = pcall(commands.isFreeCamera)
    if ok then return free == true end
  end
  return false
end

-- Back to a normal driving camera once the spectator lock is lifted.
local function restoreGameCamera()
  if commands and commands.setGameCamera then
    if pcall(commands.setGameCamera) then return true end
  end
  if core_camera and core_camera.setByName then
    if pcall(core_camera.setByName, 0, 'orbit') then return true end
  end
  return false
end

local function enterSpectator(reason, source)
  spectatorLock   = source or 'race'
  spectatorReason = reason or 'You are out of this session'
  spectatorRecheck = 0
  removeLocalVehicle()
  forceFreeCamera()
  guihooks.trigger('RaceManagerSpectator', {
    spectating = true, reason = spectatorReason, source = spectatorLock,
  })
  pushNotice('spectate', spectatorReason)
  pushRouteState()
  log('I', 'raceManager', 'Forced spectator mode (' .. tostring(spectatorLock)
    .. '): ' .. tostring(spectatorReason))
end

-- Only the source that imposed the lock can lift it, so a derby finishing can
-- never hand a race DNF their car back (and vice versa). Releasing puts the
-- removed vehicle back and hands the camera to it, so the driver is ready for
-- the next session instead of stuck in freecam.
--
-- The respawn is QUEUED rather than done here. Every driver in the field is
-- released by the same broadcast, so doing it on the spot means the whole grid
-- spawning on one tick — refused spawns and interpenetrated cars. `order` and
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
  if queueFieldPlacement then
    queueFieldPlacement({ respawn = true, order = order, count = count })
  else
    respawnRemovedVehicle()
    restoreGameCamera()
  end
  guihooks.trigger('RaceManagerSpectator', { spectating = false })
  pushRouteState()
  log('I', 'raceManager', 'Spectator mode released (' .. tostring(source or 'any')
    .. ', order ' .. tostring(order or 1) .. '/' .. tostring(count or 1) .. ')')
end

-- While the lock is held the camera is re-asserted periodically: leaving
-- freecam is the one way a DNF'd driver could get back into a car.
local function spectatorUpdate(dt)
  if not spectatorLock then return end
  spectatorRecheck = spectatorRecheck - dt
  if spectatorRecheck > 0 then return end
  spectatorRecheck = 1.0
  if not isFreeCamera() then forceFreeCamera() end
end

-- The reset allowance applies for the whole of a live session — qualifying as
-- well as a race, now that qualifying is one — and the countdown that starts it.
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
  setResetInputsBlocked(wantBlocked)
end

-- Rolling "last good position" sample. Taken a few times a second while the
-- driver is out on track and NOT frozen on the grid, so a blocked reset always
-- has somewhere sane to put the car back.
local function snapshotUpdate(dt)
  if not (resetsEnforced() or derbyResetsEnforced()) or spectatorLock or gridFrozen then return end
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
-- inside the window AND the car is sitting where we put it. Both halves matter —
-- the window alone would swallow a driver reset pressed immediately after a
-- block, and a driver reset always moves the car somewhere else.
--
-- "Where we put it" cannot be a fixed radius, though. BeamNG v0.39 reworked the
-- teleport detector (objectTeleported(): "improved detection to reduce false
-- positives/negatives in extreme cases (such as ... really fast vehicles)"), so
-- an echo we used to hear on the same frame can now arrive a frame or two later
-- — and a car doing 250 km/h covers 2 metres in a frame and a half. Judged
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

-- Age out both reset-side timers.
local function resetGuardUpdate(dt)
  if selfTeleport.left  > 0 then selfTeleport.left  = selfTeleport.left  - dt end
  if blockNoticeLeft    > 0 then blockNoticeLeft    = blockNoticeLeft    - dt end
end

-- Heading (hx, hy) -> yaw about Z, expressed as a quaternion that stands a
-- VEHICLE facing down that heading. BeamNG vehicle models point down -Y at
-- identity, so a half-turn is baked in on top of the heading yaw — without it
-- every placement came out exactly 180° backwards.
local function headingRot(hx, hy)
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
  local rot = headingRot(wp.hx, wp.hy)
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
-- extension hook, so it fires for every vehicle — filter to our own first.
function M.onVehicleResetted(vehId)
  -- Ours, or there is nothing here to do. The attached vehicle can be another
  -- player's car — that is precisely the situation a driver who has just been
  -- taken off the track is in — and treating their reset as ours is how a rival
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
    removeLocalVehicle()
    forceFreeCamera()
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
    pushNotice('grid', 'Reset on the grid — you are back on your slot and held')
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
        and 'RESET BLOCKED — no resets allowed in this session'
        or  ('RESET BLOCKED — all ' .. maxResets .. ' resets used'))
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
  end

  if resetsEnforced() then
    resetsUsed = resetsUsed + 1
    -- A legal reset makes the new position the good one immediately, so a second
    -- (blocked) press right after it doesn't drag the car back to before the first.
    snapshotLeft = 0
    if inMultiplayer() then TriggerServerEvent('RM_VehicleReset', '') end
    local left = maxResets - resetsUsed
    pushNotice('reset', string.format('Reset %d/%d used — %d left', resetsUsed, maxResets, left))
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
          and 'RESET BLOCKED — no resets allowed in this derby'
          or  ('RESET BLOCKED — all ' .. derbyMaxResets .. ' derby resets used'))
        log('W', 'raceManager', 'Derby reset blocked: allowance of ' .. derbyMaxResets
          .. ' exhausted (position ' .. (restored and 'restored' or 'NOT restored') .. ')')
      end
      return
    end
    derbyResetsUsed = derbyResetsUsed + 1
    snapshotLeft = 0
    if inMultiplayer() then TriggerServerEvent('RM_DerbyVehicleReset', '') end
    pushNotice('reset', string.format('Derby reset %d/%d used — %d left',
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
  -- it — it is a new vehicle, and the old one's freeze died with it. Put the
  -- driver back on their slot, held, rather than leaving them the only car on
  -- the grid that can move.
  if holdWanted and isOwnVehicle(vehId) then
    hold.restore('vehicle respawned while held on the grid')
    pushNotice('grid', 'Back on your grid slot — held for the countdown')
  end
  if not spectatorLock then return end
  if not isOwnVehicle(vehId) then return end
  removeLocalVehicle()
  forceFreeCamera()
  pushNotice('spectate', 'You are spectating until the session ends')
  log('W', 'raceManager', 'Blocked vehicle spawn while in forced spectator mode')
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
-- slot and holds it there — the server has no physics access, so only the
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
-- BeamNG's -Y vehicle forward — placements used to come out 180° backwards.
local function placeOnStartPosition(sp)
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
      'Grid hold restored (%s) — correction #%d', tostring(reason), hold.corrections))
  end
  hold.correctLeft = TUNE.HOLD_CORRECT_COOLDOWN
  return true
end

-- Watch a held car and report where it is.
--
-- Two jobs, both only while a hold is wanted. Locally: if the car has moved off
-- its slot the freeze is not doing its job, so put it back. This is what makes
-- the hold survive a lost freeze whatever caused it -- it corrects the SYMPTOM
-- (a car that moved) rather than needing to enumerate every cause.
--
-- And upward: the server owns the hold, so it is told where this car is on a
-- steady cadence and can correct and log independently. A client that has been
-- modified to skip the local guard still has the server behind it.
--
-- A car that is behaving is touched by NONE of this, and "behaving" includes
-- the second or two after it is put down: a car dropped onto a start position
-- falls onto its suspension, which is both movement and displacement. Enforcing
-- against that is how the guard turned into a loop -- it teleported the car back
-- up to the height it was placed at, the teleport was reported as a vehicle
-- reset, and the car hovered there being reset every frame instead of settling.
--
-- So: nothing happens until the car has SETTLED, and the resting position it
-- settles into becomes the anchor. Putting a car back then means putting it back
-- on the ground where it was standing, not into the air where it was spawned.
--
-- The response is also graded, because the two failures are different sizes. A
-- car that is merely MOVING has lost its freeze but is still on its slot: it is
-- re-frozen where it stands, which costs nothing and provokes no reset. Only a
-- car that has actually LEFT its slot is teleported back, and that is the rare
-- case -- a real creep, or a freeze that cannot be applied at all.
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
      pushNotice('grid', 'Hold the car — the countdown has not finished')
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
        pushNotice('grid', 'Hold the car — the countdown has not finished')
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
  local sp = slot and (field.slots or startPositions)[slot]
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
  -- position a blocked reset should restore to — facing down the track, not
  -- at whatever identity rotation happens to mean on this circuit.
  lastGoodPos = vec3(sp.x, sp.y, sp.z)
  lastGoodRot = headingRot(sp.hx, sp.hy)
  pushNotice('grid', 'You start from P' .. slot .. ' — hold for the countdown')
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
      log('W', 'raceManager', 'Field placement timed out — finishing it anyway')
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
    -- arbitrary — which is how everyone ended up watching the same car.
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
  if want == (ghost.applied[vehId] == true) then return end
  if not veh then
    local got, found = pcall(getObjectByID, vehId)
    veh = got and found or nil
  end
  ghost.apply(vehId, veh, want, ghost.alphaFor(vehId))
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
    if ghost.veh[otherId] then return end          -- a ghost cannot weld
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
  -- ownVehicle() and not playerVehicle(), for the reason set out at the top of
  -- the file: the moment our car is deleted the game attaches this client to
  -- somebody else's, and "the car I am attached to" would then exclude a RIVAL
  -- from the ghost -- leaving the one car we are about to be respawned next to
  -- as the only solid thing on track. With no car of our own the answer is nil,
  -- and everything gets ghosted, which is exactly right for a mass respawn.
  local mine = ownVehicle()
  local myId = mine and vehicleId(mine) or nil
  forEachVehicle(myId, function (veh, id) ghost.reason(id, reason, on, veh) end)
  if on then ghost.field[reason] = true else ghost.field[reason] = nil end
end

local function clearGhostReasons()
  ghost.field = {}
  ghost.remote = {}
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
              pushNotice('ghost', 'Still ghosted — MOVE CLEAR of the other car')
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
-- and perpendicular to the direction of travel. Nothing else — no poles, no
-- cage — so what an admin sees on track is the real trigger, and raising the
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
  PALETTE = {
    finish    = ColorF(1, 1, 1, 0.9),          -- start/finish: white
    armed     = ColorF(0.2, 0.85, 0.35, 0.9),  -- next target: green
    route     = ColorF(1, 0.4, 0, 0.7),        -- rest of route: orange
    joker     = ColorF(0.65, 0.3, 0.95, 0.8),  -- joker route: violet
    jokerUsed = ColorF(0.45, 0.45, 0.5, 0.45), -- joker already taken: dimmed
    text      = ColorF(1, 1, 1, 1),
    -- The editor gate's filled surface. Deliberately faint: it has to show the
    -- gate's extent without hiding the road it is judged against.
    fill      = ColorF(0.35, 0.65, 1, 0.16),
    textBg    = ColorI(0, 0, 0, 160),
    -- Demo derby arena. Its own entries rather than its own table: the derby
    -- module keeps its state and its logic separate, but a colour is a colour,
    -- and building these per frame is what this exists to stop.
    derbyLive    = ColorF(0.9, 0.15, 0.15, 0.9),  -- live arena: red
    derbySetup   = ColorF(0.9, 0.6, 0.1, 0.8),    -- setup/finished: amber
    derbyLabelBg = ColorI(120, 0, 0, 180),
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
    String('P' .. index .. (mine and ' — YOU' or '')),
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

-- ===========================================================================
-- Race-mode checkpoint markers: BeamNG's own gate poles
-- ===========================================================================
-- During an actual race a checkpoint should look like a checkpoint, not like an
-- editor overlay -- two vertical poles standing either side of the racing line,
-- which is what BeamNG uses for its own races and what a driver already reads
-- without being taught. That is `scenario/race_marker`, and this is the wrapper
-- around it.
--
-- IT IS USED IN ITS DETACHED FORM, AND THAT IS THE WHOLE DESIGN. race_marker is
-- a SINGLETON shared by everything in the game that races -- BeamNG's own
-- hotlapping and flowgraph races, drag, drift, and BeamJoy if it is installed.
-- Its setupMarkers() call rebuilds one global marker list, so calling it would
-- silently delete every marker any of them had placed, and theirs would delete
-- ours. createRaceMarker(true, ...) instead returns a marker that is never put
-- in that shared list: we own it, nobody else can see it, and nothing we do can
-- disturb another mod's race. The cost is that we drive it ourselves -- position
-- it, colour it, tick it and destroy it -- which is what the rest of this
-- section does.
--
-- Only the gates a driver needs are ever built: the one they are heading for
-- and the one after it. A twenty-gate circuit still costs two markers.
local poles = {
  live = {},        -- [slot] = { marker = <engine marker>, key = <identity> }
  enabled = false,  -- markers are currently wanted
  -- The resolved engine module: nil = not looked yet, false = looked and this
  -- build has none, table = the module.
  mod = nil,
  -- Why the poles are (or are not) up, and the last engine error if one was
  -- thrown. Every call into the marker is pcall'd -- a checkpoint visual must
  -- never take the race loop down -- but swallowing the reason as well is how a
  -- visual that never appears becomes undiagnosable.
  why = nil,
  lastError = nil,
}

-- Ask the engine for a marker, or nil on a build (or a headless test) that has
-- no race_marker. Every call into engine code here is pcall'd: a checkpoint
-- visual must never be able to take the race loop down with it.
--
-- The module lookup is resolved ONCE and its failure is remembered. require()
-- on a name that does not resolve walks the whole package path, and this is
-- reached from the frame loop -- left uncached, a build without race_marker
-- paid that search twice a frame forever, which measured seventy times the cost
-- of everything else the mod does per frame put together.
function poles.module()
  if poles.mod ~= nil then return poles.mod or nil end
  local ok, mod = pcall(require, 'scenario/race_marker')
  if not ok or type(mod) ~= 'table' or type(mod.createRaceMarker) ~= 'function' then
    poles.mod = false            -- looked, found nothing; do not look again
    log('W', 'raceManager', 'No scenario/race_marker on this build — '
      .. 'race checkpoints will keep the editor gate visual')
    return nil
  end
  poles.mod = mod
  return mod
end

function poles.create()
  local mod = poles.module()
  if not mod then return nil end
  local made, marker = pcall(mod.createRaceMarker, true, 'sideColumnMarker')
  if not made or type(marker) ~= 'table' then return nil end
  return marker
end

-- Call into the engine, remembering the first thing that goes wrong. Silence is
-- what made "I started a race and saw no poles" impossible to answer.
function poles.call(what, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and not poles.lastError then
    poles.lastError = tostring(what) .. ': ' .. tostring(err)
    log('E', 'raceManager', 'Race marker ' .. poles.lastError)
  end
  return ok
end

-- Point one marker slot at a gate. `key` identifies what the slot is currently
-- showing, so a marker is only re-pointed when the gate under it actually
-- changes rather than every frame.
function poles.set(slot, wp, mode, key)
  local entry = poles.live[slot]
  if not entry then
    local marker = poles.create()
    if not marker then return false end
    entry = { marker = marker }
    poles.live[slot] = entry
  end
  if entry.key ~= key then
    entry.key = key
    local w = gateDims(wp)
    -- The marker plants its poles at pos +/- side * radius, so radius is the
    -- HALF width -- the same number the editor rectangle is built from.
    poles.call('setToCheckpoint', entry.marker.setToCheckpoint, entry.marker, {
      pos    = vec3(wp.x, wp.y, wp.z),
      normal = vec3(wp.hx, wp.hy, 0),
      radius = w * 0.5,
    })
    poles.call('setMode', entry.marker.setMode, entry.marker, mode)
  end
  return true
end

-- Destroy every marker we hold. Called on every teardown path there is: the
-- race ending, the editor opening, the session closing, the extension
-- unloading. These are real scene objects, so one left behind is a pair of
-- poles standing on an empty map with nothing able to remove them.
function poles.clear()
  for slot, entry in pairs(poles.live) do
    pcall(entry.marker.clearMarkers, entry.marker)
    poles.live[slot] = nil
  end
  poles.enabled = false
end

-- Markers animate (they pulse and fade with distance), so they need a tick.
-- Detached markers are not in race_marker's own render list, which is exactly
-- why they are safe -- so we drive them.
function poles.update(dt)
  for _, entry in pairs(poles.live) do
    poles.call('update', entry.marker.update, entry.marker, dt, dt)
  end
end

-- Which gates should be wearing poles right now.
--
-- Race markers are for DRIVING, so they exist only while a session is running
-- and only for this driver's own next two gates: the one they are aiming at and
-- the one after it, so the line through the corner reads before they arrive.
-- The editor's own view of the track is a separate thing entirely and turns
-- these off -- an admin laying out a circuit wants to see all of it at once,
-- labelled, which poles cannot do.
function poles.sync(editorView)
  -- Poles are the DRIVER's view of a checkpoint, in every phase -- not only
  -- during a running session. A driver learning a circuit before the lights
  -- wants to see where the gates are just as much as one racing through them,
  -- and the alternative was drawing the whole checkpoint set as rectangles,
  -- which is the editor's job and clutter for everyone else.
  local want = not editorView and not spectatorLock and #route > 0
  -- One line whenever the answer changes, so "no poles" always has a reason
  -- attached to it in the console rather than being a silent nothing.
  local why = want and 'on'
    or (editorView and 'the editor is open and you are an admin')
    or (spectatorLock and 'spectating')
    or (#route == 0 and 'no track loaded')
    or 'off'
  if why ~= poles.why then
    poles.why = why
    log('I', 'raceManager', 'Race checkpoint poles: ' .. why)
  end
  if not want then
    if next(poles.live) ~= nil then poles.clear() end
    return
  end
  -- Nothing to do on a build with no marker module, and asking again every
  -- frame is exactly the cost this short-circuit exists to avoid.
  if poles.mod == false then return end
  poles.enabled = true

  -- The gate being aimed at, and the one after it, so the line through the
  -- corner reads before the driver arrives. 'lap' colours the start/finish
  -- line, 'default' the ordinary next gate -- the same meanings BeamNG gives
  -- them in its own races.
  local n = #route
  local a = armedWp
  if a < 1 or a > n then a = 1 end
  poles.set(1, route[a], a == n and 'lap' or 'default', 'main:' .. a)
  local b = a % n + 1
  if n > 1 then
    poles.set(2, route[b], b == n and 'lap' or 'next', 'main:' .. b)
  elseif poles.live[2] then
    pcall(poles.live[2].marker.clearMarkers, poles.live[2].marker)
    poles.live[2] = nil
  end

  -- The joker route, when one is armed and still owed.
  --
  -- This is not decoration. The server DISQUALIFIES a driver who does not take
  -- the joker exactly once, so a required route that nobody can see is a
  -- penalty waiting to happen -- and the joker gates are not part of `route`,
  -- so the two markers above never reach them. 'branch' is BeamNG's own colour
  -- for an alternate line.
  local jn = #jokerRoute
  local showJoker = jokerEnabled and not jokerTaken and jn > 0
  if showJoker then
    local j = jokerArmed
    if j < 1 or j > jn then j = 1 end
    poles.set(3, jokerRoute[j], 'branch', 'joker:' .. j)
  elseif poles.live[3] then
    pcall(poles.live[3].marker.clearMarkers, poles.live[3].marker)
    poles.live[3] = nil
  end
end

local function drawGates()
  if not debugDrawer then return end
  -- The checkpoint rectangles are the EDITOR's view and only the editor's.
  --
  -- Everyone else -- every driver, and an admin who has closed the editor --
  -- gets the gate poles instead, in every phase. Drawing a whole circuit's
  -- worth of numbered rectangles at somebody who is trying to drive through it
  -- is clutter; the poles say where the next gate is, which is the only part a
  -- driver needs. `visualize` still hides them for an admin who wants the
  -- unobstructed view while placing gates.
  if not (editorOpen and isAdmin) then return end
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
    drawGate(wp, color, routeLabel(i, n), authoring)
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
    drawGate(wp, color, jokerLabel(i, jn, state), authoring)
  end
end

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
local DERBY_POLE_HEIGHT   = 6     -- boundary poles are taller than gate poles
local DERBY_POLE_RADIUS   = 0.2

-- One table rather than a dozen file-scope locals, for the same reason the
-- tunables at the top of the file are one table: Lua caps a function at 200
-- locals, the top level of this file is a function, and going over does not warn
-- -- the file fails to compile and the mod is simply not there. This block was
-- the largest cohesive group left.
local derbyState = {
  phase     = 'idle',   -- idle | running | finished (mirrored from server)
  boundary  = {},       -- ordered polygon vertices { x, y, z }
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

local function derbyPushWarning()
  guihooks.trigger('RaceManagerDerbyWarning', {
    oob     = derbyState.oobLeft,
    stopped = derbyState.demoLeft,
  })
  derbyState.warnShown = (derbyState.oobLeft ~= nil) or (derbyState.demoLeft ~= nil)
end

local function derbyClearWarnings()
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

local function derbyUpdate(dt)
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

-- Boundary visualization: red poles at each marker, a rope along the
-- perimeter (closed loop), and a label above marker 1. Mirrors the race
-- editor's Hide/Show Gates rule: unconditional while the derby runs (drivers
-- must see the arena), the toggle only applies outside of one.
local function derbyDrawBoundary()
  if not debugDrawer then return end
  if derbyState.phase ~= 'running' and not derbyState.visualize then return end
  -- Derby starting grid slots, numbered from slot 1. Setup furniture, the same
  -- as the race start grid: they exist to lay the slots out and check spacing,
  -- so they stop being drawn once the derby is under way -- by then every car
  -- has left its slot and the outlines are just clutter in a live arena.
  -- (Reaching here while not running means derbyState.visualize is on, per the guard
  -- above.) The boundary below is NOT hidden: leaving it is what eliminates
  -- you, so a driver has to be able to see it.
  if derbyState.phase ~= 'running' then
    for i, sp in ipairs(derbyState.starts) do
      drawStartPosition(sp, i, derbyState.slot == i)
    end
  end
  local boundary = derbyState.boundary
  local n = #boundary
  if n == 0 then return end

  -- Same story as the race gates: an arena perimeter is fixed geometry redrawn
  -- every frame, and it was rebuilding all of it each time -- a pole and a rope
  -- span per marker, which is seven vectors a marker, plus the label and its
  -- anchor. Over an eight-marker arena that is the best part of sixty tables a
  -- frame, for the entire length of a derby.
  --
  -- The cache lives on derbyState rather than in a new file-scope local, because
  -- this file is close enough to Lua's 200-local ceiling that a new one there is
  -- a cost of its own. It is keyed on the boundary table itself: onDerbyUpdate
  -- keeps the existing table when the markers have not moved, so identity is
  -- enough to say "nothing about this arena has changed".
  local cache = derbyState.draw
  if not cache or cache.src ~= boundary then
    local up   = vec3(0, 0, DERBY_POLE_HEIGHT)
    local half = vec3(0, 0, DERBY_POLE_HEIGHT * 0.5)
    cache = { src = boundary, poles = {}, ropes = {} }
    for i, m in ipairs(boundary) do
      local base = vec3(m.x, m.y, m.z)
      cache.poles[i] = { a = base, b = base + up }
      local nxt = boundary[i % n + 1]
      if nxt and n > 1 then
        cache.ropes[#cache.ropes + 1] = {
          a = base + half,
          b = vec3(nxt.x, nxt.y, nxt.z) + half,
        }
      end
    end
    local first = boundary[1]
    cache.labelAt = vec3(first.x, first.y, first.z + DERBY_POLE_HEIGHT + 0.8)
    cache.label   = 'DERBY BOUNDARY (' .. n .. ')'
    derbyState.draw = cache
  end

  local p = palette()
  local color = (derbyState.phase == 'running') and p.derbyLive or p.derbySetup
  for _, pole in ipairs(cache.poles) do
    debugDrawer:drawCylinder(pole.a, pole.b, DERBY_POLE_RADIUS, color)
  end
  for _, rope in ipairs(cache.ropes) do
    debugDrawer:drawCylinder(rope.a, rope.b, DERBY_POLE_RADIUS * 0.35, color)
  end
  debugDrawer:drawTextAdvanced(cache.labelAt, String(cache.label),
    p.text, true, false, p.derbyLabelBg)
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
  TriggerServerEvent('RM_DerbySaveLayout', jsonEncode({
    name = name, boundary = markers,
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

local function onDerbyUpdate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  if not fromCurrentServer(data) then return end

  local newPhase = data.derbyPhase or 'idle'
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
  -- after Start Derby and are a spectator — a parked spectator must not get
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
-- the placed heading. No freeze/hold — the derby's start grace period covers
-- the line-up, and the teleport is flagged so it never counts as a reset.
local function onDerbyGridAssign(rawData)
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
local function onDerbyCountdown(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local count = tonumber(data.count)
  if count and count <= 0 then releaseGridHold('derby') end
  guihooks.trigger('RaceManagerCountdown', data)
end

-- Map-filtered arena list from the server.
local function onDerbyLayoutList(rawData)
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
  drawGates()
  -- Race-mode checkpoint poles. Editor visuals belong to admins with the editor
  -- open; everyone else, including an admin who has closed it, gets the poles.
  poles.sync(editorOpen and isAdmin)
  poles.update(dt)
  drawStartPositions()      -- starting grid slots
  fieldUpdate(dt)           -- ghosted, staggered grid placement / mass respawn
  holdUpdate(dt)            -- grid hold: verify it is holding, report position
  snapshotUpdate(dt)        -- Module 1: rolling "last good position"
  resetGuardUpdate(dt)      -- Module 1: teleport-echo window + notice throttle
  resetInputBlockUpdate()   -- Module 1: dead reset keys once the allowance is gone
  spectatorUpdate(dt)       -- Module 1: keep a spectator in freecam
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

-- Diagnostic for the in-game Lua console:
--   dump(raceManager.polesStatus())
-- Answers "why can I not see the checkpoint poles" in one line, without needing
-- the log: whether the engine module resolved, whether they are wanted right
-- now and why, how many are standing, and the first engine error if any.
function M.polesStatus()
  local live = 0
  for _ in pairs(poles.live) do live = live + 1 end
  return {
    moduleFound    = poles.mod ~= nil and poles.mod ~= false,
    moduleLookedUp = poles.mod ~= nil,
    reason         = poles.why,
    markersUp      = live,
    lastError      = poles.lastError,
    phase          = phase,
    editorOpen     = editorOpen,
    isAdmin        = isAdmin,
    spectating     = spectatorLock ~= nil,
    gates          = #route,
    armed          = armedWp,
  }
end

function M.setEditorOpen(open)
  editorOpen = open == true
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
  if target ~= 'joker' and target ~= 'start' then target = 'main' end
  editorTarget = target
  pushRouteState()
  log('I', 'raceManager', 'Editor target: ' .. editorTarget)
end

local function activeEditorRoute()
  if editorTarget == 'joker' then return jokerRoute end
  if editorTarget == 'start' then return startPositions end
  return route
end

function M.editorAdd()
  local place = vehiclePlacement()
  if not place then
    log('W', 'raceManager', 'Editor: no player vehicle, cannot place')
    return
  end
  local target = activeEditorRoute()
  target[#target + 1] = place
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
    end
    pushRouteState()
  end
end

function M.editorClear()
  -- Clearing the joker route or the grid on its own must not wipe the main lap.
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
    pushRouteState()
    log('I', 'raceManager', 'Start positions cleared')
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
  pushRouteState()
  log('I', 'raceManager', 'Start position ' .. index .. ' moved to the current vehicle')
end

function M.removeStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  if not startPositions[index] then return end
  table.remove(startPositions, index)
  if gridSlot and gridSlot > #startPositions then gridSlot = nil end
  pushRouteState()
end

-- Preview: stand the car on a placed slot so the creator can check spacing
-- without starting a race. Never freezes — this is an editor convenience.
function M.previewStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  local sp = startPositions[index]
  if not sp then return end
  if not placeOnStartPosition(sp) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Could not move the vehicle' })
  end
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

function M.editorSave()
  if #route == 0 then
    log('W', 'raceManager', 'Editor: nothing to save')
    return
  end
  jsonWriteFile(TUNE.ROUTE_FILE, {
    version = 5,
    width   = checkpointWidth,
    height  = checkpointHeight,
    waypoints = route,
    joker     = jokerRoute,
    startPositions = startPositions,
  }, true)
  log('I', 'raceManager', 'Editor: saved ' .. #route .. ' checkpoints ('
    .. #jokerRoute .. ' joker, ' .. #startPositions .. ' start positions) to ' .. TUNE.ROUTE_FILE)
  guihooks.trigger('RaceManagerEditorMsg', {
    msg = 'Saved ' .. #route .. ' checkpoints'
      .. (#jokerRoute > 0 and (' + ' .. #jokerRoute .. ' joker gates') or '')
      .. (#startPositions > 0 and (' + ' .. #startPositions .. ' start positions') or ''),
  })
end

-- v1 route files stored spherical waypoints { x, y, z, radius }. Convert:
-- heading = direction toward the next waypoint (wrapping to the first).
local function migrateV1(waypoints)
  local out = {}
  local n = #waypoints
  for i, wp in ipairs(waypoints) do
    local nxt = waypoints[i % n + 1]
    local dx, dy = nxt.x - wp.x, nxt.y - wp.y
    local len = math.sqrt(dx * dx + dy * dy)
    local hx, hy = 0, 1
    if len > 1e-4 then hx, hy = dx / len, dy / len end
    out[i] = { x = wp.x, y = wp.y, z = wp.z, hx = hx, hy = hy }
  end
  return out
end

function M.editorLoad()
  local data = jsonReadFile(TUNE.ROUTE_FILE)
  if type(data) ~= 'table' or type(data.waypoints) ~= 'table' or #data.waypoints == 0 then
    log('W', 'raceManager', 'Editor: no saved route at ' .. TUNE.ROUTE_FILE)
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'No saved route found' })
    return
  end
  if data.version and data.version >= 2 then
    route = data.waypoints
    checkpointWidth  = clampWidth(data.width or TUNE.DEFAULT_WIDTH)
    checkpointHeight = clampHeight(data.height or TUNE.DEFAULT_HEIGHT)
    jokerRoute = (type(data.joker) == 'table') and data.joker or {}
    startPositions = (type(data.startPositions) == 'table') and data.startPositions or {}
  else
    route = migrateV1(data.waypoints)
    jokerRoute = {}
    startPositions = {}
  end
  armedWp    = math.max(#route, 1)
  jokerArmed = 1
  pushRouteState()
  guihooks.trigger('RaceManagerEditorMsg', {
    msg = 'Loaded ' .. #route .. ' checkpoints'
      .. (#jokerRoute > 0 and (' + ' .. #jokerRoute .. ' joker gates') or '')
      .. (#startPositions > 0 and (' + ' .. #startPositions .. ' start positions') or ''),
  })
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

function M.saveLayout(name)
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
  local payload = jsonEncode({
    name        = name,
    width       = clampWidth(checkpointWidth),
    height      = clampHeight(checkpointHeight),
    checkpoints = cps,
    joker       = jokerCps,
    startPositions = starts,
    -- Whether this track is a sprint stage or a circuit is a property of the
    -- TRACK, so it is stored with it. An admin who built a point-to-point stage
    -- should not have to remember to set it again every race night.
    pointToPoint   = pointToPoint,
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
  -- or reconnects mid-final-lap is told too — but announced only on the EDGE, or
  -- a 3 Hz broadcast would repeat the notice several times a second.
  local wasFinalLap = finalLap
  finalLap = data.finalLap == true
  if finalLap and not wasFinalLap then
    pushNotice('session', 'TIME EXPIRED — FINAL LAP. Your session ends as you cross the line.')
  end
  -- Race entry + qualifying rules.
  if type(data.entryMode) == 'string' then entryMode = data.entryMode end
  if type(data.pointToPoint) == 'boolean' then pointToPoint = data.pointToPoint end
  ghostQuali = data.ghostQuali == true
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
      if tonumber(d.id) == myId then joined = d.joined == true; break end
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
        string.format('FASTEST LAP — %d:%06.3f', mins, bestTime - mins * 60))
    end
    lastBestLapPid  = bestPid
    lastBestLapTime = bestTime
  end

  local newPhase = data.phase or 'waiting'
  local phaseChanged = newPhase ~= phase
  if newPhase ~= phase then
    phase = newPhase
    -- Any session transition re-arms local detection from a clean slate:
    -- quali start begins a fresh out-lap, GO starts lap 1 at the line.
    resetLapTracking()
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
-- not the local guard did its job — which is the point of having it.
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
  pushNotice('grid', 'Held on the grid — wait for the lights')
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
  -- authoritative release — everyone's car is let go by the same broadcast, so
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
      if tonumber(cp.width)  then out[i].width  = clampWidth(cp.width)   end
      if tonumber(cp.height) then out[i].height = clampHeight(cp.height) end
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
  clearTrackState('applying layout "' .. tostring(data.name) .. '"')
  route      = cps
  jokerRoute = jokerCps
  startPositions = starts
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

-- Module 1: what a legal reset does while racing — repair in place (default)
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
  if mode ~= 'random' and mode ~= 'custom' then mode = 'quali' end
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

function M.requestState()
  pushRouteState()
  if inMultiplayer() then
    TriggerServerEvent('RM_RequestState', '')
    TriggerServerEvent('RM_RequestLayouts', '')
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
-- across a reload — a stale instance pushing its own (empty) state to the UI
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
-- every one of these is a rule the SERVER owns and only this client can apply —
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
  poles.clear()                  -- scene objects: never leave them standing
  clearGhostReasons()
  setResetInputsBlocked(false)   -- never leave the reset keys dead after unload
  holdWanted = nil               -- nothing is meant to be held any more
  maxResets       = -1
  resetsUsed      = 0
  resetMode       = 'inplace'
  lastGate        = nil
  selfTeleport.left = 0
  blockNoticeLeft = 0
  jokerEnabled    = false
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
-- regulation the server owns is APPLIED here — the reset keys are switched off
-- at the input filter, the car is frozen on its grid slot, a finished or
-- eliminated driver is held in freecam — and all of them are lifted by a
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

return M
