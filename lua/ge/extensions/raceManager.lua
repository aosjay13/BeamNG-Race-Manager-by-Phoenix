-- Race Manager - client GE extension (BeamMP bridge + waypoint editor)
--
-- Multiplayer-only for racing. The BeamMP server (server/RaceManager/main.lua)
-- owns the race state; this extension does what only a client can do:
--   1. Waypoint editor: place/undo/clear waypoints at the local vehicle's
--      position, save/load them as a route file, draw them in-world.
--   2. Detect the LOCAL player's vehicle passing route waypoints in order
--      (the server has no physics access); the last waypoint is the finish
--      line and is reported upstream.
--   3. Receive the server's state broadcasts and hand them to the UI app
--      via guihooks.
--
-- Finish detection works two ways, either is sufficient:
--   a. A route created with the editor (last waypoint = finish).
--   b. A BeamNGTrigger object on the map named 'race_finish'.
--
-- Runs in BeamNG's GE Lua (LuaJIT / Lua 5.1 semantics) and talks to the
-- server through BeamMP's client bridge (TriggerServerEvent / AddEventHandler).
--
-- Author: Phoenix

local M = {}

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local FINISH_DEBOUNCE = 3.0      -- seconds; ignore repeat finish crossings
local DEFAULT_RADIUS  = 10       -- meters; capture radius for new waypoints
local ROUTE_FILE      = 'settings/raceManager/route.json'

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local phase           = 'waiting'  -- mirrored from server broadcasts
local localFinished   = false
local localTime       = 0
local lastFinishStamp = -math.huge

local route     = {}     -- ordered list of { x, y, z, radius }
local nextWp    = 1      -- next route waypoint the local car must hit
local visualize = true   -- draw route markers in-world

local function inMultiplayer()
  return MPGameNetwork ~= nil and TriggerServerEvent ~= nil
end

local function playerPos()
  local veh = be:getPlayerVehicle(0)
  if not veh then return nil end
  return veh:getPosition()
end

-- ---------------------------------------------------------------------------
-- UI push helpers
-- ---------------------------------------------------------------------------
local function pushRouteState()
  guihooks.trigger('RaceManagerRoute', {
    waypoints = route,
    nextWp    = nextWp,
    visualize = visualize,
  })
end

-- ---------------------------------------------------------------------------
-- Finish + waypoint detection
-- ---------------------------------------------------------------------------
local function reportFinish()
  if phase ~= 'racing' or localFinished then return end
  if localTime - lastFinishStamp < FINISH_DEBOUNCE then return end
  lastFinishStamp = localTime
  localFinished = true
  if inMultiplayer() then
    TriggerServerEvent('RM_Finish', '')
  end
end

-- Route a: editor waypoints, enforced in order; last one is the finish.
local function checkRoute()
  if #route == 0 or phase ~= 'racing' or localFinished then return end
  local pos = playerPos()
  if not pos then return end
  local wp = route[nextWp]
  if not wp then return end
  local dx, dy, dz = pos.x - wp.x, pos.y - wp.y, pos.z - wp.z
  if dx * dx + dy * dy + dz * dz <= wp.radius * wp.radius then
    if nextWp >= #route then
      reportFinish()
    else
      nextWp = nextWp + 1
    end
    pushRouteState()
  end
end

-- Route b: BeamNGTrigger object named 'race_finish' placed on the map.
function M.onBeamNGTrigger(data)
  if not data or data.event ~= 'enter' then return end
  if data.triggerName ~= 'race_finish' then return end
  if data.subjectID ~= be:getPlayerVehicleID(0) then return end
  reportFinish()
end

-- ---------------------------------------------------------------------------
-- In-world route visualization
-- ---------------------------------------------------------------------------
local function drawRoute()
  if not visualize or #route == 0 or not debugDrawer then return end
  for i, wp in ipairs(route) do
    local pos = vec3(wp.x, wp.y, wp.z)
    local color
    if i == #route then
      color = ColorF(1, 1, 1, 0.35)          -- finish: white
    elseif phase == 'racing' and i == nextWp then
      color = ColorF(0.2, 0.85, 0.35, 0.4)   -- next target: green
    else
      color = ColorF(1, 0.4, 0, 0.25)        -- rest of route: orange
    end
    debugDrawer:drawSphere(pos, wp.radius, color)
    local label = (i == #route) and (i .. ' FINISH') or tostring(i)
    debugDrawer:drawTextAdvanced(pos + vec3(0, 0, wp.radius + 1), String(label),
      ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 160))
  end
end

function M.onUpdate(dt)
  localTime = localTime + dt
  checkRoute()
  drawRoute()
end

-- ---------------------------------------------------------------------------
-- Waypoint editor API (called by the UI app)
-- ---------------------------------------------------------------------------
function M.editorAdd(radius)
  local pos = playerPos()
  if not pos then
    log('W', 'raceManager', 'Editor: no player vehicle, cannot place waypoint')
    return
  end
  route[#route + 1] = { x = pos.x, y = pos.y, z = pos.z, radius = radius or DEFAULT_RADIUS }
  pushRouteState()
end

function M.editorUndo()
  if #route > 0 then
    route[#route] = nil
    if nextWp > #route then nextWp = math.max(#route, 1) end
    pushRouteState()
  end
end

function M.editorClear()
  route = {}
  nextWp = 1
  pushRouteState()
end

function M.editorSave()
  if #route == 0 then
    log('W', 'raceManager', 'Editor: nothing to save')
    return
  end
  jsonWriteFile(ROUTE_FILE, { version = 1, waypoints = route }, true)
  log('I', 'raceManager', 'Editor: saved ' .. #route .. ' waypoints to ' .. ROUTE_FILE)
  guihooks.trigger('RaceManagerEditorMsg', { msg = 'Saved ' .. #route .. ' waypoints' })
end

function M.editorLoad()
  local data = jsonReadFile(ROUTE_FILE)
  if type(data) ~= 'table' or type(data.waypoints) ~= 'table' or #data.waypoints == 0 then
    log('W', 'raceManager', 'Editor: no saved route at ' .. ROUTE_FILE)
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'No saved route found' })
    return
  end
  route = data.waypoints
  nextWp = 1
  pushRouteState()
  guihooks.trigger('RaceManagerEditorMsg', { msg = 'Loaded ' .. #route .. ' waypoints' })
end

function M.editorToggleVisualize()
  visualize = not visualize
  pushRouteState()
end

-- Console helper kept for compatibility: creates a one-waypoint route
-- (a bare finish line). raceManager.setFinishLine(x, y, z [, radius])
function M.setFinishLine(x, y, z, radius)
  route = { { x = x, y = y, z = z, radius = radius or DEFAULT_RADIUS } }
  nextWp = 1
  pushRouteState()
end

-- ---------------------------------------------------------------------------
-- Server -> client
-- ---------------------------------------------------------------------------
local function onServerUpdate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end

  local wasRacing = (phase == 'racing')
  phase = data.phase or 'waiting'
  if phase == 'racing' and not wasRacing then
    -- Fresh race start: re-arm local detection at the top of the route.
    localFinished = false
    lastFinishStamp = -math.huge
    nextWp = 1
    pushRouteState()
  end

  guihooks.trigger('RaceManagerUpdate', data)
end

local function onServerCountdown(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  guihooks.trigger('RaceManagerCountdown', data)
end

-- ---------------------------------------------------------------------------
-- Race commands (called by the UI app) -- all go to the server
-- ---------------------------------------------------------------------------
function M.setGrid()
  if inMultiplayer() then TriggerServerEvent('RM_SetGrid', '') end
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

function M.requestState()
  pushRouteState()
  if inMultiplayer() then
    TriggerServerEvent('RM_RequestState', '')
  else
    -- Not on a BeamMP server: still push a state so the UI renders, and the
    -- editor remains fully usable for building routes offline.
    guihooks.trigger('RaceManagerUpdate', { phase = 'waiting', raceTime = 0, drivers = {} })
    log('W', 'raceManager', 'Racing is multiplayer-only; the waypoint editor works offline')
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
