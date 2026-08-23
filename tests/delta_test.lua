-- Headless test for LAP AND SECTOR DELTAS in lua/ge/extensions/raceManager.lua.
--
-- Two readouts, two baselines, and the baselines are the point:
--
--   the LAP delta is against the driver's PREVIOUS lap -- "am I still
--   improving", which is the question asked at the line;
--   the SECTOR delta is against their BEST for that sector -- "where am I
--   losing it", which only has an answer against a reference.
--
-- Both are computed on the CLIENT. The server already stamps every crossing
-- into rec.splits, but that table exists to build the gap to the LEADER: it
-- compares two drivers on one clock. A driver's delta to their own earlier lap
-- compares them to themselves, so it needs no other car, no round trip, and
-- cannot be blanked by a dropped packet the way a cross-driver gap can.
--
-- WHAT THIS FILE IS REALLY GUARDING IS THE SIGN. Faster means a SMALLER time,
-- so an improvement is a NEGATIVE delta -- an inversion that is easy to write
-- backwards, and one a driver reads mid-corner at speed. Getting it wrong does
-- not crash anything. It just tells them the opposite of the truth all race.
--
-- Run from the repo root: lua5.3 tests/delta_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function near(a, b, tol)
  return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 0.02)
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

-- ---------------------------------------------------------------------------
-- Driving the circuit
-- ---------------------------------------------------------------------------
-- Two gates: gate 1 at y=100, and gate 2 at y=200 which is the start/finish
-- line. So a lap is two sectors -- S1 from the line to gate 1, S2 from gate 1
-- back to the line.
--
-- Frames are 0.05 s, so a duration is burned by counting them. Sector lengths
-- are kept well clear of TUNE.LAP_DEBOUNCE (2 s), or the lap crossing is
-- discarded as a double-fire and no lap ever completes.
local function burn(seconds)
  frame(math.floor(seconds / 0.05 + 0.5))
end

-- One lap, spending `s1` seconds on sector 1 and `s2` on sector 2.
--
-- THE RETURN LEG GOES ROUND THE OUTSIDE, and it has to. Teleporting straight
-- back from past the line to the start crosses gate 1 BACKWARDS on the way, and
-- the route counts that as clearing it: armedWp advances, so the next lap
-- numbers its sectors one out and every delta is measured against the wrong
-- one. A real car drives a loop; the first version of this helper did not, and
-- the failures looked like the feature was broken rather than the harness.
--
-- x=300 is well outside the 40 m gates, so the return crosses nothing.
local function lap(s1, s2)
  moveTo(50)                 -- on the run to gate 1
  burn(s1)
  moveTo(95); moveTo(105)    -- clear gate 1: closes S1
  burn(s2)
  moveTo(195); moveTo(205)   -- clear the line: closes S2 and the lap
  moveTo(205, 300)           -- swing wide...
  moveTo(10, 300)            -- ...down the outside...
  moveTo(10, 0)              -- ...and back onto the racing line
end

local function lastHook(name)
  for i = #hooks, 1, -1 do
    if hooks[i].event == name then return hooks[i].payload end
  end
end
local function sectorHooks()
  local out = {}
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerSector' then out[#out + 1] = h.payload end
  end
  return out
end

startRace(9)

-- ---------------------------------------------------------------------------
-- The first timed lap has nothing to compare against
-- ---------------------------------------------------------------------------
-- nil, not zero. A delta of 0.000 on the first lap would read as "dead level
-- with yourself", which is a statement about a lap that does not exist.
hooks = {}
lap(2.0, 2.0)
local first = lastHook('RaceManagerLapDone')
check(first ~= nil, 'the first lap is announced')
check(first.delta == nil,
  'and carries NO delta: there is no previous lap to measure it against')

local s = sectorHooks()
check(#s == 2, 'a two-gate lap closes two sectors (got ' .. #s .. ')')
check(s[1] and s[1].sector == 1 and s[2] and s[2].sector == 2,
  'numbered by the gate that closed them')
check(s[1].delta == nil and s[2].delta == nil,
  'and neither carries a delta on their first visit')

-- ---------------------------------------------------------------------------
-- A FASTER lap is a NEGATIVE delta
-- ---------------------------------------------------------------------------
-- The sign is the whole point of this file. Faster is less time, so the number
-- goes down, and that is what the UI paints green.
hooks = {}
lap(1.5, 1.5)
local quicker = lastHook('RaceManagerLapDone')
check(quicker.delta ~= nil, 'the second lap carries a delta')
check(quicker.delta < 0,
  'a QUICKER lap is a NEGATIVE delta, which is what the UI paints green (got '
    .. tostring(quicker.delta) .. ')')

s = sectorHooks()
check(s[1].delta ~= nil and s[1].delta < 0, 'the quicker sector 1 is negative too')
check(s[1].best == true, 'and is flagged as a personal best for that sector')

-- ---------------------------------------------------------------------------
-- A SLOWER lap is a POSITIVE delta
-- ---------------------------------------------------------------------------
hooks = {}
lap(2.5, 2.5)
local slower = lastHook('RaceManagerLapDone')
check(slower.delta > 0,
  'a SLOWER lap is a POSITIVE delta, which the UI paints red (got '
    .. tostring(slower.delta) .. ')')

-- ---------------------------------------------------------------------------
-- THE TWO BASELINES ARE DIFFERENT, and this is what proves it
-- ---------------------------------------------------------------------------
-- This lap is quicker than the one just driven (2.5 s sectors) but still slower
-- than the best (1.5 s). So the LAP delta must be negative -- an improvement on
-- last time -- while the SECTOR delta must be positive, because it is measured
-- against a best that still stands.
--
-- One baseline serving both would make these two agree, and every check above
-- would still pass with the feature half wrong.
hooks = {}
lap(2.0, 2.0)
local mixed = lastHook('RaceManagerLapDone')
s = sectorHooks()
check(mixed.delta < 0, 'quicker than the LAST lap, so the lap delta is negative')
check(s[1].delta > 0,
  'but slower than the BEST sector 1, so the sector delta is positive -- the '
    .. 'two readouts answer different questions')
check(s[1].best ~= true, 'and it is not flagged as a best')

-- ---------------------------------------------------------------------------
-- The best only moves when it is beaten
-- ---------------------------------------------------------------------------
hooks = {}
lap(1.2, 2.0)
s = sectorHooks()
check(s[1].best == true, 'a new quickest sector 1 is a best')
hooks = {}
lap(1.4, 2.0)
s = sectorHooks()
check(s[1].best ~= true, 'and a slower one afterwards is not')
check(s[1].delta > 0, 'measured against the 1.2 that still stands')

if fails == 0 then
  print(('delta_test: %d checks, 0 failures'):format(checks))
else
  print(('delta_test: %d FAILURES of %d checks'):format(fails, checks))
  os.exit(1)
end
