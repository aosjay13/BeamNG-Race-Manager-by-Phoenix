-- Headless test for the gate drawing in lua/ge/extensions/raceManager.lua.
--
-- Why this exists: the draw loop is the only genuinely hot path in this mod --
-- it runs for every gate on every frame -- and it used to rebuild everything it
-- needed each time: four corner vectors and a label per gate, six ColorF per
-- gate. On a twenty-gate circuit that was ~100 tables and ~25 strings a frame
-- handed straight to the collector.
--
-- All of it is cached now, which moves the risk from "slow" to "wrong": a cache
-- that fails to notice a gate has changed draws the trigger somewhere the car
-- will never touch, and it does it silently. No other test in this suite reaches
-- this code at all -- they leave debugDrawer nil, so the whole draw path is
-- skipped -- so this file stubs the drawer and checks both halves: that the
-- geometry is right, and that it is actually reused.
--
-- Run from the repo root: lua5.3 tests/draw_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- ---------------------------------------------------------------------------
-- Stubs. vec3 needs real operators here: the label anchor is computed as
-- (tl + tr) * 0.5 + vec3(0, 0, 0.8), which every other harness avoids by never
-- reaching the draw path.
-- ---------------------------------------------------------------------------
local vec3Allocs = 0
local vec3mt = {}
vec3mt.__index = vec3mt
vec3mt.__add = function (a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
vec3mt.__mul = function (a, s) return vec3(a.x * s, a.y * s, a.z * s) end
vec3 = function (x, y, z)
  vec3Allocs = vec3Allocs + 1
  return setmetatable({ x = x, y = y, z = z }, vec3mt)
end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end

local colorAllocs = 0
ColorF = function (r, g, b, a) colorAllocs = colorAllocs + 1; return { r, g, b, a } end
ColorI = function (r, g, b, a) colorAllocs = colorAllocs + 1; return { r, g, b, a } end
String = function (s) return s end

local quads = {}
local cylinders, texts = {}, {}
debugDrawer = {
  drawCylinder = function (_, a, b, radius, color)
    cylinders[#cylinders + 1] = { a = a, b = b, radius = radius, color = color }
  end,
  drawTextAdvanced = function (_, at, text)
    texts[#texts + 1] = { at = at, text = text }
  end,
  -- The filled surface of an editor gate. Only the authoring view draws it.
  drawQuadSolid = function (_, a, b, c, d, color)
    quads[#quads + 1] = { a = a, b = b, c = c, d = d, color = color }
  end,
}

local veh = { id = 7, x = 0, y = 0, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation() end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end

getPlayerVehicle = function (_) return veh end
be = { getPlayerVehicle = function () return veh end }
getAllVehicles = function () return { veh } end
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
log = function () end
guihooks = { trigger = function () end }
MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function () end
local handlers = {}
AddEventHandler = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function frame()
  cylinders, texts, quads = {}, {}, {}
  RM.onUpdate(0.016)
end
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end

-- Three gates in a line, all facing +Y, 20 m wide and 10 m tall.
handlers['RM_ApplyLayout']({
  name = 'test', width = 20, height = 10,
  checkpoints = {
    { x = 0,   y = 100, z = 5, hx = 0, hy = 1 },
    { x = 0,   y = 200, z = 5, hx = 0, hy = 1 },
    { x = 0,   y = 300, z = 5, hx = 0, hy = 1 },
  },
})
-- ===========================================================================
-- Editor and race are two views of the same checkpoint
-- ===========================================================================
-- A driver in a race gets TWO POLES at the gate they are aiming at, and two more
-- at the one after it, drawn out of the same cylinders the editor rectangle is
-- built from. BeamNG's own race markers are the shape this imitates but could not
-- be made bright or solid enough to see, and could not be widened either --
-- their spacing IS the gate's width, so wider poles would mark a target that
-- does not score. Reported from a live night as
-- "racers cannot see the default BeamNG checkpoints" -- and the poles cannot
-- simply be widened to fix it, because their spacing IS the gate's width and
-- poles wider than the trigger would show a target that does not score.
--
-- What a driver must NOT get is the whole circuit: a lap's worth of numbered
-- rectangles across the racing line is the clutter this was pulled out for. Two
-- gates, no more -- the armed one and the next.
--
-- An admin with the editor open still gets the authoring view of every gate:
-- the filled surface, the number, and which way through counts.
-- A LOADED TRACK IS VISIBLE BEFORE THE LIGHTS, not only once a session starts.
--
-- Reported live: on the Race tab nothing showed until the race began, and the
-- joker LABEL hung in the air over a gate that was not drawn. drawDriverGate had
-- a phase gate; drawJokerLabel, drawing the same gate, did not, and neither did
-- the stock markers this replaced. A driver looking over a circuit they are
-- about to race wants to see it.
serverState({ phase = 'waiting', totalLaps = 3, maxResets = -1, drivers = {} })
frame()
check(#cylinders == 4,
  'the armed gate and the next are drawn while the session is still WAITING')
check(#quads == 0, 'and still as poles, not the authoring view')

serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
frame()
check(#quads == 0,
  'an ordinary checkpoint gets no FILLED surface for a driver -- that is the '
    .. 'authoring view, and a plain gate means one thing and needs no help '
    .. 'saying it. The joker and the pit box are the exceptions, below')
check(#texts == 0,
  'and NO text on them: the poles say where the gate is and the colour says which '
    .. 'one is next, so "CP 3" at racing speed is one more thing painted across '
    .. 'the racing line for nothing. Only the joker is labelled, because only its '
    .. 'text changes what a driver should do')
check(#cylinders == 4,
  'drawn as TWO POLES each and nothing else -- no top bar, because the thing '
    .. 'being marked is the line BETWEEN them at any height, and a bar reads as '
    .. 'a hoop to aim at')

serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  youAreAdmin = true })
RM.setEditorOpen(true)
frame()
check(#quads == 3, 'an admin authoring sees a filled surface per gate')

-- ===========================================================================
-- The geometry is right
-- ===========================================================================
frame()
-- Four edges and a three-part direction arrow per gate.
check(#cylinders == 21, 'three gates draw four edges and an arrow each')
check(#texts == 3, 'and one label each')

-- Gate 1 faces +Y, so its lateral axis is +X and it spans ±10 m across,
-- ±5 m vertically, centred on (0, 100, 5).
local bl, tl = cylinders[1].a, cylinders[1].b
check(near(bl.x, -10) and near(bl.y, 100) and near(bl.z, 0),
  'bottom-left corner is half a width across and half a height down')
check(near(tl.x, -10) and near(tl.y, 100) and near(tl.z, 10),
  'top-left corner is directly above it')
local br = cylinders[2].a
check(near(br.x, 10) and near(br.z, 0), 'bottom-right is the other side of centre')
check(near(texts[1].at.z, 10.8), 'the label sits just above the top edge')
check(texts[1].text == 'CP 1', 'an intermediate gate is labelled by number')
check(texts[3].text == '3 START/FINISH', 'the last gate is the start/finish line')

-- ===========================================================================
-- ...and it is reused, not rebuilt
-- ===========================================================================
-- One vec3 a frame is expected: checkGates records the car's position for next
-- frame's crossing segment. Everything else has to come out of the cache.
vec3Allocs, colorAllocs = 0, 0
frame()
check(vec3Allocs <= 1,
  'a steady frame allocates no gate geometry at all (got ' .. vec3Allocs .. ')')
check(colorAllocs == 0, 'and no colours (got ' .. colorAllocs .. ')')

vec3Allocs = 0
for _ = 1, 10 do frame() end
check(vec3Allocs <= 10, 'and stays that way frame after frame (got ' .. vec3Allocs .. ')')

-- The drawn corners must still be the SAME values, not just cheap ones.
frame()
check(near(cylinders[1].a.x, -10) and near(cylinders[1].a.z, 0),
  'a cached gate draws where an uncached one did')

-- ===========================================================================
-- A cache that misses a change is worse than no cache
-- ===========================================================================
-- The global default no longer reaches a gate that has already been placed.
-- It used to, and nudging that slider resized a whole circuit retroactively
-- with nothing to undo it; a placed gate now owns its size.
local wasX = cylinders[1].a.x
RM.setCheckpointWidth(40)
frame()
check(near(cylinders[1].a.x, wasX),
  'changing the default does NOT resize gates that are already placed')

-- Per-gate override: only that gate moves.
--
-- HEIGHT IS UP AND DEPTH IS DOWN, measured from the placement point, so a gate
-- can stand tall enough to see without an equal amount of it hanging under the
-- road. The gates here sit at z = 5, so a 20/3 gate runs from 2 up to 25.
RM.setCheckpointOverride(1, 60, 20, 3)
frame()
check(near(cylinders[1].a.x, -30) and near(cylinders[1].a.z, 2),
  'a per-gate override is picked up on that gate, and DEPTH puts the bottom bar '
    .. '3 m below the placement point rather than half the height below it')
check(near(cylinders[1].b.z, 25),
  'while HEIGHT puts the top bar 20 m above it: the two ends are independent')
-- Each gate emits four edges then a three-part arrow, so gate 2's first edge
-- is index 8.
check(near(cylinders[8].a.x, -10) and near(cylinders[8].a.z, 0),
  'and leaves the gates that did not change alone, at the size they were loaded '
    .. 'with: this layout predates depth, so its 10 was a full centred span and '
    .. 'migrates to 5 up and 5 down, which is the same gate it always was')

-- Clearing the override falls back to the global default again.
RM.setCheckpointOverride(1, nil, nil, nil)
frame()
check(near(cylinders[1].a.x, -20) and near(cylinders[1].a.z, 0),
  'clearing an override falls back to the session default, which was migrated '
    .. 'the same way the gates were rather than being left as a raw 10')

-- ===========================================================================
-- Labels follow the route, and the route can change under them
-- ===========================================================================
handlers['RM_ApplyLayout']({
  name = 'shorter', width = 20, height = 10,
  checkpoints = {
    { x = 0, y = 100, z = 5, hx = 0, hy = 1 },
    { x = 0, y = 200, z = 5, hx = 0, hy = 1 },
  },
})
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
frame()
check(#texts == 2, 'a shorter route draws fewer gates')
check(texts[2].text == '2 START/FINISH',
  'and the new last gate becomes the start/finish line')
check(texts[1].text == 'CP 1', 'while the rest keep their numbers')

-- ===========================================================================
-- Joker gates: three label states, none of them built per frame
-- ===========================================================================
handlers['RM_ApplyLayout']({
  name = 'joker', width = 20, height = 10,
  checkpoints = { { x = 0, y = 100, z = 5, hx = 0, hy = 1 } },
  joker = {
    { x = 50, y = 100, z = 5, hx = 0, hy = 1 },
    { x = 50, y = 200, z = 5, hx = 0, hy = 1 },
  },
})
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1,
  jokerEnabled = true, drivers = {} })
frame()
-- Lap 1: the joker route is closed, and says so.
check(texts[2].text == 'JOKER 1/2 (lap 1: closed)', 'a joker gate says it is closed on lap 1')
check(texts[3].text == 'JOKER EXIT (lap 1: closed)', 'including the exit gate')

vec3Allocs = 0
frame()
check(vec3Allocs <= 1, 'joker gates are cached too (got ' .. vec3Allocs .. ')')

-- ===========================================================================
-- The derby arena: same problem, same fix
-- ===========================================================================
-- A perimeter is a pole and a rope span per marker, redrawn every frame for the
-- whole length of a derby. The cache is keyed on the boundary table's identity,
-- which only works because a broadcast that changes nothing keeps the table it
-- already had -- so both halves are checked here.
local function derbyState(t) t.rmProtocol = 2; handlers['RM_DerbyUpdate'](t) end
local square = {
  { x = 0,   y = 0,   z = 0 },
  { x = 100, y = 0,   z = 0 },
  { x = 100, y = 100, z = 0 },
  { x = 0,   y = 100, z = 0 },
}
local function markers()
  local out = {}
  for i, m in ipairs(square) do out[i] = { x = m.x, y = m.y, z = m.z } end
  return out
end

-- --- The driving view -------------------------------------------------------
-- A live derby is gameplay, not an editor: translucent walls, a rail to read the
-- edge by, and NOTHING else. No labels, no corner numbers, no floor -- an
-- eliminated driver spectating an arena covered in authoring furniture is the
-- exact thing this split exists to stop.
-- Close the race editor first: its filled gate surfaces are quads too, and
-- everything below counts quads to tell walls apart from floors.
RM.setEditorOpen(false)
derbyState({ derbyPhase = 'running', boundary = markers(), players = {},
  oobLimit = 5, demoLimit = 10 })
cylinders, texts, quads = {}, {}, {}
RM.onUpdate(0.016)
-- One panel per edge, drawn twice with the winding reversed: drivers stand
-- INSIDE this box, which is the one view a single-sided quad is invisible from.
check(#quads == 8, 'four walls, each drawn from both sides (got ' .. #quads .. ')')
local back = 0
for i = 1, #quads - 1, 2 do
  local f, b = quads[i], quads[i + 1]
  if f.a == b.d and f.b == b.c and f.c == b.b and f.d == b.a then back = back + 1 end
end
check(back == 4, 'the second copy of each wall is wound the other way')
check(#texts == 0, 'a live arena carries no labels at all')

vec3Allocs, colorAllocs = 0, 0
frame()
check(vec3Allocs <= 1, 'a steady derby frame allocates no arena geometry (got '
  .. vec3Allocs .. ')')
check(colorAllocs == 0, 'and no colours')

-- A broadcast that changes nothing must not invalidate anything. This is the
-- part that makes the cache worth having: the server pushes derby state once a
-- second, and every push used to install a brand new boundary table.
derbyState({ derbyPhase = 'running', boundary = markers(), players = {},
  oobLimit = 5, demoLimit = 10 })
vec3Allocs = 0
frame()
check(vec3Allocs <= 1,
  'an unchanged arena survives a rebroadcast intact (got ' .. vec3Allocs .. ')')

-- A marker that actually moves must be picked up.
square[2].x = 250
derbyState({ derbyPhase = 'running', boundary = markers(), players = {},
  oobLimit = 5, demoLimit = 10 })
quads = {}
RM.onUpdate(0.016)
local moved = false
for _, q in ipairs(quads) do
  if math.abs(q.a.x - 250) < 1e-6 then moved = true end
end
check(moved, 'a marker that moves is redrawn where it moved to')

-- ...and so is one that is added.
square[#square + 1] = { x = 50, y = 150, z = 0 }
derbyState({ derbyPhase = 'running', boundary = markers(), players = {},
  oobLimit = 5, demoLimit = 10 })
quads = {}
RM.onUpdate(0.016)
check(#quads == 10, 'a marker added to the arena grows the wall run')

-- Wall height is server-owned and changes the geometry without any marker
-- moving, so the cache has to key on it as well. It used to key on the boundary
-- table alone, which would have redrawn a resized arena at its old height.
derbyState({ derbyPhase = 'running', boundary = markers(), players = {},
  oobLimit = 5, demoLimit = 10, wallHeight = 12 })
quads = {}
RM.onUpdate(0.016)
local tallest = 0
for _, q in ipairs(quads) do
  if q.d.z > tallest then tallest = q.d.z end
end
check(near(tallest, 12), 'a wall height change is picked up (got ' .. tallest .. ')')

-- WALL DEPTH: how far the wall drops BELOW the boundary plane, and the other
-- half of the same problem the race gates had. It was a hardcoded 1.5 with no
-- way to change it, so on uneven ground the wall floated over every dip.
--
-- Part of the draw cache key for the same reason height is: it changes the
-- geometry without a single marker moving, and a cache that missed it would go
-- on drawing the arena at its old skirt.
derbyState({ derbyPhase = 'running', boundary = markers(), players = {},
  oobLimit = 5, demoLimit = 10, wallHeight = 12, wallDepth = 4 })
quads = {}
RM.onUpdate(0.016)
local lowest = math.huge
for _, q in ipairs(quads) do
  for _, pt in ipairs({ q.a, q.b, q.c, q.d }) do
    if pt.z < lowest then lowest = pt.z end
  end
end
check(near(lowest, -4),
  'a wall depth change is picked up and drops the wall below the boundary (got '
    .. lowest .. ')')

derbyState({ derbyPhase = 'running', boundary = markers(), players = {},
  oobLimit = 5, demoLimit = 10, wallHeight = 12, wallDepth = 0 })
quads = {}
RM.onUpdate(0.016)
lowest = math.huge
for _, q in ipairs(quads) do
  for _, pt in ipairs({ q.a, q.b, q.c, q.d }) do
    if pt.z < lowest then lowest = pt.z end
  end
end
check(near(lowest, 0),
  'and zero depth stops the wall dead at the boundary plane (got ' .. lowest .. ')')

-- --- The editor view --------------------------------------------------------
-- The same boundary, drawn for somebody laying it out: the extent stated
-- exactly, every corner numbered, and the arena named.
square[#square] = nil                                  -- back to a four-corner box
square[2].x = 100
serverState({ phase = 'waiting', totalLaps = 3, maxResets = -1, drivers = {},
  youAreAdmin = true })
derbyState({ derbyPhase = 'idle', boundary = markers(), players = {},
  oobLimit = 5, demoLimit = 10 })
RM.setDerbyEditorOpen(true)
cylinders, texts, quads = {}, {}, {}
RM.onUpdate(0.016)
local labelled, numbered = false, 0
for _, t in ipairs(texts) do
  if t.text == 'DERBY BOUNDARY (4)' then labelled = true end
  if t.text:match('^M%d+$') then numbered = numbered + 1 end
end
check(labelled, 'the editor names the arena and its marker count')
check(numbered == 4, 'and numbers every corner (got ' .. numbered .. ')')

-- The editor draws no floor for a hand-driven arena: filling an arbitrary
-- polygon means triangulating it, and a fan from vertex 1 paints outside a
-- concave shape -- which a demo arena very often is.
check(#quads == 8, 'a drive-and-place arena is walls only, no floor')

-- --- The rectangle ----------------------------------------------------------
-- Four corners derived from a centre, and the one shape convex enough to fill
-- safely. The dimensions go in the label, so the sliders have a readout.
local rectBoundary = {
  { x = -50, y = -30, z = 4 }, { x = 50, y = -30, z = 4 },
  { x = 50,  y = 30,  z = 4 }, { x = -50, y = 30, z = 4 },
}
derbyState({ derbyPhase = 'idle', boundary = rectBoundary, players = {},
  oobLimit = 5, demoLimit = 10, boundaryMode = 'rect', wallHeight = 6,
  shape = { cx = 0, cy = 0, cz = 4, halfW = 50, halfL = 30, rot = 0 } })
cylinders, texts, quads = {}, {}, {}
RM.onUpdate(0.016)
check(#quads == 9, 'a rectangle adds one floor quad to its four walls')
local sized = false
for _, t in ipairs(texts) do
  if t.text == 'DERBY ARENA: 100 x 60 m' then sized = true end
end
check(sized, 'the editor reads the rectangle back in metres')

-- Closing the editor drops every authoring visual, even standing still in an
-- idle derby -- the panel is the gate, not the phase.
RM.setDerbyEditorOpen(false)
cylinders, texts, quads = {}, {}, {}
RM.onUpdate(0.016)
check(#texts == 0 and #quads == 8,
  'closing the derby editor leaves the driving view behind')

-- ===========================================================================
-- A gate keeps its own size, and passes it to the next one placed
-- ===========================================================================
-- There used to be one global width/height that every gate without an override
-- read live, so nudging a slider resized the whole circuit at once,
-- retroactively, with nothing to undo it. A gate now takes its size when it is
-- placed and keeps it.
RM.setEditorOpen(false)
-- Own the world: anything still placed by an earlier case draws too -- the
-- other routes, the starting grid, and the derby arena above.
derbyState({ derbyPhase = 'idle', boundary = {}, players = {}, starts = {} })
for _, t in ipairs({ 'joker', 'pit', 'start', 'main' }) do
  RM.setEditorTarget(t); RM.editorClear()
end
veh.x, veh.y, veh.z = 0, 10, 0; RM.editorAdd()
RM.setCheckpointOverride(1, 44, 12)
veh.x, veh.y, veh.z = 0, 20, 0; RM.editorAdd()
veh.x, veh.y, veh.z = 0, 30, 0; RM.editorAdd()
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  youAreAdmin = true })
RM.setEditorOpen(true)
frame()
check(#cylinders == 21, 'three gates are drawn')
check(near(cylinders[1].a.x, -22), 'a resized gate is 22 m either side of centre')
check(near(cylinders[8].a.x, -22), 'the gate placed after it inherited that size')
check(near(cylinders[15].a.x, -22), 'and so did the one after that')

-- Changing one gate now moves ONLY that gate.
RM.setCheckpointOverride(2, 10, 4)
frame()
check(near(cylinders[8].a.x, -5), 'resizing a gate changes that gate')
check(near(cylinders[1].a.x, -22), 'and leaves the one before it alone')
check(near(cylinders[15].a.x, -22), 'and the one after it alone')
RM.setEditorOpen(false)


-- ===========================================================================
-- The joker wears its state, and the pit stall is drawn as the box it tests
-- ===========================================================================
-- These two are the exceptions to "a driver gets poles and nothing else", and
-- both earn it the same way: what the driver has to DO changes with state, and
-- getting either wrong costs them the race.
-- A running derby correctly suppresses every race gate, so it is stood down
-- first: a checkpoint hanging over a demolition arena is debris. This block
-- lives at the END of the file because doing that mid-way disturbs the derby
-- sections above, which is worth one comment to save the next person the hunt.
derbyState({ derbyPhase = 'idle', boundary = {}, players = {},
  oobLimit = 5, demoLimit = 10 })
RM.setDerbyEditorOpen(false)
RM.setEditorOpen(false)
handlers['RM_ApplyLayout']({
  name = 'joker + pits', width = 20, height = 10,
  checkpoints = {
    { x = 0, y = 100, z = 5, hx = 0, hy = 1 },
    { x = 0, y = 200, z = 5, hx = 0, hy = 1 },
  },
  joker = { { x = 50, y = 150, z = 5, hx = 1, hy = 0 } },
  pits  = { { x = -50, y = 100, z = 5, hx = 1, hy = 0 } },
})
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  jokerEnabled = true })
cylinders, texts, quads = {}, {}, {}
frame()

-- The joker: a fill behind it so the words have something to sit on, and the
-- label ON the gate rather than floating over its top edge where it can end up
-- against the sky with nothing behind it.
local jokerText
for _, t in ipairs(texts) do
  if t.text:find('JOKER', 1, true) then jokerText = t end
end
check(jokerText ~= nil, 'the joker still says which gate it is and what state it is in')
check(near(jokerText.at.z, 5),
  'and the label sits at the middle of the gate face, not above its top edge '
    .. '(got z=' .. tostring(jokerText.at.z) .. ')')
check(#quads > 0, 'the joker gate is filled, faintly, so the text reads against it')

-- Lap 1 with the joker enabled is the forbidden state, and a cross says so
-- faster than a sentence read at racing speed.
-- The glyph strokes are the only cylinders passing through the gate's own
-- CENTRE: its poles stand at the edges, ten metres out either side.
local through = 0
for _, c in ipairs(cylinders) do
  local mx = (c.a.x + c.b.x) * 0.5
  local my = (c.a.y + c.b.y) * 0.5
  local mz = (c.a.z + c.b.z) * 0.5
  local dx, dy, dz = mx - 50, my - 150, mz - 5
  if math.sqrt(dx * dx + dy * dy + dz * dz) < 3 then through = through + 1 end
end
check(through >= 2,
  'a CROSS is drawn across a joker that is shut on lap 1: two strokes through '
    .. 'the gate centre, where its poles never reach (got ' .. through .. ')')

local jokerLabels = 0
for _, t in ipairs(texts) do
  if t.text:find('JOKER', 1, true) then jokerLabels = jokerLabels + 1 end
end
check(jokerLabels == 1,
  'and it is labelled ONCE. drawJokerLabel and drawPoleGate both drew it, at '
    .. 'the same point, so the duplication was invisible until the driver label '
    .. 'moved onto the gate face and the two separated')

-- The pit box: the footprint pit.inside actually tests, which is the gate's
-- width across and PIT_DEPTH either way ALONG. Two poles used to show a plane
-- for a rule that is a volume, while the mod asked the driver to stop in a box
-- it never drew.
local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
for _, q in ipairs(quads) do
  for _, pt in ipairs({ q.a, q.b, q.c, q.d }) do
    if pt.x < -20 then           -- the pit stall is out at x = -50
      if pt.x < minX then minX = pt.x end
      if pt.x > maxX then maxX = pt.x end
      if pt.y < minY then minY = pt.y end
      if pt.y > maxY then maxY = pt.y end
    end
  end
end
-- The stall faces +X, so PIT_DEPTH runs along X and the width runs along Y.
check(near(maxX - minX, 6),
  'the box runs PIT_DEPTH either way along the stall (6 m, got '
    .. tostring(maxX - minX) .. ')')
check(near(maxY - minY, 20),
  'and the gate width across it (20 m, got ' .. tostring(maxY - minY) .. ')')

if fails == 0 then
  print('draw_test: ' .. checks .. ' checks, 0 failures')
else
  print('draw_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end

