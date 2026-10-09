-- Headless test for PROPS: lua/ge/extensions/raceManager/props.lua and its
-- wiring in lua/ge/extensions/raceManager.lua.
--
-- A prop is a real TSStatic in the level, spawned on every client from the
-- layout. What can go wrong is the engine side, so that is what is pinned:
--
--   * the world follows the list: a load spawns, a purge deletes, an edit moves;
--   * a solid prop needs a collision rebuild, batched, and never mid-session;
--   * props are ghosts while their tab is open (the ground probes must see the
--     road), and one touching this client's car stays a ghost until it is clear;
--   * a delete never touches an object that is not ours, even on a reused id.
--
-- Run from the repo root: lua5.3 tests/props_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- The scene: just enough of SimObject to watch what the module does
-- ---------------------------------------------------------------------------
local registry = {}   -- [id] = object
local nextId   = 1000
local deleted  = {}   -- names, in order
local reloads  = 0

local function newObject(class)
  local o = { class = class, fields = {}, children = {} }
  function o:setField(k, _, v) self.fields[k] = v end
  function o:registerObject(name)
    nextId = nextId + 1
    self.id, self.name = nextId, name
    registry[self.id] = self
  end
  function o:getId() return self.id end
  function o:getName() return self.name end
  function o:setPosRot(x, y, z, qx, qy, qz, qw)
    self.pos = { x = x, y = y, z = z }
    self.rot = { x = qx, y = qy, z = qz, w = qw }
  end
  function o:addObject(child) self.children[#self.children + 1] = child end
  function o:delete()
    registry[self.id] = nil
    deleted[#deleted + 1] = self.name
  end
  function o:deleteAllObjects()
    for _, c in ipairs(self.children) do
      if registry[c.id] then c:delete() end
    end
  end
  return o
end
createObject = newObject

local missionGroup = newObject('SimGroup')
scenetree = {
  MissionGroup = missionGroup,
  findObjectById = function (id) return registry[id] end,
  findObject = function (name)
    for _, o in pairs(registry) do if o.name == name then return o end end
  end,
}

local function ours()
  local out = {}
  for _, o in pairs(registry) do
    if o.class == 'TSStatic' and o.name:sub(1, 7) == 'rmProp_' then out[#out + 1] = o end
  end
  table.sort(out, function (a, b) return a.id < b.id end)
  return out
end
-- Ids change when a prop is recreated, so objects are found by where they are.
local function at(x, y)
  for _, o in ipairs(ours()) do
    if o.pos and math.abs(o.pos.x - x) < 1e-6 and math.abs(o.pos.y - y) < 1e-6 then return o end
  end
end
local function solidCount()
  local n = 0
  for _, o in ipairs(ours()) do
    if o.fields.collisionType == 'Collision Mesh' then n = n + 1 end
  end
  return n
end

-- Flat ground at z = 0.
castRayStatic = function (o, dir, len)
  if dir.z < 0 and o.z >= 0 then return o.z end
  return (len or 100) + 1
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs (as marker_test)
-- ---------------------------------------------------------------------------
local sent, hooks, handlers = {}, {}, {}

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

be = {
  getPlayerVehicle = function () return veh end,
  reloadCollision = function () reloads = reloads + 1 end,
}
getPlayerVehicle = function (_) return veh end
getAllVehicles   = function () return { veh } end
beamng_version   = '0.39.0.0'

vec3 = function (x, y, z) return { x = x, y = y, z = z } end
-- Records the direction it was asked for: z and w carry it.
quatFromDir = function (d, up) return { x = 0, y = up and up.z or 0, z = d.x, w = d.y } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }

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
local props = require('raceManager/props')

local function frame(n)
  for _ = 1, (n or 1) do RM.onUpdate(0.05) end
end
-- Long enough for the clear-of-my-car tick and the settle after it.
local function settle() frame(20) end
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end
local function routeState()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerRoute' then return hooks[i].payload end
  end
end

serverState({ phase = 'waiting', drivers = {}, youAreAdmin = true })

local function course(list)
  handlers['RM_ApplyLayout']({
    name = 'props', width = 20, height = 8, depth = 2,
    checkpoints = { { x = 0, y = 300, z = 0, hx = 0, hy = 1 } },
    props = list,
  })
end

-- ---------------------------------------------------------------------------
-- The catalogue, and the server's copy of it
-- ---------------------------------------------------------------------------
do
  local seen = {}
  for _, def in ipairs(props.CATALOG) do
    check(not seen[def.id], 'prop id "' .. def.id .. '" is unique')
    seen[def.id] = true
    check(type(def.shape) == 'string' and def.shape:sub(1, 11) == 'art/shapes/',
      def.id .. ' uses a shape every map has (art/shapes/)')
    check(type(def.label) == 'string' and def.label ~= '', def.id .. ' has a label')
    check(not def.label:find('\226\128\148'), def.id .. ' label has no em dash')
  end
  -- A kind missing on the server is dropped from every save.
  local f = assert(io.open('server/RaceManager/main.lua', 'r'))
  local src = f:read('*a')
  f:close()
  local body = src:match('function race%.sanitizeProps.-local KINDS = (%b{})')
  check(body ~= nil, 'the server has a prop whitelist to compare')
  local server = {}
  for k in (body or ''):gmatch('([%w_]+)%s*=%s*true') do server[k] = true end
  for id in pairs(seen) do
    check(server[id], 'the server keeps "' .. id .. '" props through a save')
  end
  for id in pairs(server) do
    check(seen[id], 'the server\'s "' .. id .. '" is a prop the client can spawn')
  end
end

-- ---------------------------------------------------------------------------
-- A layout's props come into the world
-- ---------------------------------------------------------------------------
veh.x, veh.y, veh.z = 0, -200, 0
course({
  { kind = 'cone',        x = 0,  y = 50, z = 0, hx = 0, hy = 1 },
  { kind = 'jersey',      x = 10, y = 50, z = 0, hx = 1, hy = 0 },
  { kind = 'plasticRed',  x = 20, y = 50, z = 0, hx = 0, hy = 1, solid = false },
  { kind = 'banana',      x = 30, y = 50, z = 0, hx = 0, hy = 1 },
  { kind = 'roadBarrier', x = 40, y = 50, z = 0, hx = 0, hy = 1 },
})
check(#routeState().props == 4, 'an unknown kind is dropped on load (got '
  .. #routeState().props .. ')')
check(routeState().propKinds and #routeState().propKinds == #props.CATALOG,
  'the panel is told every kind')
frame()
local objs = ours()
check(#objs == 4, 'one TSStatic per prop (got ' .. #objs .. ')')
check(objs[1] and objs[1].fields.shapeName == props.BY_ID.cone.shape, 'with the kind\'s shape')
check(objs[1] and objs[1].canSave == false, 'never saved into the level')
check(solidCount() == 3, 'solid by default, ghost when saved as one')
check(objs[3] and objs[3].fields.collisionType == 'None', 'the ghost has no collision')
check(#missionGroup.children == 1, 'all in one group under the MissionGroup')
check(objs[4].pos and objs[4].pos.z == 0 and objs[4].pos.y == 50, 'a based mesh sits at its point')
check(reloads == 0, 'the collision rebuild waits for the batch to settle')
settle()
check(reloads == 1, 'then runs once for the whole load (got ' .. reloads .. ')')

-- Pose: quatFromDir along the heading, turned by the mesh's own yaw.
check(objs[1].rot.z == 0 and objs[1].rot.w == 1 and objs[1].rot.y == 1,
  'a prop is pointed along its heading, upright')
check(objs[2].rot.z == 1 and objs[2].rot.w == 0, 'heading +X points it along +X')
local rb = objs[4].rot
check(math.abs(math.abs(rb.z) - 1) < 1e-6 and math.abs(rb.w) < 1e-6,
  'a mesh built across the road is turned a quarter to lie along it')

-- ---------------------------------------------------------------------------
-- Ghosts while edited
-- ---------------------------------------------------------------------------
RM.setEditorOpen(true)
RM.setEditorTarget('prop')
check(routeState().editorTarget == 'prop', 'Props is an editor tab')
settle()
check(#ours() == 4 and solidCount() == 0, 'every prop is a ghost while the Props tab is open')
check(reloads == 2, 'and the solid ones going needed a rebuild (got ' .. reloads .. ')')

-- Placed by driving: in front of the car, on the ground.
veh.x, veh.y, veh.z, veh.hx, veh.hy = 0, 0, 0.5, 0, 1
RM.setPropKind('jersey')
check(routeState().propKind == 'jersey', 'the next prop\'s kind is chosen')
RM.setPropKind('banana')
check(routeState().propKind == 'jersey', 'an unknown kind is refused')
RM.editorAdd()
local p5 = routeState().props[5]
check(p5 and p5.kind == 'jersey', 'a driven prop takes the chosen kind')
check(p5 and math.abs(p5.y - (props.AHEAD + props.BY_ID.jersey.r)) < 1e-6 and p5.x == 0,
  'and goes in front of the car, not inside it')
check(p5 and p5.z == 0, 'seated on the ground, not at the car\'s height')
check(p5 and p5.width == nil, 'a prop has no gate size')

-- Placed by click: where clicked. This one is under the car.
RM.editorAdd({ x = 0, y = 1, z = 0.5, hx = 0, hy = 1 })
check(#routeState().props == 6 and routeState().props[6].y == 1, 'a clicked prop goes where clicked')
settle()
check(#ours() == 6 and solidCount() == 0, 'new props are ghosts while editing')

-- ---------------------------------------------------------------------------
-- Leaving the tab: solid, except what the car is touching
-- ---------------------------------------------------------------------------
local before = reloads
RM.setEditorTarget('main')
settle()
check(solidCount() == 4, 'leaving the tab makes them solid, but not the one under the car '
  .. 'nor the ghost (got ' .. solidCount() .. ')')
check(reloads == before + 1, 'in one rebuild')

-- A session: nothing turns solid, the car may be anywhere.
serverState({ phase = 'racing', totalLaps = 3, maxResets = -1, drivers = {} })
veh.x, veh.y = 0, -100
before = reloads
settle()
check(solidCount() == 4, 'no prop turns solid mid-session, even with the car clear')
check(reloads == before, 'and nothing is rebuilt while racing')
serverState({ phase = 'waiting', drivers = {} })
settle()
check(solidCount() == 5, 'it does once the session ends and the car is clear')

-- ---------------------------------------------------------------------------
-- Editing a placed prop
-- ---------------------------------------------------------------------------
RM.setEditorTarget('prop')
RM.setPropKind('cone', 5)
check(routeState().props[5].kind == 'cone', 'a placed prop can change kind')
RM.setPropSolid(5, false)
check(routeState().props[5].solid == false, 'and be made a ghost')
RM.setPropSolid(5, true)
check(routeState().props[5].solid == nil, 'and solid again (stored as absent)')
local h0 = routeState().props[1]
RM.flipProp(1)
check(routeState().props[1].hy == -1, 'a half turn reverses its heading')
settle()
check(at(0, 50) and at(0, 50).rot.w == -1,
  'and the object in the world turns with it')
check(h0 ~= nil, 'flip keeps the prop')
RM.setPropSolid(3, true)
RM.setPropSolid(2, false)

-- Saved with the layout, ghosts marked.
RM.saveLayout('with props')
local save
for i = #sent, 1, -1 do if sent[i].event == 'RM_SaveLayout' then save = sent[i].payload; break end end
check(save and save.props and #save.props == 6, 'props travel with a save')
check(save and save.props[2].solid == false and save.props[1].solid == nil,
  'a ghost is saved as one, a solid prop carries nothing')
check(save and save.props[1].kind == 'cone' and save.props[1].width == nil,
  'as kind and pose only')

-- Unsaved prop work is protected like gates are.
local count = #routeState().props
course({ { kind = 'cone', x = 500, y = 500, z = 0, hx = 0, hy = 1 } })
check(#routeState().props == count, 'a layout arriving over unsaved prop edits is refused')

-- ---------------------------------------------------------------------------
-- Purges, level changes and unloads
-- ---------------------------------------------------------------------------
RM.setEditorOpen(false)
settle()
before = reloads
handlers['RM_ClearTrack']({ reason = 'props audit' })
frame()
check(#ours() == 0, 'a purge takes every prop out of the world')
settle()
check(reloads == before + 1, 'and rebuilds, or their collision stays behind')

-- The level goes; the ids may come back as somebody else's objects.
course({ { kind = 'cone', x = 0, y = 50, z = 0, hx = 0, hy = 1 } })
settle()
local old = ours()[1]
check(old ~= nil, 'a fresh layout spawns again')
local nDeleted = #deleted
RM.onClientEndMission()
check(#deleted == nDeleted, 'ending the mission deletes nothing')
-- The level unloaded: our object is gone and its id belongs to a stranger.
registry[old.id] = nil
local stranger = newObject('TSStatic')
stranger.id, stranger.name = old.id, 'theirBarrier'
registry[old.id] = stranger
settle()
check(registry[old.id] == stranger, 'an object on a reused id is never deleted')
check(#ours() == 1, 'and the prop is spawned again in the new level')

-- An id we did hold, taken over without a mission end.
local cur = ours()[1]
registry[cur.id] = nil
local intruder = newObject('TSStatic')
intruder.id, intruder.name = cur.id, 'levelLamp'
registry[cur.id] = intruder
settle()
check(registry[cur.id] == intruder, 'a stale id is checked by name before any delete')
check(#ours() == 1, 'and the prop is put back')

RM.onExtensionUnloaded()
check(#ours() == 0, 'unloading takes the props with it')
check(scenetree.findObject('RaceManagerProps') == nil, 'and the group')

print(string.format('props_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
