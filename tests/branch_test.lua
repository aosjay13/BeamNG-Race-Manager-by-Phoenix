-- Headless test for BRANCH GATES in lua/ge/extensions/raceManager.lua: the
-- other ways through a checkpoint, which is what lets two halves of a field
-- drive the same track in different directions and be scored together.
--
-- Run from the repo root: lua5.3 tests/branch_test.lua
--
-- Mirror of the client's logic (kept in sync by hand; the extension needs the
-- BeamNG GE environment and cannot be dofile'd here). Three pieces:
--   * rectCrossesGate      -- the geometry, bidirectional unless oneWay
--   * branch.crossedAt     -- did this movement clear slot i, by ANY of its gates
--   * checkGates           -- the crossing/arming state machine
--
-- The claim under test is the whole design: a branch gate is another way through
-- a checkpoint that already exists rather than an extra checkpoint, so armedWp
-- stays an integer bounded by #route, the lap completes on armedWp >= #route
-- whichever gates a driver took, and NOTHING is carried from one slot to the
-- next. There is no lane, so there is nothing to assign, lock or remember.

local function rectCrossesGate(wp, prev, cur, w, h, d)
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
  -- Height is UP from the placement point and depth is DOWN, so the vertical
  -- test is a range rather than a symmetric one. `d` defaults to h here so the
  -- cases written before the split still describe the gate they were written
  -- for: back then height was the full span, centerd.
  d = d or h
  local dz = iz - wp.z
  if dz > h or dz < -d then return false end
  return true, backward
end

-- ---------------------------------------------------------------------------
-- The client's state, and the state machine over it
-- ---------------------------------------------------------------------------
local S = {}

-- `branches` is the FLAT authored list: { { slot = n, x, y, z, hx, hy }, ... }.
-- Several gates may carry the same slot, and that is the feature.
local function reset(route, branches)
  S.route   = route or {}
  S.list    = branches or {}
  S.bySlot  = {}
  for _, g in ipairs(S.list) do
    local at = S.bySlot[g.slot]
    if not at then at = {}; S.bySlot[g.slot] = at end
    at[#at + 1] = g
  end
  S.armedWp = 1
  S.localLap = 1
  S.laps    = 0            -- completed crossings reported upstream
  S.scored  = 0            -- laps that were actually timed (out lap excluded)
  S.lastGate = nil
  S.lastBack = false
  S.outLapOwed = false     -- the session/track rule
end

-- Mirror of branch.crossedAt: the main gate for slot i, then every branch gate
-- authored against it. Returns the gate crossed and whether it was backwards.
local function crossedAt(i, prev, cur)
  local wp = S.route[i]
  if wp then
    local crossed, backwards = rectCrossesGate(wp, prev, cur, 20, 10)
    if crossed then return wp, backwards end
  end
  local alts = S.bySlot[i]
  if alts then
    for k = 1, #alts do
      local crossed, backwards = rectCrossesGate(alts[k], prev, cur, 20, 10)
      if crossed then return alts[k], backwards end
    end
  end
  return nil, false
end

-- Mirror of onOutLap(): the rule, and "this driver has not crossed yet".
local function onOutLap()
  return S.outLapOwed and S.localLap <= 1
end

-- Mirror of checkGates. Returns true when this movement scored a slot.
local function drive(prev, cur)
  local onOut = onOutLap()
  local wp, backwards = crossedAt(S.armedWp, prev, cur)
  local crossed = wp ~= nil

  -- On the out lap the LINE also ends the lap, from wherever the driver has got
  -- to and with slots still owing.
  local lineEndedOutLap = false
  if onOut and not crossed and S.armedWp < #S.route then
    local line = S.route[#S.route]
    if line then
      crossed, backwards = rectCrossesGate(line, prev, cur, 20, 10)
      if crossed then wp, lineEndedOutLap = line, true end
    end
  end
  if not crossed then return false end

  S.lastGate, S.lastBack = wp, backwards or false
  if lineEndedOutLap then
    S.laps = S.laps + 1
    S.localLap = S.localLap + 1
    S.armedWp = 1
  elseif S.armedWp >= #S.route then
    S.laps = S.laps + 1
    if not onOut then S.scored = S.scored + 1 end
    S.localLap = S.localLap + 1
    S.armedWp = 1
  else
    S.armedWp = S.armedWp + 1
  end
  return true
end

-- Slot renumbering, mirrored from the editor. A branch gate addresses its
-- checkpoint by number, so editing the main route has to move them with it.
local function shiftSlots(from, delta)
  for _, g in ipairs(S.list) do
    if g.slot >= from then g.slot = g.slot + delta end
  end
end
local function dropSlot(slot)
  local dropped = 0
  for i = #S.list, 1, -1 do
    if S.list[i].slot == slot then table.remove(S.list, i); dropped = dropped + 1 end
  end
  return dropped
end
local function reorderSlots(from, to)
  local lo, hi, step = math.min(from, to), math.max(from, to), (from < to) and -1 or 1
  for _, g in ipairs(S.list) do
    if g.slot == from then g.slot = to
    elseif g.slot >= lo and g.slot <= hi then g.slot = g.slot + step end
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

-- Drive straight through a gate's center, along the direction given. `dir` is
-- +1 to go the way the gate points and -1 to come back through it.
local function through(gate, dir)
  dir = dir or 1
  local fx, fy = gate.hx * dir, gate.hy * dir
  return drive(P(gate.x - fx * 3, gate.y - fy * 3), P(gate.x + fx * 3, gate.y + fy * 3))
end

-- ===========================================================================
-- THE OVAL, exactly as a head-on layout is described:
--   CP1 and a branch of it, CP2 shared, CP3 and a branch of it, start/finish.
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
  -- Two branch gates, one for each turn. The branch for slot 1 stands at turn 2
  -- and the branch for slot 3 stands at turn 1, both facing the way an
  -- anti-clockwise car travels. The back stretch and the line get none: they are
  -- shared, and crossed the other way round by a CCW car, which is what
  -- bidirectional gates are for.
  local alts = {
    { slot = 1, x = TURN2.x, y = TURN2.y, z = 0, hx = 0, hy = 1  },
    { slot = 3, x = TURN1.x, y = TURN1.y, z = 0, hx = 0, hy = -1 },
  }
  return route, alts
end

-- --- 1. A track with no branch gates behaves exactly as it always did -------
local plain = select(1, oval())
reset(plain, {})
check(S.bySlot[1] == nil, 'a track with no branch gates has no per-slot entry at all')
check(through(plain[1]) == true, 'CP 1 scores')
check(S.armedWp == 2, 'and arms CP 2')
check(through(plain[2]) == true, 'CP 2 scores')
check(through(plain[3]) == true, 'CP 3 scores')
check(through(plain[4]) == true, 'the line scores')
check(S.armedWp == 1, 'and the lap wraps to CP 1')
check(S.laps == 1 and S.scored == 1, 'one lap, timed')

-- --- 2. crossedAt accepts the main gate OR any branch of it ----------------
local route, alts = oval()
reset(route, alts)
check(#S.bySlot[1] == 1 and #S.bySlot[3] == 1, 'each branched slot holds its gate')
check(S.bySlot[2] == nil and S.bySlot[4] == nil, 'a shared slot holds none')
-- The main gate for slot 1 is at turn 1; its branch is at turn 2. Both clear it.
check(crossedAt(1, P(TURN1.x, TURN1.y - 3), P(TURN1.x, TURN1.y + 3)) == route[1],
  'the main gate clears its slot')
check(crossedAt(1, P(TURN2.x, TURN2.y - 3), P(TURN2.x, TURN2.y + 3)) == alts[1],
  'and so does its branch gate, at the other end of the circuit')
check(crossedAt(2, P(TURN2.x, TURN2.y - 3), P(TURN2.x, TURN2.y + 3)) == nil,
  'a gate only ever clears the slot it was authored against')

-- --- 3. THE HEAD-ON LAP: both directions, same slots, same lap -------------
-- The clockwise car, driving the main gates the way they point.
reset(oval())
check(through(route[1]) == true, 'CW: turn 1 clears CP 1')
check(S.armedWp == 2, 'CW: CP 2 armed')
check(through(route[2]) == true, 'CW: the back stretch clears CP 2')
check(through(route[3]) == true, 'CW: turn 2 clears CP 3')
check(through(route[4]) == true, 'CW: the line clears CP 4')
check(S.laps == 1 and S.armedWp == 1, 'CW: one lap, back to CP 1')

-- The counter-clockwise car over the SAME four slots, in the opposite physical
-- order, taking a branch gate wherever one exists. Nothing was assigned to it:
-- it simply reaches the anti-clockwise gate for each slot first.
local r2, a2 = oval()
reset(r2, a2)
check(through(a2[1]) == true, 'CCW: turn 2 clears CP 1, by the branch gate there')
check(S.armedWp == 2, 'CCW: CP 2 armed, the same slot the CW car is on')
check(through(r2[2], -1) == true, 'CCW: the shared back stretch, crossed backwards')
check(S.lastBack == true, 'and it is recorded as a backwards crossing')
check(through(a2[2]) == true, 'CCW: turn 1 clears CP 3, by the branch gate there')
check(through(r2[4], -1) == true, 'CCW: the shared line, crossed backwards')
check(S.laps == 1 and S.armedWp == 1, 'CCW: one lap over the same four slots')

-- --- 4. NOTHING IS CARRIED FROM ONE SLOT TO THE NEXT -----------------------
-- The property this whole design rests on, and the one the lane system did not
-- have. Every slot is decided on its own, so a car that turns round mid-lap is
-- not stuck on a line it can no longer reach: it clears the next checkpoint by
-- whichever of that checkpoint's gates it actually drives through.
local r3, a3 = oval()
reset(r3, a3)
check(through(a3[1]) == true, 'clear CP 1 by its branch gate, at turn 2')
check(through(r3[2], -1) == true, 'clear CP 2 anti-clockwise')
-- Now turn round and take CP 3 by its MAIN gate at turn 2, not the branch at
-- turn 1. Under the old lane rules this car was locked to the CCW line and the
-- main gate for slot 3 was not armed for it at all.
check(through(r3[3]) == true, 'and CP 3 by its MAIN gate: the earlier branch bound nothing')
check(S.armedWp == 4, 'the lap carries on normally from there')

-- The reverse mix, for the same reason.
local r4, a4 = oval()
reset(r4, a4)
check(through(r4[1]) == true, 'clear CP 1 by its main gate')
check(through(r4[2]) == true, 'clear CP 2')
check(through(a4[2]) == true, 'and CP 3 by its BRANCH gate: still no line to be on')

-- --- 5. Both directions complete the same number of laps -------------------
-- The whole field is scored together on one clock, so this has to hold exactly.
local function lapCW(r) through(r[1]); through(r[2]); through(r[3]); through(r[4]) end
local function lapCCW(r, a) through(a[1]); through(r[2], -1); through(a[2]); through(r[4], -1) end

local r5, a5 = oval()
reset(r5, a5)
for _ = 1, 3 do lapCW(r5) end
local cwLaps = S.laps
reset(r5, a5)
for _ = 1, 3 do lapCCW(r5, a5) end
check(S.laps == cwLaps and S.laps == 3,
  'three laps each way is three laps, on one count that means the same thing')

-- --- 6. The out lap arms the checkpoints AND the line ----------------------
-- A head-on grid is spread round the circuit, so slot 1 can be behind a driver
-- at the moment they are released. The checkpoints are armed like any other lap
-- (it is the lap a driver least knows the circuit), and reaching the LINE ends
-- it from wherever they have got to, with slots still owing.
local r6, a6 = oval()
reset(r6, a6)
S.outLapOwed = true
check(onOutLap() == true, 'the out lap is owed')
check(through(r6[1]) == true, 'a checkpoint IS armed on the out lap and scores normally')
check(S.armedWp == 2, 'and arms the next one')
check(through(r6[4]) == true, 'reaching the line ends the out lap with slots still owing')
check(S.armedWp == 1, 'slot 1 arms behind it')
check(S.laps == 1 and S.scored == 0, 'the crossing is reported but not timed')
check(onOutLap() == false, 'and the out lap is over')
lapCW(r6)
check(S.scored == 1, 'the next lap is the first timed one')

-- A branch gate can end the out lap too, since it clears the same slot.
local r7, a7 = oval()
reset(r7, a7)
S.outLapOwed = true
check(through(a7[1]) == true, 'a branch gate scores on the out lap like any other')

-- A track whose grid IS on the line owes nothing and behaves as before.
local r8, a8 = oval()
reset(r8, a8)
check(onOutLap() == false, 'a grid on the line owes no out lap')
lapCW(r8)
check(S.scored == 1, 'so its first lap is timed')

-- --- 7. The respawn direction is recorded at the crossing -------------------
-- A shared gate carries one heading and is driven both ways, so which way a car
-- went through it is only knowable at the moment it did. The "Last Checkpoint"
-- reset mode puts a car back facing the way it was going.
local r9, a9 = oval()
reset(r9, a9)
through(r9[1])
check(S.lastGate == r9[1] and S.lastBack == false,
  'a forward crossing records the gate and its own direction')
reset(r9, a9)
through(a9[1])
check(S.lastGate == a9[1] and S.lastBack == false,
  'a branch gate is recorded as the last gate exactly like a main one')
reset(r9, a9)
through(a9[1]); through(r9[2], -1)
check(S.lastGate == r9[2] and S.lastBack == true,
  'and a shared gate taken backwards is recorded as backwards')

-- --- 8. Editing the main route renumbers the branch gates -------------------
-- A branch gate addresses its checkpoint by number, so inserting, deleting or
-- moving a main gate changes what those numbers mean. One left un-renumbered
-- silently comes to describe a different corner.
local r10, a10 = oval()
reset(r10, a10)
shiftSlots(2, 1)          -- a checkpoint inserted at slot 2
check(a10[1].slot == 1, 'a branch gate before the insert keeps its checkpoint')
check(a10[2].slot == 4, 'and one after it moves up with the slot it belongs to')

reset(oval())
local dropped = dropSlot(1)
check(dropped == 1, 'removing a checkpoint drops the branch gates that belonged to it')
check(#S.list == 1, 'and only those')
shiftSlots(2, -1)
check(S.list[1].slot == 2, 'the survivors renumber down behind it')

local r11, a11 = oval()
reset(r11, a11)
reorderSlots(1, 3)        -- checkpoint 1 dragged to position 3
check(a11[1].slot == 3, 'a branch gate follows the checkpoint it belongs to when it moves')
check(a11[2].slot == 2, 'and the ones it moved past shift the other way')

-- --- 9. Checkpoints are what is counted, not gates --------------------------
-- The property the whole server side rests on: the count reported upstream is
-- CHECKPOINTS CLEARED, and it means the same thing for the whole field however
-- they got round. Nothing about branch gates can change it.
local r12, a12 = oval()
reset(r12, a12)
through(r12[1]); through(r12[2])
local cwCleared = S.armedWp - 1
reset(r12, a12)
through(a12[1]); through(r12[2], -1)
check(S.armedWp - 1 == cwCleared and cwCleared == 2,
  'two checkpoints cleared is two, whichever gates cleared them')

-- --- 10. Several branch gates on ONE checkpoint -----------------------------
-- Three ways through one corner is three gates on the same slot. The old design
-- could not express this at all: one gate per slot per lane meant a third route
-- needed a third lane, and a lane is a thing a driver had to be put on.
local r13 = select(1, oval())
local three = {
  { slot = 1, x = TURN1.x, y = TURN1.y + 30, z = 0, hx = 0, hy = 1 },
  { slot = 1, x = TURN1.x, y = TURN1.y - 30, z = 0, hx = 0, hy = 1 },
}
reset(r13, three)
check(#S.bySlot[1] == 2, 'one checkpoint holds as many branch gates as were placed')
check(through(r13[1]) == true, 'the main gate clears it')
reset(r13, three)
check(through(three[1]) == true, 'so does the first branch')
reset(r13, three)
check(through(three[2]) == true, 'and so does the second')
check(S.armedWp == 2, 'each of them arms the same next checkpoint')

-- --- 11. A branch gate on the start/finish line -----------------------------
-- Nothing special about the last slot: a branch of it completes the lap exactly
-- as the main gate does, which is what a split run to the line needs.
local r14 = select(1, oval())
local lineAlt = { { slot = 4, x = LINE.x + 40, y = LINE.y, z = 0, hx = 1, hy = 0 } }
reset(r14, lineAlt)
through(r14[1]); through(r14[2]); through(r14[3])
check(S.armedWp == 4, 'three checkpoints cleared, the line armed')
check(through(lineAlt[1]) == true, 'a branch of the LINE completes the lap')
check(S.laps == 1 and S.scored == 1 and S.armedWp == 1,
  'and it is a scored lap that wraps to CP 1, like any other')

-- --- 12. One-way still means one way ---------------------------------------
-- Bidirectional gates are what make a shared corner work, but where direction is
-- the only thing separating two legs of a track, oneWay puts it back. A branch
-- gate honors the flag exactly as a main gate does.
local r15 = select(1, oval())
local oneWayAlt = { { slot = 1, x = TURN2.x, y = TURN2.y, z = 0, hx = 0, hy = 1, oneWay = true } }
reset(r15, oneWayAlt)
check(through(oneWayAlt[1], -1) == false, 'a one-way branch gate refuses the wrong way')
check(S.armedWp == 1, 'and nothing is cleared by the attempt')
check(through(oneWayAlt[1]) == true, 'the right way through it still scores')

if fails == 0 then
  print('branch_test: ' .. checks .. ' checks, 0 failures')
else
  print('branch_test: ' .. checks .. ' checks, ' .. fails .. ' FAILURES')
  os.exit(1)
end
