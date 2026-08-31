-- Headless test for MULTI-CLASS RACING in server/RaceManager/main.lua.
--
-- There was no class concept anywhere: no field on a driver record, no per-class
-- positions, no per-class results section. A league running two car types either
-- scored them together or ran two separate events, and the Garage List locking
-- the field to one car was the workaround.
--
-- A CLASS IS A PROPERTY OF THE CAR, which is why it is tagged on the Garage List
-- entry rather than assigned to a driver. GT3 cars are GT3 whoever is driving
-- them, so a league sets it once per entry instead of doing bookkeeping for
-- every driver at every event -- and a driver who changes car changes class by
-- doing so, with nobody having to remember.
--
-- The checks worth having here are the ones that keep the feature from leaking
-- into a season that never asked for it, and the ones about what a class
-- position MEANS:
--
--   * a server with no class on any entry is untouched: no class, no classPos,
--     no column, no section;
--   * classes work with enforcement OFF, because "what class is this car" and
--     "is this car legal" are different questions;
--   * class positions are counted within the class, so P1 in the slower class is
--     not P1 overall -- and the overall order is unchanged by any of it;
--   * a class survives the Generate Grid purge, like a heat does.
--
-- Run from the repo root: lua5.3 tests/class_test.lua

local connected = { [0] = 'Admin', [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
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

-- Declaring a car, the way a client does. The parts signature is what 'parts'
-- mode matches on, and it is the prefix of the full one.
local function declare(pid, model)
  local parts = 'model=' .. model .. '|parts=std'
  RM_onVehicleConfig(pid, string.format(
    '{"model":"%s","label":"%s","partsSig":"%s","sig":"%s|vars=0"}',
    model, model, parts, parts))
end
-- Whitelisting one, the way the panel does. The admin drives it and captures it.
local function whitelist(pid, model)
  local parts = 'model=' .. model .. '|parts=std'
  RM_onWhitelistVehicle(pid, string.format(
    '{"model":"%s","label":"%s","partsSig":"%s","sig":"%s|vars=0"}',
    model, model, parts, parts))
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":10}')

-- ---------------------------------------------------------------------------
-- A garage with no classes on it is a garage
-- ---------------------------------------------------------------------------
-- CLEARED FIRST, because garage.json is real persisted state and it outlives a
-- test run. Without this the suite inherits the classes its own previous run
-- left behind and the first two checks pass or fail depending on whether
-- anybody has run it before -- which is the worst kind of test.
RM_onClearGarage(0)
whitelist(0, 'fastcar')
whitelist(0, 'slowcar')
check(#lastState.garage == 2, 'two cars on the list')
check(lastState.garage[1].class == nil, 'and neither carries a class yet')

declare(1, 'fastcar'); declare(2, 'fastcar')
declare(3, 'slowcar'); declare(4, 'slowcar')
seconds(0.5)
check(driver(1).class == nil, 'so no driver has one either')
check(driver(1).classPos == nil, 'and there are no class positions to hand out')

-- ---------------------------------------------------------------------------
-- Tagging the entries
-- ---------------------------------------------------------------------------
RM_onSetGarageClass(3, '{"index":1,"class":"GT3"}')
check(lastState.garage[1].class == nil, 'tagging a class requires authentication')

RM_onSetGarageClass(0, '{"index":1,"class":"GT3"}')
RM_onSetGarageClass(0, '{"index":2,"class":"GT4"}')
check(lastState.garage[1].class == 'GT3', 'the first entry is GT3')
check(lastState.garage[2].class == 'GT4', 'the second is GT4')

-- EVERY DRIVER IS RE-JUDGED IMMEDIATELY. An admin who tags an entry has to see
-- the drivers in that car become GT3 now, not whenever they next happen to
-- touch their setup -- which for a driver sitting on the grid is never.
seconds(0.5)
check(driver(1).class == 'GT3' and driver(2).class == 'GT3',
  'the drivers in that car are GT3 without re-declaring')
check(driver(3).class == 'GT4' and driver(4).class == 'GT4', 'and the others GT4')

-- ...AND IT WORKS WITH ENFORCEMENT OFF, which is the point of deriving the class
-- separately from the verdict. Scoring two classes and policing setups are
-- different things to want.
check(lastState.garageEnforce ~= true, 'the garage is not being enforced')
check(driver(1).carOk == nil, 'so nobody has a compliance verdict')
check(driver(1).class == 'GT3', 'and the class is there anyway')

-- ---------------------------------------------------------------------------
-- Class positions are counted WITHIN the class
-- ---------------------------------------------------------------------------
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
-- The two GT3 cars run away with it; the GT4s are a lap down. Overall that is
-- 1, 2, 3, 4 -- and in class it is two P1s.
lap(1); lap(2); lap(3); lap(4)
lap(1); lap(2)
seconds(0.5)
check(driver(1).position == 1 and driver(2).position == 2,
  'the GT3 cars lead overall')
check(driver(1).classPos == 1 and driver(2).classPos == 2,
  'and are P1 and P2 in GT3')
check(driver(3).classPos == 1,
  'the leading GT4 is P1 IN CLASS while being P3 overall (got P'
    .. tostring(driver(3).classPos) .. ')')
check(driver(3).position == 3, 'and the overall order is untouched by any of it')
check(driver(4).classPos == 2, 'with the second GT4 behind them in class')

-- ---------------------------------------------------------------------------
-- A class survives the purge, like a heat does
-- ---------------------------------------------------------------------------
-- Generate Grid drops every record that is not a connected player, so the class
-- is mirrored into the identity registry. A driver who reconnects between two
-- races must not come back unclassified and be scored against the wrong field.
RM_onEndRace(0)
RM_onPlayerDisconnect(3)
RM_onGenerateGrid(0)
RM_onPlayerJoin(3)
seconds(0.5)
check(driver(3) ~= nil and driver(3).class == 'GT4',
  'a driver who dropped out and came back is still GT4')

-- ---------------------------------------------------------------------------
-- Clearing a class
-- ---------------------------------------------------------------------------
-- Blank is how a league drops back to one class without deleting the entry that
-- defines the car.
RM_onSetGarageClass(0, '{"index":2,"class":""}')
seconds(0.5)
check(lastState.garage[2].class == nil, 'an empty class clears the tag')
check(driver(3).class == nil, 'and the drivers in that car are unclassified again')
check(driver(1).class == 'GT3', 'while the other class is untouched')

-- A class name is capped and cleaned: the results file is a fixed-width table
-- and a long or multi-byte name would shear every row after it.
RM_onSetGarageClass(0, '{"index":2,"class":"AAAAAAAAAAAAAAAAAAAA"}')
check(#lastState.garage[2].class <= 12, 'a long class name is cut to fit the column')
RM_onSetGarageClass(0, '{"index":2,"class":""}')

-- ---------------------------------------------------------------------------
-- The results file carries both
-- ---------------------------------------------------------------------------
RM_onSetGarageClass(0, '{"index":2,"class":"GT4"}')
RM_onResetLeaderboard(0)
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":1}')
seconds(0.5)
RM_onGenerateGrid(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lap(1); lap(3); lap(2); lap(4)  -- a GT3, a GT4, a GT3, a GT4
seconds(1)
RM_onEndRace(0)
seconds(7)

local path = nil
for _, m in ipairs(chatLog) do
  local p = m:match('(Resources/Server/RaceManager/results/[%w%-_%./]+%.txt)')
  if p then path = p end
end
check(path ~= nil, 'a results file was written')
local text = ''
if path then
  local f = io.open(path, 'r')
  if f then text = f:read('*a'); f:close() end
end
check(text:find('Class', 1, true) ~= nil, 'the results table has a Class column')
check(text:find('--- CLASS: GT3 ---', 1, true) ~= nil, 'and a GT3 section')
check(text:find('--- CLASS: GT4 ---', 1, true) ~= nil, 'and a GT4 section')
check(text:find('CLASS WINNER', 1, true) ~= nil,
  'each class names its own winner, which is the sheet a GT4 driver reads')
-- The overall winner is still the overall winner. A per-class section is an
-- extra reading of the race, not a replacement for it.
check(text:find('RACE WINNER', 1, true) ~= nil, 'and the overall winner is still named')

-- ...and cleared again on the way out, so this suite does not hand its GT3/GT4
-- tags to whatever runs next.
RM_onClearGarage(0)

if fails == 0 then
  print(string.format('class_test: %d checks, 0 failures', checks))
else
  print(string.format('class_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
