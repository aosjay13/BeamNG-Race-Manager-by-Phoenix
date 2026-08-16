-- Headless test for the live position system in server/RaceManager/main.lua
-- (Lua 5.3, same as BeamMP): the three-metric running order
--   1. laps completed  2. checkpoints cleared  3. distance to the next gate
-- plus the position integers stamped on the broadcast array, telemetry
-- validation, and the fact that progress reports never broadcast by themselves.
-- Run from the repo root: lua5.3 tests/positions_test.lua

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
local lastState = nil
local updateCount = 0
local timers = {}
local hostedMap = '/levels/gridmap_v2/info.json'

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then
      lastState = payload
      updateCount = updateCount + 1
    end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  Settings = { Map = 0 },
  Get = function () return hostedMap end,
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
local function driver(name)
  for _, d in ipairs(lastState.drivers) do
    if d.name == name then return d end
  end
end
-- Names in broadcast order, leader first.
local function order()
  local names = {}
  for i, d in ipairs(lastState.drivers) do names[i] = d.name end
  return table.concat(names, ',')
end
local function progress(pid, lap, cp, dist)
  RM_onProgress(pid, string.format('{"lap":%d,"cp":%d,"dist":%s}', lap, cp, tostring(dist)))
end
-- Force a broadcast without advancing anything else.
local function push() RM_onRequestState(1) end

onInit()
RM_onLogin(1, '{"password":"phoenix"}')
RM_onPlayerJoin(1); RM_onPlayerJoin(2); RM_onPlayerJoin(3); RM_onPlayerJoin(4)
-- These suites predate the entry list; run them with entry open to everyone.

RM_onSetTotalLaps(1, '{"laps":5}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'race is running')

-- Fresh race: everyone is level, so the order falls back to the grid.
check(driver('Alice').position == 1, 'position integers are stamped on the array')
check(driver('Alice').cpCleared == 0 and driver('Alice').distNext == nil,
  'telemetry starts empty')
local gridOrder = order()
check(gridOrder == 'Alice,Bob,Cara,Dan', 'untelemetered field keeps the grid order')

-- ---------------------------------------------------------------------------
-- Metric 3: distance to the next checkpoint (same lap, same checkpoints)
-- ---------------------------------------------------------------------------
progress(1, 1, 2, 180.0)   -- Alice: 180 m from gate 3
progress(2, 1, 2, 40.0)    -- Bob:    40 m from gate 3  -> ahead
progress(3, 1, 2, 95.5)    -- Cara:   95.5 m
progress(4, 1, 2, 500.0)   -- Dan:   500 m
push()
check(order() == 'Bob,Cara,Alice,Dan',
  'same lap + same checkpoints: shortest distance to the next gate leads')
check(driver('Bob').position == 1 and driver('Cara').position == 2
  and driver('Alice').position == 3 and driver('Dan').position == 4,
  'positions renumber 1..N in the sorted order')

-- A driver who has not reported a distance sits behind everyone who has.
local before = order()
progress(1, 1, 2, 10.0)    -- Alice closes right up to the gate
push()
check(order() == 'Alice,Bob,Cara,Dan', 'a closer car takes the lead on the next push')
check(before ~= order(), 'the running order actually changed')

-- ---------------------------------------------------------------------------
-- Metric 2: checkpoints cleared beats distance
-- ---------------------------------------------------------------------------
progress(4, 1, 4, 900.0)   -- Dan is a gate further round, but far from the next
push()
check(driver('Dan').position == 1,
  'more checkpoints cleared outranks a shorter distance')
check(order() == 'Dan,Alice,Bob,Cara', 'checkpoint count sorts above distance')

-- ---------------------------------------------------------------------------
-- Metric 1: laps completed beats everything
-- ---------------------------------------------------------------------------
RM_onLap(3, '{"lapTime":90}')   -- Cara starts lap 2
check(driver('Cara').currentLap == 2, 'Cara is on lap 2')
check(driver('Cara').cpCleared == 0 and driver('Cara').distNext == nil,
  'crossing the line wipes the previous lap telemetry')
progress(3, 2, 0, 950.0)        -- ...and is a long way from her next gate
push()
check(driver('Cara').position == 1, 'an extra lap outranks checkpoints and distance')
check(order() == 'Cara,Dan,Alice,Bob', 'laps sort above everything else')

-- ---------------------------------------------------------------------------
-- Telemetry validation
-- ---------------------------------------------------------------------------
local danCp, danDist = driver('Dan').cpCleared, driver('Dan').distNext
RM_onProgress(4, 'not json at all {{{')
RM_onProgress(4, '')
push()
check(driver('Dan').cpCleared == danCp and driver('Dan').distNext == danDist,
  'malformed telemetry is ignored')

progress(4, 99, 3, 5.0)         -- report for a lap the server has not credited
push()
check(driver('Dan').cpCleared == danCp,
  'telemetry for the wrong lap is dropped instead of applied')

RM_onProgress(4, '{"lap":1,"cp":-5,"dist":-20}')
push()
check(driver('Dan').cpCleared == 0, 'a negative checkpoint count clamps to 0')
check(driver('Dan').distNext == danDist, 'a negative distance is rejected')

RM_onProgress(4, '{"lap":1,"cp":99999,"dist":1e12}')
push()
check(driver('Dan').cpCleared == 500, 'an absurd checkpoint count is clamped')
check(driver('Dan').distNext == danDist, 'an absurd distance is rejected')
progress(4, 1, 4, 900.0)        -- restore something sane

-- Telemetry from players who are not racing is ignored outright.
RM_onProgress(99, '{"lap":1,"cp":1,"dist":1}')
check(driver('Alice') ~= nil, 'telemetry from an unknown player is harmless')

-- ---------------------------------------------------------------------------
-- Throttling: reports must never broadcast on their own
-- ---------------------------------------------------------------------------
local countBefore = updateCount
for _ = 1, 50 do
  progress(1, 1, 2, 10.0)
  progress(2, 1, 2, 40.0)
end
check(updateCount == countBefore,
  '100 progress reports triggered no broadcasts at all')

-- The race tick loop is the one place the running order goes out.
for _ = 1, 3 do RM_Tick() end
check(updateCount == countBefore + 1,
  'the tick loop broadcasts the sorted order on its own cadence')

-- ---------------------------------------------------------------------------
-- Finishers, DNFs and the final classification
-- ---------------------------------------------------------------------------
RM_onSetTotalLaps(1, '{"laps":5}')
RM_onResetLeaderboard(1)
RM_onSetTotalLaps(1, '{"laps":1}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()

-- Dan is way out in front on distance, but Bob and Cara take the flag first.
progress(4, 1, 0, 1.0)
progress(1, 1, 0, 900.0)
push()
check(driver('Dan').position == 1, 'Dan leads on the road')

for _ = 1, 20 do RM_Tick() end
RM_onLap(2, '{"lapTime":90}')   -- Bob finishes
for _ = 1, 10 do RM_Tick() end
RM_onLap(3, '{"lapTime":95}')   -- Cara finishes
push()
check(driver('Bob').position == 1 and driver('Cara').position == 2,
  'classified finishers hold the top places by finish time')
check(driver('Dan').position == 3,
  'the on-road leader ranks behind drivers who already took the flag')

connected[4] = nil
RM_onPlayerDisconnect(4)        -- Dan DNFs
push()
check(driver('Dan').status == 'dnf', 'Dan is out')
check(driver('Alice').position == 3 and driver('Dan').position == 4,
  'a DNF drops below everyone still classified')

-- Clean up the directory tree this test created in the repo root. "rm -rf" is
-- not a command on Windows, so the tree has to be removed the native way there.
-- ---------------------------------------------------------------------------
-- Drivers going opposite ways round the same track are ranked against each other
-- ---------------------------------------------------------------------------
-- The claim the whole branching design rests on, and it is a claim about THIS
-- file: a branch substitutes a gate into a slot that already exists rather than
-- adding one, so `cp` counts SLOTS and means the same thing whichever way round a
-- driver is going. The comparator needed no lane arithmetic, no normalisation and
-- no new wire field -- and this test fails if someone later adds any.
--
-- Alice and Bob are clockwise, Cara and Dan counter-clockwise, all on lap 2 of
-- the same four-slot oval.
do
  -- A fresh race: the suite above ran its field to the flag, and finishers are
  -- ordered by the clock rather than by live progress.
  RM_onEndRace(1)
  RM_onSetTotalLaps(1, '{"laps":20}')
  RM_onGenerateGrid(1)
  RM_onStartCountdown(1)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
  local lap = driver('Alice').currentLap

  -- Dan retired earlier in this suite, so the field here is the three still out.
  progress(1, lap, 3, 20.0)    -- Alice  CW,  three slots cleared, 20 m to go
  progress(3, lap, 3, 60.0)    -- Cara   CCW, three slots cleared, 60 m to go
  progress(2, lap, 2, 5.0)     -- Bob    CW,  two slots, right on the gate
  push()
  check(order() == 'Alice,Cara,Bob',
    'slots cleared ranks the field across both directions, then distance')

  -- The lanes are opposite and the gates are on opposite sides of the circuit,
  -- but three slots is three slots: Cara passing Alice is a real change of place
  -- and the comparator sees it without knowing lanes exist.
  progress(3, lap, 4, 10.0)
  push()
  check(order() == 'Cara,Alice,Bob',
    'a counter-clockwise car takes the lead from a clockwise one on slots cleared')

  -- Reported slot counts are still clamped. No layout came through this server,
  -- so the ceiling is the flat one; a track loaded through RM_LoadLayout is
  -- clamped to its own length instead (see server_test).
  progress(2, lap, 99999, 1.0)
  push()
  check(driver('Bob').cpCleared == 500,
    'an absurd slot count is clamped rather than believed')
end

if package.config:sub(1, 1) == '\\' then
  os.execute('rmdir /s /q "Resources" 2>nul')
else
  os.execute('rm -rf Resources')
end

if fails == 0 then
  io.stdout:write(('ALL PASS (%d checks)\n'):format(checks))
else
  io.stdout:write(('%d/%d FAILED\n'):format(fails, checks))
  os.exit(1)
end
