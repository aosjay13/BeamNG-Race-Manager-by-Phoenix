-- Headless frame-cost budget for the client extension.
--
-- Why this exists: every other suite asks whether the mod is CORRECT. This one
-- asks what it COSTS per frame, because the two failure modes look nothing alike
-- and only one of them shows up in a test that checks behavior. A feature can
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
--      nothing per frame by design: the gate geometry and colors are cached.
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

local draws, tris = 0, 0
debugDrawer = {
  drawCylinder  = function () draws = draws + 1 end,
  drawTextAdvanced = function () draws = draws + 1 end,
  drawQuadSolid = function () draws = draws + 1 end,
  -- The marker faces, counted SEPARATELY. A marker board is a tiled sign and
  -- nothing else in the mod draws a triangle, so keeping them apart is what
  -- lets the gate budget below stay a gate budget: one 20m board is ~80 filled
  -- marks, which would swamp a shared counter and make "does this scale with
  -- the route" unreadable.
  drawTriSolid  = function () tris = tris + 1 end,
}
-- Packed colors for drawTriSolid. The renderer guards on `color` being a
-- function and skips the marker fills when it is not, so leaving it out would
-- quietly measure a cheaper marker than the game draws.
color = function () return 0 end

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
-- The route payload is kept, not just counted: it is how this file checks the
-- fixture below actually LOADED, which is the difference between a budget and
-- a budget on an empty track.
local routeState = nil
guihooks = { trigger = function (event, payload)
  pushes[event] = (pushes[event] or 0) + 1
  pushTotal = pushTotal + 1
  if event == 'RaceManagerRoute' then routeState = payload end
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

-- `jokerEnabled` defaults ON here, and that is the point: it is a field the
-- extension only ever reads from this payload (session.jokerEnabled), so a
-- harness that never sent it measured a circuit whose joker gates were on the
-- track and never drawn. The joker glyph was outside every budget in this file.
local function serverState(t)
  t.rmProtocol = 2
  if t.jokerEnabled == nil then t.jokerEnabled = true end
  handlers['RM_Update'](t)
end
local function resetCounters() pushes, pushTotal, allocs, draws, tris = {}, 0, 0, 0, 0 end

-- ---------------------------------------------------------------------------
-- A realistic circuit: twelve checkpoints, a joker route, a pit lane, a
-- direction marker and a grid slot.
--
-- EVERY KEY HERE HAS TO MATCH WHAT onApplyLayout READS. The pit stalls were
-- sent as `pit` where the handler reads `pits`, so track.pitRoute stayed empty
-- for the life of this file: paint.pitBox is drawn for a DRIVER (the nearest
-- stall, every frame of every session) and it was the largest uncached
-- allocator in the mod, sitting outside the allocation budget three lines of
-- this file claim to be enforcing. A typo in a fixture is not a small bug in a
-- test whose whole job is to notice cost.
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
  pits  = { { x = -30, y = 200, z = 0, hx = 0, hy = 1 } },
  markers = { { x = -20, y = 500, z = 0, hx = 0, hy = 1, kind = 'right' } },
  startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 } },
})
-- The fixture is only worth what it actually loaded. These assert the layout
-- reached the models, so a future rename of a payload key fails here with the
-- reason rather than silently making every budget below cheaper.
check(routeState ~= nil, 'the layout was applied and pushed a route state')
check(#(routeState.pitRoute or {}) == 1,
  'the fixture pit lane loaded: the payload key is `pits`, not `pit`')
check(#(routeState.jokerRoute or {}) == 2, 'the fixture joker route loaded')
check(#(routeState.markers or {}) == 1, 'the fixture direction marker loaded')
check(#(routeState.waypoints or {}) == 12, 'the fixture checkpoints loaded')

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
-- 2b. A HELD GRID, with a car drifting off its slot
-- ---------------------------------------------------------------------------
-- The grid hold is the one steady state with a NOTICE inside a per-frame
-- function: a car off its slot is put back every frame (deliberately -- landing
-- on the same anchor is idempotent, and a car whose freeze will not take must
-- not be allowed to ratchet forward), and only the talking about it is
-- throttled, on hold.correctLeft.
--
-- That throttle got twice as important when notices started reaching BeamNG's
-- Messages HUD app as well as the app's own strip: every pushNotice is two
-- pushes across the boundary now, not one. A regression here would be a driver
-- on the grid taking a hundred and twenty pushes a second while the lights are
-- still out -- the worst possible moment, and the one nothing else measures.
--
-- ui_message is deliberately NOT stubbed anywhere in this file. Without it
-- hudMessage falls through to guihooks.trigger('Message', ...), which this
-- harness counts like any other push -- so the HUD channel is inside every
-- budget here rather than invisible to all of them.
serverState({ phase = 'grid', sessionKind = 'race', totalLaps = 5,
  maxResets = -1, flag = 'green', drivers = {} })
handlers['RM_GridAssign']({ slot = 1, x = 0, y = 0, z = 0, hx = 0, hy = 1, hold = true })
resetCounters()
for _ = 1, 60 do
  -- Shoved off the slot every frame, which is the worst case the hold sees.
  veh.x = veh.x + 2
  RM.onUpdate(1 / 60)
end
check(pushTotal <= 12, string.format(
  'a second of a held grid with a drifting car costs %d UI pushes (budget 12): '
    .. 'the correction runs per frame, the notice about it does not', pushTotal))
check((pushes['Message'] or 0) <= 4, string.format(
  'and reaches the Messages HUD app %d times (budget 4): a notice is two '
    .. 'pushes now, so an unthrottled one costs double',
  pushes['Message'] or 0))
local heldPushes, heldMessages = pushTotal, pushes['Message'] or 0

-- ---------------------------------------------------------------------------
-- 3. The draw loop: two gates, and nothing rebuilt per frame
-- ---------------------------------------------------------------------------
serverState({ phase = 'racing', sessionKind = 'race', totalLaps = 5,
  maxResets = -1, flag = 'green', drivers = {} })
RM.onUpdate(1 / 60)          -- prime the caches
resetCounters()
RM.onUpdate(1 / 60)
local steadyAllocs, steadyDraws, steadyTris = allocs, draws, tris

-- A DRIVER SEES TWO GATES. Twelve checkpoints, a joker and a pit stall are on
-- the track; what gets drawn is the armed gate, the one after it, and whichever
-- joker or pit furniture applies. If this scales with the route the whole lap is
-- being painted across the racing line.
check(steadyDraws <= 24, string.format(
  'a steady frame draws %d shapes on a twelve-gate circuit, not the whole lap '
    .. '(budget 24)', steadyDraws))

-- The marker board, which is the only thing here that draws triangles. Its
-- cost is bounded by TUNE.MARKER_MAX_MARKS (60) rather than by the board's
-- size, which is the property worth pinning: an admin who drags a marker forty
-- meters wide gets a denser sign, not an unbounded one.
check(steadyTris <= 4 * 60, string.format(
  'the marker board fills %d triangles, capped by MARKER_MAX_MARKS rather than '
    .. 'by how wide the board was drawn', steadyTris))

-- Immediate-mode drawing that allocates is drawing that feeds the collector on
-- the render thread. The geometry and the colors are both cached.
--
-- ZERO. This budget was 1 for a long time, for a reason that had stopped being
-- true: checkGates keeps last frame's position so it has a segment to test
-- gates against, and that carry-over sample was `vec3(pos.x, pos.y, pos.z)`
-- every frame. Every consumer of it reads .x/.y/.z and nothing else -- no vec3
-- method, no operator, and none of them keeps the reference -- so it is a plain
-- table mutated in place now and a driver's frame allocates NOTHING AT ALL.
--
-- Which makes this the strictest form of the property it was always pinning: a
-- steady frame builds no garbage, so anything that appears here is new work
-- somebody added to the per-frame path.
check(steadyAllocs == 0, string.format(
  'a steady frame allocates %d vectors/colors, and the budget is 0: the draw '
    .. 'path caches its geometry and the crossing detector reuses its sample',
  steadyAllocs))

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
check(allocs == 0, string.format(
  'and allocates %d on the bigger circuit too', allocs))

-- ---------------------------------------------------------------------------
-- 4. THE EDITOR, which nothing in this file used to open
-- ---------------------------------------------------------------------------
-- A driver sees two gates. An ADMIN with the editor open sees the whole circuit
-- at once, numbered and labeled, plus every branch gate, pit stall, marker and
-- grid slot: it is far and away the heaviest draw pass in the mod, and it was
-- outside every budget in this file because perf_test never called
-- setEditorOpen. draw_test.lua opens the editor but counts shapes and colors,
-- not cost, so the entire authoring path was unmeasured.
--
-- It is measured on the SAME terms as the driver's frame, because the same rule
-- applies: the labels and the geometry are fixed by the layout, so an editor
-- frame on a circuit nobody is touching has nothing to build.
-- A FULL GRID, staggered, because drawStartPosition runs per slot per frame and
-- the authoring pass costs what the grid is long. A one-slot fixture would have
-- measured the cheapest possible version of the thing that was actually
-- expensive here.
local starts = {}
for i = 1, 24 do
  starts[i] = { x = (i % 2 == 0) and 4 or -4, y = -i * 6, z = 0, hx = 0, hy = 1 }
end
handlers['RM_ApplyLayout']({
  name = 'perf', width = 20, height = 8, depth = 2,
  checkpoints = cps,
  joker = { { x = 30, y = 300, z = 0, hx = 0, hy = 1 },
            { x = 30, y = 400, z = 0, hx = 0, hy = 1 } },
  pits  = { { x = -30, y = 200, z = 0, hx = 0, hy = 1 } },
  markers = { { x = -20, y = 500, z = 0, hx = 0, hy = 1, kind = 'right' } },
  branches = { { slot = 3, x = 15, y = 300, z = 0, hx = 0, hy = 1 } },
  startPositions = starts,
})
serverState({ phase = 'waiting', sessionKind = 'race', totalLaps = 5,
  maxResets = -1, flag = 'green', drivers = {}, youAreAdmin = true })
RM.setEditorOpen(true)
RM.onUpdate(1 / 60)          -- prime the caches
check(#(routeState.startPositions or {}) == 24,
  'the fixture grid loaded, so the slot markers are actually being drawn')
check(#(routeState.branches or {}) == 1, 'the fixture branch gate loaded')
resetCounters()
RM.onUpdate(1 / 60)
local editAllocs, editDraws, editTris = allocs, draws, tris

-- THE SAME ZERO. Twelve gates, a branch gate, two joker gates, a pit stall, a
-- marker and twenty-four grid slots, all labeled, and a steady editor frame
-- builds nothing: the gate corners, the slot outlines, the stall box and every
-- label string are cached against the thing they describe and rebuilt only when
-- it moves.
--
-- This is where the authoring path used to spend it. drawStartPosition alone
-- was nine vec3, a ColorF and a fresh 'P<n>' string per slot per frame -- on a
-- twenty-four car grid that is ~250 objects a frame, thrown at the collector
-- while an admin drags a gate around.
check(editAllocs == 0, string.format(
  'a steady EDITOR frame allocates %d vectors/colors, and the budget is 0: the '
    .. 'authoring path caches its geometry and its labels like the driver path '
    .. 'does', editAllocs))

-- The editor DOES draw the whole circuit, and that is correct: it is the view
-- whose entire job is showing everything at once. What this pins is that it
-- costs what those items cost and no more -- no per-frame rebuild, and no
-- second pass over the route.
-- ~343 as it stands: twelve gates and two joker gates at nine shapes each
-- (filled face, four edges, a label and a three-piece direction arrow), a
-- branch gate, a pit stall at twelve, twenty-four grid slots at eight, and the
-- marker's two posts. The budget is that plus headroom, and it is a budget on
-- the ITEMS rather than on the route: check 3's scaling test is what catches
-- the whole lap being painted.
check(editDraws <= 380, string.format(
  'a steady editor frame draws %d shapes on a twelve-gate circuit with a '
    .. 'twenty-four car grid (budget 380)', editDraws))

RM.setEditorOpen(false)

print(string.format('perf_test: %d checks, %d failures', checks, fails))
print(string.format('  held grid: %d UI pushes/sec (%d to the Messages app)',
  heldPushes, heldMessages))
print(string.format('  racing: %d UI pushes/sec, %d draws + %d tris/frame, %d allocs/frame',
  racingPushes, steadyDraws, steadyTris, steadyAllocs))
print(string.format('  editor: %d draws + %d tris/frame, %d allocs/frame',
  editDraws, editTris, editAllocs))
if fails > 0 then os.exit(1) end
