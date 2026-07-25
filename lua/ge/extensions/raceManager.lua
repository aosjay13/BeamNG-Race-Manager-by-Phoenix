-- Race Manager - client GE extension (BeamMP bridge + checkpoint editor)
--
-- Multiplayer-only for racing. The BeamMP server (server/RaceManager/main.lua)
-- owns the session state; this extension does what only a client can do:
--   1. Checkpoint editor: place gate-style checkpoints at the local vehicle's
--      position AND heading. Each checkpoint is drawn as two vertical poles
--      marking the outer edges of a timing line perpendicular to the travel
--      direction — no capture bubbles. The gate width is adjustable live from
--      the UI and applies to every checkpoint.
--   2. Detect the LOCAL vehicle crossing each gate, in order, by intersecting
--      the frame-to-frame movement segment with the vertical plane spanned
--      between the two poles (the server has no physics access). The last
--      checkpoint placed is the start/finish line; completing the checkpoint
--      sequence and crossing it again scores a lap, which is timed locally
--      and reported upstream (RM_QualiLap during qualifying, RM_Lap in race).
--   3. Receive the server's state broadcasts, reset local lap tracking on
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
local DEFAULT_WIDTH  = 20       -- meters between the two poles (lateral span)
local MIN_WIDTH      = 2
local MAX_WIDTH      = 120
local DEFAULT_HEIGHT = 10       -- meters the trigger extends up/down (vertical)
local MIN_HEIGHT     = 1
local MAX_HEIGHT     = 100
local DEFAULT_DEPTH  = 4        -- meters of forward thickness (along heading)
local MIN_DEPTH      = 0.5
local MAX_DEPTH      = 100
local POLE_HEIGHT    = 4        -- meters
local POLE_RADIUS    = 0.15    -- meters
local LAP_DEBOUNCE   = 2.0      -- seconds; double-fire guard on the S/F gate.
                                -- Kept low so even very short circuits report:
                                -- this only needs to swallow same-crossing
                                -- re-fires, not bound real lap times.
local PROGRESS_EVERY = 0.3      -- seconds between live-position reports
                                -- (~3.3 Hz: responsive enough to resolve a
                                -- side-by-side fight, light enough that a full
                                -- grid does not flood the server)
local ROUTE_FILE     = 'settings/raceManager/route.json'

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local phase     = 'waiting'  -- mirrored from server broadcasts
local totalLaps = 5          -- mirrored from server broadcasts

-- Checkpoints: ordered list of { x, y, z, hx, hy } where (hx, hy) is the
-- normalized direction of travel captured at placement. The gate line runs
-- perpendicular to it; the last checkpoint is the start/finish line. A gate may
-- also carry per-checkpoint width/height/depth overrides; absent, it inherits
-- the global defaults below. Each checkpoint is a 3D oriented bounding box:
-- width = lateral span (between the poles), height = vertical extent (covers
-- banking), depth = forward thickness (how "thick" the timing line is).
local route            = {}
local checkpointWidth  = DEFAULT_WIDTH
local checkpointHeight = DEFAULT_HEIGHT
local checkpointDepth  = DEFAULT_DEPTH
local visualize        = true

-- Rallycross joker route (Module 2): a second, completely separate gate set
-- describing the alternate route. Same checkpoint format as `route`; it travels
-- with the track layout and is only policed when the server arms the rule.
local jokerRoute   = {}
local jokerEnabled = false       -- mirrored from the server broadcast
local jokerArmed   = 1           -- next joker gate the local car must cross
local jokerTaken   = false       -- joker route already completed this race
local jokerLapUsed = nil         -- lap the joker was taken on (for the UI)
local editorTarget = 'main'      -- which route the editor appends to: main | joker

-- Local lap tracking (reset on every session change)
local armedWp      = 1           -- next gate the local car must cross
local timingActive = false       -- quali: false until the first S/F crossing (out-lap)
local lapStart     = 0           -- localTime at the start of the current lap
local localLap     = 1
local localTime    = 0
local prevPos      = nil         -- vehicle position last frame (crossing segment)

-- Live position telemetry: metres from the car to the centre of the next
-- checkpoint, recomputed every frame and reported to the server on a throttle.
local distToNext   = nil
local progressLeft = 0           -- seconds until the next report is due

-- Vehicle reset ruleset (Module 1). maxResets mirrors the server: -1 unlimited,
-- 0 none, N allowed per session. resetsUsed counts what this client has spent.
local maxResets    = -1
local resetsUsed   = 0

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

local function playerVehicle()
  return be:getPlayerVehicle(0)
end

local function clampWidth(w)
  w = tonumber(w) or DEFAULT_WIDTH
  if w < MIN_WIDTH then w = MIN_WIDTH elseif w > MAX_WIDTH then w = MAX_WIDTH end
  return w
end

local function clampHeight(h)
  h = tonumber(h) or DEFAULT_HEIGHT
  if h < MIN_HEIGHT then h = MIN_HEIGHT elseif h > MAX_HEIGHT then h = MAX_HEIGHT end
  return h
end

local function clampDepth(d)
  d = tonumber(d) or DEFAULT_DEPTH
  if d < MIN_DEPTH then d = MIN_DEPTH elseif d > MAX_DEPTH then d = MAX_DEPTH end
  return d
end

-- Effective box dimensions for a checkpoint: a per-gate override wins, otherwise
-- the global default. Always returned clamped so bad stored data can't produce
-- a degenerate (zero/negative) trigger volume.
local function gateDims(wp)
  return clampWidth(wp.width   or checkpointWidth),
         clampHeight(wp.height or checkpointHeight),
         clampDepth(wp.depth   or checkpointDepth)
end

-- ---------------------------------------------------------------------------
-- UI push helpers
-- ---------------------------------------------------------------------------
local function pushRouteState()
  guihooks.trigger('RaceManagerRoute', {
    waypoints    = route,
    nextWp       = armedWp,
    width        = checkpointWidth,
    height       = checkpointHeight,
    depth        = checkpointDepth,
    visualize    = visualize,
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
    spectating   = spectatorLock ~= nil,
  })
end

-- Dedicated, dismissable notice channel for regulation events (reset denied,
-- joker invalidated, vehicle rejected) so they don't get lost among the
-- editor's transient messages.
local function pushNotice(kind, msg)
  guihooks.trigger('RaceManagerNotice', { kind = kind, msg = msg })
end

-- ---------------------------------------------------------------------------
-- Gate geometry
-- ---------------------------------------------------------------------------
-- Pole positions: center point offset left/right along the line perpendicular
-- to the stored heading, by half the gate's (possibly overridden) width.
local function gatePoles(wp)
  local w = gateDims(wp)
  local half = w * 0.5
  local rx, ry = wp.hy, -wp.hx  -- right-hand perpendicular of the heading
  return vec3(wp.x - rx * half, wp.y - ry * half, wp.z),
         vec3(wp.x + rx * half, wp.y + ry * half, wp.z)
end

-- 3D Oriented Bounding Box crossing test. A checkpoint is a box centered on
-- (wp.x, wp.y, wp.z), oriented by the stored heading, with local axes:
--   forward f = (hx, hy)      thickness = depth   (why banked lines still hit)
--   lateral r = (hy, -hx)     span      = width   (between the poles)
--   up      z                 span      = height  (covers the banking)
-- The car registers a forward pass through the box in one of two ways, both of
-- which require it to be moving in the gate's forward direction so a reversing
-- car never scores a gate:
--   (1) the current position lands inside the box -- catches slow, steep and
--       high-banked crossings the old flat plane missed; or
--   (2) the frame-to-frame segment crosses the box's center plane in the
--       forward direction and the crossing point is within the width/height
--       half-extents -- a tunnel guard for a car too fast to be sampled inside
--       the (thin, depth-deep) box on any single frame.
-- Dimensions are passed in so the same math can be unit-tested headlessly
-- (see tests/gate_test.lua); the live caller feeds gateDims(wp).
local function obbCrossesGate(wp, prev, cur, w, h, d)
  local fx, fy = wp.hx, wp.hy

  -- Forward component of this frame's displacement. Non-negative == the car is
  -- travelling in (or along) the gate's forward direction.
  local moveF = (cur.x - prev.x) * fx + (cur.y - prev.y) * fy
  if moveF < 0 then return false end

  -- (1) point-in-OBB on the current position (local box coordinates).
  local dx, dy, dz = cur.x - wp.x, cur.y - wp.y, cur.z - wp.z
  local lf = dx * fx + dy * fy          -- along forward (depth) axis
  local lr = dx * fy - dy * fx          -- along lateral (width) axis
  if math.abs(lf) <= d * 0.5 and math.abs(lr) <= w * 0.5
      and math.abs(dz) <= h * 0.5 then
    return true
  end

  -- (2) forward crossing of the center plane, bounded by width & height.
  local dPrev = (prev.x - wp.x) * fx + (prev.y - wp.y) * fy
  local dCur  = lf
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

-- Live wrapper: resolve the gate's effective box dimensions, then run the OBB
-- test. Keeps the crossing check callers unchanged (segmentCrossesGate(wp, a, b)).
local function segmentCrossesGate(wp, prev, cur)
  local w, h, d = gateDims(wp)
  return obbCrossesGate(wp, prev, cur, w, h, d)
end

-- ---------------------------------------------------------------------------
-- Lap logic
-- ---------------------------------------------------------------------------
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
  -- Telemetry restarts with the session; report immediately on the next frame
  -- so the leaderboard has a distance for this driver from the first moments.
  distToNext   = nil
  progressLeft = 0
  -- Race: cars launch from the grid at the line, so the first target is
  -- checkpoint 1. Quali: the out-lap ends at the S/F line, so arm the line.
  if phase == 'racing' then
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
  armedWp      = 1
  jokerArmed   = 1
  jokerTaken   = false
  jokerLapUsed = nil
  timingActive = false
  localLap     = 1
  lapStart     = localTime
  prevPos      = nil
  distToNext   = nil
  progressLeft = 0
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
  if timingActive and lapTime < LAP_DEBOUNCE then return end  -- double-fire guard

  if phase == 'qualifying' then
    if timingActive then
      if inMultiplayer() then
        TriggerServerEvent('RM_QualiLap', jsonEncode({ lapTime = lapTime }))
      end
      log('I', 'raceManager', string.format('Quali lap: %.3fs', lapTime))
    else
      timingActive = true  -- out-lap over, the clock starts now
      log('I', 'raceManager', 'Quali: flying lap started')
    end
    lapStart = localTime
  elseif phase == 'racing' then
    if inMultiplayer() then
      TriggerServerEvent('RM_Lap', jsonEncode({ lapTime = lapTime }))
    end
    log('I', 'raceManager', string.format('Lap %d done: %.3fs', localLap, lapTime))
    localLap = localLap + 1
    lapStart = localTime
  end
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
  local veh = playerVehicle()
  if not veh then return end
  local pos = veh:getPosition()
  if prevPos then
    local wp = route[armedWp]
    if wp and segmentCrossesGate(wp, prevPos, pos) then
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
-- Live position telemetry
-- ---------------------------------------------------------------------------
-- The server decides the running order but has no physics access, so the third
-- tie-break metric — how far a car is from the next checkpoint — can only be
-- measured here. Every frame the straight-line distance from the vehicle to the
-- next gate's centre is recomputed; a few times a second that distance goes up
-- to the server together with the lap and the number of checkpoints already
-- cleared on it. The send is throttled (PROGRESS_EVERY) so a full grid costs the
-- server a handful of small events per second, not one per frame per driver.
local function reportProgress(dt)
  if phase ~= 'racing' or spectatorLock then
    distToNext = nil
    return
  end
  local wp = route[armedWp]
  if not wp then
    distToNext = nil
    return
  end
  local veh = playerVehicle()
  if not veh then
    distToNext = nil
    return
  end

  -- Distance from the car to the centre of the next checkpoint, in metres.
  local pos = veh:getPosition()
  local dx, dy, dz = pos.x - wp.x, pos.y - wp.y, pos.z - wp.z
  distToNext = math.sqrt(dx * dx + dy * dy + dz * dz)

  progressLeft = progressLeft - dt
  if progressLeft > 0 then return end
  progressLeft = PROGRESS_EVERY

  -- armedWp is the gate we are driving TOWARDS, so the count already cleared on
  -- this lap is one less (and 0 right after crossing the start/finish line).
  local payload = {
    lap  = localLap,
    cp   = armedWp - 1,
    dist = distToNext,
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
      if type(cfg.partConfigFilename) == 'string' then
        configName = cfg.partConfigFilename:match('([^/\\]+)%.pc$')
      end
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
    model = cfg.model, label = cfg.label, sig = cfg.sig,
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
-- sees it. Every local reset is counted here; the one that goes past the
-- allowance is invalidated on the spot — the driver is DNF'd, their vehicle is
-- removed and their camera is pinned to freecam, so a reset can never buy them
-- anything. The same spectator lock is used when the (isolated) derby module
-- reports an elimination.

-- Delete the local player's vehicle. BeamNG exposes several ways to do this
-- depending on version, so try them in order and never let a failure escape.
local function removeLocalVehicle()
  local veh = playerVehicle()
  if not veh then return end
  if core_vehicles and core_vehicles.removeCurrent then
    if pcall(core_vehicles.removeCurrent) then return end
  end
  pcall(function () veh:delete() end)
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
-- never hand a race DNF their car back (and vice versa).
local function releaseSpectator(source)
  if not spectatorLock then return end
  if source and source ~= spectatorLock then return end
  spectatorLock   = nil
  spectatorReason = nil
  guihooks.trigger('RaceManagerSpectator', { spectating = false })
  pushRouteState()
  log('I', 'raceManager', 'Spectator mode released (' .. tostring(source or 'any') .. ')')
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

-- The reset allowance only applies while a race session is live; qualifying
-- out-laps and the setup phases stay free.
local function resetsEnforced()
  return maxResets >= 0 and (phase == 'racing' or phase == 'countdown')
end

-- BeamNG hook: the local player reset/recovered a vehicle. Registered as an
-- extension hook, so it fires for every vehicle — filter to our own first.
function M.onVehicleResetted(vehId)
  local veh = playerVehicle()
  if not veh or veh:getID() ~= vehId then return end
  if spectatorLock then
    -- Already out: a reset must never put a DNF'd driver back on track.
    removeLocalVehicle()
    forceFreeCamera()
    return
  end
  if not resetsEnforced() then return end

  if resetsUsed >= maxResets then
    -- Over the allowance: block it. The reset itself has already happened in
    -- the physics engine, so "blocking" means invalidating it completely —
    -- the car goes away, the driver is DNF'd and the server is told.
    if inMultiplayer() then TriggerServerEvent('RM_ResetDenied', '') end
    enterSpectator(maxResets == 0
      and 'Vehicle resets are not allowed in this session — DNF'
      or  ('Reset limit exceeded (' .. maxResets .. ' allowed) — DNF'), 'race')
    log('W', 'raceManager', 'Reset blocked: allowance of ' .. maxResets .. ' exhausted')
    return
  end

  resetsUsed = resetsUsed + 1
  if inMultiplayer() then TriggerServerEvent('RM_VehicleReset', '') end
  local left = maxResets - resetsUsed
  pushNotice('reset', string.format('Reset %d/%d used — %d left', resetsUsed, maxResets, left))
  pushRouteState()
end

-- BeamNG hook: a vehicle appeared. A driver serving a spectator penalty must
-- not be able to spawn a replacement until the session ends, so their new car
-- is removed immediately. Other players' vehicles are left alone.
function M.onVehicleSpawned(vehId)
  -- Module 4: a new car means a new configuration to declare to the server.
  reportVehicleConfig(true)
  if not spectatorLock then return end
  local mine = true
  if MPVehicleGE and MPVehicleGE.isOwn then
    local ok, own = pcall(MPVehicleGE.isOwn, vehId)
    if ok then mine = own == true end
  else
    local veh = playerVehicle()
    mine = veh ~= nil and veh:getID() == vehId
  end
  if not mine then return end
  removeLocalVehicle()
  forceFreeCamera()
  pushNotice('spectate', 'You are spectating until the session ends')
  log('W', 'raceManager', 'Blocked vehicle spawn while in forced spectator mode')
end

-- ---------------------------------------------------------------------------
-- In-world gate visualization: two poles per checkpoint + crossbar
-- ---------------------------------------------------------------------------
-- Draw the faint edge cage of a checkpoint's true 3D hit-volume (the OBB), so
-- an admin can eyeball that the box actually covers the banking. Eight corners
-- built from the gate's forward/lateral/up axes and its width/height/depth,
-- wired up as the box's 12 edges.
local function drawGateVolume(wp, color)
  local w, h, d = gateDims(wp)
  local hw, hh, hd = w * 0.5, h * 0.5, d * 0.5
  local fx, fy = wp.hx, wp.hy          -- forward (depth)
  local rx, ry = wp.hy, -wp.hx         -- lateral (width)
  -- corner(sr, sd, su): center + r*sr*hw + f*sd*hd + up*su*hh
  local function corner(sr, sd, su)
    return vec3(
      wp.x + rx * sr * hw + fx * sd * hd,
      wp.y + ry * sr * hw + fy * sd * hd,
      wp.z + su * hh)
  end
  -- Index the 8 corners by (sr, sd, su) in {-1,+1}.
  local c = {
    corner(-1, -1, -1), corner(1, -1, -1), corner(1, 1, -1), corner(-1, 1, -1),  -- bottom
    corner(-1, -1,  1), corner(1, -1,  1), corner(1, 1,  1), corner(-1, 1,  1),  -- top
  }
  local edges = {
    {1,2},{2,3},{3,4},{4,1},   -- bottom rectangle
    {5,6},{6,7},{7,8},{8,5},   -- top rectangle
    {1,5},{2,6},{3,7},{4,8},   -- vertical pillars
  }
  local faint = ColorF(color.r or 1, color.g or 1, color.b or 1, 0.28)
  for _, e in ipairs(edges) do
    debugDrawer:drawCylinder(c[e[1]], c[e[2]], POLE_RADIUS * 0.35, faint)
  end
end

-- One gate: two poles, a crossbar, the faint 3D hit-volume cage and a label.
local function drawGate(wp, color, label)
  local pL, pR = gatePoles(wp)
  local up = vec3(0, 0, POLE_HEIGHT)
  debugDrawer:drawCylinder(pL, pL + up, POLE_RADIUS, color)
  debugDrawer:drawCylinder(pR, pR + up, POLE_RADIUS, color)
  -- Crossbar between the pole tops so the gate reads as one line.
  debugDrawer:drawCylinder(pL + up, pR + up, POLE_RADIUS * 0.5, color)
  -- Faint 3D cage showing the real width x height x depth trigger volume.
  drawGateVolume(wp, color)

  local mid = (pL + pR) * 0.5 + vec3(0, 0, POLE_HEIGHT + 0.8)
  debugDrawer:drawTextAdvanced(mid, String(label),
    ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 160))
end

-- Gate visibility (Module 3). The checkpoint boxes are drawn by every client,
-- admin or not: during an active session (countdown / qualifying / race) the
-- drawing is unconditional, because a driver who cannot see the gates cannot
-- race. The Hide/Show Gates toggle only applies outside a session, where it
-- exists to keep the editor view clean.
local function drawGates()
  if not debugDrawer then return end
  local active = (phase == 'qualifying' or phase == 'racing' or phase == 'countdown')
  if not active and not visualize then return end

  for i, wp in ipairs(route) do
    local color
    if i == #route then
      color = ColorF(1, 1, 1, 0.9)               -- start/finish: white
    elseif active and i == armedWp then
      color = ColorF(0.2, 0.85, 0.35, 0.9)       -- next target: green
    else
      color = ColorF(1, 0.4, 0, 0.7)             -- rest of route: orange
    end
    drawGate(wp, color, (i == #route) and (i .. ' START/FINISH') or ('CP ' .. i))
  end

  -- Joker route: violet, so it never reads as part of the main lap. The next
  -- joker gate lights up green like the main route, and the whole set greys out
  -- once the joker has been used (or while it is still forbidden on lap 1).
  for i, wp in ipairs(jokerRoute) do
    local color
    if jokerTaken then
      color = ColorF(0.45, 0.45, 0.5, 0.45)      -- already used: dimmed
    elseif active and jokerEnabled and i == jokerArmed then
      color = ColorF(0.2, 0.85, 0.35, 0.9)       -- next joker target: green
    else
      color = ColorF(0.65, 0.3, 0.95, 0.8)       -- joker route: violet
    end
    local label = 'JOKER ' .. i .. '/' .. #jokerRoute
    if i == #jokerRoute then label = 'JOKER EXIT' end
    if jokerTaken then label = label .. ' (used)'
    elseif active and localLap <= 1 then label = label .. ' (lap 1: closed)' end
    drawGate(wp, color, label)
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
local DERBY_START_GRACE   = 5     -- s after Start Derby before the stopped-vehicle
                                  -- check arms, so drivers waiting for the GO
                                  -- announcement aren't instantly on the clock
local DERBY_POLE_HEIGHT   = 6     -- boundary poles are taller than gate poles
local DERBY_POLE_RADIUS   = 0.2

local derbyPhase     = 'idle'     -- idle | running | finished (mirrored from server)
local derbyBoundary  = {}         -- ordered polygon vertices { x, y, z }
local derbyOobLimit  = 5          -- seconds (mirrored from server config)
local derbyDemoLimit = 10
local derbyOobLeft   = nil        -- active out-of-bounds countdown, nil = inside
local derbyDemoLeft  = nil        -- active stopped countdown, nil = moving
local derbyOut       = false      -- true once we reported our own elimination
                                  -- (or we're a spectator, not a participant)
local derbyRunTime   = 0          -- local seconds since this derby went running
local derbyWarnShown = false      -- whether the UI currently shows a warning

local function derbyPushWarning()
  guihooks.trigger('RaceManagerDerbyWarning', {
    oob     = derbyOobLeft,
    stopped = derbyDemoLeft,
  })
  derbyWarnShown = (derbyOobLeft ~= nil) or (derbyDemoLeft ~= nil)
end

local function derbyClearWarnings()
  derbyOobLeft, derbyDemoLeft = nil, nil
  if derbyWarnShown then derbyPushWarning() end
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
local function derbyLocalServerId()
  if MPConfig and MPConfig.getPlayerServerID then
    local ok, id = pcall(MPConfig.getPlayerServerID)
    if ok then return tonumber(id) end
  end
  return nil
end

local function derbyUpdate(dt)
  if derbyPhase ~= 'running' or derbyOut then
    derbyClearWarnings()
    return
  end
  derbyRunTime = derbyRunTime + dt
  local veh = playerVehicle()
  if not veh then
    derbyClearWarnings()
    return
  end
  local changed = false

  -- Out-of-bounds check (needs a real polygon: at least 3 markers).
  if #derbyBoundary >= 3 then
    local pos = veh:getPosition()
    if derbyPointInPolygon(pos.x, pos.y, derbyBoundary) then
      if derbyOobLeft then derbyOobLeft = nil; changed = true end
    else
      if not derbyOobLeft then
        derbyOobLeft = derbyOobLimit
      else
        derbyOobLeft = derbyOobLeft - dt
      end
      changed = true
      if derbyOobLeft <= 0 then
        derbyOut = true
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
  if speed > DERBY_STOP_SPEED or derbyRunTime < DERBY_START_GRACE then
    if derbyDemoLeft then derbyDemoLeft = nil; changed = true end
  else
    if not derbyDemoLeft then
      derbyDemoLeft = derbyDemoLimit
    else
      derbyDemoLeft = derbyDemoLeft - dt
    end
    changed = true
    if derbyDemoLeft <= 0 then
      derbyOut = true
      derbyClearWarnings()
      if inMultiplayer() then TriggerServerEvent('RM_DerbyDemolished', '') end
      log('I', 'raceManager', 'Derby: stopped timer expired, reported demolition')
      return
    end
  end

  if changed then derbyPushWarning() end
end

-- Boundary visualization: red poles at each marker, a rope along the
-- perimeter (closed loop), and a label above marker 1.
local function derbyDrawBoundary()
  if #derbyBoundary == 0 or not debugDrawer then return end
  local color = (derbyPhase == 'running')
    and ColorF(0.9, 0.15, 0.15, 0.9)   -- live arena: red
    or  ColorF(0.9, 0.6, 0.1, 0.8)     -- setup/finished: amber
  local up = vec3(0, 0, DERBY_POLE_HEIGHT)
  for i, m in ipairs(derbyBoundary) do
    local base = vec3(m.x, m.y, m.z)
    debugDrawer:drawCylinder(base, base + up, DERBY_POLE_RADIUS, color)
    local nxt = derbyBoundary[i % #derbyBoundary + 1]
    if nxt and #derbyBoundary > 1 then
      local a = base + vec3(0, 0, DERBY_POLE_HEIGHT * 0.5)
      local b = vec3(nxt.x, nxt.y, nxt.z) + vec3(0, 0, DERBY_POLE_HEIGHT * 0.5)
      debugDrawer:drawCylinder(a, b, DERBY_POLE_RADIUS * 0.35, color)
    end
  end
  local first = derbyBoundary[1]
  debugDrawer:drawTextAdvanced(
    vec3(first.x, first.y, first.z + DERBY_POLE_HEIGHT + 0.8),
    String('DERBY BOUNDARY (' .. #derbyBoundary .. ')'),
    ColorF(1, 1, 1, 1), true, false, ColorI(120, 0, 0, 180))
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

function M.derbySetConfig(oobLimit, demoLimit)
  if inMultiplayer() then
    TriggerServerEvent('RM_DerbySetConfig', jsonEncode({
      oobLimit = tonumber(oobLimit), demoLimit = tonumber(demoLimit),
    }))
  end
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
  else
    guihooks.trigger('RaceManagerDerby', {
      derbyPhase = 'idle', oobLimit = derbyOobLimit, demoLimit = derbyDemoLimit,
      derbyTime = 0, boundary = {}, players = {},
    })
  end
end

-- --- Derby server -> client ------------------------------------------------

local function onDerbyUpdate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end

  local newPhase = data.derbyPhase or 'idle'
  if newPhase == 'running' and derbyPhase ~= 'running' then
    -- Fresh derby: re-arm local detection from a clean slate.
    derbyOut = false
    derbyRunTime = 0
    derbyClearWarnings()
  elseif newPhase ~= 'running' then
    derbyClearWarnings()
  end
  derbyPhase = newPhase

  derbyOobLimit  = tonumber(data.oobLimit)  or derbyOobLimit
  derbyDemoLimit = tonumber(data.demoLimit) or derbyDemoLimit

  local boundary = {}
  if type(data.boundary) == 'table' then
    for i, m in ipairs(data.boundary) do
      local x, y, z = tonumber(m.x), tonumber(m.y), tonumber(m.z)
      if x and y and z then boundary[#boundary + 1] = { x = x, y = y, z = z } end
    end
  end
  derbyBoundary = boundary

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
      if mine.status ~= 'alive' then derbyOut = true end
    elseif derbyPhase == 'running' then
      derbyOut = true
    end
  end

  guihooks.trigger('RaceManagerDerby', data)
end

-- ===========================================================================
-- End of DEMO DERBY module
-- ===========================================================================

function M.onUpdate(dt)
  localTime = localTime + dt
  checkGates()
  reportProgress(dt)        -- live position telemetry (distance to next gate)
  drawGates()
  spectatorUpdate(dt)       -- Module 1: keep a DNF'd driver in freecam
  vehicleConfigUpdate(dt)   -- Module 4: declare setup changes to the server
  derbyUpdate(dt)
  derbyDrawBoundary()
end

-- ---------------------------------------------------------------------------
-- Checkpoint editor API (called by the UI app)
-- ---------------------------------------------------------------------------
-- Which route the editor is currently building: the main lap or the joker
-- route. Everything below (+ Checkpoint Here, Undo, the list) follows it.
function M.setEditorTarget(target)
  editorTarget = (tostring(target or 'main') == 'joker') and 'joker' or 'main'
  pushRouteState()
  log('I', 'raceManager', 'Editor target route: ' .. editorTarget)
end

local function activeEditorRoute()
  return editorTarget == 'joker' and jokerRoute or route
end

function M.editorAdd()
  local veh = playerVehicle()
  if not veh then
    log('W', 'raceManager', 'Editor: no player vehicle, cannot place checkpoint')
    return
  end
  local pos = veh:getPosition()
  local dir = veh:getDirectionVector()
  local len = math.sqrt(dir.x * dir.x + dir.y * dir.y)
  local hx, hy = 0, 1
  if len > 1e-4 then hx, hy = dir.x / len, dir.y / len end
  local target = activeEditorRoute()
  target[#target + 1] = { x = pos.x, y = pos.y, z = pos.z, hx = hx, hy = hy }
  pushRouteState()
end

function M.editorUndo()
  local target = activeEditorRoute()
  if #target > 0 then
    target[#target] = nil
    if editorTarget == 'joker' then
      if jokerArmed > #jokerRoute then jokerArmed = math.max(#jokerRoute, 1) end
    elseif armedWp > #route then
      armedWp = math.max(#route, 1)
    end
    pushRouteState()
  end
end

function M.editorClear()
  -- Clearing the joker route on its own must not wipe the main lap.
  if editorTarget == 'joker' then
    jokerRoute   = {}
    jokerArmed   = 1
    jokerTaken   = false
    jokerLapUsed = nil
    pushRouteState()
    log('I', 'raceManager', 'Joker route cleared')
    return
  end
  clearTrackState('editor clear')
end

function M.setCheckpointWidth(w)
  checkpointWidth = clampWidth(w)
  pushRouteState()
end

function M.setCheckpointHeight(h)
  checkpointHeight = clampHeight(h)
  pushRouteState()
end

function M.setCheckpointDepth(d)
  checkpointDepth = clampDepth(d)
  pushRouteState()
end

-- Per-checkpoint override editor. index is 1-based into the placed route; a
-- nil/blank/non-positive value for a dimension clears that override so the gate
-- falls back to the global default. Pass all three blank to fully reset a gate.
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
  wp.depth  = opt(d, clampDepth)
  pushRouteState()
end

function M.editorSave()
  if #route == 0 then
    log('W', 'raceManager', 'Editor: nothing to save')
    return
  end
  jsonWriteFile(ROUTE_FILE, {
    version = 4,
    width   = checkpointWidth,
    height  = checkpointHeight,
    depth   = checkpointDepth,
    waypoints = route,
    joker     = jokerRoute,
  }, true)
  log('I', 'raceManager', 'Editor: saved ' .. #route .. ' checkpoints ('
    .. #jokerRoute .. ' joker) to ' .. ROUTE_FILE)
  guihooks.trigger('RaceManagerEditorMsg', {
    msg = 'Saved ' .. #route .. ' checkpoints'
      .. (#jokerRoute > 0 and (' + ' .. #jokerRoute .. ' joker gates') or ''),
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
  local data = jsonReadFile(ROUTE_FILE)
  if type(data) ~= 'table' or type(data.waypoints) ~= 'table' or #data.waypoints == 0 then
    log('W', 'raceManager', 'Editor: no saved route at ' .. ROUTE_FILE)
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'No saved route found' })
    return
  end
  if data.version == 2 or data.version == 3 or data.version == 4 then
    route = data.waypoints
    checkpointWidth  = clampWidth(data.width or DEFAULT_WIDTH)
    checkpointHeight = clampHeight(data.height or DEFAULT_HEIGHT)
    checkpointDepth  = clampDepth(data.depth or DEFAULT_DEPTH)
    jokerRoute = (type(data.joker) == 'table') and data.joker or {}
  else
    route = migrateV1(data.waypoints)
    jokerRoute = {}
  end
  armedWp    = math.max(#route, 1)
  jokerArmed = 1
  pushRouteState()
  guihooks.trigger('RaceManagerEditorMsg', {
    msg = 'Loaded ' .. #route .. ' checkpoints'
      .. (#jokerRoute > 0 and (' + ' .. #jokerRoute .. ' joker gates') or ''),
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
      if tonumber(wp.depth)  then out[i].depth  = clampDepth(wp.depth)   end
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
  local payload = jsonEncode({
    name        = name,
    width       = clampWidth(checkpointWidth),
    height      = clampHeight(checkpointHeight),
    depth       = clampDepth(checkpointDepth),
    checkpoints = cps,
    joker       = jokerCps,
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

  -- League regulations arrive with every state broadcast (Modules 1 & 2).
  if type(data.maxResets) == 'number' then maxResets = math.floor(data.maxResets) end
  jokerEnabled = data.jokerEnabled == true

  local newPhase = data.phase or 'waiting'
  if newPhase ~= phase then
    phase = newPhase
    -- Any session transition re-arms local detection from a clean slate:
    -- quali start begins a fresh out-lap, GO starts lap 1 at the line.
    resetLapTracking()
  end
  totalLaps = data.totalLaps or totalLaps

  guihooks.trigger('RaceManagerUpdate', data)
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
  local source = (ok and type(data) == 'table' and data.source) and tostring(data.source) or nil
  releaseSpectator(source)
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
local function onGarageResult(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  editorMsg(tostring(data.message or ''))
  guihooks.trigger('RaceManagerGarageResult', data)
end

local function onServerCountdown(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
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
      if tonumber(cp.depth)  then out[i].depth  = clampDepth(cp.depth)   end
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
  clearTrackState('applying layout "' .. tostring(data.name) .. '"')
  route      = cps
  jokerRoute = jokerCps
  checkpointWidth  = clampWidth(data.width or checkpointWidth)
  checkpointHeight = clampHeight(data.height or checkpointHeight)
  checkpointDepth  = clampDepth(data.depth or checkpointDepth)
  resetLapTracking()
  editorMsg('Loaded layout "' .. tostring(data.name) .. '" (' .. #route .. ' gates'
    .. (#jokerRoute > 0 and (' + ' .. #jokerRoute .. ' joker') or '') .. ')')
  log('I', 'raceManager', 'Applied server layout "' .. tostring(data.name)
    .. '" with ' .. #route .. ' checkpoints and ' .. #jokerRoute .. ' joker gates')
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
  guihooks.trigger('RaceManagerAuth', { success = data.success == true })
  log('I', 'raceManager', 'Login result: ' .. tostring(data.success == true))
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
    -- meant to stay usable single-player, so grant local admin outright.
    guihooks.trigger('RaceManagerAuth', { success = true, offline = true })
  end
end

-- Drop admin rights (UI "Log out" / back-to-login). Offline there is no server
-- session to clear, so this is purely a UI-side action there.
function M.logout()
  if inMultiplayer() then TriggerServerEvent('RM_Logout', '') end
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
    guihooks.trigger('RaceManagerUpdate', { phase = 'waiting', raceTime = 0, totalLaps = totalLaps, drivers = {} })
    guihooks.trigger('RaceManagerAuth', { success = true, offline = true })
    log('W', 'raceManager', 'Racing is multiplayer-only; the checkpoint editor works offline')
  end
end

function M.onExtensionLoaded()
  if inMultiplayer() and AddEventHandler then
    AddEventHandler('RM_Update', onServerUpdate)
    AddEventHandler('RM_Countdown', onServerCountdown)
    AddEventHandler('RM_Layouts', onLayoutList)
    AddEventHandler('RM_ApplyLayout', onApplyLayout)
    AddEventHandler('RM_ClearTrack', onClearTrack)
    AddEventHandler('RM_LoginResult', onLoginResult)
    AddEventHandler('RM_PasswordChanged', onPasswordChanged)
    -- Module 1: forced spectator mode (used by racing and, separately, by derby)
    AddEventHandler('RM_ForceSpectate', onForceSpectate)
    AddEventHandler('RM_ReleaseSpectate', onReleaseSpectate)
    -- Module 4: garage list enforcement feedback
    AddEventHandler('RM_VehicleRejected', onVehicleRejected)
    AddEventHandler('RM_GarageResult', onGarageResult)
    AddEventHandler('RM_DerbyUpdate', onDerbyUpdate)  -- Demo Derby module
  end
  log('I', 'raceManager', 'Race Manager client bridge loaded (multiplayer=' .. tostring(inMultiplayer()) .. ')')
end

function M.onExtensionUnloaded()
  phase = 'waiting'
  -- The extension stays resident across sessions (manual unload mode), so an
  -- explicit purge here is what stops checkpoints leaking into the next one.
  clearTrackState('extension unloaded')
  -- Regulation state must not survive either: a stale spectator lock would
  -- leave the next session's driver stuck in freecam.
  releaseSpectator(nil)
  maxResets       = -1
  resetsUsed      = 0
  jokerEnabled    = false
  editorTarget    = 'main'
  lastReportedSig = nil
  -- Same purge for the isolated derby module: markers and warnings must not
  -- survive into the next session.
  derbyPhase    = 'idle'
  derbyBoundary = {}
  derbyOut      = false
  derbyClearWarnings()
end

return M
