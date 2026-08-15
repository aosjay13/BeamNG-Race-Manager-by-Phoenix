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
local spawnedAt = nil   -- where the last respawn was placed (the weld fix)
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
  spawnNewVehicle = function (_, opts)
    spawns = spawns + 1
    spawnedAt = opts and opts.pos or nil
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
-- A RACE FINISHER: the car comes off the track, the camera is left alone
-- ===========================================================================
-- Taking a finisher off the track is deliberate -- they have nothing left to
-- gain and a parked car on the racing line is an obstacle for everyone still
-- running. What was wrong was everything AROUND that: the camera was forced into
-- freecam and re-forced every second, and the whole field was respawned back
-- onto the few metres of road they had all just been removed from.
--
-- The grid this driver was given, so the respawn has a slot to go to.
handlers['RM_ApplyLayout']({
  name = 'test', checkpoints = { { x = 0, y = 300, z = 0, hx = 0, hy = 1 } },
  startPositions = {
    { x = 10, y = 0, z = 0, hx = 0, hy = 1 },
    { x = 20, y = 0, z = 0, hx = 0, hy = 1 },
  },
})
handlers['RM_GridAssign']({ slot = 2, order = 1, count = 1 })
frames(2.0)
deleted, spawns, spawnedAt = {}, 0, nil
attached = world[OWN_ID]
blockedGroups = {}

serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ForceSpectate']({
  reason = 'You finished the race — spectating until the flag', source = 'race',
})

check(deleted[OWN_ID] == true, 'a race finisher IS taken off the track')
check(deleted[RIVAL_ID] ~= true, "and no other car is touched")
check(freeCam == false,
  'but the camera MODE is left alone -- the driver keeps whatever view they had')
check(drivingBlocked() == true, 'and driving is filtered off')
check(attached ~= nil and attached:getID() == RIVAL_ID,
  'they are put on a car that is still MOVING, so there is a race to watch')

-- The mod must not "helpfully" delete that rival's car when it hears about a
-- spawn or a reset while spectating.
RM.onVehicleSpawned(RIVAL_ID)
check(deleted[RIVAL_ID] ~= true, 'a rival spawning does not get their car deleted')
RM.onVehicleResetted(RIVAL_ID)
check(deleted[RIVAL_ID] ~= true, 'a rival resetting does not get their car deleted')

-- ===========================================================================
-- The flag: the field comes back ON ITS GRID SLOTS, not on the finish line
-- ===========================================================================
serverState({ phase = 'finished', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ReleaseSpectate']({ source = 'race', order = 1, count = 5 })
check(ghosts[RIVAL_ID] == true, 'cars are ghosted while the field respawns')
check(spawns == 0, 'and nothing has spawned yet -- the placement is queued')

frames(0.3)
check(spawns == 1, 'our car comes back')
check(drivingBlocked() == false, 'and it can be driven again')
check(attached ~= nil and attached:getID() == RESPAWNED_ID,
  'with this client attached to OUR car, not whatever the game picked')
check(freeCam == false, 'still without the mod ever touching the camera mode')

-- THE WELD FIX. A race removes cars as they take the flag, so every snapshot is
-- within a few metres of the start/finish line -- and respawning each car at its
-- own snapshot put the whole field back into that same few metres, inside each
-- other. The grid is spaced by construction, and this driver owns slot 2 of it.
check(spawnedAt ~= nil, 'the respawn was given an explicit position')
check(spawnedAt ~= nil and math.abs(spawnedAt.x - 20) < 0.01
  and math.abs(spawnedAt.y - 0) < 0.01,
  "and it is this drivers GRID SLOT, not the finish line they were removed at")

world[RIVAL_ID].x = 40
if world[RESPAWNED_ID] then world[RESPAWNED_ID].x = 80 end
frames(3.0)
check(ghosts[RIVAL_ID] == nil, 'collisions come back once the field is placed and settled')

-- ===========================================================================
-- DERBY ELIMINATION: the wreck stays in the arena, and stays visible
-- ===========================================================================
-- The opposite call, and the one the live report was about. Deleting a vehicle
-- in BeamMP deletes it for EVERY client, so using deletion to mean "you are out"
-- removed the car from the arena the other drivers were still fighting in.
world[OWN_ID] = makeVehicle(OWN_ID)
attached = world[OWN_ID]
deleted, spawns, blockedGroups = {}, 0, {}
serverState({ phase = 'waiting', totalLaps = 3, maxResets = -1, drivers = {} })
handlers['RM_ForceSpectate']({ reason = 'Eliminated', source = 'derby' })

check(deleted[OWN_ID] ~= true, 'an eliminated driver KEEPS their car as a wreck')
check(world[OWN_ID] ~= nil, 'so it is still in the arena for everyone else to see')
check(deleted[RIVAL_ID] ~= true,
  'and eliminating one driver touches no other car -- B through N are unaffected')
check(drivingBlocked() == true, 'the wreck cannot be driven')
check(freeCam == false, 'and no camera mode is forced on them')
check(attached ~= nil and attached:getID() == OWN_ID,
  'they are left on their OWN wreck rather than moved somewhere automatically')

-- Tabbing away is theirs to do, and the mod does not drag them back. This is the
-- loop that used to re-assert freecam every second.
attached = world[RIVAL_ID]
frames(5.0)
check(attached ~= nil and attached:getID() == RIVAL_ID,
  'after five seconds of watching a rival, the mod has not snatched the view back')
check(deleted[RIVAL_ID] ~= true, 'and watching a rival never deletes their car')

handlers['RM_ReleaseSpectate']({ source = 'derby' })
check(drivingBlocked() == false, 'the derby ending gives driving back')
check(spawns == 0, 'and nothing respawns, because nothing was ever removed')

if fails == 0 then
  print('respawn_test: ' .. checks .. ' checks, 0 failures')
else
  print('respawn_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
