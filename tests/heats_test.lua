-- Headless test for HEATS AND TRANSFERS in server/RaceManager/main.lua.
--
-- A night run as several short heats and then a feature, with the heat results
-- setting the feature grid. The design claim being tested is that A HEAT IS AN
-- ORDINARY RACE RUN BY A SUBSET OF THE FIELD -- so almost none of the session
-- machinery knows heats exist, and one function (isEntrant) carries the whole
-- idea.
--
-- Three things here are worth the file:
--
--   THE SERPENTINE DRAW. 1st to heat 1, 2nd to heat 2, ... Nth to heat N, then
--   BACK along the row. A straight round-robin puts the fastest drivers on four
--   different poles and the slowest four all at the back of their own heats,
--   which makes the heats incomparable and the transfer worth more out of one
--   than another. The serpentine is what makes them balanced.
--
--   THE ENTRANT FILTER. Only the running heat's drivers are gridded. Everything
--   downstream -- the online purge, the respawn, the entrant count -- reads the
--   same function, so getting this wrong grids the wrong people or nobody.
--
--   THE TRANSFER SURVIVING. Heat results are written into the identity registry
--   as well as onto the record, because Generate Grid purges every record that
--   is not a connected player. A driver who drops out between heat two and the
--   feature must not come back having lost the front-row start they earned.
--
-- Run from the repo root: lua5.3 tests/heats_test.lua

local connected = {}
for i = 0, 12 do connected[i] = (i == 0) and 'Admin' or ('D' .. i) end
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
local function lap(pid) RM_onLap(pid, '{"lapTime":60.0}') end
local function seconds(n)
  for _ = 1, math.floor(n * 10) do RM_Tick() end
end
-- Who was actually put on the grid, in slot order.
local function gridded()
  local out = {}
  for _, d in ipairs(lastState.drivers) do
    if d.gridPos then out[d.gridPos] = d.id end
  end
  local list = {}
  for i = 1, #out do list[#list + 1] = out[i] end
  return list
end
local function gridString() return table.concat(gridded(), ',') end
local function heatOf(pid) return driver(pid) and driver(pid).heat end

onInit()
RM_onLogin(0, '{"password":"phoenix"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
-- The admin runs the night rather than driving it, so the field is 12 drivers.
RM_onSetSpectating(0, '{"spectating":true}')
RM_onSetTotalLaps(0, '{"laps":2}')

-- ---------------------------------------------------------------------------
-- A server that runs no heats is untouched
-- ---------------------------------------------------------------------------
check(lastState.heatCount == 0, 'no heat program by default')
check(lastState.heatCurrent == 0, 'and nothing selected')
RM_onGenerateGrid(0)
check(#gridded() == 12, 'a plain race grids the whole field (got ' .. #gridded() .. ')')
RM_onEndRace(0)

-- ---------------------------------------------------------------------------
-- Configuring the program
-- ---------------------------------------------------------------------------
RM_onSetHeats(5, '{"count":3,"transfer":2}')
check(lastState.heatCount == 0, 'configuring heats requires authentication')

RM_onSetHeats(0, '{"count":3,"transfer":2}')
check(lastState.heatCount == 3, 'three heats')
check(lastState.heatTransfer == 2, 'top two transfer from each')

RM_onSetHeats(0, '{"count":999,"transfer":2}')
check(lastState.heatCount <= 12, 'the heat count is capped, so a typo is not a hang')
RM_onSetHeats(0, '{"count":3,"transfer":2}')

-- Heats order is not an answer until a program exists.
chatClear()
RM_onSetHeats(0, '{"count":0,"transfer":0}')
RM_onSetGridMode(0, '{"mode":"heats"}')
check(lastState.gridMode ~= 'heats', 'heats grid order is refused with no program behind it')
check(chatHas('needs a heat program'), 'and says what is missing')
RM_onSetHeats(0, '{"count":3,"transfer":2}')

-- ---------------------------------------------------------------------------
-- The draw
-- ---------------------------------------------------------------------------
chatClear()
RM_onDrawHeats(0)
check(lastState.heatsDrawn == true, 'the field is drawn')
check(chatHas('HEATS DRAWN'), 'and the server says so')

-- Every driver is in exactly one heat, and the heats are within one car of each
-- other in size -- 12 drivers into 3 heats is 4, 4, 4.
local sizes = { 0, 0, 0 }
for pid = 1, 12 do
  local h = heatOf(pid)
  check(h ~= nil and h >= 1 and h <= 3, 'D' .. pid .. ' is in a heat (got ' .. tostring(h) .. ')')
  if h then sizes[h] = sizes[h] + 1 end
end
check(sizes[1] == 4 and sizes[2] == 4 and sizes[3] == 4,
  'twelve drivers split evenly into three heats (got '
    .. table.concat(sizes, '/') .. ')')

-- THE SERPENTINE. With no qualifying times the draw falls back to join order,
-- which is D1..D12 -- so the pattern is checkable exactly:
--   out:  D1->H1  D2->H2  D3->H3
--   back: D4->H3  D5->H2  D6->H1
--   out:  D7->H1  D8->H2  D9->H3   ...
-- A straight round-robin would give D1,D4,D7,D10 all to heat 1, putting the
-- four fastest drivers in one heat and the four slowest in another.
check(heatOf(1) == 1 and heatOf(2) == 2 and heatOf(3) == 3,
  'the draw goes out along the row')
check(heatOf(4) == 3 and heatOf(5) == 2 and heatOf(6) == 1,
  'and back along it, which is what balances the heats')
check(heatOf(7) == 1 and heatOf(8) == 2 and heatOf(9) == 3,
  'and out again for the next pass')
check(heatOf(1) ~= heatOf(4), 'so the two quickest drivers are NOT in the same heat')

RM_onSetHeats(0, '{"count":2,"transfer":1}')
check(lastState.heatCount == 2, 'the program can be reconfigured before a heat is run')
RM_onSetHeats(0, '{"count":3,"transfer":2}')
RM_onDrawHeats(0)

-- ---------------------------------------------------------------------------
-- Running heat 1: only heat 1 is gridded
-- ---------------------------------------------------------------------------
check(lastState.heatCurrent == 1, 'the draw selects heat 1 to run first')
RM_onGenerateGrid(0)
local g = gridded()
check(#g == 4, 'heat 1 grids four cars, not the whole field (got ' .. #g .. ')')
for _, pid in ipairs(g) do
  check(heatOf(pid) == 1, 'D' .. pid .. ' is gridded and is in heat 1')
end
check(lastState.entrants == 4, 'and the entrant count is the heat, not the night')

RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'heat 1 is running')

-- Two laps each, in an order we choose: the first driver home wins the heat.
local h1 = {}
for pid = 1, 12 do if heatOf(pid) == 1 then h1[#h1 + 1] = pid end end
table.sort(h1)
chatClear()
for _ = 1, 2 do
  for _, pid in ipairs(h1) do lap(pid) end
end
seconds(7)      -- past the end-of-race hold
check(lastState.phase == 'finished' or lastState.phase == 'waiting',
  'heat 1 is over')
check(chatHas('HEAT 1 COMPLETE'), 'and the field is told how many transferred')

check(driver(h1[1]).heatPos == 1, 'the first car home won the heat')
check(driver(h1[1]).transferred == true, 'and transferred')
check(driver(h1[2]).transferred == true, 'as did second, with a transfer of two')
check(driver(h1[3]).transferred == false, 'third did not')
check(driver(h1[4]).transferred == false, 'nor fourth')

-- A driver in another heat has no position in this one. The classification is
-- built from every record the server holds, so this is the check that the heat
-- filter on the result is real.
local other = nil
for pid = 1, 12 do if heatOf(pid) == 2 then other = pid break end end
check(driver(other).heatPos == nil,
  'a driver waiting for heat 2 was given no position in heat 1')
check(driver(other).transferred == nil, 'and no transfer out of it')

-- ---------------------------------------------------------------------------
-- Heats 2 and 3
-- ---------------------------------------------------------------------------
local function runHeat(h)
  RM_onSetHeatCurrent(0, '{"heat":' .. h .. '}')
  check(lastState.heatCurrent == h, 'heat ' .. h .. ' is selected')
  RM_onGenerateGrid(0)
  check(#gridded() == 4, 'heat ' .. h .. ' grids four cars')
  RM_onStartCountdown(0)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
  local field = {}
  for pid = 1, 12 do if heatOf(pid) == h then field[#field + 1] = pid end end
  table.sort(field)
  for _ = 1, 2 do
    for _, pid in ipairs(field) do lap(pid) end
  end
  seconds(7)
  return field
end
local h2 = runHeat(2)
local h3 = runHeat(3)

-- ---------------------------------------------------------------------------
-- The feature: the whole field, gridded by the transfers
-- ---------------------------------------------------------------------------
RM_onSetHeatCurrent(0, '{"heat":0}')
check(lastState.heatCurrent == 0, 'the feature is selected')
RM_onSetGridMode(0, '{"mode":"heats"}')
check(lastState.gridMode == 'heats', 'the feature is gridded by the heat results')

RM_onGenerateGrid(0)
local feature = gridded()
check(#feature == 12, 'the feature grids the WHOLE field, not just one heat (got '
  .. #feature .. ')')

-- THE FRONT ROWS ARE THE HEAT WINNERS, then all the seconds. Interleaved by
-- heat, which is what makes a heat win worth having and stops one strong heat
-- filling the whole front of the grid.
local p1, p2, p3 = feature[1], feature[2], feature[3]
check(driver(p1).heatPos == 1 and driver(p2).heatPos == 1 and driver(p3).heatPos == 1,
  'the first three starters are the three heat winners')
check(driver(p1).heat ~= driver(p2).heat and driver(p2).heat ~= driver(p3).heat,
  'one from each heat, rather than one heat filling the front')
local p4, p5, p6 = feature[4], feature[5], feature[6]
check(driver(p4).heatPos == 2 and driver(p5).heatPos == 2 and driver(p6).heatPos == 2,
  'then the three second-place finishers')

-- ...and everyone who did NOT transfer still races, behind those who did.
for i = 1, 6 do
  check(driver(feature[i]).transferred == true,
    'slot ' .. i .. ' went to a driver who transferred')
end
for i = 7, 12 do
  check(driver(feature[i]).transferred == false,
    'slot ' .. i .. ' went to a driver who did not, and who is still racing')
end

-- ---------------------------------------------------------------------------
-- A transfer survives a driver dropping out and coming back
-- ---------------------------------------------------------------------------
-- Generate Grid purges every record that is not a connected player, so without
-- the identity registry a driver who reconnects between the last heat and the
-- feature loses the heat they were drawn into and the front-row start they
-- earned in it -- and is gridded at the back with no explanation.
local winner = p1
check(driver(winner).transferred == true, 'the heat 1 winner transferred')
RM_onPlayerDisconnect(winner)
RM_onPlayerJoin(winner)
RM_onGenerateGrid(0)
check(driver(winner) ~= nil, 'they are back in the field')
check(driver(winner).heat ~= nil, 'with the heat they were drawn into')
check(driver(winner).heatPos == 1, 'and the heat they won')
check(driver(winner).transferred == true, 'and the transfer they earned')
check(gridded()[1] == winner or driver(winner).gridPos <= 3,
  'gridded on the front row again, not at the back (P'
    .. tostring(driver(winner).gridPos) .. ')')
RM_onEndRace(0)

-- ---------------------------------------------------------------------------
-- Ending the program
-- ---------------------------------------------------------------------------
RM_onSetHeats(0, '{"count":0,"transfer":0}')
check(lastState.heatCount == 0, 'the program is off')
check(lastState.heatCurrent == 0, 'nothing is still pointing into it')
check(lastState.heatsDrawn == false, 'and the draw is forgotten')
check(lastState.gridMode ~= 'heats',
  'the grid mode falls back rather than ordering by results that no longer exist')
for pid = 1, 12 do
  check(driver(pid).heat == nil, 'D' .. pid .. ' is in no heat any more')
end
RM_onGenerateGrid(0)
check(#gridded() == 12, 'and Generate Grid is back to the whole field')
RM_onEndRace(0)

-- ---------------------------------------------------------------------------
-- Qualifying is never split into heats
-- ---------------------------------------------------------------------------
-- The draw is made FROM qualifying times, so a qualifying session that only let
-- one heat out would be drawing heats from times set by the drivers it had
-- already drawn.
RM_onSetHeats(0, '{"count":3,"transfer":2}')
RM_onDrawHeats(0)
RM_onSetHeatCurrent(0, '{"heat":2}')
RM_onStartQualifying(0)
check(#gridded() == 12,
  'qualifying grids the WHOLE field with a heat selected (got ' .. #gridded() .. ')')
RM_onEndRace(0)

-- ---------------------------------------------------------------------------
-- Reset Session ends the night
-- ---------------------------------------------------------------------------
RM_onResetLeaderboard(0)
check(lastState.heatCount == 0, 'Reset Session ends the heat program')
check(lastState.heatsDrawn == false, 'and the draw with it')
check(lastState.heatCurrent == 0, 'leaving nothing pointing into a heat nobody is in')

if fails == 0 then
  print(string.format('heats_test: %d checks, 0 failures', checks))
else
  print(string.format('heats_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
