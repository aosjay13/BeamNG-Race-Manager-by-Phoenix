-- Headless test for THE BLUE FLAG in server/RaceManager/main.lua.
--
-- Lapped traffic was displayed and never signalled. The board read "+1 LAP" and
-- neither driver was told anything: the backmarker got no blue flag, and the car
-- closing on them got no warning that the car ahead was not racing it.
--
-- THE CLASSIFICATION IS THE WRONG LIST TO READ THIS OFF, and that is the whole
-- reason this file exists rather than three lines in positions_test. A lapped
-- car sorts BELOW the entire lead lap, so the car directly above it on the
-- board is another backmarker -- while the car physically behind it on the road,
-- the one actually about to come past, is somewhere near the top of the sheet.
-- Adjacency on the timing screen and adjacency on the track stop being the same
-- question the moment anybody is lapped.
--
-- So the checks that matter are the ones that would pass against a version that
-- read the board instead of the road:
--
--   * the flag goes to the car being CAUGHT, not to the one below it in the
--     classification;
--   * two cars on the SAME lap running nose to tail get nothing, however close;
--   * a car a lap down on the far side of the circuit gets nothing, however
--     many laps down it is;
--   * the flag clears when the lapping car goes by.
--
-- TRACK ORDER IS CHECKPOINTS THEN METRES, and the direction is the thing to get
-- right: `distNext` is the distance TO the next gate, so a SMALLER one is
-- further along. A car is behind another when it has cleared fewer checkpoints,
-- or the same number with further still to run.
--
-- The other half is hysteresis. A single threshold makes a flag that strobes:
-- one broadcast inside it and the next outside turns the flag on and off several
-- times a second, and a flag that blinks is one a driver learns to ignore. The
-- test for that is not "a wide gap keeps the flag" -- a merely wide threshold
-- passes that. It is that the SAME gap does different things depending on
-- whether the flag was already out.
--
-- Run from the repo root: lua5.3 tests/blue_flag_test.lua

local connected = { [0] = 'Admin', [1] = 'Alice', [2] = 'Bob', [3] = 'Cara' }
local lastState = nil
local chatLog   = {}
local timers    = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chatLog[#chatLog + 1] = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
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
local function seconds(n)
  for _ = 1, math.floor(n * 10) do RM_Tick() end
end
local function lap(pid) RM_onLap(pid, '{"lapTime":60.0}') end
-- A driver reaching a checkpoint, NOW. Only a count that goes UP stamps a
-- split, which is the whole mechanism the gap is built out of -- so every
-- position in this file walks forward, exactly as a car does.
local function at(pid, cp, dist)
  RM_onProgress(pid, string.format('{"lap":%d,"cp":%d,"dist":%.1f}',
    driver(pid).currentLap, cp, dist or 100.0))
end
local function blue(pid)    return driver(pid) and driver(pid).blue == true end
local function lapping(pid) return driver(pid) and driver(pid).lapping == true end

onInit()
RM_onLogin(0, '{"password":"phoenix"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":50}')
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'the race is running')

-- ---------------------------------------------------------------------------
-- Put Cara a lap down
-- ---------------------------------------------------------------------------
lap(1); lap(2); lap(3)          -- all onto lap 2
seconds(1)
lap(1); lap(2)                  -- Alice and Bob onto lap 3, Cara left on 2
seconds(1)
check(driver(1).currentLap == 3 and driver(3).currentLap == 2,
  'Alice is a lap up on Cara')

-- ---------------------------------------------------------------------------
-- SAME LAP, NOSE TO TAIL: nothing
-- ---------------------------------------------------------------------------
-- Alice and Bob are as close as two cars get and neither is lapping the other.
-- A version that flagged on proximity alone would light this up.
at(1, 1, 50.0)
seconds(0.2)
at(2, 1, 60.0)                  -- Bob just behind Alice, same lap
at(3, 1, 400.0)                 -- Cara a lap down, far up the road
seconds(0.5)
check(not blue(1) and not blue(2),
  'two cars on the same lap get no blue flag, however close')
check(not lapping(1) and not lapping(2),
  'and neither is told they are lapping anybody')

-- ---------------------------------------------------------------------------
-- A LAP DOWN AND FAR AWAY: still nothing
-- ---------------------------------------------------------------------------
-- Cara is a lap down and nowhere near either of them. She is behind on the
-- SHEET by a whole lap, and the flag is not about the sheet.
check(not blue(3),
  'a lapped car nowhere near the cars lapping it gets no flag')

-- ---------------------------------------------------------------------------
-- A THREE SECOND GAP, COLD: not close enough
-- ---------------------------------------------------------------------------
-- Established before the flag has ever been out, so this is the SHOW threshold
-- being tested. The same gap is used again further down, once the flag IS out,
-- and must behave differently there.
-- Bob goes far enough up the road to stay there. Parked at a middling
-- checkpoint he ends up directly behind Cara as she works round, and becomes
-- the car lapping her -- which is right, and is a different test.
at(2, 20, 100.0)
at(3, 4, 300.0)                 -- Cara clears checkpoint 4
seconds(3.0)
at(1, 4, 300.0)                 -- Alice reaches it three seconds later
at(3, 5, 300.0)                 -- ...and Cara moves on, so Alice is behind her
seconds(0.5)
check(not blue(3), 'three seconds back is not close enough to light the flag')
check(not lapping(1), 'and the lapping car is told nothing yet')

-- ---------------------------------------------------------------------------
-- THE LAPPING CAR CLOSES: the flag comes out
-- ---------------------------------------------------------------------------
at(3, 6, 300.0)                 -- Cara clears checkpoint 6
seconds(0.4)
at(1, 6, 300.0)                 -- Alice reaches it 0.4s later: right behind her
at(3, 7, 300.0)                 -- Cara moves on; Alice is behind on the road
seconds(0.5)
check(blue(3), 'the car being caught is shown the blue flag')
check(lapping(1), 'and the car doing the lapping is told there is one ahead')

-- THE FLAG IS ON THE RIGHT CAR. Bob is a lap up on Cara too and sits between
-- them in the classification; a version that read the board would have flagged
-- the wrong pair, or flagged Cara for the wrong reason.
check(not blue(1), 'the leader is not shown blue')
check(not blue(2), 'nor the car between them on the timing sheet')
check(not lapping(3), 'and the backmarker is not told they are lapping anybody')
check(not lapping(2), 'nor a car a lap up that is nowhere near one')

-- The board still says what it always said. The flag is a signal ON TOP of the
-- classification, not a change to it.
check(driver(3).position == 3, 'Cara is still classified third')

-- ---------------------------------------------------------------------------
-- HYSTERESIS: the same gap, two different answers
-- ---------------------------------------------------------------------------
-- Three seconds did NOT light the flag above. With the flag already out it must
-- not put it away, or a car sitting near the threshold turns it on and off
-- several times a second.
at(3, 8, 300.0)
seconds(3.0)
at(1, 8, 300.0)                 -- the same three seconds, flag already out
at(3, 9, 300.0)
seconds(0.5)
check(blue(3),
  'a gap that was too wide to LIGHT the flag is not wide enough to clear it')
check(lapping(1), 'and the warning holds with it')

-- ---------------------------------------------------------------------------
-- LET BY: the flag clears
-- ---------------------------------------------------------------------------
-- Alice goes past. On the road she is now in front of Cara, so the pair is no
-- longer "lapping car behind backmarker" and there is nothing left to signal.
at(1, 12, 100.0)                -- Alice well up the road
seconds(0.5)
check(not blue(3), 'once the lapping car is past, the flag goes')
check(not lapping(1), 'and the warning goes with it')

-- ---------------------------------------------------------------------------
-- A CAUTION OUTRANKS IT
-- ---------------------------------------------------------------------------
-- Nobody is letting anybody by under a yellow, and a blue flag beside a yellow
-- is two instructions that contradict each other. The pair is set up again
-- first, so what is tested is the caution clearing it rather than the geometry
-- never having been there.
at(3, 13, 300.0)
seconds(0.4)
at(1, 13, 300.0)
at(3, 14, 300.0)
seconds(0.5)
check(blue(3), 'the pair is close again and the flag is out')

RM_onCaution(0)
seconds(0.5)
check(lastState.cautionPending == true, 'a caution is called')
check(not blue(3), 'and the blue flag goes: nobody is being let by under a yellow')
check(not lapping(1), 'both ends of it')

-- ...and it is available again when the race is.
lap(1)                          -- the leader makes the caution official
lap(3)                          -- Cara comes round under the yellow as well
RM_onRestart(0)
lap(1)                          -- and Alice takes the restart
check(lastState.caution == false, 'the race is green again')
-- Both have crossed the line, so both are back at the start of a lap with fresh
-- splits. Cara is now two laps down rather than one, which changes nothing: the
-- rule is "the car behind is on a higher lap", not "exactly one higher".
at(3, 2, 300.0)
seconds(0.4)
at(1, 2, 300.0)
at(3, 3, 300.0)
seconds(0.5)
check(driver(1).currentLap > driver(3).currentLap + 1, 'Cara is now two laps down')
check(blue(3), 'and the blue flag comes back once the race is green')
check(lapping(1), 'on both ends, at two laps down as at one')

-- ---------------------------------------------------------------------------
-- Nothing outlives the session
-- ---------------------------------------------------------------------------
RM_onEndRace(0)
check(not blue(3), 'ending the session drops the flag')
check(not lapping(1), 'and the warning')

-- ---------------------------------------------------------------------------
-- Qualifying has no lapped traffic
-- ---------------------------------------------------------------------------
-- Drivers are on their own laps and a car "a lap down" is just a car that went
-- out later. There is nothing to let by.
RM_onResetLeaderboard(0)
RM_onSetSpectating(0, '{"spectating":true}')
RM_onStartQualifying(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'qualifying', 'qualifying is running')
lap(1); lap(2); lap(3)
seconds(1)
lap(1); lap(2)
seconds(1)
at(3, 4, 300.0)
seconds(0.4)
at(1, 4, 300.0)
at(3, 5, 300.0)
seconds(0.5)
check(not blue(3), 'no blue flag in qualifying, whatever the lap counters read')
check(not lapping(1), 'and nobody is lapping anybody')

if fails == 0 then
  print(string.format('blue_flag_test: %d checks, 0 failures', checks))
else
  print(string.format('blue_flag_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
