-- Race Manager - BeamMP server plugin (Lua 5.3)
--
-- Authoritative race state. Clients (lua/ge/extensions/raceManager.lua)
-- detect waypoint trigger hits locally -- the server has no physics access --
-- and report them here. The server validates progression, computes standings
-- and gaps, and broadcasts the leaderboard to every connected client.
--
-- Author: Phoenix

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local TICK_MS          = 100   -- server clock resolution (also gap resolution)
local PUSH_EVERY_TICKS = 5     -- broadcast standings every N ticks (500 ms)
local MIN_LAP_TIME     = 5.0   -- seconds; client-reported laps below this are rejected

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local race = {
  active         = false,
  time           = 0.0,   -- seconds since race start (advanced by RM_Tick)
  totalWaypoints = 0,     -- learned from highest waypoint index reported
}
local players = {}        -- [playerID] = per-player record
local tickCounter = 0

local function newRecord(pid)
  return {
    id               = pid,
    name             = MP.GetPlayerName(pid) or ('Player ' .. pid),
    currentLap       = 0,
    lastLap          = nil,
    bestLap          = nil,
    lastWaypoint     = -1,
    lastWaypointTime = 0,      -- race.time at last accepted waypoint hit
    finished         = false,
    dnf              = false,
  }
end

local function ensurePlayer(pid)
  if not players[pid] then
    players[pid] = newRecord(pid)
  end
  return players[pid]
end

-- ---------------------------------------------------------------------------
-- Standings
-- ---------------------------------------------------------------------------
local function progressScore(rec)
  local wpPerLap = math.max(race.totalWaypoints, 1)
  return rec.currentLap * wpPerLap + (rec.lastWaypoint + 1)
end

local function compareStandings(a, b)
  if a.dnf ~= b.dnf then return not a.dnf end
  local pa, pb = progressScore(a), progressScore(b)
  if pa ~= pb then return pa > pb end
  return a.lastWaypointTime < b.lastWaypointTime
end

local function lapsDown(front, behind)
  return math.max(front.currentLap - behind.currentLap, 0)
end

local function buildStandings()
  local list = {}
  for _, rec in pairs(players) do
    list[#list + 1] = rec
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
    standings[#standings + 1] = {
      pos        = pos,
      id         = rec.id,
      name       = rec.name,
      currentLap = rec.currentLap + 1,   -- show lap in progress, 1-based
      lastLap    = rec.lastLap,
      bestLap    = rec.bestLap,
      gapLeader  = gapLeader,
      gapAhead   = gapAhead,
      dnf        = rec.dnf,
      finished   = rec.finished,
    }
  end
  return standings
end

local function broadcastState(targetPid)
  local payload = Util.JsonEncode({
    raceActive = race.active,
    raceTime   = race.time,
    standings  = buildStandings(),
  })
  MP.TriggerClientEvent(targetPid or -1, 'RM_Update', payload)
end

-- ---------------------------------------------------------------------------
-- Event handlers (registered in onInit)
-- ---------------------------------------------------------------------------

-- Client reports a validated waypoint hit.
-- data: JSON { wp = <index>, lapTime = <seconds, only when wp 0 closes a lap> }
function RM_onWaypointHit(pid, data)
  if not race.active then return end
  local rec = ensurePlayer(pid)
  if rec.finished or rec.dnf then return end

  local ok, msg = pcall(Util.JsonDecode, data)
  if not ok or type(msg) ~= 'table' then return end
  local wpIndex = math.tointeger(msg.wp)
  if not wpIndex or wpIndex < 0 then return end

  -- Learn track size from the highest index any client reports.
  if wpIndex + 1 > race.totalWaypoints then
    race.totalWaypoints = wpIndex + 1
  end

  -- Server-side progression check (clients also validate, but never trust
  -- a single client for ordering): next sequential waypoint or lap close.
  local expected = (rec.lastWaypoint + 1) % math.max(race.totalWaypoints, 1)
  if wpIndex ~= expected and wpIndex ~= 0 then return end

  if wpIndex == 0 then
    -- Lap closed. Lap time is measured client-side (only the client has a
    -- high-resolution clock aligned with its own physics).
    local lapTime = tonumber(msg.lapTime)
    if lapTime and lapTime >= MIN_LAP_TIME then
      rec.currentLap = rec.currentLap + 1
      rec.lastLap = lapTime
      if not rec.bestLap or lapTime < rec.bestLap then
        rec.bestLap = lapTime
      end
    elseif rec.lastWaypoint ~= -1 then
      -- Lap close without a plausible time: count progress, drop the time.
      rec.currentLap = rec.currentLap + 1
    end
  end

  rec.lastWaypoint = wpIndex
  rec.lastWaypointTime = race.time
end

function RM_onStart(pid)
  players = {}
  race.time = 0.0
  race.totalWaypoints = 0
  race.active = true
  for id, name in pairs(MP.GetPlayers()) do
    ensurePlayer(id).name = name
  end
  broadcastState()
  print('[RaceManager] Race started by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_onStop(pid)
  race.active = false
  broadcastState()
  print('[RaceManager] Race stopped by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_onReset(pid)
  players = {}
  race.time = 0.0
  race.totalWaypoints = 0
  race.active = false
  broadcastState()
end

-- Client asks for current state (UI app just opened).
function RM_onRequestState(pid)
  broadcastState(pid)
end

function RM_Tick()
  if not race.active then return end
  race.time = race.time + TICK_MS / 1000.0
  tickCounter = tickCounter + 1
  if tickCounter >= PUSH_EVERY_TICKS then
    tickCounter = 0
    broadcastState()
  end
end

function RM_onPlayerJoin(pid)
  if race.active then
    ensurePlayer(pid)
  end
  broadcastState(pid)
end

function RM_onPlayerDisconnect(pid)
  local rec = players[pid]
  if rec and race.active then
    rec.dnf = true
  end
end

function onInit()
  MP.RegisterEvent('RM_WaypointHit',  'RM_onWaypointHit')
  MP.RegisterEvent('RM_Start',        'RM_onStart')
  MP.RegisterEvent('RM_Stop',         'RM_onStop')
  MP.RegisterEvent('RM_Reset',        'RM_onReset')
  MP.RegisterEvent('RM_RequestState', 'RM_onRequestState')
  MP.RegisterEvent('onPlayerJoin',       'RM_onPlayerJoin')
  MP.RegisterEvent('onPlayerDisconnect', 'RM_onPlayerDisconnect')
  MP.RegisterEvent('RM_Tick', 'RM_Tick')
  MP.CreateEventTimer('RM_Tick', TICK_MS)
  print('[RaceManager] Server plugin loaded')
end
