local M = {}

local raceState = {
  raceStartTime = nil,
  raceDuration = 0,
  activeVehicles = {},
  standings = {}
}

local function formatTime(seconds)
  if not seconds or seconds < 0 then
    return '--:--.---'
  end

  local minutes = math.floor(seconds / 60)
  local secs = seconds - (minutes * 60)
  return string.format('%02d:%06.3f', minutes, secs)
end

local function formatGap(seconds)
  if seconds == nil then
    return '---'
  end

  if seconds < 0.001 then
    return '+0.000'
  end

  return string.format('+%.3f', seconds)
end

local function isStartFinishWaypoint(waypointKey)
  if waypointKey == '' then
    return false
  end

  local key = string.lower(waypointKey)
  return key:find('start', 1, true) ~= nil or key:find('finish', 1, true) ~= nil
end

local function safeVehicleName(vid)
  local veh = be and be:getObjectByID(vid)
  if veh and veh.getName then
    local name = veh:getName()
    if name and name ~= '' then
      return name
    end
  end

  return tostring(vid)
end

local function ensureVehicleState(vid)
  if not raceState.activeVehicles[vid] then
    raceState.activeVehicles[vid] = {
      id = vid,
      driverName = safeVehicleName(vid),
      currentLap = 0,
      currentLapStart = nil,
      lastLap = nil,
      bestLap = nil,
      totalTime = 0,
      totalDistance = 0,
      sectorIndex = 0,
      lastWaypointKey = nil,
      sectorTimestamps = {},
      lastEventTime = nil,
      crashedOrReset = false,
      pos = 0,
      gapToLeader = nil,
      gapToAhead = nil
    }
  end

  local state = raceState.activeVehicles[vid]
  state.driverName = safeVehicleName(vid)
  return state
end

local function normalizeTriggerData(data)
  if type(data) ~= 'table' then
    return nil
  end

  local vid = data.vehId or data.vehicleId or data.objectId or data.vid
  if not vid then
    return nil
  end

  return {
    vehId = vid,
    waypoint = data.waypoint or data.triggerName or data.triggerId,
    lap = data.lap,
    sector = data.sector or data.split,
    progress = data.progress or data.distance or data.trackProgress,
    timestamp = data.time
  }
end

local function recalculateStandings(now)
  local rows = {}
  for _, v in pairs(raceState.activeVehicles) do
    rows[#rows + 1] = v
  end

  table.sort(rows, function(a, b)
    if a.currentLap ~= b.currentLap then
      return a.currentLap > b.currentLap
    end

    if a.sectorIndex ~= b.sectorIndex then
      return a.sectorIndex > b.sectorIndex
    end

    if a.totalDistance ~= b.totalDistance then
      return a.totalDistance > b.totalDistance
    end

    return a.totalTime < b.totalTime
  end)

  local leader = rows[1]
  for i, v in ipairs(rows) do
    v.pos = i

    if leader then
      if leader.currentLap ~= v.currentLap then
        local lapDiff = leader.currentLap - v.currentLap
        v.gapToLeader = lapDiff .. 'L'
      else
        v.gapToLeader = formatGap(math.max(0, v.totalTime - leader.totalTime))
      end

      if i > 1 then
        local ahead = rows[i - 1]
        if ahead.currentLap ~= v.currentLap then
          local aheadLapDiff = ahead.currentLap - v.currentLap
          v.gapToAhead = aheadLapDiff .. 'L'
        else
          v.gapToAhead = formatGap(math.max(0, v.totalTime - ahead.totalTime))
        end
      else
        v.gapToAhead = '---'
      end
    end
  end

  raceState.standings = rows
end

local function pushUpdate(now)
  recalculateStandings(now)

  local payload = {
    raceDuration = raceState.raceDuration,
    raceDurationFormatted = formatTime(raceState.raceDuration),
    vehicles = {}
  }

  for _, v in ipairs(raceState.standings) do
    payload.vehicles[#payload.vehicles + 1] = {
      id = v.id,
      driverName = v.driverName,
      pos = v.pos,
      currentLap = v.currentLap,
      bestLap = v.bestLap,
      bestLapFormatted = formatTime(v.bestLap),
      lastLap = v.lastLap,
      lastLapFormatted = formatTime(v.lastLap),
      totalTime = v.totalTime,
      totalTimeFormatted = formatTime(v.totalTime),
      gapToLeader = v.gapToLeader,
      gapToAhead = v.gapToAhead,
      crashedOrReset = v.crashedOrReset
    }
  end

  guiHooks.trigger('RaceManagerUpdate', payload)
end

local function consumeWaypoint(data)
  local evt = normalizeTriggerData(data)
  if not evt then
    return
  end

  local now = evt.timestamp or (Engine and Engine.Platform and Engine.Platform.getRuntime and Engine.Platform.getRuntime()) or os.clock()

  if not raceState.raceStartTime then
    raceState.raceStartTime = now
  end

  raceState.raceDuration = math.max(0, now - raceState.raceStartTime)

  local vehicle = ensureVehicleState(evt.vehId)
  vehicle.crashedOrReset = false
  vehicle.lastEventTime = now
  vehicle.totalTime = math.max(0, now - raceState.raceStartTime)

  if evt.progress then
    vehicle.totalDistance = math.max(vehicle.totalDistance, evt.progress)
  end

  if evt.sector then
    vehicle.sectorIndex = tonumber(evt.sector) or vehicle.sectorIndex
    vehicle.sectorTimestamps[vehicle.sectorIndex] = now
  end

  local waypointKey = tostring(evt.waypoint or '')
  local lapValue = tonumber(evt.lap)
  if not lapValue and isStartFinishWaypoint(waypointKey) and vehicle.lastWaypointKey == waypointKey then
    lapValue = vehicle.currentLap + 1
  end

  if lapValue and lapValue > vehicle.currentLap then
    if vehicle.currentLapStart then
      local completedLap = now - vehicle.currentLapStart
      if completedLap > 0.001 then
        vehicle.lastLap = completedLap
        if not vehicle.bestLap or completedLap < vehicle.bestLap then
          vehicle.bestLap = completedLap
        end
      end
    end

    vehicle.currentLap = lapValue
    vehicle.currentLapStart = now
    vehicle.sectorIndex = 0
    vehicle.sectorTimestamps = {}
    vehicle.lastWaypointKey = waypointKey
  elseif waypointKey ~= '' and waypointKey ~= vehicle.lastWaypointKey then
    vehicle.lastWaypointKey = waypointKey
  end

  if not vehicle.currentLapStart then
    vehicle.currentLapStart = now
  end

  pushUpdate(now)
end

local function markVehicleReset(vid)
  if type(vid) == 'table' then
    vid = vid.vehId or vid.vehicleId or vid.objectId or vid.id
  end

  local vehicle = raceState.activeVehicles[vid]
  if vehicle then
    vehicle.crashedOrReset = true
    vehicle.totalDistance = 0
    vehicle.sectorIndex = 0
    vehicle.sectorTimestamps = {}
    vehicle.lastWaypointKey = nil
    pushUpdate((Engine and Engine.Platform and Engine.Platform.getRuntime and Engine.Platform.getRuntime()) or os.clock())
  end
end

local function resetRace()
  raceState = {
    raceStartTime = nil,
    raceDuration = 0,
    activeVehicles = {},
    standings = {}
  }
  pushUpdate((Engine and Engine.Platform and Engine.Platform.getRuntime and Engine.Platform.getRuntime()) or os.clock())
end

local function onUpdate(dtReal, dtSim)
  if not raceState.raceStartTime then
    return
  end

  local now = (Engine and Engine.Platform and Engine.Platform.getRuntime and Engine.Platform.getRuntime()) or os.clock()
  raceState.raceDuration = math.max(0, now - raceState.raceStartTime)

  pushUpdate(now)
end

M.onRaceTrigger = consumeWaypoint
M.onRaceWaypointReached = consumeWaypoint
M.onVehicleDestroyed = markVehicleReset
M.onVehicleReset = markVehicleReset
M.onVehicleResetted = markVehicleReset
M.onClientEndMission = resetRace
M.onExtensionUnloaded = resetRace
M.onUpdate = onUpdate

return M
