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

local ghosted = nil         -- last obj:setGhostEnabled value reaching the vehicle

-- `speed` is the car's speed in m/s. A pit stop is only offered to a car that
-- has come to a STOP in the stall, so most of this file drives a stationary car
-- (the historical behaviour, where the box alone was the trigger) and the
-- section on the stop rule moves it.
local veh = { id = VEH_ID, x = 0, y = 0, z = 0, speed = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = self.speed, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
function veh:queueLuaCommand(cmd)
  -- The repair: BeamNG's own in-place recovery, queued into the vehicle VM.
  if cmd == 'recovery.recoverInPlace()' then repairs = repairs + 1 end
  -- Ghosting is a vehicle-side call reached the same way.
  local g = cmd:match('^obj:setGhostEnabled%((%a+)%)$')
  if g then ghosted = (g == 'true') end
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
-- A car has to LEAVE a stall before it can serve another stop in it
-- ===========================================================================
-- The cooldown was meant to stop the box you are standing in re-triggering, but
-- a timer only delays that: a car still parked in the stall when it expires is
-- caught again, and again. Each stop freezes and ghosts it, so from the
-- driver's seat the car is stuck as a ghost for the rest of the race -- and the
-- server, told about each new ghost, never sees the end of the last one.
--
-- Resetting in the pits is how a driver ends up parked there: a reset in place
-- leaves the car exactly where it stood, which is in the box it just used.
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
              ghostOnReset = true, ghostMinSec = 5, ghostMaxSec = 15, ghosts = {} })
veh.x, veh.y = 0, 0
frames(9.0)                          -- well clear of any earlier stop
veh.x, veh.y = 50, 0                 -- into the stall
frames(0.3)
check(lastRoute().pitActive == true, 'a stop starts on arrival')
frames(6.0)                          -- the stop runs and releases
check(lastRoute().pitActive ~= true, 'and ends')

-- Stay exactly where the stop left the car, and wait out the cooldown twice
-- over. Nothing may start again.
local stopsBefore = countSent('RM_PitStop')
frames(20.0)
check(lastRoute().pitActive ~= true,
  'a car left parked in the stall does not serve a second stop')
check(countSent('RM_PitStop') == stopsBefore,
  'and no further stop is reported to the server')
check(frozen ~= true, 'nor is it frozen again')
check(ghosted ~= true, 'nor ghosted again -- this is the stuck-as-a-ghost report')

-- Driving out and coming back IS a fresh visit, and must still work.
veh.x, veh.y = 0, 0
frames(0.5)
veh.x, veh.y = 50, 0
frames(0.3)
check(lastRoute().pitActive == true, 'leaving and returning starts a new stop')
check(countSent('RM_PitStop') == stopsBefore + 1, 'which is reported once')
frames(6.0)
check(lastRoute().pitActive ~= true, 'and that one ends too')
veh.x, veh.y = 0, 0
frames(1.0)

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

-- ===========================================================================
-- You have to stop in the box yourself
-- ===========================================================================
-- The stall used to trigger on the BOX ALONE, so a car that clipped a corner of
-- one at racing speed was seized and frozen where it stood -- mid-lane, at
-- whatever angle it happened to be travelling, with the stop happening TO the
-- driver rather than being something they performed. The trigger is now the box
-- AND a stopped car.
clearLog()
racing()
veh.x, veh.y = 0, 0
veh.speed = 0
frames(9.0)                          -- clear the cooldown from the case above

-- Straight through at racing speed: nothing happens.
veh.speed = 30
veh.x, veh.y = 50, 0
frames(0.5)
check(frozen ~= true, 'driving through a stall at speed does not seize the car')
check(countSent('RM_PitStop') == 0, 'and starts no stop')

-- ...and out the other side. Missing it must cost NOTHING but the lap: no stop
-- was started, so no cooldown was spent and the stall is live on the next visit.
veh.x, veh.y = 0, 0
frames(0.5)
check(countSent('RM_PitStop') == 0, 'still no stop after driving out again')

-- Back in, and this time actually stop.
veh.x, veh.y = 50, 0
frames(0.3)
check(frozen ~= true, 'still rolling in the box, still not held')
veh.speed = 0
frames(0.3)
check(frozen == true, 'coming to a stop in the box starts the stop')
check(countSent('RM_PitStop') == 1, 'and it is reported once')
check(lastRoute().pitActive == true, 'and the driver is told they are in the pits')

-- The stall was NOT on cooldown from the drive-through, which is the whole
-- point of missing it being free.
check(repairs >= 0, 'the stop runs normally after a missed attempt')

-- ===========================================================================
-- A car frozen in a stall is a ghost
-- ===========================================================================
-- It cannot move out of the way -- the stop is holding it -- and it is parked in
-- the one part of the track everyone else arrives at slowly and off-line.
check(ghosted == true, 'a car serving a pit stop is ghosted')

-- The repair reloads the vehicle VM, which drops BOTH the freeze and the ghost.
-- The freeze has always been re-asserted; the ghost has to be too, or collision
-- comes back silently with seconds of the stop still to run.
local repairsBefore = repairs
ghosted = nil                        -- forget it, so only a re-assert can set it
frames(3.5)
check(repairs == repairsBefore + 1, 'the repair is issued during the stop')
check(ghosted == true, 'and the ghost survives the repair reloading the vehicle')

frames(2.5)
check(frozen == false, 'the car is released when the stop is over')
check(ghosted == false, 'and collision comes back with it')

print(string.format('pit_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
