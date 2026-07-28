-- Headless test for the client-side vehicle-reset rules in
-- lua/ge/extensions/raceManager.lua (Module 1).
--
-- Why this exists: BeamNG reports a teleport as a vehicle reset, and the mod
-- teleports the car itself — a blocked reset puts it back where it was, and a
-- grid assignment stands it on its slot. Those teleports come straight back
-- through onVehicleResetted. Treated as a driver pressing reset, the blocked
-- case looped forever (restore -> hook -> restore ...), which pinned the car in
-- place and flooded the UI with notices until the game locked up, and the grid
-- case silently spent an allowance nobody used.
--
-- The extension is a GE module, so the BeamNG/BeamMP globals it calls are
-- stubbed here and the file is dofile'd like any other Lua module.
-- Run from the repo root: lua5.3 tests/reset_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local sent      = {}   -- ordered { event, payload } sent to the server
local hooks     = {}   -- ordered { event, payload } pushed to the UI
local teleports = {}   -- every setPositionRotation the mod performed
local handlers  = {}   -- server -> client handlers the extension registered
local frozen    = nil  -- last controller.setFreeze the mod queued

local veh = {
  id = 7,
  x = 0, y = 0, z = 0,
  hx = 0, hy = 1,
}
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = self.hx, y = self.hy, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return nil end
function veh:setPositionRotation(x, y, z, qx, qy, qz, qw)
  self.x, self.y, self.z = x, y, z
  teleports[#teleports + 1] = { x = x, y = y, z = z, qx = qx, qy = qy, qz = qz, qw = qw }
end
function veh:queueLuaCommand(cmd) frozen = cmd end

-- Where BeamNG's own reset dropped the car before the mod hears about it.
local function driverPressedReset(x, y, z)
  veh.x, veh.y, veh.z = x, y, z
end

be     = { getPlayerVehicle = function () return veh end }
vec3   = function (x, y, z) return { x = x, y = y, z = z } end
quat   = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log    = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
-- LuaJIT (BeamNG) still has math.atan2; 5.3 folded it into math.atan.
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

-- ---------------------------------------------------------------------------
-- Harness helpers
-- ---------------------------------------------------------------------------
local function serverState(t) handlers['RM_Update'](t) end
local function gridAssign(slot) handlers['RM_GridAssign']({ slot = slot }) end
local function resetHook() RM.onVehicleResetted(veh.id) end
local function frames(seconds, step)
  step = step or 0.1
  for _ = 1, math.floor(seconds / step + 0.5) do RM.onUpdate(step) end
end
local function countSent(event)
  local n = 0
  for _, e in ipairs(sent) do if e.event == event then n = n + 1 end end
  return n
end
local function countNotices()
  local n = 0
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerNotice' and h.payload.kind == 'reset' then n = n + 1 end
  end
  return n
end
local function lastRouteState()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerRoute' then return hooks[i].payload end
  end
end
local function clearLog() sent, hooks, teleports = {}, {}, {} end

-- ===========================================================================
-- A reset inside the allowance is counted and left alone
-- ===========================================================================
serverState({ phase = 'waiting', maxResets = 1, totalLaps = 3, drivers = {} })
serverState({ phase = 'racing',  maxResets = 1, totalLaps = 3, drivers = {} })

veh.x, veh.y, veh.z = 100, 0, 0
frames(0.6)                                  -- rolling snapshot: (100, 0, 0)
clearLog()

driverPressedReset(5, 5, 0)
resetHook()
check(countSent('RM_VehicleReset') == 1, 'a reset inside the allowance is reported to the server')
check(#teleports == 0, 'a legal reset is not undone')
check(lastRouteState().resetsUsed == 1, 'the allowance is spent')

-- ===========================================================================
-- The blocked reset: applied once, and its own restore is not heard back as a
-- fresh reset (the loop that froze the game)
-- ===========================================================================
veh.x, veh.y, veh.z = 200, 0, 0
frames(0.6)                                  -- new snapshot: (200, 0, 0)
clearLog()

driverPressedReset(5, 5, 0)
resetHook()
check(#teleports == 1, 'an over-allowance reset puts the car back')
check(teleports[1].x == 200 and teleports[1].y == 0,
  'the car is put back on its last good position')
check(countSent('RM_ResetDenied') == 1, 'the blocked attempt is reported once')
check(countSent('RM_VehicleReset') == 0, 'a blocked reset spends no allowance')
check(countNotices() == 1, 'the driver is told once')
check(lastRouteState() == nil, 'a blocked reset pushes no route state: nothing in it changed')

-- BeamNG now reports the restore itself as a vehicle reset. Repeatedly, the
-- way it would arrive frame after frame.
for _ = 1, 5 do resetHook() end
check(#teleports == 1, 'the restore is not heard back as a reset (no teleport loop)')
check(countSent('RM_ResetDenied') == 1, 'the echo is not reported to the server')
check(countNotices() == 1, 'the echo raises no second notice')

-- A genuine second attempt still gets blocked: the car moved somewhere the mod
-- did not put it.
driverPressedReset(-40, 12, 0)
resetHook()
check(#teleports == 2, 'a real second attempt is blocked too')
check(teleports[2].x == 200, 'and lands back on the same good position')
check(countNotices() == 1, 'repeat attempts inside the throttle window stay quiet')
check(countSent('RM_ResetDenied') == 1, 'and are not re-reported to the server')

-- Once the throttle window passes, the driver is told again.
frames(1.2)
driverPressedReset(-60, 20, 0)
resetHook()
check(countNotices() == 2, 'a later attempt reports again')
check(countSent('RM_ResetDenied') == 2, 'and reaches the server again')

-- ===========================================================================
-- Being placed on the starting grid is not a reset
-- ===========================================================================
serverState({ phase = 'waiting', maxResets = 1, totalLaps = 3, drivers = {} })

-- Place one start position at (300, 10, 0) facing +X.
RM.setEditorTarget('start')
veh.x, veh.y, veh.z = 300, 10, 0
veh.hx, veh.hy = 1, 0
RM.editorAdd()

serverState({ phase = 'countdown', maxResets = 1, totalLaps = 3, drivers = {} })
clearLog()
veh.x, veh.y, veh.z = 0, 0, 0               -- somewhere else when the grid forms
gridAssign(1)
check(#teleports == 1 and teleports[1].x == 300, 'the car is stood on its grid slot')
check(math.abs(teleports[1].qz - math.sin(math.pi / 4)) < 1e-6
  and math.abs(teleports[1].qw - math.cos(math.pi / 4)) < 1e-6,
  'facing down the track (a quarter turn from +Y)')
check(frozen == 'controller.setFreeze(1)', 'and held for the countdown')

-- The placement comes back through the same hook.
resetHook(); resetHook()
check(countSent('RM_VehicleReset') == 0, 'a grid placement never spends an allowance')
check(countSent('RM_ResetDenied') == 0, 'and is never reported as a blocked attempt')
check(#teleports == 1, 'and is not answered with another teleport')

-- A driver who resets off the grid is put back on their slot, facing the right
-- way: the slot is the good position, heading included.
frames(1.2)
serverState({ phase = 'countdown', maxResets = 0, totalLaps = 3, drivers = {} })
clearLog()
driverPressedReset(0, 0, 0)
resetHook()
check(#teleports == 1 and teleports[1].x == 300 and teleports[1].y == 10,
  'a reset on the grid is undone back to the slot')
check(math.abs(teleports[1].qz - math.sin(math.pi / 4)) < 1e-6,
  'the restored car keeps the slot heading instead of snapping to +Y')

if fails == 0 then
  print('reset_test: ' .. checks .. ' checks, 0 failures')
else
  print('reset_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
