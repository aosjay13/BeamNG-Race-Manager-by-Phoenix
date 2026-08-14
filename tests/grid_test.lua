-- Headless test for the race-entry list, the starting grid and the qualifying
-- session rules in server/RaceManager/main.lua (Lua 5.3, same as BeamMP).
-- Run from the repo root: lua5.3 tests/grid_test.lua
--
-- Covers, in one session-shaped pass:
--   * opt-in entry: connecting is not entering, and only entrants are gridded
--   * grid order: qualifying, random draw and a hand-picked custom order
--   * grid assignment: every gridded driver is told which start position to
--     stand on, and drivers who withdraw are told to stand down
--   * qualifying limits: a per-driver lap allowance and a wall-clock limit
--   * a finished driver is taken off the track and given their car back at
--     the flag

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
local lastState  = nil
local lastChat   = nil
local gridAssign = {}   -- [pid] = last slot the server assigned (false = cleared)
local spectated  = {}   -- [pid] = last RM_ForceSpectate payload
local released   = {}   -- ordered list of RM_ReleaseSpectate payloads
local timers     = {}
local hostedMap  = '/levels/gridmap_v2/info.json'

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) lastChat = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
    if event == 'RM_GridAssign' then
      gridAssign[target] = payload.slot or false
    end
    if event == 'RM_ForceSpectate'   then spectated[target] = payload end
    if event == 'RM_ReleaseSpectate' then released[#released + 1] = payload end
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

onInit()
RM_onLogin(1, '{"password":"phoenix"}')
for id in pairs(connected) do RM_onPlayerJoin(id) end

-- ===========================================================================
-- Race entry: connecting is not entering
-- ===========================================================================
check(lastState.entryMode == 'join', 'entry defaults to opt-in')
check(lastState.entrants == 0, 'four connected players, nobody entered')

RM_onJoinRace(2, '{"join":true}')
RM_onJoinRace(3, '{"join":true}')
RM_onJoinRace(1, '{"join":true}')
check(lastState.entrants == 3, 'three of the four players entered')
check(driver('Dan').joined ~= true, 'the player who never joined is not an entrant')

-- ===========================================================================
-- Qualifying with a lap allowance
-- ===========================================================================
RM_onSetQualiLimits(1, '{"laps":2,"seconds":0}')
check(lastState.qualiLapLimit == 2, 'lap allowance set to 2')
RM_onSetGhostQuali(1, '{"enabled":true}')
check(lastState.ghostQuali == true, 'ghost qualifying armed')

-- Qualifying runs the SAME lifecycle a race does: form the grid, hold the
-- field, count down, run the session, take finished cars off and give every car
-- back. It used to skip straight to a running phase with no grid at all, which
-- is why a driver's first crossing of the line was an out-lap and a "2 lap"
-- session took three or four laps to get through.
RM_onStartQualifying(1)
check(lastState.phase == 'grid', 'Start Qualifying forms a grid, exactly like a race')
check(driver('Alice').gridPos ~= nil, 'entrants are gridded for qualifying')
check(driver('Alice').status == 'gridded', 'and are held on the grid, not loose on track')
check(driver('Dan').gridPos == nil, 'a non-entrant is left off the qualifying grid')
check(driver('Alice').joined == true, 'entry survives the session wipe')
check(gridAssign[1] == driver('Alice').gridPos,
  'every qualifying entrant is told which start position to take')

RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'qualifying', 'the qualifying session is running')
check(driver('Alice').status == 'qualifying', 'entrants are out on track')
check(driver('Alice').currentLap == 1, 'lap 1 starts at the line, from the grid')
check(driver('Dan').status == 'waiting', 'a non-entrant stays a spectator')

-- A non-entrant's lap is not recorded at all.
RM_onLap(4, '{"lapTime":50.0}')
check(driver('Dan').qualiBest == nil, 'a non-entrant cannot set a qualifying time')

-- The out lap, taken by everyone who is entered. It is the standing start being
-- given away, so it sets nothing and spends nothing.
for pid = 1, 3 do RM_onLap(pid, '{"lapTime":60.0}') end
check(driver('Alice').qualiBest == nil and driver('Alice').qualiLaps == 0,
  'the out lap sets no time and spends none of the allowance')
check(driver('Alice').status == 'qualifying', 'and does not end anyone\'s session')

-- Alice: two timed laps, then her session is done and a third lap is ignored.
RM_onLap(1, '{"lapTime":95.0}')
RM_onLap(1, '{"lapTime":93.0}')
check(driver('Alice').qualiLaps == 2, 'both of Alice\'s timed laps counted')
check(driver('Alice').status == 'finished', 'Alice used her lap allowance')
check(spectated[1] ~= nil, 'a driver who is done is taken off the track')
RM_onLap(1, '{"lapTime":80.0}')
check(driver('Alice').qualiBest == 93.0, 'a lap past the allowance is ignored')
check(driver('Alice').qualiLaps == 2, 'and does not add to the lap count')

RM_onLap(2, '{"lapTime":91.0}')   -- Bob, one timed lap: fastest so far
RM_onLap(3, '{"lapTime":97.0}')   -- Cara, one timed lap

-- The session closes itself once every entrant has used their allowance.
check(lastState.phase == 'qualifying', 'the session runs while drivers have laps left')
released = {}
RM_onLap(2, '{"lapTime":99.0}')
RM_onLap(3, '{"lapTime":99.0}')
check(lastState.phase == 'waiting', 'qualifying closes when every allowance is spent')
check(driver('Bob').qualiBest == 91.0, 'best laps survive the close')
check(#released >= 3, 'every driver gets their car back when qualifying ends')

-- ===========================================================================
-- Grid order: qualifying, random and custom
-- ===========================================================================
RM_onGenerateGrid(1)
check(lastState.phase == 'grid', 'grid formed')
check(driver('Bob').gridPos == 1 and driver('Alice').gridPos == 2
  and driver('Cara').gridPos == 3, 'quali order puts the fastest on pole')
check(driver('Dan').gridPos == nil, 'a non-entrant is left off the grid')
check(gridAssign[2] == 1 and gridAssign[1] == 2 and gridAssign[3] == 3,
  'every gridded driver is told which start position to take')
check(gridAssign[4] == false, 'a non-entrant is told to stand down')

-- Withdrawing from a formed grid clears that driver's placement.
RM_onJoinRace(3, '{"join":false}')
check(gridAssign[3] == false, 'withdrawing clears the start position')
check(lastState.entrants == 2, 'the field shrinks to two')
RM_onJoinRace(3, '{"join":true}')

-- ===========================================================================
-- Reverse grid: slowest on pole, fastest at the back
-- ===========================================================================
-- The format inverts the TIMES and nothing else. A driver who set no time is
-- still gridded last, because a literal reversal would put them on pole -- and
-- then the quickest way to start first is to sit in the pits and set nothing. A
-- reverse grid is meant to reward the slow, not the absent.
RM_onJoinRace(4, '{"join":true}')            -- Dan: entered, never set a time
RM_onSetGridMode(1, '{"mode":"reverse"}')
check(lastState.gridMode == 'reverse', 'grid mode switched to a reverse grid')
RM_onGenerateGrid(1)
check(driver('Cara').gridPos == 1, 'the slowest qualifier (97.0) takes pole')
check(driver('Alice').gridPos == 2, 'the middle time (93.0) stays in the middle')
check(driver('Bob').gridPos == 3,
  'the fastest qualifier (91.0) starts last of the drivers who set a time')
check(driver('Dan').gridPos == 4,
  'and a driver with no time is still at the back, not on pole')
check(gridAssign[3] == 1 and gridAssign[2] == 3,
  'the reversed order is what gets sent to the clients')

-- Nothing about it is sticky: the same field grids the other way round again.
RM_onSetGridMode(1, '{"mode":"quali"}')
RM_onGenerateGrid(1)
check(driver('Bob').gridPos == 1 and driver('Cara').gridPos == 3,
  'switching back to quali order puts the fastest on pole again')
RM_onJoinRace(4, '{"join":false}')           -- Dan back out

-- Random draw: still a complete 1..N permutation of the entry list.
RM_onSetGridMode(1, '{"mode":"random"}')
check(lastState.gridMode == 'random', 'grid mode switched to a random draw')
RM_onGenerateGrid(1)
local seen = {}
for _, d in ipairs(lastState.drivers) do
  if d.gridPos then seen[d.gridPos] = (seen[d.gridPos] or 0) + 1 end
end
check(seen[1] == 1 and seen[2] == 1 and seen[3] == 1,
  'the random draw assigns each slot exactly once')

-- Custom order: pinning a driver moves them, and pinning a slot someone else
-- holds takes it off that driver rather than doubling up.
RM_onSetDriverGrid(1, '{"pid":3,"slot":1}')
check(lastState.gridMode == 'custom', 'pinning a slot switches to the custom order')
RM_onSetDriverGrid(1, '{"pid":1,"slot":2}')
RM_onSetDriverGrid(1, '{"pid":2,"slot":1}')  -- steals slot 1 from Cara
RM_onGenerateGrid(1)
check(driver('Bob').gridPos == 1, 'the last driver pinned to slot 1 starts from pole')
check(driver('Alice').gridPos == 2, 'the driver pinned to slot 2 starts second')
check(driver('Cara').gridPos == 3, 'the driver whose slot was taken falls in behind')
check(gridAssign[2] == 1 and gridAssign[1] == 2 and gridAssign[3] == 3,
  'the custom order is what gets sent to the clients')

-- Grid order cannot be rewritten once the lights go out.
RM_onSetTotalLaps(1, '{"laps":1}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'race running')
RM_onSetGridMode(1, '{"mode":"quali"}')
check(lastState.gridMode == 'custom', 'grid mode locked during the race')
RM_onJoinRace(4, '{"join":true}')
check(lastState.entrants == 3, 'nobody can enter a race already under way')

-- ===========================================================================
-- A finished driver is taken off the track, and gets their car back at the flag
-- ===========================================================================
spectated = {}
released  = {}
RM_onLap(2, '{"lapTime":90}')
check(driver('Bob').status == 'finished', 'Bob took the flag')
check(spectated[2] ~= nil and spectated[2].source == 'race',
  'a finished car is removed from the track')
check(lastState.phase == 'racing', 'the race continues for the others')

RM_onLap(1, '{"lapTime":91}')
RM_onLap(3, '{"lapTime":92}')
check(lastState.phase == 'finished', 'race over once everyone has finished')
check(#released > 0 and released[#released].source == 'race',
  'the flag gives every removed car back')

-- ===========================================================================
-- Qualifying time limit: the clock arms the final lap
-- ===========================================================================
-- Expiry does NOT end a timed session — the drivers out there are mid-lap, and
-- that lap is the one that matters. See tests/timed_quali_test.lua for the whole
-- final-lap path and its edge cases; this only pins the transition.
RM_onResetLeaderboard(1)
RM_onSetQualiLimits(1, '{"laps":0,"seconds":2}')
check(lastState.qualiTimeLimit == 2, 'a 2 second qualifying limit is accepted')
RM_onJoinRace(1, '{"join":true}')
RM_onStartQualifying(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'qualifying', 'timed qualifying started')
for _ = 1, 10 do RM_Tick() end     -- +1.0s
check(lastState.phase == 'qualifying', 'the session runs while time remains')
check(lastState.qualiLeft ~= nil and lastState.qualiLeft < 2,
  'the remaining time counts down in the broadcast')
for _ = 1, 15 do RM_Tick() end     -- past the limit
check(lastState.phase == 'qualifying',
  'the time limit does not end the session out from under a driver mid-lap')
check(lastState.finalLap == true, 'it arms the final lap instead')
check(type(lastChat) == 'string' and lastChat:find('FINAL LAP', 1, true) ~= nil,
  'chat tells every driver the lap they are on is their last')
-- The crossing is what ends it, and it takes the car off the track — but not
-- the OUT lap crossing. This driver was still on their out lap when the clock
-- expired, and a session that had already promised not to score that lap must
-- not turn round and end them on it: they get the flying lap the final-lap rule
-- gives everybody else.
RM_onLap(1, '{"lapTime":88}')
check(lastState.phase == 'qualifying',
  'the out lap is never the crossing that ends a driver\'s session')
check(driver('Alice').qualiBest == nil, 'and it still sets no time')
RM_onLap(1, '{"lapTime":88}')
check(lastState.phase == 'waiting', 'the last driver home closes qualifying')
check(driver('Alice').qualiBest == 88.0, 'the timed lap after it counts in full')

-- Limits cannot be changed while qualifying is running.
RM_onStartQualifying(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
RM_onSetQualiLimits(1, '{"laps":9,"seconds":900}')
check(lastState.qualiLapLimit == 0 and lastState.qualiTimeLimit == 2,
  'qualifying limits are locked while the session runs')

-- ---------------------------------------------------------------------------
-- Player id ZERO is a real driver.
--
-- BeamMP hands out zero-based player ids, so the first player on the server is
-- id 0. An `id > 0` guard silently throws that driver away -- which is exactly
-- how the client bridge dropped both the grid-pin and the display-name command
-- for whoever joined first: the control accepted input and nothing was ever
-- sent. Pinned here so the server never grows the same assumption.
--
-- Deliberately last in the file: it adds a fourth driver, and every section
-- above is written around the three that join at the top.
-- ---------------------------------------------------------------------------
RM_onEndRace(1)
RM_onResetLeaderboard(1)
connected[0] = 'Zed'
RM_onPlayerJoin(0)
RM_onSetEntryMode(1, '{"mode":"all"}')
RM_onSetGridMode(1, '{"mode":"custom"}')
RM_onSetDriverGrid(1, '{"pid":0,"slot":1}')
RM_onGenerateGrid(1)
check(driver('Zed') ~= nil, 'player id 0 is a real driver')
check(driver('Zed').gridPos == 1, 'player id 0 can be pinned to a grid slot')
check(gridAssign[0] == 1, 'player id 0 is sent its slot like every other driver')

if fails == 0 then
  print('ALL PASS (' .. checks .. ' checks)')
else
  print(fails .. '/' .. checks .. ' FAILED')
  os.exit(1)
end
