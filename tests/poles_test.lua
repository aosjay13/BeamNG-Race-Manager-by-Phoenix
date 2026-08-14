-- Headless test for the race-mode checkpoint markers (BeamNG's gate poles) in
-- lua/ge/extensions/raceManager.lua.
--
-- Why this exists, and why most of it is about what the mod must NOT do:
--
-- `scenario/race_marker` is a SINGLETON shared by everything in the game that
-- races -- BeamNG's own hotlapping and flowgraph races, drag, drift, and
-- BeamJoy if it is installed. Its setupMarkers() rebuilds ONE global marker
-- list, so calling it deletes every marker all of them had placed, and the next
-- one to call it deletes ours. BeamJoy uses that shared path and documents
-- crashes on disconnect for every marker type but one.
--
-- So the markers are taken in their DETACHED form: createRaceMarker(true, ...)
-- hands back a marker that is never entered into the shared list. We own it, we
-- drive it, and nothing we do can disturb another mod's race. The engine stubs
-- below fail the test if the shared API is called at all.
--
-- The other half is teardown. These are real scene objects (TSStatic), not
-- immediate-mode drawing: one left behind is a pair of poles standing on an
-- empty map with nothing left able to delete them.
--
-- Run from the repo root: lua5.3 tests/poles_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- Engine stubs
-- ---------------------------------------------------------------------------
local sent, hooks, handlers = {}, {}, {}
local VEH_ID = 7

-- Every marker the engine has handed out, alive or dead, in order.
local madeMarkers = {}
local sharedApiCalls = {}   -- any use of the SHARED (non-detached) API

-- The real sideColumnMarker builds this in its init with
-- `self.modeInfos = deepcopy(modeInfos)` -- a PER-INSTANCE copy of the eight
-- stock mode colours. That copy is what makes recolouring one marker safe, so
-- the stub reproduces it (a fresh table per marker, never a shared one) and the
-- joker case below checks the recolour lands on it.
local function stockModeInfos()
  return {
    default  = { color = { 1, 0.07, 0 },  baseColor = { 1, 1, 1 } },
    next     = { color = { 0, 0, 0 },     baseColor = { 0, 0, 0 } },
    lap      = { color = { 0.4, 1, 0.2 }, baseColor = { 1, 1, 1 } },
    recovery = { color = { 1, 0.85, 0 },  baseColor = { 1, 1, 1 } },
    branch   = { color = { 1, 0.6, 0 },   baseColor = { 1, 1, 1 } },
    hidden   = { color = { 0, 0, 0 },     baseColor = { 0, 0, 0 } },
  }
end

local function makeMarker(id)
  local m = { id = id, alive = false, checkpoint = nil, mode = nil, updates = 0,
              modeInfos = stockModeInfos() }
  function m:createMarkers() self.alive = true end
  function m:clearMarkers() self.alive = false end
  function m:setToCheckpoint(wp) self.checkpoint = wp end
  function m:setMode(mode) self.mode = mode end
  function m:update(dt) self.updates = self.updates + 1 end
  return m
end

-- The real module, as far as its shape matters here.
local raceMarkerModule = {
  createRaceMarker = function (detached, markerType)
    -- Detached is not optional. A non-detached marker goes into the shared list
    -- and becomes everyone else's problem.
    if detached ~= true then
      sharedApiCalls[#sharedApiCalls + 1] = 'createRaceMarker(non-detached)'
    end
    local m = makeMarker(#madeMarkers + 1)
    m.markerType = markerType
    m:createMarkers()
    madeMarkers[#madeMarkers + 1] = m
    return m
  end,
  -- Everything below rebuilds or walks the SHARED list. Touching any of it is
  -- the bug this file exists to prevent.
  setupMarkers = function () sharedApiCalls[#sharedApiCalls + 1] = 'setupMarkers' end,
  setModes     = function () sharedApiCalls[#sharedApiCalls + 1] = 'setModes' end,
  init         = function () sharedApiCalls[#sharedApiCalls + 1] = 'init' end,
  render       = function () sharedApiCalls[#sharedApiCalls + 1] = 'render' end,
  hide         = function () sharedApiCalls[#sharedApiCalls + 1] = 'hide' end,
  show         = function () sharedApiCalls[#sharedApiCalls + 1] = 'show' end,
}

-- The extension reaches the module through require(). Counted, because
-- require() on a name that does not resolve walks the whole package path, and
-- this is reached from the frame loop: an uncached lookup cost seventy times
-- everything else the mod does per frame put together.
local requireCalls = 0
local realRequire = require
require = function (name)
  if name == 'scenario/race_marker' then
    requireCalls = requireCalls + 1
    return raceMarkerModule
  end
  return realRequire(name)
end

local veh = { id = VEH_ID, x = 0, y = 0, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z) self.x, self.y, self.z = x, y, z end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end
function veh:getSpawnWorldOOBB() return nil end

getPlayerVehicle = function () return veh end
be = { getPlayerVehicle = function () return veh end, enterVehicle = function () end }
getAllVehicles = function () return { veh } end
getObjectByID = function (id) return id == VEH_ID and veh or nil end
MPVehicleGE = {
  isOwn = function (id) return id == VEH_ID end,
  getVehicles = function () return { { ownerID = 1, gameVehicleID = VEH_ID } } end,
}
core_vehicleBridge = { executeAction = function () end }
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
core_vehicles = { removeCurrent = function () end }
beamng_version = '0.39.4.0'

local V = {}
V.__index = V
V.__add = function (a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, V) end
V.__mul = function (a, s) return setmetatable({ x = a.x * s, y = a.y * s, z = a.z * s }, V) end
vec3 = function (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
ColorF = function () return {} end
ColorI = function () return {} end
String = function (s) return s end
debugDrawer = {
  drawCylinder = function () end,
  drawTextAdvanced = function () end,
  drawSphere = function () end,
  drawLine = function () end,
  drawQuadSolid = function () end,   -- the editor gate's filled surface
}
MPGameNetwork = {}
MPConfig = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function frames(n) for _ = 1, (n or 1) do RM.onUpdate(1 / 60) end end
local function serverState(t) t.rmProtocol = 2; t.raceTime = 0; handlers['RM_Update'](t) end
local function racing() serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {} }) end
local function aliveMarkers()
  local n = 0
  for _, m in ipairs(madeMarkers) do if m.alive then n = n + 1 end end
  return n
end

-- A four-gate circuit.
RM.setEditorTarget('main')
for i = 1, 4 do
  veh.x, veh.y = i * 100, 0
  RM.editorAdd()
end

-- ===========================================================================
-- Poles are the driver's view of a checkpoint, in every phase
-- ===========================================================================
-- Not only during a running session: a driver learning a circuit before the
-- lights wants to see where the gates are just as much as one racing through
-- them. The alternative was drawing the whole checkpoint set as numbered
-- rectangles, which is the editor's job and clutter for everyone else.
serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
frames(3)
check(aliveMarkers() == 2, 'poles are up before a session, for learning the track')

-- ===========================================================================
-- Racing: poles on the next two gates, and only those
-- ===========================================================================
racing()
frames(3)
check(aliveMarkers() == 2,
  'a running session puts poles on the next two gates, whatever the circuit length')
check(madeMarkers[1].markerType == 'sideColumnMarker',
  'using the one marker type that is safe to tear down')
check(madeMarkers[1].checkpoint ~= nil, 'the marker is pointed at a gate')
check(madeMarkers[1].checkpoint.radius == 10,
  'radius is the HALF width, so poles stand at the rectangle edges')
check(madeMarkers[1].checkpoint.normal.y == 1,
  'and the gate heading is passed through as the marker normal')

-- They animate, so they have to be ticked -- detached markers are not in the
-- engine's own render list, which is exactly what makes them safe.
local before = madeMarkers[1].updates
frames(5)
check(madeMarkers[1].updates > before, 'markers are ticked every frame')

-- Re-pointed only when the gate under them changes, not once a frame.
local pointedAt = madeMarkers[1].checkpoint
frames(10)
check(madeMarkers[1].checkpoint == pointedAt,
  'a marker sitting on the same gate is not re-pointed every frame')

-- ===========================================================================
-- The joker route gets a marker too
-- ===========================================================================
-- This is not decoration. The server DISQUALIFIES a driver who does not take
-- the joker exactly once, and the joker gates are NOT part of the main route --
-- so the two markers above never reach them. Before this, removing the
-- checkpoint rectangles would have left a required route invisible.
racing()
frames(3)
local plain = aliveMarkers()
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
  jokerEnabled = true })
handlers['RM_ApplyLayout']({ name = 'j', width = 20, height = 10,
  checkpoints = {
    { x = 100, y = 0, z = 0, hx = 1, hy = 0 },
    { x = 200, y = 0, z = 0, hx = 1, hy = 0 },
  },
  joker = { { x = 150, y = 50, z = 0, hx = 1, hy = 0 } },
})
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
  jokerEnabled = true })
frames(3)
check(aliveMarkers() == plain + 1,
  'an armed joker route gets a marker of its own, beyond the two main ones')

-- ...and it is VIOLET.
--
-- The marker's stock `branch` mode -- BeamNG's own alternate-route colour -- is
-- orange (1, 0.6, 0), which sits right beside the main route's red-orange
-- `default` (1, 0.07, 0). On track that made the joker read as more of the same
-- lap, which is the one thing it must never read as. There is no violet mode to
-- switch to, so the colour is written onto this marker's own copy of the table.
local function jokerMarker()
  for i = #madeMarkers, 1, -1 do
    local m = madeMarkers[i]
    if m.alive and m.mode == 'branch' then return m end
  end
end
-- The colour is read out of the extension rather than repeated here. A test
-- holding its own copy of a colour is a test that fails the day somebody tunes
-- one, which says nothing about whether the repaint still works -- the property
-- worth pinning is "the marker gets the colour the mod declares", not "the
-- marker is this exact violet".
local clientSrc
do
  local f = assert(io.open('lua/ge/extensions/raceManager.lua', 'r'))
  clientSrc = f:read('*a')
  f:close()
end
local function rgbFromSource(pattern, what)
  local r, g, b = clientSrc:match(pattern)
  check(r ~= nil, 'found ' .. what .. ' in the client extension')
  return { tonumber(r), tonumber(g), tonumber(b) }
end
local JOKER_RGB = rgbFromSource(
  'JOKER_POLE_RGB%s*=%s*{%s*([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)%s*}',
  "the joker gate's pole colour")

local jm = jokerMarker()
check(jm ~= nil, 'the joker marker is the one in branch mode')
local jc = jm and jm.modeInfos.branch.color
check(jc and math.abs(jc[1] - JOKER_RGB[1]) < 1e-9
  and math.abs(jc[2] - JOKER_RGB[2]) < 1e-9
  and math.abs(jc[3] - JOKER_RGB[3]) < 1e-9,
  'the joker marker is repainted violet, not left on the stock branch orange')

-- The repaint must land on THIS marker and nowhere else. If a build ever shared
-- one colour table between markers, recolouring the joker would drag every
-- other pole -- and every other mod's -- violet with it.
local others = 0
for _, m in ipairs(madeMarkers) do
  if m ~= jm and m.modeInfos.branch.color[1] ~= 1 then others = others + 1 end
end
check(others == 0, 'and on no other marker: the colour table is per instance')

-- NOT asserted here: that a joker already TAKEN stays signposted (dimmed
-- rather than vanishing, so "you have taken it" is still readable). `jokerTaken`
-- is set only by actually driving the joker route -- it is client-local and no
-- server field sets it -- so the only honest way to reach that state from this
-- file is to stage a real crossing, which is a different test's job. Asserting
-- it by poking server state would pass without ever leaving the untaken case.

-- Disarming the joker rule stops it being signposted at all.
handlers['RM_ApplyLayout']({ name = 'j2', width = 20, height = 10,
  checkpoints = {
    { x = 100, y = 0, z = 0, hx = 1, hy = 0 },
    { x = 200, y = 0, z = 0, hx = 1, hy = 0 },
  },
  joker = { { x = 150, y = 50, z = 0, hx = 1, hy = 0 } },
})
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
  jokerEnabled = false })
frames(3)
check(aliveMarkers() == plain, 'a disarmed joker route is not signposted')

-- ===========================================================================
-- The shared singleton is never touched
-- ===========================================================================
-- This is the whole reason for the detached form. Any of these calls would
-- delete the markers of every other racing mod in the game, and let theirs
-- delete ours.
check(#sharedApiCalls == 0,
  'the shared race_marker API is never called: ' .. table.concat(sharedApiCalls, ', '))

-- ===========================================================================
-- The editor owns the view when an admin is in it
-- ===========================================================================
-- Poles cannot carry a number or show a gate's dimensions, so an admin laying
-- out a circuit gets the editor view instead -- and only an admin does.
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
  youAreAdmin = true })
RM.setEditorOpen(true)
frames(3)
check(aliveMarkers() == 0, 'an admin with the editor open sees the editor, not poles')

RM.setEditorOpen(false)
frames(3)
check(aliveMarkers() == 2, 'closing the editor hands the view back to the poles')

-- A non-admin can never get the editor view, whatever the editor flag says.
-- Admin status only changes when the payload carries it -- ordinary broadcasts
-- leave it alone -- so demoting takes an explicit youAreAdmin = false.
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {},
  youAreAdmin = false })
RM.setEditorOpen(true)
frames(3)
check(aliveMarkers() == 2, 'a non-admin keeps the race view even with the editor flagged open')
RM.setEditorOpen(false)

-- ===========================================================================
-- Teardown: these are scene objects, so nothing may be left standing
-- ===========================================================================
-- A track being cleared takes them down: there are no gates left to point at.
racing()
frames(3)
check(aliveMarkers() == 2, 'poles up')
handlers['RM_ClearTrack']({ reason = 'test' })
frames(3)
check(aliveMarkers() == 0, 'clearing the track takes the poles down')
handlers['RM_ApplyLayout']({ name = 'x', width = 20, height = 10, checkpoints = {
  { x = 100, y = 0, z = 0, hx = 1, hy = 0 },
  { x = 200, y = 0, z = 0, hx = 1, hy = 0 },
  { x = 300, y = 0, z = 0, hx = 1, hy = 0 },
  { x = 400, y = 0, z = 0, hx = 1, hy = 0 },
} })
frames(3)
check(aliveMarkers() == 2, 'and loading one puts them back')

racing()
frames(3)
check(aliveMarkers() == 2, 'poles up again')
RM.onBeamMPServerLeave()
check(aliveMarkers() == 0, 'leaving the session takes them down')

racing()
frames(3)
RM.onExtensionUnloaded()
check(aliveMarkers() == 0, 'unloading the extension takes them down')

-- Markers are reused rather than re-created every time the view returns: a
-- marker is three scene objects, and churning them per frame would be worse
-- than the drawing it replaces.
local madeSoFar = #madeMarkers
racing()
frames(10)
check(#madeMarkers - madeSoFar <= 2,
  'returning to the race view creates at most the two markers it needs')

-- The engine module is resolved once for the life of the extension, however
-- many times the markers come and go.
check(requireCalls == 1,
  'the marker module is looked up once, not per frame (was ' .. requireCalls .. ')')

-- ===========================================================================
-- The poles are brightened, and brightened ONCE
-- ===========================================================================
-- BeamNG's palette is built for BeamNG's races: `default` is a deep red-orange
-- (1, 0.07, 0) -- a strong colour and a dark one, which against a bright map or
-- a pale road surface is a silhouette rather than a marker. Every mode with a
-- colour is lifted to the luminous version of the SAME colour, so what a driver
-- has learned each one means still holds.
do
  local stock = stockModeInfos()
  local m = madeMarkers[1]
  check(m ~= nil and type(m.modeInfos) == 'table', 'found a created marker to inspect')
  local infos = m and m.modeInfos or {}

  -- Hue, as the ratio the middle channel sits at between the other two. It is
  -- what "the same colour, brighter" has to hold constant, and both halves of
  -- the lift (scale to full value, then mix toward white) preserve it exactly.
  local function hueRatio(c)
    local mx = math.max(c[1], c[2], c[3])
    local mn = math.min(c[1], c[2], c[3])
    if mx == mn then return nil end          -- grey: no hue to compare
    local mid = c[1] + c[2] + c[3] - mx - mn
    return (mid - mn) / (mx - mn)
  end
  local function luma(c) return c[1] + c[2] + c[3] end

  for _, mode in ipairs({ 'default', 'lap', 'recovery' }) do
    local before, after = stock[mode].color, infos[mode] and infos[mode].color
    check(after ~= nil, 'the marker has a ' .. mode .. ' mode')
    if after then
      check(luma(after) > luma(before) + 0.05,
        'the ' .. mode .. ' pole is brighter than the stock colour ('
          .. string.format('%.2f vs %.2f', luma(after), luma(before)) .. ')')
      local h1, h2 = hueRatio(before), hueRatio(after)
      check(h1 == nil or (h2 ~= nil and math.abs(h1 - h2) < 1e-6),
        'the ' .. mode .. ' pole kept its hue: a driver who learned that colour '
          .. 'should not have to learn it again')
      check(math.max(after[1], after[2], after[3]) > 0.99,
        'the ' .. mode .. ' pole is at full value')
    end
  end

  -- `hidden` ships black because it is meant to be invisible. Brightening it
  -- would put a white pole on track where the mod asked for nothing at all.
  local hid = infos.hidden and infos.hidden.color
  check(hid and hid[1] == 0 and hid[2] == 0 and hid[3] == 0,
    'the hidden mode is left black — it is not a colour, it is an absence')

  -- `next` ships black too, and that one IS a problem: this mod puts a marker
  -- on the gate after the one being aimed at precisely so the line through the
  -- corner reads early, and a black pole cannot do that job.
  local nxt = infos.next and infos.next.color
  check(nxt and luma(nxt) > 0.5,
    'the next-gate pole is visible rather than the stock black')
  check(nxt and nxt[1] > nxt[2] and nxt[2] > nxt[3],
    'and it is the orange of the route ahead, not an invented colour')
end

-- Brightening is applied ONCE, to a fresh per-instance table, and it has to
-- stay that way: lifting a colour that has already been lifted washes it out a
-- little further every time. The hazard is not hypothetical -- it is the same
-- one this whole file is about. If a build ever shared modeInfos between
-- markers, every marker created over a race night would lift the same table
-- again, and the poles would fade out over the evening.
do
  local firstColor = {
    madeMarkers[1].modeInfos.default.color[1],
    madeMarkers[1].modeInfos.default.color[2],
    madeMarkers[1].modeInfos.default.color[3],
  }
  local madeBefore = #madeMarkers
  for _ = 1, 4 do
    serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
    frames(2)
    racing()
    frames(2)
  end
  local newest = madeMarkers[#madeMarkers]
  check(#madeMarkers > madeBefore or newest == madeMarkers[madeBefore],
    'the session cycling either reused or rebuilt the markers')
  local c = newest.modeInfos.default.color
  check(math.abs(c[1] - firstColor[1]) < 1e-9
    and math.abs(c[2] - firstColor[2]) < 1e-9
    and math.abs(c[3] - firstColor[3]) < 1e-9,
    'a marker created later carries the same colour as the first one: the lift '
      .. 'is applied once to a per-instance table, never compounded ('
      .. string.format('%.3f,%.3f,%.3f vs %.3f,%.3f,%.3f',
           c[1], c[2], c[3], firstColor[1], firstColor[2], firstColor[3]) .. ')')
end

-- ===========================================================================
-- The joker's pole colour and its editor colour are the same colour
-- ===========================================================================
-- They are two separate literals in two forms -- a {r,g,b} array written into
-- the engine marker's own colour table, and a ColorF in the drawing palette --
-- because the two renderers take colours differently. Nothing but this check
-- keeps them in step, and drifting is not a visible bug while you are looking
-- at either one on its own: the joker gate is simply a slightly different
-- violet in the editor than it is on track, which is exactly the kind of
-- difference a driver reads as two different things.
do
  local rgbOf = rgbFromSource
  local pairsToCheck = {
    { tune = 'JOKER_POLE_RGB%s*=%s*{%s*([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)%s*}',
      pal  = 'joker%s*=%s*ColorF%(([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)',
      what = 'the joker gate' },
    { tune = 'JOKER_POLE_USED_RGB%s*=%s*{%s*([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)%s*}',
      pal  = 'jokerUsed%s*=%s*ColorF%(([%d%.]+),%s*([%d%.]+),%s*([%d%.]+)',
      what = 'a joker already taken' },
  }
  for _, p in ipairs(pairsToCheck) do
    local pole = rgbOf(p.tune, p.what .. "'s pole colour")
    local pal  = rgbOf(p.pal,  p.what .. "'s palette colour")
    for i = 1, 3 do
      check(pole[i] == pal[i],
        p.what .. ' is a different colour on track than in the editor '
          .. '(channel ' .. i .. ': pole ' .. tostring(pole[i])
          .. ' vs palette ' .. tostring(pal[i]) .. ')')
    end
  end
end

print(string.format('poles_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
