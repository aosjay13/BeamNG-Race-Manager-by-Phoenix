-- Headless test for NUDGE MODE in lua/ge/extensions/raceManager.lua: moving and
-- turning placed gates with the mouse from free cam.
--
-- Run from the repo root: lua5.3 tests/nudge_test.lua
--
-- Two things are being protected here, and the second is the reason this file
-- exists at all.
--
-- THE MATHS. Picking a gate off a camera ray, turning a heading without letting
-- it drift off the unit circle, and moving a gate across terrain while keeping
-- the height it was authored at. All of it is testable without a game.
--
-- THE WIRING. `nudge` is one table reached from the frame loop, from the
-- drawing, and from pushRouteState, and all three of those run ABOVE the point
-- where it would naturally be defined. A local declared too late is not an
-- error in Lua: it silently becomes a nil GLOBAL, the file compiles, every test
-- that does not actually call the code passes, and the mod dies the first time
-- somebody drags a gate. That already happened once while this was being
-- written. So the frame loop is driven here with the editor open, which is what
-- makes the reference real.

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- Engine stubs
-- ---------------------------------------------------------------------------
local sent, hooks, handlers = {}, {}, {}
local routeState = nil
local VEH_ID = 7

-- The mouse, as ui_imgui reports it.
local mouse = { clicked = false, down = false, released = false, wheel = 0, wantUi = false }
ui_imgui = {
  IsMouseClicked  = function () return mouse.clicked end,
  IsMouseDown     = function () return mouse.down end,
  IsMouseReleased = function () return mouse.released end,
  GetIO = function ()
    return { WantCaptureMouse = mouse.wantUi, MouseWheel = mouse.wheel }
  end,
}

-- Where the cursor ray starts, where it points, and what it lands on. The
-- engine gives these as two separate calls and the mod uses both: the ray to
-- pick a gate out of the air, the raycast to find the ground under the cursor.
local ray = { pos = { x = 0, y = 0, z = 50 }, dir = { x = 0, y = 1, z = 0 } }
local rayHit = { pos = { x = 0, y = 0, z = 0 }, normal = { x = 0, y = 0, z = 1 } }
getCameraMouseRay = function () return ray end
cameraMouseRayCast = function () return rayHit end
-- Flat ground at z = 0: the ray starts 50 above and travels 50 to reach it.
castRayStatic = function (origin, dir, maxDist) return 50 end

local cursorShown = nil
core_canvas = {
  showCursor = function () cursorShown = true end,
  hideCursor = function () cursorShown = false end,
}

local veh = { id = VEH_ID, x = 0, y = 0, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end
function veh:getSpawnWorldOOBB() return nil end

getPlayerVehicle = function () return veh end
be = { getPlayerVehicle = function () return veh end, enterVehicle = function () end }
getAllVehicles = function () return { veh } end
getObjectByID = function (id) return id == VEH_ID and veh or nil end
MPVehicleGE = {
  isOwn = function (id) return id == VEH_ID end,
  getVehicles = function () return { { ownerID = 1, gameVehicleID = VEH_ID } } end,
}
core_vehicleBridge = { executeAction = function () end }
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
core_vehicles = { removeCurrent = function () end }
beamng_version = '0.39.4.0'

local V = {}
V.__index = V
V.__add = function (a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, V) end
V.__mul = function (a, s) return setmetatable({ x = a.x * s, y = a.y * s, z = a.z * s }, V) end
vec3 = function (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log = function () end
guihooks = { trigger = function (e, p)
  hooks[#hooks + 1] = { event = e, payload = p }
  if e == 'RaceManagerRoute' then routeState = p end
end }
ColorF = function () return {} end
ColorI = function () return {} end
String = function (s) return s end
debugDrawer = {
  drawCylinder = function () end,
  drawTextAdvanced = function () end,
  drawSphere = function () end,
  drawLine = function () end,
  drawQuadSolid = function () end,
}
MPGameNetwork = {}
MPConfig = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function frame() RM.onUpdate(1 / 60) end
local function serverState(t) t.rmProtocol = 2; t.raceTime = 0; handlers['RM_Update'](t) end
local function gates() return (routeState or {}).waypoints or {} end

-- Point the cursor ray at a spot on flat ground, from 50 metres up and behind.
local function aimAt(x, y)
  ray.pos = { x = x, y = y - 50, z = 50 }
  local d = math.sqrt(50 * 50 + 50 * 50)
  ray.dir = { x = 0, y = 50 / d, z = -50 / d }
  rayHit.pos = { x = x, y = y, z = 0 }
end
local function clickAt(x, y)
  aimAt(x, y)
  mouse.clicked, mouse.down, mouse.released = true, true, false
  frame()
  mouse.clicked = false
end
local function dragTo(x, y)
  aimAt(x, y)
  mouse.clicked, mouse.down, mouse.released = false, true, false
  frame()
end
local function letGo()
  mouse.down, mouse.released = false, true
  frame()
  mouse.released = false
end

-- A three-gate circuit, 100 metres apart on the Y axis, all facing +Y.
RM.setEditorTarget('main')
for i = 1, 3 do
  veh.x, veh.y, veh.z = 0, i * 100, 0
  RM.editorAdd()
end
serverState({ phase = 'waiting', totalLaps = 3, maxResets = -1, drivers = {},
  youAreAdmin = true })
RM.setEditorOpen(true)

-- ===========================================================================
-- The mode is off until it is asked for, and the mouse stays the camera's
-- ===========================================================================
frame()
check(cursorShown == nil, 'nothing touches the cursor before the mode is turned on')
check(routeState and routeState.nudgeOn == false, 'and the UI is told the mode is off')

clickAt(0, 100)
check(gates()[1].y == 100, 'a click with the mode off moves nothing')

-- ===========================================================================
-- Turning it on borrows the mouse. Turning it off gives it back.
-- ===========================================================================
RM.setNudgeMode(true)
check(cursorShown == true, 'the cursor is released so the camera stops eating the mouse')
check(routeState and routeState.nudgeOn == true, 'and the UI is told')

RM.setNudgeMode(false)
check(cursorShown == false, 'turning it off hands the mouse straight back')

-- Closing the editor has to hand it back too, or the camera stops answering
-- with nothing on screen to explain why.
RM.setNudgeMode(true)
RM.setEditorOpen(false)
check(cursorShown == false, 'closing the editor releases the mode and the cursor')
RM.setEditorOpen(true)

-- ===========================================================================
-- Pick, drag, drop
-- ===========================================================================
RM.setNudgeMode(true)
clickAt(0, 200)
check(routeState and routeState.nudgeSel == 2,
  'clicking near a gate selects it, by its CENTRE: two overlapping rectangles '
    .. 'are exactly where a generous pick radius chooses the wrong one')

dragTo(40, 240)
local g = gates()[2]
check(g and math.abs(g.x - 40) < 0.01 and math.abs(g.y - 240) < 0.01,
  'dragging moves the selected gate to the ground under the cursor')
check(gates()[1].y == 100 and gates()[3].y == 300, 'and moves nothing else')

letGo()
dragTo(400, 400)
check(math.abs(gates()[2].x - 40) < 0.01,
  'a drag after the button is released moves nothing: the grab has to be held')

-- A click on empty ground drops the selection rather than grabbing whatever was
-- nearest. Clicking away from everything means "nothing", not "the far end".
clickAt(900, 900)
check(routeState and routeState.nudgeSel == nil,
  'clicking well away from every gate clears the selection')

-- ===========================================================================
-- The scroll wheel turns the gate it has hold of
-- ===========================================================================
clickAt(40, 240)
letGo()
local before = gates()[2]
check(math.abs(before.hx) < 1e-6 and math.abs(before.hy - 1) < 1e-6,
  'the gate starts facing +Y, as it was placed')

mouse.wheel = 1
frame()
mouse.wheel = 0
local after = gates()[2]
check(math.abs(after.hy - 1) > 1e-6, 'one scroll notch turns the heading')
check(math.abs(math.sqrt(after.hx ^ 2 + after.hy ^ 2) - 1) < 1e-9,
  'and the heading stays a UNIT vector: a heading that has drifted off the unit '
    .. 'circle silently changes how wide the gate tests')

-- Turning is reversible, and 72 notches of 5 degrees is a full circle back to
-- where it started. Drift shows up here if the renormalise is ever dropped.
for _ = 1, 71 do mouse.wheel = 1; frame() end
mouse.wheel = 0
local round = gates()[2]
check(math.abs(round.hx) < 1e-6 and math.abs(round.hy - 1) < 1e-6,
  '72 notches of five degrees comes back to exactly where it started')

-- ===========================================================================
-- A UI panel under the cursor keeps its clicks
-- ===========================================================================
clickAt(0, 300)
local sel = routeState.nudgeSel
mouse.wantUi = true
clickAt(0, 100)
check(routeState.nudgeSel == sel,
  'a click the HUD app wants is not also a gate pick: the admin is pressing '
    .. 'buttons with this same cursor')
mouse.wantUi = false

-- ===========================================================================
-- Nudge mode never touches a live session
-- ===========================================================================
RM.setNudgeMode(true)
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  youAreAdmin = true })
frame()
check(cursorShown == false, 'a session starting ends the mode and returns the mouse')
local held = gates()[2] and gates()[2].y
clickAt(0, 100)
dragTo(500, 500)
check(gates()[2] and gates()[2].y == held,
  'and no gate moves while a race is running')

-- ===========================================================================
-- Drive and place still works, unchanged
-- ===========================================================================
serverState({ phase = 'waiting', totalLaps = 3, maxResets = -1, drivers = {},
  youAreAdmin = true })
local n = #gates()
veh.x, veh.y, veh.z = 12, 34, 0
RM.editorAdd()
check(#gates() == n + 1, 'driving to a spot and placing a gate is untouched')
local last = gates()[#gates()]
check(math.abs(last.x - 12) < 1e-6 and math.abs(last.y - 34) < 1e-6,
  'and it still lands exactly where the car is standing')

if fails == 0 then
  print('nudge_test: ' .. checks .. ' checks, 0 failures')
else
  print('nudge_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
