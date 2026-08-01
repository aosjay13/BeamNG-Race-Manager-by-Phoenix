-- Headless test for TIMED qualifying in server/RaceManager/main.lua.
--
-- Why this exists: a lap-limited session has a per-driver terminal event built
-- in — the crossing that completes your allowance is the moment you are done —
-- and the session ends when the last driver reaches it. A timed session has no
-- such thing: the clock expires for everybody at once while they are spread
-- around the circuit. Expiry used to end the session outright, which locked the
-- leaderboard and left every car loose on a session that was supposedly over:
-- nothing was removed, so the respawn had nothing to put back and no driver was
-- ever told they were done.
--
-- Expiry now arms a FINAL LAP instead. Drivers stay on track and controllable;
-- the next start/finish line each of them crosses is terminal for them; the
-- session closes through the same removal and respawn-all the lap-limited path
-- uses. This file pins that, and the five edge cases around it.
--
-- Run from the repo root: lua5.3 tests/timed_quali_test.lua

local connected = { [0] = 'Guest_A', [1] = 'Guest_B', [2] = 'Guest_C' }
local lastState  = nil
local chat       = {}
local gridAssign = {}
local spectated  = {}
local released   = {}
local timers     = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chat[#chat + 1] = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update'          then lastState = payload end
    if event == 'RM_GridAssign'      then gridAssign[target] = payload end
    if event == 'RM_ForceSpectate'   then spectated[target] = payload end
    if event == 'RM_ReleaseSpectate' then released[target] = payload end
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
local function chatSaid(needle)
  for _, m in ipairs(chat) do
    if type(m) == 'string' and m:find(needle, 1, true) then return true end
  end
  return false
end
local function clearSignals()
  gridAssign, spectated, released, chat = {}, {}, {}, {}
end
local function ticks(n) for _ = 1, n do RM_Tick() end end
-- Start a timed qualifying session: everyone in, grid, hold, countdown, GO.
local function startTimedQuali(seconds, laps)
  RM_onSetQualiLimits(0, '{"laps":' .. (laps or 0) .. ',"seconds":' .. seconds .. '}')
  for pid in pairs(connected) do RM_onJoinRace(pid, '{"join":true}') end
  RM_onStartQualifying(0)
  RM_onStartCountdown(0)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end

-- ===========================================================================
-- 1. Expiry arms the final lap. It does NOT end the session.
-- ===========================================================================
startTimedQuali(2)
check(lastState.phase == 'qualifying', 'timed qualifying is running')
check(lastState.finalLap ~= true, 'the final lap is not armed while time remains')

clearSignals()
ticks(25)   -- past the 2 second limit (100 ms a tick)
check(lastState.phase == 'qualifying',
  'the session is STILL RUNNING after the clock expires (drivers keep driving)')
check(lastState.finalLap == true, 'the final lap is armed')
check(chatSaid('FINAL LAP'), 'every driver is told the clock expired and this lap is their last')
for pid = 0, 2 do
  check(driver(pid).status == 'qualifying',
    'driver ' .. pid .. ' is still on track and controllable')
  check(spectated[pid] == nil, 'driver ' .. pid .. ' has not been removed yet')
end

-- ===========================================================================
-- 2. Each driver is removed as they cross the line, not before
-- ===========================================================================
-- ...and the lap still counts. The order settles when the last driver takes the
-- flag, not at expiry: a final lap you cannot improve on is not worth running.
clearSignals()
RM_onLap(1, '{"lapTime":88.0}')
check(driver(1).status == 'finished', 'the driver who crossed the line is done')
check(spectated[1] ~= nil, 'and their car is taken off the track')
check(driver(1).qualiBest == 88.0, 'the final lap still counts toward Best Lap')
check(lastState.phase == 'qualifying', 'the session continues for the drivers still out')
check(spectated[0] == nil and spectated[2] == nil, 'nobody else is touched')
check(next(released) == nil, 'and nothing is respawned while drivers are still running')

-- A crossing that arrives after expiry is terminal, every time — there is no
-- "one more lap" for the driver who was closest to the line.
check(driver(1).qualiLaps == 1, 'the final lap is counted once, not doubled')

-- ===========================================================================
-- 3. The last driver home closes the session, and everybody respawns
-- ===========================================================================
clearSignals()
RM_onLap(0, '{"lapTime":85.0}')
check(lastState.phase == 'qualifying', 'two down, one still out: the session runs on')
RM_onLap(2, '{"lapTime":91.0}')
check(lastState.phase == 'waiting', 'the last driver home closes the session')
check(lastState.finalLap ~= true, 'and the final-lap state is cleared')

local back = 0
for pid = 0, 2 do if released[pid] then back = back + 1 end end
check(back == 3, 'every driver gets their car back — the same respawn-all lap qualifying uses')
check(released[0] and released[0].order ~= nil, 'and it is staggered, like every mass respawn')

-- The fastest lap of the session was set ON the final lap, and it decides the
-- order. Positions are not frozen at expiry.
check(driver(0).qualiBest == 85.0, 'best laps from the final lap are kept')
check(lastState.drivers[1].id == 0, 'and they decide the provisional grid order')

-- ===========================================================================
-- Edge case: a driver who never crosses the line (pits, parked, still gridded)
-- ===========================================================================
-- Without a bound the session waits on them forever. The grace timeout takes
-- them where they stand and closes normally.
startTimedQuali(2)
clearSignals()
ticks(25)
check(lastState.finalLap == true, 'final lap armed again')
RM_onLap(0, '{"lapTime":90.0}')      -- one driver comes round
check(lastState.phase == 'qualifying', 'the session waits for the two still out')

-- 180 s of grace, at 100 ms a tick.
ticks(1800)
check(lastState.phase == 'waiting', 'the grace timeout closes a session nobody can finish')
check(chatSaid('grace expired'), 'and says why, rather than just stopping')
for pid = 0, 2 do
  check(spectated[pid] ~= nil, 'driver ' .. pid .. ' was taken off the track')
  check(released[pid] ~= nil,  'driver ' .. pid .. ' still gets their car back')
end

-- ===========================================================================
-- Edge case: a driver disconnects during the final lap
-- ===========================================================================
startTimedQuali(2)
clearSignals()
ticks(25)
RM_onLap(0, '{"lapTime":90.0}')
RM_onLap(1, '{"lapTime":92.0}')
check(lastState.phase == 'qualifying', 'one driver still out on the final lap')
connected[2] = nil
RM_onPlayerDisconnect(2)
check(lastState.phase == 'waiting',
  'a disconnect on the final lap closes the session rather than hanging it')
connected[2] = 'Guest_C'
RM_onPlayerJoin(2)

-- ===========================================================================
-- Edge case: nobody on track when the clock expires
-- ===========================================================================
-- Every driver already used a lap allowance, so there is no final lap to run.
-- The session must close cleanly rather than arming a state nothing can leave.
startTimedQuali(3, 1)                 -- 3 s limit AND a 1 lap allowance
for pid = 0, 2 do RM_onLap(pid, '{"lapTime":80.0}') end
check(lastState.phase == 'waiting', 'the lap allowance closed the session first')

-- ...and the same again where the clock is what runs out on an empty track.
startTimedQuali(3, 1)
clearSignals()
for pid = 0, 2 do RM_onLap(pid, '{"lapTime":80.0}') end
ticks(60)
check(lastState.phase == 'waiting', 'an expired clock on an empty track does not stall')
check(lastState.finalLap ~= true, 'and never arms a final lap with nobody to run it')

-- ===========================================================================
-- Criterion 6: lap-based qualifying is unchanged
-- ===========================================================================
-- No time limit at all, so nothing above can reach this path.
startTimedQuali(0, 2)
check(lastState.phase == 'qualifying', 'lap-limited qualifying starts as before')
clearSignals()
ticks(600)                            -- a minute; no clock to expire
check(lastState.phase == 'qualifying', 'and does not end on a timer it never had')
check(lastState.finalLap ~= true, 'and never arms the final lap')
for lap = 1, 2 do
  for pid = 0, 2 do RM_onLap(pid, '{"lapTime":' .. (90 + pid) .. '}') end
end
check(lastState.phase == 'waiting', 'it still closes on the lap allowance')
for pid = 0, 2 do
  check(driver(pid).qualiLaps == 2, 'driver ' .. pid .. ' ran exactly their 2 laps')
  check(released[pid] ~= nil, 'driver ' .. pid .. ' got their car back')
end

-- ===========================================================================
-- And a RACE is untouched by any of it
-- ===========================================================================
RM_onSetTotalLaps(0, '{"laps":2}')
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'a race starts normally')
clearSignals()
ticks(600)
check(lastState.phase == 'racing', 'and is not ended by the qualifying clock')
check(lastState.finalLap ~= true, 'a race never arms the final lap')
for lap = 1, 2 do
  for pid = 0, 2 do RM_onLap(pid, '{"lapTime":' .. (95 + pid) .. '}') end
end
check(lastState.phase == 'finished', 'the race finishes on its lap count as before')

if fails == 0 then
  print('timed_quali_test: ' .. checks .. ' checks, 0 failures')
else
  print('timed_quali_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
