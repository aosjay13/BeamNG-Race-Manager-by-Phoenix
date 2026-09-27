-- Headless test for the race clock and the green flag in
-- server/RaceManager/main.lua.
--
-- Three reported problems, pinned here:
--   * the green fell at the same spot every pace lap, 10 m from the line, so a
--     field could learn it and jump it. Now GET READY is called 100 m out and
--     the green falls at a random point 1 to 50 m out, drawn per pace lap and
--     per restart;
--   * the race clock ran from the release, so a pace lap showed on the clock
--     and in every finish time. It runs from the green now;
--   * nothing could stop the clock when a race was stopped. A red flag does.
--
-- Run from the repo root: lua tests/green_test.lua

local connected = { [0] = 'Admin', [1] = 'Leader', [2] = 'Second', [3] = 'Third' }
local lastState, lastChat = nil, nil
-- Every state broadcast, so a GET READY can be found between two ticks.
local readyAt = nil
MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (_, msg) lastChat = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (_, event, payload)
    if event == 'RM_Update' then
      lastState = payload
      if payload.greenReady and not readyAt then readyAt = currentDist end
    end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
  RemoveVehicle = function () end,
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
local function seconds(n)
  for _ = 1, math.floor(n * 10 + 0.5) do RM_Tick() end
end
local function report(pid, lapNum, cp, dist)
  RM_onProgress(pid, string.format('{"lap":%d,"cp":%d,"dist":%.1f}', lapNum, cp, dist))
end
local function field(cp, dist)
  currentDist = dist
  report(1, 1, cp, dist)
  report(2, 1, cp, dist + 20)
  report(3, 1, cp, dist + 40)
end
local function near(a, b, tol) return a and math.abs(a - b) <= (tol or 0.5) end

onInit()
RM_onLogin(0, '{"password":"phoenix"}'); RM_onSetReadyCheck(0, '{"on":false}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetSpectating(0, '{"spectating":true}')

-- A square lap: CP1, CP2, CP3, then the line. The final sector, CP3 to the
-- line, is 200 m.
local function loadTrack(name, cp3)
  RM_onEndRace(0)
  RM_onResetLeaderboard(0)   -- a layout will not load mid-session
  RM_onSaveLayout(0, '{"name":"' .. name .. '","width":20,"checkpoints":['
    .. '{"x":200,"y":0,"z":0,"hx":0,"hy":1},'
    .. '{"x":200,"y":200,"z":0,"hx":-1,"hy":0},'
    .. '{"x":' .. cp3.x .. ',"y":' .. cp3.y .. ',"z":0,"hx":0,"hy":-1},'
    .. '{"x":0,"y":0,"z":0,"hx":1,"hy":0}]}')
  RM_onLoadLayout(0, '{"name":"' .. name .. '"}')
end

-- One pace lap: release, then walk the leader in from 200 m on the final
-- sector half a meter at a time. Returns the distance the green fell at and
-- the distance GET READY was called at.
local function paceLapGreenAt(from)
  RM_onResetLeaderboard(0)
  RM_onSetSpectating(0, '{"spectating":true}')
  RM_onGenerateGrid(0)
  RM_onStartRace(0)
  if lastState.pacing ~= true then return nil end
  readyAt = nil
  for d = from or 200, 0, -0.5 do
    field(3, d)
    RM_Tick()
    if lastState.pacing == false then return d, readyAt end
  end
  return -1, readyAt
end

-- ===========================================================================
-- The green falls somewhere different every pace lap
-- ===========================================================================
loadTrack('Square', { x = 0, y = 200 })
RM_onSetPaceLap(0, '{"enabled":true}')

-- Close to the line, but not on the final sector: a leader passing near the
-- line mid-lap must not start the race.
RM_onResetLeaderboard(0)
RM_onSetSpectating(0, '{"spectating":true}')
RM_onGenerateGrid(0)
RM_onStartRace(0)
field(1, 5.0)
seconds(0.5)
check(lastState.pacing == true,
  'the green does not fall on a leader near the line before the final sector')
check(lastState.greenReady == nil, 'nor does GET READY: the leader is not on the run in')
check(lastState.greenZone == nil,
  'and where it will fall is never broadcast: a number a driver can read is a spot a driver can learn')

local seen, lo, hi = {}, math.huge, -math.huge
local readyLo, readyHi = math.huge, -math.huge
for _ = 1, 8 do
  local d, r = paceLapGreenAt()
  if d then
    seen[d] = true
    if d < lo then lo = d end
    if d > hi then hi = d end
  end
  r = r or -1
  if r < readyLo then readyLo = r end
  if r > readyHi then readyHi = r end
end
local distinct = 0
for _ in pairs(seen) do distinct = distinct + 1 end
check(readyLo >= 99.5 and readyHi <= 100, string.format(
  'GET READY is called as the leader comes within 100 m of the line (got %s to %s)',
  readyLo, readyHi))
check(lo >= 0.5 and hi <= 50, string.format(
  'every green falls between 1 and 50 m before the line (got %s to %s)', lo, hi))
check(distinct >= 3, string.format(
  'and not at the same spot each time: eight pace laps, %d different points', distinct))
check(lastState.greenReady == nil, 'GET READY is cleared once the green has fallen')

-- A short final sector caps the zone inside it. Past its length the green
-- would fall at the last checkpoint every time. GET READY cannot be trusted
-- before the final sector, so on a short one it comes as the leader clears
-- the last checkpoint.
loadTrack('Short', { x = 0, y = 30 })
local shortHi, shortReady = -math.huge, nil
for _ = 1, 6 do
  local d, r = paceLapGreenAt(30)
  if d and d > shortHi then shortHi = d end
  shortReady = r
end
check(shortHi <= 27 and shortHi >= 0.5, string.format(
  'on a 30 m final sector the green stays inside it, at most 27 m out (got %s)', shortHi))
check(shortReady ~= nil and shortReady <= 30, string.format(
  'and GET READY comes as the leader starts that sector (got %s)', tostring(shortReady)))

-- ===========================================================================
-- The race clock starts at the green
-- ===========================================================================
loadTrack('Square', { x = 0, y = 200 })
RM_onResetLeaderboard(0)
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":1}')
RM_onGenerateGrid(0)
RM_onStartRace(0)
field(1, 400)
seconds(45)
check(lastState.pacing == true, 'forming up')
check(lastState.raceClock == 0, 'the race clock reads 0:00 through the pace lap (got '
  .. tostring(lastState.raceClock) .. ')')
check(lastState.raceTime > 44, 'while the session clock runs, for the ghost timers')
field(3, 5)
seconds(0.2)
check(lastState.pacing == false, 'the green falls')
-- Everyone takes the line to end the pace lap, then races one lap.
RM_onLap(1, '{"lapTime":60.0}'); RM_onLap(2, '{"lapTime":60.0}'); RM_onLap(3, '{"lapTime":60.0}')
seconds(30)
check(near(lastState.raceClock, 30, 0.3), 'and counts from the green (got '
  .. tostring(lastState.raceClock) .. ')')
seconds(20)
lastChat = nil
RM_onLap(1, '{"lapTime":50.0}'); RM_onLap(2, '{"lapTime":50.5}'); RM_onLap(3, '{"lapTime":51.0}')
seconds(10)
local path = lastChat and lastChat:match('(Resources/Server/RaceManager/Data/results/[%w%-_%.]+%.txt)')
local f = path and io.open(path, 'r')
local text = f and f:read('a') or ''
if f then f:close() end
check(text:find('0:50.', 1, true) ~= nil,
  'the winner\'s race time is measured from the green, about 50 s, not from the release')
check(text:find('1:35.', 1, true) == nil,
  'and does not include the 45 s pace lap')

-- ===========================================================================
-- A red flag stops the race clock
-- ===========================================================================
RM_onResetLeaderboard(0)
RM_onSetPaceLap(0, '{"enabled":false}')
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetRaceLimits(0, '{"laps":25,"seconds":600,"mode":"timed"}')
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'a timed race is running')
field(1, 300)
seconds(60)
check(near(lastState.raceLeft, 540), 'a minute in, nine minutes left (got '
  .. tostring(lastState.raceLeft) .. ')')

RM_onSetFlag(0, '{"flag":"red"}')
check(lastChat and lastChat:find('race clock is stopped', 1, true),
  'the red flag tells the field the clock is stopped')
seconds(120)
check(near(lastState.raceLeft, 540), 'two minutes under red and the countdown has not moved (got '
  .. tostring(lastState.raceLeft) .. ')')
check(near(lastState.raceClock, 60), 'nor has the race clock (got '
  .. tostring(lastState.raceClock) .. ')')
check(lastState.clockStopped == true, 'and the panel is told the clock is stopped')
check(lastState.raceTime > 179, 'while the session clock runs on underneath')

RM_onSetFlag(0, '{"flag":"green"}')
check(lastChat and lastChat:find('running again', 1, true), 'lifting the red says the clock runs again')
seconds(60)
check(near(lastState.raceLeft, 480), 'and it picks up where it stopped (got '
  .. tostring(lastState.raceLeft) .. ')')
check(lastState.clockStopped == nil, 'no longer stopped')

-- The clock cannot run out under a red.
seconds(470)
RM_onSetFlag(0, '{"flag":"red"}')
seconds(60)
check(lastState.raceExpired ~= true, 'ten seconds from time up, a minute of red does not expire the race')
RM_onSetFlag(0, '{"flag":"green"}')
seconds(11)
check(lastState.raceExpired == true, 'and the time runs out once the red is lifted')

-- Qualifying's clock stops too.
RM_onEndRace(0)
RM_onResetLeaderboard(0)
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetQualiLimits(0, '{"laps":0,"seconds":600}')
RM_onStartQualifying(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'qualifying', 'qualifying is running')
seconds(30)
local qBefore = lastState.qualiLeft
RM_onSetFlag(0, '{"flag":"red"}')
seconds(60)
check(near(lastState.qualiLeft, qBefore), 'a red flag holds the qualifying clock too (got '
  .. tostring(lastState.qualiLeft) .. ', was ' .. tostring(qBefore) .. ')')
RM_onEndRace(0)

if fails == 0 then
  print(string.format('green_test: %d checks, 0 failures', checks))
else
  print(string.format('green_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
