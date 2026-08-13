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

local function makeVehicle(id)
  local v = { id = id, x = 0, y = 0, z = 0 }
  function v:getID() return self.id end
  function v:getPosition() return { x = self.x, y = self.y, z = self.z } end
  function v:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
  function v:getDirectionVector() return { x = 0, y = 1, z = 0 } end
  function v:getVelocity() return { x = 0, y = 0, z = 0 } end
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
world[RIVAL_ID] = makeVehicle(RIVAL_ID)
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
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
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
-- A driver takes the flag: their car is removed, and it is THEIR car
-- ===========================================================================
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ForceSpectate']({
  reason = 'You finished the race — spectating until the flag', source = 'race',
})

check(deleted[OWN_ID] == true, 'the finisher\'s own car is removed')
check(deleted[RIVAL_ID] ~= true, 'and no other player\'s car is touched')
check(freeCam == true, 'the finisher is put into freecam')
check(attached ~= nil and attached:getID() == RIVAL_ID,
  'the game has now attached this client to a rival\'s car (the trap)')

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
check(spawns == 1,
  'our car comes back even though the client was attached to a rival\'s car')
check(attached ~= nil and attached:getID() == RESPAWNED_ID,
  'and the camera is bound to OUR car, not left on whatever the game picked')
check(freeCam == false, 'the driving camera is restored')
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
-- The stagger: a driver further down the field waits its turn
-- ===========================================================================
-- Same operation, from the back of a five-car field. Nothing may happen on the
-- tick the release arrives, or the whole point of the order is lost.
attached = world[RESPAWNED_ID]
spawns = 0
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ForceSpectate']({ reason = 'out', source = 'race' })
serverState({ phase = 'finished', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ReleaseSpectate']({ source = 'race', order = 5, count = 5 })

frames(0.1, 0.01)
check(spawns == 0, 'the last car in the field does not spawn on the first tick')
frames(1.0, 0.05)
check(spawns == 1, 'it spawns once its turn in the order comes round')
check(attached ~= nil and attached:getID() == RESPAWNED_ID,
  'and its camera is bound to its own car too')

if fails == 0 then
  print('respawn_test: ' .. checks .. ' checks, 0 failures')
else
  print('respawn_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
