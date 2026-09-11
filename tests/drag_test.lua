-- Headless test for the DRAG RACING module (server/RaceManager/drag.lua),
-- run against the real server plugin in Lua 5.3, the same as BeamMP.
-- Run from the repo root: lua5.3 tests/drag_test.lua
--
-- The whole tournament is bookkeeping over an entrant list, so all of it is
-- testable with no vehicle, no physics and no client: a sixteen-car ladder runs
-- to a champion here without anything existing.
--
-- The drag ladder is an isolated module, so this also asserts that a full
-- tournament leaves the circuit racing state machine completely untouched.

local connected = {}
local lastState = nil    -- last RM_Update payload (circuit racing)
-- RM_DragUpdate MERGED, not replaced, exactly as the UI does it. A lane
-- reporting its time sends the live pass and leaves the ladder, the entrants
-- and the rules out, because none of them changed -- so a harness that replaced
-- the whole table would read a config the server never unset as absent, and so
-- would a panel written the same way. Holding the last value here is the same
-- contract the app.js handler keeps, tested by being depended on.
local lastDrag  = nil    -- accumulated RM_DragUpdate state
local lastDragRaw = nil  -- ...and the payload of the LAST one, unmerged
local laneAssign = {}    -- [pid] = last RM_DragLane payload
local treeSent   = {}    -- [pid] = last RM_DragTree payload
local spectated  = {}    -- [pid] = last RM_ForceSpectate payload
local released   = {}    -- [pid] = last RM_ReleaseSpectate payload (-1 = everyone)
local lastCup  = nil     -- last RM_CupUpdate payload (championship standings)
local lastChat = nil
local timers = {}
local hostedMap = '/levels/gridmap_v2/info.json'

for i = 1, 16 do connected[i] = 'Driver' .. i end

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) lastChat = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update'        then lastState = payload end
    if event == 'RM_DragUpdate' then
      lastDragRaw = payload
      if lastDrag == nil then
        lastDrag = payload
      else
        for k, v in pairs(payload) do lastDrag[k] = v end
      end
    end
    if event == 'RM_DragLane'      then laneAssign[target] = payload end
    if event == 'RM_DragTree'      then treeSent[target] = payload end
    if event == 'RM_CupUpdate'       then lastCup = payload end
    if event == 'RM_ForceSpectate'   then spectated[target] = payload end
    if event == 'RM_ReleaseSpectate' then released[target] = payload end
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

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
local ADMIN = 1

local function login(pid)
  RM_onLogin(pid, '{"password":"phoenix"}')
end

-- The drag strip: a point-to-point layout with two gates (a start line and a
-- finish line) and eight start positions. Nothing about it is drag-specific --
-- it is an ordinary sprint stage, which is the whole reuse.
local function loadStrip(startCount)
  local cps, starts = {}, {}
  for i = 1, 2 do
    cps[#cps + 1] = string.format('{"x":%d,"y":0,"z":0,"hx":0,"hy":1}', i * 400)
  end
  for i = 1, startCount do
    starts[#starts + 1] = string.format('{"x":0,"y":%d,"z":0,"hx":0,"hy":1}', i * 4)
  end
  RM_onSaveLayout(ADMIN, '{"name":"Test Strip","width":20,"height":8,"depth":2,'
    .. '"pointToPoint":true,"confirmDrop":true,'
    .. '"checkpoints":[' .. table.concat(cps, ',') .. '],'
    .. '"startPositions":[' .. table.concat(starts, ',') .. ']}')
  RM_onLoadLayout(ADMIN, '{"name":"Test Strip"}')
end

local function config(fields)
  RM_onDragSetConfig(ADMIN, fields)
end

local function entrantBySeed(seed)
  for _, e in ipairs(lastDrag.entrants) do
    if e.seed == seed then return e end
  end
end

-- Run the tree out. The pre-roll is randomised between 1.5s and 2.5s and the
-- lights add up to 1.5s at most, so the longest tree is 4.0s -- sixteen
-- quarter-second ticks EXACTLY, which is no margin at all. Twenty-four, so a
-- pre-roll that is retuned upward does not turn every assertion below it into a
-- failure with nothing to do with what it was testing.
local function runTree()
  for _ = 1, 24 do
    if lastDrag.dragPhase ~= 'tree' then break end
    RM_DragTick()
  end
end

-- Hold the result up for its cool-down, then let the ladder move on.
local function clearResult()
  for _ = 1, 60 do
    if lastDrag.dragPhase ~= 'result' then break end
    RM_DragTick()
  end
end

-- The pass the ladder is pointing at, as the panel sees it.
local function current()
  return lastDrag.current
end

-- The player id behind a seed, which the board deliberately does not carry --
-- entrants are people, not sessions. Resolved here from the draw order.
local seedToPid = {}

local function reportRun(seed, run)
  local pid = seedToPid[seed]
  local parts = {}
  if run.rt    then parts[#parts + 1] = string.format('"rt":%.4f', run.rt) end
  if run.et    then parts[#parts + 1] = string.format('"et":%.4f', run.et) end
  if run.speed then parts[#parts + 1] = string.format('"speed":%.2f', run.speed) end
  if run.foul  then parts[#parts + 1] = '"foul":true' end
  RM_onDragResult(pid, '{' .. table.concat(parts, ',') .. '}')
end

-- Stage, run, report every lane, and let the result clear. `runFor(seed, lane)`
-- returns the pass that lane made.
local function pass(runFor)
  RM_onDragStage(ADMIN)
  local lanes = {}
  for i, l in ipairs(current().lanes) do lanes[i] = l end
  RM_onDragRun(ADMIN)
  runTree()
  for i, l in ipairs(lanes) do
    local run = runFor(l.seed, i, l)
    if run then reportRun(l.seed, run) end
  end
  -- A lane that reported nothing is a DNF, which only lands when the pass runs
  -- out of time.
  if lastDrag.dragPhase == 'running' then
    for _ = 1, math.ceil((lastDrag.timeout + 8) / 0.25) do
      if lastDrag.dragPhase ~= 'running' then break end
      RM_DragTick()
    end
  end
  clearResult()
  return lanes
end

-- Build a ladder and remember which player id each seed landed on, which is
-- the only thing the test needs that the board does not carry.
local function build()
  RM_onDragBuild(ADMIN, '')
  seedToPid = {}
  -- 'order' seeding is pid ascending, so the seed IS the player id. Every test
  -- below builds under it for exactly that reason; the random and quali draws
  -- are asserted separately.
  for _, e in ipairs(lastDrag.entrants) do
    for pid, name in pairs(connected) do
      if name == e.name then seedToPid[e.seed] = pid end
    end
  end
end

local function fieldOf(n)
  connected = {}
  for i = 1, n do connected[i] = 'Driver' .. i end
end

-- Everybody runs a clean, ordered pass: lane 1 quickest, lane 2 next, and so
-- on. Deterministic, so an assertion about who advances is an assertion about
-- the ladder and not about a coin toss.
local function byLane(seed, lane)
  return { rt = 0.100 + lane * 0.001, et = 10.000 + lane * 0.100, speed = 130 - lane }
end

-- ---------------------------------------------------------------------------
print('--- setup ---')
-- ---------------------------------------------------------------------------
login(ADMIN)
loadStrip(8)
RM_onDragRequestState(ADMIN)
check(lastDrag ~= nil, 'a state request answers')
check(lastDrag.dragPhase == 'idle', 'no ladder yet')
check(lastDrag.stripLanes == 8, 'the strip reports its eight start positions')
check(lastDrag.stripGates == 2, 'the strip reports its two gates')

-- ---------------------------------------------------------------------------
print('--- refusals ---')
-- ---------------------------------------------------------------------------
RM_onDragBuild(2, '')   -- not an admin
check(lastDrag.dragPhase == 'idle', 'a non-admin cannot build a ladder')
RM_onDragStage(ADMIN)
check(lastDrag.dragPhase == 'idle', 'Stage does nothing without a ladder')
RM_onDragRun(ADMIN)
check(lastDrag.dragPhase == 'idle', 'Run does nothing without a ladder')

-- ---------------------------------------------------------------------------
print('--- single elimination, eight cars, two lanes ---')
-- ---------------------------------------------------------------------------
fieldOf(8)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","tree":"pro",'
  .. '"holdResult":1,"timeout":30}')
build()
check(#lastDrag.entrants == 8, 'eight entrants')
check(lastDrag.roundLabel == 'Round 1', 'the first of three rounds is Round 1')
check(lastDrag.passCount == 4, 'eight cars over two lanes is four passes')
-- The classic sheet: 1 v 8, 2 v 7, 3 v 6, 4 v 5.
local sheet = {}
for _, r in ipairs(lastDrag.board[1].passes) do
  sheet[#sheet + 1] = r.lanes[1].seed .. 'v' .. r.lanes[2].seed
end
check(table.concat(sheet, ' ') == '1v8 2v7 3v6 4v5',
  'the draw pairs top seed with bottom seed: ' .. table.concat(sheet, ' '))

-- Round 1: the higher seed wins every pass.
for _ = 1, 4 do
  pass(function (seed, lane) return byLane(seed, lane) end)
end
check(lastDrag.roundLabel == 'Semifinal', 'four left over two lanes is the semifinal')
check(lastDrag.passCount == 2, 'the semifinal is two passes')
check(entrantBySeed(8).status == 'out', 'seed 8 is out')
check(entrantBySeed(8).outRound == 1, 'seed 8 went out in round 1')
check(entrantBySeed(1).status == 'in', 'seed 1 is still in')
check(entrantBySeed(1).wins == 1, 'seed 1 has one win')

for _ = 1, 2 do pass(byLane) end
check(lastDrag.roundLabel == 'Final', 'two left is the final')
check(lastDrag.passCount == 1, 'the final is one pass')
pass(byLane)
check(lastDrag.dragPhase == 'complete', 'the ladder is complete')
check(lastDrag.champion ~= nil, 'somebody won it: ' .. tostring(lastDrag.champion))
check(#lastDrag.finishOrder == 8, 'the finishing order holds the whole field')
check(lastDrag.finishOrder[1].name == lastDrag.champion, 'the champion is first')
check(lastDrag.finishOrder[1].wins == 3, 'the champion won three passes')

-- Nothing the ladder did touched the circuit racing state machine.
check(lastState == nil or lastState.phase == 'waiting',
  'a whole tournament leaves the racing phase alone')

-- ---------------------------------------------------------------------------
print('--- byes ---')
-- ---------------------------------------------------------------------------
fieldOf(5)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0}')
build()
check(lastDrag.passCount == 3, 'five cars over two lanes is three passes')
local byes = 0
for _, p in ipairs(lastDrag.board[1].passes) do if p.bye then byes = byes + 1 end end
check(byes == 1, 'exactly one bye')
check(lastDrag.board[1].passes[1].bye, 'the bye is the first pass')
check(lastDrag.board[1].passes[1].lanes[1].seed == 1, 'the top seed gets the bye')

-- A bye run advances even when the car never gets there. Drag racing has always
-- worked that way, and it is the reason the bye is a real pass at all.
pass(function () return nil end)
check(entrantBySeed(1).status == 'in', 'a bye advances on a DNF')
check(entrantBySeed(1).passes == 1, 'and it still counts as a pass run')

-- ---------------------------------------------------------------------------
print('--- eight wide, top four through ---')
-- ---------------------------------------------------------------------------
fieldOf(16)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":8,"advance":4,"seed":"order","holdResult":0}')
build()
check(lastDrag.lanes == 8, 'eight lanes')
check(lastDrag.passCount == 2, 'sixteen cars over eight lanes is two passes')
check(#lastDrag.board[1].passes[1].lanes == 8, 'eight cars on the line')
pass(byLane)
pass(byLane)
check(#lastDrag.entrants == 16, 'the entrant list does not shrink')
local through = 0
for _, e in ipairs(lastDrag.entrants) do if e.status == 'in' then through = through + 1 end end
check(through == 8, 'top four of each pass is eight through, got ' .. through)
check(lastDrag.passCount == 1, 'eight left over eight lanes is one pass')
check(lastDrag.roundLabel == 'Final', 'and that pass is the final')
pass(byLane)
check(lastDrag.dragPhase == 'complete', 'an eight-wide shootout completes')
check(lastDrag.champion ~= nil, 'and crowns somebody')

-- ---------------------------------------------------------------------------
print('--- double elimination ---')
-- ---------------------------------------------------------------------------
fieldOf(4)
RM_onDragClear(ADMIN)
config('{"format":"double","lanes":2,"advance":1,"seed":"order","holdResult":0}')
build()
check(lastDrag.passCount == 2, 'four cars over two lanes is two passes')
-- Round 1: seeds 1 and 2 win, so 3 and 4 go to the losers bracket rather than
-- home. The draw is 1v4 and 2v3.
pass(function (seed, lane) return byLane(seed, lane) end)
pass(function (seed, lane) return byLane(seed, lane) end)
check(entrantBySeed(4).status == 'in', 'a first loss does not knock you out')
check(entrantBySeed(4).losses == 1, 'but it is recorded')
check(lastDrag.roundSide == 'l', 'the losers bracket runs next')
check(lastDrag.roundLabel:find('Losers'), 'and says so: ' .. lastDrag.roundLabel)

pass(byLane)   -- the losers pass: one of them goes home for good
local gone = 0
for _, e in ipairs(lastDrag.entrants) do if e.status == 'out' then gone = gone + 1 end end
check(gone == 1, 'a second loss is the end of it, got ' .. gone .. ' out')
check(lastDrag.roundSide == 'w', 'then the winners bracket comes back round')

pass(byLane)   -- the winners final: seed 1 v seed 2, and the loser drops
check(lastDrag.roundSide == 'l', 'losing the winners final drops you, it does not end you')
check(entrantBySeed(2).status == 'in', 'seed 2 is still alive on one loss')
check(entrantBySeed(2).losses == 1, 'with exactly one')

pass(byLane)   -- the losers final decides who meets the undefeated one
check(lastDrag.roundLabel == 'Final', 'and now the final: ' .. lastDrag.roundLabel)
check(#current().lanes == 2, 'two cars in it')

-- Lane 2 takes the final, so the entrant who arrived undefeated has spent the
-- second life the format promised them and the two of them go again.
pass(function (seed, lane)
  return lane == 2
    and { rt = 0.100, et = 10.000, speed = 130 }
    or  { rt = 0.200, et = 11.000, speed = 128 }
end)
check(lastDrag.dragPhase ~= 'complete', 'losing the final undefeated is not the end')
check(lastDrag.roundLabel == 'Final (reset)', 'it is a reset: ' .. tostring(lastDrag.roundLabel))
pass(byLane)
check(lastDrag.dragPhase == 'complete', 'the reset decides it')
check(lastDrag.champion ~= nil, 'and crowns somebody')

-- ---------------------------------------------------------------------------
print('--- the tree, the lanes and the red light ---')
-- ---------------------------------------------------------------------------
fieldOf(2)
RM_onDragClear(ADMIN)
-- HOLD staging explicitly: this section is about the tree, the lanes and the
-- red light, and it wants the field placed and frozen rather than creeping.
-- The default is roll-up, so a test that assumes the older procedure has to
-- ask for it.
config('{"format":"single","lanes":2,"advance":1,"seed":"order","tree":"sportsman",'
  .. '"holdResult":0,"timeout":30,"stageMode":"hold"}')
build()
laneAssign, treeSent = {}, {}
RM_onDragStage(ADMIN)
check(lastDrag.dragPhase == 'staging', 'Stage stages')
check(laneAssign[1] and laneAssign[1].slot == 1, 'lane one gets start position one')
check(laneAssign[2] and laneAssign[2].slot == 2, 'lane two gets start position two')
check(laneAssign[1].hold == true, 'and is held for the tree')
check(treeSent[1] == nil, 'the tree has not dropped yet')
RM_onDragRun(ADMIN)
check(lastDrag.dragPhase == 'tree', 'Run drops the tree')
check(treeSent[1] and treeSent[1].pattern == 'sportsman', 'the pattern goes to the client')
check(treeSent[1].preroll >= 1.5 and treeSent[1].preroll <= 2.5,
  'with a randomised pre-roll long enough for the widest field to land')
check(treeSent[1].preroll == treeSent[2].preroll, 'and both lanes get the SAME tree')
runTree()
check(lastDrag.dragPhase == 'running', 'the tree runs out into the pass')

-- Lane 1 red-lights and still runs the quicker time. It loses anyway.
reportRun(1, { rt = -0.050, et = 9.500, speed = 140, foul = true })
reportRun(2, { rt = 0.180, et = 10.500, speed = 135 })
check(lastDrag.dragPhase == 'result', 'both lanes home settles the pass')
local won = lastDrag.board[1].passes[1]
check(won.winner == entrantBySeed(2).name, 'the clean run beats the red light')
check(won.lanes[1].foul == true, 'and the red light is on the board')
check(entrantBySeed(1).bestET == 9.5, 'a red light still puts its ET on the record')
check(entrantBySeed(1).bestRT == nil, 'but never on the reaction record')

-- ALL THREE NUMBERS REACH THE CHAT. The trap speed used to stop at the
-- driver's own screen, which is the one place the people arguing about it are
-- not looking.
check(lastChat and lastChat:find('RT 0.180', 1, true), 'the chat line carries the light')
check(lastChat and lastChat:find('ET 10.500', 1, true), 'and the elapsed time')
check(lastChat and lastChat:find('135.0 mph', 1, true),
  'and the trap speed: ' .. tostring(lastChat))
clearResult()
check(lastDrag.dragPhase == 'complete', 'a two-car ladder is one pass long')

-- ---------------------------------------------------------------------------
print('--- dial-ins, handicap starts and breaking out ---')
-- ---------------------------------------------------------------------------
fieldOf(2)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","dialIn":true,'
  .. '"breakout":true,"holdResult":0,"timeout":30}')
build()
RM_onDragSetDial(1, '{"dial":12.000}')   -- the slow car
RM_onDragSetDial(2, '{"dial":10.000}')   -- the quick one
check(entrantBySeed(1).dial == 12.0, 'a driver can set their own dial')
check(entrantBySeed(2).dial == 10.0, 'and so can the other one')
RM_onDragSetDial(2, '{"seed":1,"dial":11.500}')
check(entrantBySeed(1).dial == 12.0, 'a non-admin cannot set somebody else\'s dial')
RM_onDragSetDial(ADMIN, '{"seed":1,"dial":11.500}')
check(entrantBySeed(1).dial == 11.5, 'an admin can')
RM_onDragSetDial(ADMIN, '{"seed":1,"dial":12.000}')

laneAssign = {}
RM_onDragStage(ADMIN)
check(math.abs(laneAssign[1].delay) < 1e-9, 'the slower dial leaves first, with no delay')
check(math.abs(laneAssign[2].delay - 2.0) < 1e-9,
  'the quicker dial waits the difference out: ' .. tostring(laneAssign[2].delay))
RM_onDragRun(ADMIN)
runTree()
-- Both run their number exactly. Lane 1 gets there at 0.1 + 12.0 = 12.1 from
-- the green; lane 2 at 2.0 + 0.1 + 10.0 = 12.1. A dead heat broken by the lane,
-- which is the point of the format: the cars are equal and the drivers are not.
reportRun(1, { rt = 0.100, et = 12.000, speed = 110 })
reportRun(2, { rt = 0.300, et = 10.000, speed = 130 })
local dial = lastDrag.board[1].passes[1]
check(dial.winner == entrantBySeed(1).name,
  'a slower car on its dial beats a quicker car that sat there: ' .. tostring(dial.winner))
clearResult()

fieldOf(2)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","dialIn":true,'
  .. '"breakout":true,"holdResult":0,"timeout":30}')
build()
RM_onDragSetDial(1, '{"dial":11.000}')
RM_onDragSetDial(2, '{"dial":11.000}')
RM_onDragStage(ADMIN)
RM_onDragRun(ADMIN)
runTree()
reportRun(1, { rt = 0.100, et = 10.500, speed = 140 })   -- half a second under
reportRun(2, { rt = 0.400, et = 11.400, speed = 132 })   -- slower, but legal
local bo = lastDrag.board[1].passes[1]
check(bo.lanes[1].brokeOut == true, 'running under your own dial is a breakout')
check(bo.winner == entrantBySeed(2).name,
  'and a breakout loses to a legal run however quick it was: ' .. tostring(bo.winner))
clearResult()

-- ---------------------------------------------------------------------------
print('--- points shootout ---')
-- ---------------------------------------------------------------------------
fieldOf(8)
RM_onDragClear(ADMIN)
config('{"format":"points","lanes":4,"seed":"order","cut":2,"rounds":3,'
  .. '"holdResult":0,"timeout":30}')
build()
check(lastDrag.roundLabel == 'Round 1 of 3', 'the shootout counts its rounds: '
  .. tostring(lastDrag.roundLabel))
check(lastDrag.passCount == 2, 'eight cars over four lanes is two passes')
pass(byLane)
pass(byLane)
local left = 0
for _, e in ipairs(lastDrag.entrants) do if e.status == 'in' then left = left + 1 end end
check(left == 6, 'the cut takes two off the bottom, got ' .. left .. ' left')
check(lastDrag.roundLabel == 'Round 2 of 3', 'and round two follows')
local top = nil
for _, e in ipairs(lastDrag.entrants) do
  if not top or e.points > top.points then top = e end
end
check(top.points == 4, 'winning a pass on a four-lane strip is four points, got '
  .. tostring(top and top.points))

-- ---------------------------------------------------------------------------
print('--- waving a pass off ---')
-- ---------------------------------------------------------------------------
fieldOf(4)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0}')
build()
RM_onDragStage(ADMIN)
RM_onDragRun(ADMIN)
runTree()
RM_onDragAbort(ADMIN)
check(lastDrag.dragPhase == 'ready', 'an abort puts the ladder back to ready')
check(lastDrag.passIndex == 1, 'and offers the SAME pass again, not the next one')
check(lastDrag.board[1].passes[1].done ~= true, 'the pass is not marked run')
pass(byLane)
check(lastDrag.board[1].passes[1].done == true, 'and runs properly the second time')

-- ---------------------------------------------------------------------------
print('--- withdrawals and disconnects ---')
-- ---------------------------------------------------------------------------
fieldOf(4)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0,"timeout":10}')
build()
RM_onDragWithdraw(ADMIN, '{"seed":4}')
check(entrantBySeed(4).status == 'withdrawn', 'an admin can pull an entrant')
-- Seed 4 was drawn against seed 1. The pass still runs; the empty lane is DNF
-- from the moment it is staged rather than holding the pass open to its
-- timeout.
RM_Drag_onPlayerDisconnect(seedToPid[4])
connected[seedToPid[4]] = nil
RM_onDragStage(ADMIN)
RM_onDragRun(ADMIN)
runTree()
reportRun(1, { rt = 0.100, et = 10.000, speed = 130 })
check(lastDrag.dragPhase == 'result', 'a disconnected lane does not hold the pass open')
check(lastDrag.board[1].passes[1].winner == entrantBySeed(1).name,
  'and the car that turned up takes it')
clearResult()

-- ---------------------------------------------------------------------------
print('--- a lane report does not resend the ladder ---')
-- ---------------------------------------------------------------------------
-- Eight lanes reporting inside fifteen seconds is eight broadcasts, and a
-- sixty-four car ladder is a hundred and twenty-six lane rows. Pinned, because
-- the cheap version of this is one line away from the expensive one and nothing
-- about the panel would look different if it regressed.
fieldOf(4)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0,"timeout":30}')
build()
RM_onDragStage(ADMIN)
-- The lanes of THIS pass, not seeds 1 and 2: the draw pairs top with bottom, so
-- pass one is 1 v 4 and reporting for seed 2 reports for a car that is not on
-- the strip.
local inPass = { current().lanes[1].seed, current().lanes[2].seed }
RM_onDragRun(ADMIN)
runTree()
reportRun(inPass[1], { rt = 0.100, et = 10.000, speed = 130 })
check(lastDragRaw.board == nil, 'a lane report leaves the ladder out')
check(lastDragRaw.entrants == nil, 'and the entrant list')
check(lastDragRaw.current ~= nil, 'and carries the pass, which is what changed')
check(lastDragRaw.rmProtocol ~= nil, 'and is still stamped, or every client drops it')
reportRun(inPass[2], { rt = 0.200, et = 11.000, speed = 128 })
check(lastDragRaw.board ~= nil, 'the pass settling sends the whole board again')
clearResult()

-- ---------------------------------------------------------------------------
print('--- the strip is closed for a pass, and only for a pass ---')
-- ---------------------------------------------------------------------------
-- A derby stands an eliminated driver down until it ends, minutes later. A
-- ladder runs for an hour, so being knocked out in round one must not cost
-- somebody their car for the next forty minutes. What is enforced is the STRIP,
-- and only while there are cars on it.
fieldOf(4)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0,"timeout":30}')
build()
spectated, released = {}, {}
RM_onDragStage(ADMIN)
local onStrip = {}
for _, l in ipairs(current().lanes) do onStrip[seedToPid[l.seed]] = true end
local stoodDown, onLine = 0, 0
for pid in pairs(connected) do
  if spectated[pid] then stoodDown = stoodDown + 1 end
  if onStrip[pid] and spectated[pid] then onLine = onLine + 1 end
end
check(stoodDown == 2, 'everybody not in the pass stands down, got ' .. stoodDown)
check(onLine == 0, 'and nobody in it does')
RM_onDragRun(ADMIN)
runTree()
released = {}
for _, l in ipairs(current().lanes) do
  reportRun(l.seed, { rt = 0.100 + l.lane * 0.01, et = 10 + l.lane, speed = 130 })
end
clearResult()
check(released[-1] ~= nil, 'the pass settling opens the strip again for everyone')

-- Losing a pass does not take a car away.
local out = nil
for _, e in ipairs(lastDrag.entrants) do if e.status == 'out' then out = e end end
check(out ~= nil, 'somebody went out')
spectated = {}
check(out == nil or spectated[seedToPid[out.seed]] == nil,
  'and was not stood down for the rest of the tournament')

-- ---------------------------------------------------------------------------
print('--- the board fills in while the pass is on ---')
-- ---------------------------------------------------------------------------
-- Lanes come home one at a time and the board has to show each of them as it
-- lands. It used to read only the settled results, so it stayed blank for the
-- whole run and filled in all at once at the end -- which is the part of a drag
-- board people actually watch.
fieldOf(2)
RM_onDragClear(ADMIN)
-- Held staging again: this is about times landing on the board one at a time,
-- and a car that has to creep into the beams first is a different test.
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0,'
  .. '"timeout":30,"stageMode":"hold"}')
build()
RM_onDragStage(ADMIN)
check(current().lanes[1].staged == true, 'a staged lane says so')
check(current().lanes[1].dnf ~= true, 'and a car that has not run yet is not a DNF')
RM_onDragRun(ADMIN)
runTree()
RM_onDragFoul(seedToPid[1], '{"rt":-0.080}')
check(current().lanes[1].foul == true, 'a red light is on the board at the launch')
check(current().lanes[1].rt ~= nil, 'with the light it left on')
reportRun(1, { rt = -0.080, et = 9.900, speed = 141, foul = true })
check(current().lanes[1].et == 9.9, 'a lane that is home shows its time straight away')
check(current().lanes[1].home == true, 'and is marked home')
check(current().lanes[2].et == nil, 'while the lane still running shows none')
check(current().lanes[2].dnf ~= true, 'and is not called a DNF for still driving')
reportRun(2, { rt = 0.150, et = 10.400, speed = 138 })
clearResult()

-- ---------------------------------------------------------------------------
print('--- a red light that never gets there ---')
-- ---------------------------------------------------------------------------
-- The foul is reported at the launch and the result at the finish, so a car
-- that leaves early and then fails to finish has one and not the other. Both
-- are the bottom tier either way; the point is that the board says WHY it lost.
fieldOf(2)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0,"timeout":10}')
build()
RM_onDragStage(ADMIN)
RM_onDragRun(ADMIN)
runTree()
RM_onDragFoul(seedToPid[1], '{"rt":-0.120}')
reportRun(2, { rt = 0.200, et = 11.000, speed = 130 })
for _ = 1, math.ceil(20 / 0.25) do
  if lastDrag.dragPhase ~= 'running' then break end
  RM_DragTick()
end
local red = lastDrag.board[1].passes[1]
check(red.lanes[1].foul == true, 'a red light that never finished is still on the board')
check(red.lanes[1].dnf == true, 'and is a DNF as well')
check(red.winner == entrantBySeed(2).name, 'the car that turned up takes it')
clearResult()

-- ---------------------------------------------------------------------------
print('--- a pass on the strip is a session ---')
-- ---------------------------------------------------------------------------
-- Somebody connecting while cars are staged and frozen on the start positions
-- must arrive as a ghost, exactly as they would into a running race or derby.
fieldOf(2)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0,"timeout":30}')
build()
RM_onDragStage(ADMIN)
connected[9] = 'Latecomer'
RM_onPlayerJoin(9)
local late = nil
for _, d in ipairs(lastState.drivers or {}) do
  if d.name == 'Latecomer' then late = d end
end
check(late ~= nil, 'the latecomer is on the board')
check(late == nil or late.status == 'waiting',
  'and arrives as a spectator rather than into a staged lane')
RM_onDragAbort(ADMIN)
connected[9] = nil

-- ---------------------------------------------------------------------------
print('--- a practice pass, alone on the strip ---')
-- ---------------------------------------------------------------------------
-- The reason this exists: a bracket needs a field, and until one turns up there
-- is otherwise no way to find out whether the strip works at all. One driver,
-- no ladder, the whole pass machinery.
connected = { [1] = 'Driver1' }
RM_onDragClear(ADMIN)
seedToPid = { [1] = 1 }
check(lastDrag.dragPhase == 'idle', 'no ladder')
laneAssign, treeSent = {}, {}
RM_onDragPractice(ADMIN)
check(lastDrag.dragPhase == 'staging', 'a practice pass stages in one press')
check(lastDrag.practice == true, 'and says it is one')
check(laneAssign[1] and laneAssign[1].slot == 1, 'the lone car gets lane one')
check(laneAssign[1].hold == true, 'and is held for the tree')
check(#current().lanes == 1, 'one car on the line')
RM_onDragRun(ADMIN)
check(treeSent[1] ~= nil, 'the tree drops for a practice pass like any other')
runTree()
check(lastDrag.dragPhase == 'running', 'and runs into the pass')
reportRun(1, { rt = 0.180, et = 11.250, speed = 121 })
check(lastDrag.dragPhase == 'result', 'the run settles it')
check(current().lanes[1].et == 11.25, 'with the time on the board')
clearResult()
check(lastDrag.dragPhase == 'idle', 'and hands the strip back with no ladder built')
check(#lastDrag.entrants == 0, 'a practice pass enters nobody in anything')
check(#lastDrag.board == 0, 'and leaves no round on the ladder')

-- It leaves a REAL tournament exactly where it found it, which is what makes it
-- usable between rounds to let somebody re-dial.
fieldOf(4)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0,"timeout":30}')
build()
pass(byLane)
local roundBefore, passBefore = lastDrag.round, lastDrag.passIndex
local recBefore = entrantBySeed(1).passes
RM_onDragPractice(ADMIN)
check(lastDrag.practice == true, 'a practice pass runs mid-tournament')
RM_onDragRun(ADMIN)
runTree()
for _, l in ipairs(current().lanes) do
  reportRun(l.seed, { rt = 0.100, et = 9.000, speed = 150 })
end
clearResult()
check(lastDrag.practice ~= true, 'and ends')
check(lastDrag.round == roundBefore, 'leaving the round where it was')
check(lastDrag.passIndex == passBefore, 'and the pass cursor too')
check(entrantBySeed(1).passes == recBefore, 'and nobody a pass better off')
check(entrantBySeed(1).bestET ~= 9.0, 'a warm-up does not set a tournament best')

-- Waving one off puts the ladder back rather than leaving it stuck.
RM_onDragPractice(ADMIN)
RM_onDragAbort(ADMIN)
check(lastDrag.dragPhase == 'ready', 'a waved-off practice pass returns to the ladder')
check(lastDrag.practice ~= true, 'and is gone')
check(lastDrag.passCount > 0, 'with the round still there to run')

-- ---------------------------------------------------------------------------
print('--- rolling up into the beams ---')
-- ---------------------------------------------------------------------------
-- The car is placed SHORT of the line and left free; the driver creeps into
-- the beams and the tree comes down when the field is in. The distance test
-- itself is the client's -- only it knows where a car is -- so what is checked
-- here is the procedure: who is told what, what the server waits for, and what
-- it does when the waiting stops.
local function stagedReport(seed, pre, inb)
  RM_onDragStaged(seedToPid[seed], string.format(
    '{"prestaged":%s,"staged":%s}', pre and 'true' or 'false',
    inb and 'true' or 'false'))
end

fieldOf(2)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0,'
  .. '"timeout":30,"stageMode":"rollup","autoStart":true,"stageWait":10}')
build()
laneAssign, treeSent = {}, {}
RM_onDragStage(ADMIN)
check(lastDrag.dragPhase == 'staging', 'the pass stages')
check(laneAssign[1] and laneAssign[1].rollup == true, 'the lane is told to roll up')
check(laneAssign[1].hold ~= true, 'and is NOT frozen: a held car cannot creep')
check(laneAssign[1].back ~= nil, 'with a distance to be placed short by')
check(laneAssign[1].stageAt ~= nil, 'and where the beams are')
check(current().lanes[1].staged ~= true, 'nobody is staged yet')

-- One car in the beams is not the field. The tree must not come down.
stagedReport(1, true, true)
check(current().lanes[1].staged == true, 'the first car stages')
for _ = 1, 8 do RM_DragTick() end
check(lastDrag.dragPhase == 'staging', 'and the tree waits for the other one')
check(treeSent[1] == nil, 'which has not been sent a tree')

-- The second car pre-stages but does not reach the stage beam.
stagedReport(2, true, false)
check(current().lanes[2].prestaged == true, 'the second car pre-stages')
check(current().lanes[2].staged ~= true, 'without being in')
for _ = 1, 8 do RM_DragTick() end
check(lastDrag.dragPhase == 'staging', 'pre-staged is not staged')

-- Now it stages. The tree is ARMED rather than fired, so the last car in gets
-- the same moment to settle everybody else got.
stagedReport(2, true, true)
RM_DragTick()
check(lastDrag.dragPhase == 'staging', 'the tree does not fire on the same tick')
for _ = 1, 8 do RM_DragTick() end
check(lastDrag.dragPhase == 'tree', 'it comes down once the field has settled')
check(treeSent[1] ~= nil and treeSent[2] ~= nil, 'and both lanes get it')
RM_onDragAbort(ADMIN)

-- ROLLING BACK OUT stops the tree coming. A driver who overshoots and reverses
-- must not have it dropped on them mid-manoeuvre.
laneAssign, treeSent = {}, {}
RM_onDragStage(ADMIN)
stagedReport(1, true, true)
stagedReport(2, true, true)
RM_DragTick()
stagedReport(2, false, false)
for _ = 1, 8 do RM_DragTick() end
check(lastDrag.dragPhase == 'staging', 'a car leaving the beams stops the tree')
check(treeSent[1] == nil, 'which never went out')
stagedReport(2, true, true)
for _ = 1, 8 do RM_DragTick() end
check(lastDrag.dragPhase == 'tree', 'and it comes back when they return')
RM_onDragAbort(ADMIN)

-- THE COURTESY STAGE. One car never stages, and the pass must not sit there
-- for ever: the tree drops on whoever is in the beams.
laneAssign, treeSent = {}, {}
RM_onDragStage(ADMIN)
stagedReport(1, true, true)
for _ = 1, math.ceil(12 / 0.25) do
  if lastDrag.dragPhase ~= 'staging' then break end
  RM_DragTick()
end
check(lastDrag.dragPhase == 'tree', 'the courtesy stage expires and the tree drops')
RM_onDragAbort(ADMIN)

-- MANUAL START. Run is the admin's, and staging arms nothing by itself.
RM_onDragSetConfig(ADMIN, '{"autoStart":false}')
laneAssign, treeSent = {}, {}
RM_onDragStage(ADMIN)
stagedReport(1, true, true)
stagedReport(2, true, true)
for _ = 1, 8 do RM_DragTick() end
check(lastDrag.dragPhase == 'staging', 'a full field does not start itself on manual')
RM_onDragRun(ADMIN)
check(lastDrag.dragPhase == 'tree', 'Run starts it')
RM_onDragAbort(ADMIN)

-- ...and RUN IS AN OVERRIDE under automatic too, for the driver who will not
-- stage. Without it an admin would have to wait out the courtesy stage.
RM_onDragSetConfig(ADMIN, '{"autoStart":true}')
RM_onDragStage(ADMIN)
check(lastDrag.dragPhase == 'staging', 'staged, nobody in the beams')
RM_onDragRun(ADMIN)
check(lastDrag.dragPhase == 'tree', 'Run overrides an unstaged field')
RM_onDragAbort(ADMIN)

-- HOLD MODE is unchanged: placed, frozen, staged on arrival, Run when ready.
RM_onDragSetConfig(ADMIN, '{"stageMode":"hold"}')
laneAssign = {}
RM_onDragStage(ADMIN)
check(laneAssign[1].hold == true, 'hold mode freezes the car')
check(laneAssign[1].rollup ~= true, 'and does not ask it to creep')
check(current().lanes[1].staged == true, 'a held car is staged the moment it lands')
for _ = 1, 8 do RM_DragTick() end
check(lastDrag.dragPhase == 'staging', 'and hold mode never starts itself')
RM_onDragRun(ADMIN)
check(lastDrag.dragPhase == 'tree', 'Run is what starts it')
RM_onDragAbort(ADMIN)
RM_onDragClear(ADMIN)

-- ---------------------------------------------------------------------------
print('--- a tournament banks a cup round ---')
-- ---------------------------------------------------------------------------
-- A drag meeting is a round of the championship like a race or a derby, on a
-- points table of its own -- a ladder is not a ten-lap race and a league gets
-- to say what it is worth.
fieldOf(4)
RM_onDragClear(ADMIN)
RM_onCupSetEnabled(ADMIN, '{"enabled":true}')
RM_onCupStart(ADMIN, '{"name":"Drag Series"}')
-- Three deep, so fourth place scores nothing and the table can be seen to end.
RM_onCupSetScoring(ADMIN,
  '{"drag":[10,6,3],"bonus":{"dragWin":5,"dragLowET":2}}')
check(lastCup ~= nil, 'the cup answers')
check(#lastCup.dragPoints == 3, 'drag scores on a table of its own, 3 deep')

config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0,"timeout":30}')
build()
local roundBefore = lastCup.round
-- Seed 1 wins the tournament. Seed 4 runs the quickest single pass of the
-- meeting and goes out in round one anyway, which is exactly the case the Low
-- ET bonus exists for.
pass(function (seed, lane)
  if seed == 4 then return { rt = 0.400, et = 8.500, speed = 160 } end
  return byLane(seed, lane)
end)
pass(byLane)
pass(byLane)
check(lastDrag.dragPhase == 'complete', 'the tournament finished')
check(lastCup.round == roundBefore + 1, 'and banked exactly one cup round')

local function cupRow(name)
  for _, r in ipairs(lastCup.standings) do
    if r.name == name then return r end
  end
end
local champ = cupRow(lastDrag.champion)
check(champ ~= nil, 'the champion is in the standings')
check(champ == nil or champ.dragRounds == 1, 'with one drag round')
check(champ == nil or champ.dragWins == 1, 'and a drag win')
check(champ == nil or champ.dragPts == 10, 'and the winner points, got '
  .. tostring(champ and champ.dragPts))
check(champ == nil or champ.dragBonusPts == 5, 'and the Event Win bonus, got '
  .. tostring(champ and champ.dragBonusPts))
check(champ == nil or champ.dragTotal == 15, 'totalling 15')
check(champ == nil or champ.total == 15, 'which is the whole of their cup so far')

-- The quickest pass of the meeting, paid to somebody who lost in round one.
local low = cupRow('Driver4')
check(low ~= nil, 'the driver who went out first is scored too')
check(low == nil or low.dragBonusPts == 2,
  'and takes Low ET despite it, got ' .. tostring(low and low.dragBonusPts))
check(low == nil or low.dragWins == 0, 'without a win')

-- Everybody who entered is scored, not just the ones who reached the final.
local scoredRows = 0
for _, r in ipairs(lastCup.standings) do
  if r.dragRounds > 0 then scoredRows = scoredRows + 1 end
end
check(scoredRows == 4, 'a drag round scores the whole field, got ' .. scoredRows)
-- ...and the table ends where it was told to. Fourth place is past it.
local fourth = nil
for _, r in ipairs(lastCup.standings) do
  if r.dragPts == 0 and r.dragRounds == 1 then fourth = r end
end
check(fourth ~= nil, 'fourth place scores no points, the table being 3 deep')

-- AN EMPTY DRAG TABLE MEANS DRAG IS NOT PART OF THIS CUP, and it means it
-- completely: no round, and no Low ET quietly paid out either.
RM_onCupSetScoring(ADMIN, '{"drag":[]}')
local roundNow = lastCup.round
fieldOf(4)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0,"timeout":30}')
build()
pass(byLane)
pass(byLane)
pass(byLane)
check(lastDrag.dragPhase == 'complete', 'a second tournament finished')
check(lastCup.round == roundNow,
  'and banked nothing, because this cup does not pay for drag racing')
RM_onCupSetEnabled(ADMIN, '{"enabled":false}')

-- ---------------------------------------------------------------------------
print('--- the ladder survives a restart ---')
-- ---------------------------------------------------------------------------
fieldOf(8)
RM_onDragClear(ADMIN)
config('{"format":"single","lanes":2,"advance":1,"seed":"order","holdResult":0}')
build()
pass(byLane)
pass(byLane)
local beforeRounds = #lastDrag.board
local beforeIn = 0
for _, e in ipairs(lastDrag.entrants) do if e.status == 'in' then beforeIn = beforeIn + 1 end end

-- The file is written on every change, so the half-run ladder is already on
-- disk. Read it back the way the boot path does and check the tournament is
-- all there: the entrants with their records, the rounds with their results,
-- and the cursor pointing at the pass that was next.
local f = io.open('Resources/Server/RaceManager/Data/dragLadder.json', 'r')
check(f ~= nil, 'the ladder was written to disk')
if f then
  local text = f:read('*a')
  f:close()
  local saved = Util.JsonDecode(text)
  check(type(saved) == 'table' and type(saved.ladder) == 'table', 'and parses back')
  check(#saved.ladder.entrants == 8, 'with all eight entrants')
  check(#saved.ladder.rounds == beforeRounds,
    'and all ' .. beforeRounds .. ' round(s) drawn so far')
  local savedIn = 0
  for _, e in ipairs(saved.ladder.entrants) do
    if e.status == 'in' then savedIn = savedIn + 1 end
  end
  check(savedIn == beforeIn, 'and the same ' .. beforeIn .. ' still in it')
  -- A pass that was run has to come back RUN, or the restored ladder offers it
  -- again and the round never ends.
  check(saved.ladder.rounds[1].passes[1].done == true, 'a run pass comes back run')
  check(saved.ladder.rounds[1].passes[1].seeds ~= nil,
    'and the lanes come back as seed numbers, not as player ids')
  check(saved.config.format == 'single', 'the rules are saved beside it')
end
RM_onDragClear(ADMIN)
check(#lastDrag.entrants == 0, 'clearing the ladder empties it')

print()
print(string.format('drag_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
