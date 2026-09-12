-- Headless test for WHICH CAR THE MOD MEASURES AND MOVES when the camera is
-- pointed at somebody else's.
--
-- Run from the repo root: lua tests/tabbed_camera_test.lua
--
-- BeamNG's getPlayerVehicle answers "what is the camera attached to", and in
-- BeamMP that is regularly a rival: tabbing round the field to watch a battle
-- is an ordinary thing to do on a green-flag lap. It is NOT the same question
-- as "which car is mine", and every measurement and every teleport in this mod
-- means the second one.
--
-- Both halves of getting that wrong were reported from one live session:
--
--   * THE LAPS. checkGates read its position off the attached car, so a driver
--     watching the leader was credited with the LEADER'S gate crossings. They
--     climbed the leaderboard without moving, and the finishing order was
--     wrong for everybody behind them.
--
--   * THE CAR. A freeze or a teleport aimed at the attached vehicle lands on
--     the rival instead. Their body is pinned (or dragged) on this client
--     while BeamMP goes on syncing their real position into it, the two fight,
--     and the car tears itself apart -- for us, and for every other client
--     that was watching it when theirs did the same. Reported as a car revving
--     to the limiter and exploding for everybody except its own driver.
--
-- The rule this pins: ownership decides, the camera never does. Only questions
-- ABOUT the camera (the spectate target) may read the attached vehicle.

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local sent     = {}
local handlers = {}

local OWN_ID, RIVAL_ID = 7, 42

local function makeVehicle(id)
  local v = { id = id, x = 0, y = 0, z = 0, moves = 0, frozen = nil }
  function v:getID() return self.id end
  function v:getPosition() return { x = self.x, y = self.y, z = self.z } end
  function v:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
  function v:getDirectionVector() return { x = 0, y = 1, z = 0 } end
  function v:getVelocity() return { x = 0, y = 0, z = 0 } end
  function v:getJBeamFilename() return self.model or 'etk800' end
  function v:setPositionRotation(x, y, z)
    self.x, self.y, self.z = x, y, z
    self.moves = self.moves + 1
  end
  function v:queueLuaCommand(cmd)
    -- The fallback freeze path, for a build without the vehicle bridge.
    if tostring(cmd):match('controller%.setFreeze%(1%)') then self.frozen = true end
    if tostring(cmd):match('controller%.setFreeze%(0%)') then self.frozen = false end
  end
  function v:setMeshAlpha() end
  return v
end

local own, rival = makeVehicle(OWN_ID), makeVehicle(RIVAL_ID)
local world = { [OWN_ID] = own, [RIVAL_ID] = rival }

-- THE CAMERA, and it starts on our own car. `attached` is what getPlayerVehicle
-- answers; nothing else in this file changes hands when it moves.
local attached = own

be               = { getPlayerVehicle = function () return attached end }
getPlayerVehicle = function (_) return attached end
getAllVehicles   = function () return { own, rival } end
getObjectByID    = function (id) return world[id] end
-- The whole point: BeamMP can tell us who owns what, and only one of these two
-- cars is ours however the camera is pointed.
MPVehicleGE = { isOwn = function (id) return id == OWN_ID end }

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

core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt   = { getConfig = function ()
  return { parts = {}, vars = {}, configName = 'Stock' }
end }
-- BeamNG tags every model with a Type in its info.json. 'Trailer' and 'Prop'
-- are the towed ones; this is what lets the mod tell a driver's race car from
-- the box on the back of it.
core_vehicles = core_vehicles or {}
core_vehicles.getModel = function (model)
  return { model = { Type = (model == 'tsfb') and 'Trailer' or 'Car' } }
end
-- Recorded per vehicle, because WHICH car was frozen is the entire question.
core_vehicleBridge = {
  executeAction = function (veh, action, value)
    if action == 'setFreeze' and veh then veh.frozen = value end
  end,
}

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

-- ---------------------------------------------------------------------------
-- Harness helpers
-- ---------------------------------------------------------------------------
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end
local function frame(n)
  for _ = 1, (n or 1) do RM.onUpdate(0.05) end
end

-- Crossing detection works on the SEGMENT between two frames, so a gate is
-- cleared by being on either side of it on consecutive frames. Moving a car
-- here means moving THAT car and letting a frame observe it.
local function moveTo(v, y)
  v.y = y
  frame()
end

local SF_Y = 200
handlers['RM_ApplyLayout']({
  name = 'oval', width = 40, height = 10, depth = 2,
  checkpoints = {
    { x = 0, y = 100,  z = 0, hx = 0, hy = 1 },
    { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 },
  },
})

local function lapsReported()
  local n = 0
  for _, m in ipairs(sent) do if m.event == 'RM_Lap' then n = n + 1 end end
  return n
end

-- A lap has to outlast TUNE.LAP_DEBOUNCE (two seconds) or the crossing is
-- discarded as a double-fire. Burned well clear of the line, so the white-flag
-- radius is never involved.
local function coast() frame(50) end

-- ---------------------------------------------------------------------------
-- THE LAPS: a watched car's crossings belong to its own driver
-- ---------------------------------------------------------------------------
serverState({ phase = 'racing', totalLaps = 10, maxResets = -1, drivers = {} })
own.y = 10
frame()

-- Tab over to the rival. Our own car stays exactly where it is -- which is what
-- a driver watching somebody else actually does, because they are not in it.
attached = rival
rival.y = 10
frame()

-- Now drive the RIVAL round a full lap, gate by gate.
moveTo(rival, 95); moveTo(rival, 105)
coast()
moveTo(rival, 195); moveTo(rival, 205)
moveTo(rival, 10)
coast()

check(lapsReported() == 0,
  'a lap driven by the car we are WATCHING is never reported as ours')
check(own.y == 10,
  'and our own car has not moved, which is the state the report contradicted')

-- The same lap driven by our OWN car still counts, camera or no camera. This is
-- the half that proves the fix is a narrowing rather than a switch-off: a
-- driver may perfectly well watch a rival while their own car is still running
-- (a passenger camera, a replay angle), and their laps are still theirs.
moveTo(own, 95); moveTo(own, 105)
coast()
moveTo(own, 195); moveTo(own, 205)
moveTo(own, 10)
coast()

check(lapsReported() == 1,
  'our own car s lap is reported even while the camera is on somebody else')

-- ---------------------------------------------------------------------------
-- THE CAR: a freeze lands on ours, never on the one being watched
-- ---------------------------------------------------------------------------
own.frozen, rival.frozen = nil, nil

-- A standing start, with the camera still parked on the rival. The grid hold
-- places this client's car on its slot and pins it.
handlers['RM_ApplyLayout']({
  name = 'oval', width = 40, height = 10, depth = 2,
  checkpoints = {
    { x = 0, y = 100,  z = 0, hx = 0, hy = 1 },
    { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 },
  },
  startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 } },
})
local rivalMovesBefore = rival.moves
serverState({ phase = 'waiting', totalLaps = 10, maxResets = -1, drivers = {} })
serverState({ phase = 'grid', totalLaps = 10, maxResets = -1, drivers = {} })
handlers['RM_GridAssign']({ slot = 1, order = 1, count = 2 })
frame(10)

check(rival.frozen ~= true,
  'the car being WATCHED is never frozen: pinning a rival s body on this client '
  .. 'while BeamMP syncs their real position into it is what detonates it')
check(rival.moves == rivalMovesBefore,
  'and it is never teleported either, for the same reason')
check(own.frozen == true, 'our own car is the one held on the grid')

-- ---------------------------------------------------------------------------
-- A DRIVER WITH A TRAILER OWNS TWO VEHICLES, and only one of them is the car
-- ---------------------------------------------------------------------------
-- "Ours" is true of a trailer as well, so resolving our car by SEARCHING for an
-- owned vehicle answers with whichever the engine lists first. On this league's
-- server everybody has one: the admin places donor cars and trailers and the
-- field clones from them, so a cloned trailer is a vehicle that driver owns.
--
-- Getting it wrong puts a grid placement on the TRAILER. It is teleported to
-- the start slot while the car it is coupled to stays where it was, and the
-- coupler between them spans the gap. Reported as trailers exploding the moment
-- they were connected.
--
-- The answer is the car the driver was last SEATED in, which a trailer can only
-- be if they climbed into the trailer. So the trailer is created here AFTER the
-- driver has been in their car, which is the real order: you cannot tow
-- something you never drove to.
do
  local TRAILER_ID = 99
  local trailer = makeVehicle(TRAILER_ID)
  trailer.model = 'tsfb'          -- Type = Trailer, per the stub above
  world[TRAILER_ID] = trailer
  -- OWNED, like the car. This is the whole trap.
  MPVehicleGE.isOwn = function (id) return id == OWN_ID or id == TRAILER_ID end
  -- FIRST in the scan order, which is the case a search gets wrong. ipairs
  -- walks this list, so the trailer is the first owned vehicle it meets.
  getAllVehicles = function () return { trailer, own, rival } end

  -- Sit in the car, so the mod learns which of the two it is.
  attached = own
  frame()

  -- Now tab away to the rival, which is when the search used to take over.
  attached = rival
  frame()

  local ownMoves, trailerMoves = own.moves, trailer.moves
  own.frozen, trailer.frozen = nil, nil

  handlers['RM_ApplyLayout']({
    name = 'oval', width = 40, height = 10, depth = 2,
    checkpoints = {
      { x = 0, y = 100,  z = 0, hx = 0, hy = 1 },
      { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 },
    },
    startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 } },
  })
  serverState({ phase = 'waiting', totalLaps = 10, maxResets = -1, drivers = {} })
  serverState({ phase = 'grid', totalLaps = 10, maxResets = -1, drivers = {} })
  handlers['RM_GridAssign']({ slot = 1, order = 1, count = 2 })
  frame(10)

  check(trailer.moves == trailerMoves,
    'the TRAILER is never teleported to a grid slot: it is coupled to a car '
      .. 'that is not going with it, and the coupler between them is what '
      .. 'detonates')
  check(own.moves > ownMoves, 'the car is what gets placed')
  check(own.frozen == true, 'and the car is what gets held')

  -- And the laps are read off the car, not off whichever vehicle was found.
  local before = lapsReported()
  moveTo(trailer, 95); moveTo(trailer, 105)
  coast()
  moveTo(trailer, 195); moveTo(trailer, 205)
  coast()
  check(lapsReported() == before,
    'and a trailer rolling through the gates on its own scores nothing')
end

-- ---------------------------------------------------------------------------
-- TABBING INTO YOUR OWN TRAILER IS A CAMERA MOVE, not a change of race car
-- ---------------------------------------------------------------------------
-- The camera-cycle key does not merely point at a vehicle, it puts you IN it,
-- so getPlayerVehicle answers with the trailer and every "is this ours?" test
-- says yes. That made the trailer the driver's car for every purpose, and the
-- one that did real damage was the configuration poll: a trailer is not on the
-- Garage List, so with enforcement on the server refused it and deleted it.
--
-- A vehicle being deleted takes the camera of everyone watching it, which is
-- how one racer tabbing to their own trailer moved other people's views.
do
  local TRAILER_ID = 99
  local trailer = world[TRAILER_ID]
  attached = own
  frame()

  -- Climb into the trailer.
  attached = trailer
  frame()

  -- The configuration poll is deliberately not driven here: it needs a settled
  -- read across several seconds of polls and a parts source to read, which is
  -- garage_test's subject and not this file's. What IS pinned is the thing that
  -- poll asks -- ownVehicle() -- through the two placements below, because if
  -- that answers "the trailer" then so does everything built on it, the
  -- declaration included.

  -- And the placement still goes to the car, not to the thing being looked at.
  local trailerMoves = trailer.moves
  own.frozen, trailer.frozen = nil, nil
  serverState({ phase = 'waiting', totalLaps = 10, maxResets = -1, drivers = {} })
  serverState({ phase = 'grid', totalLaps = 10, maxResets = -1, drivers = {} })
  handlers['RM_GridAssign']({ slot = 1, order = 1, count = 2 })
  frame(10)
  check(trailer.moves == trailerMoves,
    'and the grid placement still goes to the car while the driver sits in the '
      .. 'trailer looking at it')
  check(own.frozen == true, 'which is also the one that gets held')
end

-- ---------------------------------------------------------------------------
print(string.format('tabbed_camera_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
