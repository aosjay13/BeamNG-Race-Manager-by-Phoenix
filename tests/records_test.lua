-- Headless test for LAP RECORDS (server/RaceManager/records.lua), run against
-- the real server plugin in Lua 5.3, the same as BeamMP.
-- Run from the repo root: lua5.3 tests/records_test.lua
--
-- Sessions are driven through the real handlers, so what lands on the board is
-- what finishSession hands over: the out lap and a race's standing first lap
-- never set a time, and a disqualified driver sets none at all.

local connected = { [0] = 'Guest_A', [1] = 'Guest_B', [2] = 'Guest_C', [3] = 'Guest_D' }
local chat = {}          -- { target, msg }
local pushes = {}        -- RM_Records payloads, { target, payload }
local timers = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chat[#chat + 1] = { target = target, msg = msg } end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Records' then pushes[#pushes + 1] = { target = target, payload = payload } end
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
local records = require('records')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local FILE = 'Resources/Server/RaceManager/Data/Lap Records/gridmap_v2.json'

local function read(p)
  local f = io.open(p, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end
local function write(p, s)
  local f = assert(io.open(p, 'w'))
  f:write(s)
  f:close()
end

local function said(needle, target)
  for _, c in ipairs(chat) do
    if (target == nil or c.target == target) and c.msg:find(needle, 1, true) then return true end
  end
  return false
end
local function lastPush(target)
  for i = #pushes, 1, -1 do
    if target == nil or pushes[i].target == target then return pushes[i].payload end
  end
end
local function board(name)
  local boards = records.read('gridmap_v2')
  return boards[name:lower()]
end
local function row(b, driver)
  for i, r in ipairs(b and b.laps or {}) do
    if r.driver == driver then return r, i end
  end
end

local function lap(pid, t) RM_onLap(pid, '{"lapTime":' .. t .. '}') end

local function startQuali()
  RM_onEndRace(0)
  RM_onSetQualiLimits(0, '{"laps":0,"seconds":0}')
  RM_onStartQualifying(0)
  RM_onStartCountdown(0)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
end

local function startRace()
  RM_onGenerateGrid(0)
  RM_onStartCountdown(0)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
end

-- Left over from other suites, which run sessions on gridmap_v2 too.
os.remove(FILE)

onInit()
RM_onLogin(0, '{"password":"phoenix"}'); RM_onSetReadyCheck(0, '{"on":false}')
RM_onChangePassword(0, '{"password":"tuesday","role":"moderator"}')
RM_onLogin(3, '{"password":"tuesday"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetTotalLaps(0, '{"laps":10}')
RM_onVehicleConfig(0, '{"sig":"model=etk800|parts=a","partsSig":"model=etk800|parts=a",'
  .. '"model":"etk800","label":"ETK 800"}')

-- ---------------------------------------------------------------------------
-- 1. Nothing global at file scope
-- ---------------------------------------------------------------------------
do
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile('server/RaceManager/records.lua', 't', env))
  chunk()
  local leaked = {}
  for k in pairs(env) do leaked[#leaked + 1] = k end
  check(#leaked == 0, 'records.lua defines no globals when BeamMP runs it on its own (found: '
    .. table.concat(leaked, ', ') .. ')')
  check(type(RM_onRecordsRequest) == 'function', 'and main.lua installed the handlers through init')
end

-- ---------------------------------------------------------------------------
-- 2. No saved layout, no records
-- ---------------------------------------------------------------------------
startQuali()
lap(1, 90); lap(1, 80)
RM_onEndRace(0)
check(read(FILE) == nil, 'a session on no saved layout writes no board')

-- ---------------------------------------------------------------------------
-- 3. Qualifying fills the board
-- ---------------------------------------------------------------------------
RM_onSaveLayout(0, '{"name":"Club","width":20,"checkpoints":['
  .. '{"x":0,"y":0,"z":0,"hx":0,"hy":1},{"x":100,"y":0,"z":0,"hx":1,"hy":0}]}')
RM_onLoadLayout(0, '{"name":"Club"}')

startQuali()
chat, pushes = {}, {}
lap(0, 70); lap(1, 70); lap(2, 70)            -- out laps: not timed
lap(0, 85.1234); lap(1, 84.5); lap(2, 86.0)
lap(0, 83.98765)
check(#pushes == 0, 'nothing is pushed while cars are on track')
RM_onEndRace(0)

local b = board('Club')
check(b and #b.laps == 3, 'three drivers with timed laps, three rows')
check(b and b.laps[1].driver == 'Guest_A' and b.laps[1].time == 83.988,
  'fastest first, to the millisecond')
check(b and b.laps[2].driver == 'Guest_B' and b.laps[3].driver == 'Guest_C', 'in order')
check(not row(b, 'Guest_D'), 'a driver with no timed lap is not on the board')
check(b and b.laps[1].car == 'ETK 800', 'the car the lap was set in')
check(b and b.laps[1].session == 'quali' and tostring(b.laps[1].date):match('^%d%d%d%d%-%d%d%-%d%d$'),
  'the session and the date')
check(not row(b, 'Guest_A') or row(b, 'Guest_A').time ~= 70, 'the out lap set nothing')
check(said('NEW LAP RECORD on "Club": Guest_A 1:23.988 (the first on this track)', -1),
  'the first record is announced')
check(said('P2 of 3', 1) and not said('P1 of 3', 0), 'the rest are told their place, privately')
local p = lastPush(-1)
check(p and p.changed and p.layout == 'Club' and #p.laps == 3, 'everyone gets the new board')

-- Laid out to be read and edited: one row per line.
local text = read(FILE) or ''
check(text:find('"Club": %[') ~= nil, 'the file is keyed by layout name')
check(text:find('\n%s+{"car": "ETK 800", "date": "[%d%-]+", "driver": "Guest_A", "session": "quali", '
  .. '"time": 83.988}') ~= nil, 'one row per line, keys in a stable order')

-- ---------------------------------------------------------------------------
-- 4. A race improves some times and not others
-- ---------------------------------------------------------------------------
startRace()
chat, pushes = {}, {}
lap(0, 60); lap(1, 60); lap(2, 60)            -- the standing first lap: no time
lap(0, 84.2); lap(1, 83.5); lap(2, 85.0)
check(#pushes == 0, 'nothing is pushed during the race either')
RM_onEndRace(0)

b = board('Club')
check(b.laps[1].driver == 'Guest_B' and b.laps[1].time == 83.5 and b.laps[1].session == 'race',
  'a faster lap takes the record')
check(row(b, 'Guest_A').time == 83.988 and row(b, 'Guest_A').session == 'quali',
  'a slower lap leaves a driver\'s best alone')
check(row(b, 'Guest_C').time == 85.0, 'a personal best replaces the old one')
check(said('NEW LAP RECORD on "Club": Guest_B 1:23.500 (was 1:23.988, Guest_A)', -1),
  'the new record names the old one')
check(said('P3 of 3', 2), 'the improver hears about it')
check(not said('Your best', 0), 'nobody is told about a lap that did not improve')

-- ---------------------------------------------------------------------------
-- 5. Disqualified, and a circuit run as a sprint
-- ---------------------------------------------------------------------------
local host = records.host
host.players[2].raceBest, host.players[2].status = 80.0, 'dsq'
records.onSession('race')
check(row(board('Club'), 'Guest_C').time == 85.0, 'a disqualified driver sets no record')
host.players[2].status = 'finished'
host.race.pointToPoint = true
records.onSession('race')
check(row(board('Club'), 'Guest_C').time == 85.0, 'nor does a circuit run point to point')
host.race.pointToPoint = false
records.onSession('race')
check(board('Club').laps[1].driver == 'Guest_C' and board('Club').laps[1].time == 80.0,
  'the same lap, classified and run as saved, counts')

-- ---------------------------------------------------------------------------
-- 6. Anyone may look
-- ---------------------------------------------------------------------------
RM_onRecordsRequest(2, '{}')
p = lastPush(2)
check(p and p.layout == 'Club' and p.loaded == 'Club' and p.total == 3, 'a driver gets the loaded layout\'s board')
check(p and p.map == 'gridmap_v2' and p.mapLabel == 'Gridmap v2', 'with the map\'s display name')
check(p and p.file == 'Lap Records/gridmap_v2.json', 'and where it is kept')
RM_onRecordsRequest(2, '{"layout":"Nowhere"}')
check(lastPush(2).layout == 'Club', 'a board that does not exist falls back to the loaded one')

-- ---------------------------------------------------------------------------
-- 7. Hand edits
-- ---------------------------------------------------------------------------
text = read(FILE)
text = text:gsub('"Guest_B"', '"Bob"'):gsub('"driver": "Guest_A", ', '"driver": "Guest_A", "note": "kept", ')
text = text:gsub('"layouts": {', '"layouts": {\n    "Night": [{"driver": "Cara", "time": 99.5}],', 1)
write(FILE, text)
RM_onRecordsRequest(2, '{"layout":"night"}')
p = lastPush(2)
check(p and p.layout == 'Night' and p.laps[1].driver == 'Cara', 'a layout added by hand is shown')
check(#p.layouts == 2, 'and listed beside the others')
RM_onRecordsRequest(2, '{"layout":"Club"}')
check(row({ laps = lastPush(2).laps }, 'Bob'), 'a renamed row shows the next time it is opened')
host.players[0].raceBest = 83.0
records.onSession('race')
local guestA = row(board('Club'), 'Guest_A')
check(guestA and guestA.time == 83.0 and guestA.note == nil, 'an improved row is a new row')
check(row(board('Club'), 'Bob'), 'a write keeps the hand edits it did not touch')
check(board('Night') and board('Night').laps[1].driver == 'Cara', 'including other layouts')

-- A file mid-edit is never written over.
write(FILE, '{ "layouts": oops')
host.players[1].raceBest = 70.0
records.onSession('race')
check(read(FILE) == '{ "layouts": oops', 'a file that does not parse is left exactly as it is')
RM_onRecordsRequest(2, '{}')
check(lastPush(2).error ~= nil, 'and the panel says so')
RM_onRecordsClear(0, '{"layout":"Club"}')
check(read(FILE) == '{ "layouts": oops', 'clearing will not touch it either')
check(said('does not parse', 0), 'and the admin is told why')
write(FILE, text)

-- ---------------------------------------------------------------------------
-- 8. Clearing: the admin tier only
-- ---------------------------------------------------------------------------
RM_onRecordsRemove(2, '{"layout":"Club","driver":"Bob"}')
check(row(board('Club'), 'Bob'), 'a driver cannot remove a time')
RM_onRecordsClear(3, '{"layout":"Club"}')
check(board('Club') ~= nil, 'a moderator cannot clear a board')
RM_onRecordsRemove(0, '{"layout":"club","driver":"bob"}')
check(not row(board('Club'), 'Bob'), 'an admin removes one time, names matched in any case')
check(said('removed Bob 1:23.500 from the "Club" lap records', -1), 'in public')
RM_onRecordsClear(0, '{"layout":"CLUB"}')
check(board('Club') == nil and board('Night') ~= nil, 'Clear Board empties one layout\'s board')
check(lastPush(-1).layout == 'Club' and #lastPush(-1).laps == 0,
  'and the people reading it see it empty, not some other board')
RM_onRecordsClear(0, '{"layout":"Night"}')
check(read(FILE) == nil, 'a map with no records left loses its file')

os.remove(FILE)
print(string.format('records_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
