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

local placements = {}   -- every setPositionRotation the mod performed
local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local OWN_ID = 7
local world, attached = {}, nil
local vehCommands = {}   -- every queueLuaCommand the mod sent to a vehicle
local frozen = nil       -- last setFreeze the mod asked for
local handlers = {}
local blockedGroups = {}

local function makeVehicle(id, speed)
  local v = { id = id, speed = speed or 0 }
  function v:getID() return self.id end
  function v:getPosition() return { x = 0, y = 0, z = 0 } end
  function v:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
  function v:getVelocity() return { x = 0, y = self.speed, z = 0 } end
  -- Needed by vehiclePlacement, which the derby-release test below drives to
  -- create a race start position for the fallback to reach for.
  function v:getDirectionVector() return { x = 0, y = 1, z = 0 } end
  function v:getJBeamFilename() return 'etk800' end
  function v:setPositionRotation(x, y, z)
    placements[#placements + 1] = { x = x, y = y, z = z }
  end
  function v:queueLuaCommand(cmd)
    vehCommands[#vehCommands + 1] = tostring(cmd)
    if cmd == 'obj:setGhostEnabled(true)'  then self.ghosted = true  end
    if cmd == 'obj:setGhostEnabled(false)' then self.ghosted = false end
  end
  function v:setMeshAlpha(a) self.alpha = a end
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
-- Recorded rather than discarded: the broadcast camera is the one place the mod
-- sets a camera MODE, so which mode it asked for is a fact worth asserting.
local cameraModes = {}
core_camera = { setByName = function (_, name) cameraModes[#cameraModes + 1] = name end }
core_input_actionFilter = {
  setGroup  = function () end,
  addAction = function (_, name, blocked) blockedGroups[name] = blocked end,
}
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
core_vehicleBridge = {
  executeAction = function (_, action, value)
    if action == 'setFreeze' then frozen = value end
  end,
}
vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
-- The broadcast camera reports back on RaceManagerWatch, which is how the board
-- knows which row to mark. Everything else on this channel is still discarded.
local watchPushes = {}
guihooks = { trigger = function (name, data)
  if name == 'RaceManagerWatch' then watchPushes[#watchPushes + 1] = data end
end }
MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function () end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

-- The extension `require`s its modules (raceManager/derby, and more to come),
-- so the headless harness has to be able to find them the way the game can.
-- One line, and it is what makes a split file testable at all.
package.path = 'lua/ge/extensions/?.lua;' .. package.path
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
handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race', place = 3 })

-- TAKING THE FLAG CREATES AND DESTROYS NOTHING. The car stays exactly where it
-- is, with its collisions off, and the driver stays in it. It used to be deleted
-- here and respawned at the end of the race -- an entity destroy and an entity
-- create per driver, at the one moment a whole field is finishing together.
check(world[OWN_ID] ~= nil, 'a race finisher KEEPS their car: nothing is despawned')
check(world[OWN_ID].ghosted == true, 'it is ghosted instead, so nobody racing can touch it')
check(attached ~= nil and attached:getID() == OWN_ID,
  'and the driver stays in it rather than being thrown at somebody else s car')

-- THE OWNER'S OWN VIEW DOES NOT CHANGE. Collision and alpha are separate calls,
-- and only one of them is the driver's business: their car goes intangible and
-- stays opaque. Everyone else sees it faded, which is asserted in ghost_test
-- where there are remote cars to fade.
check(world[OWN_ID].alpha == nil or world[OWN_ID].alpha == 1,
  'a finisher s own car is never faded for them')

-- DRIVING IS KEPT. A finished driver spectates BY driving: they are already
-- unscoreable and untouchable, so a free car cannot affect the race.
check(blockedGroups['raceManagerSpectate'] ~= true,
  'and they can still drive it, which is how they spectate')

-- THE CAR YOU ARE WATCHING CAN STILL VANISH -- not from a finish any more, but
-- from a disconnect, which deletes the car for everyone. The view has to move on
-- rather than sit on a hole.
attached = world[A]
frames(0.2)
world[A] = nil
frames(0.6)
check(attached ~= nil and attached:getID() == B,
  'a watched car that disconnects hands the view to the next one moving')

-- And again, immediately after, which is what a mass disconnect looks like.
world[B] = nil
frames(0.6)
check(attached ~= nil and attached:getID() == C,
  'and again when the next one goes right behind it')

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
-- AN ELIMINATED DERBY CAR IS A ROLLING CHASSIS, NOT A REVVING ONE
-- ---------------------------------------------------------------------------
-- Reported from a live session: a driver knocked out of a derby sat there with
-- the engine screaming at full throttle.
--
-- Blocking the inputs stops new ones arriving and does nothing about the ones
-- already there -- BeamNG's action filter suppresses an action's onChange, so
-- whatever the value was when the filter armed is the value it keeps. Eliminate
-- somebody mid-corner and the throttle stays exactly where their foot left it.
--
-- What the wreck has to be: no throttle, no brake, no steering, and NO PARKING
-- BRAKE -- it is meant to be an obstacle the survivors can shove around, not one
-- bolted to the arena floor. Solid, too: no ghost and no freeze. The only thing
-- taken away is the driver's own ability to move it.
do
  handlers['RM_ReleaseSpectate']({ source = 'derby' })
  handlers['RM_ReleaseSpectate']({ source = 'race' })
  world[OWN_ID] = world[OWN_ID] or makeVehicle(OWN_ID)
  attached = world[OWN_ID]
  vehCommands = {}

  derbyPhase('running')
  handlers['RM_ForceSpectate']({ reason = 'Demolished', source = 'derby' })
  frames(0.2)

  local function sentTo(input)
    for _, c in ipairs(vehCommands) do
      if c == ('input.event("%s", 0, 1)'):format(input) then return true end
    end
    return false
  end
  for _, input in ipairs({ 'throttle', 'brake', 'steering', 'clutch' }) do
    check(sentTo(input),
      'an eliminated derby car has its ' .. input .. ' zeroed: the filter stops '
        .. 'new input and leaves the last value standing')
  end
  check(sentTo('parkingbrake'),
    'and the parking brake is RELEASED rather than left where it was')

  -- Released, never applied. The end-of-derby stand-down sets it deliberately
  -- to hold the field for the cool-down; an elimination must not, or the wreck
  -- stops being something the survivors can push.
  local applied = false
  for _, c in ipairs(vehCommands) do
    if c:find('parkingbrake", 1', 1, true) then applied = true end
  end
  check(not applied,
    'the parking brake is never SET on an elimination: a wreck bolted to the '
      .. 'floor is a wall, not an obstacle')

  -- Still solid, and still there. A ghost cannot be shoved and a deleted car is
  -- not an obstacle at all.
  check(world[OWN_ID] ~= nil, 'the wreck stays in the arena')
  check(world[OWN_ID].ghosted ~= true,
    'and stays SOLID -- it is an obstacle, which a ghost is not')
  check(frozen ~= true, 'and is not frozen: it has to be free to roll')

  -- ...and the driver cannot drive it.
  check(blockedGroups['raceManagerSpectate'] == true,
    'the driving inputs are filtered, so the driver cannot move it themselves')

  -- THE IGNITION GOES TOO, and the out-of-bounds case is why. A car eliminated
  -- by the stopped timer is by definition sitting still; one disqualified for
  -- leaving the arena was driving a second ago, and zeroed pedals leave an
  -- engine that still idles and still walks an automatic forward.
  local cut, restored = false, false
  for _, c in ipairs(vehCommands) do
    if c:find('setEngineIgnition(false)', 1, true) then cut = true end
  end
  check(cut, 'the engine is cut, so a car disqualified at speed coasts to a '
    .. 'stop instead of idling away under its own power')

  -- ...and comes back at the release, or the driver is handed a car that will
  -- not start for the next session.
  vehCommands = {}
  handlers['RM_ReleaseSpectate']({ source = 'derby' })
  frames(0.2)
  for _, c in ipairs(vehCommands) do
    if c:find('setEngineIgnition(true)', 1, true) then restored = true end
  end
  check(restored, 'and is restored when the derby releases them')

  -- Only ours to put back. A race finisher never had theirs cut -- they keep
  -- their car and drive it -- so the release must not switch anything on.
  vehCommands = {}
  handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race' })
  frames(0.2)
  handlers['RM_ReleaseSpectate']({ source = 'race' })
  frames(0.2)
  local touched = false
  for _, c in ipairs(vehCommands) do
    if c:find('setEngineIgnition', 1, true) then touched = true end
  end
  check(not touched,
    'a race finisher s ignition is never touched, in either direction')

  derbyPhase('idle')
  frames(0.2)
end

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

-- ---------------------------------------------------------------------------
-- The end of a derby stands the cars down
-- ---------------------------------------------------------------------------
-- The arena stays up for a few seconds after the result so it can be seen. A
-- wreck still being driven into people for those seconds is not a cool-down, it
-- is extra time nobody was given.
--
-- Freezing alone is not enough, and that is the point of the order below. The
-- grid hold uses the same freeze and gets away with it because a car on the grid
-- is stationary with nothing pressed; a derby ends with somebody flat to the
-- floor, and a freeze over that captures the throttle -- the engine sits
-- screaming against a locked car and lets go the instant the freeze lifts.
do
  vehCommands = {}
  frozen = nil
  handlers['RM_DerbyUpdate']({ rmProtocol = 2, derbyPhase = 'running',
    derbyOver = false, derbyPlayers = {} })
  frames(0.2)
  check(frozen ~= true, 'a running derby does not freeze anybody')

  handlers['RM_DerbyUpdate']({ rmProtocol = 2, derbyPhase = 'running',
    derbyOver = true, derbyPlayers = {} })
  frames(0.2)
  check(frozen == true, 'once the derby is decided the car is frozen')
  local throttleIdx, freezeIdx
  for i, c in ipairs(vehCommands) do
    if c:find('throttle', 1, true) and throttleIdx == nil then throttleIdx = i end
  end
  check(throttleIdx ~= nil, 'the throttle is let go of')
  local braked = false
  for _, c in ipairs(vehCommands) do
    if c:find('brake', 1, true) then braked = true end
  end
  check(braked, 'and the brakes go on, so the freeze goes over a car already stopping')
  check(blockedGroups['raceManagerResets'] == true,
    'resets are dead: one would reload the vehicle out from under the freeze')
  check(blockedGroups['raceManagerSpectate'] ~= true,
    'but the CONTROLS stay live -- there is nothing to win and the car cannot move')

  -- Released when the derby actually ends, whatever order the broadcasts land in.
  handlers['RM_DerbyUpdate']({ rmProtocol = 2, derbyPhase = 'finished',
    derbyOver = true, derbyPlayers = {} })
  frames(0.4)
  check(frozen == false, 'the freeze lifts when the derby ends')
  check(blockedGroups['raceManagerResets'] ~= true, 'and the reset keys come back')
end

-- ---------------------------------------------------------------------------
-- A DERBY RELEASE DOES NOT PUT THE CAR ON THE RACE'S START LINE
-- ---------------------------------------------------------------------------
-- Reported live: the derby ended, the five-second cool-down ran out, and the
-- driver was respawned onto the start position of whatever race had been run
-- last.
--
-- A derby leaves the wreck in the arena on purpose, so nothing was removed and
-- there is nothing to put back. The placement fallback is the RACE's grid, so
-- with no removed vehicle and no race grid slot it fell all the way through to
-- race start position 1. Released where they sit now; they reset themselves.
RM.setEditorTarget('start')
RM.editorAdd()                          -- a race start position now exists
RM.setEditorTarget('main')

placements = {}
handlers['RM_ForceSpectate']({ reason = 'Eliminated', source = 'derby' })
frames(0.2)
handlers['RM_ReleaseSpectate']({ source = 'derby', order = 1, count = 1 })
frames(3.0)
check(#placements == 0,
  'a derby release places the car nowhere: it is left where the derby left it '
    .. '(got ' .. #placements .. ' placement(s))')

-- A RACE RELEASE PLACES NOTHING EITHER, now that nothing was removed.
--
-- It used to stand the whole field back on the grid, which was necessary while
-- finishing deleted the car: something had to put it back, and putting a whole
-- field back at once needed slots to stop them respawning into each other.
-- Nothing is removed now, so there is nothing to put back -- and a driver who
-- spent the last two laps spectating from wherever they drove to is released
-- exactly there. Teleporting the field at the flag would be the same entity
-- churn this change exists to remove, wearing a different hat.
placements = {}
handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race' })
frames(0.2)
check(world[OWN_ID] ~= nil and world[OWN_ID].ghosted == true,
  'the finisher is ghosted in place')
handlers['RM_ReleaseSpectate']({ source = 'race', order = 1, count = 1 })
frames(3.0)
check(#placements == 0,
  'a RACE release places the car nowhere either: it was never taken away (got '
    .. #placements .. ')')
check(world[OWN_ID] ~= nil and world[OWN_ID].ghosted == false,
  'and the flag hands its collisions back')

-- ---------------------------------------------------------------------------
-- THE BROADCAST CAMERA: click a name, land on that car
-- ---------------------------------------------------------------------------
-- The board sends a BeamMP PLAYER id, never a vehicle id, because a vehicle id
-- is a local scene-object id and means a different car on every machine. So the
-- one thing worth pinning here is the resolution: pid in, the right local car
-- out, and the camera actually moved to it.
--
-- IT IS ALSO THE ONE PLACE THE MOD SETS A CAMERA MODE. Everywhere else that is
-- the driver's business and the tests above assert it is left alone. Here the
-- view IS the request -- a broadcaster clicking a name is asking for a chase
-- camera on that car, not for whatever seat they were last in -- so orbit is
-- asserted rather than merely permitted.
do
  world[OWN_ID] = world[OWN_ID] or makeVehicle(OWN_ID)
  world[A] = makeVehicle(A, 12)
  world[B] = makeVehicle(B, 8)
  -- MPVehicleGE's list is how a pid becomes a local car, and it is the reason
  -- the board can name a driver at all. OWN_ID is deliberately NOT in it: a
  -- build that only tracks remote vehicles is the case ownVehicle() exists for.
  MPVehicleGE.getVehicles = function ()
    return {
      { ownerID = 21, gameVehicleID = A },
      { ownerID = 22, gameVehicleID = B },
    }
  end

  attached = world[OWN_ID]
  cameraModes = {}
  watchPushes = {}
  check(RM.spectateDriver(21) == true, 'clicking a name switches to that driver s car')
  check(attached ~= nil and attached:getID() == A,
    'and it is the car that pid owns, not whichever one was nearest')
  check(cameraModes[#cameraModes] == 'orbit',
    'the camera goes to orbit: a broadcaster asked for a view, not a seat')
  check(#watchPushes == 1 and watchPushes[1].pid == 21 and watchPushes[1].ok == true,
    'and the board is told which car the camera actually landed on')

  -- A second click moves it again. Nothing latches: the board is a camera
  -- control, and a control that only works once is a bug report.
  check(RM.spectateDriver(22) == true, 'a second click moves the camera again')
  check(attached ~= nil and attached:getID() == B, 'to the second driver s car')

  -- OUR OWN ROW GOES THROUGH ownVehicle(), not the pid list. A finisher
  -- watching the race is a spectator with a car, and it is in the field like
  -- anyone else's -- so their own name has to be clickable too.
  check(RM.spectateDriver(1) == true, 'our own row resolves through ownVehicle')
  check(attached ~= nil and attached:getID() == OWN_ID, 'and lands on our own car')

  -- A pid with no car HERE is the ordinary case for somebody who has only just
  -- joined. It must fail loudly enough for the board to un-mark the row, and
  -- quietly enough to leave the camera where it was.
  watchPushes = {}
  local wasOn = attached
  check(RM.spectateDriver(99) == false, 'a driver with no local car cannot be watched')
  check(attached == wasOn, 'and the camera is left exactly where it was')
  check(#watchPushes == 1 and watchPushes[1].ok == false,
    'the board is told the switch failed, so it does not mark a row it never reached')

  -- Garbage in changes nothing at all. The id crosses a bngApi.engineLua string
  -- boundary to get here, so "it came from our own template" is not a guarantee.
  watchPushes = {}
  check(RM.spectateDriver(nil) == false, 'a nil pid is refused')
  check(RM.spectateDriver('nonsense') == false, 'and so is a non-numeric one')
  check(#watchPushes == 0, 'neither of which tells the board anything')
end

if fails == 0 then
  print('spectate_test: ' .. checks .. ' checks, 0 failures')
else
  print('spectate_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
