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

function M.onUpdate(dt)
  localTime = localTime + dt
  checkGates()
  drawGates()
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
  route = {}
  armedWp = 1
  pushRouteState()
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
  end
  log('I', 'raceManager', 'Race Manager client bridge loaded (multiplayer=' .. tostring(inMultiplayer()) .. ')')
end

function M.onExtensionUnloaded()
  phase = 'waiting'
end

return M
