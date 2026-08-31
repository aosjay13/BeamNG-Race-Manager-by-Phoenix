-- Headless test for THE CAUTION and THE RESTART in server/RaceManager/main.lua.
--
-- A full-course yellow called mid-race, and one thing about it is the whole
-- feature: IT FREEZES THE RUNNING ORDER.
--
-- That is the only half of a real caution this plugin can enforce. The server
-- has no physics -- it cannot slow a car, close a gap or line a field up behind
-- the leader. What it can do is stop positions changing, which is exactly what a
-- real caution does to the timing sheet and is a scoring rule rather than a
-- movement one.
--
-- WHEN it stops them is the part this file is really about, and it is not when
-- the button is pressed. THE FIELD RACES BACK TO THE LINE:
--
--   * calling the caution sets a PENDING yellow. Nothing is frozen and the
--     board goes on re-sorting, because on the road the race is still on.
--   * THE LEADER DICTATES THE LAP. Their crossing makes the caution official
--     and names the lap it was called on.
--   * every other driver locks their own place as they complete THAT lap. First
--     back to the line is first, which is what racing back to it pays.
--   * a car a lap or more down sorts BELOW the whole lead lap, in the order the
--     lapped cars came back -- wherever they happen to be on the road.
--   * the highest-placed lapped car may take its lap back before the green (the
--     free pass, off unless a league asks for it).
--
-- The restart is the same shape: an admin CALLS one, the leader's return to the
-- line drops the green, and it can be waved off until it falls.
--
-- The way this file tests a freeze is to make the field OVERTAKE under it and
-- then assert the board did not move. A test that only checked the flag colour
-- would pass against a caution that froze nothing at all.
--
-- The other thing worth a file of its own: a frozen order must never outlive the
-- caution that set it. A cautionPos left standing after a session would silently
-- order the NEXT race, which is invisible until somebody wins a race they were
-- fourth in.
--
-- Run from the repo root: lua5.3 tests/caution_test.lua

local connected = { [0] = 'Admin', [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
local lastState = nil
local chatLog   = {}
local timers    = {}
local lapCredits = {}     -- [pid] = the lap the server credited

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
    -- The free pass credits a lap the driver never crossed for, and the CLIENT
    -- has to be told: its own lap counter stamps every progress report and the
    -- server drops any whose number disagrees with its own.
    if event == 'RM_LapCredit' then lapCredits[target] = payload.lap end
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
check(lastState.cautionPending ~= true, 'and does not even leave one pending')

-- ---------------------------------------------------------------------------
-- Build a running order, with one car a lap down
-- ---------------------------------------------------------------------------
-- Alice, Bob and Cara on the lead lap; Dan a lap down. The ordinary comparator,
-- with nothing frozen yet: laps, then checkpoints, then distance.
lap(1); lap(2); lap(3); lap(4)  -- everyone onto lap 2
lap(1); lap(2); lap(3)          -- the three lead-lap cars onto lap 3; Dan stays
report(1, 3, 2, 100.0)
report(2, 3, 1, 50.0)
report(3, 3, 1, 300.0)
report(4, 2, 1, 50.0)
seconds(0.5)
check(order() == '1,2,3,4',
  'the live order is Alice, Bob, Cara, and Dan a lap down (got ' .. order() .. ')')

-- ---------------------------------------------------------------------------
-- CALLING the caution freezes NOTHING. The field races back to the line.
-- ---------------------------------------------------------------------------
chatClear()
RM_onCaution(0)
check(lastState.cautionPending == true, 'the caution is called')
check(lastState.caution == false,
  'and is NOT yet official: nothing is frozen until the leader takes the line')
check(lastState.flag == 'yellow', 'the yellow is already flying')
check(chatHas('RACE BACK TO THE LINE'), 'and that is the instruction, said out loud')
check(chatHas('leader decides which lap'),
  'the field is told whose crossing settles it')

-- THE BOARD IS STILL LIVE, and this is the whole difference from a snapshot
-- taken at the button. Cara passes Alice on the way back to the line and the
-- board must show it: on the road, that place is hers.
report(3, 3, 2, 10.0)
seconds(0.5)
check(order() == '3,1,2,4',
  'the order still moves while the field races back (got ' .. order() .. ')')

-- A second caution while one is pending is refused rather than restacked.
chatClear()
RM_onCaution(0)
check(chatHas('already under caution'), 'a second caution is refused, and says so')

-- A restart cannot be called before there is a caution to restart out of.
chatClear()
RM_onRestart(0)
check(lastState.restartPending ~= true, 'no restart while the field is still racing back')
check(chatHas('still racing back to the line'), 'and it says which half of the caution it is in')

-- ---------------------------------------------------------------------------
-- THE LEADER MAKES IT OFFICIAL, and names the lap
-- ---------------------------------------------------------------------------
chatClear()
lap(3)                          -- Cara, leading, takes the line
check(lastState.caution == true, 'the leader crossing makes the caution official')
check(lastState.cautionPending == false, 'and it is no longer pending')
check(lastState.cautionLaps == 0, 'no laps run under it yet')
check(chatHas('CAUTION IS OUT on lap 3'),
  'the announcement names the lap the leader was on, so a marshal can place it later')
check(driver(3).cautionDown == 0, 'the leader is on the lead lap by definition')

-- ---------------------------------------------------------------------------
-- LAPPED CARS GO TO THE BOTTOM, whatever order they come back in
-- ---------------------------------------------------------------------------
-- Dan is a lap down and takes the line BEFORE the two lead-lap cars behind
-- Cara. He is still classified last: a car a lap down is behind the whole lead
-- lap, which is how a caution board reads everywhere. Locking purely on the
-- order cars arrived would have put him second.
lap(4)                          -- Dan, a lap down, back to the line first
lap(1)                          -- Alice
lap(2)                          -- Bob
seconds(0.5)
check(driver(4).cautionDown == 1, 'Dan locked a lap down')
check(driver(1).cautionDown == 0 and driver(2).cautionDown == 0,
  'and the two behind Cara locked on the lead lap')
check(order() == '3,1,2,4',
  'so the board is Cara, Alice, Bob, then the lapped car last -- even though '
    .. 'Dan came back to the line before either of them (got ' .. order() .. ')')

-- ---------------------------------------------------------------------------
-- THE FREEZE: overtake under the caution and the board does not move
-- ---------------------------------------------------------------------------
-- This is the check the whole file exists for. Dan passes the entire field on
-- every metric the live comparator uses -- more laps, more checkpoints, less
-- distance to the next gate -- and the board must not move a place.
lap(4); lap(4)                  -- Dan now leads on raw laps outright
report(4, 5, 9, 1.0)
report(3, 4, 1, 900.0)
report(1, 4, 1, 900.0)
report(2, 4, 1, 900.0)
seconds(0.5)
check(order() == '3,1,2,4',
  'the order is FROZEN: Dan passing the whole field under the caution changes '
    .. 'nothing on the board (got ' .. order() .. ')')
check(driver(4).position == 4, 'Dan is still classified last')
check(driver(4).currentLap > driver(3).currentLap,
  'even though he is genuinely up the road, which is what the caution told him to do')

-- Caution laps are counted off the leader's crossing, and they count toward the
-- distance: the race does not get longer because it was neutralised.
check(lastState.cautionLaps > 0, 'laps run under the caution are counted')
local underCaution = lastState.cautionLaps

chatClear()
RM_onCaution(0)
check(chatHas('already under caution'), 'a second caution is still refused')
check(lastState.cautionLaps == underCaution, 'and does not reset the lap count')

-- ---------------------------------------------------------------------------
-- The restart is CALLED, and the leader takes it
-- ---------------------------------------------------------------------------
chatClear()
RM_onRestart(3)
check(lastState.restartPending ~= true, 'calling a restart requires authentication')

RM_onRestart(0)
check(lastState.restartPending == true, 'the restart is called')
check(lastState.caution == true,
  'and the race is STILL under caution: calling one is not taking one')
check(lastState.flag == 'yellow', 'the yellow is still out')
check(chatHas('RESTART THIS LAP'), 'the field is warned')
check(chatHas('as the leader reaches'), 'and told what drops the green')
seconds(0.5)
check(order() == '3,1,2,4',
  'the board stays frozen while the restart is waited on (got ' .. order() .. ')')

-- A second call is refused rather than re-announced.
chatClear()
RM_onRestart(0)
check(chatHas('already called'), 'a second restart call is refused')

-- ---------------------------------------------------------------------------
-- ...and it can be waved off
-- ---------------------------------------------------------------------------
-- A marshal who calls a restart and then sees the track is not clear after all
-- needs the call back. Pressing Caution again would count a second yellow and
-- re-freeze an order that never thawed, so the wave-off is its own control.
chatClear()
RM_onCancelRestart(3)
check(lastState.restartPending == true, 'waving a restart off requires authentication')

RM_onCancelRestart(0)
check(lastState.restartPending == false, 'the restart is waved off')
check(lastState.caution == true, 'and ONLY the call goes: the race stays neutralised')
check(lastState.flag == 'yellow', 'still under the yellow')
check(chatHas('WAVED OFF'), 'and the field is told')
seconds(0.5)
check(order() == '3,1,2,4', 'the board is still frozen (got ' .. order() .. ')')

chatClear()
RM_onCancelRestart(0)
check(chatHas('nothing'), 'waving off a restart nobody called is a no-op that says so')

-- ---------------------------------------------------------------------------
-- The leader's crossing is the backstop that drops the green
-- ---------------------------------------------------------------------------
-- restartWatch normally greens the field about ten meters before the line, but
-- it needs race.slotCount (0 for a route built in the editor and never saved)
-- and it needs telemetry to have landed near the line. Neither is guaranteed,
-- and a restart that was called and never fell would leave the field circulating
-- under a yellow forever.
chatClear()
RM_onRestart(0)
check(lastState.restartPending == true, 'called again')
lap(3)                          -- the frozen leader takes the line
check(lastState.caution == false, 'the leader crossing drops the green')
check(lastState.restartPending == false, 'and clears the call with it')
check(lastState.flag == 'green', 'the flag follows')
check(chatHas('RESTART'), 'the field is told the race is on again')
check(chatHas('under caution'), 'and how many laps were run under it')

seconds(0.5)
check(order() == '4,3,1,2',
  'and the live order resumes: Dan is where he actually is now (got '
    .. order() .. ')')
check(driver(4).position == 1, 'leading, because the freeze is over and not undone')
check(driver(4).cautionDown == nil, 'and the caution stamps are cleared, not kept')

chatClear()
RM_onRestart(0)
check(lastState.caution == false, 'restarting a race that is not under caution is a no-op')
check(chatHas('nothing to restart'), 'and says so')

-- ---------------------------------------------------------------------------
-- The manual green IS the restart
-- ---------------------------------------------------------------------------
-- The panel no longer offers a plain green during a race -- Restart is its own
-- button -- but the path is kept, because a green called by hand must never
-- leave the race running with the order still frozen and nothing to unfreeze it.
RM_onCaution(0)
lap(4)                          -- the leader makes it official
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
-- Red is a condition laid over the session, not a state change. A race that was
-- neutralised before the red is still neutralised after it, so LIFTING the red
-- returns the field to its yellow rather than waving them off the instant the
-- wreck was moved.
RM_onCaution(0)
lap(4)
check(lastState.caution == true, 'under caution')
RM_onSetFlag(0, '{"flag":"red"}')
check(lastState.flag == 'red', 'a red can be thrown during a caution')
check(lastState.caution == true, 'and the caution survives it')
chatClear()
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.flag == 'yellow', 'lifting the red goes back to the YELLOW, not to green')
check(lastState.caution == true, 'because the race is still neutralised')
check(chatHas('STILL'), 'and the field is told exactly that')
-- ...AND A RED HOLDS THE RESTART, on both paths that drop the green. Red means
-- stop where you are, so a leader who rolls the last few meters to the line
-- under one must not restart the race by arriving.
RM_onSetFlag(0, '{"flag":"red"}')
RM_onRestart(0)
check(lastState.restartPending == true, 'a restart can be called under a red')
lap(4)
check(lastState.caution == true,
  'but the leader taking the line under a red does NOT drop the green')
check(lastState.flag == 'red', 'the red is still out')
check(lastState.restartPending == true, 'and the call is still standing')
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.flag == 'yellow', 'lifting the red goes back to the caution')
lap(4)
check(lastState.caution == false, 'and the restart out of it is the way back to green')

-- ---------------------------------------------------------------------------
-- A frozen order must never outlive its session
-- ---------------------------------------------------------------------------
-- The failure this guards is invisible until somebody wins a race they ran
-- fourth in: a cautionPos left standing is the FIRST thing the comparator reads,
-- so it would silently order the next race from the last one's caution.
RM_onCaution(0)
lap(4)
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
report(4, 1, 1, 900.0)
seconds(0.5)
check(lastState.caution == false, 'the new race is green')
check(lastState.cautionPending == false, 'and no pending call survived either')
check(order():sub(1, 1) == '3',
  'and is ordered on its own merits: no frozen position survived the last one '
    .. '(got ' .. order() .. ')')

-- ...and the same across a Reset Session rather than an End Session.
RM_onCaution(0)
RM_onResetLeaderboard(0)
check(lastState.caution == false, 'Reset Session drops a running caution too')
check(lastState.cautionPending == false, 'and a pending one')

-- ---------------------------------------------------------------------------
-- THE FREE PASS, and the green that falls at the line
-- ---------------------------------------------------------------------------
-- Two things need a track with a known length: the free pass wants a full lock
-- of the field, and restartWatch cannot judge "approaching the line" without
-- knowing which checkpoint IS the line. A saved layout gives race.slotCount.
local cps = '[{"x":0,"y":0,"z":0,"hx":0,"hy":1},'
  .. '{"x":100,"y":0,"z":0,"hx":1,"hy":0},'
  .. '{"x":100,"y":100,"z":0,"hx":0,"hy":-1}]'
RM_onSaveLayout(0, '{"name":"Oval","width":20,"checkpoints":' .. cps .. '}')
RM_onLoadLayout(0, '{"name":"Oval"}')

RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":20}')
check(lastState.luckyDog == false, 'the free pass is OFF by default: a league opts into it')
RM_onSetLuckyDog(0, '{"enabled":true}')
check(lastState.luckyDog == true, 'and an admin can arm it')

RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
-- Alice, Bob and Cara on the lead lap; Dan one down.
lap(1); lap(2); lap(3); lap(4)
lap(1); lap(2); lap(3)
report(1, 3, 1, 10.0)
report(2, 3, 1, 20.0)
report(3, 3, 1, 30.0)
report(4, 2, 1, 40.0)
seconds(0.5)

chatClear()
lapCredits = {}
RM_onCaution(0)
lap(1)                          -- Alice leads it away, caution official on lap 3
lap(2); lap(3)                  -- the rest of the lead lap locks
check(lapCredits[4] == nil, 'no free pass while a car is still racing back to the line')
lap(4)                          -- and the last car home closes the field
check(lastState.cautionLucky == 4, 'the free pass goes to the highest-placed lapped car')
check(chatHas('FREE PASS'), 'and the whole field is told')
check(driver(4).cautionDown == 0, 'Dan is back on the lead lap')
check(lapCredits[4] == driver(4).currentLap,
  'and the CLIENT is told the lap it now owns, or its telemetry would be dropped '
    .. 'for the rest of the race')
seconds(0.5)
check(order() == '1,2,3,4',
  'he restarts at the TAIL of the lead lap, not in the place he left (got '
    .. order() .. ')')

-- One per caution, and not one per crossing.
local luckyLap = driver(4).currentLap
lap(1); lap(4)
check(driver(4).currentLap == luckyLap + 1,
  'the pass is worth exactly one lap: further crossings count normally')

-- ---------------------------------------------------------------------------
-- The green falls AS THE LEADER REACHES THE LINE
-- ---------------------------------------------------------------------------
-- Not when the button was pressed. The field is packed up and looking at the
-- line when it goes green, rather than being waved off round the back of the
-- circuit at whatever moment the marshal happened to decide.
chatClear()
RM_onRestart(0)
check(lastState.restartPending == true, 'the restart is called')
-- The leader is mid-lap: past the first gate, nowhere near the line.
report(1, driver(1).currentLap, 1, 8.0)
seconds(0.5)
check(lastState.caution == true,
  'and does NOT fall on a leader who is close to some other checkpoint')
-- ...now on the last leg, inside the trigger.
report(1, driver(1).currentLap, 2, 8.0)
seconds(0.5)
check(lastState.caution == false, 'the green falls as the leader reaches the LINE')
check(lastState.flag == 'green', 'and the flag follows')
check(lastState.restartPending == false, 'the call is spent')

-- ---------------------------------------------------------------------------
-- Qualifying has no running order to freeze
-- ---------------------------------------------------------------------------
-- Drivers are on their own laps and the board is a list of best times, so there
-- is no order a caution could hold -- and freezing one would be freezing the
-- wrong thing entirely.
RM_onEndRace(0)
RM_onResetLeaderboard(0)
RM_onSetSpectating(0, '{"spectating":true}')
RM_onStartQualifying(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'qualifying', 'qualifying is running')
chatClear()
RM_onCaution(0)
check(lastState.caution ~= true, 'a caution is refused in qualifying')
check(lastState.cautionPending ~= true, 'not even a pending one')
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
check(lastState.cautionPending ~= true, 'and leaves nothing pending')
check(chatHas('already under yellow on the pace lap'), 'and says so')
check(lastState.pacing == true, 'and the pace lap is undisturbed')

if fails == 0 then
  print(string.format('caution_test: %d checks, 0 failures', checks))
else
  print(string.format('caution_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
