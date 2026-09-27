-- Headless test for the READY CHECK: calling drivers to the grid, and putting
-- each one on their slot only when they press Ready.
-- Run from the repo root: lua5.3 tests/ready_test.lua
--
-- The complaint it answers: forming the grid teleported every entrant onto a
-- slot and froze them there, whatever they were in the middle of.

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara', [4] = 'Dan' }
local lastState = nil
local gridSent  = {}   -- [pid] = list of RM_GridAssign payloads, in order
local notices   = {}   -- [pid] = last RM_Notice payload
local chats     = {}   -- [pid] = list of chat lines (-1 = everyone)
local timers    = {}
local lastDerby = nil  -- last RM_DerbyUpdate
local lastDrag  = nil  -- RM_DragUpdate, merged the way the panel merges it
local sentTo    = {}   -- [event][pid] = list of payloads, for the derby and drag events

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg)
    chats[target] = chats[target] or {}
    table.insert(chats[target], msg)
  end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
    if event == 'RM_Notice' then notices[target] = payload end
    if event == 'RM_GridAssign' then
      gridSent[target] = gridSent[target] or {}
      table.insert(gridSent[target], payload)
    end
    if event == 'RM_DerbyUpdate' and target == -1 then lastDerby = payload end
    if event == 'RM_DragUpdate' then
      lastDrag = lastDrag or {}
      for k, v in pairs(payload) do lastDrag[k] = v end
    end
    sentTo[event] = sentTo[event] or {}
    sentTo[event][target] = sentTo[event][target] or {}
    table.insert(sentTo[event][target], payload)
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

local ADMIN = 1
local function row(pid)
  for _, d in ipairs(lastState.drivers) do
    if d.id == pid then return d end
  end
end
local function lastSlot(pid)
  local list = gridSent[pid]
  return list and list[#list] or nil
end
local function placed(pid)
  local p = lastSlot(pid)
  return p ~= nil and p.slot ~= nil
end
local function ghosted(pid)
  for _, id in ipairs(lastState.ghostFinished or {}) do
    if id == pid then return true end
  end
  return false
end
local function saidTo(pid, text)
  for _, line in ipairs(chats[pid] or {}) do
    if line:find(text, 1, true) then return true end
  end
  return false
end
local function clearSends() gridSent, notices, chats = {}, {}, {} end

onInit()
RM_onLogin(ADMIN, '{"password":"phoenix"}')
for id in pairs(connected) do RM_onPlayerJoin(id) end

-- ---------------------------------------------------------------------------
-- 1. Forming the grid calls drivers to it; nobody is moved
-- ---------------------------------------------------------------------------
check(lastState.readyCheck == true, 'the ready check is on by default')
clearSends()
RM_onGenerateGrid(ADMIN)
check(lastState.phase == 'grid', 'the grid is formed')
for pid = 1, 4 do
  check(row(pid).status == 'called', connected[pid] .. ' is called to the grid, not placed')
  check(row(pid).gridPos == pid, connected[pid] .. ' already holds a slot')
  check(not placed(pid), connected[pid] .. "'s car is not moved")
  check(row(pid).bystander == true and ghosted(pid),
    connected[pid] .. ' is a ghost while not ready, so a loose car cannot hit the grid')
end
check(saidTo(-1, 'press Ready'), 'chat says how to take a slot')

-- Nobody ready: starting would be a race with nobody in it.
RM_onStartCountdown(ADMIN)
check(lastState.phase == 'grid' and saidTo(ADMIN, 'Nobody is ready'),
  'Start Countdown with nobody ready is refused, and says why')

-- ---------------------------------------------------------------------------
-- 2. Ready, and changing your mind
-- ---------------------------------------------------------------------------
clearSends()
RM_onSetReady(2, '{"ready":true}')
check(row(2).status == 'gridded', 'Bob pressed Ready and is on the grid')
check(placed(2) and lastSlot(2).slot == 2, 'his car is sent to his own slot')
check(lastSlot(2).order == 1 and lastSlot(2).count == 1,
  'a lone ready-up lands at once, not staggered behind the whole field')
check(row(2).bystander == nil and not ghosted(2), 'and he is solid again')

RM_onSetReady(2, '{"ready":false}')
check(row(2).status == 'called' and lastSlot(2).slot == nil,
  'Not ready takes him back off the slot and lets the hold go')
check(ghosted(2), 'as a ghost, so he can drive off through the field')
RM_onSetReady(2, '{"ready":true}')
check(row(2).status == 'gridded', 'and Ready puts him back')

-- Somebody else's Ready is an admin's call only.
RM_onSetReady(3, '{"ready":true,"pid":4}')
check(row(4).status == 'called', 'a driver cannot ready somebody else')
RM_onSetReady(ADMIN, '{"ready":true,"pid":4}')
check(row(4).status == 'gridded' and placed(4), 'an admin can, for a driver whose panel is closed')

-- ---------------------------------------------------------------------------
-- 3. Late arrivals go to the back
-- ---------------------------------------------------------------------------
connected[5] = 'Erin'
RM_onPlayerJoin(5)
check(row(5).status == 'called' and row(5).gridPos == 5,
  'a driver who joins while the grid is called gets the next slot')

RM_onSetSpectating(3, '{"spectating":true}')
check(row(3).status == 'waiting' and row(3).gridPos == nil, 'Cara sits out and gives up her slot')
RM_onSetSpectating(3, '{"spectating":false}')
check(row(3).status == 'called' and row(3).gridPos == 6,
  'rejoining while the grid is called is a slot at the back, not her old one')

-- ---------------------------------------------------------------------------
-- 4. Starting without the drivers who are not ready
-- ---------------------------------------------------------------------------
-- Ready: Bob (2), Dan (4). Not ready: Alice (1), Erin (5), Cara (3).
chats = {}
RM_onSetReady(ADMIN, '{"ready":true}')
check(row(1).status == 'gridded', 'the admin readies their own car like anyone else')
RM_onStartCountdown(ADMIN)
check(lastState.phase == 'countdown', 'the countdown starts with three ready')
for _, pid in ipairs({ 3, 5 }) do
  check(row(pid).status == 'waiting' and row(pid).gridPos == nil,
    connected[pid] .. ' was not ready and sits the session out')
  check(row(pid).bystander == true, connected[pid] .. ' stays a ghost for the race')
  check(notices[pid] and notices[pid].msg:find('without you', 1, true),
    connected[pid] .. ' is told on the HUD')
end
check(saidTo(-1, 'Starting without Cara, Erin'), 'chat names who was left out')
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'racing', 'GO')
for _, pid in ipairs({ 1, 2, 4 }) do
  check(row(pid).status == 'racing', connected[pid] .. ' is racing')
end
check(row(3).status == 'waiting' and row(5).status == 'waiting', 'the other two are not')
RM_onSetReady(3, '{"ready":true}')
check(row(3).status == 'waiting', 'Ready does nothing once the session is running')
RM_onEndRace(ADMIN)

-- ---------------------------------------------------------------------------
-- 5. Ready All, and the everyone-is-ready line
-- ---------------------------------------------------------------------------
connected[5] = nil
RM_onPlayerDisconnect(5)
clearSends()
RM_onGenerateGrid(ADMIN)
check(row(1).status == 'called' and row(3).status == 'called',
  'a new grid calls everyone again, including the drivers who sat the last one out')
for pid = 1, 3 do RM_onSetReady(pid, '{"ready":true}') end
check(not saidTo(ADMIN, 'Everyone is ready'), 'three of four ready is not everyone')
RM_onSetReady(4, '{"ready":true}')
check(saidTo(ADMIN, 'Everyone is ready (4/4)'), 'the admin is told the moment the last one readies')
check(not saidTo(2, 'Everyone is ready'), 'and only the admin: drivers have the count on the panel')
RM_onEndRace(ADMIN)

clearSends()
RM_onGenerateGrid(ADMIN)
RM_onReadyAll(3)
check(row(1).status == 'called', 'a driver cannot press Ready All')
RM_onSetReady(1, '{"ready":true}')
RM_onReadyAll(ADMIN)
for pid = 1, 4 do check(row(pid).status == 'gridded', connected[pid] .. ' is on the grid after Ready All') end
check(lastSlot(1).count == 1, 'Alice was already placed and is not placed twice')
local staggered = true
for _, pid in ipairs({ 2, 3, 4 }) do
  if lastSlot(pid).count ~= 3 then staggered = false end
end
check(staggered, 'Ready All lands the three it placed as one staggered batch')

-- Forming the grid again keeps who is ready.
clearSends()
RM_onGenerateGrid(ADMIN)
check(row(2).status == 'gridded' and placed(2),
  'Generate Grid again over a called grid keeps Ready, and re-places the car')

-- ---------------------------------------------------------------------------
-- 6. Leaving and aborting
-- ---------------------------------------------------------------------------
RM_onSetReady(3, '{"ready":false}')
connected[3] = nil
RM_onPlayerDisconnect(3)
check(row(3) == nil, 'a driver who leaves while not ready is gone, with no DNF')
RM_onEndRace(ADMIN)
check(lastState.phase == 'waiting', 'End Session stands the grid down')
connected[3] = 'Cara'
RM_onPlayerJoin(3)
check(row(3).status == 'waiting', 'joining with no grid being called is joining, not a call')

RM_onGenerateGrid(ADMIN)
RM_onSetReady(2, '{"ready":true}')
RM_onEndRace(ADMIN)
check(row(1).status == 'waiting' and row(1).bystander == nil,
  'standing a called grid down lifts the ghost the call put on')

-- ---------------------------------------------------------------------------
-- 7. Qualifying is called the same way
-- ---------------------------------------------------------------------------
RM_onStartQualifying(ADMIN)
check(row(1).status == 'called' and row(2).status == 'called', 'Start Quali calls the grid too')
RM_onEndRace(ADMIN)

-- ---------------------------------------------------------------------------
-- 8. The switch
-- ---------------------------------------------------------------------------
RM_onSetReadyCheck(2, '{"on":false}')
check(lastState.readyCheck == true, 'a driver cannot turn the ready check off')
RM_onSetReadyCheck(ADMIN, '{"on":false}')
check(lastState.readyCheck == false, 'an admin can')
clearSends()
RM_onGenerateGrid(ADMIN)
for pid = 1, 4 do
  check(row(pid).status == 'gridded' and placed(pid),
    connected[pid] .. ' is placed at once with the ready check off, as before')
end
check(lastSlot(4).count == 4, 'and the whole grid lands staggered, as before')
RM_onSetReady(2, '{"ready":false}')
check(row(2).status == 'gridded', 'Not ready means nothing with the check off')
RM_onEndRace(ADMIN)

-- The back of the grid stops at the last start position.
RM_onSetReadyCheck(ADMIN, '{"on":true}')
RM_onSaveLayout(ADMIN, '{"name":"Three","width":20,"height":8,"depth":2,"confirmDrop":true,'
  .. '"checkpoints":[{"x":0,"y":100,"z":0,"hx":0,"hy":1},{"x":0,"y":200,"z":0,"hx":0,"hy":1}],'
  .. '"startPositions":[{"x":0,"y":0,"z":0,"hx":0,"hy":1},{"x":0,"y":8,"z":0,"hx":0,"hy":1},'
  .. '{"x":0,"y":16,"z":0,"hx":0,"hy":1},{"x":0,"y":24,"z":0,"hx":0,"hy":1}]}')
RM_onLoadLayout(ADMIN, '{"name":"Three"}')
check(lastState.startSlots == 4, 'a layout with four start positions is loaded')
RM_onGenerateGrid(ADMIN)
connected[6] = 'Finn'
chats = {}
RM_onPlayerJoin(6)
check(row(6).status == 'waiting' and row(6).gridPos == nil and saidTo(6, 'grid is full'),
  'a fifth driver on a four-slot grid is told it is full, not given a slot with nowhere to stand')

-- ---------------------------------------------------------------------------
-- 9. The derby is called the same way
-- ---------------------------------------------------------------------------
RM_onEndRace(ADMIN)
local function derbyRow(pid)
  for _, p in ipairs(lastDerby.players or {}) do
    if p.id == pid then return p end
  end
end
local function lastTo(event, pid)
  local list = sentTo[event] and sentTo[event][pid]
  return list and list[#list] or nil
end

sentTo, chats = {}, {}
RM_onDerbyFormUp(ADMIN)
check(lastDerby.derbyPhase == 'forming', 'Form Up forms the derby')
for _, pid in ipairs({ 1, 2, 3, 4, 6 }) do
  check(derbyRow(pid) and derbyRow(pid).ready == false,
    connected[pid] .. ' is called to the derby, not placed')
  check(lastTo('RM_DerbyGridAssign', pid) == nil, connected[pid] .. "'s car is not moved")
end
RM_onDerbyStart(ADMIN)
check(lastDerby.derbyPhase == 'forming' and saidTo(ADMIN, 'Nobody is ready'),
  'Start Derby with nobody ready is refused')

RM_onDerbyReady(2, '{"ready":true}')
local assign = lastTo('RM_DerbyGridAssign', 2)
check(derbyRow(2).ready == true and assign and assign.hold == true
  and assign.order == 1 and assign.count == 1, 'Bob readies: held at once, not staggered')
RM_onDerbyReady(2, '{"ready":false}')
check(derbyRow(2).ready == false and lastTo('RM_DerbyGridAssign', 2).release == true,
  'Not ready lets the hold go')
RM_onDerbyReady(2, '{"ready":true}')
RM_onDerbyReady(3, '{"ready":true,"pid":4}')
check(derbyRow(4).ready == false, 'a driver cannot ready somebody else for the derby')
RM_onDerbyReady(ADMIN, '{"ready":true,"pid":4}')
check(derbyRow(4).ready == true, 'an admin can')

connected[7] = 'Gus'
RM_onPlayerJoin(7)
RM_Derby_onPlayerJoin(7)
check(derbyRow(7) and derbyRow(7).ready == false, 'a driver who joins during Form Up is called too')
connected[6] = nil
RM_onPlayerDisconnect(6)
RM_Derby_onPlayerDisconnect(6)
check(derbyRow(6) == nil, 'a driver who leaves during Form Up is out of the field, not a car-less entry')

-- Ready: Bob (2), Dan (4). Not ready: Alice (1), Cara (3), Gus (7).
chats = {}
RM_onDerbyStart(ADMIN)
check(lastDerby.derbyPhase == 'countdown', 'Start Derby goes with two ready')
for _, pid in ipairs({ 1, 3, 7 }) do
  check(derbyRow(pid) == nil, connected[pid] .. ' was not ready and is not in the derby')
  local fs = lastTo('RM_ForceSpectate', pid)
  check(fs and fs.source == 'derby',
    connected[pid] .. ' is stood down, so nothing loose can drive into the arena')
end
check(saidTo(-1, 'Derby starting without Alice, Cara, Gus'), 'chat names who sat out')
for _ = 1, 3 do RM_DerbyCountdownTick() end
check(lastDerby.derbyPhase == 'running', 'the derby runs with the two who were ready')
sentTo = {}
RM_onDerbyEnd(ADMIN)
for _, pid in ipairs({ 1, 3, 7 }) do
  check(lastTo('RM_ReleaseSpectate', pid) ~= nil, connected[pid] .. ' gets their car back at the end')
end
RM_onDerbyEnd(ADMIN)

-- ---------------------------------------------------------------------------
-- 10. A drag pass is called the same way
-- ---------------------------------------------------------------------------
RM_onSaveLayout(ADMIN, '{"name":"Strip","width":20,"height":8,"depth":2,'
  .. '"pointToPoint":true,"confirmDrop":true,'
  .. '"checkpoints":[{"x":400,"y":0,"z":0,"hx":0,"hy":1},{"x":800,"y":0,"z":0,"hx":0,"hy":1}],'
  .. '"startPositions":[{"x":0,"y":4,"z":0,"hx":0,"hy":1},{"x":0,"y":8,"z":0,"hx":0,"hy":1},'
  .. '{"x":0,"y":12,"z":0,"hx":0,"hy":1},{"x":0,"y":16,"z":0,"hx":0,"hy":1}]}')
RM_onLoadLayout(ADMIN, '{"name":"Strip"}')
RM_onDragSetConfig(ADMIN, '{"stageMode":"hold"}')
local function lane(pid)
  for _, ln in ipairs(lastDrag.current and lastDrag.current.lanes or {}) do
    if ln.id == pid then return ln end
  end
end

sentTo, chats = {}, {}
RM_onDragPractice(ADMIN)
check(lastDrag.dragPhase == 'staging', 'a practice pass is staged')
for _, pid in ipairs({ 1, 2, 3, 4 }) do
  check(lane(pid) and lane(pid).ready == false, connected[pid] .. ' is called to a lane, not placed')
  check(lastTo('RM_DragLane', pid) == nil, connected[pid] .. "'s car is not moved")
end
RM_onDragRun(ADMIN)
check(lastDrag.dragPhase == 'staging' and saidTo(ADMIN, 'Nobody in this pass is ready'),
  'no tree with nobody ready')

RM_onDragReady(2, '{"ready":true}')
local placedLane = lastTo('RM_DragLane', 2)
check(lane(2).ready == true and placedLane and placedLane.lane == lane(2).lane
  and placedLane.order == 1 and placedLane.count == 1, 'Bob readies onto his lane at once')
check(lane(2).staged == true, 'and under hold he is staged the moment he lands')
RM_onDragReady(2, '{"ready":false}')
check(lane(2).ready == false and lane(2).staged == false
  and lastTo('RM_DragLane', 2).release == true, 'Not ready takes him off the strip')
RM_onDragReady(2, '{"ready":true}')
RM_onDragReady(3, '{"ready":true,"pid":1}')
check(lane(1).ready == false, 'a driver cannot ready another lane')
RM_onDragReady(ADMIN, '{"ready":true,"pid":3}')
check(lane(3).ready == true, 'an admin can')

-- Ready: Bob (2), Cara (3). Not ready: Alice (1), Dan (4).
chats = {}
RM_onDragRun(ADMIN)
check(lastDrag.dragPhase == 'tree', 'the tree drops with two ready')
check(lastTo('RM_DragTree', 2) ~= nil and lastTo('RM_DragTree', 3) ~= nil, 'the ready lanes get the tree')
check(lastTo('RM_DragTree', 1) == nil and lastTo('RM_DragTree', 4) == nil, 'the no-shows do not')
for _, pid in ipairs({ 1, 4 }) do
  local fs = lastTo('RM_ForceSpectate', pid)
  check(fs and fs.source == 'drag', connected[pid] .. ' is a no-show, stood down for the pass')
  check(lane(pid).home == true, connected[pid] .. "'s lane is settled with no time")
end
check(saidTo(-1, 'not ready, no-show'), 'chat names the no-shows')
RM_onDragAbort(ADMIN)

-- The courtesy stage with nobody ready waves the pass off instead of scoring it.
RM_onDragSetConfig(ADMIN, '{"stageMode":"rollup","autoStart":true,"stageWait":5}')
chats = {}
RM_onDragPractice(ADMIN)
check(lastDrag.dragPhase == 'staging', 'a roll-up practice pass is staged')
for _ = 1, 40 do RM_DragTick() end
check(lastDrag.dragPhase ~= 'staging' and lastDrag.dragPhase ~= 'tree'
  and lastDrag.dragPhase ~= 'running', 'nobody ready by the courtesy stage: waved off, not run')
check(saidTo(-1, 'nobody was ready'), 'and chat says why')

print(string.format('ready_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
