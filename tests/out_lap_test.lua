-- Headless test for the QUALIFYING OUT LAP in server/RaceManager/main.lua.
--
-- Why this exists: qualifying starts from a standing grid, so a driver's first
-- crossing of the line ends the lap they spent getting off it. Timing that lap
-- measures a launch, and on a track with a slow first corner it produces a time
-- nobody can beat later in the session for reasons that have nothing to do with
-- pace. The first lap is therefore given away: not timed, not scored, not
-- counted against the lap allowance.
--
-- The rule it must not turn back into: this mod once had an out lap because
-- qualifying had no defined start at all - drivers began from wherever they were
-- parked, so the first crossing arrived at a different point of the circuit for
-- everybody and a "3 lap" session took five or six laps to finish. The out lap
-- here starts on the grid with everyone else's and is counted SEPARATELY from
-- the allowance, so three qualifying laps is still three timed laps.
--
-- Run from the repo root: lua5.3 tests/out_lap_test.lua

local connected = { [0] = 'Guest_A', [1] = 'Guest_B', [2] = 'Guest_C' }
local lastState  = nil
local chat       = {}
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
local function clearSignals() spectated, released, chat = {}, {}, {} end
local function lap(pid, t) RM_onLap(pid, '{"lapTime":' .. t .. '}') end

-- Everyone in, grid, hold, countdown, GO. Closes whatever was running first:
-- Start Qualifying is refused while a session is under way, and a test that
-- silently kept driving the previous session would assert nothing.
local function startQuali(laps)
  RM_onEndRace(0)
  RM_onSetQualiLimits(0, '{"laps":' .. (laps or 0) .. ',"seconds":0}')
  RM_onStartQualifying(0)
  RM_onStartCountdown(0)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end

-- ===========================================================================
-- 1. The rule is announced before anyone has driven anywhere
-- ===========================================================================
-- A driver cannot be expected to work out that their lap is not being timed
-- from the absence of a time. It is on the state broadcast (so the app can say
-- so on the driver's own readout), on every driver row (so the timing screen
-- can), and in chat at GO (so it reaches a driver with no app open).
clearSignals()
RM_onSetQualiLimits(0, '{"laps":3,"seconds":0}')
RM_onStartQualifying(0)
check(lastState.qualiOutLap == true, 'the qualifying grid already says there is an out lap')
check(driver(0).outLap == true, 'and every gridded driver is carrying one')
check(chatSaid('out lap'), 'forming the grid says so in chat')

RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'qualifying', 'the session is running')
check(chatSaid('OUT LAP'), 'and GO says it again, in the words a driver reads mid-race')
for pid = 0, 2 do
  check(driver(pid).outLap == true, 'driver ' .. pid .. ' starts owing an out lap')
  check(driver(pid).currentLap == 1, 'and starts on lap 1 like everybody else')
end

-- ===========================================================================
-- 2. The out lap is thrown away, and it is thrown away completely
-- ===========================================================================
-- Fast enough to win pole three times over: it must reach nothing at all.
clearSignals()
lap(0, 42.0)
check(driver(0).qualiBest == nil, 'no Best Lap from an out lap')
check(driver(0).qualiLaps == 0, 'no lap spent from the allowance')
check(lastState.bestLapTime == nil, 'and not the fastest lap of the session either')
check(driver(0).status == 'qualifying', 'the driver is still out on track')
check(spectated[0] == nil, 'and still has their car')
check(driver(0).outLap == false, 'they are on a timed lap now')
check(driver(0).currentLap == 2, 'and the lap counter advanced, as it does for any crossing')
check(chatSaid('Out lap complete'), 'the driver is told their timing has started')

-- One driver's out lap is their own business: the others are still on theirs.
check(driver(1).outLap == true and driver(2).outLap == true,
  'a driver completing their out lap does not end anybody else\'s')

-- ===========================================================================
-- 3. Three qualifying laps means three TIMED laps
-- ===========================================================================
-- The allowance is spent by scored laps only, so the session runs to four
-- crossings and the fourth is what ends a driver's session.
lap(0, 95.0)
check(driver(0).qualiLaps == 1 and driver(0).qualiBest == 95.0, 'lap 1 of 3 counts')
lap(0, 93.0)
check(driver(0).qualiLaps == 2 and driver(0).qualiBest == 93.0, 'lap 2 of 3 improves it')
check(driver(0).status == 'qualifying', 'and does not end the session early')
lap(0, 97.0)
check(driver(0).qualiLaps == 3, 'lap 3 of 3 is the last one')
check(driver(0).qualiBest == 93.0, 'a slower lap does not overwrite the best')
check(driver(0).status == 'finished', 'the allowance is spent on the fourth crossing')
check(spectated[0] ~= nil, 'and the car comes off the track, as before')
check(chatSaid('used all 3 qualifying lap'),
  'the driver is told they used 3 laps - the number the admin set, not 4')

-- ===========================================================================
-- 4. A second session re-arms it for everybody
-- ===========================================================================
-- Including for the driver who had already given theirs away in the session
-- before: the flag belongs to the session, not to the driver.
startQuali(1)
for pid = 0, 2 do
  check(driver(pid).outLap == true, 'driver ' .. pid .. ' owes a fresh out lap')
  check(driver(pid).qualiBest == nil, 'and starts with no time')
end
clearSignals()
for pid = 0, 2 do lap(pid, 60.0) end       -- out laps
check(lastState.phase == 'qualifying', 'a field of out laps does not end a 1 lap session')
for pid = 0, 2 do lap(pid, 88.0 + pid) end -- the single timed lap each
check(lastState.phase == 'waiting', 'the timed lap does')
for pid = 0, 2 do
  check(driver(pid).qualiLaps == 1, 'driver ' .. pid .. ' ran exactly 1 timed lap')
  check(driver(pid).qualiBest == 88.0 + pid, 'and it is the one on the board')
end

-- ===========================================================================
-- 5. A race gives no lap AWAY, but its first crossing is not timed
-- ===========================================================================
-- Lap 1 of a race is a lap of the race. Nothing is given away, because a race is
-- not timing one lap at a time -- the flag decides it, and a lap thrown away
-- would be a lap of the race distance thrown away. That is the difference from
-- qualifying's out lap, which is added ON TOP of the allowance.
--
-- Its TIME is dropped, though, and that is not the same thing. Lap 1 is run off a
-- STANDING START: it carries the launch, the run to the first corner and
-- whatever the field did to each other getting there, so it is not the same
-- measurement as a flying lap and does not belong in the same contest. Asked for
-- from a live test.
--
-- A ONE-LAP race is exempt, because there the standing lap is the only lap there
-- is and dropping its time would leave the results with no times at all.
--
-- This test used to assert the opposite while docs/REFERENCE.md described what
-- is asserted here. The docs were right.
RM_onSetTotalLaps(0, '{"laps":2}')
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'the race is running')
check(lastState.qualiOutLap ~= true, 'a race broadcasts no out lap')
for pid = 0, 2 do check(driver(pid).outLap == false, 'driver ' .. pid .. ' owes nothing') end

lap(0, 99.0)
check(driver(0).raceBest == nil, 'lap 1 of a race sets no lap time')
check(lastState.bestLapTime == nil, 'so it cannot take fastest lap of the race')
check(driver(0).lapsLed == 1,
  'but it COUNTS: the driver who led it is credited with leading it')
check(driver(0).currentLap == 2, 'and the driver is on lap 2, not still on lap 1')
lap(1, 99.5); lap(2, 99.9)
-- The second crossing is the first timed one.
lap(0, 98.0)
check(driver(0).raceBest == 98.0, 'the second crossing IS timed')
check(lastState.bestLapTime == 98.0, 'and can take fastest lap')
lap(1, 98.5); lap(2, 98.9)
-- Past the hold at the flag: a race no longer closes on the tick the last car
-- crosses, so the field stays ghosted for a moment (see race.endDelay).
for _ = 1, 70 do RM_Tick() end
check(lastState.phase == 'finished', 'and 2 laps means 2 laps, exactly as before')

-- A ONE-LAP race keeps its time: there is no flying lap to compare against, and
-- results with no times in them at all would be worse than a standing-start one.
RM_onEndRace(0)
RM_onSetTotalLaps(0, '{"laps":1}')
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lap(0, 97.0)
check(driver(0).raceBest == 97.0, 'a one-lap race DOES time its only lap')

-- ===========================================================================
-- 6. A sprint stage has no out lap either, and must not
-- ===========================================================================
-- A point-to-point stage is driven ONCE, first gate to last. A lap given away
-- there is the whole session given away - and there is no line to come back
-- past to start a timed one.
RM_onResetLeaderboard(0)
RM_onSetPointToPoint(0, '{"enabled":true}')
startQuali(1)
check(lastState.qualiOutLap == false, 'a sprint stage runs no out lap')
for pid = 0, 2 do check(driver(pid).outLap == false, 'driver ' .. pid .. ' owes nothing') end

clearSignals()
lap(0, 74.5)
check(driver(0).qualiBest == 74.5, 'the one run down the stage IS the timed run')
check(driver(0).qualiLaps == 1, 'and it counts')
check(driver(0).status == 'finished', 'and it completes that driver\'s session')

-- Back to a circuit, and the rule comes back with it.
RM_onResetLeaderboard(0)
RM_onSetPointToPoint(0, '{"enabled":false}')
startQuali(1)
check(lastState.qualiOutLap == true, 'a circuit qualifies with an out lap again')

if fails == 0 then
  print('out_lap_test: ' .. checks .. ' checks, 0 failures')
else
  print('out_lap_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
