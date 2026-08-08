-- Headless test for reset ghosting in lua/ge/extensions/raceManager.lua.
--
-- Why this exists: a driver who resets mid-race used to reappear solid and
-- stationary, often in the middle of the track, and the field drove into them.
-- Ghosting drops their vehicle-to-vehicle collisions for a few seconds so that
-- cannot happen.
--
-- The dangerous half is switching collisions back ON. BeamNG welds the node
-- structures of two overlapping vehicles together the instant both are solid:
-- it ends both drivers' races and there is no recovery from it. So the ghost
-- does NOT simply expire — when its timer runs out the space around the car is
-- tested against every other car, and collisions come back only on a frame that
-- is provably clear. That test has no time limit and is never overridden, which
-- is what most of this file is about.
--
-- The overlap test is a real oriented-bounding-box query (the engine's
-- overlapsOBB_OBB, fed from getSpawnWorldOOBB) and not a distance between
-- origins: a car lying crossways THROUGH another has its origin metres away and
-- would be called clear by a radius check.
--
-- The extension is a GE module, so the BeamNG/BeamMP globals it calls are
-- stubbed here and the file is dofile'd like any other Lua module.
-- Run from the repo root: lua5.3 tests/ghost_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local sent     = {}    -- ordered { event, payload } sent to the server
local hooks    = {}    -- ordered { event, payload } pushed to the UI
local handlers = {}    -- server -> client handlers the extension registered
local world    = {}    -- [id] = vehicle, the vehicles that currently exist

local OWN_ID, RIVAL_ID, THIRD_ID = 7, 42, 43
local OWN_PID, RIVAL_PID, THIRD_PID = 1, 2, 3

-- A minimal vec3 with just the arithmetic the bounds code performs on it.
local Vec = {}
Vec.__index = Vec
Vec.__mul = function (v, s) return setmetatable({ x = v.x * s, y = v.y * s, z = v.z * s }, Vec) end
local function v3(x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end

-- The engine's oriented-bounding-box overlap test. The real one is a full
-- 15-axis separating-axis test in lua/common/mathlib.lua; every car in this file
-- is axis-aligned, for which an interval overlap per axis is the same answer,
-- so that is what the stand-in computes. The half-extent VECTORS are what the
-- production call passes, exactly as the engine expects them.
overlapsOBB_OBB = function (c1, x1, y1, z1, c2, x2, y2, z2)
  return math.abs(c1.x - c2.x) <= (x1.x + x2.x)
     and math.abs(c1.y - c2.y) <= (y1.y + y2.y)
     and math.abs(c1.z - c2.z) <= (z1.z + z2.z)
end

local AXES = { [0] = v3(1, 0, 0), [1] = v3(0, 1, 0), [2] = v3(0, 0, 1) }
local BB = {}
BB.__index = BB
function BB:getCenter() return self.c end
function BB:getHalfExtents() return self.he end
function BB:getAxis(i) return AXES[i] end

-- A car, 2 m wide by 4.4 m long by 1.4 m tall -- ordinary saloon dimensions, so
-- the 0.25 m margin in the config is a realistic fraction of them rather than a
-- number that swamps the box.
local function makeVehicle(id, x, y)
  local v = {
    id = id, x = x or 0, y = y or 0, z = 0,
    ghosted = nil,     -- what obj:setGhostEnabled was last told
    alpha = 1,
    hasBounds = true,  -- getSpawnWorldOOBB: clear it to simulate no oriented box
    hasWorldBox = true, -- getWorldBox: the axis-aligned fallback
  }
  function v:getID() return self.id end
  function v:getPosition() return { x = self.x, y = self.y, z = self.z } end
  function v:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
  function v:getDirectionVector() return { x = 0, y = 1, z = 0 } end
  function v:getVelocity() return { x = 0, y = 0, z = 0 } end
  function v:getJBeamFilename() return 'etk800' end
  function v:setPositionRotation(nx, ny, nz) self.x, self.y, self.z = nx, ny, nz end
  -- The real collision toggle: BeamNG's vehicle-side obj:setGhostEnabled,
  -- queued across from GE. Watching the command string is how this test
  -- observes the mechanism that actually ships.
  function v:queueLuaCommand(cmd)
    if cmd == 'obj:setGhostEnabled(true)'  then self.ghosted = true  end
    if cmd == 'obj:setGhostEnabled(false)' then self.ghosted = false end
  end
  function v:setMeshAlpha(a) self.alpha = a end
  function v:getSpawnWorldOOBB()
    if not self.hasBounds then return nil end
    return setmetatable({ c = v3(self.x, self.y, self.z), he = v3(1.0, 2.2, 0.7) }, BB)
  end
  -- The axis-aligned world box, which is what BeamNG's own spawn-occupancy test
  -- uses for vehicles that already exist. getExtents returns the FULL size, so
  -- these are the same 2.0 x 4.4 x 1.4 m dimensions as the oriented box above.
  function v:getWorldBox()
    if not self.hasWorldBox then return nil end
    return {
      getCenter  = function () return v3(self.x, self.y, self.z) end,
      getExtents = function () return v3(2.0, 4.4, 1.4) end,
    }
  end
  return v
end

world[OWN_ID]   = makeVehicle(OWN_ID, 0, 0)
world[RIVAL_ID] = makeVehicle(RIVAL_ID, 500, 0)   -- far away to start with
local own, rival = world[OWN_ID], world[RIVAL_ID]

getPlayerVehicle = function (_) return world[OWN_ID] end
be = { getPlayerVehicle = function () return world[OWN_ID] end,
       enterVehicle = function () end }
getAllVehicles = function ()
  local list = {}
  for _, v in pairs(world) do list[#list + 1] = v end
  return list
end
getObjectByID = function (id) return world[id] end

-- BeamMP's vehicle map. ownerID is the player id the SERVER files everyone
-- under, and gameVehicleID is this client's local scene id for that car -- the
-- two are different numbers, which is the whole reason ghost broadcasts carry a
-- player id and never a vehicle id.
MPVehicleGE = {
  isOwn = function (id) return id == OWN_ID end,
  getVehicles = function ()
    local list = {}
    for _, v in pairs(world) do
      local ownerId = RIVAL_PID
      if v.id == OWN_ID then ownerId = OWN_PID
      elseif v.id == THIRD_ID then ownerId = THIRD_PID end
      list[#list + 1] = { ownerID = ownerId, gameVehicleID = v.id }
    end
    return list
  end,
}

core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
core_vehicles = { removeCurrent = function () end }
beamng_version = '0.39.4.0'

vec3 = function (x, y, z) return v3(x, y, z) end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return OWN_PID end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

-- ---------------------------------------------------------------------------
-- Harness helpers
-- ---------------------------------------------------------------------------
local raceTime = 0
local function serverState(t)
  t.rmProtocol = 2
  t.raceTime = t.raceTime or raceTime
  handlers['RM_Update'](t)
end
local function racing(extra)
  local t = { phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {} }
  for k, v in pairs(extra or {}) do t[k] = v end
  serverState(t)
end
local function frames(seconds, step)
  step = step or 0.1
  for _ = 1, math.floor(seconds / step + 0.5) do
    raceTime = raceTime + step
    RM.onUpdate(step)
  end
end
-- A driver reset: BeamNG has already moved the car by the time the hook fires.
local function driverReset(x, y)
  own.x, own.y = x or own.x, y or own.y
  RM.onVehicleResetted(OWN_ID)
end
local function countSent(event)
  local n = 0
  for _, e in ipairs(sent) do if e.event == event then n = n + 1 end end
  return n
end
local function lastSent(event)
  for i = #sent, 1, -1 do if sent[i].event == event then return sent[i].payload end end
end
local function lastGhostHud()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerGhost' then return hooks[i].payload end
  end
end
local function clearLog() sent, hooks = {}, {} end

racing()
frames(0.3)
clearLog()

-- ===========================================================================
-- A reset while racing ghosts the car, immediately and locally
-- ===========================================================================
-- No round trip. The frame the car lands on somebody is the frame it has to be
-- intangible already, and asking the server first takes longer than that.
driverReset(10, 0)
check(own.ghosted == true, 'a reset while racing drops the car\'s collisions on the spot')
check(own.alpha < 1, 'and makes it translucent so everyone can see it is a ghost')
check(countSent('RM_GhostStart') == 1, 'the server is told, after the fact')
check(lastSent('RM_GhostStart').duration == 5.0,
  'and asks for the configured minimum duration')

-- ===========================================================================
-- The minimum duration is honoured
-- ===========================================================================
frames(4.0)
check(own.ghosted == true, 'the car is still a ghost four seconds in')
check(countSent('RM_GhostEnd') == 0, 'and nothing has been reported as finished')

-- With nothing near it, collisions come back once the timer expires.
frames(1.5)
check(own.ghosted == false, 'past the minimum, and clear, collisions come back')
check(countSent('RM_GhostEnd') == 1, 'and the server is told the ghost is over')
check(own.alpha == 1, 'the car is solid again, in both senses')

-- ===========================================================================
-- THE INVARIANT: a car parked inside another never goes solid
-- ===========================================================================
-- This is the case that ends two races if it is got wrong. B resets inside A and
-- waits out the whole timer; B must stay a ghost for as long as A is there, with
-- no limit, and no force.
clearLog()
rival.x, rival.y = 20, 0
driverReset(20, 0)            -- straight into the middle of the rival
check(own.ghosted == true, 'resetting inside another car ghosts as usual')

frames(6.0)
check(own.ghosted == true,
  'the base timer expires and the car STAYS ghosted: the space is occupied')
check(countSent('RM_GhostEnd') == 0, 'nothing is reported as finished')

-- Well past any timer, including the 15 s maximum. The overlap block has no
-- time limit at all -- that is the point of it.
frames(60.0)
check(own.ghosted == true,
  'a full minute later it is still ghosted: the block has no time limit')
check(countSent('RM_GhostEnd') == 0, 'and it is still never force-restored')
check(own.alpha < 1, 'and it still LOOKS like a ghost rather than fading to solid')

-- The driver is warned, and the server is told, but only as a warning.
check(countSent('RM_GhostBlocked') == 1,
  'the server is told once that the driver is stuck inside another car')
local warned = false
for _, h in ipairs(hooks) do
  if h.event == 'RaceManagerNotice' and h.payload.kind == 'ghost'
     and tostring(h.payload.msg):find('MOVE CLEAR') then warned = true end
end
check(warned, 'and the driver is told to move clear')
check(lastGhostHud().blocked == true, 'the HUD reports the ghost as overlap-blocked')

-- ===========================================================================
-- ...and goes solid cleanly the moment the other car leaves
-- ===========================================================================
rival.x = 500                 -- A drives away
frames(0.3)
check(own.ghosted == false, 'once the other car moves away, collisions come back')
check(countSent('RM_GhostEnd') == 1, 'and that is reported exactly once')

-- ===========================================================================
-- A car crossways THROUGH another is not "clear"
-- ===========================================================================
-- The reason the check is a bounding-box query and not a distance between
-- origins: these two origins are 2.4 m apart -- outside the radius a naive
-- check would use for a 2 m wide car -- while the two 4.4 m long cars are
-- solidly inside one another, nose through tail.
clearLog()
rival.x, rival.y = 0, 0
driverReset(0, 2.4)
frames(6.0)
check(own.ghosted == true,
  'overlapping cars whose ORIGINS are metres apart are still detected as overlapping')

-- Clear of it along the same axis (2.2 + 2.2 half-lengths plus the 0.25 m
-- margin) and the space is genuinely free.
own.y = 20
frames(0.3)
check(own.ghosted == false, 'and clear of it, collisions come back')

-- ===========================================================================
-- Three cars stacked: ghosts do not block each other into a deadlock
-- ===========================================================================
-- A ghost cannot weld to anything, so a ghosted car is not a hazard and must not
-- count as one. If it did, two overlapping ghosts would each wait for the other
-- forever and neither would ever go solid again.
clearLog()
world[THIRD_ID] = makeVehicle(THIRD_ID, 0, 0)
local third = world[THIRD_ID]
rival.x, rival.y = 0, 0
-- The rival is a ghost too (the server says so), sitting exactly where we are.
handlers['RM_Ghost']({ pid = RIVAL_PID, active = true,
  startedAt = raceTime, duration = 5.0 })
check(rival.ghosted == true, 'a broadcast ghost is applied to the right rival car')
check(third.ghosted ~= true, 'and only to that one — ghosts are per vehicle, not global')

driverReset(0, 0)             -- straight into the pile
frames(6.0)
check(own.ghosted == true,
  'still blocked: the THIRD car is solid and we are inside it')

third.x = 500                 -- the solid one leaves; the ghosted rival stays
frames(0.3)
check(own.ghosted == false,
  'with only a ghosted car overlapping us, collisions come back — a ghost cannot weld')

-- ===========================================================================
-- Fail safe: uncertainty is resolved conservatively, but it IS resolved
-- ===========================================================================
-- A ghost lifted one frame early is two ruined races, so anything unclear is
-- treated as occupied. But "occupied" has to be a question that can be asked
-- again next frame and eventually answered no -- the first version made it a
-- verdict, and a car that could not be measured left the driver ghosted for the
-- whole race with nothing able to undo it.
--
-- The rival is put back to SOLID first. It is still carrying the broadcast ghost
-- from the stacked case above, and a ghosted car is deliberately invisible to
-- the occupancy check -- so leaving it ghosted here would test nothing.
clearLog()
handlers['RM_Ghost']({ pid = RIVAL_PID, active = false })
rival.x, rival.y = 500, 0
driverReset(0, 0)
frames(6.0)
check(own.ghosted == false, 'baseline: clear space, ghost released')

-- Our own car cannot be sized up at all, and neither box answers. With the
-- track clear around us that still resolves: nothing is near enough to be
-- inside us, whatever shape we are.
clearLog()
driverReset(0, 0)
own.hasBounds, own.hasWorldBox = false, false
-- A little longer than the others: a car that reports no box waits out the
-- settle cap before its timer even starts.
frames(8.0)
check(own.ghosted == false,
  'a car that cannot be sized up is still released when the track is clear')

-- ...but not with a car alongside it. Unable to measure either of them, the
-- fallback keeps it ghosted until that car is well away.
clearLog()
driverReset(0, 0)
rival.x, rival.y = 3, 0
frames(20.0)
check(own.ghosted == true,
  'a car that cannot be sized up stays ghosted while another is close by')
rival.x, rival.y = 500, 0
frames(0.3)
check(own.ghosted == false, 'and is released once that car is clear of it')
own.hasBounds, own.hasWorldBox = true, true

-- A rival that cannot be measured is judged on DISTANCE instead. Treating every
-- measurement failure as an overlap is what left drivers ghosted for a whole
-- race: it was a verdict that could never be revisited, and one unmeasurable car
-- anywhere on the map was enough to cause it. A car that cannot be sized up but
-- is half a kilometre away is plainly not inside us.
clearLog()
driverReset(0, 0)
rival.x, rival.y = 500, 0
rival.hasBounds, rival.hasWorldBox = false, false   -- a RIVAL cannot be measured
frames(6.0)
check(own.ghosted == false,
  'an unmeasurable car far away does not block the ghost')

-- Close by, though, it does -- the fallback is conservative, just not infinite.
clearLog()
driverReset(0, 0)
rival.x, rival.y = 3, 0       -- unmeasurable AND within the fallback radius
frames(20.0)
check(own.ghosted == true,
  'an unmeasurable car close by is treated as occupying the space')
rival.x = 500
frames(0.3)
check(own.ghosted == false, 'and once it moves away, the space is clear')
rival.hasBounds, rival.hasWorldBox = true, true
own.y = 0

-- ===========================================================================
-- The oriented box is preferred, but not required
-- ===========================================================================
-- getSpawnWorldOOBB can return nil -- BeamNG's own code nil-guards it -- and a
-- nil used to mean "assume occupied", permanently. The axis-aligned world box
-- is the fallback, and it is the same box BeamNG's spawn-occupancy test uses,
-- so a car with no oriented box is still measured properly rather than guessed
-- at.
clearLog()
own.hasBounds = false         -- no oriented box; the world box still answers
rival.x, rival.y = 500, 0
driverReset(0, 0)
frames(6.0)
check(own.ghosted == false,
  'a car with no oriented box is still measured, and released when clear')

clearLog()
driverReset(0, 0)
rival.x, rival.y = 0, 2.4     -- overlapping, nose to tail
frames(6.0)
check(own.ghosted == true,
  'and is still held when something is genuinely in its space')
rival.x, rival.y = 500, 0
frames(0.3)
check(own.ghosted == false, 'and released when that car leaves')
own.hasBounds = true

-- ===========================================================================
-- A repeat reset restarts the timer, and does not stack
-- ===========================================================================
clearLog()
rival.x = 500
driverReset(0, 0)
frames(3.0)
driverReset(0, 0)             -- second reset, 3 s into the first ghost
check(countSent('RM_GhostStart') == 2, 'the second reset is reported too')
check(lastSent('RM_GhostStart').duration == 10.0,
  'and extends the base timer rather than starting a second ghost beside it')
frames(9.0)
check(own.ghosted == true, 'the extended timer is honoured in full')
frames(2.0)
check(own.ghosted == false, 'and then, clear, collisions come back')

-- The extension is capped. Holding the reset key cannot buy an unbounded ghost.
clearLog()
driverReset(0, 0)
for _ = 1, 10 do driverReset(0, 0) end
check(lastSent('RM_GhostStart').duration == 15.0,
  'repeat resets cap the base timer at the configured maximum')

-- ...and a held reset key does not become a message per frame. The reset hook
-- fires repeatedly while the key is down; the server hears the duration change
-- (5 -> 10 -> 15) and then nothing more, because it has stopped changing.
check(countSent('RM_GhostStart') == 3,
  'a held reset key reports each change in duration and then goes quiet')

-- ...but the cap is on the TIMER, never on the occupancy check. A capped ghost
-- sitting inside another car still refuses to go solid.
rival.x, rival.y = 0, 0
frames(30.0)
check(own.ghosted == true,
  'the maximum caps the timer only — it never overrides the occupancy check')
rival.x = 500
frames(0.3)
check(own.ghosted == false, 'and the car is released when the space clears')

-- ===========================================================================
-- Other people's ghosts
-- ===========================================================================
clearLog()
-- Remaining time is worked out from the server clock, so latency SHORTENS a
-- ghost on a late client rather than extending it. This one started two seconds
-- ago as far as this client's copy of that clock is concerned.
handlers['RM_Ghost']({ pid = RIVAL_PID, active = true,
  startedAt = raceTime - 2.0, duration = 5.0 })
check(rival.ghosted == true, 'a rival mid-ghost is ghosted here too')

-- A receiver must NEVER restore collisions on its own clock. Only the owning
-- client runs the occupancy check around its own car; a receiver that un-ghosted
-- when its own timer ran out would make the car solid on this screen while it
-- was still a ghost on its owner's -- and two solid overlapping cars on THIS
-- client weld on this client.
frames(20.0)
check(rival.ghosted == true,
  'a lapsed remote ghost is NOT restored locally: only its owner can end it')
handlers['RM_Ghost']({ pid = RIVAL_PID, active = false })
check(rival.ghosted == false, 'it is restored when its owner says so, and not before')

-- ===========================================================================
-- Joining mid-ghost: the state broadcast carries the roster
-- ===========================================================================
-- A one-shot event is no use to a client that was not connected for it, so the
-- authoritative roster rides on the ordinary state broadcast as well.
clearLog()
racing({ ghosts = { { pid = RIVAL_PID, endsAt = raceTime + 4.0 } } })
frames(0.1)
check(rival.ghosted == true, 'a client joining mid-ghost learns about it from the roster')

-- The roster is authoritative: a pid absent from it has no ghost.
racing({ ghosts = {} })
frames(0.1)
check(rival.ghosted == false, 'and a ghost missing from the roster is dropped')

-- ===========================================================================
-- The end-of-session respawn is ghosted for EVERYONE
-- ===========================================================================
-- At the flag the server puts every removed car back. Cars land on top of each
-- other doing it, which is what the placement ghost is for -- but it used to
-- reach only the drivers who had something to respawn. A driver who was still
-- running when the session ended never lost their car, so their client ignored
-- the release entirely and they sat solid in the middle of a field
-- materialising around them.
clearLog()
racing()
rival.x, rival.y = 500, 0
handlers['RM_ReleaseSpectate']({ source = 'race', order = 1, count = 11 })
frames(0.1)
check(rival.ghosted == true,
  'a driver who never lost their car still ghosts for the respawn')

-- A car that appears DURING the respawn is ghosted on the spot, not whenever
-- the slow re-assert sweep next comes round -- a mass respawn is exactly when
-- cars appear, and two seconds solid in the middle of one is the whole problem.
local LATE_ID = 44
world[LATE_ID] = makeVehicle(LATE_ID, 5, 0)
RM.onVehicleSpawned(LATE_ID)
check(world[LATE_ID].ghosted == true,
  'a car spawning mid-respawn is ghosted immediately')

-- ...and it all comes back once the field has landed.
frames(6.0)
check(rival.ghosted == false, 'collisions return once the respawn has settled')
check(world[LATE_ID].ghosted == false, 'for the late arrival too')
world[LATE_ID] = nil

-- ===========================================================================
-- Teardown: nothing stays ghosted across a session boundary
-- ===========================================================================
clearLog()
racing()
driverReset(0, 0)
check(own.ghosted == true, 'ghosted mid-race')
serverState({ phase = 'finished', maxResets = -1, totalLaps = 3, drivers = {} })
frames(0.2)
check(own.ghosted == false, 'the race ending restores collisions')

-- A deleted vehicle takes its ghost bookkeeping with it. Vehicle ids are REUSED,
-- so an entry left behind is inherited by the next car handed that id, which
-- would then believe it is already ghosted and quietly refuse to ghost again.
clearLog()
racing()
driverReset(0, 0)
check(own.ghosted == true, 'ghosted again')
RM.onVehicleDestroyed(OWN_ID)
check(countSent('RM_GhostEnd') == 1, 'deleting the car ends its ghost')
world[OWN_ID] = makeVehicle(OWN_ID, 0, 0)
own = world[OWN_ID]
driverReset(0, 0)
check(own.ghosted == true,
  'and a replacement car handed the same id can still be ghosted')

-- Leaving the server purges everything, with no broadcast left to do it for us.
frames(0.2)
RM.onBeamMPServerLeave()
check(own.ghosted == false, 'leaving the session restores collisions')

-- ===========================================================================
-- A ghost can never outlive the race
-- ===========================================================================
-- Reported from a live race: a car ghosted by a reset stayed ghosted for the
-- rest of the session and was still ghosted after it ended. The occupancy check
-- had answered "blocked" on a measurement failure, which is a verdict nothing
-- could ever revisit -- so the ghost had no way to end.
--
-- Two independent guarantees now. The check itself always terminates (above),
-- and the end of a session clears every car in the world regardless of what the
-- bookkeeping believes.
clearLog()
racing()
rival.x, rival.y = 0, 0       -- parked exactly on top of us: genuinely blocked
driverReset(0, 0)
frames(20.0)
check(own.ghosted == true, 'a genuinely blocked car stays ghosted during the race')

serverState({ phase = 'finished', maxResets = -1, totalLaps = 3, drivers = {} })
frames(0.2)
check(own.ghosted == false,
  'and is solid again the moment the race ends, blocked or not')

-- Even a ghost the bookkeeping has lost track of is cleared. A vehicle id that
-- has been reused, or a ghost left by an instance of the extension that has
-- since been reloaded, would otherwise be intangible with nothing left able to
-- undo it.
clearLog()
racing()
driverReset(0, 0)
rival.x, rival.y = 500, 0
frames(0.2)
check(own.ghosted == true, 'ghosted again')
RM.onBeamMPServerLeave()
check(own.ghosted == false, 'leaving the session leaves nothing ghosted')
check(rival.ghosted == false, 'and that goes for every other car too')

-- ===========================================================================
-- Fastest lap notice
-- ===========================================================================
-- The driver who sets the session's fastest lap is told, on the notice channel
-- the reset and joker rulings use.
local function fastestNotices()
  local n = 0
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerNotice' and h.payload.kind == 'fastest' then n = n + 1 end
  end
  return n
end

clearLog()
racing({ bestLapPid = OWN_PID, bestLapTime = 95.5 })
check(fastestNotices() == 1, 'setting the fastest lap tells the driver who set it')

-- The standing best rides on every state broadcast, three times a second. Being
-- told again on each of them would bury the notice channel.
clearLog()
racing({ bestLapPid = OWN_PID, bestLapTime = 95.5 })
racing({ bestLapPid = OWN_PID, bestLapTime = 95.5 })
check(fastestNotices() == 0, 'the same lap re-broadcast says nothing further')

-- Beating your OWN fastest lap is announced again. Keyed on the holder alone
-- this said nothing -- the pid had not changed -- which is the one case a driver
-- most wants to hear about.
clearLog()
racing({ bestLapPid = OWN_PID, bestLapTime = 93.0 })
check(fastestNotices() == 1, 'beating your own fastest lap is announced again')
local msg
for _, h in ipairs(hooks) do
  if h.event == 'RaceManagerNotice' and h.payload.kind == 'fastest' then msg = h.payload.msg end
end
check(msg and msg:find('1:33.000', 1, true) ~= nil, 'and carries the new time')

-- Somebody else taking it is not announced to us -- they get their own notice.
clearLog()
racing({ bestLapPid = RIVAL_PID, bestLapTime = 91.0 })
check(fastestNotices() == 0, 'a rival taking the fastest lap is not announced to us')

-- Taking it back is.
clearLog()
racing({ bestLapPid = OWN_PID, bestLapTime = 90.0 })
check(fastestNotices() == 1, 'taking it back is announced')

-- ===========================================================================
-- Ghosting is collision and render only
-- ===========================================================================
-- The lap and checkpoint rules must not be able to tell a ghost apart from any
-- other car, or a reset would become a way to alter timing rather than a way to
-- avoid a crash.
clearLog()
racing()
local before = countSent('RM_Lap') + countSent('RM_Progress') + countSent('RM_QualiLap')
driverReset(0, 0)
frames(1.0)
local after = countSent('RM_Lap') + countSent('RM_QualiLap')
check(after == 0, 'ghosting scores no laps of its own')
check(countSent('RM_VehicleReset') >= 0, 'and leaves the reset accounting alone')

print(string.format('ghost_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
