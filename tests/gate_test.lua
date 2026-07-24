-- Headless test for the 3D Oriented Bounding Box checkpoint-crossing math in
-- lua/ge/extensions/raceManager.lua (obbCrossesGate).
-- Run from the repo root: lua5.3 tests/gate_test.lua
--
-- Mirror of obbCrossesGate (kept in sync by hand; the extension needs the
-- BeamNG GE environment and cannot be dofile'd here). A checkpoint is a box
-- centered on wp.x/y/z, oriented by the heading (hx, hy), with local axes:
--   forward f = (hx, hy)   thickness = depth   (forward "line thickness")
--   lateral r = (hy, -hx)  span      = width   (between the poles)
--   up      z              span      = height  (covers banking)
-- A forward pass registers either by the current point landing inside the box,
-- or by the frame segment crossing the box's center plane in the forward
-- direction within the width/height half-extents (tunnel guard).
local function obbCrossesGate(wp, prev, cur, w, h, d)
  local fx, fy = wp.hx, wp.hy
  local moveF = (cur.x - prev.x) * fx + (cur.y - prev.y) * fy
  if moveF < 0 then return false end

  local dx, dy, dz = cur.x - wp.x, cur.y - wp.y, cur.z - wp.z
  local lf = dx * fx + dy * fy
  local lr = dx * fy - dy * fx
  if math.abs(lf) <= d * 0.5 and math.abs(lr) <= w * 0.5
      and math.abs(dz) <= h * 0.5 then
    return true
  end

  local dPrev = (prev.x - wp.x) * fx + (prev.y - wp.y) * fy
  local dCur  = lf
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

-- Default box dimensions (mirror of the client tunables): 20 wide, 10 tall,
-- 4 deep -> half-extents 10 (lateral), 5 (vertical), 2 (forward).
local W, H, D = 20, 10, 4
local function cross(wp, prev, cur) return obbCrossesGate(wp, prev, cur, W, H, D) end

-- Gate at origin, travel direction +Y (line runs along X, poles at x = ±10).
-- Y offsets are ±3 so the "before/after" cases sit clear of the 4 m depth.
local gate = { x = 0, y = 0, z = 100, hx = 0, hy = 1 }
local function P(x, y, z) return { x = x, y = y, z = z or 100 } end
local cases = {
  { 'straight through center',        P(0, -3), P(0, 3),   true  },
  { 'through near left pole (x=-9)',   P(-9, -3), P(-9, 3), true  },
  { 'outside the poles (x=15)',        P(15, -3), P(15, 3), false },
  { 'exactly at pole edge (x=10)',     P(10, -3), P(10, 3), true  },
  { 'wrong direction (backwards)',     P(0, 3), P(0, -3),   false },
  { 'no crossing (both before)',       P(0, -6), P(0, -3),  false },
  { 'no crossing (both after)',        P(0, 3), P(0, 6),    false },
  { 'diagonal fast pass',              P(-8, -6), P(6, 4),  true  },
  { 'on bridge above (z+20)',          P(0, -3, 120), P(0, 3, 120), false },
  { 'landing in the box (dCur=0)',     P(0, -3), P(0, 0),   true  },
  { 'clips corner outside pole',       P(14, -1.5), P(11, 1.5), false },
  -- Banking within the 10 m default height (±5) still hits...
  { 'banked crossing (z+4)',           P(0, -3, 104), P(0, 3, 104), true },
  -- ...but a crossing beyond the height half-extent does not.
  { 'crossing above the box (z+8)',    P(0, -3, 108), P(0, 3, 108), false },
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

-- Height: a steeply banked crossing (+12 m) misses the default 10 m-tall box
-- but is caught once the box height is raised to cover the banking.
expect(obbCrossesGate(gate, P(0, -3, 112), P(0, 3, 112), 20, 10, 4) == false,
  'default height too short for +12 banking')
expect(obbCrossesGate(gate, P(0, -3, 112), P(0, 3, 112), 20, 30, 4) == true,
  'tall box (h=30) covers +12 banking')

-- Depth (forward thickness): a car creeping forward but not reaching the center
-- plane this frame still registers if it is inside a thick enough box; a thin
-- box misses it (would need a clean center-plane crossing instead).
expect(obbCrossesGate(gate, P(0, -1), P(0, -0.8), 20, 10, 1) == false,
  'thin box (d=1) misses a car short of the center plane')
expect(obbCrossesGate(gate, P(0, -1), P(0, -0.8), 20, 10, 2) == true,
  'thick box (d=2) triggers on a car inside the forward slab')

-- Per-checkpoint override semantics: the very same movement can hit a wide box
-- and miss a narrow one at the same gate (widths 30 vs 6).
expect(obbCrossesGate(gate, P(12, -3), P(12, 3), 30, 10, 4) == true,
  'wide override (w=30) catches an x=12 pass')
expect(obbCrossesGate(gate, P(12, -3), P(12, 3), 6, 10, 4) == false,
  'narrow override (w=6) rejects an x=12 pass')

-- Rotated gate: travel direction +X (line runs along Y).
local gate2 = { x = 50, y = 50, z = 0, hx = 1, hy = 0 }
expect(cross(gate2, {x=47,y=55,z=0}, {x=53,y=55,z=0}) == true,  'rotated: through')
expect(cross(gate2, {x=47,y=62,z=0}, {x=53,y=62,z=0}) == false, 'rotated: wide')
expect(cross(gate2, {x=53,y=50,z=0}, {x=47,y=50,z=0}) == false, 'rotated: backwards')

if fails == 0 then
  print('ALL PASS (' .. (#cases + 9) .. ' cases)')
else
  print(fails .. ' FAILURES')
  os.exit(1)
end
