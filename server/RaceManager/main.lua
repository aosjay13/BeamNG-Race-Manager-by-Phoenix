-- Race Manager - BeamMP server plugin (Lua 5.3)
--
-- Authoritative session state machine for circuit racing:
--
--   waiting -> qualifying -> grid -> countdown -> racing -> finished
--                 (quali)   (grid locked)          (race)
--
-- Qualifying: clients time their own laps (the server has no physics access)
-- and report each completed lap; the server keeps the Best Lap per driver.
-- Generate Grid sorts drivers fastest-to-slowest by quali Best Lap and locks
-- in starting positions. Race mode shows the grid, then the countdown starts
-- the race. During the race clients report every completed lap; the server
-- tracks Current Lap, race Best Lap, Laps Led (first driver to complete each
-- lap), and flags the finish when a driver completes the configured lap count.
-- All timing that must be fair across drivers (finish order, laps led) is
-- decided by arrival order / the server clock.
--
-- Author: Phoenix

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local TICK_MS            = 100   -- server clock resolution
local PUSH_EVERY_TICKS   = 5     -- broadcast state every N ticks (500 ms)
local COUNTDOWN_FROM     = 3     -- 3, 2, 1, GO!
local DEFAULT_TOTAL_LAPS = 5
local MAX_TOTAL_LAPS     = 500

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local race = {
  phase     = 'waiting',  -- waiting | qualifying | grid | countdown | racing | finished
  time      = 0.0,        -- seconds since GO (advanced by RM_Tick while racing)
  totalLaps = DEFAULT_TOTAL_LAPS,
}
local players = {}          -- [playerID] = per-player record
local tickCounter = 0
local countdownValue = nil  -- current countdown number while phase == 'countdown'
local lapFirsts = {}        -- [lapNumber] = pid of the first driver to complete that lap

local function newRecord(pid)
  return {
    id         = pid,
    name       = MP.GetPlayerName(pid) or ('Player ' .. pid),
    status     = 'waiting',  -- waiting | qualifying | gridded | racing | finished | dnf
    gridPos    = nil,        -- locked-in starting position (Generate Grid)
    qualiBest  = nil,        -- best qualifying lap (seconds)
    raceBest   = nil,        -- best race lap (seconds)
    currentLap = 0,          -- lap the driver is currently on (1-based once racing)
    lapsLed    = 0,          -- laps this driver crossed the line first on
    finishTime = nil,        -- server race clock at final-lap completion
  }
end

local function ensurePlayer(pid)
  if not players[pid] then
    players[pid] = newRecord(pid)
  end
  return players[pid]
end

local function decodeNumber(rawData, field)
  if type(rawData) ~= 'string' or rawData == '' then return nil end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return nil end
  local n = tonumber(data[field])
  return n
end

-- ---------------------------------------------------------------------------
-- Broadcast
-- ---------------------------------------------------------------------------
local function buildDrivers()
  local list = {}
  for _, rec in pairs(players) do
    list[#list + 1] = rec
  end
  if race.phase == 'qualifying' or race.phase == 'waiting' then
    -- Provisional grid order: fastest quali Best Lap first, no-time last.
    table.sort(list, function (a, b)
      local ta, tb = a.qualiBest, b.qualiBest
      if ta and tb then
        if ta ~= tb then return ta < tb end
      elseif ta ~= tb then
        return ta ~= nil  -- drivers with a time ahead of drivers without
      end
      return a.id < b.id
    end)
  else
    -- Race order: finished first (by finish time), then racers by laps
    -- completed (laps led breaks ties), then gridded by position, DNFs last.
    table.sort(list, function (a, b)
      local ra = a.status == 'dnf' and 2 or (a.finishTime and 0 or 1)
      local rb = b.status == 'dnf' and 2 or (b.finishTime and 0 or 1)
      if ra ~= rb then return ra < rb end
      if ra == 0 then return a.finishTime < b.finishTime end
      if a.currentLap ~= b.currentLap then return a.currentLap > b.currentLap end
      if a.lapsLed ~= b.lapsLed then return a.lapsLed > b.lapsLed end
      return (a.gridPos or math.huge) < (b.gridPos or math.huge)
    end)
  end
  return list
end

local function broadcastState(targetPid)
  local payload = Util.JsonEncode({
    phase     = race.phase,
    raceTime  = race.time,
    totalLaps = race.totalLaps,
    drivers   = buildDrivers(),
  })
  MP.TriggerClientEvent(targetPid or -1, 'RM_Update', payload)
end

local function broadcastCountdown(count)
  MP.TriggerClientEvent(-1, 'RM_Countdown', Util.JsonEncode({ count = count }))
end

-- ---------------------------------------------------------------------------
-- Session state machine (UI commands relayed by the client bridge)
-- ---------------------------------------------------------------------------

-- Start Qualifying: snapshot connected players and wipe all session data.
-- Allowed any time outside an active countdown/race.
function RM_onStartQualifying(pid)
  if race.phase == 'countdown' or race.phase == 'racing' then return end
  MP.CancelEventTimer('RM_CountdownTick')
  players = {}
  lapFirsts = {}
  race.time = 0.0
  for id in pairs(MP.GetPlayers()) do
    local rec = ensurePlayer(id)
    rec.status = 'qualifying'
  end
  race.phase = 'qualifying'
  broadcastState()
  print('[RaceManager] Qualifying started by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Generate Grid: sort by quali Best Lap (fastest first, no-time last) and
-- lock in starting positions. Drivers who join afterwards go to the back on
-- the next Generate Grid. Also usable from waiting/finished: with no quali
-- times everyone ties and the grid falls back to join order.
function RM_onGenerateGrid(pid)
  if race.phase == 'countdown' or race.phase == 'racing' then return end
  race.time = 0.0
  lapFirsts = {}
  -- Make sure every connected player has a record so nobody is left off grid.
  for id in pairs(MP.GetPlayers()) do ensurePlayer(id) end
  local ordered = {}
  for _, rec in pairs(players) do ordered[#ordered + 1] = rec end
  table.sort(ordered, function (a, b)
    local ta, tb = a.qualiBest, b.qualiBest
    if ta and tb then
      if ta ~= tb then return ta < tb end
    elseif ta ~= tb then
      return ta ~= nil
    end
    return a.id < b.id
  end)
  for gridPos, rec in ipairs(ordered) do
    rec.gridPos    = gridPos
    rec.status     = 'gridded'
    rec.raceBest   = nil
    rec.currentLap = 0
    rec.lapsLed    = 0
    rec.finishTime = nil
  end
  race.phase = 'grid'
  broadcastState()
  print('[RaceManager] Grid generated by ' .. (MP.GetPlayerName(pid) or pid)
    .. ' (' .. #ordered .. ' drivers, pole: '
    .. (ordered[1] and ordered[1].name or 'n/a') .. ')')
end

-- Host sets the race distance. Locked once the countdown/race is under way.
function RM_onSetTotalLaps(pid, rawData)
  if race.phase == 'countdown' or race.phase == 'racing' then return end
  local n = decodeNumber(rawData, 'laps')
  if not n then return end
  n = math.floor(n)
  if n < 1 then n = 1 elseif n > MAX_TOTAL_LAPS then n = MAX_TOTAL_LAPS end
  race.totalLaps = n
  broadcastState()
  print('[RaceManager] Total laps set to ' .. n .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_onStartCountdown(pid)
  if race.phase ~= 'grid' then return end
  race.phase = 'countdown'
  countdownValue = COUNTDOWN_FROM
  broadcastState()
  broadcastCountdown(countdownValue)
  MP.CreateEventTimer('RM_CountdownTick', 1000)
  print('[RaceManager] Countdown started by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_CountdownTick()
  if race.phase ~= 'countdown' then
    MP.CancelEventTimer('RM_CountdownTick')
    return
  end
  countdownValue = countdownValue - 1
  if countdownValue > 0 then
    broadcastCountdown(countdownValue)
    return
  end
  -- GO!
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(0)
  race.phase = 'racing'
  race.time = 0.0
  lapFirsts = {}
  for _, rec in pairs(players) do
    if rec.status == 'gridded' then
      rec.status     = 'racing'
      rec.currentLap = 1
      rec.raceBest   = nil
      rec.lapsLed    = 0
      rec.finishTime = nil
    end
  end
  broadcastState()
  print('[RaceManager] GO! (' .. race.totalLaps .. ' laps)')
end

-- End Session: during a race anyone still on track becomes DNF; during
-- qualifying the session closes but Best Laps are kept so the grid can
-- still be generated.
function RM_onEndRace(pid)
  if race.phase == 'racing' or race.phase == 'countdown' then
    MP.CancelEventTimer('RM_CountdownTick')
    broadcastCountdown(-1)  -- hide any countdown overlay
    race.phase = 'finished'
    for _, rec in pairs(players) do
      if rec.status == 'racing' or rec.status == 'gridded' then
        rec.status = 'dnf'
      end
    end
    broadcastState()
    print('[RaceManager] Race ended by ' .. (MP.GetPlayerName(pid) or pid))
  elseif race.phase == 'qualifying' then
    race.phase = 'waiting'
    broadcastState()
    print('[RaceManager] Qualifying closed by ' .. (MP.GetPlayerName(pid) or pid))
  end
end

function RM_onResetLeaderboard(pid)
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(-1)
  players = {}
  lapFirsts = {}
  race.phase = 'waiting'
  race.time = 0.0
  for id in pairs(MP.GetPlayers()) do
    ensurePlayer(id)
  end
  broadcastState()
  print('[RaceManager] Session reset by ' .. (MP.GetPlayerName(pid) or pid))
end

-- ---------------------------------------------------------------------------
-- Lap reports from clients
-- ---------------------------------------------------------------------------

-- Qualifying: client completed a timed lap; keep the best.
function RM_onQualiLap(pid, rawData)
  if race.phase ~= 'qualifying' then return end
  local rec = ensurePlayer(pid)
  if rec.status ~= 'qualifying' then rec.status = 'qualifying' end
  local lapTime = decodeNumber(rawData, 'lapTime')
  if not lapTime or lapTime <= 0 then return end
  if not rec.qualiBest or lapTime < rec.qualiBest then
    rec.qualiBest = lapTime
    print(string.format('[RaceManager] %s quali best: %.3fs', rec.name, lapTime))
  end
  broadcastState()
end

-- Race: client crossed the start/finish line after all checkpoints.
-- Server decides Laps Led (first report per lap number wins — one arrival
-- order for everyone) and the finish (lap count reached).
function RM_onLap(pid, rawData)
  if race.phase ~= 'racing' then return end
  local rec = ensurePlayer(pid)
  if rec.status ~= 'racing' then return end
  local lapTime = decodeNumber(rawData, 'lapTime')
  if lapTime and lapTime > 0 and (not rec.raceBest or lapTime < rec.raceBest) then
    rec.raceBest = lapTime
  end

  local completed = rec.currentLap
  if not lapFirsts[completed] then
    lapFirsts[completed] = pid
    rec.lapsLed = rec.lapsLed + 1
  end

  if completed >= race.totalLaps then
    rec.status = 'finished'
    rec.finishTime = race.time
    print(string.format('[RaceManager] %s finished %d laps at %.3fs (led %d)',
      rec.name, completed, race.time, rec.lapsLed))
    -- Everyone done (finished or dnf)? Close the race.
    for _, r in pairs(players) do
      if r.status == 'racing' then
        broadcastState()
        return
      end
    end
    race.phase = 'finished'
    print('[RaceManager] All drivers finished')
  else
    rec.currentLap = completed + 1
  end
  broadcastState()
end

-- Client asks for current state (UI app just opened).
function RM_onRequestState(pid)
  broadcastState(pid)
end

-- ---------------------------------------------------------------------------
-- Clock + lifecycle
-- ---------------------------------------------------------------------------
function RM_Tick()
  if race.phase ~= 'racing' then return end
  race.time = race.time + TICK_MS / 1000.0
  tickCounter = tickCounter + 1
  if tickCounter >= PUSH_EVERY_TICKS then
    tickCounter = 0
    broadcastState()
  end
end

function RM_onPlayerJoin(pid)
  local rec = ensurePlayer(pid)
  -- Joining mid-quali means you can set a time; mid-race you spectate.
  if race.phase == 'qualifying' then rec.status = 'qualifying' end
  broadcastState()
end

function RM_onPlayerDisconnect(pid)
  local rec = players[pid]
  if not rec then return end
  if rec.status == 'racing' or rec.status == 'gridded' then
    rec.status = 'dnf'
  elseif rec.status == 'waiting' or (rec.status == 'qualifying' and not rec.qualiBest) then
    players[pid] = nil
  end
  broadcastState()
end

function onInit()
  MP.RegisterEvent('RM_StartQualifying',  'RM_onStartQualifying')
  MP.RegisterEvent('RM_GenerateGrid',     'RM_onGenerateGrid')
  MP.RegisterEvent('RM_SetTotalLaps',     'RM_onSetTotalLaps')
  MP.RegisterEvent('RM_StartCountdown',   'RM_onStartCountdown')
  MP.RegisterEvent('RM_EndRace',          'RM_onEndRace')
  MP.RegisterEvent('RM_ResetLeaderboard', 'RM_onResetLeaderboard')
  MP.RegisterEvent('RM_QualiLap',         'RM_onQualiLap')
  MP.RegisterEvent('RM_Lap',              'RM_onLap')
  MP.RegisterEvent('RM_RequestState',     'RM_onRequestState')
  MP.RegisterEvent('onPlayerJoin',        'RM_onPlayerJoin')
  MP.RegisterEvent('onPlayerDisconnect',  'RM_onPlayerDisconnect')
  MP.RegisterEvent('RM_Tick',             'RM_Tick')
  MP.RegisterEvent('RM_CountdownTick',    'RM_CountdownTick')
  MP.CreateEventTimer('RM_Tick', TICK_MS)
  print('[RaceManager] Server plugin loaded (circuit edition)')
end
