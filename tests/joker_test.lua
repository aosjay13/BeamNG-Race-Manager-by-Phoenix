-- Headless test for THE JOKER LAP and its collision with the pace lap, in
-- lua/ge/extensions/raceManager.lua.
--
-- The joker route must be driven exactly once per race and NEVER ON LAP 1. That
-- rule is enforced client-side, because only this side can see the car move.
--
-- LAP 1 IS A RACING LAP, NOT A CROSSING, and that is the whole of what this file
-- guards. Behind the pace car the first crossing ends the FORMATION lap, so the
-- driver's raw counter reads 1 on a lap nobody is scored for and 2 on the lap
-- the race actually starts on. Tested against the raw counter the rule closed
-- the joker on the formation lap -- where nobody was going to take it anyway --
-- and left it wide open on the first racing lap, which is the one lap it exists
-- to close. A test that only ran without a pace lap passes against that bug.
--
-- The reported lap number matters for the same reason: the results file prints
-- "joker: lap 4", and a driver whose own board said lap 3 at that moment has no
-- way to reconcile the two.
--
-- Run from the repo root: lua5.3 tests/joker_test.lua

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
-- (the historical behavior, where the box alone was the trigger) and the
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

-- The extension `require`s its modules (raceManager/derby, and more to come),
-- so the headless harness has to be able to find them the way the game can.
-- One line, and it is what makes a split file testable at all.
package.path = 'lua/ge/extensions/?.lua;' .. package.path
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


-- ---------------------------------------------------------------------------
-- A two-gate circuit with a two-gate joker loop beside it
-- ---------------------------------------------------------------------------
RM.setEditorTarget('main')
veh.x, veh.y = 0, 200; RM.editorAdd()
veh.x, veh.y = 0, 400; RM.editorAdd()
RM.setEditorTarget('joker')
veh.x, veh.y = 80, 200; RM.editorAdd()
veh.x, veh.y = 80, 400; RM.editorAdd()
RM.setEditorTarget('main')
veh.x, veh.y = 0, 0
check(#lastRoute().jokerRoute == 2, 'the joker loop is its own two-gate route')
check(#lastRoute().waypoints == 2, 'and is not part of the checkpoint route')

-- BACK TO THE START THE LONG WAY ROUND, and it has to be the long way. A gate
-- scores in EITHER direction unless it is marked one-way, so teleporting from
-- past the line straight back to the grid drives back through every gate on the
-- circuit and undoes the lap that was just driven. Out to x=-200 misses them all.
local function toStart()
  veh.x, veh.y = -200, 500; frames(0.2)
  veh.x, veh.y = -200, -50; frames(0.2)
  veh.x, veh.y = 0, -50;    frames(0.2)
end
-- Drive a lap: through both main gates in order. The line is the last gate of
-- the route, so a lap is "cross them in order".
local function driveLap()
  veh.x, veh.y = 0, 100;  frames(0.2)
  veh.x, veh.y = 0, 300;  frames(0.2)   -- gate 1
  veh.x, veh.y = 0, 500;  frames(0.2)   -- gate 2 (the line)
  toStart()
end
-- ...and the joker loop, which runs alongside at x=80 and so crosses none of the
-- main gates: they are 20 wide and centered on x=0.
local function driveJoker()
  veh.x, veh.y = 80, 100; frames(0.2)
  veh.x, veh.y = 80, 300; frames(0.2)   -- joker gate 1
  veh.x, veh.y = 80, 500; frames(0.2)   -- joker gate 2
  toStart()
end
local function jokerSent()
  for _, x in ipairs(sent) do if x.event == 'RM_JokerLap' then return x.payload end end
  return nil
end

-- ---------------------------------------------------------------------------
-- NO PACE LAP: the joker is closed on the first lap, open on the second
-- ---------------------------------------------------------------------------
-- The behaviour that already worked, kept because it is the half a pace-lap fix
-- is most likely to break.
serverState({ phase = 'racing', maxResets = -1, totalLaps = 5,
  jokerEnabled = true, paceLap = false, drivers = {} })
frames(0.5)
clearLog()
driveJoker()
check(jokerSent() == nil, 'lap 1: the joker is refused and nothing is reported')

clearLog(); driveLap()                            -- now on lap 2
do for _,h in ipairs(hooks) do print('DEBUG hook: '..tostring(h.event)) end end
do local r = lastRoute() or {}
   local ks = {}
   for k,v in pairs(r) do ks[#ks+1]=k..'='..tostring(v) end
   table.sort(ks); print('DEBUG route: '..table.concat(ks,' '))
end
clearLog()
driveJoker()
for _,h in ipairs(hooks) do
  if type(h.payload)=='table' and h.payload.msg then print('DEBUG notice: '..tostring(h.payload.msg)) end
end
local p = jokerSent()
check(p ~= nil, 'lap 2: the joker counts')
check(p and p.lap == 2, 'and is reported as lap 2 (got ' .. tostring(p and p.lap) .. ')')

-- ---------------------------------------------------------------------------
-- BEHIND THE PACE CAR: lap 1 is the SECOND crossing
-- ---------------------------------------------------------------------------
-- This is the case the raw counter got wrong in both directions at once.
--
-- THE SESSION IS ENDED AND RESTARTED, not the extension reloaded.
-- RM.onExtensionLoaded() rebuilds the module but leaves the SESSION alone -- the
-- lap counter and `jokerTaken` both survive it -- so a second scenario started
-- that way inherits the first one's race and every lap number in it is off by
-- one. Dropping out of 'racing' and back into it is what a real evening does
-- between two races, and it is what resets both.
serverState({ phase = 'waiting', maxResets = -1, totalLaps = 5,
  jokerEnabled = true, drivers = {} })
frames(0.3)
serverState({ phase = 'racing', maxResets = -1, totalLaps = 5,
  jokerEnabled = true, paceLap = true, pacing = true, drivers = {} })
frames(0.5)
veh.x, veh.y = 0, -50; frames(0.2)
clearLog()
driveJoker()
check(jokerSent() == nil,
  'the formation lap refuses the joker, as it always did')

-- The green falls and the field crosses the line: everyone is now on RACING
-- lap 1, which is the driver's second crossing.
serverState({ phase = 'racing', maxResets = -1, totalLaps = 5,
  jokerEnabled = true, paceLap = true, pacing = false, drivers = {} })
frames(0.5)
driveLap()
clearLog()
driveJoker()
check(jokerSent() == nil,
  'RACING LAP 1 refuses it too, which is the lap the rule is actually about '
    .. '(the raw crossing counter reads 2 here and used to let it through)')

driveLap()                            -- racing lap 2
clearLog()
driveJoker()
p = jokerSent()
check(p ~= nil, 'racing lap 2 accepts it')
check(p and p.lap == 2,
  'and reports the RACING lap, not the crossing -- the results file prints this '
    .. 'number next to a board that counts racing laps (got '
    .. tostring(p and p.lap) .. ')')

-- ---------------------------------------------------------------------------
-- Once per race, pace lap or not
-- ---------------------------------------------------------------------------
clearLog()
driveJoker()
check(jokerSent() == nil, 'a second run of the joker route reports nothing')

if fails == 0 then
  print(string.format('joker_test: %d checks, 0 failures', checks))
else
  print(string.format('joker_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
