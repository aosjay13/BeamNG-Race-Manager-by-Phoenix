-- Headless test for FLAG TRANSITIONS in lua/ge/extensions/raceManager.lua.
--
-- Not the same thing as flag STATE. driverFlag() answers "what is this driver's
-- flag right now" and the header glyph asks it every frame; nothing in a query
-- can tell "still white" from "just went white", and a full-panel flash needs
-- the second one. This file is about the latches that turn the standing state
-- into an event exactly once.
--
-- The white flag is the interesting one. It is PER DRIVER, because the field is
-- spread around the circuit and the leader takes it a lap before the
-- backmarkers do, and it is waved on the APPROACH to the line that starts the
-- last lap rather than once the car is already past it -- which is what a
-- marshal does, and what makes it useful rather than a receipt.
--
-- Run from the repo root: lua5.3 tests/flag_test.lua

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

-- A LAP HAS TO TAKE LONGER THAN TUNE.LAP_DEBOUNCE.
--
-- Two seconds, and a crossing inside that window is discarded as a double-fire
-- before the lap counter advances. Frames here are 0.05 s, so a lap driven in
-- five of them is a quarter of a second long and never counts: the gates all
-- register, nextWp cycles correctly, and localLap sits on 1 forever.
--
-- The time is burned at y=105 -- just past gate 1, and ninety-five metres from
-- the line, which is well outside the white-flag radius. Coasting anywhere
-- inside that radius would trip the very thing under test.
local function coast(seconds)
  frame(math.floor((seconds or 2.5) / 0.05 + 0.5))
end

-- Drive up to gate 1 and clear it, leaving the car on the run down to the line.
local function ontoTheApproach()
  moveTo(95); moveTo(105)
  coast(2.5)
end

-- Complete one full lap: through gate 1, then through the line.
local function completeLap()
  ontoTheApproach()
  moveTo(195); moveTo(205)          -- the start/finish line
  moveTo(10)                        -- round to the start of the next lap
end

local function flagNotices()
  local out = {}
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerNotice' and h.payload.kind == 'flag' then
      out[#out + 1] = h.payload
    end
  end
  return out
end
local function clearLog() hooks = {} end
-- The two approach flags share a kind, so tests about one have to say which.
local function flagsNamed(name)
  local n = 0
  for _, f in ipairs(flagNotices()) do if f.msg == name then n = n + 1 end end
  return n
end

-- ---------------------------------------------------------------------------
-- The white flag is waved BEFORE the line, not after it
-- ---------------------------------------------------------------------------
startRace(3)
clearLog()

-- Lap 1, on the run down to the line. Two laps still to go, so nothing yet.
ontoTheApproach()
moveTo(170)
check(#flagNotices() == 0, 'no white flag two laps from the end')

completeLap()          -- now on lap 2 of 3
clearLog()
ontoTheApproach()

-- Still well clear of the line: the flag belongs to the last fifty metres.
moveTo(120)
check(#flagNotices() == 0, 'no white flag while still 80 m from the line')

-- Inside the last fifty.
moveTo(170)
local white = flagNotices()
check(#white == 1, 'the white flag is waved on the approach to the final lap')
check(white[1] and white[1].msg == 'WHITE FLAG', 'and says so')
check(white[1] and white[1].colour == 'white', 'and waves white')

-- It does not re-arm every frame for the rest of the approach. The run down to
-- a line takes seconds and this is sampled per frame, so a missing latch is a
-- flash that never stops.
clearLog()
moveTo(180); moveTo(190); frame(20)
check(#flagNotices() == 0, 'the white flag fires once, not every frame of the approach')

-- ...and not again on the final lap itself, having already been given. That run
-- to the line is now the CHECKERED approach, so the assertion is about which
-- flag appears rather than about silence.
completeLap()
clearLog()
ontoTheApproach()
moveTo(175)
check(flagsNamed('WHITE FLAG') == 0, 'and not a second time on the last lap')
check(flagsNamed('CHECKERED FLAG') == 1,
  'the run to the finish waves the checkered flag on the same fifty metres')

-- Once, like the white one: this is sampled every frame for the whole approach.
clearLog()
moveTo(185); moveTo(192); frame(20)
check(flagsNamed('CHECKERED FLAG') == 0, 'and waves it once, not every frame')

-- ---------------------------------------------------------------------------
-- Races that have no approach to a final lap
-- ---------------------------------------------------------------------------
-- A one-lap race: lap 1 IS the flag and there is no earlier lap to be waved at
-- on. Asking for localLap == totalLaps - 1 would be asking for lap zero.
startRace(1)
clearLog()
ontoTheApproach()
moveTo(180)
check(flagsNamed('WHITE FLAG') == 0, 'a one-lap race never waves a white flag')
check(flagsNamed('CHECKERED FLAG') == 1,
  'but it does have a finish, and lap 1 IS the flag')

-- A sprint stage is driven once from the first gate to the last: the last gate
-- is a FINISH, not a line you come back round to.
handlers['RM_ApplyLayout']({
  name = 'stage', width = 40, height = 10, depth = 2, pointToPoint = true,
  checkpoints = {
    { x = 0, y = 100,  z = 0, hx = 0, hy = 1 },
    { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 },
  },
})
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
moveTo(10)
clearLog()
ontoTheApproach()
moveTo(180)
check(flagsNamed('WHITE FLAG') == 0, 'a point-to-point stage never waves a white flag')
check(flagsNamed('CHECKERED FLAG') == 1,
  'though its last gate is still a finish to be waved at')

-- ---------------------------------------------------------------------------
-- The flag goes with the session
-- ---------------------------------------------------------------------------
-- A latch left set from the last race would suppress the flag in the next one,
-- which is the failure that only shows up on the second race of the evening.
startRace(3)
completeLap()
clearLog()
ontoTheApproach()
moveTo(170)
check(flagsNamed('WHITE FLAG') == 1, 'a fresh session waves the white flag again')

-- ---------------------------------------------------------------------------
-- The checkered flag, once, for this driver
-- ---------------------------------------------------------------------------
-- Retired WITHOUT having crossed the line -- a DNF, an admin ending the session,
-- the clock running out. No approach flash happened, so this is the only time
-- this driver sees the flag.
startRace(3)
clearLog()
handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race', place = 4 })
local chq = flagNotices()
check(#chq == 1, 'a driver retired without crossing the line still gets the flag')
check(chq[1] and chq[1].msg == 'CHECKERED FLAG', 'and says so')
check(chq[1] and chq[1].sub and chq[1].sub:find('4th', 1, true) ~= nil,
  'and carries the placing as its second line rather than as a notice of its own')

-- ...but a driver who DROVE across the line saw it seconds ago on the approach.
-- Waving it again the instant they cross is the same news twice; the placing is
-- the part they do not have yet.
startRace(1)
clearLog()
ontoTheApproach()
moveTo(180)
check(flagsNamed('CHECKERED FLAG') == 1, 'the approach waves it')
clearLog()
handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race', place = 2 })
check(flagsNamed('CHECKERED FLAG') == 0, 'crossing does not wave it a second time')
local placed = nil
for _, h in ipairs(hooks) do
  if h.event == 'RaceManagerNotice' and h.payload.kind == 'finish' then placed = h.payload end
end
check(placed and tostring(placed.msg):find('2nd', 1, true) ~= nil,
  'it says where they came instead')

-- A repeat broadcast is not a second finish. The server re-sends state freely
-- and a flash per broadcast would be a strobe.
clearLog()
handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race', place = 4 })
check(#flagNotices() == 0, 'the checkered flag is waved once, not per broadcast')

-- A derby elimination is not a finish. It has an overlay of its own, and
-- driverFlag() leaves it out for the same reason.
startRace(3)
clearLog()
handlers['RM_ForceSpectate']({ reason = 'Eliminated', source = 'derby', place = 2 })
check(#flagNotices() == 0, 'a derby elimination does not wave a checkered flag')

-- ---------------------------------------------------------------------------
-- Session flags carry their own colour
-- ---------------------------------------------------------------------------
-- Green, yellow and red are one kind ('flag') and each has to flash in its own
-- colour, so the colour travels on the notice rather than being looked up from
-- the kind.
startRace(3)
clearLog()
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  flag = 'yellow' })
local y = flagNotices()
check(#y == 1 and y[1].msg == 'YELLOW FLAG', 'a caution is announced')
check(y[1] and y[1].colour == 'yellow', 'and waves yellow')

clearLog()
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  flag = 'red' })
local r = flagNotices()
check(#r == 1 and r[1].colour == 'red', 'a red flag waves red')

clearLog()
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  flag = 'green' })
local g = flagNotices()
check(#g == 1 and g[1].msg == 'GREEN FLAG', 'and going back green is announced')
check(g[1] and g[1].colour == 'green', 'and waves green')

-- The same flag re-broadcast is not a new flag.
clearLog()
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {},
  flag = 'green' })
check(#flagNotices() == 0, 'a re-broadcast of the standing flag says nothing')

print(string.format('flag_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
