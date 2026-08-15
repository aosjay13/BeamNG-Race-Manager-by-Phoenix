-- Headless test for the shared session lifecycle in server/RaceManager/main.lua.
--
-- This file is the acceptance test for the five-racer BeamMP session that
-- produced four bugs at once, all of them the same shape: single-player
-- assumptions about identity and about doing things to one car at a time.
--
--   1. Display names did not survive a mode change or a second race, because
--      `players` is rebuilt from scratch by Start Qualifying and the alias went
--      with it.
--   2. Five drivers opting in individually produced no grid and no teleport,
--      while "everyone races" put the same five on the grid — the online purge
--      threw away every `joined` flag when the id keys did not compare equal.
--   3. Only the last finisher got their car back, because the release was fired
--      while the participant list was still being walked.
--   4. A three-lap qualifying session took five or six laps, because qualifying
--      had lap detection of its own and no grid to start from.
--
-- Run from the repo root: lua5.3 tests/session_test.lua

local connected = { [0] = 'Guest_A', [1] = 'Guest_B', [2] = 'Guest_C',
                    [3] = 'Guest_D', [4] = 'Guest_E' }
local lastState  = nil
local lastChat   = nil
local gridAssign = {}   -- [pid] = last RM_GridAssign payload
local spectated  = {}   -- [pid] = last RM_ForceSpectate payload
local released   = {}   -- [pid] = last RM_ReleaseSpectate payload
local releaseSeq = {}   -- ordered pids, in the order the releases went out
local timers     = {}

-- Flipped on to reproduce the id-key mismatch that emptied the entry list: the
-- server reports its connected players under keys that do not compare equal to
-- the ones the records are stored under.
local stringKeyedPlayers = false

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) lastChat = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do
      if stringKeyedPlayers then t[tostring(id)] = name else t[id] = name end
    end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update'        then lastState = payload end
    if event == 'RM_GridAssign'    then gridAssign[target] = payload end
    if event == 'RM_ForceSpectate' then spectated[target] = payload end
    if event == 'RM_ReleaseSpectate' then
      released[target] = payload
      releaseSeq[#releaseSeq + 1] = target
    end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  Settings = { Map = 0 },
  Get = function () return '/levels/gridmap_v2/info.json' end,
}

Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

dofile('server/RaceManager/main.lua')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function driver(pid)
  for _, d in ipairs(lastState.drivers) do
    if d.id == pid then return d end
  end
end
local function shown(pid)
  local d = driver(pid)
  return d and (d.alias or d.name) or nil
end
local function clearSignals()
  gridAssign, spectated, released, releaseSeq = {}, {}, {}, {}
end
-- Everyone opts in, one press each, exactly as five racers would.
local function everybodyJoins()
  for pid in pairs(connected) do RM_onJoinRace(pid, '{"join":true}') end
end
-- Form up and go, whichever kind of session is armed.
local function runCountdown()
  RM_onStartCountdown(0)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
check(lastState.entryMode == 'all', 'entry defaults to everyone racing')
check(lastState.entrants == 5, 'so all five connected players are in the field')

-- ===========================================================================
-- Criterion 2: all-opted-in behaves identically to "everyone races"
-- ===========================================================================
-- Which needs the OPT-IN mode to say anything: the failure was drivers who had
-- each pressed Join Race being left off a grid that "everyone races" filled
-- from the same five names.
RM_onSetEntryMode(0, '{"mode":"join"}')
check(lastState.entrants == 0, 'switched to opt-in, nobody is entered yet')
-- The two entry modes are two ways of answering "who is in the field", and from
-- there they must be the same code. They were not: with everyone opted in the
-- field came out empty and no car was ever teleported, while flipping entry to
-- "all" gridded the same five drivers without complaint.
everybodyJoins()
check(lastState.entrants == 5, 'all five drivers opted in')

clearSignals()
RM_onGenerateGrid(0)
check(lastState.phase == 'grid', 'the opt-in path reaches the grid')
local optInSlots = {}
for pid in pairs(connected) do
  check(gridAssign[pid] ~= nil and gridAssign[pid].slot ~= nil,
    'opt-in: driver ' .. pid .. ' is told which start position to take')
  optInSlots[pid] = gridAssign[pid] and gridAssign[pid].slot
end

-- The same five drivers, reached the other way.
RM_onEndRace(0)
for pid in pairs(connected) do RM_onJoinRace(pid, '{"join":false}') end
RM_onSetEntryMode(0, '{"mode":"all"}')
clearSignals()
RM_onGenerateGrid(0)
check(lastState.phase == 'grid', '"everyone races" reaches the grid')
local sameField = true
for pid in pairs(connected) do
  if not (gridAssign[pid] and gridAssign[pid].slot == optInSlots[pid]) then
    sameField = false
  end
end
check(sameField, 'both entry modes produce the same grid, slot for slot')

-- ---------------------------------------------------------------------------
-- ...and the reason the opt-in path used to differ: the online purge.
--
-- MP.GetPlayers() keys its map on the server's own terms. When those keys do not
-- compare equal to the ones the records are stored under, EVERY record is purged
-- one line before the entry list is read — taking every `joined` flag with it.
-- In "all" mode that is invisible, because nothing looks at the flag.
-- ---------------------------------------------------------------------------
RM_onEndRace(0)
RM_onSetEntryMode(0, '{"mode":"join"}')
everybodyJoins()
stringKeyedPlayers = true
clearSignals()
RM_onGenerateGrid(0)
check(lastState.phase == 'grid',
  'the grid still forms when the server keys its player map differently')
local gridded = 0
for pid in pairs(connected) do
  if gridAssign[pid] and gridAssign[pid].slot then gridded = gridded + 1 end
end
check(gridded == 5, 'and all five opted-in drivers are still on it')
stringKeyedPlayers = false

-- ===========================================================================
-- Criterion 1 (first half): names set before qualifying
-- ===========================================================================
RM_onEndRace(0)
RM_onSetAlias(0, '{"target":0,"alias":"Phoenix"}')
RM_onSetAlias(0, '{"target":1,"alias":"Ryder"}')
RM_onSetAlias(0, '{"target":2,"alias":"Nomad"}')
RM_onSetAlias(0, '{"target":3,"alias":"Falcon"}')
RM_onSetAlias(0, '{"target":4,"alias":"Comet"}')
check(shown(0) == 'Phoenix' and shown(4) == 'Comet', 'display names are set')

-- ===========================================================================
-- Criteria 4 + 5: a three-lap qualifying session, on the race lifecycle
-- ===========================================================================
-- Grid -> hold -> session -> remove finished -> respawn all, parameterised by
-- the lap count. Qualifying used to flip straight to a running phase with no
-- grid, so a driver's first crossing of the line was an out-lap nobody asked
-- for, arriving at a different point of the circuit for every driver, and three
-- laps took five or six to complete.
--
-- There is an out lap again, and it is not that one: it starts on the grid with
-- everybody else's, ends at the line, and is counted separately from the
-- allowance. Three laps is three TIMED laps — the fourth crossing is what ends
-- a driver's session, and nothing but the standing start is given away.
RM_onSetQualiLimits(0, '{"laps":3,"seconds":0}')
clearSignals()
RM_onStartQualifying(0)
check(lastState.phase == 'grid', 'Start Qualifying forms a grid (not a free-for-all)')
local held = 0
for pid in pairs(connected) do
  if gridAssign[pid] and gridAssign[pid].slot then held = held + 1 end
end
check(held == 5, 'every qualifying entrant is stood on a slot and held')
check(driver(0).status == 'gridded', 'and is gridded, not loose on track')

runCountdown()
check(lastState.phase == 'qualifying', 'the qualifying session is running')
for pid in pairs(connected) do
  check(driver(pid).currentLap == 1,
    'driver ' .. pid .. ' starts on lap 1, from the grid')
  check(driver(pid).outLap == true,
    'driver ' .. pid .. ' owes an out lap before anything is timed')
end
check(lastState.qualiOutLap == true,
  'and the session says so, so a client can tell a driver before they cross anything')

-- The out lap: one crossing each, scored nowhere.
clearSignals()
for pid = 0, 4 do
  RM_onLap(pid, '{"lapTime":' .. (70 + pid) .. '}')   -- quicker than anything below
end
for pid = 0, 4 do
  check(driver(pid).qualiBest == nil,
    'driver ' .. pid .. ' has no time from the out lap, however fast it was')
  check(driver(pid).qualiLaps == 0, 'and it did not touch their lap allowance')
  check(driver(pid).outLap == false, 'and they are on a timed lap now')
  check(driver(pid).status == 'qualifying', 'nobody is retired by an out lap')
end
check(lastState.bestLapTime == nil,
  'an out lap cannot take the fastest lap of the session either')

-- Exactly three TIMED laps each. Not four, not six.
clearSignals()
for lap = 1, 3 do
  for pid = 0, 4 do
    RM_onLap(pid, '{"lapTime":' .. (90 + pid + lap) .. '}')
  end
end
for pid = 0, 4 do
  check(driver(pid).qualiLaps == 3,
    'driver ' .. pid .. ' finished qualifying on exactly 3 timed laps')
  check(driver(pid).qualiBest == 91 + pid,
    'driver ' .. pid .. ' keeps their fastest lap')
end
check(lastState.phase == 'waiting', 'qualifying closes itself at the lap target')

-- Removed, then given back: the same shape a race finish has.
local removed, gotCarBack = 0, 0
for pid = 0, 4 do
  if spectated[pid] then removed = removed + 1 end
  if released[pid]  then gotCarBack = gotCarBack + 1 end
end
check(removed == 5, 'every driver who completed qualifying is taken off the track')
check(gotCarBack == 5, 'and every one of them gets their car back when it ends')

-- ===========================================================================
-- Criterion 1 (second half): names survive qualifying -> race
-- ===========================================================================
check(shown(0) == 'Phoenix' and shown(2) == 'Nomad' and shown(4) == 'Comet',
  'display names survive the qualifying session wipe')

-- ===========================================================================
-- Criteria 3 + 6: every participant respawns, in a staggered order
-- ===========================================================================
RM_onSetTotalLaps(0, '{"laps":2}')
RM_onGenerateGrid(0)
check(lastState.phase == 'grid', 'the race grid forms from the qualifying times')
check(driver(0).gridPos == 1, 'the fastest qualifier takes pole')
runCountdown()
check(lastState.phase == 'racing', 'the race is running')
check(shown(0) == 'Phoenix', 'display names survive Generate Grid and GO')

clearSignals()
for lap = 1, 2 do
  for pid = 0, 4 do RM_onLap(pid, '{"lapTime":' .. (95 + pid) .. '}') end
end
check(lastState.phase == 'finished', 'the race ends when every driver has finished')

-- Every participant, not just the last one to cross the line. The release is
-- built from a snapshot of the field taken before anything is sent.
local respawned, orders = 0, {}
for pid = 0, 4 do
  local r = released[pid]
  if r then
    respawned = respawned + 1
    check(type(r.order) == 'number' and type(r.count) == 'number',
      'driver ' .. pid .. ' is told its place in the respawn order')
    if r.order then orders[r.order] = (orders[r.order] or 0) + 1 end
    check(r.count == 5, 'driver ' .. pid .. ' is told how big the field is')
  end
end
check(respawned == 5, 'EVERY participant gets their car back, not only the last finisher')
local sequenceOk = true
for i = 1, 5 do
  if orders[i] ~= 1 then sequenceOk = false end
end
check(sequenceOk, 'the respawn order is a clean 1..5 with no two cars sharing a slot')

-- ===========================================================================
-- Criterion 1 (third half): names survive into a SECOND race
-- ===========================================================================
everybodyJoins()
RM_onGenerateGrid(0)
runCountdown()
check(lastState.phase == 'racing', 'a second race starts')
check(shown(0) == 'Phoenix' and shown(1) == 'Ryder' and shown(2) == 'Nomad'
  and shown(3) == 'Falcon' and shown(4) == 'Comet',
  'every display name is still correct in the second race')

-- A driver who respawns keeps their name: nothing here is keyed on a vehicle,
-- which is the only thing that actually changes when a car is replaced.
RM_onVehicleReset(2)
check(shown(2) == 'Nomad', 'a respawn does not cost a driver their display name')

-- Reset Session clears the field but not the names.
RM_onEndRace(0)
RM_onResetLeaderboard(0)
check(lastState.entrants == 0, 'Reset Session stands the whole field down')
check(shown(0) == 'Phoenix' and shown(4) == 'Comet',
  'but the display names an admin set are still there')

-- ---------------------------------------------------------------------------
-- The one case where a name must NOT survive: somebody else inherits the id.
-- ---------------------------------------------------------------------------
RM_onPlayerDisconnect(3)
connected[3] = 'Guest_SOMEONE_ELSE'
RM_onPlayerJoin(3)
check(shown(3) == 'Guest_SOMEONE_ELSE',
  'a recycled session id does not inherit the previous player\'s name')
check(shown(0) == 'Phoenix', 'and everybody else keeps theirs')

if fails == 0 then
  print('session_test: ' .. checks .. ' checks, 0 failures')
else
  print('session_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
