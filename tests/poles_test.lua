-- Headless test for the race-mode checkpoint markers (BeamNG's gate poles) in
-- lua/ge/extensions/raceManager.lua.
--
-- Why this exists, and why most of it is about what the mod must NOT do:
--
-- `scenario/race_marker` is a SINGLETON shared by everything in the game that
-- races -- BeamNG's own hotlapping and flowgraph races, drag, drift, and
-- BeamJoy if it is installed. Its setupMarkers() rebuilds ONE global marker
-- list, so calling it deletes every marker all of them had placed, and the next
-- one to call it deletes ours. BeamJoy uses that shared path and documents
-- crashes on disconnect for every marker type but one.
--
-- So the markers are taken in their DETACHED form: createRaceMarker(true, ...)
-- hands back a marker that is never entered into the shared list. We own it, we
-- drive it, and nothing we do can disturb another mod's race. The engine stubs
-- below fail the test if the shared API is called at all.
--
-- The other half is teardown. These are real scene objects (TSStatic), not
-- immediate-mode drawing: one left behind is a pair of poles standing on an
-- empty map with nothing left able to delete them.
--
-- Run from the repo root: lua5.3 tests/poles_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- Engine stubs
-- ---------------------------------------------------------------------------
local sent, hooks, handlers = {}, {}, {}
local VEH_ID = 7

-- Every marker the engine has handed out, alive or dead, in order.
local madeMarkers = {}
local sharedApiCalls = {}   -- any use of the SHARED (non-detached) API

local function makeMarker(id)
  local m = { id = id, alive = false, checkpoint = nil, mode = nil, updates = 0 }
  function m:createMarkers() self.alive = true end
  function m:clearMarkers() self.alive = false end
  function m:setToCheckpoint(wp) self.checkpoint = wp end
  function m:setMode(mode) self.mode = mode end
  function m:update(dt) self.updates = self.updates + 1 end
  return m
end

-- The real module, as far as its shape matters here.
local raceMarkerModule = {
  createRaceMarker = function (detached, markerType)
    -- Detached is not optional. A non-detached marker goes into the shared list
    -- and becomes everyone else's problem.
    if detached ~= true then
      sharedApiCalls[#sharedApiCalls + 1] = 'createRaceMarker(non-detached)'
    end
    local m = makeMarker(#madeMarkers + 1)
    m.markerType = markerType
    m:createMarkers()
    madeMarkers[#madeMarkers + 1] = m
    return m
  end,
  -- Everything below rebuilds or walks the SHARED list. Touching any of it is
  -- the bug this file exists to prevent.
  setupMarkers = function () sharedApiCalls[#sharedApiCalls + 1] = 'setupMarkers' end,
  setModes     = function () sharedApiCalls[#sharedApiCalls + 1] = 'setModes' end,
  init         = function () sharedApiCalls[#sharedApiCalls + 1] = 'init' end,
  render       = function () sharedApiCalls[#sharedApiCalls + 1] = 'render' end,
  hide         = function () sharedApiCalls[#sharedApiCalls + 1] = 'hide' end,
  show         = function () sharedApiCalls[#sharedApiCalls + 1] = 'show' end,
}

-- The extension reaches the module through require(). Counted, because
-- require() on a name that does not resolve walks the whole package path, and
-- this is reached from the frame loop: an uncached lookup cost seventy times
-- everything else the mod does per frame put together.
local requireCalls = 0
local realRequire = require
require = function (name)
  if name == 'scenario/race_marker' then
    requireCalls = requireCalls + 1
    return raceMarkerModule
  end
  return realRequire(name)
end

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
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
ColorF = function () return {} end
ColorI = function () return {} end
String = function (s) return s end
debugDrawer = {
  drawCylinder = function () end,
  drawTextAdvanced = function () end,
  drawSphere = function () end,
  drawLine = function () end,
  drawQuadSolid = function () end,   -- the editor gate's filled surface
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

local function frames(n) for _ = 1, (n or 1) do RM.onUpdate(1 / 60) end end
local function serverState(t) t.rmProtocol = 2; t.raceTime = 0; handlers['RM_Update'](t) end
local function racing() serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {} }) end
local function aliveMarkers()
  local n = 0
  for _, m in ipairs(madeMarkers) do if m.alive then n = n + 1 end end
  return n
end

-- A four-gate circuit.
RM.setEditorTarget('main')
for i = 1, 4 do
  veh.x, veh.y = i * 100, 0
  RM.editorAdd()
end

-- ===========================================================================
-- Nothing before the lights
-- ===========================================================================
serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
frames(3)
check(aliveMarkers() == 0, 'no poles outside a running session')

-- ===========================================================================
-- Racing: poles on the next two gates, and only those
-- ===========================================================================
racing()
frames(3)
check(aliveMarkers() == 2,
  'a running session puts poles on the next two gates, whatever the circuit length')
check(madeMarkers[1].markerType == 'sideColumnMarker',
  'using the one marker type that is safe to tear down')
check(madeMarkers[1].checkpoint ~= nil, 'the marker is pointed at a gate')
check(madeMarkers[1].checkpoint.radius == 10,
  'radius is the HALF width, so poles stand at the rectangle edges')
check(madeMarkers[1].checkpoint.normal.y == 1,
  'and the gate heading is passed through as the marker normal')

-- They animate, so they have to be ticked -- detached markers are not in the
-- engine's own render list, which is exactly what makes them safe.
local before = madeMarkers[1].updates
frames(5)
check(madeMarkers[1].updates > before, 'markers are ticked every frame')

-- Re-pointed only when the gate under them changes, not once a frame.
local pointedAt = madeMarkers[1].checkpoint
frames(10)
check(madeMarkers[1].checkpoint == pointedAt,
  'a marker sitting on the same gate is not re-pointed every frame')

-- ===========================================================================
-- The shared singleton is never touched
-- ===========================================================================
-- This is the whole reason for the detached form. Any of these calls would
-- delete the markers of every other racing mod in the game, and let theirs
-- delete ours.
check(#sharedApiCalls == 0,
  'the shared race_marker API is never called: ' .. table.concat(sharedApiCalls, ', '))

-- ===========================================================================
-- The editor owns the view when an admin is in it
-- ===========================================================================
-- Poles cannot carry a number or show a gate's dimensions, so an admin laying
-- out a circuit gets the editor view instead -- and only an admin does.
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
  youAreAdmin = true })
RM.setEditorOpen(true)
frames(3)
check(aliveMarkers() == 0, 'an admin with the editor open sees the editor, not poles')

RM.setEditorOpen(false)
frames(3)
check(aliveMarkers() == 2, 'closing the editor hands the view back to the poles')

-- A non-admin can never get the editor view, whatever the editor flag says.
-- Admin status only changes when the payload carries it -- ordinary broadcasts
-- leave it alone -- so demoting takes an explicit youAreAdmin = false.
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
  youAreAdmin = false })
RM.setEditorOpen(true)
frames(3)
check(aliveMarkers() == 2, 'a non-admin keeps the race view even with the editor flagged open')
RM.setEditorOpen(false)

-- ===========================================================================
-- Teardown: these are scene objects, so nothing may be left standing
-- ===========================================================================
racing()
frames(3)
check(aliveMarkers() == 2, 'poles up')
serverState({ phase = 'finished', maxResets = -1, totalLaps = 3, drivers = {} })
frames(3)
check(aliveMarkers() == 0, 'the race ending takes the poles down')

racing()
frames(3)
check(aliveMarkers() == 2, 'poles up again')
RM.onBeamMPServerLeave()
check(aliveMarkers() == 0, 'leaving the session takes them down')

racing()
frames(3)
RM.onExtensionUnloaded()
check(aliveMarkers() == 0, 'unloading the extension takes them down')

-- Markers are reused rather than re-created every time the view returns: a
-- marker is three scene objects, and churning them per frame would be worse
-- than the drawing it replaces.
local madeSoFar = #madeMarkers
racing()
frames(10)
check(#madeMarkers - madeSoFar <= 2,
  'returning to the race view creates at most the two markers it needs')

-- The engine module is resolved once for the life of the extension, however
-- many times the markers come and go.
check(requireCalls == 1,
  'the marker module is looked up once, not per frame (was ' .. requireCalls .. ')')

print(string.format('poles_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
