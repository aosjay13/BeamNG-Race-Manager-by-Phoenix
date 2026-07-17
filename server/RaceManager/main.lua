-- Race Manager - BeamMP server plugin (Lua 5.3)
--
-- Authoritative race state machine:
--   waiting -> grid -> countdown -> racing -> finished -> (reset) -> waiting
--
-- Clients (lua/ge/extensions/raceManager.lua) detect finish-line crossings
-- locally -- the server has no physics access -- and report them here. The
-- server assigns grid positions, runs the countdown, timestamps finishes on
-- its own clock (one clock for everyone = fair gaps), and broadcasts the
-- driver table to every connected client.
--
-- Author: Phoenix

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local TICK_MS          = 100   -- server clock resolution
local PUSH_EVERY_TICKS = 5     -- broadcast state every N ticks (500 ms)
local COUNTDOWN_FROM   = 3     -- 3, 2, 1, GO!

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local race = {
  phase = 'waiting',  -- waiting | grid | countdown | racing | finished
  time  = 0.0,        -- seconds since GO (advanced by RM_Tick)
}
local players = {}          -- [playerID] = per-player record
local tickCounter = 0
local countdownValue = nil  -- current countdown number while phase == 'countdown'

local function newRecord(pid)
  return {
    id         = pid,
    name       = MP.GetPlayerName(pid) or ('Player ' .. pid),
    status     = 'waiting',  -- waiting | gridded | racing | finished | dnf
    gridPos    = nil,
    finishTime = nil,
  }
end

local function ensurePlayer(pid)
  if not players[pid] then
    players[pid] = newRecord(pid)
  end
  return players[pid]
end

-- ---------------------------------------------------------------------------
-- Broadcast
-- ---------------------------------------------------------------------------
local function buildDrivers()
  local list = {}
  for _, rec in pairs(players) do
    list[#list + 1] = rec
  end
  -- Finished drivers first (by finish time), then racers/gridded by grid
  -- position, DNFs last.
  table.sort(list, function (a, b)
    local ra = a.status == 'dnf' and 2 or (a.finishTime and 0 or 1)
    local rb = b.status == 'dnf' and 2 or (b.finishTime and 0 or 1)
    if ra ~= rb then return ra < rb end
    if ra == 0 then return a.finishTime < b.finishTime end
    return (a.gridPos or math.huge) < (b.gridPos or math.huge)
  end)
  return list
end

local function broadcastState(targetPid)
  local payload = Util.JsonEncode({
    phase    = race.phase,
    raceTime = race.time,
    drivers  = buildDrivers(),
  })
  MP.TriggerClientEvent(targetPid or -1, 'RM_Update', payload)
end

local function broadcastCountdown(count)
  MP.TriggerClientEvent(-1, 'RM_Countdown', Util.JsonEncode({ count = count }))
end

-- ---------------------------------------------------------------------------
-- UI commands (relayed by the client bridge)
-- ---------------------------------------------------------------------------

-- Set Grid: snapshot connected players and assign starting positions in
-- join order. Allowed from waiting/grid/finished (re-gridding is fine).
function RM_onSetGrid(pid)
  if race.phase == 'countdown' or race.phase == 'racing' then return end
  players = {}
  race.time = 0.0
  local ids = {}
  for id in pairs(MP.GetPlayers()) do ids[#ids + 1] = id end
  table.sort(ids)
  for gridPos, id in ipairs(ids) do
    local rec = ensurePlayer(id)
    rec.gridPos = gridPos
    rec.status = 'gridded'
  end
  race.phase = 'grid'
  broadcastState()
  print('[RaceManager] Grid set by ' .. (MP.GetPlayerName(pid) or pid) .. ' (' .. #ids .. ' drivers)')
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
  for _, rec in pairs(players) do
    if rec.status == 'gridded' then rec.status = 'racing' end
  end
  broadcastState()
  print('[RaceManager] GO!')
end

-- End Race: anyone still on track becomes DNF.
function RM_onEndRace(pid)
  if race.phase ~= 'racing' and race.phase ~= 'countdown' then return end
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
end

function RM_onResetLeaderboard(pid)
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(-1)
  players = {}
  race.phase = 'waiting'
  race.time = 0.0
  for id in pairs(MP.GetPlayers()) do
    ensurePlayer(id)
  end
  broadcastState()
  print('[RaceManager] Leaderboard reset by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Client reports its vehicle crossed the finish line. Timestamp on the
-- server clock so every driver is measured against the same GO.
function RM_onFinish(pid)
  if race.phase ~= 'racing' then return end
  local rec = ensurePlayer(pid)
  if rec.status ~= 'racing' then return end
  rec.status = 'finished'
  rec.finishTime = race.time
  print(string.format('[RaceManager] %s finished at %.3fs', rec.name, race.time))

  -- Everyone done (finished or dnf)? Close the race.
  for _, r in pairs(players) do
    if r.status == 'racing' then
      broadcastState()
      return
    end
  end
  race.phase = 'finished'
  broadcastState()
  print('[RaceManager] All drivers finished')
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
  ensurePlayer(pid)  -- joins mid-race as 'waiting'; gridded next Set Grid
  broadcastState()
end

function RM_onPlayerDisconnect(pid)
  local rec = players[pid]
  if not rec then return end
  if rec.status == 'racing' or rec.status == 'gridded' then
    rec.status = 'dnf'
  elseif rec.status == 'waiting' then
    players[pid] = nil
  end
  broadcastState()
end

function onInit()
  MP.RegisterEvent('RM_SetGrid',          'RM_onSetGrid')
  MP.RegisterEvent('RM_StartCountdown',   'RM_onStartCountdown')
  MP.RegisterEvent('RM_EndRace',          'RM_onEndRace')
  MP.RegisterEvent('RM_ResetLeaderboard', 'RM_onResetLeaderboard')
  MP.RegisterEvent('RM_Finish',           'RM_onFinish')
  MP.RegisterEvent('RM_RequestState',     'RM_onRequestState')
  MP.RegisterEvent('onPlayerJoin',        'RM_onPlayerJoin')
  MP.RegisterEvent('onPlayerDisconnect',  'RM_onPlayerDisconnect')
  MP.RegisterEvent('RM_Tick',             'RM_Tick')
  MP.RegisterEvent('RM_CountdownTick',    'RM_CountdownTick')
  MP.CreateEventTimer('RM_Tick', TICK_MS)
  print('[RaceManager] Server plugin loaded')
end
