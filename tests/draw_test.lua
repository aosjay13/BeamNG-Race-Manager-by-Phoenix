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

local cylinders, texts = {}, {}
debugDrawer = {
  drawCylinder = function (_, a, b, radius, color)
    cylinders[#cylinders + 1] = { a = a, b = b, radius = radius, color = color }
  end,
  drawTextAdvanced = function (_, at, text)
    texts[#texts + 1] = { at = at, text = text }
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
  cylinders, texts = {}, {}
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
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })

-- ===========================================================================
-- The geometry is right
-- ===========================================================================
frame()
check(#cylinders == 12, 'three gates draw four edges each')
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
-- Global width: nothing tells the draw loop this happened, so it has to notice.
RM.setCheckpointWidth(40)
frame()
check(near(cylinders[1].a.x, -20),
  'widening every gate is picked up (the corner moves out to 20 m)')
check(near(cylinders[1].a.z, 0), 'and the height is unchanged')

-- Per-gate override: only that gate moves.
RM.setCheckpointOverride(1, 60, 20)
frame()
check(near(cylinders[1].a.x, -30) and near(cylinders[1].a.z, -5),
  'a per-gate override is picked up on that gate')
check(near(cylinders[5].a.x, -20) and near(cylinders[5].a.z, 0),
  'and leaves the gates that did not change alone')

-- Clearing the override falls back to the global default again.
RM.setCheckpointOverride(1, nil, nil)
frame()
check(near(cylinders[1].a.x, -20) and near(cylinders[1].a.z, 0),
  'clearing an override falls back to the session default')

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

if fails == 0 then
  print('draw_test: ' .. checks .. ' checks, 0 failures')
else
  print('draw_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
