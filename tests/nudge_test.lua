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
local mouse = { clicked = false, down = false, released = false, wheel = 0,
                wantUi = false, ctrl = false, shift = false }
ui_imgui = {
  IsMouseClicked  = function () return mouse.clicked end,
  IsMouseDown     = function () return mouse.down end,
  IsMouseReleased = function () return mouse.released end,
  GetIO = function ()
    return { WantCaptureMouse = mouse.wantUi, MouseWheel = mouse.wheel,
             KeyCtrl = mouse.ctrl, KeyShift = mouse.shift }
  end,
}

-- Where the cursor ray starts, where it points, and what it lands on. The
-- engine gives these as two separate calls and the mod uses both: the ray to
-- pick a gate out of the air, the raycast to find the ground under the cursor.
local ray = { pos = { x = 0, y = 0, z = 50 }, dir = { x = 0, y = 1, z = 0 } }
local rayHit = { pos = { x = 0, y = 0, z = 0 }, normal = { x = 0, y = 0, z = 1 } }
getCameraMouseRay = function () return ray end
cameraMouseRayCast = function () return rayHit end
-- REAL TERRAIN, not a constant. The old stub returned 50 whatever it was asked,
-- which with a probe that starts above the query point reports the ground as
-- being exactly where you asked about -- so every height test would pass against
-- a world with no shape at all.
--
-- `terrainAt` is the map: flat at z = 0 by default, and tests set it to a
-- function to build a slope or a ledge.
local terrainAt = function (x, y) return 0 end
castRayStatic = function (origin, dir, maxDist)
  local g = terrainAt(origin.x, origin.y)
  local dist = origin.z - g
  if dist < 0 or dist > (maxDist or math.huge) then return maxDist or 1e9 end
  return dist
end

-- THE CURSOR, REACHED THE WAY THE GAME REACHES IT.
--
-- There is no `core_canvas` global in BeamNG. The helpers live in
-- lua/ge/client/canvas.lua, which is not an extension: the game does
-- require('client/canvas') and so must the mod. The first build of nudge mode
-- checked for a core_canvas that has never existed, so the mode refused to start
-- with "needs a newer BeamNG build" on a build that had everything it needed.
--
-- The stub is a require() hook rather than a global for exactly that reason: a
-- test that invents the API it is testing against proves nothing about the game.
local cursorShown = nil
local canvasModule = {
  showCursor = function () cursorShown = true end,
  hideCursor = function () cursorShown = false end,
}
local requiredCanvas = 0
local realRequire = require
require = function (name)
  if name == 'client/canvas' then
    requiredCanvas = requiredCanvas + 1
    return canvasModule
  end
  return realRequire(name)
end
-- The raw engine call canvas.lua wraps, and the fallback when the module is not
-- reachable. Recorded so the fallback can be tested on its own.
local locked = nil
lockMouse = function (v) locked = v end

-- The Canvas, for the "was the cursor already free" probe. BeamNG has no
-- Lua-side getter for this, so the mod asks the Torque object and copes with
-- not being answered. cursorOn = nil makes the probe fail, which is the real
-- world on a build without isCursorOn and the case that matters most.
local cursorOn = nil
scenetree = {
  findObject = function (name)
    if name ~= 'Canvas' then return nil end
    if cursorOn == nil then return nil end
    return { isCursorOn = function () return cursorOn end }
  end,
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

-- The extension `require`s its modules (raceManager/derby, and more to come),
-- so the headless harness has to be able to find them the way the game can.
-- One line, and it is what makes a split file testable at all.
package.path = 'lua/ge/extensions/?.lua;' .. package.path
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
local function ctrlClickAt(x, y)
  aimAt(x, y)
  mouse.ctrl = true
  mouse.clicked, mouse.down, mouse.released = true, true, false
  frame()
  mouse.clicked, mouse.down, mouse.ctrl = false, false, false
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

check(requiredCanvas > 0,
  "the cursor comes from require('client/canvas'), the path the game itself "
    .. 'uses: there is no core_canvas global and never has been')

-- TAKING THE CURSOR BACK IS THE DANGEROUS DIRECTION.
--
-- The first build locked the mouse to the camera on every exit. An admin who
-- already had a free cursor -- which they must have had, because clicking the
-- Nudge button needs one -- turned the mode off and could no longer click
-- anything at all, including the button to turn it back on. Reported live.
--
-- Three cases, and only one of them re-locks.

-- 1. The probe cannot answer (no isCursorOn on this build). Not knowing means
--    leaving the cursor alone: a free cursor costs a keypress on the player's
--    own camera toggle, a captured one costs them the whole UI.
cursorShown = nil
RM.setNudgeMode(false)
check(cursorShown ~= false,
  'with no way to tell what the cursor was, turning the mode off LEAVES IT '
    .. 'FREE rather than guessing and stranding the admin')

-- 2. The probe says the cursor was already free. It was not ours, so it stays.
cursorOn = true
RM.setNudgeMode(true)
check(cursorShown == true, 'the mode still releases the cursor on the way in')
cursorShown = nil
RM.setNudgeMode(false)
check(cursorShown ~= false,
  'a cursor that was already free before the mode is left free after it')

-- 3. The probe says the cursor was locked to the camera. That one we took, so
--    that one we give back.
cursorOn = false
RM.setNudgeMode(true)
cursorShown = nil
RM.setNudgeMode(false)
check(cursorShown == false,
  'a cursor taken FROM the camera is handed back to it')
cursorOn = nil

-- The refusal has to name what is actually missing. "Needs a newer build" sent
-- somebody looking for a game update to fix a typo in this file.
local status = RM.nudgeStatus()
check(status.usable == true, 'the mode reports itself usable with the real API present')
check(status.imgui and status.rayCast and status.canvas,
  'and names each piece it resolved, so a refusal can be diagnosed from the console')

-- Closing the editor has to hand it back too, or the camera stops answering
-- with nothing on screen to explain why.
cursorOn = false
RM.setNudgeMode(true)
cursorShown = nil
RM.setEditorOpen(false)
check(cursorShown == false,
  'closing the editor ends the mode and returns the mouse it borrowed')
RM.setEditorOpen(true)
cursorOn = nil

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
-- Ctrl+click places a gate, which is what makes a long track fast
-- ===========================================================================
RM.setNudgeMode(false)
RM.setNudgeMode(true)
clickAt(900, 900)                       -- drop any selection first
local before = #gates()
ctrlClickAt(0, 500)
check(#gates() == before + 1, 'ctrl+click on open ground places a gate')
local placed = gates()[#gates()]
check(placed and math.abs(placed.x - 0) < 0.01 and math.abs(placed.y - 500) < 0.01,
  'exactly where the cursor hit the ground')

-- A click has no direction of its own, so the gate takes the one the route is
-- already travelling. Clicking along a road in order is then a route that faces
-- the way the road goes, which is the entire reason this beats driving.
check(placed and math.abs(placed.hy - 1) < 1e-6 and math.abs(placed.hx) < 1e-6,
  'facing the way the route travels: from the previous gate toward this point')

local sideways = #gates()
ctrlClickAt(200, 500)                   -- due east of the last one
local east = gates()[#gates()]
check(#gates() == sideways + 1, 'and again')
check(east and math.abs(east.hx - 1) < 1e-6 and math.abs(east.hy) < 1e-6,
  'a gate placed east of the last one faces east, not north')

-- Placing must not also pick and drag. Placing a gate and then instantly
-- dragging it off the point it was placed at is not what anybody meant.
local wherePlaced = { x = east.x, y = east.y }
dragTo(700, 700)
local still = gates()[#gates()]
check(math.abs(still.x - wherePlaced.x) < 0.01 and math.abs(still.y - wherePlaced.y) < 0.01,
  'the click that placed it did not also start a drag')
letGo()

-- ===========================================================================
-- With a gate picked, a placement goes in AFTER it
-- ===========================================================================
-- A gap noticed halfway round used to cost every gate placed since. It goes
-- through the ordinary insert path, so the branch slot shifting that comes with
-- it happens exactly once, in the code that already knew how.
clickAt(0, 100)                         -- pick gate 1
check(routeState.nudgeSel == 1, 'gate 1 picked')
local total = #gates()
ctrlClickAt(0, 150)
check(#gates() == total + 1, 'the gate is placed')
check(math.abs(gates()[2].y - 150) < 0.01,
  'INSERTED after the picked gate, not appended to the end')
-- Gate 2 was dragged to (40, 240) earlier in this file, so that is what the new
-- gate lands in front of.
check(math.abs(gates()[1].y - 100) < 0.01 and math.abs(gates()[3].y - 240) < 0.01,
  'and the gates either side keep their order')
check(routeState.nudgeSel == 2, 'the new gate is the picked one, ready to turn')

-- ===========================================================================
-- Delete removes the picked gate and picks nothing
-- ===========================================================================
local n = #gates()
RM.nudgeDelete()
check(#gates() == n - 1, 'delete removes the picked gate')
check(math.abs(gates()[2].y - 240) < 0.01, 'and the one after it closes up')
check(routeState.nudgeSel == nil, 'nothing is picked afterwards')
RM.nudgeDelete()
check(#gates() == n - 1, 'delete with nothing picked does nothing')

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
-- Off first: setNudgeMode is a no-op when the state already matches, so the
-- probe would not be re-read and this would be testing the previous entry.
RM.setNudgeMode(false)
cursorOn = false
RM.setNudgeMode(true)
cursorShown = nil
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  youAreAdmin = true })
frame()
check(cursorShown == false, 'a session starting ends the mode and returns the mouse')
cursorOn = nil
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

-- ===========================================================================
-- GATES MUST CLEAR THE GROUND, AND MUST BE RECOVERABLE WHEN THEY DO NOT
-- ===========================================================================
-- Reported from a live night on uneven terrain: ctrl+clicked checkpoints ended
-- up under the map, no control in the editor could raise them, and a Last
-- Checkpoint reset onto one spawned the car half buried and sometimes sideways.
-- Three separate faults, one symptom.

-- --- 1. A CLICKED GATE SITS AT DRIVING HEIGHT, NOT ON THE DIRT ---------------
-- The raycast lands ON the terrain. A gate placed by DRIVING takes the car's
-- origin, which is about half a metre up, so a clicked gate used to sit lower
-- than a driven one on the same piece of road.
RM.setEditorTarget('main')
RM.editorClear()
RM.setNudgeMode(true)
frame()
check(routeState and routeState.nudgeOn == true, 'nudge mode is on for these cases')
terrainAt = function (x, y) return 0 end
veh.x, veh.y, veh.z = 0, 0, 0
RM.editorAdd()                       -- a driven gate, to anchor the route
ctrlClickAt(0, 100)
local g = gates()
check(#g == 2, 'the clicked gate is placed')
check(g[2] and g[2].z >= 0.49,
  'a clicked gate clears the ground rather than sitting on it (z='
    .. tostring(g[2] and g[2].z) .. ')')

-- On a SLOPE, where the bug actually bit: the ground under the click is not the
-- ground the ray started from.
terrainAt = function (x, y) return y * 0.1 end     -- rises 1 in 10 along +Y
rayHit.pos = { x = 0, y = 200, z = 20 }
ctrlClickAt(0, 200)
g = gates()
check(#g == 3, 'a gate is placed on the slope')
check(g[3] and g[3].z >= 20.49,
  'and it clears the sloping ground under it, not the flat it was aimed from (z='
    .. tostring(g[3] and g[3].z) .. ')')

-- --- 2. SHIFT+SCROLL RAISES AND LOWERS A SELECTED GATE ----------------------
-- The Gate size sliders set HEIGHT and DEPTH, which is how far a gate extends up
-- and down from where it sits. Neither moves it. Before this there was no
-- control at all that changed a gate's z, so a buried gate was permanent.
terrainAt = function (x, y) return 0 end
RM.editorClear()
veh.x, veh.y, veh.z = 0, 0, 0
RM.editorAdd()
clickAt(0, 0)                         -- select it
local before = gates()[1] and gates()[1].z
mouse.shift, mouse.wheel = true, 4
frame()
mouse.wheel = 0
local after = gates()[1] and gates()[1].z
check(before ~= nil and after ~= nil and after > before,
  'shift+scroll up raises the selected gate (' .. tostring(before)
    .. ' -> ' .. tostring(after) .. ')')

mouse.wheel = -2
frame()
mouse.wheel = 0
local lowered = gates()[1] and gates()[1].z
check(lowered ~= nil and lowered < after, 'and shift+scroll down lowers it again')

-- It cannot be used to bury one: the floor is the same ground clearance every
-- placement path uses.
mouse.wheel = -100
frame()
mouse.wheel = 0
mouse.shift = false
local floored = gates()[1] and gates()[1].z
check(floored ~= nil and floored >= 0.49,
  'and it stops at ground clearance rather than digging the gate in (z='
    .. tostring(floored) .. ')')

-- Plain scroll still turns rather than lifts, which is the control it shares.
local turnedFrom = gates()[1] and gates()[1].hy
mouse.wheel = 3
frame()
mouse.wheel = 0
check(gates()[1] and gates()[1].z == floored,
  'plain scroll does NOT move the gate vertically')
check(gates()[1] and gates()[1].hy ~= turnedFrom, 'it still turns it')

-- --- 3. AN INSERTED GATE FACES THE WAY THE ROUTE GOES THERE ------------------
-- A clicked gate takes its heading from the gate BEFORE it. With a gate selected
-- the click is an INSERT, and the heading used to be read off the last gate on
-- the route instead -- so a gate inserted into the middle of a lap was aimed at
-- wherever the lap happened to finish. That is the car standing sideways across
-- the track on a reset.
RM.editorClear()
for i = 1, 3 do
  veh.x, veh.y, veh.z = 0, i * 100, 0
  veh.hx, veh.hy = 0, 1
  RM.editorAdd()
end
-- Gate 3 is the last one. Select gate 1 and insert after it, far off to the
-- side: reading gate 3 would aim the new gate back down the route.
clickAt(0, 100)
ctrlClickAt(0, 150)
g = gates()
check(#g == 4, 'the gate is inserted rather than appended')
check(g[2] ~= nil and g[2].hy > 0.9,
  'and faces the way the route travels THERE (+Y), not back toward the end of '
    .. 'the lap (hy=' .. tostring(g[2] and g[2].hy) .. ')')

-- ===========================================================================
-- A GENERATED GRID FOLLOWS THE TERRAIN
-- ===========================================================================
-- Reported alongside the checkpoint case: slots generated on uneven ground ended
-- up under the map. Every slot used to be handed the ANCHOR's z -- the height of
-- wherever the car generating the grid was standing -- which is a horizontal
-- plane laid through the hill. On a crest the rows behind the anchor are inside
-- the slope; in a dip they float above it.
RM.setNudgeMode(false)
RM.setEditorTarget('start')
RM.editorClear()

-- Ground that falls away behind the anchor: 1 in 10 down the -Y axis, which is
-- the direction a grid is laid back along.
terrainAt = function (x, y) return y * 0.1 end
veh.x, veh.y, veh.z = 0, 0, 0.5     -- anchor half a metre up, as a car sits
veh.hx, veh.hy = 0, 1               -- facing +Y, so the grid runs back down -Y
RM.generateStartPositions(6, 10, 4, 0, 2)
frame()

local slots = (routeState or {}).startPositions or {}
check(#slots == 6, 'six slots are generated (got ' .. #slots .. ')')

-- Row 0 is at the anchor, row 1 ten metres back, row 2 twenty. The ground there
-- is -1 and -2 metres, so a grid that ignored terrain would leave those rows one
-- and two metres in the air -- or buried, on ground that rises.
local ok = true
for i, sp in ipairs(slots) do
  local g = terrainAt(sp.x, sp.y)
  local clear = sp.z - g
  if clear < 0.4 or clear > 0.7 then
    ok = false
    print(string.format('    slot %d: z=%.2f ground=%.2f clearance=%.2f',
      i, sp.z, g, clear))
  end
end
check(ok, 'every slot sits the same half metre above the ground UNDER IT, '
  .. 'rather than all sharing the anchor height')

-- The anchor's height above ground is what is preserved, not its absolute z. A
-- grid generated from a car up on a bridge stays on the bridge.
RM.editorClear()
terrainAt = function (x, y) return 0 end
veh.x, veh.y, veh.z = 0, 0, 20      -- twenty metres up, on a flyover
RM.generateStartPositions(3, 10, 4, 0, 1)
frame()
slots = (routeState or {}).startPositions or {}
check(#slots == 3, 'three slots on the flyover')
check(slots[3] ~= nil and slots[3].z > 15,
  'a grid generated up on a bridge is not dropped to the ground below it (z='
    .. tostring(slots[3] and slots[3].z) .. ')')

if fails == 0 then
  print('nudge_test: ' .. checks .. ' checks, 0 failures')
else
  print('nudge_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
