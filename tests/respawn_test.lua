-- Headless test for the client half of the post-session respawn in
-- lua/ge/extensions/raceManager.lua.
--
-- Why this exists: in multiplayer "the player's vehicle" and "our vehicle" are
-- different questions, and the mod used to ask the first one when it meant the
-- second. The moment a finisher's car is deleted BeamNG hands the camera to
-- whatever vehicle is nearest — another player's car — and from there:
--
--   * the respawn guard ("do I already have a car?") answered yes, so the
--     driver never got theirs back;
--   * the camera was left wherever the game had put it, so every client in the
--     session ended up watching the same car;
--   * removeLocalVehicle would have deleted that rival's car rather than ours.
--
-- Every stub below is arranged around that one situation: our car is gone and
-- the client is looking at somebody else's.
--
-- Run from the repo root: lua5.3 tests/respawn_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- A world with two cars in it: ours, and somebody else's
-- ---------------------------------------------------------------------------
local OWN_ID, RIVAL_ID, RESPAWNED_ID = 7, 42, 77

local sent     = {}
local handlers = {}
local world    = {}     -- [id] = vehicle, the vehicles that currently exist
local attached = nil    -- what getPlayerVehicle(0) hands back
-- [id] = true while that car's vehicle-to-vehicle collisions are switched off.
--
-- Collisions are dropped through BeamNG's own vehicle-side obj:setGhostEnabled,
-- queued across from GE like any other vehicle command -- so watching the
-- command string is how this test observes the real mechanism rather than a
-- stand-in for it. (It used to stub MPVehicleGE.setGhostMode, which no BeamMP
-- build has ever had: the test passed against an API that did not exist while
-- ghosting did nothing on track.)
local ghosts   = {}
local deleted  = {}     -- [id] = true for every vehicle the mod deleted
local spawns   = 0

local function makeVehicle(id, speed)
  local v = { id = id, x = 0, y = 0, z = 0, speed = speed or 0 }
  function v:getID() return self.id end
  function v:getPosition() return { x = self.x, y = self.y, z = self.z } end
  function v:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
  function v:getDirectionVector() return { x = 0, y = 1, z = 0 } end
  function v:getVelocity() return { x = 0, y = self.speed, z = 0 } end
  function v:getJBeamFilename() return 'etk800' end
  function v:setPositionRotation() end
  function v:queueLuaCommand(cmd)
    if cmd == 'obj:setGhostEnabled(true)'  then ghosts[self.id] = true end
    if cmd == 'obj:setGhostEnabled(false)' then ghosts[self.id] = nil  end
  end
  function v:setMeshAlpha() end
  function v:delete()
    deleted[self.id] = true
    world[self.id] = nil
  end
  return v
end

world[OWN_ID]   = makeVehicle(OWN_ID)
world[RIVAL_ID] = makeVehicle(RIVAL_ID, 30)   -- still racing, 30 m/s
attached = world[OWN_ID]

getPlayerVehicle = function (_) return attached end
be = { getPlayerVehicle = function () return attached end }
-- Explicitly binding the camera is the fix for "everyone spectated one car".
function be:enterVehicle(_, veh) attached = veh end

getAllVehicles = function ()
  local list = {}
  for _, v in pairs(world) do list[#list + 1] = v end
  return list
end

-- BeamMP's ownership oracle. Without it the mod has no way to tell our car from
-- anyone else's, which is the whole root of this bug.
MPVehicleGE = {
  isOwn = function (id) return id == OWN_ID or id == RESPAWNED_ID end,
}

-- BeamNG's scene lookup. The ghost bookkeeping is keyed by vehicle id, so it
-- needs a way back to the object for cars it is not holding a reference to.
getObjectByID = function (id) return world[id] end

core_vehicles = {
  -- Deletes whatever the client is ATTACHED to. That is only safe once the mod
  -- has established the attached car is ours; the test asserts it never reaches
  -- here holding a rival.
  removeCurrent = function ()
    if not attached then error('removeCurrent with nothing attached') end
    local id = attached:getID()
    attached:delete()
    -- BeamNG hands the camera on to whatever is left, which in a BeamMP session
    -- is another player's car. This is the line that made the bug.
    attached = world[RIVAL_ID]
    return id
  end,
  spawnNewVehicle = function ()
    spawns = spawns + 1
    world[RESPAWNED_ID] = makeVehicle(RESPAWNED_ID)
    -- Deliberately does NOT attach the camera: the mod has to do that itself.
    return world[RESPAWNED_ID]
  end,
}

local freeCam = false
commands = {
  setFreeCamera = function () freeCam = true end,
  isFreeCamera  = function () return freeCam end,
  setGameCamera = function () freeCam = false end,
}
core_camera = { setByName = function () end }
local blockedGroups = {}
core_input_actionFilter = {
  setGroup  = function () end,
  addAction = function (_, name, blocked) blockedGroups[name] = blocked end,
}
local function drivingBlocked() return blockedGroups['raceManagerSpectate'] == true end
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }

vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function () end }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function frames(seconds, step)
  step = step or 0.05
  for _ = 1, math.floor(seconds / step + 0.5) do RM.onUpdate(step) end
end
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end

-- ===========================================================================
-- A driver takes the flag: NOTHING IS DELETED, NO CAMERA MODE IS TOUCHED
-- ===========================================================================
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ForceSpectate']({
  reason = 'You finished the race — spectating until the flag', source = 'race',
})

check(deleted[OWN_ID] ~= true, "the finisher KEEPS their car -- nothing is deleted")
check(world[OWN_ID] ~= nil, "and it is still in the world for everyone else to see")
check(deleted[RIVAL_ID] ~= true, 'and no other player\'s car is touched')
check(freeCam == false,
  "the camera MODE is left alone -- the driver keeps whatever view they had")
check(drivingBlocked() == true,
  "what is taken away is the DRIVING: the input filter is armed")
check(attached ~= nil and attached:getID() == RIVAL_ID,
  "and they are placed on a car that is still MOVING, so there is a race to watch")

-- The mod must not "helpfully" delete that rival's car when it hears about a
-- spawn or a reset while spectating.
RM.onVehicleSpawned(RIVAL_ID)
check(deleted[RIVAL_ID] ~= true, 'a rival spawning does not get their car deleted')
RM.onVehicleResetted(RIVAL_ID)
check(deleted[RIVAL_ID] ~= true, 'a rival resetting does not get their car deleted')

-- ===========================================================================
-- The flag: every participant is released, ours comes back, camera and all
-- ===========================================================================
serverState({ phase = 'finished', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ReleaseSpectate']({ source = 'race', order = 1, count = 5 })

-- Collisions are off for the whole operation: a field respawning together is
-- how cars land inside each other and are thrown apart.
check(ghosts[RIVAL_ID] == true, 'cars are ghosted while the field respawns')
check(spawns == 0, 'and nothing has spawned yet — the placement is queued')

frames(0.3)
check(spawns == 0,
  "NOTHING respawns at the flag: the car was never removed, so there is nothing "
    .. "to put back -- which is what stops a field landing inside itself")
check(drivingBlocked() == false, "driving comes back when the lock lifts")
check(attached ~= nil and attached:getID() == OWN_ID,
  "and the driver is put back on their own car")
check(freeCam == false, "still without the mod ever touching the camera mode")
check(ghosts[RIVAL_ID] == true, 'collisions stay off until the whole field has settled')

-- ...and come back once it has, AND once the cars are off each other. Landing
-- is what the placement timer waits for; being clear of the car next to you is
-- the gate every ghost passes through on its way back to solid. The mock spawns
-- every car at the origin, so they are put on their own ground here -- which is
-- what a grid of start slots is.
world[RIVAL_ID].x = 40
if world[RESPAWNED_ID] then world[RESPAWNED_ID].x = 80 end
frames(3.0)
check(ghosts[RIVAL_ID] == nil, 'collisions come back once the field is placed and settled')

-- ===========================================================================
-- The whole field, from the back of it
-- ===========================================================================
-- Every driver is released by the same broadcast. Under the old design that
-- meant a field of deleted cars all respawning at once, which is how they came
-- back inside each other and welded. Nothing is deleted now, so nothing
-- respawns, and the ordering that existed to stagger those spawns has nothing
-- left to stagger.
attached = world[OWN_ID]
spawns = 0
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ForceSpectate']({ reason = 'out', source = 'race' })
check(drivingBlocked() == true, "the back of the field is locked the same way")
check(deleted[OWN_ID] ~= true, "and keeps its car the same way")

serverState({ phase = 'finished', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ReleaseSpectate']({ source = 'race', order = 5, count = 5 })
frames(1.5, 0.05)
check(spawns == 0, "no car in the field respawns, whatever its place in the order")
check(drivingBlocked() == false, "and every one of them can drive again")
check(attached ~= nil and attached:getID() == OWN_ID, "on its own car")

-- ===========================================================================
-- DERBY ELIMINATION: the wreck stays in the arena, and stays visible
-- ===========================================================================
-- The reported symptom was players vanishing -- eliminated drivers gone from
-- every screen, and the mode unplayable. Deleting a vehicle in BeamMP deletes it
-- for EVERY client, so "you are out" was removing the car from the arena the
-- other drivers were still fighting in.
--
-- A derby elimination is also the one case that is NOT moved to another car: the
-- arena is the show and the eliminated driver is sitting in it. They stay on
-- their own wreck and can tab away if they want to.
deleted, spawns = {}, 0
attached = world[OWN_ID]
blockedGroups = {}
serverState({ phase = 'waiting', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ForceSpectate']({ reason = 'Eliminated', source = 'derby' })

check(deleted[OWN_ID] ~= true, "an eliminated driver KEEPS their car as a wreck")
check(world[OWN_ID] ~= nil, "so it is still in the arena for everyone else to see")
check(deleted[RIVAL_ID] ~= true,
  "and eliminating one driver touches no other car -- B through N are unaffected")
check(drivingBlocked() == true, "the wreck cannot be driven")
check(freeCam == false, "and no camera mode is forced on them")
check(attached ~= nil and attached:getID() == OWN_ID,
  "they are left on their OWN wreck rather than moved somewhere automatically")

-- Tabbing away is theirs to do, and the mod does not drag them back. This is the
-- loop that used to re-assert freecam every second.
attached = world[RIVAL_ID]
frames(5.0)
check(attached ~= nil and attached:getID() == RIVAL_ID,
  "after five seconds of watching a rival, the mod has not snatched the view back")
check(deleted[RIVAL_ID] ~= true, "and watching a rival never deletes their car")

-- The derby ends: driving comes back, nothing respawns.
handlers['RM_ReleaseSpectate']({ source = 'derby' })
check(drivingBlocked() == false, "the derby ending gives driving back")
check(spawns == 0, "and nothing respawns, because nothing was ever removed")

if fails == 0 then
  print('respawn_test: ' .. checks .. ' checks, 0 failures')
else
  print('respawn_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
