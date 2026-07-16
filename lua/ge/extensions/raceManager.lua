-- Race Manager - client GE extension (BeamMP bridge)
--
-- Multiplayer-only. The BeamMP server (server/RaceManager/main.lua) owns the
-- race state; this extension does the two things only a client can do:
--   1. Detect waypoint trigger hits for the LOCAL player's vehicle (the
--      server has no physics access) and report them upstream.
--   2. Receive the server's standings broadcast and hand it to the UI app.
--
-- Runs in BeamNG's GE Lua (LuaJIT / Lua 5.1 semantics) and talks to the
-- server through BeamMP's client bridge (TriggerServerEvent / AddEventHandler).
--
-- Author: Phoenix

local M = {}

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local TRIGGER_DEBOUNCE = 1.0   -- seconds; ignore duplicate trigger hits
local MIN_LAP_TIME     = 5.0   -- seconds; shorter laps are glitches, not sent

-- ---------------------------------------------------------------------------
-- Local state (own vehicle only -- everyone else's progress comes from the server)
-- ---------------------------------------------------------------------------
local raceActive       = false  -- mirrored from server broadcasts
local localTime        = 0      -- local clock for lap timing (high resolution)
local lapStartTime     = nil
local lastWaypoint     = -1
local lastTriggerStamp = -math.huge
local knownWaypoints   = 0      -- highest waypoint index seen + 1

local function inMultiplayer()
  return MPGameNetwork ~= nil and TriggerServerEvent ~= nil
end

-- ---------------------------------------------------------------------------
-- Waypoint detection (local vehicle only)
-- ---------------------------------------------------------------------------
local function handleWaypoint(vehId, wpIndex)
  if not raceActive then return end
  if vehId ~= be:getPlayerVehicleID(0) then return end

  -- Debounce: physics can fire the same trigger several times as the
  -- vehicle's bounding box crosses it.
  if localTime - lastTriggerStamp < TRIGGER_DEBOUNCE and wpIndex == lastWaypoint then
    return
  end
  lastTriggerStamp = localTime

  if wpIndex + 1 > knownWaypoints then
    knownWaypoints = wpIndex + 1
  end

  -- Reject out-of-order hits (spun backwards through a gate, clipped a
  -- different sector). Allowed: next sequential waypoint, or 0 to close a lap.
  local expected = (lastWaypoint + 1) % math.max(knownWaypoints, 1)
  if wpIndex ~= expected and wpIndex ~= 0 then return end

  local payload = { wp = wpIndex }
  if wpIndex == 0 then
    if lapStartTime then
      local lapTime = localTime - lapStartTime
      if lapTime < MIN_LAP_TIME then return end  -- duplicate start-line hit
      payload.lapTime = lapTime
    end
    lapStartTime = localTime
  end

  lastWaypoint = wpIndex
  if inMultiplayer() then
    TriggerServerEvent('RM_WaypointHit', jsonEncode(payload))
  end
end

-- ---------------------------------------------------------------------------
-- Game engine hooks
-- ---------------------------------------------------------------------------

-- Scenario/track waypoint hook (BeamNG scenario system).
function M.onRaceWaypointReached(data)
  if not data then return end
  local vehId = data.vehId or data.vehicleId
  if not vehId then return end
  handleWaypoint(vehId, data.index or 0)
end

-- BeamNGTrigger objects placed on the track. Trigger names must follow the
-- convention 'race_wp_<index>' (race_wp_0 = start/finish line).
function M.onBeamNGTrigger(data)
  if not data or data.event ~= 'enter' then return end
  local idx = tonumber(string.match(data.triggerName or '', '^race_wp_(%d+)$'))
  if not idx then return end
  handleWaypoint(data.subjectID, idx)
end

-- Own vehicle recovered/reset: invalidate the lap in progress so a recovery
-- can't produce an impossibly fast lap.
function M.onVehicleResetted(vehId)
  if vehId == be:getPlayerVehicleID(0) then
    lapStartTime = nil
  end
end

function M.onUpdate(dt)
  localTime = localTime + dt
end

-- ---------------------------------------------------------------------------
-- Server -> client: standings broadcast, forwarded straight to the UI app
-- ---------------------------------------------------------------------------
local function onServerUpdate(rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end

  local wasActive = raceActive
  raceActive = data.raceActive == true
  if raceActive and not wasActive then
    -- Fresh race: reset local lap tracking.
    lapStartTime = nil
    lastWaypoint = -1
    lastTriggerStamp = -math.huge
    knownWaypoints = 0
  end

  guihooks.trigger('RaceManagerUpdate', data)
end

-- ---------------------------------------------------------------------------
-- Public API (called by the UI app) -- all commands go to the server
-- ---------------------------------------------------------------------------
function M.startRace()
  if inMultiplayer() then TriggerServerEvent('RM_Start', '') end
end

function M.stopRace()
  if inMultiplayer() then TriggerServerEvent('RM_Stop', '') end
end

function M.resetRace()
  if inMultiplayer() then TriggerServerEvent('RM_Reset', '') end
end

function M.requestState()
  if inMultiplayer() then
    TriggerServerEvent('RM_RequestState', '')
  else
    -- Not on a BeamMP server: tell the UI there's nothing to show.
    guihooks.trigger('RaceManagerUpdate', { raceActive = false, raceTime = 0, standings = {} })
    log('W', 'raceManager', 'Race Manager is multiplayer-only; join a BeamMP server running the RaceManager plugin')
  end
end

function M.onExtensionLoaded()
  if inMultiplayer() and AddEventHandler then
    AddEventHandler('RM_Update', onServerUpdate)
  end
  log('I', 'raceManager', 'Race Manager client bridge loaded (multiplayer=' .. tostring(inMultiplayer()) .. ')')
end

function M.onExtensionUnloaded()
  raceActive = false
end

return M
