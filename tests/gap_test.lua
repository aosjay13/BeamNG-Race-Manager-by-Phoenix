-- Headless test for GAP AND INTERVAL in server/RaceManager/main.lua: the split
-- timing the two are subtracted from, and the rules about when there is nothing
-- honest to say.
--
-- Why this is its own file: it is the only suite that cares what the CLOCK read
-- when something happened. positions_test drives the same handlers and never
-- advances race.time at all, because the running order it checks is built from
-- laps, checkpoints and metres and none of those is a time. Sharing its world
-- would have meant every existing check running against a clock that suddenly
-- moves.
--
-- The thing under test: a gap is a subtraction of two readings off ONE clock,
-- taken at the last checkpoint both cars have actually reached. Nothing is
-- estimated, nothing is interpolated, and a car that has not got there yet has
-- no gap rather than a guessed one.
--
-- Run from the repo root: lua5.3 tests/gap_test.lua

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
local lastState, hostedMap = nil, '/levels/gridmap_v2/info.json'

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (_, event, payload)
    if event == 'RM_Update' then lastState = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
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
-- Floats off a clock advanced in 100 ms steps: compare to the millisecond the
-- wire is rounded to, not to the bit.
local function near(a, b, msg)
  checks = checks + 1
  if a == nil or math.abs(a - b) > 0.0015 then
    fails = fails + 1
    print(('FAIL: %s (got %s, wanted %s)'):format(msg, tostring(a), tostring(b)))
  end
end

local function driver(name)
  for _, d in ipairs(lastState.drivers) do
    if d.name == name then return d end
  end
end
local function progress(pid, lap, cp, dist)
  RM_onProgress(pid, string.format('{"lap":%d,"cp":%d,"dist":%s}', lap, cp, tostring(dist)))
end
local function lap(pid, t)
  RM_onLap(pid, string.format('{"lapTime":%s}', tostring(t or 90)))
end
-- Advance the shared clock. TICK_MS is 100, so ten ticks is a second.
local function seconds(n)
  for _ = 1, math.floor(n * 10 + 0.5) do RM_Tick() end
end
local function push() RM_onRequestState(1) end

onInit()
RM_onLogin(1, '{"password":"phoenix"}')
for pid = 1, 4 do RM_onPlayerJoin(pid) end
RM_onSetTotalLaps(1, '{"laps":5}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'race is running')

-- ---------------------------------------------------------------------------
-- Nothing has happened yet, so there is nothing to say
-- ---------------------------------------------------------------------------
-- A blank column is the correct answer before anyone has reached a checkpoint,
-- and it is a different answer from zero: "level with the leader" and "has not
-- got anywhere yet" must not render the same.
push()
check(driver('Alice').gap == nil and driver('Alice').intv == nil,
  'a field that has cleared nothing has no gap and no interval')

-- ---------------------------------------------------------------------------
-- One checkpoint, four cars, four different times
-- ---------------------------------------------------------------------------
-- The whole mechanism in one pass: they cross the same gate at known moments
-- off one clock, so every number below is a subtraction that can be done by
-- hand.
seconds(10.0)
progress(1, 1, 1, 50.0)        -- Alice at 10.0s
seconds(1.5)
progress(2, 1, 1, 50.0)        -- Bob   at 11.5s
seconds(0.8)
progress(3, 1, 1, 50.0)        -- Cara  at 12.3s
seconds(2.2)
progress(4, 1, 1, 50.0)        -- Dan   at 14.5s
push()

check(driver('Alice').position == 1, 'Alice leads on distance to the next gate')
near(driver('Alice').gap, 0.0, 'the leader is zero behind themselves')
check(driver('Alice').intv == nil, 'and has nobody ahead to be an interval from')
near(driver('Bob').gap,   1.5, 'Bob is 1.5s behind the leader at that checkpoint')
near(driver('Bob').intv,  1.5, 'and 1.5s behind the car ahead, who is the leader')
near(driver('Cara').gap,  2.3, 'Cara is 2.3s behind the leader')
near(driver('Cara').intv, 0.8, 'but only 0.8s behind Bob')
near(driver('Dan').gap,   4.5, 'Dan is 4.5s behind the leader')
near(driver('Dan').intv,  2.2, 'and 2.2s behind Cara')

-- INTERVALS SUM TO THE GAP. Not a separate mechanism bolted on: both come off
-- the same stamps, so the arithmetic has to close.
near(driver('Bob').intv + driver('Cara').intv + driver('Dan').intv,
  driver('Dan').gap, 'the intervals down the field add up to the last gap')

-- ---------------------------------------------------------------------------
-- The comparison is made at the FOLLOWER's checkpoint, not the leader's
-- ---------------------------------------------------------------------------
-- This is the rule that makes a gap mean anything. Alice drives on to gate 5
-- while the others sit at gate 1; her being further round must not change what
-- anybody behind her is told, because the last point they have both reached is
-- still gate 1.
local bobGap = driver('Bob').gap
seconds(20.0)
progress(1, 1, 5, 30.0)
push()
check(driver('Alice').position == 1, 'Alice is still leading, four gates further on')
near(driver('Bob').gap, bobGap,
  'the leader pulling away does not move a gap measured where the two of them '
    .. 'last met -- it moves when the follower reaches the next checkpoint')

-- ...and it does move, by exactly the time she gained, once he gets there.
seconds(5.0)                     -- Bob reaches gate 5 at 39.0s; Alice was at 34.0s
progress(2, 1, 5, 30.0)
push()
near(driver('Bob').gap, 5.0, 'reaching the leader s checkpoint updates the gap')

-- ---------------------------------------------------------------------------
-- A lost checkpoint report is backfilled, not left as a hole
-- ---------------------------------------------------------------------------
-- The arithmetic looks the LEADER up at the FOLLOWER's checkpoint, so one hole
-- in the leader's table would blank the column for the whole field behind them.
-- Cara has never reported gates 2, 3 or 4; jumping straight to 5 has to leave
-- her a usable row rather than a nil.
seconds(3.0)                     -- 42.0s
progress(3, 1, 5, 30.0)
push()
near(driver('Cara').gap, 8.0, 'a driver who skipped three reports still has a gap')
near(driver('Cara').intv, 3.0, 'and an interval to the car ahead')

-- ---------------------------------------------------------------------------
-- The line is a checkpoint like any other
-- ---------------------------------------------------------------------------
-- A lap crossing is stamped through the same path, so a gap survives the moment
-- the leader starts a new lap instead of blanking until the first gate of it.
seconds(6.0)                     -- Alice crosses at 48.0s
lap(1)
seconds(2.5)                     -- Bob crosses at 50.5s
lap(2)
push()
check(driver('Alice').currentLap == 2 and driver('Bob').currentLap == 2,
  'both are on lap 2')
near(driver('Bob').gap, 2.5, 'the start/finish line is stamped like any other checkpoint')

-- ...and the telemetry wipe that comes with a new lap does not take the splits
-- with it. They belong to the session, not the lap.
check(driver('Bob').cpCleared == 0, 'the new lap starts with no checkpoints cleared')
near(driver('Bob').gap, 2.5, 'but the gap from the crossing survives the wipe')

-- ---------------------------------------------------------------------------
-- Retirements have no gap
-- ---------------------------------------------------------------------------
-- A driver who is out is classified by a ruling rather than by where they got
-- to, so a time behind the leader is a number about a race they are not in.
RM_onRetire(4)
push()
check(driver('Dan').status == 'dnf', 'Dan is out')
check(driver('Dan').gap == nil and driver('Dan').intv == nil,
  'a retirement carries no gap and no interval')
-- ...and the car behind the retirement is not given an interval to it.
check(driver('Cara').intv ~= nil, 'the drivers still running keep theirs')

-- ---------------------------------------------------------------------------
-- Never negative
-- ---------------------------------------------------------------------------
-- Alice crossed the line at 48.0s and Cara at 57.0s, so at the last point the
-- two of them have both reached, Alice is nine seconds AHEAD. Send Cara a long
-- way round the next lap and she outranks Alice on checkpoints -- while the
-- subtraction at Alice's last checkpoint still says minus nine. A minus sign in
-- a column headed "behind" reads as a bug, so it is clamped to level.
seconds(6.5)                     -- Cara crosses at 57.0s
lap(3)
seconds(1.0)
progress(3, 2, 9, 5.0)           -- ...and is nine gates into lap 2
push()
check(driver('Cara').position == 1, 'Cara now leads on checkpoints')
near(driver('Cara').gap, 0.0, 'the new leader is level with themselves')
check(driver('Alice').gap ~= nil and driver('Alice').gap >= 0,
  'a driver overtaken since their last checkpoint is never shown a negative gap')
near(driver('Alice').gap, 0.0,
  'it is reported as level rather than dropped: they are on the same second, '
    .. 'and the order has simply moved on since')

-- ---------------------------------------------------------------------------
-- Qualifying is scored on a lap, not on the clock
-- ---------------------------------------------------------------------------
-- Two drivers who set identical laps ten minutes apart are level, so a delta off
-- the session clock says nothing about who is quicker. The server sends nothing
-- and the panel works the qualifying gap out from the best laps it already has.
RM_onEndRace(1)
RM_onStartQualifying(1)
-- NO Generate Grid here. It is the control that takes a host FROM qualifying TO
-- the race and supersedes the session, which is exactly what this needs not to
-- happen; Start Quali has already formed its own grid.
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.sessionKind == 'quali', 'a qualifying session is running')
seconds(5.0)
progress(1, 1, 1, 50.0)
seconds(3.0)
progress(2, 1, 1, 50.0)
push()
check(driver('Alice').gap == nil and driver('Bob').gap == nil,
  'qualifying sends no clock gap: the classification is the best lap')

-- ---------------------------------------------------------------------------
-- A new session starts level
-- ---------------------------------------------------------------------------
-- The splits are stamps off a clock that goes back to zero at the grid. Keeping
-- them across a session would have the next race's first checkpoint reading as
-- several minutes behind the last one's.
RM_onEndRace(1)
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
push()
check(driver('Alice').gap == nil and driver('Bob').gap == nil,
  'the grid clears every split with the clock it stamped them from')
seconds(4.0)
progress(1, 1, 1, 50.0)
seconds(1.0)
progress(2, 1, 1, 50.0)
push()
near(driver('Bob').gap, 1.0,
  'and the new session measures from its own zero, not the old one s')

-- ---------------------------------------------------------------------------
-- Both numbers are on the wire, and rounded
-- ---------------------------------------------------------------------------
-- Three decimals is past what this method resolves (the stamp carries the
-- reporting client's ping) and it keeps a full field of raw floats out of a
-- payload that goes out three times a second.
do
  local g = driver('Bob').gap
  check(g == math.floor(g * 1000 + 0.5) / 1000,
    'the gap on the wire is rounded to the millisecond')
end

if package.config:sub(1, 1) == '\\' then
  os.execute('rmdir /s /q "Resources" 2>nul')
else
  os.execute('rm -rf Resources')
end

if fails == 0 then
  print(('gap_test: %d checks, 0 failures'):format(checks))
else
  print(('gap_test: %d FAILURES of %d checks'):format(fails, checks))
  os.exit(1)
end
