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

-- The real sideColumnMarker builds this in its init with
-- `self.modeInfos = deepcopy(modeInfos)` -- a PER-INSTANCE copy of the eight
-- stock mode colours. That copy is what makes recolouring one marker safe, so
-- the stub reproduces it (a fresh table per marker, never a shared one) and the
-- joker case below checks the recolour lands on it.
local function stockModeInfos()
  return {
    default  = { color = { 1, 0.07, 0 },  baseColor = { 1, 1, 1 } },
    next     = { color = { 0, 0, 0 },     baseColor = { 0, 0, 0 } },
    lap      = { color = { 0.4, 1, 0.2 }, baseColor = { 1, 1, 1 } },
    recovery = { color = { 1, 0.85, 0 },  baseColor = { 1, 1, 1 } },
    branch   = { color = { 1, 0.6, 0 },   baseColor = { 1, 1, 1 } },
    hidden   = { color = { 0, 0, 0 },     baseColor = { 0, 0, 0 } },
  }
end

local function makeMarker(id)
  local m = { id = id, alive = false, checkpoint = nil, mode = nil, updates = 0,
              modeInfos = stockModeInfos() }
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
-- ===========================================================================
-- THE STOCK MARKERS ARE RETIRED, AND THE SHARED SINGLETON IS LEFT ALONE
-- ===========================================================================
-- race_marker was the right SHAPE -- a column either side of the racing line is
-- what a driver already reads without being taught -- but the markers could not
-- be made bright or solid enough to see on track, and they could not be widened
-- either: their spacing IS the gate width, so poles further apart than the
-- trigger would mark a target that does not score.
--
-- So the mod draws its own two poles now, out of the same cylinders the editor
-- rectangle is built from (drawPoleGate, covered by tests/draw_test.lua).
--
-- What this file protects is what it always protected, and it matters MORE now
-- that nothing here is used: race_marker is a singleton shared with BeamNG's own
-- hotlapping and flowgraph races, drag, drift, and BeamJoy if it is installed.
-- Its setupMarkers() rebuilds one global marker list, so calling it would delete
-- every marker any of them had placed. The mod must touch none of it.

serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
frames(5)
check(aliveMarkers() == 0, 'no stock marker is created before a session')

racing()
frames(5)
check(aliveMarkers() == 0, 'none during a race either')

serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
  jokerEnabled = true })
frames(5)
check(aliveMarkers() == 0, 'and none for the joker route -- it is drawn as poles too')

-- The shared list is never rebuilt. This is the one that would break other mods.
local touchedShared = false
for _, call in ipairs(sharedApiCalls) do
  if call == 'setupMarkers' then touchedShared = true end
end
check(touchedShared == false,
  'setupMarkers is NEVER called: it rebuilds the list BeamNG, drag, drift and '
    .. 'BeamJoy all share, and calling it would delete their markers')

-- Teardown still tears down. If an older build left markers standing, unloading
-- has to take them with it -- they are real scene objects and nothing else can.
RM.onExtensionUnloaded()
check(aliveMarkers() == 0, 'unloading leaves no marker standing')

if fails == 0 then
  print('poles_test: ' .. checks .. ' checks, 0 failures')
else
  print('poles_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
