-- Headless test for the two-pole gate crossing math in
-- lua/ge/extensions/raceManager.lua (segmentCrossesGate).
-- Run from the repo root: lua5.3 tests/gate_test.lua

-- Mirror of segmentCrossesGate (kept in sync by hand; the extension needs
-- the BeamNG GE environment and cannot be dofile'd here).
local checkpointWidth = 20
local Z_TOLERANCE = 6
local function segmentCrossesGate(wp, prev, cur)
  local dPrev = (prev.x - wp.x) * wp.hx + (prev.y - wp.y) * wp.hy
  local dCur  = (cur.x  - wp.x) * wp.hx + (cur.y  - wp.y) * wp.hy
  if not (dPrev < 0 and dCur >= 0) then return false end
  local t  = dPrev / (dPrev - dCur)
  local ix = prev.x + (cur.x - prev.x) * t
  local iy = prev.y + (cur.y - prev.y) * t
  local iz = prev.z + (cur.z - prev.z) * t
  local lateral = (ix - wp.x) * wp.hy - (iy - wp.y) * wp.hx
  if math.abs(lateral) > checkpointWidth * 0.5 then return false end
  if math.abs(iz - wp.z) > Z_TOLERANCE then return false end
  return true
end

-- Gate at origin, travel direction +Y (line runs along X, poles at x = ±10)
local gate = { x = 0, y = 0, z = 100, hx = 0, hy = 1 }
local function P(x, y, z) return { x = x, y = y, z = z or 100 } end
local cases = {
  { 'straight through center',        P(0, -2), P(0, 2),   true  },
  { 'through near left pole (x=-9)',  P(-9, -2), P(-9, 2), true  },
  { 'outside the poles (x=15)',       P(15, -2), P(15, 2), false },
  { 'exactly at pole edge (x=10)',    P(10, -2), P(10, 2), true  },
  { 'wrong direction (backwards)',    P(0, 2), P(0, -2),   false },
  { 'no crossing (both before)',      P(0, -5), P(0, -1),  false },
  { 'no crossing (both after)',       P(0, 1), P(0, 5),    false },
  { 'diagonal fast pass',             P(-8, -6), P(6, 4),  true  },
  { 'on bridge above (z+20)',         P(0, -2, 120), P(0, 2, 120), false },
  { 'landing on the plane (dCur=0)',  P(0, -3), P(0, 0),   true  },
  { 'clips corner outside pole',      P(14, -1), P(11, 1), false },
}
local fails = 0
for _, c in ipairs(cases) do
  local got = segmentCrossesGate(gate, c[2], c[3])
  if got ~= c[4] then
    fails = fails + 1
    print(('FAIL: %s (expected %s, got %s)'):format(c[1], tostring(c[4]), tostring(got)))
  end
end

-- Rotated gate: travel direction +X (line runs along Y)
local gate2 = { x = 50, y = 50, z = 0, hx = 1, hy = 0 }
assert(segmentCrossesGate(gate2, {x=48,y=55,z=0}, {x=52,y=55,z=0}) == true, 'rotated: through')
assert(segmentCrossesGate(gate2, {x=48,y=62,z=0}, {x=52,y=62,z=0}) == false, 'rotated: wide')

if fails == 0 then
  print('ALL PASS (' .. #cases + 2 .. ' cases)')
else
  print(fails .. ' FAILURES')
  os.exit(1)
end
