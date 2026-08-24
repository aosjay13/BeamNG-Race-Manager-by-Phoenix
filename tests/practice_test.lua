-- Headless test for FREE PRACTICE in lua/ge/extensions/raceManager.lua.
--
-- A driver pulls up an approved track between sessions and drives it, timed,
-- with nothing at stake. The server decides whether they may; this file is
-- about what the client does once told yes.
--
-- THE PROPERTY THAT MATTERS IS A NEGATIVE ONE, and it is the reason this file
-- exists: a practice lap REPORTS NOTHING. No RM_Lap, so no leaderboard row, no
-- best lap, no cup round, nothing for a real session to notice. A practice lap
-- that leaked onto the timing screen would be worse than no practice at all --
-- it would put a time nobody was racing for into a championship.
--
-- The second property is that practice is NOT a session. sessionRunning() stays
-- false throughout, so the grid, the hold, the reset allowance, the flags and
-- the spectator lock all go on ignoring a practising driver. Those rules exist
-- to make a race fair, and there is no race.
--
-- Run from the repo root: lua5.3 tests/practice_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local sent     = {}
local hooks    = {}
local handlers = {}

local veh = { id = 7, x = 0, y = 0, z = 0, hx = 0, hy = 1 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = self.hx, y = self.hy, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end

be               = { getPlayerVehicle = function () return veh end }
getPlayerVehicle = function (_) return veh end
getAllVehicles   = function () return { veh } end
beamng_version   = '0.39.0.0'

vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
-- debugDrawer is deliberately NOT stubbed. The draw path checks for it and
-- returns when it is absent, so leaving it nil keeps every frame here on the
-- logic under test instead of building gate geometry this file never looks at.
-- Stubbing it only half way is worse than not at all: the draw runs and then
-- reaches for ColorF, which is not here either.

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

-- Put the car somewhere and let a frame observe it there. Crossing detection
-- works on the SEGMENT between two frames, so a gate is cleared by being on
-- either side of it on consecutive frames -- teleporting past one in a single
-- step clears nothing, which is the same rule a real car obeys.
local function moveTo(y, x)
  veh.x, veh.y, veh.z = x or 0, y, 0
  frame()
end

-- A two-gate circuit. The LAST checkpoint is the start/finish line, so gate 2
-- at y=200 is the line and gate 1 at y=100 is the rest of the lap.
local SF_Y = 200
local function loadCircuit()
  handlers['RM_ApplyLayout']({
    name = 'oval', width = 40, height = 10, depth = 2,
    checkpoints = {
      { x = 0, y = 100,  z = 0, hx = 0, hy = 1 },
      { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 },
    },
  })
end

local function startRace(laps)
  -- RELEASE THE SPECTATOR LOCK FIRST. Nothing else clears it: resetLapTracking
  -- does not, because in a real session the SERVER releases it when the session
  -- ends. A block that finished a driver therefore leaves the lock standing,
  -- and every approach check after it returns early on spectatorLock -- so the
  -- next block's flags silently never fire and the failure looks like the
  -- watcher being broken rather than the harness not ending the last race.
  handlers['RM_ReleaseSpectate']({ source = 'race' })
  loadCircuit()
  serverState({ phase = 'racing', totalLaps = laps, maxResets = -1, drivers = {} })
  moveTo(10)
end


-- The route the client currently holds, read back off the last panel push.
local function routeWaypointsNow()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerRoute' then return hooks[i].payload.waypoints or {} end
  end
  return {}
end
-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
-- Gate 1 at y=100, gate 2 at y=200 which is the line. The return leg goes round
-- the outside: teleporting back across gate 1 counts as clearing it backwards
-- and advances the route, which numbers the next lap's gates one out.
local function burn(seconds)
  frame(math.floor(seconds / 0.05 + 0.5))
end
local function lap()
  moveTo(50)
  burn(2.5)
  moveTo(95); moveTo(105)
  burn(2.5)
  moveTo(195); moveTo(205)
  moveTo(205, 300); moveTo(10, 300); moveTo(10, 0)
end
local function sentCount(event)
  local n = 0
  for _, s in ipairs(sent) do if s.event == event then n = n + 1 end end
  return n
end
local function lastHook(name)
  for i = #hooks, 1, -1 do
    if hooks[i].event == name then return hooks[i].payload end
  end
end

-- An idle server with a track loaded: exactly the state practice is for.
handlers['RM_ReleaseSpectate']({ source = 'race' })
loadCircuit()
-- A start grid, so the placement on practice start has somewhere to go.
handlers['RM_ApplyLayout']({
  name = 'oval', width = 40, height = 10, depth = 2,
  checkpoints = {
    { x = 0, y = 100, z = 0, hx = 0, hy = 1 },
    { x = 0, y = 200, z = 0, hx = 0, hy = 1 },
  },
  startPositions = { { x = 0, y = 10, z = 0, hx = 0, hy = 1 } },
})
serverState({ phase = 'waiting', totalLaps = 3, maxResets = -1, drivers = {} })
moveTo(10)

-- ---------------------------------------------------------------------------
-- Without practice, an idle server times nothing
-- ---------------------------------------------------------------------------
-- The gates are still DRAWN -- a driver looking at a track wants to see where it
-- goes -- but nothing is armed and no lap is taken. This is the behaviour
-- practice exists to change, so it is worth pinning before changing it.
sent, hooks = {}, {}
lap()
check(sentCount('RM_Lap') == 0, 'an idle server reports no laps')
check(lastHook('RaceManagerLapDone') == nil,
  'and takes none either: no time is shown for a lap nobody was timing')

-- ---------------------------------------------------------------------------
-- Practising: timed here, reported nowhere
-- ---------------------------------------------------------------------------
-- THE HANDLER MUST DECODE ITS PAYLOAD, like every other one in DISPATCH.
--
-- Worth a check of its own because the first version took a table and the wire
-- carries a STRING, so it failed its own type check and returned: practice
-- never switched on, the gates rendered exactly as they always do outside a
-- session, and nothing was ever armed. It looked like the checkpoints were
-- broken.
--
-- This test could not see it. It called the handler with a table -- which a
-- decode-first handler also accepts, because the harness's jsonDecode is the
-- identity function -- so it passed against the bug and against the fix alike.
-- Spying on the decode is what tells the two apart.
local decodedPayload = false
do
  local realDecode = jsonDecode
  jsonDecode = function (v) decodedPayload = true; return realDecode(v) end
  handlers['RM_Practice']({ on = true, layout = 'oval' })
  jsonDecode = realDecode
end
check(decodedPayload,
  'the practice handler decodes what it is given, so a real JSON payload off '
    .. 'the wire turns practice on rather than being dropped')

-- ...and it stands the car on a start position, so lap one is a lap rather than
-- the drive out to the circuit plus a lap, timed as one.
--
-- Checked by where the CAR ends up, not by a slot number in a payload: the
-- placement goes through the same staggered queue the grid uses, so it takes a
-- few frames and the assertion has to wait for it. A slot number says what was
-- asked for; the position says what happened.
-- Parked off to the SIDE, not straight up the road. The teleport back to the
-- grid is seen as one segment, and a segment down the middle of the circuit
-- crosses both gates on the way -- which advances the route and leaves the lap
-- below starting from the wrong gate. x=300 is well outside the 40 m gates.
veh.x, veh.y, veh.z = 300, 400, 0
frame(60)
check(math.abs(veh.y - 10) < 2,
  'starting practice stands the car on start position 1 (y=10, got '
    .. tostring(veh.y) .. ')')

sent, hooks = {}, {}
lap()

local done = lastHook('RaceManagerLapDone')
check(done ~= nil and type(done.lapTime) == 'number',
  'a practice lap is timed and shown to the driver')
check(done ~= nil and done.lap == 1, 'and counted from one')

-- THE ASSERTION THIS FILE IS FOR.
check(sentCount('RM_Lap') == 0,
  'and reported to NOBODY: no RM_Lap, so no leaderboard row and no cup round')
check(sentCount('RM_Progress') == 0,
  'and no position telemetry either -- a practising car is not in the running order')

-- Sectors work the same way: timed locally, sent nowhere.
local sectors = 0
for _, h in ipairs(hooks) do
  if h.event == 'RaceManagerSector' then sectors = sectors + 1 end
end
check(sectors == 2, 'both sectors are timed while practising (got ' .. sectors .. ')')

-- A second lap carries a delta, the same as a session lap would.
sent, hooks = {}, {}
lap()
done = lastHook('RaceManagerLapDone')
check(done ~= nil and done.lap == 2, 'the lap counter advances')
check(done ~= nil and done.delta ~= nil,
  'and the second practice lap has a delta to the first')
check(sentCount('RM_Lap') == 0, 'still reporting nothing')

-- ---------------------------------------------------------------------------
-- Practice is not a session
-- ---------------------------------------------------------------------------
-- Everything that polices a RACE reads the phase, and the phase never moved.
-- If practice had been implemented by pretending to be a session, this is what
-- would have gone wrong: a hold, a grid slot, a reset allowance and a flag
-- system all switching on for somebody driving alone.
local route = lastHook('RaceManagerRoute')
check(route ~= nil and route.practice == true, 'the panel is told practice is on')
local state = lastHook('RaceManagerState')
check(state == nil or state.phase ~= 'racing',
  'but the session phase never moves: practice is not a race')

-- ---------------------------------------------------------------------------
-- Ending it stops the timing and leaves the track alone
-- ---------------------------------------------------------------------------
hooks = {}
RM.endPractice()
-- Read off the push endPractice itself makes. Reading it after the lap below
-- would find nothing: with timing off, no gate crossing pushes route state, so
-- the check would pass or fail on whether anything happened to refresh the
-- panel rather than on whether the track is still there.
check(#routeWaypointsNow() > 0,
  'the track stays loaded: a driver who stopped timing has not stopped '
    .. 'looking at where the circuit goes')
local offRoute = lastHook('RaceManagerRoute')
check(offRoute ~= nil and offRoute.practice ~= true, 'and the panel is told it is off')

sent, hooks = {}, {}
lap()
check(lastHook('RaceManagerLapDone') == nil, 'ending practice stops the timing')
check(sentCount('RM_Lap') == 0, 'and still reports nothing')

if fails == 0 then
  print(('practice_test: %d checks, 0 failures'):format(checks))
else
  print(('practice_test: %d FAILURES of %d checks'):format(fails, checks))
  os.exit(1)
end
