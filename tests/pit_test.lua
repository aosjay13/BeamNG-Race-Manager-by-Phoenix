-- Headless test for pit stalls in lua/ge/extensions/raceManager.lua.
--
-- A pit stall is an AREA a driver may choose to drive into, not a checkpoint
-- they must pass in order. Driving into one holds the car, repairs it in place
-- and lets it go again.
--
-- Most of this file is about what a pit stop must NOT touch. Stalls are kept
-- out of the checkpoint list entirely, so laps and splits cannot see them; and
-- the repair is a vehicle reset as far as BeamNG is concerned, so it must be
-- recognised as the mod's own doing or a pit stop would silently spend a
-- driver's reset allowance and be reported to the server as a reset.
--
-- Run from the repo root: lua5.3 tests/pit_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local sent, hooks, handlers = {}, {}, {}
local frozen = nil          -- last setFreeze value that reached the vehicle
local repairs = 0           -- recovery.recoverInPlace() calls
local VEH_ID = 7

local veh = { id = VEH_ID, x = 0, y = 0, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
function veh:queueLuaCommand(cmd)
  -- The repair: BeamNG's own in-place recovery, queued into the vehicle VM.
  if cmd == 'recovery.recoverInPlace()' then repairs = repairs + 1 end
end
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
core_vehicleBridge = {
  executeAction = function (_, action, value)
    if action == 'setFreeze' then frozen = value end
  end,
}
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
-- The route push carries the pit state. Kept in its own variable rather than
-- searched out of the hook log, because the log is cleared between cases and
-- the mod only re-pushes when something changes -- so the last state has to
-- survive a clear.
local routeState = nil
guihooks = { trigger = function (e, p)
  hooks[#hooks + 1] = { event = e, payload = p }
  if e == 'RaceManagerRoute' then routeState = p end
end }
ColorF = function () return {} end
ColorI = function () return {} end
String = function (s) return s end
debugDrawer = {
  drawCylinder = function () end, drawTextAdvanced = function () end,
  drawSphere = function () end, drawLine = function () end,
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

local function frames(seconds, step)
  step = step or 0.1
  for _ = 1, math.floor(seconds / step + 0.5) do RM.onUpdate(step) end
end
local function serverState(t) t.rmProtocol = 2; t.raceTime = 0; handlers['RM_Update'](t) end
local function racing(extra)
  local t = { phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {} }
  for k, v in pairs(extra or {}) do t[k] = v end
  serverState(t)
end
local function countSent(e)
  local n = 0
  for _, x in ipairs(sent) do if x.event == e then n = n + 1 end end
  return n
end
local function lastRoute() return routeState end
local function clearLog() sent, hooks = {}, {} end

-- A two-gate circuit with one pit stall at (50, 0).
RM.setEditorTarget('main')
veh.x, veh.y = 0, 200; RM.editorAdd()
veh.x, veh.y = 0, 400; RM.editorAdd()
RM.setEditorTarget('pit')
veh.x, veh.y = 50, 0; RM.editorAdd()
RM.setEditorTarget('main')
veh.x, veh.y = 0, 0

check(#lastRoute().pitRoute == 1, 'a pit stall is placed on its own list')
check(#lastRoute().waypoints == 2, 'and is NOT added to the checkpoint route')

-- ===========================================================================
-- Driving into a stall holds the car and repairs it
-- ===========================================================================
racing()
clearLog()
frames(0.3)
check(frozen ~= true, 'a car out on track is not held')

veh.x, veh.y = 50, 0                 -- into the stall
frames(0.2)
check(frozen == true, 'driving into a stall holds the car')
check(lastRoute().pitActive == true, 'and the driver is told they are in the pits')
check(countSent('RM_PitStop') == 1, 'and the stop is reported to the server once')
check(repairs == 0, 'the repair has not happened yet -- the stop has to cost time')

-- The repair lands part-way through, so the car is whole before it is released.
frames(3.5)
check(repairs == 1, 'the car is repaired during the stop')
check(frozen == true, 'and is still held after the repair')

frames(2.0)
check(frozen == false, 'the car is released when the stop is over')
check(lastRoute().pitActive == false, 'and the readout clears')

-- ===========================================================================
-- A pit stop is not a driver reset
-- ===========================================================================
-- The repair IS a vehicle reset as far as BeamNG is concerned. Left
-- unrecognised it would spend a reset allowance, be reported to the server, and
-- on a spent allowance would have the car dragged back to its last good
-- position mid-stop.
clearLog()
serverState({ phase = 'racing', maxResets = 2, totalLaps = 3, drivers = {} })
veh.x, veh.y = 0, 0
frames(9.0)                          -- clear the stall cooldown
veh.x, veh.y = 50, 0
frames(3.2)                          -- into the stall, up to the repair
check(repairs > 0, 'the repair has been issued')
-- queueLuaCommand is asynchronous: the reset it provokes arrives a frame or
-- two later, which is well inside the echo window the mod arms for it.
RM.onVehicleResetted(VEH_ID)
check(countSent('RM_VehicleReset') == 0, 'a pit repair is not reported as a driver reset')
local st = lastRoute()
check(st and (st.resetsUsed or 0) == 0, 'and spends no reset allowance')
frames(3.0)

-- ===========================================================================
-- Stalls never touch the checkpoint sequence
-- ===========================================================================
-- The whole reason they are a separate list: lap and split validation must not
-- be able to see them.
clearLog()
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {} })
veh.x, veh.y = 0, 0
frames(9.0)
local armedBefore = lastRoute().nextWp
veh.x, veh.y = 50, 0
frames(6.0)
check(lastRoute().nextWp == armedBefore,
  'a pit stop does not advance the checkpoint sequence')
check(countSent('RM_Lap') == 0, 'and scores no lap')

-- ===========================================================================
-- The stop cannot outlive the session
-- ===========================================================================
-- A driver handed a frozen car in the lobby has no way to free it.
clearLog()
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {} })
veh.x, veh.y = 0, 0
frames(9.0)
veh.x, veh.y = 50, 0
frames(0.3)
check(frozen == true, 'held in the pits')
serverState({ phase = 'finished', maxResets = -1, totalLaps = 3, drivers = {} })
frames(0.3)
check(frozen == false, 'the session ending releases the car')

-- ===========================================================================
-- A stall does not re-trigger while you sit in it
-- ===========================================================================
clearLog()
racing()
veh.x, veh.y = 0, 0
frames(9.0)
veh.x, veh.y = 50, 0
frames(6.0)                          -- one full stop
local firstStops = countSent('RM_PitStop')
frames(3.0)                          -- still parked in the stall
check(countSent('RM_PitStop') == firstStops,
  'sitting in the stall afterwards does not start another stop')

print(string.format('pit_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
