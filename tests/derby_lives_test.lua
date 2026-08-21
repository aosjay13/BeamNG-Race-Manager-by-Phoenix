-- Headless test for DERBY LIVES on the CLIENT side
-- (lua/ge/extensions/raceManager/derby.lua).
--
-- Its own file because it is the only suite that drives the derby's local
-- policing to expiry and back again. derby_test is the server's half -- it
-- checks that a life is spent and the driver is sent back -- and it cannot see
-- this: the client is what runs the stopped and out-of-bounds timers and what
-- reports them, so a client that quietly stops policing looks, from the server,
-- exactly like a derby in which nobody has stopped moving.
--
-- WHAT WENT WRONG, reported from a live session: after losing one life a driver
-- had no idle timer and no out-of-bounds timer for the rest of the derby, and
-- the derby then ran until an admin pressed End Derby.
--
-- One cause. `out` meant two things at once -- "the server says I am not in this
-- derby" and "I have reported something, do not report it twice" -- and the
-- timer-expiry path set it. That was true while a stopped timer meant
-- elimination. Lives made it false: the server can now answer with a life and
-- put the car back, and nothing cleared the latch. A field that cannot report
-- cannot be eliminated, which is the second symptom falling out of the first.
--
-- Run from the repo root: lua5.3 tests/derby_lives_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local sent     = {}   -- ordered { event, payload } sent to the server
local handlers = {}   -- server -> client handlers the extension registered
local vehCmds  = {}   -- every queueLuaCommand, which is how a ghost is applied

local OWN_ID, RIVAL_ID = 7, 21
local OWN_PID, RIVAL_PID = 1, 2

local function makeVehicle(id)
  local v = { id = id, x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, ghosted = false }
  function v:getID() return self.id end
  function v:getPosition() return { x = self.x, y = self.y, z = self.z } end
  function v:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
  function v:getDirectionVector() return { x = 0, y = 1, z = 0 } end
  function v:getVelocity() return { x = self.vx, y = self.vy, z = self.vz } end
  function v:getJBeamFilename() return 'etk800' end
  function v:getInitialWidth() return 2.0 end
  function v:getInitialLength() return 4.5 end
  function v:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
  function v:setMeshAlpha(a) self.alpha = a end
  function v:queueLuaCommand(cmd)
    vehCmds[#vehCmds + 1] = { id = self.id, cmd = tostring(cmd) }
    if cmd == 'obj:setGhostEnabled(true)'  then self.ghosted = true  end
    if cmd == 'obj:setGhostEnabled(false)' then self.ghosted = false end
  end
  return v
end

local world = { [OWN_ID] = makeVehicle(OWN_ID), [RIVAL_ID] = makeVehicle(RIVAL_ID) }
local own, rival = world[OWN_ID], world[RIVAL_ID]
-- Parked far apart, or the weld gate in ghost.reason quite rightly refuses to
-- hand a car its collisions back and the expiry checks below never resolve.
rival.x, rival.y = 500, 500

getPlayerVehicle = function () return own end
be = { getPlayerVehicle = function () return own end, enterVehicle = function () end }
getAllVehicles = function ()
  local list = {}
  for _, v in pairs(world) do list[#list + 1] = v end
  return list
end
getObjectByID = function (id) return world[id] end
MPVehicleGE = {
  isOwn = function (id) return id == OWN_ID end,
  getVehicles = function ()
    return {
      { ownerID = OWN_PID,   gameVehicleID = OWN_ID },
      { ownerID = RIVAL_PID, gameVehicleID = RIVAL_ID },
    }
  end,
}
core_vehicles = { removeCurrent = function () return true end,
                  spawnNewVehicle = function () return nil end }
commands = { setFreeCamera = function () end, isFreeCamera = function () return false end,
             setGameCamera = function () end }
core_camera = { setByName = function () end }
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
core_vehicleBridge = { executeAction = function () end }
vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function () end }
MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return OWN_PID end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function frames(seconds, step)
  step = step or 0.1
  for _ = 1, math.floor(seconds / step + 0.5) do RM.onUpdate(step) end
end
local function countSent(event)
  local n = 0
  for _, s in ipairs(sent) do if s.event == event then n = n + 1 end end
  return n
end
-- A derby broadcast. `players` carries our own row, which is how the server
-- tells this client whether it is still in.
local function derbyState(phase, myStatus, extra)
  local t = {
    rmProtocol = 2, derbyPhase = phase, oobLimit = 5, demoLimit = 10, lives = 3,
    boundary = {}, startPositions = {},
    players = { { id = OWN_PID, name = 'Alice', status = myStatus or 'alive' } },
  }
  for k, v in pairs(extra or {}) do t[k] = v end
  handlers['RM_DerbyUpdate'](t)
end
-- The stopped timer is held off for a start grace, so getting to an expiry
-- means sitting still for the grace AND the limit.
local function sitStillUntilReported(event, budget)
  own.vx, own.vy, own.vz = 0, 0, 0
  local before = countSent(event)
  for _ = 1, math.floor((budget or 30) / 0.1) do
    RM.onUpdate(0.1)
    if countSent(event) > before then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- A derby is running and we are in it
-- ---------------------------------------------------------------------------
derbyState('running', 'alive')
check(sitStillUntilReported('RM_DerbyDemolished'),
  'a car left sitting still reports the stopped timer')
check(countSent('RM_DerbyDemolished') == 1,
  'exactly once (got ' .. countSent('RM_DerbyDemolished') .. ')')

-- ...and NOT AGAIN while the ruling is outstanding. The round trip takes time
-- and the car is still stopped throughout it; without a hold-off the same timer
-- would spend every life the driver had in the space of a second.
frames(20.0)
check(countSent('RM_DerbyDemolished') == 1,
  'and not again while waiting for the ruling (got '
    .. countSent('RM_DerbyDemolished') .. ')')

-- ---------------------------------------------------------------------------
-- THE RULING IS A LIFE: policing has to come back
-- ---------------------------------------------------------------------------
-- This is the bug. The driver is back on their slot, in the derby, with lives
-- in hand -- and before this fix their client had stopped watching for good.
handlers['RM_DerbyLifeLost']({ lives = 2, slot = 1 })
derbyState('running', 'alive')
check(sitStillUntilReported('RM_DerbyDemolished'),
  'AFTER SPENDING A LIFE the stopped timer works again -- it did not, and a '
    .. 'driver who lost one life was never counted out again')
check(countSent('RM_DerbyDemolished') == 2,
  'and reports the second one (got ' .. countSent('RM_DerbyDemolished') .. ')')

-- The derby ending for want of reports is the same fault seen from the server:
-- a field that cannot report cannot be eliminated, so nothing ever decides it.
-- Nothing to assert here that the line above does not already cover; the note
-- is here so the connection is not lost.

-- ---------------------------------------------------------------------------
-- The out-of-bounds timer comes back with it
-- ---------------------------------------------------------------------------
-- Out of bounds is an outright elimination rather than a life, but it is
-- policed by the same loop behind the same latch -- so it died the same death.
handlers['RM_DerbyLifeLost']({ lives = 1, slot = 1 })
derbyState('running', 'alive', {
  -- A boundary the car is outside of: one small square, far from the origin.
  -- Every marker carries a z, or the client drops it as malformed and the
  -- polygon never reaches the three points the check needs.
  boundary = { { x = 400, y = 400, z = 0 }, { x = 410, y = 400, z = 0 },
               { x = 410, y = 410, z = 0 }, { x = 400, y = 410, z = 0 } },
  boundaryMode = 'polygon',
})
check(sitStillUntilReported('RM_DerbyDisqualified', 20),
  'the out-of-bounds timer works after a life too -- it is policed by the same '
    .. 'loop behind the same latch, so it died the same death')

-- ---------------------------------------------------------------------------
-- THE RULING IS AN ELIMINATION: policing stops, and stays stopped
-- ---------------------------------------------------------------------------
local before = countSent('RM_DerbyDemolished')
derbyState('running', 'eliminated')
own.vx, own.vy, own.vz = 0, 0, 0
frames(30.0)
check(countSent('RM_DerbyDemolished') == before,
  'a driver the server has eliminated reports nothing further (got '
    .. (countSent('RM_DerbyDemolished') - before) .. ' more)')

-- ---------------------------------------------------------------------------
-- The broadcast can win the race with the life message
-- ---------------------------------------------------------------------------
-- The server sends RM_DerbyLifeLost and then broadcasts, and nothing guarantees
-- which lands first. If the broadcast wins, the car has not been moved yet and
-- is sitting stopped exactly where the timer expired -- so resuming without
-- re-arming the start grace would spend the next life within a frame.
derbyState('idle', 'alive')
derbyState('running', 'alive')
check(sitStillUntilReported('RM_DerbyDemolished'), 'stopped timer armed again')
local n = countSent('RM_DerbyDemolished')
derbyState('running', 'alive')      -- the ruling, arriving BEFORE the life message
frames(2.0)                          -- still stopped, still where it was
check(countSent('RM_DerbyDemolished') == n,
  'the grace is re-armed when the broadcast is what resumes policing, so the '
    .. 'next life is not spent in the same second (got '
    .. (countSent('RM_DerbyDemolished') - n) .. ' extra)')

-- ---------------------------------------------------------------------------
-- The respawn ghost reaches EVERY client
-- ---------------------------------------------------------------------------
-- The placement queue ghosts the RIVALS on the respawning driver's own machine,
-- which stops them welding into anybody. On every other machine the returning
-- car lands solid, and that is the side the weld comes from -- so the server
-- broadcasts, and each client ghosts that one car.
vehCmds = {}
handlers['RM_DerbyGhost']({ pid = RIVAL_PID, seconds = 4.0 })
check(rival.ghosted == true,
  "another driver's car is ghosted while it comes back on a life")
frames(2.0)
check(rival.ghosted == true, 'and stays ghosted for the few seconds it needs')
frames(3.0)
check(rival.ghosted == false, 'then goes solid again on its own')

-- OUR OWN CAR TOO, which is the difference between this and every other
-- field-wide ghost in the mod: those mean "everyone else is intangible" and
-- deliberately skip us. The driver coming back is the one who needs it most.
handlers['RM_DerbyGhost']({ pid = OWN_PID, seconds = 4.0 })
check(own.ghosted == true, 'our own car is ghosted when WE come back on a life')
frames(5.0)
check(own.ghosted == false, 'and comes back solid')

-- Garbage in changes nothing: the payload crosses the wire.
vehCmds = {}
handlers['RM_DerbyGhost']({})
handlers['RM_DerbyGhost']({ pid = RIVAL_PID })
handlers['RM_DerbyGhost']({ pid = 999, seconds = 4.0 })
check(#vehCmds == 0, 'a malformed respawn ghost touches nothing')

if fails == 0 then
  print(('derby_lives_test: %d checks, 0 failures'):format(checks))
else
  print(('derby_lives_test: %d FAILURES of %d checks'):format(fails, checks))
  os.exit(1)
end
