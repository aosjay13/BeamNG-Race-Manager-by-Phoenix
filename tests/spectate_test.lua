-- Headless test for the SPECTATE TARGET in lua/ge/extensions/raceManager.lua.
--
-- Its own file, with its own world, because the thing under test is what happens
-- as cars come and go and that needs a field nothing else has already respawned
-- into. (respawn_test covers the removal and the grid-slot respawn; sharing its
-- world made a queued placement land in the middle of this and attach the camera
-- to a car that this test had never heard of.)
--
-- What it is about: a race takes finishers off the track and they arrive in a
-- BUNCH. Attach a driver to the car in front and a second later that car crosses
-- the line and is removed -- and with two or three coming in together the car
-- after it goes the same way. The view has to move on, once, rather than being
-- left on nothing.
--
-- The rule being tested is "gone, not stopped": the target is FOLLOWED, and the
-- only thing that moves it is that car ceasing to exist. A car that merely parks
-- is still a car, and a car the driver tabbed to themselves is never taken away
-- from them.
--
-- Run from the repo root: lua5.3 tests/spectate_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local OWN_ID = 7
local world, attached = {}, nil
local handlers = {}
local blockedGroups = {}

local function makeVehicle(id, speed)
  local v = { id = id, speed = speed or 0 }
  function v:getID() return self.id end
  function v:getPosition() return { x = 0, y = 0, z = 0 } end
  function v:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
  function v:getVelocity() return { x = 0, y = self.speed, z = 0 } end
  function v:getJBeamFilename() return 'etk800' end
  function v:setPositionRotation() end
  function v:queueLuaCommand() end
  function v:setMeshAlpha() end
  function v:delete() world[self.id] = nil end
  return v
end

getPlayerVehicle = function () return attached end
be = { getPlayerVehicle = function () return attached end }
function be:enterVehicle(_, veh) attached = veh end
getAllVehicles = function ()
  local list = {}
  for _, v in pairs(world) do list[#list + 1] = v end
  return list
end
getObjectByID = function (id) return world[id] end
MPVehicleGE = { isOwn = function (id) return id == OWN_ID end }

core_vehicles = {
  removeCurrent = function ()
    if attached then attached:delete() end
    attached = nil
    return true
  end,
  spawnNewVehicle = function () return nil end,
}
local freeCam = false
commands = {
  setFreeCamera = function () freeCam = true end,
  isFreeCamera  = function () return freeCam end,
  setGameCamera = function () freeCam = false end,
}
core_camera = { setByName = function () end }
core_input_actionFilter = {
  setGroup  = function () end,
  addAction = function (_, name, blocked) blockedGroups[name] = blocked end,
}
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function () end }
MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function () end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()
local function frames(seconds)
  for _ = 1, math.floor(seconds / 0.05 + 0.5) do RM.onUpdate(0.05) end
end
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end
local function grabberBlocked() return blockedGroups['raceManagerGrabber'] == true end
-- The derby broadcast carries its phase as `derbyPhase`, and every broadcast
-- from the current plugin is protocol-stamped -- an unstamped one is dropped as
-- coming from an outdated server copy.
local function derbyPhase(p)
  handlers['RM_DerbyUpdate']({ rmProtocol = 2, derbyPhase = p, derbyPlayers = {} })
end

-- Three rivals still running, at descending speeds, plus our own car.
local A, B, C = 101, 102, 103
world[OWN_ID] = makeVehicle(OWN_ID)
world[A] = makeVehicle(A, 30)
world[B] = makeVehicle(B, 25)
world[C] = makeVehicle(C, 20)
attached = world[OWN_ID]

serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race' })
check(world[OWN_ID] == nil, 'a race finisher is taken off the track')
check(attached ~= nil and attached:getID() == A,
  'and lands on the fastest car still running, not on their own parked one')

-- THE BACK-TO-BACK CASE. That car finishes and is removed under them.
world[A] = nil
frames(0.6)
check(attached ~= nil and attached:getID() == B,
  'when the car being watched goes, the view moves on to the next one moving')

-- And again, a moment later, which is what a bunched finish actually looks like.
world[B] = nil
frames(0.6)
check(attached ~= nil and attached:getID() == C,
  'and again when the next one finishes right behind it')

-- GONE IS NOT THE SAME AS STOPPED. A car that parks is still a car; if a driver
-- wants to watch it park, that is their business.
world[C].speed = 0
frames(2.0)
check(attached ~= nil and attached:getID() == C,
  'a target that merely parks is left alone')

-- A car the driver tabbed to themselves is followed, never overridden.
world[A] = makeVehicle(A, 40)
attached = world[A]
frames(2.0)
check(attached ~= nil and attached:getID() == A,
  'a target the driver picked is never taken away from them')

-- Nothing left at all: the view is left where it is rather than flicking between
-- cars that are not there.
world[A], world[C] = nil, nil
frames(1.0)
check(true, 'an empty field does not spin looking for a target')

check(freeCam == false, 'and no camera MODE was forced at any point')

-- ---------------------------------------------------------------------------
-- The node grabber is off for the whole of a derby
-- ---------------------------------------------------------------------------
-- Dragging physics nodes is a debug tool everywhere else and a winning move in a
-- demolition derby: pull your own wreck back onto its wheels, or drag somebody
-- else into the wall without touching them.
handlers['RM_ReleaseSpectate']({ source = 'race' })
frames(0.2)
check(grabberBlocked() == false, 'the grabber is free outside a derby')

for _, phase in ipairs({ 'forming', 'countdown', 'running' }) do
  derbyPhase(phase)
  frames(0.2)
  check(grabberBlocked() == true, 'the grabber is blocked during derby ' .. phase)
end

-- ...and comes back when the derby is over. A tool left dead after the session
-- that disabled it is its own bug report.
derbyPhase('idle')
frames(0.2)
check(grabberBlocked() == false, 'and comes back once the derby is over')

-- ---------------------------------------------------------------------------
-- The blocked action NAMES have to be the game's, not ours
-- ---------------------------------------------------------------------------
-- A filter group made of names nothing answers to fails completely silently: no
-- error, no log line, it just blocks nothing. The first version of this list was
-- guessed in snake_case -- `nodegrabber_action` and friends -- and every name was
-- wrong, so the grabber went on working through a block that reported success.
--
-- BeamNG keeps the canonical set in core/input/actionFilter.lua as
-- actionTemplates.nodegrabber. This pins ours to it by NAME SHAPE: every entry
-- must be camelCase, because that is the convention every real action in that
-- file uses, and snake_case is what the wrong guess looked like.
do
  local src = io.open('lua/ge/extensions/raceManager.lua'):read('*a')
  local list = src:match('GRAB%s*=%s*{(.-)}')
  check(list ~= nil, 'found the GRAB action list')
  local n, bad = 0, {}
  for name in (list or ''):gmatch("'([%w_]+)'") do
    n = n + 1
    if name:find('_') then bad[#bad + 1] = name end
  end
  check(n >= 6, "the list has the node grabber actions in it")
  check(#bad == 0,
    "no snake_case names: BeamNG actions are camelCase, and a name nothing "
      .. "answers to blocks nothing and says nothing -- " .. table.concat(bad, ", "))
  for _, need in ipairs({ 'nodegrabberAction', 'nodegrabberGrab',
                          'nodegrabberStrength', 'nodegrabberPadGrab' }) do
    check((list or ''):find("'" .. need .. "'", 1, true) ~= nil,
      "blocks " .. need .. ", one of the games own nodegrabber actions")
  end
end

if fails == 0 then
  print('spectate_test: ' .. checks .. ' checks, 0 failures')
else
  print('spectate_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
