-- Headless test for the CLIENT half of drag racing
-- (lua/ge/extensions/raceManager/drag.lua).
-- Run from the repo root: lua5.3 tests/drag_client_test.lua
--
-- WHY THIS EXISTS. Every other suite here tests the server, because the server
-- is where the rules live and the client is where the physics are. That left
-- the client half with no coverage at all, and it has now produced two bugs
-- that a test would have caught outright:
--
--   * the lanes were taken from the host BY REFERENCE, and the host reassigns
--     that table when a layout loads, so every staged car was placed against
--     the empty one the mod booted with;
--   * the time slip was pushed once and never taken down, so it outlived the
--     pass, the ladder and the tab.
--
-- Neither needs a vehicle to demonstrate. This module is reachable headlessly:
-- it takes everything it touches through init(host), and the four globals it
-- uses are stubbed below. What it cannot test is the physics themselves --
-- there is no car here -- so the vehicle is a position this file moves by hand,
-- which is exactly the input the real one would supply.

local sent = {}        -- server events this client fired: { name, payload }
local ui = {}          -- guihooks channels: [channel] = last payload
local placements = {}  -- queueFieldPlacement calls, in order
local notices = {}     -- pushNotice calls
local released = 0     -- releaseGridHold calls

function TriggerServerEvent(name, payload)
  sent[#sent + 1] = { name = name, payload = payload }
end

guihooks = {
  trigger = function (channel, data) ui[channel] = data end,
}

-- The mod ships against BeamNG's own codecs. These two only have to round-trip
-- what this module sends and receives, which is flat tables of scalars.
function jsonEncode(t)
  local parts = {}
  for k, v in pairs(t) do
    local val
    if type(v) == 'string' then val = '"' .. v .. '"'
    elseif type(v) == 'boolean' then val = tostring(v)
    elseif v == nil then val = 'null'
    else val = tostring(v) end
    parts[#parts + 1] = '"' .. k .. '":' .. val
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

function jsonDecode(s)
  if type(s) == 'table' then return s end
  local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
  return load('return ' .. body)()
end

local D = dofile('lua/ge/extensions/raceManager/drag.lua')

-- ---------------------------------------------------------------------------
-- The host, as this module sees it
-- ---------------------------------------------------------------------------
-- THE LANES COME THROUGH A GETTER, deliberately, and the test reassigns the
-- table underneath it: that is the bug being pinned. A host that handed over a
-- stable table would let the old code pass.
local track = { startPositions = {}, route = {} }
local car = { x = 0, y = 0, z = 0 }
local placementBusy = false

D.init({
  inMultiplayer = function () return true end,
  fromCurrentServer = function () return true end,
  localServerId = function () return 7 end,
  -- A COPY, not the table itself. The real sampledVehicle returns a fresh
  -- vector each frame, and the finish test compares last frame's position with
  -- this one -- hand it the same object twice and the two are always equal, so
  -- nothing ever crosses anything.
  sampledVehicle = function ()
    return {}, { x = car.x, y = car.y, z = car.z }
  end,
  pushNotice = function (kind, msg) notices[#notices + 1] = msg end,
  queueFieldPlacement = function (opts) placements[#placements + 1] = opts end,
  releaseGridHold = function () released = released + 1 end,
  requestHold = function () end,
  segmentCrossesGate = function (gate, prev, cur)
    -- A plane at gate.x crossed travelling in +x, which is all the geometry
    -- this test needs: the real one is exercised by tests/gate_test.lua.
    return prev and cur and prev.x < gate.x and cur.x >= gate.x
  end,
  finishGate = function ()
    local n = #track.route
    return n > 0 and track.route[n] or nil
  end,
  startPositions = function () return track.startPositions end,
  placementActive = function () return placementBusy end,
})

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local function lastSent(name)
  for i = #sent, 1, -1 do
    if sent[i].name == name then return sent[i].payload end
  end
end
local function clearCaptures()
  sent, placements, notices, released = {}, {}, {}, 0
end
-- Sixty frames a second, which is what the extension calls this at.
local function frames(n)
  for _ = 1, (n or 1) do D.dragUpdate(1 / 60) end
end
local function seconds(t) frames(math.floor(t * 60)) end

-- ONE CLEAN PASS, start to finish, as a sequence of positions.
--
-- The car has to STRADDLE the finish gate rather than teleport past it: the
-- crossing test compares last frame's position with this one, so a car that
-- appears beyond the line was never on the near side of it and never crossed.
-- That is true of the real test too, which is why it is worth doing properly
-- here rather than nudging a flag.
local function makeAPass()
  car.x = 99.8                     -- staged, in the beams
  frames(2)
  D.onDragTree(jsonEncode({ pattern = 'pro', preroll = 1.0, delay = 0,
                            lane = 1, timeout = 60 }))
  seconds(1.5)                     -- sit still until after the green
  car.x = 101                      -- launch
  frames(2)
  car.x = 320                      -- and through the lights at the top end
  frames(2)
end

-- ---------------------------------------------------------------------------
print('--- the lanes follow the loaded layout ---')
-- ---------------------------------------------------------------------------
-- The bug: the module captured track.startPositions at init, and the host
-- REASSIGNS it when a layout loads. Reproduced by doing exactly that.
track.startPositions = {
  { x = 100, y = 0, z = 0, hx = 1, hy = 0 },
  { x = 100, y = 8, z = 0, hx = 1, hy = 0 },
}
clearCaptures()
D.onDragLane(jsonEncode({ lane = 1, slot = 1, count = 2, hold = true }))
check(#placements == 1, 'a lane assignment places the car')
local pl = placements[1]
check(pl and pl.slots and pl.slots[1] ~= nil,
  'against a slot list that is not empty: the getter followed the layout')
check(pl and pl.slots[1].x == 100, 'and it is the loaded strip, got '
  .. tostring(pl and pl.slots[1] and pl.slots[1].x))

-- ...and again after ANOTHER layout load, which is the half that would catch a
-- reference re-captured once and then gone stale a second time.
track.startPositions = { { x = 500, y = 0, z = 0, hx = 1, hy = 0 } }
clearCaptures()
D.onDragLane(jsonEncode({ lane = 1, slot = 1, count = 1, hold = true }))
check(placements[1].slots[1].x == 500, 'a second layout load is followed too')

-- ---------------------------------------------------------------------------
print('--- rolling up into the beams ---')
-- ---------------------------------------------------------------------------
track.startPositions = { { x = 100, y = 0, z = 0, hx = 1, hy = 0 } }
clearCaptures()
D.onDragLane(jsonEncode({ lane = 1, slot = 1, count = 1, rollup = true,
                          back = 5, prestageAt = -1.2, stageAt = -0.35,
                          stagePast = 2.0 }))
check(placements[1].hold ~= true, 'a rolled-up car is not frozen')
check(math.abs(placements[1].slots[1].x - 95) < 1e-9,
  'and is placed five metres short of the line, got '
  .. tostring(placements[1].slots[1].x))

-- Well short: no bulbs.
car.x = 95
clearCaptures()
frames(2)
check(lastSent('RM_DragStaged') == nil, 'five metres out reports nothing')

-- Into the pre-stage beam.
car.x = 99.0
frames(2)
local rep = lastSent('RM_DragStaged')
check(rep ~= nil, 'reaching the pre-stage beam reports')
check(rep and rep:find('"prestaged":true'), 'pre-staged')
check(rep and rep:find('"staged":false'), 'but not yet staged')

-- ...and into the stage beam.
clearCaptures()
car.x = 99.8
frames(2)
rep = lastSent('RM_DragStaged')
check(rep ~= nil and rep:find('"staged":true'), 'creeping further stages it')

-- NOT EVERY FRAME. Sixty reports a second for a fact that moves twice is the
-- difference between a quiet channel and a loud one.
clearCaptures()
frames(30)
check(lastSent('RM_DragStaged') == nil, 'and standing still reports nothing more')

-- Rolling well past drops out of the beams again, so an overshoot is fixed by
-- backing up rather than by waving the pass off.
car.x = 103
frames(2)
rep = lastSent('RM_DragStaged')
check(rep ~= nil and rep:find('"staged":false'), 'rolling through un-stages')
car.x = 99.8
frames(2)
check(lastSent('RM_DragStaged'):find('"staged":true'), 'and backing up re-stages')

-- ---------------------------------------------------------------------------
print('--- the tree, the launch and the red light ---')
-- ---------------------------------------------------------------------------
track.route = { { x = 300 } }   -- the finish line
clearCaptures()
D.onDragTree(jsonEncode({ pattern = 'pro', preroll = 1.0, delay = 0, lane = 1,
                          timeout = 60 }))
check(ui['RaceManagerDragTree'] ~= nil, 'the tree shows')
-- Leaving during the pre-roll, before this driver's green, is a red light.
seconds(0.5)
car.x = 101.0
frames(2)
check(ui['RaceManagerDragTree'].stage == 'red', 'leaving early is a red light')

-- It is a FOUL, NOT A CANCELLED PASS: the car goes on down the strip and still
-- puts a time on the board.
car.x = 320
frames(2)
local res = lastSent('RM_DragResult')
check(res ~= nil, 'crossing the finish still reports')
check(res and res:find('"foul":true'), 'as a foul')
check(res and res:find('"et":'), 'with an elapsed time')

-- ---------------------------------------------------------------------------
print('--- the time slip does not outlive the pass ---')
-- ---------------------------------------------------------------------------
-- The bug: pushed once when the pass ended and never taken down, so it
-- outlived the pass, the ladder and the tab.
check(ui['RaceManagerDragRun'] ~= nil, 'the slip goes up when the pass ends')
check(ui['RaceManagerDragRun'].et ~= nil, 'with a time on it')
seconds(10)
check(ui['RaceManagerDragRun'].et ~= nil, 'and is still up ten seconds later')
seconds(20)
check(ui['RaceManagerDragRun'].clear == true,
  'but is taken down before it becomes a lie')

-- A NEW PASS ON THE LINE clears it too, rather than leaving the last one up
-- until a fresh result happens to replace it.
makeAPass()
check(ui['RaceManagerDragRun'].et ~= nil, 'a second pass puts a slip up')
D.onDragLane(jsonEncode({ lane = 1, slot = 1, count = 1, hold = true }))
check(ui['RaceManagerDragRun'].clear == true, 'staging the next pass clears it')

-- ...and so does the ladder going away. This is the path that matters most:
-- after a practice pass the phase is 'idle' and Clear Ladder is DISABLED, so
-- it cannot be the button that tidies up.
makeAPass()
check(ui['RaceManagerDragRun'].et ~= nil, 'a third pass puts a slip up')
D.onDragUpdate(jsonEncode({ rmProtocol = 2, dragPhase = 'idle' }))
check(ui['RaceManagerDragRun'].clear == true,
  'and the ladder going idle takes it down')

-- An aborted pass leaves nothing behind either.
makeAPass()
D.onDragAborted(jsonEncode({ reason = 'waved off' }))
check(ui['RaceManagerDragRun'].clear == true, 'a waved-off pass clears it')
check(ui['RaceManagerDragTree'].stage == 'off', 'and takes the tree down')

print()
print(string.format('drag_client_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
