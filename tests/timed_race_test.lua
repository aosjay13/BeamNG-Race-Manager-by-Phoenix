-- Headless test for TIMED RACES in server/RaceManager/main.lua.
--
-- The format is "10 minutes + 1 lap", and the whole of it is in what does NOT
-- happen when the clock runs out. Nothing does. The race ends one lap after the
-- LEADER next takes the line, so a driver watching the countdown reach zero
-- still has two laps to run: the one they are on, and the last one.
--
-- Three states, and each exists because the answer to "is this crossing your
-- last" is different in it:
--
--   raceExpired  the clock is out. Waiting on the leader. Nothing terminal.
--   lastLapNum   the leader has been past, and that crossing named the final
--                lap. Completing THAT lap ends a driver's race -- not their
--                next crossing, which is qualifying's rule and would flag off a
--                car two seconds behind the leader a full lap early.
--   finalLap     the winner is home. NOW every crossing is terminal, which is
--                what classifies the cars that are a lap or more down.
--
-- WHAT THIS FILE IS REALLY GUARDING is the middle one. Collapsing it into
-- `finalLap` is the obvious implementation, it passes any test with one car in
-- it, and it robs second place of a lap.
--
-- Run from the repo root: lua5.3 tests/timed_race_test.lua

local connected = { [0] = 'Admin', [1] = 'Leader', [2] = 'Second', [3] = 'Lapped' }
local lastState = nil
local lastChat  = nil
local chatLog   = {}
local spectated = {}
local timers    = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg)
    lastChat = msg
    chatLog[#chatLog + 1] = msg
  end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update'        then lastState = payload end
    if event == 'RM_ForceSpectate' then spectated[target] = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
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
local function driver(pid)
  for _, d in ipairs(lastState.drivers) do
    if d.id == pid then return d end
  end
end
local function chatHas(text)
  for _, m in ipairs(chatLog) do
    if m:find(text, 1, true) then return true end
  end
  return false
end
-- Run the clock forward. One tick is CFG.tickMs (100 ms), so this is seconds.
local function seconds(n)
  for _ = 1, math.floor(n * 10) do RM_Tick() end
end
-- A lap for one driver. The lap time is arbitrary: nothing here is about times.
local function lap(pid)
  RM_onLap(pid, '{"lapTime":60.0}')
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
-- The admin runs the session rather than driving it, so the field under test is
-- three cars and the leader is unambiguous.
RM_onSetSpectating(0, '{"spectating":true}')

-- ---------------------------------------------------------------------------
-- Setting the length
-- ---------------------------------------------------------------------------
RM_onSetRaceLimits(0, '{"laps":25,"seconds":600,"mode":"timed"}')
check(lastState.raceTimeLimit == 600, 'a race can be set to run to a clock')
check(lastState.raceMode == 'timed', 'and says so')
check(lastState.totalLaps == 25, 'and the lap count it had is remembered underneath')

-- Laps mode ZEROES the clock rather than leaving it set and unused. A lap race
-- with a live time limit underneath it is a race that ends when nobody expects.
RM_onSetRaceLimits(0, '{"laps":25,"seconds":600,"mode":"laps"}')
check(lastState.raceTimeLimit == 0, 'picking laps clears the clock, whatever was sent with it')
check(lastState.raceMode == 'laps', 'and the mode follows')

-- Asking for a clock and giving none is a lap race whatever the button said.
RM_onSetRaceLimits(0, '{"laps":25,"seconds":0,"mode":"timed"}')
check(lastState.raceMode == 'laps', 'a timed race with no clock falls back to laps')

-- A PAYLOAD WITH NO MODE is a panel from before endurance existed, which said
-- everything by the numbers alone. Read it the way that client meant it.
RM_onSetRaceLimits(0, '{"laps":25,"seconds":600}')
check(lastState.raceMode == 'timed' and lastState.raceTimeLimit == 600,
  'a mode-less payload with a clock is still a timed race')
RM_onSetRaceLimits(0, '{"laps":25,"seconds":0}')
check(lastState.raceMode == 'laps', 'and a mode-less payload with no clock is a lap race')

RM_onSetRaceLimits(3, '{"laps":1,"seconds":30,"mode":"timed"}')
check(lastState.raceTimeLimit == 0, 'setting the race length requires authentication')

RM_onSetRaceLimits(0, '{"laps":25,"seconds":600,"mode":"timed"}')

-- ---------------------------------------------------------------------------
-- The clock expiring changes nothing on its own
-- ---------------------------------------------------------------------------
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'the race is running')
check(lastState.raceLeft ~= nil and lastState.raceLeft > 599,
  'and the header has a countdown to show')

-- Two laps in, well inside the clock. The lap count is 25 and nobody is near it:
-- a timed race must not be endable by the number in the laps box.
for _ = 1, 2 do
  lap(1); lap(2); lap(3)
end
seconds(30)
check(lastState.raceExpired ~= true, 'the clock has not expired yet')
check(driver(1).status == 'racing', 'and nobody has been flagged off')

seconds(590)   -- past 600 total
check(lastState.raceExpired == true, 'the clock expires')
check(lastState.lastLapNum == nil, 'but names no final lap: the leader has not been past')
check(lastState.finalLap ~= true, 'and the flag is not out')
check(driver(1).status == 'racing' and driver(2).status == 'racing'
  and driver(3).status == 'racing', 'every driver is still racing')
check(chatHas('TIME UP'), 'the field is told the clock is out')

-- THE LAP COUNT IS INERT. Twenty-five laps was set and the race is three laps
-- old; if totalLaps were still a target this would be a very different test.
check(lastState.totalLaps == 25, 'the lap setting is still there')

-- ---------------------------------------------------------------------------
-- The leader's crossing starts the final lap
-- ---------------------------------------------------------------------------
lap(1)
check(lastState.lastLapNum == 4,
  'the leader crossing after expiry names the final lap (got '
    .. tostring(lastState.lastLapNum) .. ')')
check(driver(1).status == 'racing',
  'and the leader is NOT flagged off by the lap they just started')
check(chatHas('FINAL LAP'), 'the field is told which lap is the last')
check(lastState.finalLap ~= true, 'the checkered flag is still not out')

-- SECOND PLACE GETS A FULL LAP. They had not reached the line when the leader
-- started the final lap, so their next crossing completes lap 3 -- the same lap
-- the leader had just finished -- and starts their lap 4. Ending their race
-- here is the bug this whole file exists to catch.
lap(2)
check(driver(2).status == 'racing',
  'the car behind the leader takes the flag lap rather than being flagged off at the line')
check(driver(2).currentLap == 4, 'and is on the final lap too')

-- ---------------------------------------------------------------------------
-- Completing the final lap ends it, and the flag falls on the winner
-- ---------------------------------------------------------------------------
lap(1)
check(driver(1).status == 'finished', 'the leader completes the final lap and is classified')
check(lastState.finalLap == true, 'which puts the checkered flag out')
check(chatHas('CHECKERED FLAG'), 'and announces the winner')

lap(2)
check(driver(2).status == 'finished', 'second place finishes on the same lap')

-- A LAPPED CAR IS CLASSIFIED WHERE IT GOT TO. It is on lap 3 and will never
-- reach lap 4; with the flag out its next crossing is its last, which is what
-- the real checkered flag does to a car a lap down.
check(driver(3).currentLap < 4, 'the lapped car never reached the final lap number')
lap(3)
check(driver(3).status == 'finished',
  'and is classified on its next crossing once the flag is out')

-- ---------------------------------------------------------------------------
-- A lap race is untouched by any of it
-- ---------------------------------------------------------------------------
-- The whole feature hangs off raceTimeLimit > 0. With it at zero nothing above
-- can fire, and a race still ends on the lap count exactly as it always has.
RM_onEndRace(0)
RM_onSetRaceLimits(0, '{"laps":2,"seconds":0,"mode":"laps"}')
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.raceLeft == nil, 'a lap race has no countdown')
seconds(700)
check(lastState.raceExpired ~= true, 'and no clock to expire, however long it runs')
lap(1)
check(driver(1).status == 'racing', 'one lap of two done')
lap(1)
check(driver(1).status == 'finished', 'and the lap count still ends the race')

-- ---------------------------------------------------------------------------
-- ENDURANCE: both limits live, whichever comes first
-- ---------------------------------------------------------------------------
-- The distinguishing property against a plain timed race is that the LAP TARGET
-- is still armed. Dropping it is the obvious implementation and turns a
-- "50 laps or 60 minutes" race into a 60 minute one.
RM_onEndRace(0)
RM_onSetRaceLimits(0, '{"laps":3,"seconds":3600,"mode":"endurance"}')
check(lastState.raceMode == 'endurance' and lastState.totalLaps == 3
  and lastState.raceTimeLimit == 3600, 'endurance holds both limits at once')

RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.raceLeft ~= nil, 'and runs a clock like a timed race')

-- THE DISTANCE ARRIVES FIRST. An hour is nowhere near up; three laps is.
for _ = 1, 2 do lap(1); lap(2); lap(3) end
check(driver(1).status == 'racing', 'two of three laps done, nobody home')
lap(1)
check(driver(1).status == 'finished', 'completing the distance ends the leader race')
check(lastState.finalLap == true,
  'and puts the flag out for everyone: an endurance race is over when it is won')
check(lastState.raceExpired ~= true, 'the clock never came into it')

-- A car still short of the distance is classified as it comes past, rather than
-- being made to run laps after the race has been won.
check(driver(3).status == 'racing', 'the third car is still short of the distance')
lap(3)
check(driver(3).status == 'finished', 'and is classified on its next crossing')

-- THE CLOCK ARRIVES FIRST. Fifty laps nobody will reach, sixty seconds they
-- will: the "+1 lap" ending has to work with a lap target still armed.
RM_onEndRace(0)
RM_onSetRaceLimits(0, '{"laps":50,"seconds":60,"mode":"endurance"}')
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lap(1); lap(2); lap(3)
seconds(70)
check(lastState.raceExpired == true, 'the clock expires well short of the distance')
check(lastState.lastLapNum == nil, 'and still waits on the leader')
lap(1)
check(lastState.lastLapNum == 3, 'whose crossing names the final lap')
check(driver(1).status == 'racing', 'without flagging the leader off')
lap(1)
check(driver(1).status == 'finished', 'and the race ends on the clock, not on 50 laps')
check(driver(1).currentLap < 50, 'nowhere near the lap target that was also set')

if fails == 0 then
  print(string.format('timed_race_test: %d checks, 0 failures', checks))
else
  print(string.format('timed_race_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
