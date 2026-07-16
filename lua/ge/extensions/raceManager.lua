-- Race Manager - GameEngine extension
-- Tracks all active vehicles, lap/sector timing, and live standings,
-- and streams the state to the RaceManager UI app.
--
-- Author: Phoenix

local M = {}

M.dependencies = {'core_input_bindings'}

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local UI_PUSH_INTERVAL   = 0.10  -- seconds between UI pushes (10 Hz)
local TRIGGER_DEBOUNCE   = 1.0   -- seconds; ignore duplicate waypoint hits per vehicle
local MIN_LAP_TIME       = 5.0   -- seconds; laps shorter than this are treated as glitches

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local raceActive   = false
local raceTime     = 0        -- total race duration (s)
local uiPushTimer  = 0
local totalWaypoints = 0      -- waypoints per lap (learned or set via setWaypointCount)

-- vehicles[vehId] = per-vehicle tracking record
local vehicles = {}

local function newVehicleRecord(vehId)
  local veh = be:getObjectByID(vehId)
  local name = 'Vehicle ' .. tostring(vehId)
  if veh then
    local jbeam = veh:getJBeamFilename() or 'unknown'
    local playerVehId = be:getPlayerVehicleID(0)
    if vehId == playerVehId then
      name = 'Player (' .. jbeam .. ')'
    else
      name = 'AI ' .. tostring(vehId) .. ' (' .. jbeam .. ')'
    end
  end
  return {
    id            = vehId,
    name          = name,
    currentLap    = 0,       -- completed laps; lap in progress is currentLap + 1
    lastLap       = nil,     -- seconds
    bestLap       = nil,     -- seconds
    lapStartTime  = nil,     -- raceTime at which the current lap started
    lastWaypoint  = -1,      -- index of last waypoint hit this lap (-1 = none / pre-start)
    lastWaypointTime = 0,    -- raceTime at last waypoint hit (progress timestamp)
    lastTriggerStamp = -math.huge, -- debounce clock
    sectorTimes   = {},      -- current lap: sectorTimes[wpIdx] = split (s from lap start)
    bestSectors   = {},      -- best split per waypoint index
    finished      = false,
    dnf           = false,
  }
end

local function ensureVehicle(vehId)
  if not vehicles[vehId] then
    vehicles[vehId] = newVehicleRecord(vehId)
  end
  return vehicles[vehId]
end

-- ---------------------------------------------------------------------------
-- Standings / gap computation
-- ---------------------------------------------------------------------------

-- Progress score: laps completed dominate, then waypoints within the lap.
local function progressScore(rec)
  local wpPerLap = math.max(totalWaypoints, 1)
  return rec.currentLap * wpPerLap + (rec.lastWaypoint + 1)
end

-- Sort: DNFs last; more progress first; equal progress -> earlier timestamp wins.
local function compareStandings(a, b)
  if a.dnf ~= b.dnf then return not a.dnf end
  local pa, pb = progressScore(a), progressScore(b)
  if pa ~= pb then return pa > pb end
  return a.lastWaypointTime < b.lastWaypointTime
end

-- Whole laps `behind` trails `front` by.
local function lapsDown(front, behind)
  return math.max(front.currentLap - behind.currentLap, 0)
end

local function buildStandings()
  local list = {}
  for _, rec in pairs(vehicles) do
    table.insert(list, rec)
  end
  table.sort(list, compareStandings)

  local standings = {}
  local leader = list[1]
  for pos, rec in ipairs(list) do
    local gapLeader, gapAhead = nil, nil
    if pos > 1 and leader and not rec.dnf then
      local ahead = list[pos - 1]
      local ldLeader = lapsDown(leader, rec)
      if ldLeader > 0 then
        gapLeader = string.format('+%d L', ldLeader)
      else
        gapLeader = rec.lastWaypointTime - leader.lastWaypointTime
      end
      local ldAhead = lapsDown(ahead, rec)
      if ldAhead > 0 then
        gapAhead = string.format('+%d L', ldAhead)
      else
        gapAhead = rec.lastWaypointTime - ahead.lastWaypointTime
      end
    end
    table.insert(standings, {
      pos        = pos,
      id         = rec.id,
      name       = rec.name,
      currentLap = rec.currentLap + 1,   -- show the lap in progress (1-based)
      lastLap    = rec.lastLap,
      bestLap    = rec.bestLap,
      gapLeader  = gapLeader,
      gapAhead   = gapAhead,
      dnf        = rec.dnf,
      finished   = rec.finished,
    })
  end
  return standings
end

-- ---------------------------------------------------------------------------
-- UI bridge
-- ---------------------------------------------------------------------------
local function pushToUI()
  local data = {
    raceActive = raceActive,
    raceTime   = raceTime,
    standings  = buildStandings(),
  }
  guihooks.trigger('RaceManagerUpdate', data)
end

-- ---------------------------------------------------------------------------
-- Lap / waypoint handling
-- ---------------------------------------------------------------------------
local function completeLap(rec)
  if not rec.lapStartTime then
    rec.lapStartTime = raceTime
    return
  end
  local lapTime = raceTime - rec.lapStartTime
  if lapTime < MIN_LAP_TIME then return end  -- glitch / duplicate start-line hit

  rec.currentLap = rec.currentLap + 1
  rec.lastLap = lapTime
  if not rec.bestLap or lapTime < rec.bestLap then
    rec.bestLap = lapTime
  end
  rec.lapStartTime = raceTime
  rec.sectorTimes = {}
end

-- Core waypoint handler. Safe against simultaneous hits from multiple
-- vehicles: each call carries its own vehicle id and mutates only that
-- vehicle's record (GE Lua is single-threaded, so no locking is needed;
-- events for two vehicles in the same frame are simply processed in order).
local function handleWaypoint(vehId, wpIndex, wpName)
  local rec = ensureVehicle(vehId)
  if rec.finished or rec.dnf then return end

  -- Debounce: physics can fire the same trigger multiple times as the
  -- vehicle's bounding box crosses it.
  if raceTime - rec.lastTriggerStamp < TRIGGER_DEBOUNCE and wpIndex == rec.lastWaypoint then
    return
  end
  rec.lastTriggerStamp = raceTime

  -- Learn track size from the highest waypoint index seen.
  if wpIndex + 1 > totalWaypoints then
    totalWaypoints = wpIndex + 1
  end

  -- Reject out-of-order hits (vehicle spun and rolled backwards through a
  -- trigger, or clipped a different sector gate). Allowed transitions:
  -- next sequential waypoint, or waypoint 0 to close a lap.
  local expected = (rec.lastWaypoint + 1) % math.max(totalWaypoints, 1)
  if wpIndex ~= expected and wpIndex ~= 0 then
    return
  end

  if wpIndex == 0 then
    -- Start/finish line: closes the previous lap (or arms the first one).
    completeLap(rec)
  end

  -- Sector split for the lap in progress.
  if rec.lapStartTime then
    local split = raceTime - rec.lapStartTime
    rec.sectorTimes[wpIndex] = split
    if not rec.bestSectors[wpIndex] or split < rec.bestSectors[wpIndex] then
      rec.bestSectors[wpIndex] = split
    end
  end

  rec.lastWaypoint = wpIndex
  rec.lastWaypointTime = raceTime
end

-- ---------------------------------------------------------------------------
-- Game engine hooks
-- ---------------------------------------------------------------------------

-- Scenario/track waypoint hook (BeamNG scenario system).
function M.onRaceWaypointReached(data)
  if not raceActive or not data then return end
  local vehId = data.vehId or data.vehicleId
  if not vehId then return end
  handleWaypoint(vehId, data.index or 0, data.waypointName or data.name)
end

-- BeamNGTrigger objects placed on the track. Trigger names must follow the
-- convention 'race_wp_<index>' (race_wp_0 = start/finish line).
function M.onBeamNGTrigger(data)
  if not raceActive or not data or data.event ~= 'enter' then return end
  local idx = tonumber(string.match(data.triggerName or '', '^race_wp_(%d+)$'))
  if not idx then return end
  handleWaypoint(data.subjectID, idx, data.triggerName)
end

function M.onVehicleSpawned(vehId)
  ensureVehicle(vehId)
end

function M.onVehicleDestroyed(vehId)
  local rec = vehicles[vehId]
  if rec then rec.dnf = true end
end

-- Vehicle recovered/reset: keep its standing but invalidate the lap in
-- progress so a recovery can't produce an impossibly fast lap.
function M.onVehicleResetted(vehId)
  local rec = vehicles[vehId]
  if not rec then return end
  rec.lapStartTime = nil
  rec.sectorTimes = {}
end

function M.onUpdate(dt)
  if not raceActive then return end
  raceTime = raceTime + dt

  uiPushTimer = uiPushTimer + dt
  if uiPushTimer >= UI_PUSH_INTERVAL then
    uiPushTimer = 0
    pushToUI()
  end
end

-- ---------------------------------------------------------------------------
-- Public API (callable from the UI or the console)
-- ---------------------------------------------------------------------------
function M.startRace()
  vehicles = {}
  raceTime = 0
  uiPushTimer = 0
  raceActive = true
  -- Register every vehicle already in the world.
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh then ensureVehicle(veh:getID()) end
  end
  pushToUI()
  log('I', 'raceManager', 'Race started with ' .. tostring(be:getObjectCount()) .. ' vehicles')
end

function M.stopRace()
  raceActive = false
  pushToUI()
  log('I', 'raceManager', 'Race stopped')
end

function M.resetRace()
  vehicles = {}
  raceTime = 0
  raceActive = false
  totalWaypoints = 0
  pushToUI()
end

-- Optional: tell the manager how many waypoints a lap has, instead of learning it.
function M.setWaypointCount(n)
  totalWaypoints = math.max(tonumber(n) or 0, 0)
end

function M.requestState()
  pushToUI()
end

function M.onExtensionLoaded()
  log('I', 'raceManager', 'Race Manager extension loaded')
end

function M.onExtensionUnloaded()
  raceActive = false
end

return M
