-- Headless test for DIRECTION MARKERS in lua/ge/extensions/raceManager.lua.
--
-- A marker is signage. It is placed exactly the way a checkpoint is and then
-- does nothing whatsoever: not armed, not crossed, not timed, not counted, never
-- in a lap or a split or a results file. On a long point-to-point stage the
-- problem is not scoring, it is that a driver arriving at a junction at speed
-- cannot tell which way the route goes -- and a checkpoint placed to answer that
-- would be a checkpoint they have to hit.
--
-- So the property worth pinning here is a NEGATIVE one, and it is the whole
-- reason this file exists: driving through a marker changes nothing. Everything
-- else (symbols, persistence, the editor target) is ordinary plumbing; a marker
-- that quietly armed itself would be a scoring bug on every stage that used one.
--
-- Run from the repo root: lua5.3 tests/marker_test.lua

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
-- A marker is inert
-- ---------------------------------------------------------------------------
-- The one that matters. A marker sits ON the racing line by design -- it points
-- at the corner it is warning about -- so a car drives through it every lap.
startRace(3)
handlers['RM_ApplyLayout']({
  name = 'signed', width = 40, height = 10, depth = 2,
  checkpoints = { { x = 0, y = 100,  z = 0, hx = 0, hy = 1 },
                  { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 } },
  -- Straddling the racing line, between the two gates.
  markers = { { x = 0, y = 150, z = 0, hx = 0, hy = 1, kind = 'right' } },
})
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
moveTo(10)

local function routeState()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerRoute' then return hooks[i].payload end
  end
end
check(#(routeState().markers or {}) == 1, 'the layout loads with its marker')
check(routeState().markers[1].kind == 'right', 'and the symbol comes with it')

-- PAST THE REAL GATE FIRST. Gate 1 is at y=100 and the marker at y=150, so a
-- car driven straight from the start line to the marker crosses the checkpoint
-- on the way and the crossing this is about gets lost in it.
moveTo(95); moveTo(105)
local sentBefore = #sent
local wpBefore = routeState().nextWp
-- Straight through the middle of the marker, twice, with the checkpoint behind.
moveTo(140); moveTo(160); moveTo(140); moveTo(160)
check(routeState().nextWp == wpBefore,
  'driving through a marker does not advance the armed checkpoint')
local lapReports = 0
for i = sentBefore + 1, #sent do
  if sent[i].event == 'RM_Lap' or sent[i].event == 'RM_Progress' then
    if sent[i].event == 'RM_Lap' then lapReports = lapReports + 1 end
  end
end
check(lapReports == 0, 'and reports no lap')

-- ...and the real checkpoints still work with a marker sitting between them.
--
-- Asserted the instant the line is crossed, and NOT after repositioning the car
-- for the next case: gates score in both directions, so driving back to the
-- start from beyond the line re-crosses gate 1 backwards and arms slot 2 again.
-- That is correct behaviour and it hides this result.
coast(2.5)
moveTo(195); moveTo(205)
check(routeState().nextWp == 1, 'the lap still completes normally around it')

-- ---------------------------------------------------------------------------
-- Symbols
-- ---------------------------------------------------------------------------
RM.setEditorTarget('marker')
check(routeState().markerKinds and #routeState().markerKinds == 7,
  'seven symbols are offered')

RM.setMarkerKind('uturn')
check(routeState().markerKind == 'uturn', 'the next marker takes the chosen symbol')
RM.setMarkerKind('banana')
check(routeState().markerKind == 'uturn', 'an unknown symbol is refused, not stored')

-- A placed marker's symbol is changed in place: the sign is corrected from the
-- panel rather than by driving back to it and putting it down again.
RM.setMarkerKind('splitLeft', 1)
check(routeState().markers[1].kind == 'splitLeft', 'a placed marker can be re-signed')
check(routeState().markerKind == 'uturn',
  'and re-signing one does not change what the NEXT one will be')
RM.setMarkerKind('left', 99)
check(routeState().markers[1].kind == 'splitLeft', 'an index that does not exist is ignored')

-- ---------------------------------------------------------------------------
-- Placing, and what a placed marker carries
-- ---------------------------------------------------------------------------
serverState({ phase = 'waiting', totalLaps = 3, maxResets = -1, drivers = {} })
RM.setMarkerKind('down')
veh.x, veh.y, veh.z = 25, 60, 0
RM.editorAdd()
local list = routeState().markers
check(#list == 2, 'a marker is placed like a checkpoint')
check(list[2].kind == 'down', 'and carries the symbol the editor was set to')

-- The editor target routes to the marker list, not the main route.
RM.editorClear()
check(#(routeState().markers or {}) == 0, 'Clear empties the markers')
check(#(routeState().waypoints or {}) == 2, 'and leaves the main route alone')

-- ---------------------------------------------------------------------------
-- A purge takes the signage with the track
-- ---------------------------------------------------------------------------
-- A sign pointing left on a track that no longer turns left is worse than no
-- sign, and it would ride along into the next save.
handlers['RM_ApplyLayout']({
  name = 'signed again', width = 40, height = 10, depth = 2,
  checkpoints = { { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 } },
  markers = { { x = 0, y = 150, z = 0, hx = 0, hy = 1, kind = 'left' },
              { x = 0, y = 170, z = 0, hx = 0, hy = 1, kind = 'up' } },
})
check(#routeState().markers == 2, 'markers load with a layout')
handlers['RM_ClearTrack']({ reason = 'marker audit' })
check(#(routeState().markers or {}) == 0, 'and a purge clears them')

-- A layout with no markers at all leaves none behind from the one before it.
handlers['RM_ApplyLayout']({
  name = 'with signs', width = 40, height = 10, depth = 2,
  checkpoints = { { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 } },
  markers = { { x = 0, y = 150, z = 0, hx = 0, hy = 1, kind = 'left' } },
})
handlers['RM_ApplyLayout']({
  name = 'no signs', width = 40, height = 10, depth = 2,
  checkpoints = { { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 } },
})
check(#(routeState().markers or {}) == 0,
  'a layout without markers does not inherit the previous one')

-- An unknown symbol arriving from a layout falls back rather than drawing
-- nothing at all, which is how a hand-edited layouts.json would fail.
handlers['RM_ApplyLayout']({
  name = 'odd', width = 40, height = 10, depth = 2,
  checkpoints = { { x = 0, y = SF_Y, z = 0, hx = 0, hy = 1 } },
  markers = { { x = 0, y = 150, z = 0, hx = 0, hy = 1, kind = 'sideways' } },
})
check(routeState().markers[1].kind == 'right',
  'an unknown symbol from a layout falls back to a real one')

print(string.format('marker_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
