-- Headless test for GARAGE DISPLAY NAMES in server/RaceManager/main.lua.
--
-- A name is for people. The checks that matter are the ones that keep it out of
-- the rule: renaming an entry must not change what it matches, what a set
-- carries, or who is refused.
--
-- Run from the repo root: lua5.3 tests/garage_name_test.lua

local connected = { [0] = 'Admin', [1] = 'Alice', [2] = 'Bob', [3] = 'Cara' }
local lastState = nil
local lastGarage = {}
local garagePushes = {}
local results, rejected, cars = {}, {}, {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
    if event == 'RM_Garage' then
      lastGarage = payload
      garagePushes[#garagePushes + 1] = { target = target, payload = payload }
    end
    if event == 'RM_GarageResult' then results[#results + 1] = payload end
    if event == 'RM_VehicleRejected' then rejected[target] = (rejected[target] or 0) + 1 end
    if event == 'RM_GarageCar' then cars[#cars + 1] = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
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

local GARAGE = 'Resources/Server/RaceManager/Data/garage.json'
local SET = 'Resources/Server/RaceManager/Data/Garage/Names Test.json'

dofile('server/RaceManager/main.lua')
local records = require('records')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function read(p)
  local f = io.open(p, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end
local function declare(pid, model)
  local parts = 'model=' .. model .. '|parts=std'
  RM_onVehicleConfig(pid, string.format(
    '{"model":"%s","label":"%s own label","partsSig":"%s","sig":"%s|vars=0"}',
    model, model, parts, parts))
end
local function whitelist(pid, model)
  local parts = 'model=' .. model .. '|parts=std'
  RM_onWhitelistVehicle(pid, string.format(
    '{"model":"%s","label":"%s","partsSig":"%s","sig":"%s|vars=0"}',
    model, model, parts, parts))
end
local function rename(pid, index, name, was)
  RM_onSetGarageName(pid, string.format('{"index":%d,"name":"%s","was":"%s"}', index, name, was))
end
local function entry(i) return lastGarage.garage[i] end

onInit()
RM_onLogin(0, '{"password":"phoenix"}')
RM_onChangePassword(0, '{"password":"tuesday","role":"moderator"}')
RM_onLogin(2, '{"password":"tuesday"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onClearGarage(0)
os.remove(SET)
whitelist(0, 'fastcar')
whitelist(0, 'slowcar')

-- ---------------------------------------------------------------------------
-- 1. Who may rename
-- ---------------------------------------------------------------------------
rename(3, 1, 'Nope', 'fastcar')
check(entry(1).label == 'fastcar' and entry(1)['default'] == nil, 'a driver cannot rename an entry')
rename(2, 1, 'GT3 Audi R8', 'fastcar')
check(entry(1).label == 'GT3 Audi R8' and entry(1)['default'] == 'fastcar',
  'a moderator can, and the panel gets the name and the captured label')

local disk = read(GARAGE) or ''
check(disk:find('"name": "GT3 Audi R8"', 1, true) ~= nil, 'the name is kept in garage.json')
check(disk:find('"label": "fastcar"', 1, true) ~= nil, 'beside the captured label, untouched')
check(disk:find('"sig": "model=fastcar|parts=std|vars=0"', 1, true) ~= nil, 'and so is the signature')

-- ---------------------------------------------------------------------------
-- 2. Matching does not read it
-- ---------------------------------------------------------------------------
RM_onSetGarageEnforce(0, '{"enabled":true}')
declare(1, 'fastcar')
declare(3, 'othercar')
check(not rejected[1], 'a renamed entry still lets its car through')
check(rejected[3], 'and a car not on the list is still refused')
local p1 = records.host.players[1]
check(p1.carOk == true and p1.carLabel == 'GT3 Audi R8',
  'the driver in it is called what the list calls it, for the board and the records')

rename(0, 1, 'Audi', 'GT3 Audi R8')
check(p1.carLabel == 'Audi', 'a rename reaches a car already out, without a re-declaration')
check(not rejected[1], 'and refuses nobody')

-- ---------------------------------------------------------------------------
-- 3. The list moved under the editor
-- ---------------------------------------------------------------------------
results = {}
rename(0, 1, 'Wrong', 'slowcar')
check(entry(1).label == 'Audi', 'a stale editor does not rename the neighbour')
check(results[1] and results[1].message:find('changed', 1, true), 'and the admin is told why')

-- ---------------------------------------------------------------------------
-- 4. Default, and what a name may hold
-- ---------------------------------------------------------------------------
rename(0, 1, '', 'Audi')
check(entry(1).label == 'fastcar' and entry(1)['default'] == nil, 'an empty name shows the captured label again')
check(not (read(GARAGE) or ''):find('"name"', 1, true), 'and leaves no name in the file')
rename(0, 2, 'slowcar', 'slowcar')
check(entry(2)['default'] == nil, 'naming an entry its own label is no name')

rename(0, 2, '  Slow \t  car  ', 'slowcar')
check(entry(2).label == 'Slow car', 'spaces and control characters are tidied')
rename(0, 2, string.rep('é', 60), 'Slow car')
check(utf8.len(entry(2).label) == 40, 'a long name is cut to 40 characters')
check(utf8.len(entry(2).label) ~= nil, 'on a character, never inside one: the broadcast must encode')
rename(0, 2, 'ok\255name', entry(2).label)
check(entry(2).label == 'okname' and utf8.len(entry(2).label), 'a byte that is not UTF-8 is dropped')

-- ---------------------------------------------------------------------------
-- 5. The take answer, and sets
-- ---------------------------------------------------------------------------
rename(0, 1, 'Audi', 'fastcar')
RM_onTakeGarageCar(1, '{"index":1}')
check(cars[#cars].message:find('"Audi"', 1, true), 'messages about an entry use its name')

RM_onSaveGarageSet(0, '{"name":"Names Test"}')
check((read(SET) or ''):find('"name": "Audi"', 1, true) ~= nil, 'a saved set carries the names')
RM_onClearGarage(0)
RM_onLoadGarageSet(0, '{"name":"Names Test"}')
check(entry(1).label == 'Audi' and entry(1)['default'] == 'fastcar', 'and loading it brings them back')
check(entry(2).label == 'okname', 'every one of them')
RM_onClearGarage(0)
RM_onLoadGarageSet(0, '{"name":"Names Test","append":true}')
check(#lastGarage.garage == 2 and entry(1).label == 'Audi', 'Add Set keeps them too')

-- ---------------------------------------------------------------------------
-- 6. A restart reads them back, cleaned
-- ---------------------------------------------------------------------------
local text = read(GARAGE):gsub('"name": "okname"', '"name": "hand\\tedited"')
local f = assert(io.open(GARAGE, 'w')); f:write(text); f:close()
dofile('server/RaceManager/main.lua')
onInit()
RM_onLogin(0, '{"password":"phoenix"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
lastGarage = {}
RM_onRequestState(0)   -- what a joining client asks for
check(entry(1).label == 'Audi', 'a name survives a restart')
check(entry(2).label == 'hand edited', 'and a hand edit is read through the same cleaning')

-- ---------------------------------------------------------------------------
-- 7. The list goes out when it changes, not with the timing
-- ---------------------------------------------------------------------------
-- It rode every RM_Update, three times a second to everyone while a session
-- ran: half of every push at a full garage, for a list that changes a couple of
-- times a night.
garagePushes = {}
RM_onSetReadyCheck(0, '{"on":false}')
RM_onStartQualifying(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
for _ = 1, 30 do RM_Tick() end
check(lastState.phase == 'qualifying', 'a session is running')
check(lastState.garage == nil and lastState.garageSets == nil,
  'the state push no longer carries the Garage List')
check(#garagePushes == 0, 'and nothing garage-shaped is sent while cars are on track')
RM_onEndRace(0)

garagePushes = {}
RM_onRequestState(3)
check(#garagePushes == 1 and garagePushes[1].target == 3 and #garagePushes[1].payload.garage == 2,
  'a client asking for state gets the list, addressed to it alone')
local seq = garagePushes[1].payload.seq
check(type(seq) == 'number' and garagePushes[1].payload.boot ~= nil, 'numbered, so a late copy can be told apart')
rename(0, 1, 'Audi Sport', 'Audi')
check(garagePushes[2].target == -1 and garagePushes[2].payload.seq == seq + 1,
  'a change goes to everyone, one number on')
RM_onSaveGarageSet(0, '{"name":"Names Test"}')
check(#garagePushes == 3, 'a saved set name is a change too')
RM_onRequestState(3)
check(garagePushes[4].payload.seq == seq + 2, 'and a request after it says so')

RM_onClearGarage(0)
RM_onSetGarageEnforce(0, '{"enabled":false}')
os.remove(SET)

if fails == 0 then
  print(string.format('garage_name_test: %d checks, 0 failures', checks))
else
  print(string.format('garage_name_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
