-- Headless test for WHEN THE START/FINISH LINE MAY END AN OUT LAP.
--
-- The out lap has a special rule: crossing the line ends it from wherever the
-- driver has got to, with checkpoints still owing. That exists for a head-on
-- layout, which spreads its grid round the circuit, so a car gridded PAST slot 1
-- clears nothing on its way to the line and would otherwise have to run on to
-- slot 1 before its lap could start.
--
-- On an ORDINARY circuit the grid sits just behind the start/finish line, so the
-- line is the first gate a driver reaches. The rule fired seconds after the
-- green with nothing cleared, which ended the out lap and started timing. From a
-- live log: out laps "completed" in 2.1s, 2.4s, 4.4s and 5.6s. The formation lap
-- is mechanically an out lap, so the same crossing dropped the green the instant
-- the leader rolled over the line.
--
-- Nothing covered this. out_lap_test drives the SERVER through RM_Lap events;
-- the rule lives in the client's gate loop, which is why it could come back.
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

-- The lap-done pushes this file rules on, and the telemetry payload beside them.
local lapsDone = {}
local lastProgress = nil
local realTrigger = guihooks.trigger
guihooks.trigger = function (event, payload)
  if event == 'RaceManagerLapDone' then lapsDone[#lapsDone + 1] = payload end
  if event == 'RaceManagerProgress' then lastProgress = payload end
  return realTrigger(event, payload)
end

local function drive(toY, step)
  step = step or 5
  while veh.y < toY do
    veh.y = math.min(veh.y + step, toY)
    RM.onUpdate(0.016)
  end
end

-- PAST THE DOUBLE-FIRE GUARD. onLapCompleted discards any lap shorter than
-- TUNE.LAP_DEBOUNCE (2s), so a harness that drives 50 m in ten 16 ms frames has
-- every crossing thrown away and tests nothing at all. Stand still for three
-- seconds first, which is also what a real car does: it takes a couple of
-- seconds to reach a line a few metres ahead, which is exactly how the bug was
-- reported (out laps "completed" in 2.1s).
local function settle()
  for _ = 1, 200 do RM.onUpdate(0.016) end
end

-- ---------------------------------------------------------------------------
-- 1. THE GRID SITS BEHIND THE LINE, which is every ordinary circuit
-- ---------------------------------------------------------------------------
-- Route order puts the start/finish LAST, so a grid a few metres behind it means
-- the line is the first gate the car meets. Crossing it has driven no route and
-- must not end anything.
local cps = {}
for i = 1, 11 do cps[i] = { x = 0, y = 1000 + i * 100, z = 0, hx = 0, hy = 1 } end
cps[12] = { x = 0, y = 50, z = 0, hx = 0, hy = 1 }   -- the start/finish line
handlers['RM_ApplyLayout']({
  name = 'grid behind the line', width = 20, height = 8, depth = 2,
  checkpoints = cps,
  startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 } },
})
check(#(routeState.waypoints or {}) == 12, 'the fixture loaded')

veh.x, veh.y, veh.z = 0, 0, 0
serverState({ phase = 'qualifying', qualiOutLap = true, drivers = {} })
RM.onUpdate(0.016)
lapsDone = {}
settle()
drive(200)          -- straight over the line, nothing else cleared
check(#lapsDone == 0,
  'crossing the start/finish with NOTHING cleared does not end the out lap: a '
    .. 'line you have not driven a route to is not a completed lap')

-- And it keeps not ending it, however long the driver sits past it.
drive(900)
check(#lapsDone == 0, 'and it stays unended while the driver runs up to slot 1')

-- Now the real lap: slots 1 through 11, then back over the line.
drive(2100)
check(#lapsDone == 0, 'still nothing while the route is being cleared')
veh.y = 0                       -- round to the line again
RM.onUpdate(0.016)
drive(200)
check(#lapsDone == 1 and lapsDone[1].outLap == true,
  'the out lap ends when the driver reaches the line having ACTUALLY gone round')

-- ---------------------------------------------------------------------------
-- 2. A CAR GRIDDED PAST SLOT 1 IS NOT STRANDED
-- ---------------------------------------------------------------------------
-- The shortcut existed for a head-on layout, which spreads its grid round the
-- circuit: such a car clears nothing on the way to the line. It no longer gets
-- to end its out lap there, and it does not need to. It runs on to slot 1 and
-- starts its lap from the gate, which is a LONGER out lap and never a backwards
-- one. Waiving the rule on geometry instead (gridIsOff is a 250 m distance test)
-- would have let a grid set further back down the straight keep the old bug.
serverState({ phase = 'waiting', drivers = {} })
RM.onUpdate(0.016)
local cps2 = {}
for i = 1, 11 do cps2[i] = { x = 0, y = 1000 + i * 100, z = 0, hx = 0, hy = 1 } end
cps2[12] = { x = 0, y = 50, z = 0, hx = 0, hy = 1 }
handlers['RM_ApplyLayout']({
  name = 'gridded past slot 1', width = 20, height = 8, depth = 2,
  checkpoints = cps2,
  startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 } },
})
veh.x, veh.y, veh.z = 0, 0, 0
serverState({ phase = 'qualifying', qualiOutLap = true, drivers = {} })
RM.onUpdate(0.016)
lapsDone = {}
settle()
drive(200)
check(#lapsDone == 0,
  'reaching the line with nothing cleared no longer ends the out lap, whatever '
    .. 'the grid geometry: that threshold was the bug wearing a different hat')
drive(1150)
check(#lapsDone == 0, 'and it is still running as the car reaches slot 1')

-- ---------------------------------------------------------------------------
-- 3. ONE CLEARED CHECKPOINT IS NOT A LAP EITHER
-- ---------------------------------------------------------------------------
-- The rule above was once "the line ends the out lap once at least one
-- checkpoint is cleared", which fixed section 1 and left the same bug one gate
-- further along. Reported from a real qualifying session: start quali, clear
-- slot 1, turn round, cross the start/finish, and the out lap was announced as
-- complete with ten gates never driven.
--
-- The tell was on screen the whole time. The renderer lights `armedWp`, so the
-- lap ended on a gate that was not the lit one -- which is what a shortcut that
-- accepts a gate the driver is not being sent to always looks like, at any
-- threshold. There is no version of the rule left.
serverState({ phase = 'waiting', drivers = {} })
RM.onUpdate(0.016)
local cps3 = {}
for i = 1, 11 do cps3[i] = { x = 0, y = 1000 + i * 100, z = 0, hx = 0, hy = 1 } end
cps3[12] = { x = 0, y = 50, z = 0, hx = 0, hy = 1 }
handlers['RM_ApplyLayout']({
  name = 'back to the line after slot 1', width = 20, height = 8, depth = 2,
  checkpoints = cps3,
  startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 } },
})
veh.x, veh.y, veh.z = 0, 0, 0
serverState({ phase = 'qualifying', qualiOutLap = true, drivers = {} })
RM.onUpdate(0.016)
lapsDone = {}
settle()

-- Out over the line (nothing cleared) and on to slot 1, which IS cleared.
drive(1150)
check(#lapsDone == 0, 'the out lap is running with slot 1 cleared')
check(routeState.nextWp == 2, 'and slot 2 is the gate the driver is being sent to')

-- ---------------------------------------------------------------------------
-- WHAT `dist` MEASURES ON AN OUT LAP, which is NOT the gate that is armed.
-- ---------------------------------------------------------------------------
-- It is metres to the START/FINISH LINE, for the whole of an out lap and only
-- then. That reads like a bug sitting next to `cp`, which counts progress along
-- the route -- two halves of one payload measuring different gates -- and it was
-- "fixed" to the armed gate once on exactly that reasoning.
--
-- THE PACE LAP IS WHAT CONSUMES IT. A pace lap is mechanically an out lap, and
-- paceLapWatch on the server waves the green off this number as
-- distance-to-the-line. Pointed at the armed gate it dropped the green as the
-- leader reached checkpoint 1: a formation lap that ended at the first corner.
--
-- Asserted here rather than left to a comment, because the server-side test that
-- covers the green (tests/pace_test.lua) feeds RM_onProgress by hand and so
-- cannot see which gate this side measured.
--
-- The car is at y=1150. Slot 2 is at y=1200, fifty metres ahead and armed. The
-- line is at y=50, eleven hundred metres behind. The two numbers are far enough
-- apart that nothing about this check is a rounding question.
check(lastProgress ~= nil, 'telemetry is being reported on the out lap')
check(lastProgress and lastProgress.dist and lastProgress.dist > 1000,
  'and `dist` is metres to the START/FINISH LINE (~1100), not to the armed gate '
    .. '(~50): the pace lap green is waved off this number, and measuring the '
    .. 'armed gate instead ends the formation lap at checkpoint 1')
check(lastProgress and lastProgress.cp == 1,
  'while `cp` counts the route: the two fields answer two questions on purpose')

-- Back round to the line and through it, exactly as reported.
veh.y = 0
RM.onUpdate(0.016)
settle()
drive(200)
check(#lapsDone == 0,
  'crossing the start/finish with ONE checkpoint cleared does not end the out '
    .. 'lap: an out lap is an ordinary lap that is not scored, and it takes the '
    .. 'same route as any other')
check(routeState.nextWp == 2,
  'and the armed gate has not moved, so the lap can only ever end on the gate '
    .. 'the driver can see lit')

-- It ends where every lap ends: having driven the route.
drive(2150)
check(#lapsDone == 0, 'still nothing part way round')
veh.y = 0
RM.onUpdate(0.016)
drive(200)
check(#lapsDone == 1 and lapsDone[1].outLap == true,
  'and the out lap completes on the line once all twelve gates are driven')

print(string.format('out_lap_line_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
