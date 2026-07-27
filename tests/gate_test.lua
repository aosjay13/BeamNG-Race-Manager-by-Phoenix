-- Headless test for the flat-rectangle checkpoint-crossing math in
-- lua/ge/extensions/raceManager.lua (rectCrossesGate).
-- Run from the repo root: lua5.3 tests/gate_test.lua
--
-- Mirror of rectCrossesGate (kept in sync by hand; the extension needs the
-- BeamNG GE environment and cannot be dofile'd here). A checkpoint is an
-- upright rectangle centered on wp.x/y/z, standing perpendicular to the
-- heading (hx, hy), with local axes:
--   forward f = (hx, hy)   the direction the car must be travelling
--   lateral r = (hy, -hx)  span = width
--   up      z              span = height  (covers banking)
-- The gate scores when the frame-to-frame segment crosses the rectangle's
-- plane forwards and the intersection lands inside the width/height extents.
local function rectCrossesGate(wp, prev, cur, w, h)
  local fx, fy = wp.hx, wp.hy

  local dPrev = (prev.x - wp.x) * fx + (prev.y - wp.y) * fy
  local dCur  = (cur.x  - wp.x) * fx + (cur.y  - wp.y) * fy
  if not (dPrev < 0 and dCur >= 0) then return false end

  local t  = dPrev / (dPrev - dCur)
  local ix = prev.x + (cur.x - prev.x) * t
  local iy = prev.y + (cur.y - prev.y) * t
  local iz = prev.z + (cur.z - prev.z) * t
  local lateral = (ix - wp.x) * fy - (iy - wp.y) * fx
  if math.abs(lateral) > w * 0.5 then return false end
  if math.abs(iz - wp.z) > h * 0.5 then return false end
  return true
end

-- Default rectangle (mirror of the client tunables): 20 wide, 10 tall ->
-- half-extents 10 (lateral) and 5 (vertical).
local W, H = 20, 10
local function cross(wp, prev, cur) return rectCrossesGate(wp, prev, cur, W, H) end

-- Gate at origin, travel direction +Y (the rectangle runs along X, edges at
-- x = ±10 and z = 100 ± 5).
local gate = { x = 0, y = 0, z = 100, hx = 0, hy = 1 }
local function P(x, y, z) return { x = x, y = y, z = z or 100 } end
local cases = {
  { 'straight through center',         P(0, -3), P(0, 3),   true  },
  { 'through near the left edge (x=-9)', P(-9, -3), P(-9, 3), true  },
  { 'outside the edges (x=15)',        P(15, -3), P(15, 3), false },
  { 'exactly at the edge (x=10)',      P(10, -3), P(10, 3), true  },
  { 'wrong direction (backwards)',     P(0, 3), P(0, -3),   false },
  { 'no crossing (both before)',       P(0, -6), P(0, -3),  false },
  { 'no crossing (both after)',        P(0, 3), P(0, 6),    false },
  { 'diagonal fast pass',              P(-8, -6), P(6, 4),  true  },
  { 'on a bridge above (z+20)',        P(0, -3, 120), P(0, 3, 120), false },
  { 'landing exactly on the plane',    P(0, -3), P(0, 0),   true  },
  { 'clips the corner outside the edge', P(14, -1.5), P(11, 1.5), false },
  -- Banking within the 10 m default height (±5) still hits...
  { 'banked crossing (z+4)',           P(0, -3, 104), P(0, 3, 104), true },
  -- ...but a crossing beyond the height half-extent does not.
  { 'crossing above the rectangle (z+8)', P(0, -3, 108), P(0, 3, 108), false },
  -- A car creeping up to the gate has not crossed it yet; the very next frame
  -- that takes it past the plane is the one that scores.
  { 'creeping short of the plane',     P(0, -1), P(0, -0.8), false },
  { 'creeping over the plane',         P(0, -0.2), P(0, 0.1), true },
  -- Zero thickness is not a tunnelling problem: the segment is what is tested,
  -- so an absurdly fast pass still registers exactly once.
  { 'very fast pass (200 m in a frame)', P(0, -100), P(0, 100), true },
}
local fails = 0
for _, c in ipairs(cases) do
  local got = cross(gate, c[2], c[3])
  if got ~= c[4] then
    fails = fails + 1
    print(('FAIL: %s (expected %s, got %s)'):format(c[1], tostring(c[4]), tostring(got)))
  end
end

local function expect(cond, msg)
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- Height: a steeply banked crossing (+12 m) misses the default 10 m-tall
-- rectangle but is caught once the height is raised to cover the banking.
expect(rectCrossesGate(gate, P(0, -3, 112), P(0, 3, 112), 20, 10) == false,
  'default height too short for +12 banking')
expect(rectCrossesGate(gate, P(0, -3, 112), P(0, 3, 112), 20, 30) == true,
  'tall rectangle (h=30) covers +12 banking')

-- Per-checkpoint override semantics: the very same movement can hit a wide
-- rectangle and miss a narrow one at the same gate (widths 30 vs 6).
expect(rectCrossesGate(gate, P(12, -3), P(12, 3), 30, 10) == true,
  'wide override (w=30) catches an x=12 pass')
expect(rectCrossesGate(gate, P(12, -3), P(12, 3), 6, 10) == false,
  'narrow override (w=6) rejects an x=12 pass')

-- Rotated gate: travel direction +X (the rectangle runs along Y).
local gate2 = { x = 50, y = 50, z = 0, hx = 1, hy = 0 }
expect(cross(gate2, {x=47,y=55,z=0}, {x=53,y=55,z=0}) == true,  'rotated: through')
expect(cross(gate2, {x=47,y=62,z=0}, {x=53,y=62,z=0}) == false, 'rotated: wide')
expect(cross(gate2, {x=53,y=50,z=0}, {x=47,y=50,z=0}) == false, 'rotated: backwards')

if fails == 0 then
  print('ALL PASS (' .. (#cases + 7) .. ' cases)')
else
  print(fails .. ' FAILURES')
  os.exit(1)
end
