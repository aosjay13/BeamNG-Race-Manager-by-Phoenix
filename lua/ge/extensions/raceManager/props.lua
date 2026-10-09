-- Race Manager: PROPS, client side.
--
-- Static scenery saved with a layout: cones, barriers, signs. Every client
-- spawns its own TSStatic copies from the layout it was sent, so BeamMP never
-- sees them: no owner, no car count, no Garage List check.
--
-- THE TRAPS:
--   * A static collides only after be:reloadCollision(), which rebuilds the
--     whole level's collision and hitches. Batched, and a prop is never made
--     solid during a session.
--   * Solid props are hit by every ground probe. While the Props tab is open
--     they are ghosts, so placing, dragging and seating see the road.
--   * A prop turning solid around a car launches it. One near this client's own
--     car stays a ghost until the car is clear.
--   * Object ids are reused once a level unloads: forget() drops them without
--     deleting, and every delete checks the object's name first.

local P = {}
local host

-- The catalogue. Shapes ship in content/art_shapes.zip, so every map has them.
-- yaw: degrees from "the mesh's +Y along the heading", chosen so barriers lie
-- along the road and boards face across it. z: lift for a mesh whose origin is
-- not its base. cy: local y of the footprint's middle, for a mesh built from
-- one end. r: footprint radius, for the clear-of-my-car check. h: overlay height.
P.CATALOG = {
  { id = 'cone',        label = 'Traffic cone',
    shape = 'art/shapes/garage_and_dealership/Clutter/road_cone.DAE', r = 0.3, h = 0.6 },
  { id = 'bollard',     label = 'Bollard',
    shape = 'art/shapes/objects/bollard_yellow.dae', r = 0.2, h = 1.7 },
  { id = 'barrel',      label = 'Barrel',
    shape = 'art/shapes/garage_and_dealership/Clutter/clutter_barrels_red.dae', r = 0.35, h = 0.9 },
  { id = 'cushion',     label = 'Crash cushion',
    shape = 'art/shapes/race/rally/rally_assets/s_safety_cushion_01.dae', r = 0.6, h = 1.1 },
  { id = 'jersey',      label = 'Concrete barrier, 3 m',
    shape = 'art/shapes/objects/jerseybarrier_3m.dae', r = 1.6, h = 0.9 },
  { id = 'jerseyEnd',   label = 'Concrete barrier end',
    shape = 'art/shapes/objects/jerseybarrier_end.dae', r = 1.8, h = 0.9 },
  { id = 'roadBarrier', label = 'Road barrier, 3 m',
    shape = 'art/shapes/garage_and_dealership/Clutter/concrete_road_barrier_a.dae',
    yaw = 90, r = 1.6, h = 1.2 },
  { id = 'plastic',     label = 'Plastic barrier',
    shape = 'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier.DAE',
    yaw = 90, r = 0.8, h = 0.8 },
  { id = 'plasticRed',  label = 'Plastic barrier, red',
    shape = 'art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier_red.DAE',
    yaw = 90, r = 0.8, h = 0.8 },
  { id = 'block',       label = 'Concrete block',
    shape = 'art/shapes/objects/s_precast_block.dae', yaw = 90, r = 1.1, h = 1.2 },
  { id = 'crate',       label = 'Wooden crate',
    shape = 'art/shapes/objects/s_wood_crate.dae', r = 1.7, h = 1.2 },
  { id = 'arrowBoard',  label = 'Arrow board',
    shape = 'art/shapes/objects/constructionbarrier_arrows.dae', yaw = 90, r = 1.1, h = 1.1 },
  { id = 'signLeft',    label = 'Arrow sign, left',
    shape = 'art/shapes/objects/race_arrowsign_1_L.dae', r = 1.5, h = 1.7 },
  { id = 'signRight',   label = 'Arrow sign, right',
    shape = 'art/shapes/objects/race_arrowsign_1_R.dae', r = 1.5, h = 1.7 },
  { id = 'chevron',     label = 'Chevron',
    shape = 'art/shapes/race/chevron_x1.dae', yaw = 90, z = 1, r = 0.8, h = 2 },
  { id = 'chevron3',    label = 'Chevron, triple',
    shape = 'art/shapes/race/chevron_x3.dae', yaw = 90, z = 1, r = 2.3, h = 2 },
  { id = 'cornerLeft',  label = 'Rally corner, left',
    shape = 'art/shapes/race/rally/rally_assets/s_corner_dir_left.dae', yaw = 90, r = 0.4, h = 1.3 },
  { id = 'cornerRight', label = 'Rally corner, right',
    shape = 'art/shapes/race/rally/rally_assets/s_corner_dir_right.dae', yaw = 90, r = 0.4, h = 1.3 },
  { id = 'tape',        label = 'Closure tape, 10 m',
    shape = 'art/shapes/race/rally/rally_assets/s_tape_road_closure_10m.dae',
    yaw = 90, cy = -5, r = 5, h = 1.2 },
}
P.BY_ID, P.IDS, P.LABEL = {}, {}, {}
for i, def in ipairs(P.CATALOG) do
  P.BY_ID[def.id] = def
  P.IDS[i] = def.id
  P.LABEL[def.id] = def.label
end

P.MAX       = 200   -- per layout; the server drops the rest
P.AHEAD     = 3     -- meters past the car's origin, plus the prop's radius
P.CAR_R     = 3     -- a car's radius for the clear-of-my-car check
P.SETTLE    = 0.25  -- seconds of no change before the collision rebuild
P.RECHECK   = 0.5   -- seconds between clear-of-my-car checks
P.GROUP     = 'RaceManagerProps'
P.PREFIX    = 'rmProp_'

-- Placed props: { x, y, z, hx, hy, kind, solid }. z is the BASE, on the ground.
P.list = {}
-- What the next placed prop is.
P.kind = 'cone'

-- [i] = { id, kind, solid, x, y, z, hx, hy }: what is in the world for list[i].
local spawned = {}
local serial = 0
local dirty = false        -- the solid set changed since the last rebuild
local settle = 0
local recheck = 0
local groupId = nil
local swept = false        -- a previous instance's group has been looked for

function P.init(h)
  host = h
end

function P.validKind(k)
  if type(k) == 'string' and P.BY_ID[k] then return k end
  return nil
end

local function call(fn)
  local ok, a = pcall(fn)
  if ok then return a end
end

-- Where the mesh's +Y points: the heading, turned by the mesh's own offset.
local function dirOf(wp, def)
  local hx, hy = tonumber(wp.hx) or 0, tonumber(wp.hy) or 1
  local a = math.rad(def.yaw or 0)
  if a ~= 0 then
    local c, s = math.cos(a), math.sin(a)
    hx, hy = hx * c - hy * s, hx * s + hy * c
  end
  return hx, hy
end

-- --------------------------------------------------------------------------
-- Scene objects
-- --------------------------------------------------------------------------

local function findOurs(id)
  if not id then return nil end
  local obj = call(function () return scenetree.findObjectById(id) end)
  if not obj then return nil end
  -- A reused id belongs to somebody else's object.
  local name = call(function () return obj:getName() end)
  if type(name) ~= 'string' then return nil end
  if name:sub(1, #P.PREFIX) ~= P.PREFIX and name ~= P.GROUP then return nil end
  return obj
end

local function deleteGroup(g)
  pcall(function () g:deleteAllObjects() end)
  pcall(function () g:delete() end)
end

local function group()
  local g = findOurs(groupId)
  if g then return g end
  if type(createObject) ~= 'function' or not scenetree then return nil end
  -- Found by name: ours, after forget(). On the first call it is a reloaded
  -- extension's, holding props nobody tracks, so it goes.
  local old = call(function () return scenetree.findObject(P.GROUP) end)
  if old and swept then
    groupId = call(function () return old:getId() end)
    return old
  end
  swept = true
  if old then
    deleteGroup(old)
    dirty = true
    log('I', 'raceManager', 'Props: removed a leftover prop group')
  end
  g = call(function ()
    local o = createObject('SimGroup')
    o:registerObject(P.GROUP)
    o.canSave = false
    return o
  end)
  if not g then return nil end
  local mg = scenetree.MissionGroup
  if mg then
    if not pcall(function () mg:addObject(g) end) then
      pcall(function () mg:addObject(g.obj) end)
    end
  end
  groupId = call(function () return g:getId() end)
  return g
end

-- quatFromDir is what the game's own floating arrows use: it points +Y along
-- the direction, so no quaternion convention is guessed here. The fallback is
-- headingRot's convention, for the headless tests.
local function setPose(obj, wp, def)
  local dx, dy = dirOf(wp, def)
  -- A mesh built from one end is moved back along its own +Y to center it.
  local back = -(def.cy or 0)
  local q
  if type(quatFromDir) == 'function' then
    q = quatFromDir(vec3(dx, dy, 0), vec3(0, 0, 1))
  else
    local half = math.atan2(dx, dy) * 0.5
    q = { x = 0, y = 0, z = math.sin(half), w = math.cos(half) }
  end
  obj:setPosRot(wp.x + dx * back, wp.y + dy * back, wp.z + (def.z or 0),
    q.x, q.y, q.z, q.w)
end

local function create(wp, def, solid)
  local g = group()
  if not g then return nil end
  serial = serial + 1
  local name = P.PREFIX .. serial
  local obj = call(function ()
    local o = createObject('TSStatic')
    o:setField('shapeName', 0, def.shape)
    local col = solid and 'Collision Mesh' or 'None'
    o:setField('collisionType', 0, col)
    o:setField('decalType', 0, col)
    o.canSave = false
    o:registerObject(name)
    return o
  end)
  if not obj then
    log('E', 'raceManager', 'Props: could not create ' .. tostring(def.id))
    return nil
  end
  pcall(function () g:addObject(obj) end)
  pcall(setPose, obj, wp, def)
  return call(function () return obj:getId() end)
end

local function remove(i)
  local s = spawned[i]
  if not s then return end
  spawned[i] = nil
  local obj = findOurs(s.id)
  if obj then pcall(function () obj:delete() end) end
  -- A deleted solid prop leaves its collision behind until the rebuild.
  if s.solid then dirty = true end
end

local function hasMoved(s, wp)
  return math.abs(s.x - wp.x) > 1e-3 or math.abs(s.y - wp.y) > 1e-3
      or math.abs(s.z - wp.z) > 1e-3 or math.abs(s.hx - (wp.hx or 0)) > 1e-4
      or math.abs(s.hy - (wp.hy or 1)) > 1e-4
end

local function remember(s, wp)
  s.x, s.y, s.z, s.hx, s.hy = wp.x, wp.y, wp.z, wp.hx or 0, wp.hy or 1
end

-- --------------------------------------------------------------------------
-- Solid or ghost
-- --------------------------------------------------------------------------

local function carPos()
  local veh = host and host.ownVehicle and host.ownVehicle()
  if not veh then return nil end
  return call(function () return veh:getPosition() end)
end

local function nearCar(wp, def, car)
  if not car then return false end
  local dx, dy = wp.x - car.x, wp.y - car.y
  local reach = (def.r or 1) + P.CAR_R
  return dx * dx + dy * dy < reach * reach and math.abs(wp.z - car.z) < 4
end

-- `promote`: this frame may turn a ghost solid.
local function wantSolid(wp, def, s, promote, car)
  if wp.solid == false then return false end
  if host and host.editing and host.editing() then return false end
  if s and s.solid then return true end
  if not promote then return false end
  if host and host.busy and host.busy() then return false end
  return not nearCar(wp, def, car)
end

-- --------------------------------------------------------------------------
-- The frame
-- --------------------------------------------------------------------------

function P.update(dt)
  dt = tonumber(dt) or 0
  recheck = recheck - dt
  local promote = recheck <= 0
  if promote then recheck = P.RECHECK end
  -- Read once a frame, and only when something may turn solid.
  local car
  local changed = false
  for i, wp in ipairs(P.list) do
    local def = P.BY_ID[wp.kind]
    local s = spawned[i]
    if not def then
      if s then remove(i); changed = true end
    else
      -- A new prop may start solid; a ghost is reconsidered on the tick.
      local may = promote or s == nil
      if may and car == nil then car = carPos() or false end
      local solid = wantSolid(wp, def, s, may, car or nil)
      -- Gone from the scene (a level reload): checked on the tick, not per frame.
      if s and (s.kind ~= wp.kind or s.solid ~= solid
                or (promote and not findOurs(s.id))) then
        remove(i)
        s = nil
      end
      if not s then
        local id = create(wp, def, solid)
        if id then
          s = { id = id, kind = wp.kind, solid = solid }
          remember(s, wp)
          spawned[i] = s
          if solid then dirty = true end
          changed = true
        end
      elseif hasMoved(s, wp) then
        local obj = findOurs(s.id)
        if obj then pcall(setPose, obj, wp, def) end
        remember(s, wp)
        if s.solid then dirty = true end
      end
    end
  end
  for i in pairs(spawned) do
    if not P.list[i] then remove(i); changed = true end
  end
  if changed then settle = P.SETTLE end
  if dirty then
    settle = settle - dt
    if settle <= 0 then P.rebuild() end
  end
end

-- The level's collision, rebuilt once a batch of changes has settled.
function P.rebuild()
  dirty, settle = false, 0
  if not (be and be.reloadCollision) then return end
  local ok, err = pcall(function () be:reloadCollision() end)
  if ok then
    log('I', 'raceManager', 'Props: collision rebuilt')
  else
    log('E', 'raceManager', 'Props: collision rebuild failed: ' .. tostring(err))
  end
end

-- The level is going away and its objects with it: drop the ids, delete
-- nothing (they may already belong to the next level).
function P.forget()
  spawned = {}
  groupId = nil
  dirty, settle = false, 0
end

-- Everything out of the world (unload, or leaving the server).
function P.destroy()
  for i in pairs(spawned) do remove(i) end
  local g = findOurs(groupId)
  if g then deleteGroup(g) end
  groupId = nil
  if dirty then P.rebuild() end
end

-- --------------------------------------------------------------------------
-- Editing
-- --------------------------------------------------------------------------

-- Down onto the ground under it. Probed from a little above, so a prop dragged
-- up a slope is found again; props are ghosts while edited, so this is the road.
function P.seat(wp)
  if not (host and host.groundAt) then return end
  local g = host.groundAt(wp.x, wp.y, wp.z + 0.3)
  if g then wp.z = g end
end

-- A new prop from a placement. `driven`: the car's own position, so it goes in
-- front of the car rather than inside it. `kind` defaults to the next prop's.
function P.fromPlace(place, driven, kind)
  kind = P.validKind(kind) or P.validKind(P.kind) or 'cone'
  local wp = { x = place.x, y = place.y, z = place.z,
               hx = place.hx or 0, hy = place.hy or 1, kind = kind }
  if driven then
    local ahead = P.AHEAD + (P.BY_ID[kind].r or 1)
    wp.x, wp.y = wp.x + wp.hx * ahead, wp.y + wp.hy * ahead
  end
  P.seat(wp)
  return wp
end

-- Where to stand the car to look at a prop: behind it, facing it.
function P.viewpoint(wp)
  local def = P.BY_ID[wp.kind] or {}
  local back = P.AHEAD + (def.r or 1) + 2
  local hx, hy = tonumber(wp.hx) or 0, tonumber(wp.hy) or 1
  return { x = wp.x - hx * back, y = wp.y - hy * back, z = wp.z + 0.5, hx = hx, hy = hy }
end

-- The kind for the next prop (no index), or re-kind a placed one.
function P.setKind(kind, index)
  local k = P.validKind(kind)
  if not k then return false end
  local i = tonumber(index)
  if i then
    local wp = P.list[math.floor(i)]
    if not wp then return false end
    wp.kind = k
  else
    P.kind = k
  end
  return true
end

function P.setSolid(index, on)
  local wp = P.list[math.floor(tonumber(index) or 0)]
  if not wp then return false end
  -- Not `and false or nil`: that is always nil.
  if on == false then wp.solid = false else wp.solid = nil end
  return true
end

-- Half a turn: a sign whose face is on the far side.
function P.flip(index)
  local wp = P.list[math.floor(tonumber(index) or 0)]
  if not wp then return false end
  wp.hx, wp.hy = -(tonumber(wp.hx) or 0), -(tonumber(wp.hy) or 1)
  return true
end

-- --------------------------------------------------------------------------
-- Layout data
-- --------------------------------------------------------------------------

-- For a save: plain fields only; an unknown kind or a bad number is dropped.
function P.bundle()
  local out = {}
  for _, wp in ipairs(P.list) do
    local x, y, z = tonumber(wp.x), tonumber(wp.y), tonumber(wp.z)
    if x and y and z and P.validKind(wp.kind) and #out < P.MAX then
      local e = { kind = wp.kind, x = x, y = y, z = z,
                  hx = tonumber(wp.hx) or 0, hy = tonumber(wp.hy) or 1 }
      if wp.solid == false then e.solid = false end
      out[#out + 1] = e
    end
  end
  return out
end

-- From a layout. Unknown kinds are dropped: a newer client's prop on an older one.
function P.unbundle(raw)
  local out = {}
  if type(raw) ~= 'table' then return out end
  for _, p in ipairs(raw) do
    if type(p) == 'table' and P.validKind(p.kind) then
      local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z)
      if x and y and z then
        local wp = { kind = p.kind, x = x, y = y, z = z,
                     hx = tonumber(p.hx) or 0, hy = tonumber(p.hy) or 1 }
        if p.solid == false then wp.solid = false end
        out[#out + 1] = wp
        if #out >= P.MAX then break end
      end
    end
  end
  return out
end

-- How many are in the world, and how many of those are solid (tests, console).
function P.status()
  local n, solid = 0, 0
  for _, s in pairs(spawned) do
    n = n + 1
    if s.solid then solid = solid + 1 end
  end
  return { placed = #P.list, spawned = n, solid = solid, pending = dirty }
end

-- --------------------------------------------------------------------------
-- The editor overlay: a pin and a label per prop, on the Props tab only
-- --------------------------------------------------------------------------

function P.draw()
  if not (debugDrawer and host and host.overlay and host.overlay()) then return end
  local pal = host.palette and host.palette()
  if not pal then return end
  for i, wp in ipairs(P.list) do
    local def = P.BY_ID[wp.kind]
    if def then
      local sel = host.selected and host.selected(i)
      local col = sel and pal.nudged or (pal.prop or pal.markerLine)
      local top = wp.z + (def.h or 1) + 0.6
      pcall(function ()
        debugDrawer:drawCylinder(vec3(wp.x, wp.y, wp.z), vec3(wp.x, wp.y, top),
          sel and 0.08 or 0.04, col)
        debugDrawer:drawCylinder(vec3(wp.x, wp.y, wp.z + 0.05),
          vec3(wp.x + (wp.hx or 0) * 1.5, wp.y + (wp.hy or 1) * 1.5, wp.z + 0.05), 0.04, col)
        debugDrawer:drawTextAdvanced(vec3(wp.x, wp.y, top + 0.3),
          String('PROP ' .. i .. ' ' .. def.label .. (wp.solid == false and ' (ghost)' or '')),
          pal.text, true, false, pal.textBg)
      end)
    end
  end
end

return P
