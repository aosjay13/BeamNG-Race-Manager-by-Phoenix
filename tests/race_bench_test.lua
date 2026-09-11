-- END TO END BENCHMARK: one real race night, both halves of the mod, measured.
--
-- 16 drivers, 20 laps, a SIXTY SECOND lap. That last number is the whole reason
-- this file exists next to stress_test.lua rather than inside it.
--
-- stress_test runs 20 drivers over 50 laps at 20 s a lap, which is the right
-- shape for finding drift and leaks: it wants as many lap crossings as it can
-- get. But a 20 s lap spends a third of its ticks near a checkpoint, and the
-- cost of a lap crossing is not the cost this mod actually pays. A real race is
-- twelve hundred ticks of NOTHING HAPPENING for every one that matters, and the
-- per-tick floor across a full field is what a low end machine feels.
--
-- And stress_test measures only the server. perf_test measures only the client,
-- against a state it makes up. Neither answers the question a league actually
-- asks: with sixteen cars circulating, what does the person in the slowest PC on
-- the grid pay, per frame, for the whole twenty minutes?
--
-- So this runs the server race for real, KEEPS THE WIRE PAYLOADS IT BROADCASTS,
-- and feeds those exact bytes to the real client extension with a real JSON
-- decoder. The client's decode is part of the measurement, because on the day it
-- is part of the frame. A harness that hands the client a ready-made Lua table
-- measures a client that does not exist.
--
-- Run from the repo root: lua tests/race_bench_test.lua

local DRIVERS        = 16      -- a league grid
local LAPS           = 20
local LAP_TICKS      = 600     -- 60 s at the server's 100 ms tick: a real lap
local PROGRESS_EVERY = 3       -- driver telemetry ~3 Hz, what the bridge sends
local FRAME_HZ       = 60      -- what the client renders at

-- Never a literal backslash anywhere in this file: it is written and rewritten
-- through shells and heredocs that eat them, and a JSON codec with a mangled
-- escape class silently stops escaping. Built from its character code instead.
local BS = string.char(92)

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- A real JSON codec. Both halves get the real one, for the same reason.
-- ---------------------------------------------------------------------------
local function jsonEncode(v)
  local t = type(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'number' then return string.format('%.10g', v) end
  if t == 'string' then
    return '"' .. v:gsub('[%c"' .. BS .. ']', function (c)
      if c == '"' then return BS .. '"' end
      if c == BS then return BS .. BS end
      return string.format(BS .. 'u%04x', c:byte())
    end) .. '"'
  end
  if t == 'table' then
    local parts = {}
    if #v > 0 or next(v) == nil then
      for _, item in ipairs(v) do parts[#parts + 1] = jsonEncode(item) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, item in pairs(v) do
      if type(k) == 'string' then
        parts[#parts + 1] = jsonEncode(k) .. ':' .. jsonEncode(item)
      end
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

local function jsonDecode(text)
  if type(text) ~= 'string' then error('json: not a string', 0) end
  local pos = 1
  local function ws() pos = text:match('^[ \t\r\n]*()', pos) end
  local parseValue
  local function parseString()
    pos = pos + 1
    local out = {}
    while true do
      local c = text:sub(pos, pos)
      if c == '' then error('json: unterminated string', 0) end
      if c == '"' then pos = pos + 1; break end
      if c == BS then out[#out + 1] = text:sub(pos + 1, pos + 1); pos = pos + 2
      else out[#out + 1] = c; pos = pos + 1 end
    end
    return table.concat(out)
  end
  parseValue = function ()
    ws()
    local c = text:sub(pos, pos)
    if c == '"' then return parseString() end
    if c == '{' then
      pos = pos + 1; local obj = {}; ws()
      if text:sub(pos, pos) == '}' then pos = pos + 1; return obj end
      while true do
        ws(); local k = parseString(); ws(); pos = pos + 1
        obj[k] = parseValue(); ws()
        local sep = text:sub(pos, pos); pos = pos + 1
        if sep == '}' then return obj end
      end
    end
    if c == '[' then
      pos = pos + 1; local arr = {}; ws()
      if text:sub(pos, pos) == ']' then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parseValue(); ws()
        local sep = text:sub(pos, pos); pos = pos + 1
        if sep == ']' then return arr end
      end
    end
    local lit = text:match('^true', pos) or text:match('^false', pos) or text:match('^null', pos)
    if lit then
      pos = pos + #lit
      if lit == 'true' then return true elseif lit == 'false' then return false end
      return nil
    end
    local num, nextPos = text:match('^(%-?%d+%.?%d*[eE]?[%+%-]?%d*)()', pos)
    if num then pos = nextPos; return tonumber(num) end
    error('json: unexpected character at ' .. pos, 0)
  end
  return parseValue()
end

-- ===========================================================================
-- PHASE 1: THE SERVER, running a real twenty minute race
-- ===========================================================================
local connected = {}
for i = 1, DRIVERS do connected[i] = string.format('Guest_%03d', i) end

local broadcasts, encodedBytes = 0, 0
-- THE WIRE PAYLOADS THEMSELVES, kept for phase 2. Not a sample of one: the
-- state a client gets on lap 1 with a field still bunched is not the state it
-- gets on lap 19 with cars lapped, retired and spread out, and the second is
-- the bigger table. Taking the first and calling it typical would measure the
-- cheap end of the race and report it as the cost.
local wire = {}
local wireCap = 400

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (_, event, payload)
    if event == 'RM_Update' then
      broadcasts = broadcasts + 1
      encodedBytes = encodedBytes + #payload
      -- Reservoir-ish: keep an even spread across the whole race rather than
      -- the first N, so phase 2 sees early, middle and late states.
      if #wire < wireCap then
        wire[#wire + 1] = payload
      elseif broadcasts % 7 == 0 then
        wire[(broadcasts % wireCap) + 1] = payload
      end
    end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
  RemoveVehicle = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/gridmap_v2/info.json' end,
}
Util = { JsonEncode = jsonEncode, JsonDecode = jsonDecode }

local function removeTree(path)
  if package.config:sub(1, 1) == BS then
    os.execute('rmdir /s /q "' .. path:gsub('/', BS) .. '" 2>nul')
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end
removeTree('Resources')

dofile('server/RaceManager/main.lua')
onInit()

local ADMIN = 99
connected[ADMIN] = 'Admin'
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onLogin(ADMIN, '{"password":"phoenix"}')

-- One race, tick by tick, the way the server actually runs one. Returns CPU for
-- the first and second halves separately: the two must be comparable, or the
-- plugin is getting more expensive as laps accumulate and a long race is a
-- different product from a short one.
local function runRace(laps)
  RM_onSetTotalLaps(ADMIN, '{"laps":' .. laps .. '}')
  RM_onGenerateGrid(ADMIN)
  RM_onStartCountdown(ADMIN)
  for _ = 1, 4 do RM_CountdownTick() end

  local halfway = math.floor(laps / 2)
  local firstHalf, secondHalf, ticks = 0, 0, 0
  for lap = 1, laps do
    local started = os.clock()
    for t = 1, LAP_TICKS do
      RM_Tick()
      ticks = ticks + 1
      if t % PROGRESS_EVERY == 0 then
        for pid = 1, DRIVERS do
          RM_onProgress(pid, string.format(
            '{"lap":%d,"cp":%d,"dist":%.1f}', lap, (t * 8) // LAP_TICKS, 3600 - t * 6))
        end
      end
    end
    -- The field crosses the line a few milliseconds apart, in an order that
    -- shuffles lap to lap so the comparator is exercised rather than handed the
    -- same answer twenty times.
    for i = 1, DRIVERS do
      local pid = ((lap + i) % DRIVERS) + 1
      RM_Tick()
      RM_onLap(pid, string.format('{"lapTime":%.3f}', 60 + (i % 7) * 0.35))
    end
    local spent = os.clock() - started
    if lap <= halfway then firstHalf = firstHalf + spent else secondHalf = secondHalf + spent end
  end
  RM_onEndRace(ADMIN)
  return firstHalf, secondHalf, ticks
end

print(string.format('race_bench: %d drivers, %d laps, %.0f s laps (%d ticks/lap)',
  DRIVERS, LAPS, LAP_TICKS / 10, LAP_TICKS))

-- Warm up and throw away: the first race grows the heap to its working size and
-- interns every format string, and charging that to the measurement flatters
-- nothing and confuses everything.
runRace(3)

collectgarbage(); collectgarbage()
local heapStart = collectgarbage('count')
broadcasts, encodedBytes, wire = 0, 0, {}
local first, second, ticks = runRace(LAPS)
collectgarbage(); collectgarbage()
local heapGrowth = collectgarbage('count') - heapStart

local serverCpu = first + second
local simSeconds = ticks / 10.0
print(string.format('  SERVER   %.3fs CPU for %.0fs of racing  (%.2f%% of one core)',
  serverCpu, simSeconds, serverCpu / simSeconds * 100))
print(string.format('           %d broadcasts, %.1f/s, %.1f KB/s on the wire',
  broadcasts, broadcasts / simSeconds, encodedBytes / simSeconds / 1024))
print(string.format('           drift %.2fx first half to second, heap +%.0f KB',
  second / math.max(first, 1e-9), heapGrowth))

-- ===========================================================================
-- PHASE 2: THE CLIENT, fed the exact bytes the server just sent
-- ===========================================================================
-- Everything below runs against payload STRINGS captured above, decoded by the
-- real decoder, because on the day the decode happens on the render thread and
-- it is part of what a frame costs. perf_test hands the extension a ready made
-- Lua table, which is right for what perf_test is asking and wrong here.
local allocs = 0
local vec3mt = {}
vec3mt.__index = vec3mt
vec3mt.__add = function (a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
vec3mt.__mul = function (a, s) return vec3(a.x * s, a.y * s, a.z * s) end
vec3 = function (x, y, z)
  allocs = allocs + 1
  return setmetatable({ x = x, y = y, z = z }, vec3mt)
end
quat   = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
ColorF = function (r, g, b, a) allocs = allocs + 1; return { r, g, b, a } end
ColorI = function (r, g, b, a) allocs = allocs + 1; return { r, g, b, a } end
String = function (s) return s end

local draws, tris = 0, 0
debugDrawer = {
  drawCylinder     = function () draws = draws + 1 end,
  drawTextAdvanced = function () draws = draws + 1 end,
  drawQuadSolid    = function () draws = draws + 1 end,
  drawTriSolid     = function () tris = tris + 1 end,
}
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
core_vehicle_partmgmt  = { getConfig = function () return { parts = {}, vars = {} } end }
log = function () end

local pushes, pushTotal = {}, 0
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
-- The GLOBALS the extension reaches for. Real ones, not identities.
_G.jsonEncode = jsonEncode
_G.jsonDecode = jsonDecode
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

-- The same realistic circuit perf_test uses: twelve checkpoints, a joker route,
-- a full twelve stall pit lane, a direction marker, and a grid deep enough for
-- the whole field.
local cps, pits, grid = {}, {}, {}
for i = 1, 12 do cps[i]  = { x = 0,   y = i * 100,      z = 0, hx = 0, hy = 1 } end
for i = 1, 12 do pits[i] = { x = -30, y = 100 + i * 12, z = 0, hx = 0, hy = 1 } end
for i = 1, DRIVERS do
  grid[i] = { x = (i % 2 == 0) and 4 or -4, y = -i * 8, z = 0, hx = 0, hy = 1 }
end
-- ENCODED, not handed over as a table. The decoder above is the real one, and
-- the real one refuses anything that is not a string -- which is correct, and is
-- exactly what the extension gets on the wire. Passing a Lua table here is the
-- shortcut every other suite takes, and it would have measured a client that
-- never parses anything.
handlers['RM_ApplyLayout'](jsonEncode({
  name = 'bench', width = 20, height = 8, depth = 2,
  checkpoints = cps,
  joker = { { x = 30, y = 300, z = 0, hx = 0, hy = 1 },
            { x = 30, y = 400, z = 0, hx = 0, hy = 1 } },
  pits = pits,
  markers = { { x = -20, y = 500, z = 0, hx = 0, hy = 1, kind = 'right' } },
  startPositions = grid,
}))
check(routeState ~= nil and #(routeState.waypoints or {}) == 12,
  'the benchmark circuit loaded on the client')
check(#(routeState.pitRoute or {}) == 12, 'with its full pit lane')
check(#(routeState.startPositions or {}) == DRIVERS,
  'and a grid slot for all ' .. DRIVERS .. ' drivers')
check(#wire > 50, 'the server phase captured a spread of real wire payloads (got '
  .. #wire .. ')')

local function resetCounters() pushes, pushTotal, allocs, draws, tris = {}, 0, 0, 0, 0 end

-- Sixty frames a second, with the real broadcasts arriving at the rate the
-- server actually sent them, cycled through early, middle and late race states.
local broadcastHz = broadcasts / simSeconds
local function runClient(seconds, payloads)
  resetCounters()
  local frames = math.floor(seconds * FRAME_HZ)
  local everyN = FRAME_HZ / broadcastHz
  local nextAt, idx = 1, 0
  local t0 = os.clock()
  for f = 1, frames do
    if f >= nextAt then
      idx = idx % #payloads + 1
      handlers['RM_Update'](payloads[idx])
      nextAt = f + everyN
    end
    veh.y = veh.y + 0.6          -- 36 m/s, so gates are genuinely crossed
    RM.onUpdate(1 / FRAME_HZ)
  end
  return os.clock() - t0, frames
end

-- A ONE DRIVER payload of the same shape, for the comparison that actually
-- answers "does a full grid cost the client anything". Built by trimming a real
-- late race state rather than inventing one, so the two differ in field size and
-- in nothing else.
local sample = jsonDecode(wire[#wire])
local soloTbl = jsonDecode(wire[#wire])
soloTbl.drivers = { sample.drivers and sample.drivers[1] or {} }
local solo = jsonEncode(soloTbl)
local fieldBytes, soloBytes = #wire[#wire], #solo

check(type(sample.drivers) == 'table' and #sample.drivers >= DRIVERS,
  'the captured state really carries the whole field (got '
    .. tostring(sample.drivers and #sample.drivers) .. ')')

-- Prime: first frames build the gate caches, and charging that to the steady
-- state would report a cost the driver pays once as one they pay always.
runClient(2, wire)

local fieldCpu, frames = runClient(10, wire)
local fieldPushes, fieldDraws, fieldTris, fieldAllocs = pushTotal, draws, tris, allocs
check(fieldPushes > 0, 'the client actually processed the real wire payloads: a '
  .. 'protocol mismatch would leave it idle and every budget below trivially met')

local soloCpu = runClient(10, { solo })
local soloPushes = pushTotal

print(string.format('  CLIENT   %d drivers: %.1f pushes/s, %.1f draws/frame, '
  .. '%.1f tris/frame, %.2f allocs/frame',
  DRIVERS, fieldPushes / 10, fieldDraws / frames, fieldTris / frames, fieldAllocs / frames))
print(string.format('           %.3f ms of Lua per frame, payload %.1f KB decoded %.1f/s',
  fieldCpu / frames * 1000, fieldBytes / 1024, broadcastHz))
print(string.format('           1 driver : %.1f pushes/s, %.3f ms/frame, payload %.1f KB',
  soloPushes / 10, soloCpu / frames * 1000, soloBytes / 1024))
print(string.format('           full grid costs %.2fx a single car per frame',
  fieldCpu / math.max(soloCpu, 1e-9)))

-- ===========================================================================
-- THE BUDGETS
-- ===========================================================================
-- Set with roughly 3x headroom over what this measures today, deliberately. A
-- budget pinned to the current number fails on a faster or slower machine and
-- gets deleted; one with no headroom at all is a number nobody trusts. These are
-- meant to catch a change of KIND -- work that now happens per frame, or per
-- driver, or that grows with laps -- not a ten percent drift.

-- SERVER. The plugin shares a box with BeamMP itself, so the figure that matters
-- is what fraction of a core a whole race costs.
local serverPct = serverCpu / simSeconds * 100
check(serverPct < 1.0, string.format(
  'a %d driver, %d lap race costs %.2f%% of one core on the server (budget 1%%)',
  DRIVERS, LAPS, serverPct))
check(second / math.max(first, 1e-9) < 1.35, string.format(
  'the second half of the race costs the same as the first (%.2fx, budget 1.35x): '
    .. 'work that grows with laps completed is invisible in a short race and '
    .. 'fatal in a twenty lap one', second / math.max(first, 1e-9)))
check(heapGrowth < 2048, string.format(
  'a whole race leaves %.0f KB behind after collection (budget 2048 KB)', heapGrowth))

-- CLIENT. The number a driver actually feels is milliseconds of Lua per frame:
-- at 60 fps the whole frame is 16.7 ms and this mod is a guest in it.
local msPerFrame = fieldCpu / frames * 1000
check(msPerFrame < 0.5, string.format(
  'the client spends %.3f ms of Lua per frame with a full grid (budget 0.5 ms, '
    .. 'against a 16.7 ms frame)', msPerFrame))
check(fieldPushes / 10 <= 20, string.format(
  'a second of racing costs %.1f UI pushes with %d drivers, not one per frame '
    .. '(budget 20)', fieldPushes / 10, DRIVERS))
check(fieldAllocs / frames < 2, string.format(
  'the draw path allocates %.2f vectors per frame (budget 2): the gate geometry '
    .. 'and colors are cached, and churning here hands work to the collector on '
    .. 'the render thread', fieldAllocs / frames))

-- THE SCALING QUESTION, and the reason this file exists at all. Sixteen cars
-- must not cost sixteen times one car. Everything the client draws is the
-- DRIVER'S OWN two gates -- it does not draw the circuit and it does not draw
-- the field -- so the only thing a full grid adds is a longer leaderboard to
-- decode and push. If this ratio ever approaches the field size, something has
-- started iterating the grid every frame.
local scaling = fieldCpu / math.max(soloCpu, 1e-9)
check(scaling < 4.0, string.format(
  '%d drivers cost %.2fx what one costs per frame, not %dx (budget 4x): the '
    .. 'client draws its own gates, not the field', DRIVERS, scaling, DRIVERS))

-- DRAW CALLS. A driver sees the gate they are approaching and the one after,
-- plus the pit lane and any marker in range. Not the lap.
check(fieldDraws / frames < 120, string.format(
  '%.1f draw calls per frame (budget 120): if this grows with route length, '
    .. 'somebody has drawn the whole circuit', fieldDraws / frames))
-- Marker faces are counted apart from gates because one signboard is ~60 tiled
-- marks and would swamp a shared counter. It is the largest single thing the
-- client draws, so it gets its own line rather than hiding inside the total.
check(fieldTris / frames < 400, string.format(
  '%.1f marker triangles per frame (budget 400): a direction marker is a tiled '
    .. 'signboard and is the biggest draw on the client', fieldTris / frames))

if fails == 0 then
  print(string.format('race_bench_test: %d checks, 0 failures', checks))
else
  print(string.format('race_bench_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
