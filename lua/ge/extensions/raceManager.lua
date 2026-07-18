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
local DEFAULT_WIDTH  = 20       -- meters between the two poles
local MIN_WIDTH      = 2
local MAX_WIDTH      = 120
local POLE_HEIGHT    = 4        -- meters
local POLE_RADIUS    = 0.15    -- meters
local Z_TOLERANCE    = 6        -- max height difference between car and gate at crossing
local LAP_DEBOUNCE   = 5.0      -- seconds; minimum plausible lap, ignores double-fires
local ROUTE_FILE     = 'settings/raceManager/route.json'

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local phase     = 'waiting'  -- mirrored from server broadcasts
local totalLaps = 5          -- mirrored from server broadcasts

-- Checkpoints: ordered list of { x, y, z, hx, hy } where (hx, hy) is the
-- normalized direction of travel captured at placement. The gate line runs
-- perpendicular to it; the last checkpoint is the start/finish line.
local route           = {}
local checkpointWidth = DEFAULT_WIDTH
local visualize       = true

-- Local lap tracking (reset on every session change)
local armedWp      = 1           -- next gate the local car must cross
local timingActive = false       -- quali: false until the first S/F crossing (out-lap)
local lapStart     = 0           -- localTime at the start of the current lap
local localLap     = 1
local localTime    = 0
local prevPos      = nil         -- vehicle position last frame (crossing segment)

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

-- ---------------------------------------------------------------------------
-- UI push helpers
-- ---------------------------------------------------------------------------
local function pushRouteState()
  guihooks.trigger('RaceManagerRoute', {
    waypoints = route,
    nextWp    = armedWp,
    width     = checkpointWidth,
    visualize = visualize,
  })
end

-- ---------------------------------------------------------------------------
-- Gate geometry
-- ---------------------------------------------------------------------------
-- Pole positions: center point offset left/right along the line perpendicular
-- to the stored heading, by half the current gate width.
local function gatePoles(wp)
  local half = checkpointWidth * 0.5
  local rx, ry = wp.hy, -wp.hx  -- right-hand perpendicular of the heading
  return vec3(wp.x - rx * half, wp.y - ry * half, wp.z),
         vec3(wp.x + rx * half, wp.y + ry * half, wp.z)
end

-- True if the movement segment prev -> cur crosses the gate's vertical plane
-- between the poles, travelling in the gate's forward direction.
local function segmentCrossesGate(wp, prev, cur)
  -- Signed distance of both endpoints to the plane through the gate center
  -- with normal = heading (XY only; the poles are vertical).
  local dPrev = (prev.x - wp.x) * wp.hx + (prev.y - wp.y) * wp.hy
  local dCur  = (cur.x  - wp.x) * wp.hx + (cur.y  - wp.y) * wp.hy
  if not (dPrev < 0 and dCur >= 0) then return false end  -- no forward crossing

  -- Intersection point of the segment with the plane.
  local t  = dPrev / (dPrev - dCur)
  local ix = prev.x + (cur.x - prev.x) * t
  local iy = prev.y + (cur.y - prev.y) * t
  local iz = prev.z + (cur.z - prev.z) * t

  -- Must pass between the poles (lateral offset within half the width)...
  local lateral = (ix - wp.x) * wp.hy - (iy - wp.y) * wp.hx
  if math.abs(lateral) > checkpointWidth * 0.5 then return false end
  -- ...and roughly at gate height (rules out bridges/overpasses).
  if math.abs(iz - wp.z) > Z_TOLERANCE then return false end
  return true
end

-- ---------------------------------------------------------------------------
-- Lap logic
-- ---------------------------------------------------------------------------
local function resetLapTracking()
  timingActive = false
  lapStart     = localTime
  localLap     = 1
  prevPos      = nil
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
  armedWp      = 1
  timingActive = false
  localLap     = 1
  lapStart     = localTime
  prevPos      = nil
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

local function checkGates()
  if #route == 0 then return end
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
      pushRouteState()
    end
  end
  prevPos = vec3(pos.x, pos.y, pos.z)
end

-- ---------------------------------------------------------------------------
-- In-world gate visualization: two poles per checkpoint + crossbar
-- ---------------------------------------------------------------------------
local function drawGates()
  if not visualize or #route == 0 or not debugDrawer then return end
  local active = (phase == 'qualifying' or phase == 'racing')
  for i, wp in ipairs(route) do
    local color
    if i == #route then
      color = ColorF(1, 1, 1, 0.9)               -- start/finish: white
    elseif active and i == armedWp then
      color = ColorF(0.2, 0.85, 0.35, 0.9)       -- next target: green
    else
      color = ColorF(1, 0.4, 0, 0.7)             -- rest of route: orange
    end
    local pL, pR = gatePoles(wp)
    local up = vec3(0, 0, POLE_HEIGHT)
    debugDrawer:drawCylinder(pL, pL + up, POLE_RADIUS, color)
    debugDrawer:drawCylinder(pR, pR + up, POLE_RADIUS, color)
    -- Crossbar between the pole tops so the gate reads as one line.
    debugDrawer:drawCylinder(pL + up, pR + up, POLE_RADIUS * 0.5, color)

    local mid = (pL + pR) * 0.5 + vec3(0, 0, POLE_HEIGHT + 0.8)
    local label = (i == #route) and (i .. ' START/FINISH') or ('CP ' .. i)
    debugDrawer:drawTextAdvanced(mid, String(label),
      ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 160))
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
local DERBY_POLE_HEIGHT   = 6     -- boundary poles are taller than gate poles
local DERBY_POLE_RADIUS   = 0.2

local derbyPhase     = 'idle'     -- idle | running | finished (mirrored from server)
local derbyBoundary  = {}         -- ordered polygon vertices { x, y, z }
local derbyOobLimit  = 5          -- seconds (mirrored from server config)
local derbyDemoLimit = 10
local derbyOobLeft   = nil        -- active out-of-bounds countdown, nil = inside
local derbyDemoLeft  = nil        -- active stopped countdown, nil = moving
local derbyOut       = false      -- true once we reported our own elimination
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

  -- Stopped-vehicle ("demolished") check.
  local vel = veh:getVelocity()
  local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
  if speed > DERBY_STOP_SPEED then
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

  -- If the server already knows we're out (e.g. reconnect race), stop policing.
  local myId = derbyLocalServerId()
  if myId and type(data.players) == 'table' then
    for _, p in ipairs(data.players) do
      if tonumber(p.id) == myId and p.status ~= 'alive' then derbyOut = true end
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
  drawGates()
  derbyUpdate(dt)
  derbyDrawBoundary()
end

-- ---------------------------------------------------------------------------
-- Checkpoint editor API (called by the UI app)
-- ---------------------------------------------------------------------------
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
  route[#route + 1] = { x = pos.x, y = pos.y, z = pos.z, hx = hx, hy = hy }
  pushRouteState()
end

function M.editorUndo()
  if #route > 0 then
    route[#route] = nil
    if armedWp > #route then armedWp = math.max(#route, 1) end
    pushRouteState()
  end
end

function M.editorClear()
  clearTrackState('editor clear')
end

function M.setCheckpointWidth(w)
  checkpointWidth = clampWidth(w)
  pushRouteState()
end

function M.editorSave()
  if #route == 0 then
    log('W', 'raceManager', 'Editor: nothing to save')
    return
  end
  jsonWriteFile(ROUTE_FILE, { version = 2, width = checkpointWidth, waypoints = route }, true)
  log('I', 'raceManager', 'Editor: saved ' .. #route .. ' checkpoints to ' .. ROUTE_FILE)
  guihooks.trigger('RaceManagerEditorMsg', { msg = 'Saved ' .. #route .. ' checkpoints' })
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
  if data.version == 2 then
    route = data.waypoints
    checkpointWidth = clampWidth(data.width or DEFAULT_WIDTH)
  else
    route = migrateV1(data.waypoints)
  end
  armedWp = math.max(#route, 1)
  pushRouteState()
  guihooks.trigger('RaceManagerEditorMsg', { msg = 'Loaded ' .. #route .. ' checkpoints' })
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
  local cps = {}
  for i, wp in ipairs(route) do
    local x, y, z = tonumber(wp.x), tonumber(wp.y), tonumber(wp.z)
    if not (x and y and z) then
      log('E', 'raceManager', 'saveLayout: checkpoint ' .. i .. ' has non-numeric coordinates, aborting')
      editorMsg('Save failed: checkpoint ' .. i .. ' is invalid')
      return
    end
    cps[i] = { x = x, y = y, z = z, hx = tonumber(wp.hx) or 0, hy = tonumber(wp.hy) or 1 }
  end
  local payload = jsonEncode({
    name        = name,
    width       = clampWidth(checkpointWidth),
    checkpoints = cps,
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
  local cps = {}
  for i, cp in ipairs(data.checkpoints) do
    local x, y, z = tonumber(cp.x), tonumber(cp.y), tonumber(cp.z)
    if not (x and y and z) then
      log('E', 'raceManager', 'RM_ApplyLayout: checkpoint ' .. i .. ' has invalid coordinates, layout rejected')
      return
    end
    cps[i] = { x = x, y = y, z = z, hx = tonumber(cp.hx) or 0, hy = tonumber(cp.hy) or 1 }
  end
  if #cps == 0 then
    log('E', 'raceManager', 'RM_ApplyLayout: empty checkpoint list, layout rejected')
    return
  end
  local width = clampWidth(data.width or checkpointWidth)
  clearTrackState('applying layout "' .. tostring(data.name) .. '"')
  route = cps
  checkpointWidth = width
  resetLapTracking()
  editorMsg('Loaded layout "' .. tostring(data.name) .. '" (' .. #route .. ' gates)')
  log('I', 'raceManager', 'Applied server layout "' .. tostring(data.name)
    .. '" with ' .. #route .. ' checkpoints')
end

-- Server ordered a full purge (server startup, pre-layout-load, or an
-- explicit clear): delete every checkpoint and its 3D poles right now.
local function onClearTrack(rawData)
  local reason = 'server'
  local ok, data = pcall(jsonDecode, rawData)
  if ok and type(data) == 'table' and data.reason then reason = tostring(data.reason) end
  clearTrackState('server: ' .. reason)
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
    -- editor remains fully usable for building circuits offline.
    guihooks.trigger('RaceManagerUpdate', { phase = 'waiting', raceTime = 0, totalLaps = totalLaps, drivers = {} })
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
    AddEventHandler('RM_DerbyUpdate', onDerbyUpdate)  -- Demo Derby module
  end
  log('I', 'raceManager', 'Race Manager client bridge loaded (multiplayer=' .. tostring(inMultiplayer()) .. ')')
end

function M.onExtensionUnloaded()
  phase = 'waiting'
  -- The extension stays resident across sessions (manual unload mode), so an
  -- explicit purge here is what stops checkpoints leaking into the next one.
  clearTrackState('extension unloaded')
  -- Same purge for the isolated derby module: markers and warnings must not
  -- survive into the next session.
  derbyPhase    = 'idle'
  derbyBoundary = {}
  derbyOut      = false
  derbyClearWarnings()
end

return M
