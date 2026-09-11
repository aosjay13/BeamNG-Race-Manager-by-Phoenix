-- Headless test for WHAT HAPPENS TO THE CAR when a derby eliminates its driver
-- (lua/ge/extensions/raceManager.lua + lua/ge/extensions/raceManager/derby.lua).
--
-- derby_test is the server's half: who is out, and why. derby_lives_test is the
-- client's policing: the stopped and out-of-bounds timers and what they report.
-- Neither of them looks at the CAR, and the car is the whole of what a driver
-- experiences when they are knocked out.
--
-- The rule, and it is one sentence: an eliminated car becomes an OBSTACLE. It
-- stays where it is, solid, free to roll, with the ignition cut and the driving
-- inputs dead. The survivors are meant to be able to shove it. It is not frozen,
-- it is not ghosted, and above all it is not on its handbrake.
--
-- Two ways that was got wrong, both reported from a live derby:
--
--   THE HANDBRAKE CAME BACK. Elimination releases it, on purpose. The
--   END-OF-DERBY stand-down applies it, also on purpose -- a settled result must
--   not be driven into while the arena stays up for the cool-down. The
--   stand-down went to EVERY client, including the drivers already out, so the
--   handbrake elimination had just released was re-applied a moment later.
--
--   Worst on the LAST elimination, which is the one that decides the derby: the
--   same broadcast says "you are out" and "the derby is over", so the release
--   and the re-application landed within a frame of each other and the handbrake
--   looked like it came back on its own.
--
--   THE ENGINE WENT ON REVVING, but only on the out-of-bounds timeout. The two
--   timers are identical on the server and nearly identical on the client; what
--   differs is physical. A car put out for NOT MOVING has nobody holding
--   anything down, so zeroing the pedals once is enough. A car put out for
--   leaving the arena was being driven a second ago with a foot on the floor --
--   and a filtered action keeps the value it had when the filter armed, so
--   setting it to zero once cannot beat a pedal that is still held. Only the
--   propulsion filter can, and that was armed for the stand-down alone.
--
-- Run from the repo root: lua5.3 tests/derby_wreck_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local handlers = {}   -- server -> client handlers the extension registered
local vehCmds  = {}   -- every queueLuaCommand, in order

local OWN_ID, OWN_PID = 7, 1

local own = { id = OWN_ID, x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0 }
function own:getID() return self.id end
function own:getPosition() return { x = self.x, y = self.y, z = self.z } end
function own:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function own:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function own:getVelocity() return { x = self.vx, y = self.vy, z = self.vz } end
function own:getJBeamFilename() return 'etk800' end
function own:getInitialWidth() return 2.0 end
function own:getInitialLength() return 4.5 end
function own:setPositionRotation() end
function own:setMeshAlpha() end
function own:queueLuaCommand(cmd)
  vehCmds[#vehCmds + 1] = tostring(cmd)
end

getPlayerVehicle = function () return own end
be = { getPlayerVehicle = function () return own end, enterVehicle = function () end }
getAllVehicles = function () return { own } end
getObjectByID = function (id) return id == OWN_ID and own or nil end
MPVehicleGE = {
  isOwn = function (id) return id == OWN_ID end,
  getVehicles = function ()
    return { { ownerID = OWN_PID, gameVehicleID = OWN_ID } }
  end,
}
core_vehicles = { removeCurrent = function () return true end,
                  spawnNewVehicle = function () return nil end }
commands = { setFreeCamera = function () end, isFreeCamera = function () return false end,
             setGameCamera = function () end }
core_camera = { setByName = function () end }

-- THE ACTION FILTER, RECORDED rather than stubbed away. Which groups are armed
-- is half of what this file rules on, and the no-op stub every other harness
-- uses cannot see it.
local filterBlocked = {}    -- [group] = the last `blocked` it was set to
core_input_actionFilter = {
  setGroup  = function () end,
  addAction = function (_, group, blocked) filterBlocked[group] = blocked end,
}
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
core_vehicleBridge = { executeAction = function () end }
vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function () end }
MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return OWN_PID end }
TriggerServerEvent = function () end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function frames(n)
  for _ = 1, (n or 3) do RM.onUpdate(0.1) end
end
local function cmdsClear() vehCmds = {} end
-- Did any command since the last clear set this input to this value?
local function didSet(input, value)
  local want = ('input.event("%s", %s, 1)'):format(input, value)
  for _, c in ipairs(vehCmds) do if c == want then return true end end
  return false
end
local function didQueue(fragment)
  for _, c in ipairs(vehCmds) do
    if c:find(fragment, 1, true) then return c end
  end
  return nil
end

-- A derby broadcast. `players` carries our own row, which is how the server
-- tells this client whether it is still in, and `derbyOver` is how it says the
-- result is settled and the cool-down is running.
local function derbyState(phase, myStatus, over)
  handlers['RM_DerbyUpdate']({
    rmProtocol = 2, derbyPhase = phase, oobLimit = 5, demoLimit = 10, lives = 1,
    derbyOver = over and true or false,
    boundary = {}, startPositions = {},
    players = { { id = OWN_PID, name = 'Alice', status = myStatus or 'alive' } },
  })
end
-- The server putting this driver out. `source` is what splits a derby wreck from
-- a race finisher, and everything below turns on it.
local function eliminated()
  handlers['RM_ForceSpectate']({ reason = 'Demolished', source = 'derby' })
end
local function released()
  handlers['RM_ReleaseSpectate']({ source = 'derby' })
end

-- ---------------------------------------------------------------------------
-- 1. A SURVIVOR IS STOOD DOWN when the derby is decided
-- ---------------------------------------------------------------------------
-- The other half of the rule, asserted first so that section 3 is a difference
-- rather than an absence. A car still being driven when the result settles gets
-- the handbrake and the freeze, because the arena stays up for the cool-down and
-- a wreck still being driven into people for those seconds is extra time nobody
-- was given.
derbyState('running', 'alive', false)
frames()
cmdsClear()
derbyState('running', 'alive', true)
frames()
check(didSet('parkingbrake', 1),
  'a driver still alive when the derby is decided gets the handbrake: the result '
    .. 'is settled and the cool-down is not extra time')
check(didSet('brake', 1), 'and the footbrake with it')
check(didSet('throttle', 0), 'and the throttle is let go first, before anything locks')

-- Put the derby away again, which releases the stand-down.
derbyState('idle', 'alive', false)
frames()

-- ---------------------------------------------------------------------------
-- 2. AN ELIMINATED CAR IS AN OBSTACLE
-- ---------------------------------------------------------------------------
derbyState('running', 'alive', false)
frames()
cmdsClear()
eliminated()
frames()

check(didSet('parkingbrake', 0),
  'elimination RELEASES the handbrake: the wreck is meant to be shoved around, '
    .. 'and one bolted to the arena floor is a wall instead')
check(not didSet('parkingbrake', 1), 'and never applies it')
check(didSet('brake', 0),
  'the footbrake goes off too, so a car put out at speed coasts to a halt '
    .. 'rather than anchoring in the middle of the arena')
check(didSet('throttle', 0), 'the throttle is zeroed')
check(didSet('steering', 0), 'and the wheel straightened, or the wreck will not push straight')

-- THE IGNITION, and the guard on it. queueLuaCommand posts a string into the
-- vehicle's own Lua VM, so an error in that string surfaces THERE and the pcall
-- on this side sees nothing: a guard that throws is a guard that silently does
-- not run, and the only symptom is an engine still running under a driver who
-- is out.
local ign = didQueue('setEngineIgnition(false)')
check(ign ~= nil, 'the ignition is cut: a car put out for leaving the arena was '
  .. 'being driven a second ago, and zeroed pedals still leave an engine idling '
  .. 'an automatic forward')
check(ign and ign:find('controller and controller.mainController', 1, true) ~= nil,
  'and the guard tests the CONTROLLER before indexing it. Guarding only the '
    .. 'function reached through it throws on exactly the vehicle the guard was '
    .. 'written for: one with no main controller')

-- ---------------------------------------------------------------------------
-- 3. THE FILTER, which is the only thing that beats a pedal still held
-- ---------------------------------------------------------------------------
-- A filtered action keeps the value it had when the filter armed, so zeroing the
-- throttle once works for a driver who has lifted and does nothing for one whose
-- foot is on the floor. The stopped timer only ever produces the first kind; the
-- out-of-bounds timer only ever produces the second, which is why it was the
-- out-of-bounds timeout that screamed and the stopped timer that never did.
check(filterBlocked['raceManagerSpectate'] == true,
  'the driving inputs are filtered, so the wreck cannot be driven')
check(filterBlocked['raceManagerPropulsion'] == true,
  'and PROPULSION with them. Setting the throttle to zero once cannot beat a '
    .. 'pedal that is still down, and a car put out for leaving the arena always '
    .. 'has one')

-- ---------------------------------------------------------------------------
-- 4. THE DERBY IS THEN DECIDED, and the wreck is left alone
-- ---------------------------------------------------------------------------
-- The bug, in one broadcast. This is the last elimination, so the same payload
-- says "you are out" and "the derby is over". The stand-down used to run from
-- the top of that handler, BEFORE this driver's status had been read out of it,
-- so it re-applied the handbrake elimination had released one frame earlier.
cmdsClear()
derbyState('running', 'eliminated', true)
frames()
check(not didSet('parkingbrake', 1),
  'the end-of-derby stand-down does NOT reach a driver already out: their car '
    .. 'was left free to roll on purpose, and this is the handbrake coming back')
check(not didSet('brake', 1), 'nor the footbrake')

-- And it holds for every later broadcast of the same cool-down, not just the
-- first: the phase is unchanged, so a guard that only fired on the transition
-- would let the next one through.
cmdsClear()
derbyState('running', 'eliminated', true)
frames()
check(not didSet('parkingbrake', 1), 'and not on the next broadcast either')

-- ---------------------------------------------------------------------------
-- 5. RELEASED, and the car is a car again
-- ---------------------------------------------------------------------------
-- The derby ends and every eliminated driver gets their car back for whatever
-- comes next. A driver handed back a car that will not start is worse off than
-- one handed back a running wreck.
cmdsClear()
derbyState('idle', 'eliminated', false)
released()
frames()
check(didQueue('setEngineIgnition(true)') ~= nil, 'the ignition comes back')
check(filterBlocked['raceManagerPropulsion'] == false,
  'and the propulsion filter lifts, or the throttle would stay dead into the '
    .. 'next session')
check(filterBlocked['raceManagerSpectate'] == false, 'along with the driving inputs')

if fails == 0 then
  io.stdout:write(('derby_wreck_test: %d checks, 0 failures\n'):format(checks))
else
  io.stdout:write(('derby_wreck_test: %d FAILURES of %d checks\n'):format(fails, checks))
  os.exit(1)
end
