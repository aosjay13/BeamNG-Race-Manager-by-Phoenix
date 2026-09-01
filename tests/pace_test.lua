-- Headless test for THE PACE LAP in server/RaceManager/main.lua.
--
-- A race started behind a pace car instead of from the lights: the field is
-- released under yellow with no countdown, forms up for a lap, and the green
-- falls as the leader comes back to the start/finish line.
--
-- Three things in it are worth a file of their own, and each is a different
-- kind of wrong if it breaks:
--
--   THE ARMING LATCH. The field starts the pace lap STANDING AT THE LINE, so
--   "the leader is within ten meters of the line" is true at the release as
--   well as at the end of the lap. Without the latch the green falls on the
--   tick the cars are let go and there is no pace lap at all -- and it would
--   look exactly like a working feature to anyone testing with one car parked
--   halfway round the circuit.
--
--   THE DISTANCE. A formation lap is not a racing lap, so it goes ON TOP of the
--   distance: five laps behind the pace car is six crossings. This is the one
--   place the pace lap differs from the out lap a head-on grid owes, which is a
--   racing lap that merely sets no time -- and getting the two confused costs
--   the field a lap in one direction or the other.
--
--   THE CLOCK. race.time runs from the release (ghost end times are expressed
--   on it, so it cannot be wound back), but a TIMED race must not have its
--   clock eaten by the formation lap. Ninety seconds of forming up must leave
--   ten minutes of racing.
--
-- Run from the repo root: lua5.3 tests/pace_test.lua

local connected = { [0] = 'Admin', [1] = 'Leader', [2] = 'Second', [3] = 'Third' }
local lastState = nil
local lastChat  = nil
local chatLog   = {}
local timers    = {}

local notices = {}
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
    if event == 'RM_Update' then lastState = payload end
    -- THE FIELD'S OWN CHANNEL. A regular client has no multiplayer chat app, so
    -- an instruction to whoever is driving goes here rather than to chat, and a
    -- test that only watched chat would read as though the message had been
    -- deleted rather than moved.
    if event == 'RM_Notice' then notices[#notices + 1] = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  RemoveVehicle = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/gridmap_v2/info.json' end,
}

-- What the FIELD was told, headline and sub-line searched as one string: a
-- message split across the two is still one sentence to the driver reading it.
local function noticeHas(text)
  for _, n in ipairs(notices) do
    local whole = tostring(n.msg or '') .. ' ' .. tostring(n.sub or '')
    if whole:find(text, 1, true) then return true end
  end
  return false
end
local function noticeClear() notices = {} end

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
-- One tick is CFG.tickMs (100 ms), so this is seconds.
local function seconds(n)
  for _ = 1, math.floor(n * 10) do RM_Tick() end
end
local function lap(pid) RM_onLap(pid, '{"lapTime":60.0}') end
-- Where a driver reports itself to be. During the pace lap every car is on its
-- out lap, so `dist` is meters to the START/FINISH LINE rather than to the next
-- checkpoint -- which is exactly the number the green flag is waved off.
local function report(pid, lapNum, cp, dist)
  RM_onProgress(pid, string.format('{"lap":%d,"cp":%d,"dist":%.1f}', lapNum, cp, dist))
end
-- Put the whole field the same distance out, in order.
local function fieldAt(dist)
  report(1, 1, 1, dist)
  report(2, 1, 1, dist + 20)
  report(3, 1, 1, dist + 40)
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
-- The admin runs the session rather than driving it, so the leader is
-- unambiguous and the field under test is three cars.
RM_onSetSpectating(0, '{"spectating":true}')

-- ---------------------------------------------------------------------------
-- The setting
-- ---------------------------------------------------------------------------
check(lastState.paceLap == false, 'a server nobody has configured runs no pace lap')

RM_onSetPaceLap(3, '{"enabled":true}')
check(lastState.paceLap == false, 'arming the pace lap requires authentication')

RM_onSetPaceLap(0, '{"enabled":true}')
check(lastState.paceLap == true, 'an admin can arm the pace lap')
RM_onSetPaceLap(0, '{"enabled":false}')
check(lastState.paceLap == false, 'and disarm it again')
RM_onSetPaceLap(0, '{"enabled":true}')

-- A SPRINT STAGE IS REFUSED, and told why. It is driven once from the first
-- gate to the last, so there is no lap to form up on -- and accepting the switch
-- and quietly ignoring it would leave an admin looking at a Start Race button
-- that had gone back to Start Countdown with nothing saying so.
RM_onSetPaceLap(0, '{"enabled":false}')
RM_onSetPointToPoint(0, '{"enabled":true}')
chatClear()
RM_onSetPaceLap(0, '{"enabled":true}')
check(lastState.paceLap == false, 'the pace lap is refused on a point-to-point stage')
check(chatHas('sprint stage'), 'and the admin is told why rather than left guessing')

-- ...and a track switched to a sprint stage UNDER an armed pace lap turns it
-- off, for the same reason: what would be left is a switch reading ENABLED above
-- a button that has silently changed.
RM_onSetPointToPoint(0, '{"enabled":false}')
RM_onSetPaceLap(0, '{"enabled":true}')
check(lastState.paceLap == true, 'armed again on a circuit')
chatClear()
RM_onSetPointToPoint(0, '{"enabled":true}')
check(lastState.paceLap == false, 'switching the track to a sprint stage disarms it')
check(chatHas('Pace lap switched off'), 'and says so, rather than leaving a dead switch')
RM_onSetPointToPoint(0, '{"enabled":false}')

-- ---------------------------------------------------------------------------
-- Start Race and Start Countdown are alternatives, not a sequence
-- ---------------------------------------------------------------------------
RM_onSetPaceLap(0, '{"enabled":false}')
RM_onSetTotalLaps(0, '{"laps":3}')
RM_onGenerateGrid(0)
check(lastState.phase == 'grid', 'the grid forms')

chatClear()
RM_onStartRace(0)
check(lastState.phase == 'grid',
  'Start Race is refused with the pace lap disarmed: it would release the field '
    .. 'with no countdown, no yellow and no green to come')
check(chatHas('pace lap is not armed'), 'and the admin is told which button to use')

RM_onStartRace(3)
check(lastState.phase == 'grid', 'and it requires authentication')

-- ---------------------------------------------------------------------------
-- The release: under yellow, with no countdown at all
-- ---------------------------------------------------------------------------
RM_onEndRace(0)                     -- stand the grid down
RM_onSetPaceLap(0, '{"enabled":true}')
RM_onGenerateGrid(0)
chatClear()
RM_onStartRace(0)

check(lastState.phase == 'racing', 'Start Race releases the field immediately')
check(timers['RM_CountdownTick'] ~= true, 'with no countdown timer running')
check(lastState.pacing == true, 'the field is on the pace lap')
check(lastState.flag == 'yellow', 'released under yellow, which is what a formation lap is')
check(noticeHas('PACE LAP'), 'and the field is told, on the channel a driver can read')
check(noticeHas('40 mph'), 'in miles per hour...')
check(noticeHas('64 km/h'), '...and in km/h, because the grid is not all in one country')
check(noticeHas('GREEN FLAG falls as the leader'), 'and told what ends it')
check(driver(1).status == 'racing', 'the drivers are racing-status: gates armed, laps reported')
check(driver(1).currentLap == 1, 'everyone is on lap 1')
check(driver(1).outLap == true,
  'and owes an out lap: a formation lap is a lap that is driven and not scored, '
    .. 'which is a rule this plugin already had')

-- THE DISTANCE. A three lap race behind the pace car is FOUR crossings.
check(lastState.totalLaps == 3, 'the lap setting is still three')

-- ---------------------------------------------------------------------------
-- The release happens BEFORE any client has reported where it is
-- ---------------------------------------------------------------------------
-- The field is let go and telemetry starts arriving a fraction of a second
-- later, so for the first few ticks not one driver has a reported distance. A
-- leader search that skipped those drivers finds nobody -- which reads as "the
-- whole field has crossed the line" and answers with an instant green. No pace
-- lap at all, and it would look like a working feature to anyone who tested
-- with a car already circulating.
seconds(1)
check(lastState.pacing == true,
  'the pace lap survives the ticks before any client has reported a position')
check(lastState.flag == 'yellow', 'still yellow, with no telemetry in yet')

-- ---------------------------------------------------------------------------
-- The arming latch: the green does not fall at the release
-- ---------------------------------------------------------------------------
-- Every car is standing on the grid, at the line. This is the state that fires
-- the trigger if the latch is missing, and it is the whole reason for the latch.
fieldAt(2.0)
seconds(1)
check(lastState.pacing == true,
  'the green does NOT fall at the release, with the whole field sitting on the '
    .. 'line -- the trigger arms only once the leader has got away from it')
check(lastState.flag == 'yellow', 'the field is still under yellow')

-- Creeping forward is not a pace lap either. Still inside the arming distance.
fieldAt(30.0)
seconds(1)
check(lastState.pacing == true, 'nor after a creep that never leaves the line area')

-- Away. The latch trips, and from here coming back to the line means something.
fieldAt(400.0)
seconds(1)
check(lastState.pacing == true, 'the field is round the back of the circuit, still pacing')

-- Halfway back. Inside the arming distance again but nowhere near the trigger.
fieldAt(120.0)
seconds(1)
check(lastState.pacing == true, 'and on the way back, with the line still 120m off')

-- ---------------------------------------------------------------------------
-- The green flag
-- ---------------------------------------------------------------------------
chatClear()
report(1, 1, 1, 8.0)      -- the leader is inside ten meters
report(2, 1, 1, 45.0)     -- the field behind is not, and does not need to be
report(3, 1, 1, 80.0)
seconds(0.5)
check(lastState.pacing == false, 'the green falls as the LEADER reaches the line')
check(lastState.flag == 'green', 'and the flag goes green')
check(noticeHas('GREEN FLAG'), 'the field is told the race is on')
check(driver(2).status == 'racing' and driver(3).status == 'racing',
  'including the cars still strung out behind: the green is one event for '
    .. 'everybody, and each driver still starts their own lap 1 at the line')
check(driver(1).outLap == true,
  'the leader has not crossed yet, so they still owe the crossing that starts lap 1')

-- ---------------------------------------------------------------------------
-- The formation lap is given away, and the distance is intact
-- ---------------------------------------------------------------------------
chatClear()
lap(1)
check(driver(1).outLap == false, 'the crossing ends the leader\'s pace lap')
check(driver(1).currentLap == 2, 'and starts their lap 1 of three')
check(chatHas('Pace lap complete'),
  'said as what it is: a driver who has just followed the field round under '
    .. 'yellow needs to hear that the lap they are STARTING is lap 1')
check(lastState.bestLapTime == nil,
  'and the formation lap sets no fastest lap: it was not raced')

lap(2); lap(3)
check(driver(1).status == 'racing', 'nobody has finished after one crossing')

-- Three racing laps, which is four crossings in total.
for _ = 1, 2 do lap(1); lap(2); lap(3) end
check(driver(1).status == 'racing',
  'still racing after three crossings: the formation lap was not one of the three')
lap(1)
check(driver(1).status == 'finished',
  'the fourth crossing is the finish -- three racing laps behind a pace lap')
check(driver(1).currentLap == 4, 'having completed four crossings for a three lap race')
lap(2); lap(3)

-- ---------------------------------------------------------------------------
-- The results file says the Laps column will read one higher
-- ---------------------------------------------------------------------------
-- Without this the header and the table disagree: "Race distance: 3 laps" above
-- a 4 in the Laps column of every finisher, months later, read by somebody who
-- was not there. Exactly the discrepancy the qualifying Format line already
-- spells its own out lap out to avoid.
--
-- And it cannot be inferred from the out-lap flag alone: a head-on grid's out
-- lap comes OUT of the distance, a formation lap goes ON TOP of it.
seconds(6)                            -- past the end-of-race hold (endDelay)
local resultsPath = lastChat and lastChat:match('(Resources/[%w%-_%./]+%.txt)')
check(resultsPath ~= nil, 'the finished race writes a results file')
local rf = resultsPath and io.open(resultsPath, 'r')
check(rf ~= nil, 'and it is on disk')
local resultsText = rf and rf:read('*a') or ''
if rf then rf:close() end
check(resultsText:find('Race distance: 3 laps + pace lap', 1, true) ~= nil,
  'whose header names the pace lap, so the distance and the Laps column agree')
check(resultsText:find('Laps column reads one higher', 1, true) ~= nil,
  'and says which way the discrepancy runs')

-- ---------------------------------------------------------------------------
-- A red flag holds the green
-- ---------------------------------------------------------------------------
-- Red means stop where you are and wait. A leader who coasts the last few
-- meters to the line under one must not start the race by arriving there.
RM_onResetLeaderboard(0)
RM_onSetPaceLap(0, '{"enabled":true}')
RM_onSetTotalLaps(0, '{"laps":3}')
RM_onSetSpectating(0, '{"spectating":true}')
RM_onGenerateGrid(0)
RM_onStartRace(0)
fieldAt(400.0)
seconds(1)                                   -- latch armed
RM_onSetFlag(0, '{"flag":"red"}')
check(lastState.flag == 'red', 'the admin throws a red during the pace lap')
check(lastState.pacing == true, 'which does not end the pace lap')
fieldAt(3.0)                                 -- the leader rolls up to the line
seconds(1)
check(lastState.pacing == true,
  'and the leader arriving at the line under a red does NOT start the race')
check(lastState.flag == 'red', 'the red is still out')

-- LIFTING A RED IS NOT A GREEN. Red is a condition laid over the session rather
-- than a state change, so whatever the field was under before the stoppage it is
-- still under afterwards: the formation lap goes back to forming up. Waving the
-- field off in the same keystroke that moved the wreck is the opposite of what
-- red means, and the panel offers this as one lit button that lifts what it
-- threw -- so the green it sends must not end the pace lap.
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.pacing == true, 'lifting the red does NOT end the pace lap')
check(lastState.flag == 'yellow', 'it goes back to the yellow the field was under')

-- ...and the same by the older route, in the sequence an admin already knows:
-- red, yellow, green. The yellow leaves the pace lap running...
RM_onSetFlag(0, '{"flag":"red"}')
RM_onSetFlag(0, '{"flag":"yellow"}')
check(lastState.pacing == true, 'going back to yellow resumes the pace lap')
-- ...and with the leader already inside the trigger, the next tick greens it.
seconds(0.5)
check(lastState.pacing == false, 'and the leader is at the line, so the green falls')

-- ---------------------------------------------------------------------------
-- The manual green: the marshal's override, and why no timeout is needed
-- ---------------------------------------------------------------------------
-- A field that has crashed, spun or simply stopped never brings its leader back
-- to the line. Rather than guess how long a formation lap may take, the person
-- who can see the track calls the green with the button they would use for any
-- other one.
RM_onResetLeaderboard(0)
RM_onSetPaceLap(0, '{"enabled":true}')
RM_onSetTotalLaps(0, '{"laps":3}')
RM_onSetSpectating(0, '{"spectating":true}')
RM_onGenerateGrid(0)
RM_onStartRace(0)
check(lastState.pacing == true, 'a second race starts behind the pace car')
check(lastState.flag == 'yellow', 'under yellow, with nothing carried over from the first')

fieldAt(300.0)
seconds(1)
chatClear()
RM_onSetFlag(0, '{"flag":"green"}')
check(lastState.pacing == false, 'a manual green ends the pace lap')
check(lastState.flag == 'green', 'and the flag follows')
check(noticeHas('pace lap is over'),
  'through the same path the automatic green takes, so the two leave identical state')

-- ---------------------------------------------------------------------------
-- Nobody left on the pace lap
-- ---------------------------------------------------------------------------
-- The other way a pace lap can never end on its own: the field crosses the line
-- (a head-on grid does this, ending the out lap short) or simply stops
-- circulating. Holding the yellow then would leave a race running under a
-- caution nothing could lift.
RM_onResetLeaderboard(0)
RM_onSetPaceLap(0, '{"enabled":true}')
RM_onSetSpectating(0, '{"spectating":true}')
RM_onGenerateGrid(0)
RM_onStartRace(0)
check(lastState.pacing == true, 'pacing')
lap(1); lap(2); lap(3)          -- the whole field ends its out lap
seconds(0.5)
check(lastState.pacing == false,
  'with nobody left on the pace lap the green falls: a yellow nothing can lift '
    .. 'is worse than an early green')

-- ---------------------------------------------------------------------------
-- A TIMED race: the formation lap does not eat the clock
-- ---------------------------------------------------------------------------
RM_onResetLeaderboard(0)
RM_onSetPaceLap(0, '{"enabled":true}')
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetRaceLimits(0, '{"laps":25,"seconds":600,"mode":"timed"}')
RM_onGenerateGrid(0)
RM_onStartRace(0)
check(lastState.pacing == true, 'a timed race can start behind the pace car too')

-- Ninety seconds of forming up.
fieldAt(400.0)
seconds(90)
check(lastState.pacing == true, 'still forming up after ninety seconds')
check(lastState.raceLeft ~= nil and lastState.raceLeft > 599,
  'and the clock the header counts down has not started: it reads '
    .. tostring(lastState.raceLeft) .. ' of 600')
check(lastState.raceTime > 89,
  'while the SESSION clock has run the whole time -- ghost end times are '
    .. 'expressed on it, so it is never wound back')

report(1, 1, 1, 5.0)
seconds(0.5)
check(lastState.pacing == false, 'the green falls')
check(lastState.raceLeft ~= nil and lastState.raceLeft > 599,
  'and the ten minutes start HERE, not ninety seconds ago')

seconds(300)
check(lastState.raceExpired ~= true, 'five minutes in, the clock has not expired')
check(lastState.raceLeft < 301 and lastState.raceLeft > 299,
  'and the countdown reads about five minutes left (got '
    .. tostring(lastState.raceLeft) .. ')')

seconds(305)
check(lastState.raceExpired == true,
  'the clock expires ten minutes after the GREEN, not after the release')

-- ---------------------------------------------------------------------------
-- Qualifying never paces, whatever the switch says
-- ---------------------------------------------------------------------------
-- There is no field to form up in qualifying: drivers go out when they choose
-- and the lap that matters is a solo one. The rule stays armed for the race
-- afterwards; it simply does not apply here.
RM_onResetLeaderboard(0)
RM_onSetPaceLap(0, '{"enabled":true}')
RM_onSetRaceLimits(0, '{"laps":3,"seconds":0,"mode":"laps"}')
RM_onSetSpectating(0, '{"spectating":true}')
RM_onStartQualifying(0)
check(lastState.phase == 'grid', 'qualifying forms a grid')
check(lastState.paceLap == true, 'with the pace lap still armed')
chatClear()
RM_onStartRace(0)
check(lastState.phase == 'grid', 'but Start Race is refused for a qualifying grid')
check(chatHas('pace lap is not armed'), 'and says so')
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'qualifying', 'qualifying starts from the lights as it always did')
check(lastState.pacing == false, 'and runs no pace lap')
check(lastState.flag == 'green', 'under green')

-- ---------------------------------------------------------------------------
-- Reset Session keeps the rule and drops the condition
-- ---------------------------------------------------------------------------
-- An admin who set the league up to run formation starts has not changed their
-- mind by pressing Reset -- but a session reset mid-pace-lap must not come back
-- as one, or the next race is released under a yellow with its latch tripped.
RM_onEndRace(0)
RM_onSetSpectating(0, '{"spectating":true}')
RM_onGenerateGrid(0)
RM_onStartRace(0)
check(lastState.pacing == true, 'pacing')
RM_onResetLeaderboard(0)
check(lastState.pacing == false, 'Reset Session drops the pace lap that was running')
check(lastState.paceLap == true, 'and keeps the rule, which is a league setting')
check(lastState.phase == 'waiting', 'back to waiting')

if fails == 0 then
  print(string.format('pace_test: %d checks, 0 failures', checks))
else
  print(string.format('pace_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
