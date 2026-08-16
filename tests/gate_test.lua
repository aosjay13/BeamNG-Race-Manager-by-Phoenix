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
-- plane -- in EITHER direction unless the gate is marked one-way -- and the
-- intersection lands inside the width/height extents. Returns (crossed,
-- backwards); the second value is what lets a respawn face the way the car was
-- travelling rather than the way a shared gate happens to point.
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
  local lateral = (ix - wp.x) * fy - (iy - wp.y) * fx
  if math.abs(lateral) > w * 0.5 then return false end
  -- Height is UP from the placement point, depth is DOWN, so the vertical test
  -- is a range rather than a symmetric one. This is what lets a gate stand tall
  -- enough to see without an equal amount of it hanging under the road.
  local dz = iz - wp.z
  if dz > h or dz < -d then return false end
  return true, backward
end

-- Default rectangle: 20 wide, and 5 up / 5 down about the placement point.
--
-- These cases were written when height was one number meaning the FULL span,
-- centred, so the 10 they assumed is spelled out here as the 5 and 5 it always
-- was. Every expectation below is unchanged, which is the point: splitting the
-- vertical in two must not move a single gate that already exists.
local W, H, D = 20, 5, 5
local function cross(wp, prev, cur) return rectCrossesGate(wp, prev, cur, W, H, D) end

-- Gate at origin, travel direction +Y (the rectangle runs along X, edges at
-- x = ±10 and z = 100 ± 5).
local gate = { x = 0, y = 0, z = 100, hx = 0, hy = 1 }
local function P(x, y, z) return { x = x, y = y, z = z or 100 } end
local cases = {
  { 'straight through center',         P(0, -3), P(0, 3),   true  },
  { 'through near the left edge (x=-9)', P(-9, -3), P(-9, 3), true  },
  { 'outside the edges (x=15)',        P(15, -3), P(15, 3), false },
  { 'exactly at the edge (x=10)',      P(10, -3), P(10, 3), true  },
  -- Backwards through the middle now COUNTS: a driver who missed this gate and
  -- turned round has driven through it, and arming is what stops it scoring
  -- twice. The one-way variants of this case are asserted below.
  { 'backwards through the middle',    P(0, 3), P(0, -3),   true  },
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

-- Counted rather than added up by hand at the bottom. The total there was a
-- hardcoded `#cases + 18` and went stale the first time a case was added, which
-- is a test file quietly under-reporting its own coverage.
local expects = 0
local function expect(cond, msg)
  expects = expects + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- Height: a steeply banked crossing (+12 m) misses the default 10 m-tall
-- rectangle but is caught once the height is raised to cover the banking.
expect(rectCrossesGate(gate, P(0, -3, 112), P(0, 3, 112), 20, 5, 5) == false,
  'default height too short for +12 banking')
expect(rectCrossesGate(gate, P(0, -3, 112), P(0, 3, 112), 20, 15, 15) == true,
  'tall rectangle (h=30) covers +12 banking')

-- Per-checkpoint override semantics: the very same movement can hit a wide
-- rectangle and miss a narrow one at the same gate (widths 30 vs 6).
expect(rectCrossesGate(gate, P(12, -3), P(12, 3), 30, 5, 5) == true,
  'wide override (w=30) catches an x=12 pass')
expect(rectCrossesGate(gate, P(12, -3), P(12, 3), 6, 10) == false,
  'narrow override (w=6) rejects an x=12 pass')

-- Rotated gate: travel direction +X (the rectangle runs along Y).
local gate2 = { x = 50, y = 50, z = 0, hx = 1, hy = 0 }
expect(cross(gate2, {x=47,y=55,z=0}, {x=53,y=55,z=0}) == true,  'rotated: through')
expect(cross(gate2, {x=47,y=62,z=0}, {x=53,y=62,z=0}) == false, 'rotated: wide')
expect(cross(gate2, {x=53,y=50,z=0}, {x=47,y=50,z=0}) == true,  'rotated: backwards counts')

-- --- One-way gates -----------------------------------------------------------
-- The escape hatch for hairpins and figure-8 crossovers, where the only thing
-- separating two legs of a track is which way you are pointing. Same rectangle,
-- same extents; the backward crossing is the only difference.
local ow  = { x = 0, y = 0, z = 100, hx = 0, hy = 1, oneWay = true }
local ow2 = { x = 50, y = 50, z = 0, hx = 1, hy = 0, oneWay = true }
expect(cross(ow, P(0, -3), P(0, 3)) == true,  'one-way: forwards still scores')
expect(cross(ow, P(0, 3), P(0, -3)) == false, 'one-way: backwards rejected')
expect(cross(ow2, {x=53,y=50,z=0}, {x=47,y=50,z=0}) == false, 'one-way rotated: backwards rejected')

-- The extents apply identically in both directions: a backward crossing outside
-- the width or the height is no more a crossing than a forward one is.
expect(cross(gate, P(15, 3), P(15, -3)) == false, 'backwards outside the width')
expect(cross(gate, P(0, 3, 108), P(0, -3, 108)) == false, 'backwards above the rectangle')
expect(rectCrossesGate(gate, P(12, 3), P(12, -3), 30, 5, 5) == true,
  'backwards inside a wide override')

-- ---------------------------------------------------------------------------
-- Height is UP, depth is DOWN, and they are independent
-- ---------------------------------------------------------------------------
-- A gate used to be one height CENTRED on the point it was placed at, so making
-- it tall enough to see buried an equal amount of it under the road. Reported
-- from under the map, looking up at gates hanging below the terrain.
--
-- 12 up and 1 down: tall to see, barely anything below the surface.
expect(rectCrossesGate(gate, P(0, -3, 110), P(0, 3, 110), 20, 12, 1) == true,
  'a crossing 10 m up scores on a gate that reaches 12 m up')
expect(rectCrossesGate(gate, P(0, -3, 113), P(0, 3, 113), 20, 12, 1) == false,
  'and one above the top bar does not')
expect(rectCrossesGate(gate, P(0, -3, 99.5), P(0, 3, 99.5), 20, 12, 1) == true,
  'half a metre below still scores: depth is 1')
expect(rectCrossesGate(gate, P(0, -3, 98), P(0, 3, 98), 20, 12, 1) == false,
  'two metres below does not, even though the gate reaches 12 m the other way')

-- The old shape is still expressible, which is what every saved layout becomes.
expect(rectCrossesGate(gate, P(0, -3, 104), P(0, 3, 104), 20, 5, 5) == true,
  'the pre-split gate is exactly a 5-and-5, and still scores where it always did')
expect(rectCrossesGate(gate, P(0, -3, 96), P(0, 3, 96), 20, 5, 5) == true,
  'including below the placement point')

-- Depth of zero is legal: a gate that stops dead at the surface.
expect(rectCrossesGate(gate, P(0, -3, 100), P(0, 3, 100), 20, 10, 0) == true,
  'a zero-depth gate still scores at the placement height')
expect(rectCrossesGate(gate, P(0, -3, 99), P(0, 3, 99), 20, 10, 0) == false,
  'but nothing below it')

-- THE CASE THIS EXISTS FOR: a driver misses the gate down the outside, turns
-- round, and comes back through the middle. One three-point turn, not two.
expect(cross(gate, P(14, -3), P(14, 3)) == false, 'missed it down the outside')
expect(cross(gate, P(0, 3), P(0, -3)) == true,    '...and scores coming back through')

-- The second return value is the half a shared gate cannot tell you afterwards:
-- one heading, driven both ways, so the respawn has to be told which way the car
-- was actually going rather than reading it off the gate.
local _, backA = cross(gate, P(0, -3), P(0, 3))
local _, backB = cross(gate, P(0, 3), P(0, -3))
expect(backA == false, 'forwards reports backwards=false')
expect(backB == true,  'backwards reports backwards=true')

if fails == 0 then
  print('ALL PASS (' .. (#cases + expects) .. ' cases)')
else
  print(fails .. ' FAILURES')
  os.exit(1)
end
