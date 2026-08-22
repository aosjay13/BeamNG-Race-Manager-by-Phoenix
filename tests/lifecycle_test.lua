-- Headless test: running events back to back leaves nothing behind.
--
-- The worry this answers is a reasonable one to have about a mod that draws a
-- circuit: after a race finishes and another starts, is anything from the first
-- still standing? A gate, a grid slot, a pit box, a joker gate, a timing state
-- that quietly makes the second race score differently from the first.
--
-- THE ARCHITECTURE ALREADY RULES OUT HALF THE QUESTION. Nothing here is a scene
-- object. There is no createObject anywhere in the mod: gates, grid slots, pit
-- stalls and arena walls are Lua tables redrawn every frame through the
-- immediate-mode debugDrawer, so there is no prop to leak, no trigger to
-- unregister and nothing to delete. What CAN survive is Lua state, and that is
-- what this measures.
--
-- The method is a diff rather than a checklist: run the same complete event
-- three times and compare what the client is left holding after each. A
-- checklist only covers the fields somebody thought of, and the residue that
-- matters is the field nobody did.
--
-- Run from the repo root: lua5.3 tests/lifecycle_test.lua

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
-- Left nil on purpose: the draw path returns without it, which keeps every
-- frame here on the state under test. See the note in flag_test.

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
-- Harness
-- ---------------------------------------------------------------------------
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end
local function frame(n) for _ = 1, (n or 1) do RM.onUpdate(0.05) end end
local function moveTo(y, x) veh.x, veh.y, veh.z = x or 0, y, 0; frame() end
-- A lap has to outlast TUNE.LAP_DEBOUNCE (2 s) or the crossing is discarded and
-- the lap counter never moves. Burned at 105, clear of the white-flag radius.
local function coast(s) frame(math.floor((s or 2.5) / 0.05 + 0.5)) end

local SF_Y = 200

-- A layout with one of everything, so a leak has something to leak.
local function loadCircuit()
  handlers['RM_ApplyLayout']({
    name = 'oval', width = 40, height = 10, depth = 2,
    checkpoints    = { { x = 0, y = 100, z = 0, hx = 0, hy = 1 },
                       { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 } },
    startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 } },
    joker          = { { x = 60, y = 150, z = 0, hx = 1, hy = 0 } },
    pits           = { { x = -60, y = 150, z = 0, hx = 1, hy = 0 } },
  })
end

local function lastRoute()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerRoute' then return hooks[i].payload end
  end
end

-- Everything the panel can see, flattened to comparable strings. Read off the
-- guihook rather than out of the extension: that payload IS what the panel
-- draws, so residue the test cannot see is residue a driver cannot see either.
local SCALARS = {
  'nextWp', 'width', 'height', 'depth', 'pointToPoint', 'gridSlot', 'gridFrozen',
  'pitActive', 'pitLeft', 'jokerNext', 'jokerTaken', 'jokerLap', 'jokerEnabled',
  'editorTarget', 'driverFlag', 'nudgeOn', 'nudgeSel', 'branchSlot', 'gridOffLine',
  'gridGenerated', 'gridSpacing', 'gridStagger', 'gridWidth', 'maxResets',
  'resetsUsed', 'visualize', 'isAdmin',
}
local LISTS = { 'waypoints', 'startPositions', 'jokerRoute', 'pitRoute', 'branches' }

local function snapshot()
  local r = lastRoute() or {}
  local s = {}
  for _, k in ipairs(SCALARS) do s[k] = tostring(r[k]) end
  for _, k in ipairs(LISTS) do s['#' .. k] = tostring(#(r[k] or {})) end
  return s
end

local function diff(a, b)
  local out = {}
  for k, v in pairs(a) do
    if b[k] ~= v then out[#out + 1] = k .. ' ' .. tostring(v) .. ' -> ' .. tostring(b[k]) end
  end
  table.sort(out)
  return out
end

-- One complete event, the way a race night runs one: grid, countdown, two laps
-- with a reset spent and the joker taken, the flag, then the teardown.
local function runEvent()
  loadCircuit()
  serverState({ phase = 'waiting', totalLaps = 2, maxResets = 2, drivers = {} })
  handlers['RM_GridAssign']({ slot = 1, order = 1, count = 1 })
  frame(5)
  for _, p in ipairs({ 'grid', 'countdown', 'racing' }) do
    serverState({ phase = p, totalLaps = 2, maxResets = 2, drivers = {} })
  end
  moveTo(10)
  for lap = 1, 2 do
    moveTo(95); moveTo(105); coast(2.5)
    if lap == 1 then
      veh.x, veh.y, veh.z = 60, 150, 0; frame()   -- through the joker gate
      veh.x, veh.y, veh.z = 0, 120, 0;  frame()
      RM.onVehicleResetted(veh.id)                 -- and spend a reset
      frame(2)
    end
    moveTo(195); moveTo(205); moveTo(10)
  end
  handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race', place = 1 })
  frame(3)
  serverState({ phase = 'finished', totalLaps = 2, maxResets = 2, drivers = {} })
  frame(3)
  handlers['RM_ReleaseSpectate']({ source = 'race' })
  serverState({ phase = 'waiting', totalLaps = 2, maxResets = 2, drivers = {} })
  frame(3)
  return snapshot()
end

-- ---------------------------------------------------------------------------
-- Three events back to back leave the client in the same place each time
-- ---------------------------------------------------------------------------
-- Compared 1-to-2 AND 2-to-3. State that settles after the first run would show
-- up in the first comparison only, and state that ACCUMULATES shows up in both;
-- the pair distinguishes them, which one comparison cannot.
local one   = runEvent()
local two   = runEvent()
local three = runEvent()

local d12 = diff(one, two)
local d23 = diff(two, three)
for _, line in ipairs(d12) do print('  drift 1->2: ' .. line) end
for _, line in ipairs(d23) do print('  drift 2->3: ' .. line) end
check(#d12 == 0, 'the second event leaves the client exactly where the first did')
check(#d23 == 0, 'and so does the third: nothing accumulates across events')

-- ---------------------------------------------------------------------------
-- A smaller layout does not inherit the bigger one's furniture
-- ---------------------------------------------------------------------------
-- The case with the most to leak: every optional section populated, then a
-- layout that has none of them. Each one has been a real bug at some point --
-- pit stalls used to survive a purge and ride along into the next save.
handlers['RM_ApplyLayout']({
  name = 'everything', width = 40, height = 10, depth = 2,
  checkpoints    = { { x = 0, y = 100, z = 0, hx = 0, hy = 1 },
                     { x = 0, y = 150, z = 0, hx = 0, hy = 1 },
                     { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 } },
  startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 },
                     { x = 5, y = 0, z = 0, hx = 0, hy = 1 } },
  joker          = { { x = 60, y = 150, z = 0, hx = 1, hy = 0 },
                     { x = 70, y = 160, z = 0, hx = 1, hy = 0 } },
  pits           = { { x = -60, y = 150, z = 0, hx = 1, hy = 0 } },
  branches       = { { slot = 1, x = 20, y = 100, z = 0, hx = 0, hy = 1 } },
})
frame()
local full = snapshot()
check(full['#waypoints'] == '3' and full['#startPositions'] == '2'
  and full['#jokerRoute'] == '2' and full['#pitRoute'] == '1'
  and full['#branches'] == '1', 'the full layout loads with all of its sections')

handlers['RM_ApplyLayout']({
  name = 'bare', width = 12, height = 4, depth = 1,
  checkpoints = { { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 } },
})
frame()
local bare = snapshot()
check(bare['#waypoints'] == '1', 'the bare layout replaces the route')
for _, k in ipairs({ 'startPositions', 'jokerRoute', 'pitRoute', 'branches' }) do
  check(bare['#' .. k] == '0',
    'no ' .. k .. ' survive onto a layout that has none (got ' .. bare['#' .. k] .. ')')
end
check(bare.width == '12' and bare.height == '4' and bare.depth == '1',
  'and the gate dimensions come from the new layout, not the old one')

-- ---------------------------------------------------------------------------
-- A derby does not disturb the loaded race track
-- ---------------------------------------------------------------------------
-- The two share a map and a panel and nothing else. Running one between two
-- races must leave the circuit exactly as it was.
loadCircuit()
frame()
local beforeDerby = snapshot()
handlers['RM_DerbyUpdate']({ rmProtocol = 2, derbyPhase = 'running',
  boundary = { { x = -50, y = -50, z = 0 }, { x = 50, y = -50, z = 0 },
               { x = 50, y = 50, z = 0 }, { x = -50, y = 50, z = 0 } },
  players = {}, starts = {} })
frame(3)
handlers['RM_DerbyUpdate']({ rmProtocol = 2, derbyPhase = 'idle',
  boundary = {}, players = {}, starts = {} })
frame(3)
local afterDerby = snapshot()
local dd = diff(beforeDerby, afterDerby)
for _, line in ipairs(dd) do print('  derby changed: ' .. line) end
check(#dd == 0, 'a derby run between races leaves the race track untouched')

-- ---------------------------------------------------------------------------
-- A purge empties every section, not just the route
-- ---------------------------------------------------------------------------
handlers['RM_ApplyLayout']({
  name = 'everything again', width = 40, height = 10, depth = 2,
  checkpoints    = { { x = 0, y = 100, z = 0, hx = 0, hy = 1 },
                     { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 } },
  startPositions = { { x = 0, y = 0, z = 0, hx = 0, hy = 1 } },
  joker          = { { x = 60, y = 150, z = 0, hx = 1, hy = 0 } },
  pits           = { { x = -60, y = 150, z = 0, hx = 1, hy = 0 } },
})
frame()
handlers['RM_ClearTrack']({ reason = 'lifecycle audit' })
frame()
local purged = snapshot()
for _, k in ipairs(LISTS) do
  check(purged['#' .. k] == '0',
    'a purge empties ' .. k .. ' (got ' .. purged['#' .. k] .. ')')
end

print(string.format('lifecycle_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
