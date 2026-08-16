-- Headless frame-cost budget for the client extension.
--
-- Why this exists: every other suite asks whether the mod is CORRECT. This one
-- asks what it COSTS per frame, because the two failure modes look nothing alike
-- and only one of them shows up in a test that checks behaviour. A feature can
-- be perfectly correct and still put a push across the Lua/CEF boundary sixty
-- times a second.
--
-- Three budgets, and the reasoning for each:
--
--   1. UI PUSHES PER SECOND. guihooks.trigger crosses into the browser process
--      and wakes an AngularJS digest, which re-evaluates every binding in a
--      ~780-expression template. This is far and away the most expensive thing
--      the client can do per frame, so the throttles (TUNE.LAP_TIME_EVERY,
--      TUNE.PROGRESS_EVERY) exist to keep it to a handful a second. A push added
--      to onUpdate without a throttle would not fail any other test in the repo.
--
--   2. ALLOCATIONS PER FRAME in the draw path. Immediate-mode drawing rebuilds
--      nothing per frame by design: the gate geometry and colours are cached.
--      Churning tables here hands work to the collector on the render thread.
--
--   3. DRAW CALLS PER FRAME. A driver sees two gates, not the circuit. If this
--      grows with route length, somebody has drawn the whole lap.
--
-- Run from the repo root: lua tests/perf_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- Stubs, with counters on everything that costs something
-- ---------------------------------------------------------------------------
local allocs = 0
local vec3mt = {}
vec3mt.__index = vec3mt
vec3mt.__add = function (a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
vec3mt.__mul = function (a, s) return vec3(a.x * s, a.y * s, a.z * s) end
vec3 = function (x, y, z)
  allocs = allocs + 1
  return setmetatable({ x = x, y = y, z = z }, vec3mt)
end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
ColorF = function (r, g, b, a) allocs = allocs + 1; return { r, g, b, a } end
ColorI = function (r, g, b, a) allocs = allocs + 1; return { r, g, b, a } end
String = function (s) return s end

local draws = 0
debugDrawer = {
  drawCylinder  = function () draws = draws + 1 end,
  drawTextAdvanced = function () draws = draws + 1 end,
  drawQuadSolid = function () draws = draws + 1 end,
}

local veh = { id = 7, x = 0, y = 0, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 40, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation() end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end

getPlayerVehicle = function (_) return veh end
be = { getPlayerVehicle = function () return veh end }
getAllVehicles = function () return { veh } end
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
log = function () end

-- The measurement that matters: every push into the browser, by event.
local pushes = {}
local pushTotal = 0
guihooks = { trigger = function (event)
  pushes[event] = (pushes[event] or 0) + 1
  pushTotal = pushTotal + 1
end }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function () end
local handlers = {}
AddEventHandler = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end
local function resetCounters() pushes, pushTotal, allocs, draws = {}, 0, 0, 0 end

-- ---------------------------------------------------------------------------
-- A realistic circuit: twelve checkpoints, a joker route and a pit lane.
-- ---------------------------------------------------------------------------
local cps = {}
for i = 1, 12 do
  cps[i] = { x = 0, y = i * 100, z = 0, hx = 0, hy = 1 }
end
handlers['RM_ApplyLayout']({
  name = 'perf', width = 20, height = 8, depth = 2,
  checkpoints = cps,
  joker = { { x = 30, y = 300, z = 0, hx = 0, hy = 1 },
            { x = 30, y = 400, z = 0, hx = 0, hy = 1 } },
  pit   = { { x = -30, y = 200, z = 0, hx = 0, hy = 1 } },
  startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 } },
})

-- ---------------------------------------------------------------------------
-- 1. UI pushes across one simulated second of racing, at 60 fps
-- ---------------------------------------------------------------------------
-- The whole point of the throttles. A driver racing is the busiest the client
-- ever is: the lap clock, the position telemetry and the flag are all live.
serverState({ phase = 'racing', sessionKind = 'race', totalLaps = 5,
  maxResets = -1, flag = 'green', drivers = {} })
resetCounters()
for i = 1, 60 do
  veh.y = veh.y + 0.6       -- 36 m/s, so gates are crossed and lap state moves
  RM.onUpdate(1 / 60)
end
local racingPushes = pushTotal

-- TUNE.LAP_TIME_EVERY is 0.25s and TUNE.PROGRESS_EVERY is 0.3s, so one second
-- of racing is 4 lap-clock pushes plus 3 to 4 progress pushes, plus whatever
-- crossing a gate legitimately reports. Sixty would mean something is pushing
-- every frame.
check(racingPushes <= 20, string.format(
  'a second of racing costs %d UI pushes, not one per frame (budget 20)',
  racingPushes))
check((pushes['RaceManagerLapTime'] or 0) <= 5,
  'the lap clock is throttled, not pushed per frame')
check((pushes['RaceManagerProgress'] or 0) <= 5,
  'position telemetry is throttled, not pushed per frame')
-- The flag rides on the route state, which is event-driven: it changes when the
-- session changes, not on a timer.
check((pushes['RaceManagerRoute'] or 0) <= 4,
  'the flag and route state are pushed on change, not on a schedule')

-- ---------------------------------------------------------------------------
-- 2. The start lights cost nothing after the countdown
-- ---------------------------------------------------------------------------
-- The lamps are markup gated on `countdown !== null` and animate with a CSS
-- transition on a class change, so they exist for about four seconds and are
-- torn out afterwards. Nothing on the Lua side ticks for them at all: this
-- checks a countdown does not add a per-frame push.
serverState({ phase = 'countdown', sessionKind = 'race', totalLaps = 5,
  maxResets = -1, flag = 'green', drivers = {} })
resetCounters()
for _ = 1, 60 do RM.onUpdate(1 / 60) end
check(pushTotal <= 6, string.format(
  'a second of countdown costs %d UI pushes (budget 6)', pushTotal))

-- ---------------------------------------------------------------------------
-- 3. The draw loop: two gates, and nothing rebuilt per frame
-- ---------------------------------------------------------------------------
serverState({ phase = 'racing', sessionKind = 'race', totalLaps = 5,
  maxResets = -1, flag = 'green', drivers = {} })
RM.onUpdate(1 / 60)          -- prime the caches
resetCounters()
RM.onUpdate(1 / 60)
local steadyAllocs, steadyDraws = allocs, draws

-- A DRIVER SEES TWO GATES. Twelve checkpoints, a joker and a pit stall are on
-- the track; what gets drawn is the armed gate, the one after it, and whichever
-- joker or pit furniture applies. If this scales with the route the whole lap is
-- being painted across the racing line.
check(steadyDraws <= 24, string.format(
  'a steady frame draws %d shapes on a twelve-gate circuit, not the whole lap '
    .. '(budget 24)', steadyDraws))

-- Immediate-mode drawing that allocates is drawing that feeds the collector on
-- the render thread. The geometry and the colours are both cached.
-- ONE, and it is not the drawing. checkGates keeps last frame's position so it
-- has a segment to test gates against, and that carry-over sample is the single
-- allocation: `prevPos = vec3(pos.x, pos.y, pos.z)`. It is inherent to crossing
-- detection and predates every visual feature here. The gate geometry and the
-- colours themselves allocate NOTHING, which is the property this pins: if this
-- climbs, something in the draw path has started rebuilding per frame.
check(steadyAllocs <= 1, string.format(
  'a steady frame allocates %d vectors/colours, and the budget is 1: the '
    .. 'crossing detector carries a position, the draw path caches everything '
    .. 'else', steadyAllocs))

-- The same frame on a route four times the size costs the same, which is the
-- property that actually matters: cost follows what is SHOWN, not what exists.
local big = {}
for i = 1, 48 do big[i] = { x = 0, y = i * 100, z = 0, hx = 0, hy = 1 } end
handlers['RM_ApplyLayout']({ name = 'big', width = 20, height = 8, depth = 2,
  checkpoints = big, startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 } } })
serverState({ phase = 'racing', sessionKind = 'race', totalLaps = 5,
  maxResets = -1, flag = 'green', drivers = {} })
RM.onUpdate(1 / 60)
resetCounters()
RM.onUpdate(1 / 60)
check(draws <= steadyDraws, string.format(
  'quadrupling the circuit to 48 gates draws %d shapes, no more than the 12-gate '
    .. 'circuit did (%d)', draws, steadyDraws))

print(string.format('perf_test: %d checks, %d failures', checks, fails))
print(string.format('  racing: %d UI pushes/sec, %d draws/frame, %d allocs/frame',
  racingPushes, steadyDraws, steadyAllocs))
if fails > 0 then os.exit(1) end
