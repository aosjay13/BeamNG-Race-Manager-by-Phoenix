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
-- does NOT simply expire - when its timer runs out the space around the car is
-- tested against every other car, and collisions come back only on a frame that
-- is provably clear. That test has no time limit and is never overridden, which
-- is what most of this file is about.
--
-- The overlap test is a real oriented-bounding-box query (the engine's
-- overlapsOBB_OBB, fed from getSpawnWorldOOBB) and not a distance between
-- origins: a car lying crossways THROUGH another has its origin meters away and
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
-- The trailer's own ids. It is a separate VEHICLE as far as BeamNG and BeamMP
-- are concerned, so it is filed under a player like any other -- and it needs a
-- player of its own here, because the map below files anything it does not
-- recognise under the rival. See the note on getVehicles.
local TRAILER_ID, TRAILER_PID = 77, 4
-- A car that turns up mid-respawn, further down. Declared with the rest so the
-- owner map below is complete rather than half of it living at the use site.
local LATE_ID, LATE_PID = 44, 5

-- A minimal vec3 with just the arithmetic the bounds code performs on it.
local Vec = {}
Vec.__index = Vec
Vec.__mul = function (v, s) return setmetatable({ x = v.x * s, y = v.y * s, z = v.z * s }, Vec) end
Vec.__add = function (a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, Vec) end
-- The dimension-based bounds build their axes with a cross product, the way the
-- engine's vec3 does.
function Vec:cross(o)
  return setmetatable({
    x = self.y * o.z - self.z * o.y,
    y = self.z * o.x - self.x * o.z,
    z = self.x * o.y - self.y * o.x,
  }, Vec)
end
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
  function v:getDirectionVector() return v3(0, 1, 0) end
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
  -- The third measurement source: the car's own dimensions. A vehicle knows how
  -- big it is even when neither bounding box will say where it is.
  v.hasDims = true
  function v:getDirectionVectorUp() return v3(0, 0, 1) end
  function v:getInitialLength() if not self.hasDims then return nil end return 4.4 end
  function v:getInitialWidth()  if not self.hasDims then return nil end return 2.0 end
  function v:getInitialHeight() if not self.hasDims then return nil end return 1.4 end
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
--
-- EVERY VEHICLE NEEDS ITS OWN OWNER HERE, and the fallback below is why. This
-- map used to file anything it did not recognise under the rival, which was
-- harmless right up until the trailer was added to `world`: from then on TWO
-- vehicles answered to RIVAL_PID, ghost.vehicleForPid returned whichever
-- `pairs` reached first, and a rival's reset ghost landed on the trailer. The
-- three trailer checks at the bottom of this file have been failing on it ever
-- since -- reading as the rig ghost being broken when it works perfectly.
--
-- So the mapping is a table, and an unmapped vehicle is nobody's rather than
-- silently the rival's. Add a vehicle to `world` and you add it here.
local VEHICLE_OWNER = {
  [OWN_ID]     = OWN_PID,
  [RIVAL_ID]   = RIVAL_PID,
  [THIRD_ID]   = THIRD_PID,
  [TRAILER_ID] = TRAILER_PID,
  [LATE_ID]    = LATE_PID,
}
MPVehicleGE = {
  isOwn = function (id) return id == OWN_ID end,
  getVehicles = function ()
    local list = {}
    for _, v in pairs(world) do
      -- nil ownerID for an unmapped vehicle: it belongs to no player, which is
      -- what a scene object nobody has claimed actually is. vehicleForPid
      -- compares with tostring(), so nil simply never matches a real pid.
      list[#list + 1] = { ownerID = VEHICLE_OWNER[v.id], gameVehicleID = v.id }
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

-- The extension `require`s its modules (raceManager/derby, and more to come),
-- so the headless harness has to be able to find them the way the game can.
-- One line, and it is what makes a split file testable at all.
package.path = 'lua/ge/extensions/?.lua;' .. package.path
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
-- The minimum duration is honored
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
  'overlapping cars whose ORIGINS are meters apart are still detected as overlapping')

-- Clear of it along the same axis (2.2 + 2.2 half-lengths plus the 0.25 m
-- margin) and the space is genuinely free.
own.y = 20
frames(0.3)
check(own.ghosted == false, 'and clear of it, collisions come back')

-- ===========================================================================
-- Three cars stacked: ghosts do not block each other into a deadlock
-- ===========================================================================
-- A car inside us blocks the restore whether or not it is itself a ghost
-- ===========================================================================
-- This used to go the other way: a ghosted car was deliberately invisible to
-- the occupancy check, on the reasoning that a ghost cannot weld.
--
-- The other car's ghost is not ours to rely on. It ends on its own clock,
-- decided by its own client, and the instant it does there are two solid bodies
-- in the same space. It also made the rule useless exactly where it is needed
-- most: after a race the whole field is respawned at once, so every car is a
-- ghost, so every car looked clear to every other one.
--
-- The worry it was written for -- two overlapping ghosts each waiting for the
-- other forever -- does not survive contact with what a ghost is: being
-- intangible is precisely what lets them drive out of each other.
clearLog()
world[THIRD_ID] = makeVehicle(THIRD_ID, 0, 0)
local third = world[THIRD_ID]
rival.x, rival.y = 0, 0
-- The rival is a ghost too (the server says so), sitting exactly where we are.
handlers['RM_Ghost']({ pid = RIVAL_PID, active = true,
  startedAt = raceTime, duration = 5.0 })
check(rival.ghosted == true, 'a broadcast ghost is applied to the right rival car')
check(third.ghosted ~= true, 'and only to that one - ghosts are per vehicle, not global')

driverReset(0, 0)             -- straight into the pile
frames(6.0)
check(own.ghosted == true,
  'still blocked: the THIRD car is solid and we are inside it')

third.x = 500                 -- the solid one leaves; the ghosted rival stays
frames(0.5)
check(own.ghosted == true,
  'a ghosted car still inside us keeps us ghosted - its ghost is not ours to '
    .. 'rely on, and it can end at any moment')

rival.x, rival.y = 500, 0     -- it drives clear, which a ghost can always do
frames(0.5)
check(own.ghosted == false, 'and collisions come back the moment it is out')

-- ===========================================================================
-- Fail safe: uncertainty is resolved conservatively, but it IS resolved
-- ===========================================================================
-- A ghost lifted one frame early is two ruined races, so anything unclear is
-- treated as occupied. But "occupied" has to be a question that can be asked
-- again next frame and eventually answered no -- the first version made it a
-- verdict, and a car that could not be measured left the driver ghosted for the
-- whole race with nothing able to undo it.
--
-- The rival is put back to solid and moved away, so this case starts from a
-- genuinely clear space rather than the pile the case above left behind.
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
own.hasBounds, own.hasWorldBox, own.hasDims = false, false, false
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
own.hasBounds, own.hasWorldBox, own.hasDims = true, true, true

-- A rival that cannot be measured is judged on DISTANCE instead. Treating every
-- measurement failure as an overlap is what left drivers ghosted for a whole
-- race: it was a verdict that could never be revisited, and one unmeasurable car
-- anywhere on the map was enough to cause it. A car that cannot be sized up but
-- is half a kilometer away is plainly not inside us.
clearLog()
driverReset(0, 0)
rival.x, rival.y = 500, 0
-- A rival that no source can size up at all.
rival.hasBounds, rival.hasWorldBox, rival.hasDims = false, false, false
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
rival.hasBounds, rival.hasWorldBox, rival.hasDims = true, true, true
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
-- When neither bounding box answers, the car is still measured properly
-- ===========================================================================
-- This is the difference between a ghost that ends and one that lasts a race.
-- Below the bounding boxes there is only a flat radius wide enough to contain
-- the largest vehicle pair -- and in a full field somebody is nearly always
-- inside that, so a ghost that fell through to it would hold for most of the
-- race. The car's own dimensions keep the answer the size of a car.
clearLog()
own.hasBounds, own.hasWorldBox = false, false      -- no boxes, dimensions only
rival.hasBounds, rival.hasWorldBox = false, false
rival.x, rival.y = 4.0, 0                          -- clear of us, but well inside
driverReset(0, 0)                                  -- any blunt radius
frames(8.0)
check(own.ghosted == false,
  'a car four meters away does not block a ghost when dimensions can be read')

-- ...and a car genuinely overlapping still does.
clearLog()
rival.x, rival.y = 0, 2.0
driverReset(0, 0)
frames(8.0)
check(own.ghosted == true, 'a car actually overlapping still blocks it')
rival.x, rival.y = 500, 0
frames(0.3)
check(own.ghosted == false, 'and releases when it moves off')
own.hasBounds, own.hasWorldBox = true, true
rival.hasBounds, rival.hasWorldBox = true, true

-- ===========================================================================
-- A repeat reset restarts the timer, and does not stack
-- ===========================================================================
clearLog()
rival.x = 500
driverReset(0, 0)
frames(3.0)
driverReset(0, 0)             -- second reset, 3 s into the first ghost
check(countSent('RM_GhostStart') == 2, 'the second reset is reported too')

-- RESTARTS AT THE BASE. It used to ADD minSec to the previous total each time,
-- capped at maxSec, which is what this file's own heading always said it did not
-- do. Reported live as the ghost time stacking: two resets in traffic and a
-- driver stayed intangible for fifteen seconds.
--
-- Restarting is also the safer reading. A ghost exists for the moment of
-- materialising in the pack, and a second reset is a second such moment rather
-- than a longer one. Anyone genuinely stuck inside another car is held by the
-- occupancy check below, which has no time limit and is what actually decides
-- when collision returns.
check(lastSent('RM_GhostStart').duration == 5.0,
  'and RESTARTS the base timer rather than adding to it')
frames(4.0)
check(own.ghosted == true, 'the restarted timer runs from the second reset')
frames(2.0)
check(own.ghosted == false, 'and then, clear, collisions come back')

-- Holding the reset key cannot buy a longer ghost, because there is nothing to
-- accumulate any more.
clearLog()
driverReset(0, 0)
for _ = 1, 10 do driverReset(0, 0) end
check(lastSent('RM_GhostStart').duration == 5.0,
  'ten more resets still ask for the base duration, never a longer one')

-- ...and a held reset key does not become a message per frame. The duration
-- never changes now, so the throttle is the only thing keeping it quiet: one
-- message, then silence until the half-second staleness window reopens.
check(countSent('RM_GhostStart') <= 2,
  'a held reset key does not turn into a message per frame')

-- The timer is not the occupancy check. A car sitting inside another still
-- refuses to go solid however short its timer was.
rival.x, rival.y = 0, 0
frames(30.0)
check(own.ghosted == true,
  'the maximum caps the timer only - it never overrides the occupancy check')
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
-- ...and the owner saying so is still not enough on its own. If the car is
-- inside OURS in this world, making it solid here welds it here -- which is the
-- very thing the paragraph above is about, applied to the other direction.
rival.x, rival.y = 0, 0
handlers['RM_Ghost']({ pid = RIVAL_PID, active = false })
frames(0.3)
check(rival.ghosted == true,
  'its owner says clear, but it is inside our car HERE, so it stays a ghost here')
rival.x, rival.y = 700, 0     -- its own patch of ground: `third` is parked at 500
frames(0.3)
check(rival.ghosted == false, 'it is restored once it is out, and not before')

-- ===========================================================================
-- Joining mid-ghost: the state broadcast carries the roster
-- ===========================================================================
-- A one-shot event is no use to a client that was not connected for it, so the
-- authoritative roster rides on the ordinary state broadcast as well.
clearLog()
racing({ ghosts = { { pid = RIVAL_PID, endsAt = raceTime + 4.0 } } })
frames(0.1)
check(rival.ghosted == true, 'a client joining mid-ghost learns about it from the roster')

-- The roster is authoritative: a pid absent from it has no ghost. Tested with
-- the car well clear of ours, so what is being measured is the roster and not
-- the "nothing goes solid with a car inside it" gate.
rival.x, rival.y = 700, 0
racing({ ghosts = {} })
frames(0.3)
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
world[LATE_ID] = makeVehicle(LATE_ID, 5, 0)
RM.onVehicleSpawned(LATE_ID)
check(world[LATE_ID].ghosted == true,
  'a car spawning mid-respawn is ghosted immediately')

-- ...and it all comes back once the field has landed AND the cars are off each
-- other. Landing is the placement's business; being clear is the gate every
-- ghost passes through, so the field is spread out here the way a grid is.
rival.x, rival.y = 700, 0
world[LATE_ID].x, world[LATE_ID].y = 900, 0
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

-- The end of the race does NOT hand a blocked car its collisions back. Nothing
-- does: a car with another car inside it stays intangible until that stops
-- being true, whatever else has happened. The race ending is not a reason to
-- weld two cars together, and the respawn that follows would ghost them again
-- anyway.
serverState({ phase = 'finished', maxResets = -1, totalLaps = 3, drivers = {} })
frames(0.5)
check(own.ghosted == true,
  'a car with another inside it is still a ghost after the race ends')

rival.x, rival.y = 500, 0     -- the other car moves off
frames(0.5)
check(own.ghosted == false, 'and goes solid as soon as the space is clear')

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
-- The time moved to the notice's SECOND line when fastest lap became a
-- full-panel flash: the headline is what gets read at speed, so it is the words
-- rather than the number. Both halves are asserted, because a flash that says
-- FASTEST LAP over an empty sub-line is the half of this worth catching.
local msg, sub
for _, h in ipairs(hooks) do
  if h.event == 'RaceManagerNotice' and h.payload.kind == 'fastest' then
    msg, sub = h.payload.msg, h.payload.sub
  end
end
check(msg == 'FASTEST LAP', 'and the headline is the flag itself')
check(sub and sub:find('1:33.000', 1, true) ~= nil, 'and carries the new time')

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

-- ===========================================================================
-- A field-wide reason must come OFF the car it went ON
-- ===========================================================================
-- The field reasons ('placement' during a mass respawn, 'quali') ghost every
-- car EXCEPT our own -- that is what "rivals are ghosts" means. Our own car is
-- identified by asking BeamMP who owns it, and there is a window where that
-- question has no answer: the car exists, its ownership has not resolved yet.
-- A respawn opens that window, and the two-second re-assert sweep fires inside
-- it, so the reason lands on our own car.
--
-- Applying the reason skips our car when it can be named; LIFTING it must skip
-- nothing, or a reason that reached our own car during that window stays on it
-- forever. Nothing can clear it afterwards: a reset ghost layered on top comes
-- and goes, and the car underneath is still held -- which is a car that flashes
-- solid as its reset timer ends and returns to being a ghost for the rest of
-- the race.
clearLog()
racing()
-- Let any ghost still running from the case above expire, so this one starts
-- from a car that is genuinely solid.
frames(12.0)
check(world[OWN_ID].ghosted ~= true, 'starting from a solid car')

-- The window: our car exists but nobody can say it is ours.
local realizOwn = MPVehicleGE.isOwn
MPVehicleGE.isOwn = function () return false end
RM.setGhostQuali(true)                      -- any field-wide reason will do
serverState({ phase = 'qualifying', ghostQuali = true, maxResets = -1,
              totalLaps = 3, drivers = {} })
frames(0.5)
MPVehicleGE.isOwn = realizOwn               -- ownership resolves again

-- Lift it. Our own car must not be left holding the reason.
serverState({ phase = 'racing', ghostQuali = false, maxResets = -1,
              totalLaps = 3, drivers = {} })
frames(0.5)
check(world[OWN_ID].ghosted ~= true,
  'a field reason applied to our own car while its ownership was unresolved is '
    .. 'lifted again -- otherwise the car is ghosted for the rest of the race '
    .. 'and no reset ghost can clear it')

-- And the ordinary case still works: a reset ghost on top comes and goes.
clearLog()
driverReset(0, 0)
frames(0.3)
check(world[OWN_ID].ghosted == true, 'a reset still ghosts our own car')
frames(9.0)
check(world[OWN_ID].ghosted ~= true, 'and still restores contact when it ends')

-- ===========================================================================
-- THE rule: nothing goes solid with a car inside it, whatever ghosted it
-- ===========================================================================
-- Every ghost -- the driver's own reset ghost, a pit stop, and the field-wide
-- ones that ghost rivals through a mass respawn or ghost qualifying -- comes
-- back through one gate, and the gate asks one question.
clearLog()
racing()
frames(12.0)                       -- start from a settled, solid car
own.x, own.y = 0, 0
rival.x, rival.y = 700, 0
world[THIRD_ID].x, world[THIRD_ID].y = 900, 0
frames(0.5)
check(own.ghosted ~= true and rival.ghosted ~= true, 'everything solid to begin with')

-- A field-wide reason, lifted while a rival is sitting inside our car.
serverState({ phase = 'qualifying', ghostQuali = true, maxResets = -1,
              totalLaps = 3, drivers = {} })
frames(0.3)
check(rival.ghosted == true, 'ghost qualifying ghosts the rival')
rival.x, rival.y = 0, 0            -- it parks inside us
serverState({ phase = 'racing', ghostQuali = false, maxResets = -1,
              totalLaps = 3, drivers = {} })
frames(0.5)
check(rival.ghosted == true,
  'the reason is gone but the car is inside ours, so it stays intangible')
rival.x, rival.y = 700, 0          -- and drives out
frames(0.5)
check(rival.ghosted == false, 'and goes solid the moment it is clear')

-- The same rule, on our own car, through the reset ghost.
rival.x, rival.y = 0, 0
driverReset(0, 0)
frames(12.0)
check(own.ghosted == true, 'our own reset ghost waits on the same question')
rival.x, rival.y = 700, 0
frames(0.5)
check(own.ghosted == false, 'and answers it the same way')

-- ===========================================================================
-- THE FINISHED GHOST: taking the flag, in the car you finished in
-- ===========================================================================
-- Finishing used to delete the car and respawn it at the end of the race. It now
-- ghosts it in place, which is a state change instead of two entity events per
-- driver at the exact moment a whole field is coming home.
--
-- Its shape is different from every other reason in the file, and each of those
-- differences is asserted below.
-- A clean baseline first. The sections above leave ghosts of their own behind,
-- and a finished-ghost assertion that passes because a quali ghost was still on
-- would be worse than no assertion at all.
rival.x, rival.y = 700, 0
third.x, third.y = 800, 0
own.x, own.y = 0, 0
serverState({ phase = 'waiting', ghostQuali = false, maxResets = -1, totalLaps = 3,
  drivers = {}, ghosts = {}, ghostFinished = {} })
handlers['RM_ReleaseSpectate']({ source = 'race' })
frames(3.0)
serverState({ phase = 'racing', ghostQuali = false, maxResets = -1, totalLaps = 3,
  drivers = {}, ghosts = {}, ghostFinished = {} })
frames(1.0)
own.alpha = 1
check(own.ghosted ~= true and rival.ghosted ~= true,
  'everything solid before the finished-ghost cases begin')

handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race', place = 1 })
frames(0.2)

-- 1. COLLISION GOES OFF ON OUR OWN CLIENT TOO, which no other reason does.
--    In BeamMP our car is simulated HERE, so leaving it collidable locally would
--    let our own sim bounce us off a racer whose sim felt nothing -- and our
--    position is what gets synced, so that phantom shove would travel. The race
--    is only provably unaffected if the collision is off on this side as well.
check(own.ghosted == true, 'a finisher s own car has its collisions dropped locally')

-- 2. AND IT IS NOT FADED FOR US. Collision and alpha are separate calls and only
--    one of them is the driver's business: their view of their own car does not
--    change at all.
check(own.alpha == 1, 'but it is NOT faded for its own driver: their view is unchanged')

-- 3. NOTHING WAS CREATED OR DESTROYED. The acceptance criterion, asserted at the
--    only moment it can be violated.
check(world[OWN_ID] ~= nil, 'and the car still exists: nothing was despawned')

-- 4. A STILL-RACING CAR CANNOT REACH IT. Driving a racer straight through the
--    ghosted car changes nothing about either of them: the ghost stays a ghost,
--    and the racer is never handed a collision to resolve.
rival.x, rival.y = 0, 0            -- driven directly into the finished car
frames(1.0)
check(own.ghosted == true,
  'a racer driven straight into a finished car does not make it solid again')
check(rival.ghosted ~= true,
  'and the racer is untouched: no ghost is imposed on a car still in the race')

-- 5. THE FLAG HANDS IT BACK. Once the race concludes the reason comes off and
--    the car is solid again, in both senses.
rival.x, rival.y = 700, 0
serverState({ phase = 'finished', maxResets = -1, totalLaps = 3, drivers = {} })
handlers['RM_ReleaseSpectate']({ source = 'race' })
frames(1.0)
check(own.ghosted == false, 'the flag hands the collisions back')
check(own.alpha == 1, 'and the car is solid in both senses')

-- 6. RESETTING WHILE GHOSTED KEEPS THE GHOST. A finished driver whose car lands
--    in the water can recover it, and must not come back solid in the middle of
--    a race still running. The reset reloads the vehicle Lua VM, which is where
--    setGhostEnabled lives, so the toggle has to be re-applied to the car that
--    came back.
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {} })
handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race', place = 2 })
frames(0.2)
check(own.ghosted == true, 'ghosted on finishing')
own.ghosted = false                 -- what a reset does to the vehicle VM
RM.onVehicleResetted(OWN_ID)
frames(0.5)
check(own.ghosted == true, 'and still ghosted after a reset put the car back solid')
check(own.alpha == 1, 'still unfaded for its own driver')

-- 7. GHOST-TO-GHOST IS PASS-THROUGH, and it is free: setGhostEnabled is per
--    vehicle, so two finished cars are both intangible and neither can shunt the
--    other into the racing line.
handlers['RM_Update']({
  rmProtocol = 2, phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
  ghostFinished = { RIVAL_PID },
})
frames(0.5)
check(rival.ghosted == true, 'another finished driver is ghosted from the roster')
rival.x, rival.y = 0, 0             -- parked inside our own finished car
frames(1.0)
check(own.ghosted == true and rival.ghosted == true,
  'two finished cars pass through each other rather than colliding')

-- 8. A DISCONNECT WHILE GHOSTED LEAVES NOTHING BEHIND. The roster is
--    authoritative, so a pid that stops appearing in it has its ghost dropped --
--    which is what stops a departed driver leaving a permanently intangible car.
rival.x, rival.y = 700, 0
handlers['RM_Update']({
  rmProtocol = 2, phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
  ghostFinished = {},
})
frames(1.0)
check(rival.ghosted == false,
  'a pid dropping out of the roster drops its ghost with it')

serverState({ phase = 'finished', maxResets = -1, totalLaps = 3, drivers = {} })
handlers['RM_ReleaseSpectate']({ source = 'race' })
frames(1.0)

-- ===========================================================================
-- ORDINAL SUFFIXES on the placement message
-- ===========================================================================
-- 1st, 2nd, 3rd, 4th. The teens are the trap: 11th, 12th and 13th take "th"
-- while 21st, 22nd and 23rd do not, so this cannot be a lookup on the last digit.
do
  local ord = RM.ordinalForTest
  check(type(ord) == 'function', 'the ordinal formatter is reachable for testing')
  if type(ord) == 'function' then
    local cases = {
      [1] = '1st',  [2] = '2nd',  [3] = '3rd',  [4] = '4th',
      [11] = '11th', [12] = '12th', [13] = '13th', [14] = '14th',
      [21] = '21st', [22] = '22nd', [23] = '23rd', [24] = '24th',
      [101] = '101st', [111] = '111th', [112] = '112th', [113] = '113th',
    }
    local keys = {}
    for k in pairs(cases) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, n in ipairs(keys) do
      check(ord(n) == cases[n],
        'ordinal ' .. n .. ' is ' .. cases[n] .. ' (got ' .. tostring(ord(n)) .. ')')
    end
  end
end


-- ===========================================================================
-- A COUPLED TRAILER IS NOT A RIVAL
-- ===========================================================================
-- BeamNG treats a trailer as a second vehicle, and this mod used to agree --
-- which broke ghosting twice over.
--
-- It ghosted the trailer as though it belonged to somebody else, so a driver
-- towed a translucent trailer for the whole race. And it counted the trailer as
-- occupying the car's space, which is permanently true of something bolted to
-- the tow hitch -- so NEITHER could ever go solid again. Reported from a
-- session as "they stayed ghosted together after the race": everybody is
-- respawned and ghosted at the flag, and this pair had no way back.
--
-- core_vehicles.attachedCouplers is the engine's live list of coupled pairs.
world[TRAILER_ID] = makeVehicle(TRAILER_ID, 0, 0)
local trailer = world[TRAILER_ID]
core_vehicles = { attachedCouplers = { { OWN_ID, TRAILER_ID, 12, 34 } } }

-- Park the trailer right where a trailer is: inside our own bounding box.
own.x, own.y = 0, 0
trailer.x, trailer.y = 0, 2.0
-- EVERY other car well clear, not just the rival. A third car is still parked
-- where an earlier case left it, and one forgotten vehicle inside our box makes
-- this read as the trailer skip failing when it is working perfectly.
rival.x, rival.y = 500, 500
third.x, third.y = 600, 600

-- A field-wide ghost (a respawn, a grid forming) must skip our whole rig, not
-- just our car.
racing()
clearLog()
own.ghosted, trailer.ghosted = nil, nil
serverState({ phase = 'racing', ghosts = {}, ghostFinished = {},
              ghostOnReset = true, ghostMinSec = 1, ghostMaxSec = 15,
              drivers = {} })
handlers['RM_GridAssign']({ slot = 1, order = 1, count = 1 })
frames(0.3)
check(trailer.ghosted ~= true,
  'a field ghost skips the trailer on our own tow hitch, not just the car')

-- LET THE FIELD OPERATION FINISH. It runs for FIELD.SETTLE seconds after the
-- last car lands, and leaving one in flight means the next case resets in the
-- middle of a placement -- which looks exactly like the ghost failing to lift.
frames(6.0)

-- ...and the pair can go SOLID again, which is the half that stranded them.
clearLog()
own.ghosted, trailer.ghosted = nil, nil
driverReset(0, 0)
check(own.ghosted == true, 'a reset still ghosts the car as usual')
frames(20.0)
check(own.ghosted == false,
  'and the car goes solid again even with a trailer permanently inside its box')

-- ===========================================================================
-- THE RESET GHOST COVERS THE WHOLE RIG
-- ===========================================================================
-- The mirror image of the rule above, and both are right. A FIELD reason means
-- "rivals are ghosts", so our own rig is skipped. A RESET ghost means "this car
-- is a ghost", and the trailer on its hitch has to be intangible with it.
--
-- Half a rig passing through a rival while the other half hits them is worse
-- than no ghost at all: the driver has been told they are clear.
clearLog()
own.ghosted, trailer.ghosted = nil, nil
driverReset(0, 0)
check(own.ghosted == true, 'a reset ghosts the car')
check(trailer.ghosted == true, 'and the trailer coupled to it, on the same reset')

-- The trailer carries the car's reason rather than a timer of its own, so the
-- two move TOGETHER. Asserted as "never disagree" across the whole ghost rather
-- than at a chosen moment: picking a time only tests the configured duration.
local disagreed = false
for _ = 1, 60 do
  frames(0.4)
  if own.ghosted ~= trailer.ghosted then disagreed = true end
end
check(not disagreed, 'the trailer is never in a different state from the car it is on')
frames(20.0)
check(own.ghosted == false, 'the car goes solid')
check(trailer.ghosted == false, 'and the trailer goes solid with it, not later')

-- A REMOTE driver's reset ghosts their trailer too, seen from here. Coupling is
-- simulated on every client, so this side can see what is on their hitch --
-- which matters, because the ghost broadcast carries a PLAYER id and a player
-- has exactly one car as far as the server is concerned.
core_vehicles = { attachedCouplers = { { OWN_ID, TRAILER_ID, 12, 34 },
                                       { RIVAL_ID, THIRD_ID, 12, 34 } } }
rival.ghosted, third.ghosted = nil, nil
handlers['RM_Ghost']({ pid = RIVAL_PID, active = true,
                       startedAt = raceTime, duration = 5.0 })
check(rival.ghosted == true, 'a rival reset ghost still reaches their car')
check(third.ghosted == true, 'and the trailer on their hitch')

-- ...AND IT COMES OFF THE WHOLE RIG AGAIN, which is the half that was missing.
-- Asserted with the coupling STILL IN PLACE, because that is the real case: a
-- trailer is on the hitch when the ghost expires just as it was when it began.
-- Dropping the coupling first (which this test used to do) tests nothing --
-- there is no rig left to lift the ghost off.
--
-- Applying to the rig and lifting from the car alone leaves the rival's trailer
-- intangible for the rest of the session, on every client but theirs: you drive
-- straight through it, and nothing in the mod is ever going to put it back.
rival.ghosted, third.ghosted = nil, nil
handlers['RM_Ghost']({ pid = RIVAL_PID, active = false })
check(rival.ghosted == false, 'the rival\'s ghost lifts from their car')
check(third.ghosted == false,
  'and from the trailer on their hitch: a ghost applied to a rig has to come '
    .. 'off the rig, or half of it stays intangible for the rest of the session')

core_vehicles = { attachedCouplers = { { OWN_ID, TRAILER_ID, 12, 34 } } }

-- THE SAFETY INVARIANT IS UNTOUCHED. Skipping our own rig must not become
-- skipping everybody: a real car overlapping still blocks, with no time limit.
-- Welding two cars together ends both races and cannot be undone.
clearLog()
own.ghosted = nil
third.x, third.y = 600, 600           -- still clear; only the rival moves in
rival.x, rival.y = 0, 0              -- a genuine rival, right on top of us
driverReset(0, 0)
frames(30.0)
check(own.ghosted == true,
  'a RIVAL inside the car still blocks the restore: rig-mates are the only '
    .. 'thing skipped, and that invariant is what stops two welded races')

rival.x, rival.y = 500, 500
core_vehicles = nil
world[TRAILER_ID] = nil

print(string.format('ghost_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
