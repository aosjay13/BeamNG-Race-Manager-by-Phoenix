-- Headless test for BRANCHING ROUTES in lua/ge/extensions/raceManager.lua:
-- the lane/slot state machine that lets two halves of a field drive the same
-- track in different directions and be scored together.
--
-- Run from the repo root: lua5.3 tests/branch_test.lua
--
-- Mirror of the client's logic (kept in sync by hand; the extension needs the
-- BeamNG GE environment and cannot be dofile'd here). Three pieces:
--   * rectCrossesGate      -- the geometry, bidirectional unless oneWay
--   * branch.gateFor       -- which gate IS slot i, for this car
--   * checkGates           -- the crossing/arming state machine
--
-- The claim under test is the whole design: a branch SUBSTITUTES a gate into a
-- slot that already exists rather than adding one, so every lane has the same
-- number of slots, armedWp stays an integer bounded by #route, and the lap
-- completes on armedWp >= #route whichever way round a driver went.

local function rectCrossesGate(wp, prev, cur, w, h)
  local fx, fy = wp.hx, wp.hy
  local dPrev = (prev.x - wp.x) * fx + (prev.y - wp.y) * fy
  local dCur  = (cur.x  - wp.x) * fx + (cur.y  - wp.y) * fy
  local forward  = (dPrev < 0 and dCur >= 0)
  local backward = (not wp.oneWay) and (dPrev > 0 and dCur <= 0)
  if not (forward or backward) then return false end
  local t  = dPrev / (dPrev - dCur)
  local ix = prev.x + (cur.x - prev.x) * t
  local iy = prev.y + (cur.y - prev.y) * t
  local iz = prev.z + (cur.z - prev.z) * t
  if math.abs((ix - wp.x) * fy - (iy - wp.y) * fx) > w * 0.5 then return false end
  if math.abs(iz - wp.z) > h * 0.5 then return false end
  return true, backward
end

-- ---------------------------------------------------------------------------
-- The client's state, and the state machine over it
-- ---------------------------------------------------------------------------
local S = {}

local function reset(route, branches)
  S.route   = route or {}
  S.list    = branches or {}
  S.bySlot  = {}
  for _, b in ipairs(S.list) do
    local slots = {}
    for _, g in ipairs(b.gates) do slots[g.slot] = g end
    S.bySlot[b.id] = slots
  end
  S.armedWp = 1
  S.lane    = nil
  S.lock    = false
  S.localLap = 1
  S.laps    = 0            -- completed crossings reported upstream
  S.scored  = 0            -- laps that were actually timed (out lap excluded)
  S.lastGate = nil
  S.lastBack = false
  S.outLapOwed = false     -- the session/track rule
  S.notices = {}
end

local function gateFor(i, lane)
  if lane then
    local bySlot = S.bySlot[lane]
    local g = bySlot and bySlot[i]
    if g then return g end
  end
  return S.route[i]
end

-- Mirror of onOutLap(): the rule, and "this driver has not crossed yet".
local function onOutLap()
  return S.outLapOwed and S.localLap <= 1
end

-- Mirror of checkGates. Returns true when this movement scored a slot.
local function drive(prev, cur)
  local onOut = onOutLap()
  local wp = onOut and S.route[#S.route] or gateFor(S.armedWp, S.lane)
  local crossed, backwards = false, false
  if wp then crossed, backwards = rectCrossesGate(wp, prev, cur, 20, 10) end

  local took = nil
  if not crossed and not onOut and not S.lane and not S.lock then
    for _, b in ipairs(S.list) do
      local g = S.bySlot[b.id] and S.bySlot[b.id][S.armedWp]
      if g then
        crossed, backwards = rectCrossesGate(g, prev, cur, 20, 10)
        if crossed then wp, took = g, b end
      end
      if crossed then break end
    end
  end
  if not crossed then return false end

  S.lastGate, S.lastBack = wp, backwards or false
  if took then
    S.lane = took.id
    S.notices[#S.notices + 1] = took.id
  end
  if onOut then
    S.laps = S.laps + 1
    S.localLap = S.localLap + 1
    S.armedWp = 1
  elseif S.armedWp >= #S.route then
    S.laps = S.laps + 1
    S.scored = S.scored + 1
    S.localLap = S.localLap + 1
    S.armedWp = 1
    if not S.lock then S.lane = nil end
  else
    S.armedWp = S.armedWp + 1
  end
  return true
end

-- Slot renumbering, mirrored from the editor. A lane addresses slots by number,
-- so editing the main route has to move the lanes with it.
local function shiftSlots(from, delta)
  for _, b in ipairs(S.list) do
    for _, g in ipairs(b.gates) do
      if g.slot >= from then g.slot = g.slot + delta end
    end
  end
end
local function dropSlot(slot)
  local dropped = 0
  for _, b in ipairs(S.list) do
    for i = #b.gates, 1, -1 do
      if b.gates[i].slot == slot then table.remove(b.gates, i); dropped = dropped + 1 end
    end
  end
  return dropped
end
local function reorderSlots(from, to)
  local lo, hi, step = math.min(from, to), math.max(from, to), (from < to) and -1 or 1
  for _, b in ipairs(S.list) do
    for _, g in ipairs(b.gates) do
      if g.slot == from then g.slot = to
      elseif g.slot >= lo and g.slot <= hi then g.slot = g.slot + step end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function P(x, y, z) return { x = x, y = y, z = z or 0 } end

-- Drive straight through a gate's centre, along the direction given. `dir` is
-- +1 to go the way the gate points and -1 to come back through it.
local function through(gate, dir)
  dir = dir or 1
  local fx, fy = gate.hx * dir, gate.hy * dir
  return drive(P(gate.x - fx * 3, gate.y - fy * 3), P(gate.x + fx * 3, gate.y + fy * 3))
end

-- ===========================================================================
-- THE OVAL, exactly as a head-on layout is described:
--   CP1, branch of CP3, CP2 for both lanes, CP3, branch of CP1, start/finish.
-- ===========================================================================
-- Four points round a ring. Going CLOCKWISE from the line:
--   start/finish (0,-100) -> turn 1 (100,0) -> back stretch (0,100) -> turn 2 (-100,0)
local TURN1, BACK, TURN2, LINE = P(100, 0), P(0, 100), P(-100, 0), P(0, -100)

local function oval()
  -- Main route (clockwise). Heading at each gate is the way a CW car travels.
  local route = {
    { x = TURN1.x, y = TURN1.y, z = 0, hx = 0,  hy = 1  },   -- slot 1: turn 1
    { x = BACK.x,  y = BACK.y,  z = 0, hx = -1, hy = 0  },   -- slot 2: back stretch
    { x = TURN2.x, y = TURN2.y, z = 0, hx = 0,  hy = -1 },   -- slot 3: turn 2
    { x = LINE.x,  y = LINE.y,  z = 0, hx = 1,  hy = 0  },   -- slot 4: start/finish
  }
  -- The counter-clockwise lane. It overrides ONLY the two turns: its slot 1 is a
  -- gate at turn 2 and its slot 3 is a gate at turn 1, both facing the way a CCW
  -- car travels. The back stretch and the line are left alone -- shared, and
  -- crossed the other way round by this lane, which is what bidirectional gates
  -- are for.
  local ccw = { id = 'ccw', name = 'Counter-clockwise', gates = {
    { slot = 1, x = TURN2.x, y = TURN2.y, z = 0, hx = 0, hy = 1  },
    { slot = 3, x = TURN1.x, y = TURN1.y, z = 0, hx = 0, hy = -1 },
  } }
  return route, { ccw }
end

-- --- 1. A track with no branches behaves exactly as it always did ----------
do
  local route = oval()
  reset(route, {})
  check(#S.route == 4, 'plain oval has four slots')
  local order = {}
  for i = 1, 4 do
    order[#order + 1] = S.armedWp
    check(through(route[i]) == true, 'plain: slot ' .. i .. ' scores')
  end
  check(table.concat(order, ',') == '1,2,3,4', 'plain: armedWp walks 1,2,3,4')
  check(S.armedWp == 1, 'plain: armedWp back to 1 after the line')
  check(S.laps == 1 and S.scored == 1, 'plain: one lap, and it counted')
  check(S.lane == nil, 'plain: no lane is ever set')
end

-- --- 2. gateFor resolves overrides and falls through -----------------------
do
  local route, branches = oval()
  reset(route, branches)
  check(gateFor(1, nil) == route[1], 'main slot 1 is the main gate')
  check(gateFor(1, 'ccw').x == TURN2.x, "ccw slot 1 is the gate at turn 2")
  check(gateFor(3, 'ccw').x == TURN1.x, "ccw slot 3 is the gate at turn 1")
  check(gateFor(2, 'ccw') == route[2], 'ccw slot 2 falls through: shared')
  check(gateFor(4, 'ccw') == route[4], 'ccw slot 4 falls through: shared')
  check(gateFor(1, 'nosuch') == route[1], 'an unknown lane falls through to the main route')
end

-- --- 3. THE HEAD-ON LAP: both directions, same slots, same lap ------------
-- The clockwise car.
do
  local route, branches = oval()
  reset(route, branches)
  S.lock = true            -- assigned by the grid, as a head-on race is
  S.lane = nil             -- ...to the main route
  check(through(route[1]) == true, 'CW: turn 1 scores slot 1')
  check(S.armedWp == 2, 'CW: on slot 2')
  check(through(route[2]) == true, 'CW: back stretch scores slot 2')
  check(through(route[3]) == true, 'CW: turn 2 scores slot 3')
  check(through(route[4]) == true, 'CW: the line completes the lap')
  check(S.scored == 1 and S.armedWp == 1, 'CW: one scored lap, re-armed on slot 1')
end

-- The counter-clockwise car, over the SAME four slots, in the opposite
-- direction round the same ring.
do
  local route, branches = oval()
  reset(route, branches)
  S.lock = true
  S.lane = 'ccw'           -- assigned by its grid slot
  local ccw1 = gateFor(1, 'ccw')
  local ccw3 = gateFor(3, 'ccw')

  check(through(ccw1) == true, 'CCW: turn 2 scores slot 1')
  check(S.armedWp == 2, 'CCW: on slot 2')
  check(S.lastBack == false, 'CCW: its own gate is crossed forwards')

  -- The shared back stretch, driven the other way. This is the crossing that
  -- only works because gates score in both directions.
  check(through(route[2], -1) == true, 'CCW: the shared back stretch scores backwards')
  check(S.lastBack == true, 'CCW: and is recorded as a backward crossing')
  check(S.armedWp == 3, 'CCW: on slot 3')

  check(through(ccw3) == true, 'CCW: turn 1 scores slot 3')
  check(through(route[4], -1) == true, 'CCW: the shared line completes the lap backwards')
  check(S.scored == 1, 'CCW: one scored lap, over the same four slots')
  check(S.armedWp == 1, 'CCW: re-armed on slot 1')
  check(S.lane == 'ccw', 'CCW: a grid-assigned lane survives the lap boundary')
end

-- --- 4. A locked lane never arms the other lane's gates --------------------
do
  local route, branches = oval()
  reset(route, branches)
  S.lock, S.lane = true, 'ccw'
  -- The CW car's turn-1 gate is not this lane's slot 1, so driving through it
  -- does nothing at all -- exactly as driving through any unarmed gate does.
  check(through(route[1]) == false, 'CCW: the main route\'s turn 1 gate is inert')
  check(S.armedWp == 1, 'CCW: and the slot did not advance')
  -- Its own slot-1 gate still works.
  check(through(gateFor(1, 'ccw')) == true, 'CCW: its own slot 1 still scores')
end

-- The main-route half of a head-on grid is locked too, and that is the point.
-- Locking only the TAGGED half would leave a clockwise driver undecided, and an
-- undecided car is moved onto whichever lane's gate it crosses first: spin one
-- round on a head-on oval and it picks up the oncoming lane and starts scoring
-- laps the other way. Untagged means the main route, which is an assignment.
do
  local route, branches = oval()
  reset(route, branches)
  S.lock, S.lane = true, nil       -- main route, locked
  check(through(gateFor(1, 'ccw')) == false, "CW: the ccw lane's gate is inert")
  check(S.armedWp == 1, 'CW: and the slot did not advance')
  check(S.lane == nil, 'CW: a locked main-route car is never moved onto a lane')

  -- The same car, WITHOUT the lock, is exactly the failure that guards against.
  reset(route, branches)
  S.lock, S.lane = false, nil
  check(through(gateFor(1, 'ccw')) == true,
    'unlocked: the oncoming lane is live -- which is why a grid-assigned track locks everyone')
  check(S.lane == 'ccw', 'unlocked: and the car is dragged onto it')
end

-- --- 5. Both lanes complete the same number of laps ------------------------
do
  local route, branches = oval()
  -- Clockwise, three laps.
  reset(route, branches); S.lock = true
  for _ = 1, 3 do
    through(route[1]); through(route[2]); through(route[3]); through(route[4])
  end
  local cwLaps = S.scored
  -- Counter-clockwise, three laps.
  reset(route, branches); S.lock, S.lane = true, 'ccw'
  for _ = 1, 3 do
    through(gateFor(1, 'ccw')); through(route[2], -1)
    through(gateFor(3, 'ccw')); through(route[4], -1)
  end
  check(cwLaps == 3 and S.scored == 3,
    'three laps each way: the field is scored together, on the same slot count')
end

-- --- 6. An unlocked lane is chosen by driving, and cleared each lap --------
-- The rally-style split: nobody is assigned, and whichever gate a car actually
-- drives through is the line it is on for that lap.
do
  local route, branches = oval()
  reset(route, branches)
  S.lock = false
  check(S.lane == nil, 'split: undecided at the start of the lap')
  check(through(gateFor(1, 'ccw')) == true, 'split: crossing the alternate gate scores')
  check(S.lane == 'ccw', 'split: ...and commits this car to that lane')
  check(S.notices[1] == 'ccw', 'split: the driver is told which line they are on')
  through(route[2], -1); through(gateFor(3, 'ccw')); through(route[4], -1)
  check(S.lane == nil, 'split: the lane is chosen again next lap')
end

do
  local route, branches = oval()
  reset(route, branches)
  S.lock = false
  check(through(route[1]) == true, 'split: the main gate scores just as well')
  check(S.lane == nil, 'split: staying on the main route commits to no lane')
end

-- --- 7. The out lap arms the LINE and nothing else -------------------------
-- A head-on grid is spread round the circuit, so slot 1 can be behind a driver
-- at GO. On a lap nobody is scoring there is nothing to police.
do
  local route, branches = oval()
  reset(route, branches)
  S.lock, S.lane = true, 'ccw'
  S.outLapOwed = true
  check(onOutLap() == true, 'out lap: owed before the first crossing')
  -- Slot 1's gate does nothing: it is not what is armed.
  check(through(gateFor(1, 'ccw')) == false, 'out lap: slot 1 is not armed')
  check(S.armedWp == 1, 'out lap: nothing advanced')
  -- The line ends it, from either direction.
  check(through(route[4], -1) == true, 'out lap: the line ends it, crossed backwards')
  check(S.laps == 1, 'out lap: reported as a crossing')
  check(S.scored == 0, 'out lap: but NOT scored -- no lap time goes on the board')
  check(onOutLap() == false, 'out lap: done')
  check(S.armedWp == 1, 'out lap: slot 1 armed for the first timed lap')
  -- And now the normal lap works.
  check(through(gateFor(1, 'ccw')) == true, 'after the out lap: slot 1 scores')
end

-- A track whose grid IS on the line owes nothing and behaves as before.
do
  local route = oval()
  reset(route, {})
  S.outLapOwed = false
  check(through(route[1]) == true, 'no out lap: slot 1 is armed from GO')
  check(S.scored == 0 and S.armedWp == 2, 'no out lap: normal progression')
end

-- --- 8. The respawn direction is recorded at the crossing ------------------
-- A shared gate carries one heading and is driven both ways, so which way a car
-- was going cannot be read off the gate afterwards.
do
  local route, branches = oval()
  reset(route, branches)
  S.lock, S.lane = true, nil
  through(route[1])
  check(S.lastGate == route[1] and S.lastBack == false,
    'CW: last gate recorded, forwards')
  reset(route, branches)
  S.lock, S.lane = true, 'ccw'
  through(gateFor(1, 'ccw'))
  through(route[2], -1)
  check(S.lastGate == route[2], 'CCW: the shared gate is the last one crossed')
  check(S.lastBack == true,
    'CCW: recorded as backwards, so the respawn faces the way the car was going')
end

-- --- 9. Editing the main route renumbers the lanes ------------------------
do
  local _, branches = oval()
  reset({}, branches)
  -- Insert a gate before slot 2: the lane's slot 3 gate becomes slot 4.
  shiftSlots(2, 1)
  check(S.list[1].gates[1].slot == 1, 'insert: a slot before the change is untouched')
  check(S.list[1].gates[2].slot == 4, 'insert: a slot after it moves up')

  local _, b2 = oval()
  reset({}, b2)
  -- Delete slot 1: the lane's override for it goes with it, and slot 3 drops to 2.
  local dropped = dropSlot(1)
  shiftSlots(2, -1)
  check(dropped == 1, 'delete: the override for the removed slot is dropped')
  check(#S.list[1].gates == 1, 'delete: the lane keeps its other gate')
  check(S.list[1].gates[1].slot == 2, 'delete: the surviving slot moves down')

  local _, b3 = oval()
  reset({}, b3)
  -- Move slot 3 to slot 1: the lane's slot 3 becomes slot 1, and its slot 1 -> 2.
  reorderSlots(3, 1)
  local bySlot = {}
  for _, g in ipairs(S.list[1].gates) do bySlot[g.slot] = g end
  check(bySlot[1] ~= nil and bySlot[1].x == TURN1.x, 'reorder: slot 3 became slot 1')
  check(bySlot[2] ~= nil and bySlot[2].x == TURN2.x, 'reorder: slot 1 shifted to 2')
end

-- --- 10. Slots are what is counted, not gates -----------------------------
-- The property the whole server side rests on: the checkpoint count reported
-- upstream means the same thing whichever lane a driver is on, so the running
-- order needs no lane arithmetic at all.
do
  local route, branches = oval()
  local cw, ccw = {}, {}
  reset(route, branches); S.lock = true
  through(route[1]); cw[#cw + 1] = S.armedWp - 1
  through(route[2]); cw[#cw + 1] = S.armedWp - 1
  through(route[3]); cw[#cw + 1] = S.armedWp - 1
  reset(route, branches); S.lock, S.lane = true, 'ccw'
  through(gateFor(1, 'ccw')); ccw[#ccw + 1] = S.armedWp - 1
  through(route[2], -1);      ccw[#ccw + 1] = S.armedWp - 1
  through(gateFor(3, 'ccw')); ccw[#ccw + 1] = S.armedWp - 1
  check(table.concat(cw, ',') == '1,2,3', 'CW reports 1,2,3 checkpoints cleared')
  check(table.concat(ccw, ',') == '1,2,3', 'CCW reports 1,2,3 -- the same numbers')
end

-- --- 11. A lane may leave every slot shared but one ------------------------
-- The rally split: one corner taken two ways, everything else common.
do
  local route = oval()
  local left = { id = 'left', name = 'Left line', gates = {
    { slot = 2, x = 0, y = 130, z = 0, hx = -1, hy = 0 },
  } }
  reset(route, { left })
  S.lock, S.lane = true, 'left'
  check(through(route[1]) == true, 'split: slot 1 is shared and scores')
  check(through(route[2]) == false, 'split: the main line at slot 2 is inert for this lane')
  check(through(gateFor(2, 'left')) == true, 'split: the left line scores slot 2')
  check(through(route[3]) == true, 'split: slot 3 is shared again')
  check(through(route[4]) == true, 'split: and the shared line ends the lap')
  check(S.scored == 1, 'split: one lap, four slots, one of them taken the other way')
end

if fails == 0 then
  print('branch_test: ' .. checks .. ' checks, 0 failures')
else
  print('branch_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
