-- Headless test for THE CAUTION and THE RESTART in server/RaceManager/main.lua.
--
-- A full-course yellow called mid-race, and one thing about it is the whole
-- feature: IT FREEZES THE RUNNING ORDER.
--
-- That is the only half of a real caution this plugin can enforce. The server
-- has no physics -- it cannot slow a car, close a gap or line a field up behind
-- the leader. What it can do is stop positions changing from the moment the
-- yellow comes out, which is exactly what a real caution does to the timing
-- sheet and is a scoring rule rather than a movement one.
--
-- So this file is mostly about the freeze, and the way it tests it is to make
-- the field OVERTAKE under the caution and then assert the board did not move.
-- A test that only checked the flag colour would pass against a caution that
-- froze nothing at all.
--
-- The other thing worth a file of its own: a frozen order must never outlive the
-- caution that set it. A cautionPos left standing after a session would silently
-- order the NEXT race, which is invisible until somebody wins a race they were
-- fourth in.
--
-- Run from the repo root: lua5.3 tests/caution_test.lua

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
local function chatHas(text)
  for _, m in ipairs(chatLog) do
    if m:find(text, 1, true) then return true end
  end
  return false
end
local function chatClear() chatLog = {} end
local function seconds(n)
  for _ = 1, math.floor(n * 10) do RM_Tick() end
end
local function lap(pid) RM_onLap(pid, '{"lapTime":60.0}') end
local function report(pid, lapNum, cp, dist)
  RM_onProgress(pid, string.format('{"lap":%d,"cp":%d,"dist":%.1f}', lapNum, cp, dist))
end
-- The running order as a list of pids, top first, off the last broadcast.
-- PARTICIPANTS ONLY. The admin runs the session from the spectator seats and is
-- still a row on the board; including them would make every expected order in
-- this file carry a driver who is not racing.
local function order()
  local out = {}
  for _, d in ipairs(lastState.drivers) do
    if not d.spectating then out[#out + 1] = d.id end
  end
  return table.concat(out, ',')
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":20}')

-- ---------------------------------------------------------------------------
-- A caution needs a race to neutralise
-- ---------------------------------------------------------------------------
chatClear()
RM_onCaution(0)
check(lastState.caution ~= true, 'no caution before the lights: there is nothing to freeze')
check(chatHas('No race is running'), 'and the admin is told why')

RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'the race is running')
check(lastState.caution == false, 'and it is not under caution')

RM_onCaution(3)
check(lastState.caution ~= true, 'throwing a caution requires authentication')

-- ---------------------------------------------------------------------------
-- Build a running order, then freeze it
-- ---------------------------------------------------------------------------
-- Alice leads on laps, Bob second, Cara third. Laps first, then checkpoints,
-- then distance -- the ordinary comparator, with nothing frozen yet.
lap(1); lap(2); lap(3)          -- everyone onto lap 2
lap(1)                          -- Alice onto lap 3
report(1, 3, 1, 100.0)
report(2, 2, 5, 50.0)
report(3, 2, 3, 50.0)
seconds(0.5)
check(order() == '1,2,3', 'the live order is Alice, Bob, Cara (got ' .. order() .. ')')

chatClear()
RM_onCaution(0)
check(lastState.caution == true, 'the caution is out')
check(lastState.flag == 'yellow', 'under a yellow flag')
check(lastState.cautionLaps == 0, 'no laps run under it yet')
check(chatHas('FULL COURSE YELLOW'), 'the field is told')
check(chatHas('NO OVERTAKING'), 'and told what it means')
check(chatHas('FROZEN'), 'and that the order is frozen, which is the part that is enforced')
-- The lap the LEADER was on, so a marshal reading the log afterwards can place
-- the caution in the race. Taken from the frozen order rather than from
-- lastLapNum, which is the final lap of a timed race and means nothing here.
check(chatHas('on lap 3'),
  'the announcement names the lap the leader was on when the yellow came out')

-- ---------------------------------------------------------------------------
-- THE FREEZE: overtake under the caution and the board does not move
-- ---------------------------------------------------------------------------
-- This is the check the whole file exists for. Cara passes BOTH cars on every
-- metric the live comparator uses -- more laps, more checkpoints, less distance
-- to the next gate -- and the board must not move a place.
lap(3); lap(3)                  -- Cara now leads on laps outright
report(3, 4, 9, 1.0)
report(1, 3, 1, 900.0)
report(2, 2, 1, 900.0)
seconds(0.5)
check(order() == '1,2,3',
  'the order is FROZEN: Cara passing both cars under the caution changes '
    .. 'nothing on the board (got ' .. order() .. ')')
check(driver(3).position == 3, 'Cara is still classified third')
check(driver(3).currentLap > driver(1).currentLap,
  'even though she is genuinely a lap up the road, which is what she was told to do')

-- Caution laps are counted off the leader's crossing, and they count toward the
-- distance: the race does not get longer because it was neutralised.
check(lastState.cautionLaps > 0, 'laps run under the caution are counted')
local underCaution = lastState.cautionLaps

-- A second caution while one is running is refused rather than restacked.
chatClear()
RM_onCaution(0)
check(chatHas('already under caution'), 'a second caution is refused, and says so')
check(lastState.cautionLaps == underCaution, 'and does not reset the lap count')

-- ---------------------------------------------------------------------------
-- The restart
-- ---------------------------------------------------------------------------
chatClear()
RM_onRestart(3)
check(lastState.caution == true, 'restarting requires authentication')

RM_onRestart(0)
check(lastState.caution == false, 'the restart ends the caution')
check(lastState.flag == 'green', 'and goes green')
check(chatHas('RESTART'), 'the field is told the race is on again')
check(chatHas('under caution'), 'and how many laps were run under it')

seconds(0.5)
check(order() == '3,1,2',
  'and the live order resumes: Cara is where she actually is now (got '
    .. order() .. ')')
check(driver(3).position == 1, 'leading, because the freeze is over and not undone')

RM_onRestart(0)
check(lastState.caution == false, 'restarting a race that is not under caution is a no-op')

-- ---------------------------------------------------------------------------
-- The manual green IS the restart
-- ---------------------------------------------------------------------------
-- The Green flag button and the Restart button must leave identical state. A
-- green that only changed the flag would go racing with the order still frozen,
-- and the board would sit on a stale classification with nothing left to
-- unfreeze it.
RM_onCaution(0)
check(lastState.caution == true, 'under caution again')
chatClear()
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.caution == false, 'a green called from the flag buttons ends the caution')
check(lastState.flag == 'green', 'and the flag follows')
check(chatHas('RESTART'), 'through the same path, so the two leave identical state')

-- A yellow called from the flag buttons is NOT a caution: it is the local
-- advisory flag the mod has always had, and it freezes nothing.
RM_onSetFlag(0, '{"flag":"yellow"}')
check(lastState.flag == 'yellow', 'the advisory yellow still works')
check(lastState.caution == false,
  'and is not a full-course caution: the flag button and the caution are '
    .. 'different instruments, and only one of them freezes the board')
RM_onSetFlag(0, '{"flag":"green"}')

-- ---------------------------------------------------------------------------
-- A red flag does not lift the caution
-- ---------------------------------------------------------------------------
RM_onCaution(0)
RM_onSetFlag(0, '{"flag":"red"}')
check(lastState.flag == 'red', 'a red can be thrown during a caution')
check(lastState.caution == true, 'and the caution survives it: red goes to yellow, then green')
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.caution == false, 'and the green out of it is still the restart')

-- ---------------------------------------------------------------------------
-- A frozen order must never outlive its session
-- ---------------------------------------------------------------------------
-- The failure this guards is invisible until somebody wins a race they ran
-- fourth in: a cautionPos left standing is the FIRST thing the comparator reads,
-- so it would silently order the next race from the last one's caution.
RM_onCaution(0)
check(lastState.caution == true, 'under caution when the session ends')
RM_onEndRace(0)
check(lastState.caution == false, 'ending the session drops the caution')

RM_onResetLeaderboard(0)
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":20}')
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
-- Cara leads this race outright. If a frozen position had survived, she would
-- be sorted behind the drivers who were ahead of her in the last one.
lap(3); lap(3); lap(3)
report(3, 4, 1, 10.0)
report(1, 1, 1, 900.0)
report(2, 1, 1, 900.0)
seconds(0.5)
check(lastState.caution == false, 'the new race is green')
check(order() == '3,1,2',
  'and is ordered on its own merits: no frozen position survived the last one '
    .. '(got ' .. order() .. ')')

-- ...and the same across a Reset Session rather than an End Session.
RM_onCaution(0)
RM_onResetLeaderboard(0)
check(lastState.caution == false, 'Reset Session drops a running caution too')

-- ---------------------------------------------------------------------------
-- Qualifying has no running order to freeze
-- ---------------------------------------------------------------------------
-- Drivers are on their own laps and the board is a list of best times, so there
-- is no order a caution could hold -- and freezing one would be freezing the
-- wrong thing entirely.
RM_onSetSpectating(0, '{"spectating":true}')
RM_onStartQualifying(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'qualifying', 'qualifying is running')
chatClear()
RM_onCaution(0)
check(lastState.caution ~= true, 'a caution is refused in qualifying')
check(chatHas('no running order to freeze'), 'and says why rather than doing nothing')
RM_onEndRace(0)

-- ---------------------------------------------------------------------------
-- A caution during the pace lap is refused
-- ---------------------------------------------------------------------------
-- The pace lap is already a neutralised field with a green still to come, which
-- is what a caution would be asking for. Accepting it would freeze an order
-- nobody is racing for and leave the admin two things to cancel before the race
-- could start.
RM_onResetLeaderboard(0)
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetPaceLap(0, '{"enabled":true}')
RM_onSetTotalLaps(0, '{"laps":5}')
RM_onGenerateGrid(0)
RM_onStartRace(0)
check(lastState.pacing == true, 'the field is on the pace lap')
chatClear()
RM_onCaution(0)
check(lastState.caution ~= true, 'a caution during the pace lap is refused')
check(chatHas('already under yellow on the pace lap'), 'and says so')
check(lastState.pacing == true, 'and the pace lap is undisturbed')

if fails == 0 then
  print(string.format('caution_test: %d checks, 0 failures', checks))
else
  print(string.format('caution_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
