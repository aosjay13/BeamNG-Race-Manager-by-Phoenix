-- Race Manager: DEMO DERBY, as its own module.
--
-- Its own module (the extension's locals ceiling): separate state, its own
-- server events (RM_Derby*), guihooks channels and editor.
--
-- THE CONTRACT: everything arrives once through init(host):
--   * plain functions (ownVehicle, pushNotice, releaseGridHold, ...)
--   * mutable scalars the extension owns (phase, isAdmin, ...) as GETTERS
--   * tables by reference (spectate, the shared derby reset allowance), but
--     ONLY where the extension clears them in place; a REASSIGNED field (such
--     as track.startPositions) needs a getter. tests/wiring_test.lua checks it.
-- The reset allowance is shared: this module writes host.resets.used and the
-- extension's reset code reads it.

local D = {}
local host

-- Called once by the extension. The two callbacks are installed here, not at
-- load, where `host` is still nil.
function D.init(h)
  host = h
  -- Only a live derby with this driver still in it spends or blocks resets.
  host.resets.active = function ()
    return D.derbyState.phase == 'running' and not D.derbyState.out
  end
  -- A stood-down driver keeps steering but loses the reset, which would reload
  -- the car out from under the freeze.
  host.spectate.derbyStoodDown = function () return D.derbyState.stoodDown == true end
end

-- ===========================================================================
-- DEMO DERBY (isolated module)
-- ===========================================================================
-- Never touches the racing state. Client side (only the client has physics):
--   * place boundary markers (the server owns the list),
--   * point-in-polygon of our car against the arena every frame; outside
--     starts the out-of-bounds countdown, zero reports RM_DerbyDisqualified,
--   * below the stop speed starts the stopped countdown, zero reports
--     RM_DerbyDemolished,
--   * draw the arena.

local DERBY_STOP_SPEED    = 0.7   -- m/s counted as stopped (above physics jiggle)
-- Seconds after GO before the stopped check arms: a released car takes a moment
-- to move. A gameplay value; retuning it is an admin's call.
local DERBY_START_GRACE   = 5
-- Seconds a car may sit still before the stopped TIMER starts, so a pause to
-- turn around or pick a target does not flash an elimination warning. Total
-- time to elimination is this plus the configured timer.
local DERBY_STOP_GRACE    = 10
local DERBY_POLE_HEIGHT   = 6     -- fallback wall height, until the server says
-- Fallback wall skirt below the boundary, until the server says. Declared here:
-- D.derbyState reads it, and a local used before its declaration is a nil global.
local DERBY_WALL_SKIRT    = 1.5
local DERBY_POLE_RADIUS   = 0.2

-- One table, for the locals ceiling.
D.derbyState = {
  phase     = 'idle',   -- idle | running | finished (mirrored from server)
  -- Decided, and running out its cool-down (see derbyStandDown).
  over      = false,
  boundary  = {},       -- ordered polygon vertices { x, y, z }
  -- Which editor authored `boundary`. Gameplay reads `boundary` either way; this
  -- only decides how the arena is drawn and which controls the panel offers.
  boundaryMode = 'polygon',  -- polygon | rect
  shape     = nil,      -- { cx, cy, cz, halfW, halfL, rot } while mode is 'rect'
  wallHeight = DERBY_POLE_HEIGHT,
  wallDepth  = DERBY_WALL_SKIRT,
  -- The Derby Editor sub-tab is open (authoring view vs driving view).
  editorOpen = false,
  oobLimit  = 5,        -- seconds (mirrored from server config)
  demoLimit = 10,
  mode = 'lms',   -- server-owned; mirrored so the offline panel matches
  starts    = {},       -- derby starting grid { x, y, z, hx, hy } (mirrored)
  slot      = nil,      -- start slot the server assigned us for this derby
  visualize = true,     -- Hide/Show toggle for the boundary + grid visuals
  oobLeft   = nil,      -- active out-of-bounds countdown, nil = inside
  demoLeft  = nil,      -- active stopped countdown, nil = moving
  -- The server says we are not in this derby (eliminated, or joined late).
  out       = false,
  -- We reported something and await the ruling: stops a timer firing twice.
  -- Separate from `out` because a ruling can send a driver back with a life.
  pending   = false,
  runTime   = 0,        -- local seconds since this derby went running
  warnShown = false,    -- whether the UI currently shows a warning
}


-- STAND THE CAR DOWN for the cool-down at the end of a derby. Neutralise the
-- inputs FIRST (throttle off, brakes on): a freeze over a floored pedal holds
-- the engine screaming and lets go when it lifts. Steering stays; the reset
-- goes (see spectate.derbyStoodDown).

local function derbyStandDown(down)
  if down == D.derbyState.stoodDown then return end
  D.derbyState.stoodDown = down
  -- OUR car: on a rival this would fight BeamMP's sync.
  local veh = host.ownVehicle()
  if down then
    if veh then
      -- Throttle off before anything locks.
      pcall(function ()
        veh:queueLuaCommand('input.event("throttle", 0, 1)')
        veh:queueLuaCommand('input.event("brake", 1, 1)')
        veh:queueLuaCommand('input.event("parkingbrake", 1, 1)')
      end)
    end
    host.setLocalVehicleFrozen(true, 'derby')
    host.pushNotice('derby', 'Derby over, hold still')
  else
    host.setLocalVehicleFrozen(false, 'derby')
    if veh then
      pcall(function ()
        veh:queueLuaCommand('input.event("brake", 0, 1)')
        veh:queueLuaCommand('input.event("parkingbrake", 0, 1)')
      end)
    end
  end
end

local function derbyPushWarning()
  guihooks.trigger('RaceManagerDerbyWarning', {
    oob     = D.derbyState.oobLeft,
    stopped = D.derbyState.demoLeft,
  })
  D.derbyState.warnShown = (D.derbyState.oobLeft ~= nil) or (D.derbyState.demoLeft ~= nil)
end

D.derbyClearWarnings = function ()
  D.derbyState.oobLeft, D.derbyState.demoLeft = nil, nil
  if D.derbyState.warnShown then derbyPushWarning() end
end

-- Ray-casting point-in-polygon on XY (height ignored: jumps must not trip it).
local function derbyPointInPolygon(px, py, poly)
  local inside = false
  local n = #poly
  local j = n
  for i = 1, n do
    local xi, yi = poly[i].x, poly[i].y
    local xj, yj = poly[j].x, poly[j].y
    if ((yi > py) ~= (yj > py))
        and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
      inside = not inside
    end
    j = i
  end
  return inside
end

-- Read through the host at the call: at load the host does not exist.
local function derbyLocalServerId() return host.localServerId() end

D.derbyUpdate = function (dt)
  if D.derbyState.phase ~= 'running' or D.derbyState.out or D.derbyState.pending then
    D.derbyClearWarnings()
    return
  end
  D.derbyState.runTime = D.derbyState.runTime + dt
  -- OUR car, not the watched one.
  local veh = host.ownVehicle()
  if not veh then
    D.derbyClearWarnings()
    return
  end
  local changed = false

  -- Out-of-bounds check (needs a real polygon: at least 3 markers).
  if #D.derbyState.boundary >= 3 then
    local pos = veh:getPosition()
    if derbyPointInPolygon(pos.x, pos.y, D.derbyState.boundary) then
      if D.derbyState.oobLeft then D.derbyState.oobLeft = nil; changed = true end
    else
      if not D.derbyState.oobLeft then
        D.derbyState.oobLeft = D.derbyState.oobLimit
      else
        D.derbyState.oobLeft = D.derbyState.oobLeft - dt
      end
      changed = true
      if D.derbyState.oobLeft <= 0 then
        D.derbyState.pending = true
        D.derbyClearWarnings()
        if host.inMultiplayer() then TriggerServerEvent('RM_DerbyDisqualified', '') end
        log('I', 'raceManager', 'Derby: out-of-bounds timer expired, reported disqualification')
        return
      end
    end
  end

  -- Stopped check, held off for the start grace. TWO CLOCKS: `stoppedFor` runs
  -- from the stop, `demoLeft` only after DERBY_STOP_GRACE. Moving clears both.
  local vel = veh:getVelocity()
  local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
  if speed > DERBY_STOP_SPEED or D.derbyState.runTime < DERBY_START_GRACE then
    D.derbyState.stoppedFor = 0
    if D.derbyState.demoLeft then D.derbyState.demoLeft = nil; changed = true end
  else
    D.derbyState.stoppedFor = (D.derbyState.stoppedFor or 0) + dt
    -- Inside the grace: no countdown and nothing pushed.
    if D.derbyState.stoppedFor < DERBY_STOP_GRACE then
      if D.derbyState.demoLeft then D.derbyState.demoLeft = nil; changed = true end
      if changed then derbyPushWarning() end
      return
    end
    if not D.derbyState.demoLeft then
      D.derbyState.demoLeft = D.derbyState.demoLimit
    else
      D.derbyState.demoLeft = D.derbyState.demoLeft - dt
    end
    changed = true
    if D.derbyState.demoLeft <= 0 then
      D.derbyState.pending = true
      D.derbyClearWarnings()
      if host.inMultiplayer() then TriggerServerEvent('RM_DerbyDemolished', '') end
      log('I', 'raceManager', 'Derby: stopped timer expired, reported demolition')
      return
    end
  end

  if changed then derbyPushWarning() end
end

-- Arena walls: one vertical panel per edge, for both arena kinds.
--   * A rectangle's corners all sit at the CENTER's z, so on a slope the walls
--     start a skirt BELOW the boundary and cut into the uphill terrain.
--   * Each panel is drawn twice, winding reversed: drivers look out from inside.
local function derbyBuildWalls(boundary, height, depth)
  local n = #boundary
  local walls = {}
  if n < 2 then return walls end
  for i = 1, n do
    local a = boundary[i]
    local b = boundary[i % n + 1]
      -- Two markers is a line: one panel, not the same one twice.
    if not (n == 2 and i == 2) then
      local a0 = vec3(a.x, a.y, a.z - depth)
      local b0 = vec3(b.x, b.y, b.z - depth)
      local a1 = vec3(a.x, a.y, a.z + height)
      local b1 = vec3(b.x, b.y, b.z + height)
      walls[#walls + 1] = { bl = a0, br = b0, tr = b1, tl = a1 }
    end
  end
  return walls
end

-- Unconditional while the derby runs; the Hide/Show toggle applies otherwise.
D.derbyDrawBoundary = function ()
  if not debugDrawer then return end
  if D.derbyState.phase ~= 'running' and not D.derbyState.visualize then return end

  -- Authoring view only for an admin with the Derby Editor open, before form-up.
  local authoring = D.derbyState.editorOpen and host.isAdmin()
    and D.derbyState.phase ~= 'running' and D.derbyState.phase ~= 'countdown'
    and D.derbyState.phase ~= 'forming'

  -- Start slots are editor furniture. While the field forms up a driver sees
  -- only their own slot; once running, none. The boundary is never hidden.
  if D.derbyState.phase ~= 'running' then
    if authoring then
      for i, sp in ipairs(D.derbyState.starts) do
        host.drawStartPosition(sp, i, D.derbyState.slot == i)
      end
    elseif D.derbyState.slot and D.derbyState.starts[D.derbyState.slot] then
      host.drawStartPosition(D.derbyState.starts[D.derbyState.slot], D.derbyState.slot, true)
    end
  end
  -- The point Place mode holds, drawn as its own post so the cached arena is not
  -- rebuilt; before the early return, so a rectangle's center shows too.
  if authoring then
    local pick = host.nudgePick and host.nudgePick() or nil
    if pick and pick.x then
      local col = host.palette().nudged
      local base = vec3(pick.x, pick.y, pick.z)
      local top  = vec3(pick.x, pick.y, pick.z + DERBY_POLE_HEIGHT)
      pcall(function ()
        debugDrawer:drawCylinder(base, top, DERBY_POLE_RADIUS * 1.6, col)
        debugDrawer:drawSphere(top, DERBY_POLE_RADIUS * 3, col)
      end)
    end
  end

  local boundary = D.derbyState.boundary
  local n = #boundary
  if n == 0 then return end

  -- Cached geometry, keyed on the boundary table's identity (onDerbyUpdate keeps
  -- it when the markers have not moved), plus height, depth and the view.
  local height = D.derbyState.wallHeight or DERBY_POLE_HEIGHT
  local depth  = D.derbyState.wallDepth or DERBY_WALL_SKIRT
  local cache = D.derbyState.draw
  if not cache or cache.src ~= boundary or cache.height ~= height
      or cache.depth ~= depth or cache.authoring ~= authoring then
    cache = { src = boundary, height = height, depth = depth, authoring = authoring }
    cache.walls = derbyBuildWalls(boundary, height, depth)
    -- Corner posts, so a translucent wall shows against a bright sky.
    cache.posts = {}
    for i, m in ipairs(boundary) do
      local base = vec3(m.x, m.y, m.z - depth)
      cache.posts[i] = { a = base, b = vec3(m.x, m.y, m.z + height) }
    end
    -- Top and ground rails; the ground rail is what a driver judges the edge by.
    cache.topRail, cache.baseRail = {}, {}
    if n > 1 then
      for i = 1, n do
        local a, b = boundary[i], boundary[i % n + 1]
        if not (n == 2 and i == 2) then
          cache.topRail[#cache.topRail + 1] = {
            a = vec3(a.x, a.y, a.z + height), b = vec3(b.x, b.y, b.z + height) }
          cache.baseRail[#cache.baseRail + 1] = {
            a = vec3(a.x, a.y, a.z + 0.05), b = vec3(b.x, b.y, b.z + 0.05) }
        end
      end
    end
    if authoring then
      -- Editor furniture: labels, and for a rectangle its floor and center cross.
      local first = boundary[1]
      cache.labelAt = vec3(first.x, first.y, first.z + height + 0.8)
      local s = D.derbyState.shape
      if D.derbyState.boundaryMode == 'rect' and s then
        cache.label = string.format('DERBY ARENA: %.0f x %.0f m', s.halfW * 2, s.halfL * 2)
        -- Convex with four corners: one quad, no triangulation.
        if n == 4 then
          cache.floor = {}
          for i, m in ipairs(boundary) do
            cache.floor[i] = vec3(m.x, m.y, m.z + 0.06)
          end
        end
        cache.center = {
          at = vec3(s.cx, s.cy, s.cz),
          -- A center cross, turned with the rectangle.
          armA = { a = vec3(s.cx - math.cos(s.rot) * 3, s.cy - math.sin(s.rot) * 3, s.cz + 0.1),
                   b = vec3(s.cx + math.cos(s.rot) * 3, s.cy + math.sin(s.rot) * 3, s.cz + 0.1) },
          armB = { a = vec3(s.cx + math.sin(s.rot) * 3, s.cy - math.cos(s.rot) * 3, s.cz + 0.1),
                   b = vec3(s.cx - math.sin(s.rot) * 3, s.cy + math.cos(s.rot) * 3, s.cz + 0.1) },
          label = string.format('CENTER: %.0f deg', math.deg(s.rot)),
          labelAt = vec3(s.cx, s.cy, s.cz + 1.6),
        }
      else
        cache.label = 'DERBY BOUNDARY (' .. n .. ')'
      end
      cache.cornerLabels = {}
      for i, m in ipairs(boundary) do
        cache.cornerLabels[i] = { at = vec3(m.x, m.y, m.z + height + 0.2), text = 'M' .. i }
      end
    end
    D.derbyState.draw = cache
  end

  local p = host.palette()
  local edge = (D.derbyState.phase == 'running') and p.derbyLive or p.derbySetup
  local face = authoring and p.derbyWallEdit or p.derbyWallLive

  -- The walls, twice each (see derbyBuildWalls).
  for _, w in ipairs(cache.walls) do
    debugDrawer:drawQuadSolid(w.bl, w.br, w.tr, w.tl, face)
    debugDrawer:drawQuadSolid(w.tl, w.tr, w.br, w.bl, face)
  end

  if authoring then
    -- Floor for rectangles only: fanning a concave hand-driven polygon would
    -- paint outside the arena.
    if cache.floor then
      debugDrawer:drawQuadSolid(cache.floor[1], cache.floor[2],
        cache.floor[3], cache.floor[4], p.derbyFloor)
    end
    for _, post in ipairs(cache.posts) do
      debugDrawer:drawCylinder(post.a, post.b, DERBY_POLE_RADIUS, edge)
    end
    for _, r in ipairs(cache.topRail) do
      debugDrawer:drawCylinder(r.a, r.b, DERBY_POLE_RADIUS * 0.5, edge)
    end
    for _, r in ipairs(cache.baseRail) do
      debugDrawer:drawCylinder(r.a, r.b, DERBY_POLE_RADIUS * 0.5, edge)
    end
    debugDrawer:drawTextAdvanced(cache.labelAt, String(cache.label),
      p.text, true, false, p.derbyLabelBg)
    for _, cl in ipairs(cache.cornerLabels) do
      debugDrawer:drawTextAdvanced(cl.at, String(cl.text), p.text, true, false, p.derbyLabelBg)
    end
    if cache.center then
      debugDrawer:drawCylinder(cache.center.armA.a, cache.center.armA.b, 0.12, edge)
      debugDrawer:drawCylinder(cache.center.armB.a, cache.center.armB.b, 0.12, edge)
      debugDrawer:drawTextAdvanced(cache.center.labelAt, String(cache.center.label),
        p.text, true, false, p.derbyLabelBg)
    end
  else
    -- Driving view: just enough edge to read the wall.
    for _, r in ipairs(cache.baseRail) do
      debugDrawer:drawCylinder(r.a, r.b, DERBY_POLE_RADIUS * 0.4, edge)
    end
    for _, post in ipairs(cache.posts) do
      debugDrawer:drawCylinder(post.a, post.b, DERBY_POLE_RADIUS * 0.5, edge)
    end
  end
end

-- --- Derby UI commands (called by the UI app) ------------------------------

function D.derbyAddMarker()
  local veh = host.ownVehicle()
  if not veh then
    log('W', 'raceManager', 'Derby: no player vehicle, cannot place boundary marker')
    return
  end
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local pos = veh:getPosition()
  TriggerServerEvent('RM_DerbyAddMarker', jsonEncode({ x = pos.x, y = pos.y, z = pos.z }))
end

function D.derbyClearBoundary()
  if host.inMultiplayer() then TriggerServerEvent('RM_DerbyClearBoundary', '') end
end

-- --- Rectangle arena (the other boundary editor) ---------------------------
-- Switch between marker-by-marker and a rectangle from a center; neither loses
-- the other's work. The car's position is the center when there is no arena.
function D.derbySetBoundaryMode(mode)
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  mode = (mode == 'rect') and 'rect' or 'polygon'
  local payload = { mode = mode }
  local veh = host.ownVehicle()
  if veh then
    local pos = veh:getPosition()
    payload.cx, payload.cy, payload.cz = pos.x, pos.y, pos.z
  elseif mode == 'rect' and #D.derbyState.boundary < 3 then
    guihooks.trigger('RaceManagerEditorMsg', {
      msg = 'Get in a vehicle first: the rectangle needs a center' })
    return
  end
  TriggerServerEvent('RM_DerbySetBoundaryMode', jsonEncode(payload))
end

-- Re-center the rectangle on the car.
function D.derbySetShapeCenter()
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local veh = host.ownVehicle()
  if not veh then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  local pos = veh:getPosition()
  TriggerServerEvent('RM_DerbySetShape',
    jsonEncode({ cx = pos.x, cy = pos.y, cz = pos.z }))
end

-- Size, turn and wall height from the sliders; every argument is optional and
-- the server keeps what is left out. Width and length are FULL spans.
function D.derbySetShape(width, length, rotDeg, wallHeight, wallDepth)
  if not host.inMultiplayer() then return end
  local payload = {}
  local w, l = tonumber(width), tonumber(length)
  local r, h = tonumber(rotDeg), tonumber(wallHeight)
  if w then payload.halfW = w * 0.5 end
  if l then payload.halfL = l * 0.5 end
  if r then payload.rot = math.rad(r) end
  if h then payload.wallHeight = h end
  local dp = tonumber(wallDepth)
  if dp then payload.wallDepth = dp end
  if next(payload) == nil then return end
  TriggerServerEvent('RM_DerbySetShape', jsonEncode(payload))
end

-- `resetLimit`, not `maxResets` (the race allowance's name). `lives` and `mode`
-- are optional, so an older UI's shorter call still works; the server ignores
-- a mode it does not recognise, nil included.
function D.derbySetConfig(oobLimit, demoLimit, resetLimit, lives, mode)
  if host.inMultiplayer() then
    TriggerServerEvent('RM_DerbySetConfig', jsonEncode({
      oobLimit = tonumber(oobLimit), demoLimit = tonumber(demoLimit),
      maxResets = tonumber(resetLimit),
      lives = tonumber(lives),
      mode = (mode == 'lms' or mode == 'dm') and mode or nil,
    }))
  end
end

-- --- Derby starting grid (admin) -------------------------------------------
-- Same workflow as the race grid; the server owns the list and assigns slots.
function D.derbyAddStartPosition()
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local place = host.vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  TriggerServerEvent('RM_DerbyAddStart', jsonEncode(place))
end

function D.derbyClearStartPositions()
  if host.inMultiplayer() then TriggerServerEvent('RM_DerbyClearStarts', '') end
end

-- --- Derby marker / start slot editing -------------------------------------
-- The arena is the SERVER's, so a move sends the index and the car's placement
-- and waits for the broadcast; only the preview is local.
function D.derbyMoveMarker(index)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local veh = host.ownVehicle()
  if not veh then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  local pos = veh:getPosition()
  TriggerServerEvent('RM_DerbyMoveMarker',
    jsonEncode({ index = index, x = pos.x, y = pos.y, z = pos.z }))
end

function D.derbyRemoveMarker(index)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if host.inMultiplayer() then
    TriggerServerEvent('RM_DerbyRemoveMarker', jsonEncode({ index = index }))
  end
end

function D.derbyMoveStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local place = host.vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  place.index = index
  TriggerServerEvent('RM_DerbyMoveStart', jsonEncode(place))
end

function D.derbyRemoveStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if host.inMultiplayer() then
    TriggerServerEvent('RM_DerbyRemoveStart', jsonEncode({ index = index }))
  end
end

-- Preview: stand the car on a placed entry. Local, never frozen.
function D.derbyPreviewStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  local sp = D.derbyState.starts[index]
  if not sp then return end
  if not host.placeOnStartPosition(sp) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Could not move the vehicle' })
  end
end

-- A boundary marker has no facing, so the car keeps its own heading.
function D.derbyPreviewMarker(index)
  index = math.floor(tonumber(index) or 0)
  local m = D.derbyState.boundary[index]
  if not m then return end
  local place = host.vehiclePlacement()
  if not place then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  if not host.placeOnStartPosition({ x = m.x, y = m.y, z = m.z, hx = place.hx, hy = place.hy }) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Could not move the vehicle' })
  end
end

-- ===========================================================================
-- PLACE MODE: the mouse editing the race editor already has, on the arena
-- ===========================================================================
-- The extension owns the mouse and picking; this answers WHICH list a derby
-- target means and HOW a change reaches the server (every change is a request;
-- a drag moves the local copy and sends once on release). Refused while a derby
-- is live, as the server refuses it too.

-- The arena center as a one-element PROXY list for Place mode, so a drag can
-- never write into the shape's extents. Synced from each broadcast, mutated by
-- a drag in between; identity kept so a held selection survives.
D.centreList = {}

function D.syncCentreList()
  local s = D.derbyState.shape
  if not s then D.centreList[1] = nil; return end
  local c = D.centreList[1]
  if not c then c = {}; D.centreList[1] = c end
  c.x, c.y, c.z = s.cx, s.cy, s.cz
  -- A facing for drawing; the Rotation slider owns it.
  c.hx, c.hy = math.sin(s.rot or 0), math.cos(s.rot or 0)
end

-- Which list a Place-mode target means, or nil (not ours: race targets).
function D.editList(target)
  if target == 'derbyMarker' then
    -- Rectangle corners are derived from the shape: the center is the handle.
    if D.derbyState.boundaryMode == 'rect' then return nil end
    return D.derbyState.boundary
  end
  if target == 'derbyStart'  then return D.derbyState.starts end
  if target == 'derbyCenter' then
    if D.derbyState.boundaryMode ~= 'rect' then return nil end
    return D.centreList
  end
  return nil
end

-- Can the arena be edited now? The panel greys out on the same answer.
function D.editAllowed()
  return D.derbyState.phase ~= 'running' and host.inMultiplayer()
end

-- Ctrl+click. The center exists once and is only ever moved.
function D.editPlace(target, place)
  if not (D.editAllowed() and place) then return false end
  if target == 'derbyMarker' then
    TriggerServerEvent('RM_DerbyAddMarker',
      jsonEncode({ x = place.x, y = place.y, z = place.z }))
    return true
  end
  if target == 'derbyStart' then
    TriggerServerEvent('RM_DerbyAddStart', jsonEncode({
      x = place.x, y = place.y, z = place.z,
      hx = place.hx or 0, hy = place.hy or 1,
    }))
    return true
  end
  return false
end

-- A drag ended or a button moved the entry; `wp` is already moved locally.
function D.editMove(target, index, wp)
  if not (D.editAllowed() and wp) then return false end
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return false end
  if target == 'derbyMarker' then
    TriggerServerEvent('RM_DerbyMoveMarker',
      jsonEncode({ index = index, x = wp.x, y = wp.y, z = wp.z }))
    return true
  end
  if target == 'derbyStart' then
    TriggerServerEvent('RM_DerbyMoveStart', jsonEncode({
      index = index, x = wp.x, y = wp.y, z = wp.z,
      hx = wp.hx or 0, hy = wp.hy or 1,
    }))
    return true
  end
  if target == 'derbyCenter' then
    -- Only the center: RM_DerbySetShape keeps whatever it is not sent.
    TriggerServerEvent('RM_DerbySetShape',
      jsonEncode({ cx = wp.x, cy = wp.y, cz = wp.z }))
    return true
  end
  return false
end

function D.editRemove(target, index)
  if not D.editAllowed() then return false end
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return false end
  if target == 'derbyMarker' then
    TriggerServerEvent('RM_DerbyRemoveMarker', jsonEncode({ index = index }))
    return true
  end
  if target == 'derbyStart' then
    TriggerServerEvent('RM_DerbyRemoveStart', jsonEncode({ index = index }))
    return true
  end
  -- The center cannot be deleted: switch the boundary mode instead.
  return false
end

-- The Derby Editor sub-tab: a client-local render gate.
function D.setDerbyEditorOpen(open)
  D.derbyState.editorOpen = open == true
end

-- Hide/Show the derby visuals (client-local).
function D.derbyToggleVisualize()
  D.derbyState.visualize = not D.derbyState.visualize
  guihooks.trigger('RaceManagerDerbyVisual', { visualize = D.derbyState.visualize })
end


-- Form up: every participant on their slot, held for the countdown.
function D.derbyFormUp()
  if host.inMultiplayer() then TriggerServerEvent('RM_DerbyFormUp', '') end
end

function D.derbyStart()
  if host.inMultiplayer() then TriggerServerEvent('RM_DerbyStart', '') end
end

function D.derbyEnd()
  if host.inMultiplayer() then TriggerServerEvent('RM_DerbyEnd', '') end
end

-- Ready check, refused with no car.
function D.derbyReady(on)
  if not host.inMultiplayer() then return end
  if on ~= false and not host.ownVehicle() then
    host.pushNotice('derby', 'Get in a car first', { sub = 'Then press Ready' })
    return
  end
  TriggerServerEvent('RM_DerbyReady', jsonEncode({ ready = on ~= false }))
end

-- Admin: ready one driver whose panel is closed, or everyone still called.
function D.derbyReadyDriver(pid)
  pid = tonumber(pid)
  if pid and host.inMultiplayer() then
    TriggerServerEvent('RM_DerbyReady', jsonEncode({ ready = true, pid = pid }))
  end
end

function D.derbyReadyAll()
  if host.inMultiplayer() then TriggerServerEvent('RM_DerbyReadyAll', '') end
end

function D.derbyRequestState()
  if host.inMultiplayer() then
    TriggerServerEvent('RM_DerbyRequestState', '')
    TriggerServerEvent('RM_DerbyRequestLayouts', '')
  else
    guihooks.trigger('RaceManagerDerby', {
      derbyPhase = 'idle', derbyMode = D.derbyState.mode,
      oobLimit = D.derbyState.oobLimit, demoLimit = D.derbyState.demoLimit,
      maxResets = host.resets.max, derbyTime = 0, boundary = {},
      boundaryMode = 'polygon', shape = nil, wallHeight = D.derbyState.wallHeight,
      wallDepth = D.derbyState.wallDepth,
      startPositions = {}, players = {},
    })
  end
end

-- --- Derby arena layouts (server-side, per map) -----------------------------
function D.derbySaveLayout(name)
  name = tostring(name or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Enter an arena name first' })
    return
  end
  if #D.derbyState.boundary < 3 then
    guihooks.trigger('RaceManagerEditorMsg', {
      msg = 'Place at least 3 boundary markers before saving an arena' })
    return
  end
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Arena layouts need a BeamMP server' })
    return
  end
  local markers = {}
  for i, m in ipairs(D.derbyState.boundary) do
    local x, y, z = tonumber(m.x), tonumber(m.y), tonumber(m.z)
    if not (x and y and z) then
      guihooks.trigger('RaceManagerEditorMsg', {
        msg = 'Save failed: boundary marker ' .. i .. ' is invalid' })
      return
    end
    markers[i] = { x = x, y = y, z = z }
  end
  -- The start grid travels with the arena.
  local starts = nil
  if #D.derbyState.starts > 0 then
    starts = {}
    for i, sp in ipairs(D.derbyState.starts) do
      starts[i] = { x = sp.x, y = sp.y, z = sp.z, hx = sp.hx, hy = sp.hy }
    end
  end
  -- A rectangle saves its shape AND its polygon, so it reloads editable and
  -- loadable by polygon-only readers.
  TriggerServerEvent('RM_DerbySaveLayout', jsonEncode({
    name = name, boundary = markers,
    boundaryMode = D.derbyState.boundaryMode,
    shape = D.derbyState.shape,
    wallHeight = D.derbyState.wallHeight,
    wallDepth  = D.derbyState.wallDepth,
    oobLimit = D.derbyState.oobLimit, demoLimit = D.derbyState.demoLimit,
    maxResets = host.resets.max, startPositions = starts,
  }))
end

function D.derbyRequestLayouts()
  if host.inMultiplayer() then TriggerServerEvent('RM_DerbyRequestLayouts', '') end
end

function D.derbyLoadLayout(name)
  name = tostring(name or '')
  if name == '' then return end
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Arena layouts need a BeamMP server' })
    return
  end
  TriggerServerEvent('RM_DerbyLoadLayout', jsonEncode({ name = name }))
end

function D.derbyDeleteLayout(name)
  name = tostring(name or '')
  if name == '' then return end
  if host.inMultiplayer() then
    TriggerServerEvent('RM_DerbyDeleteLayout', jsonEncode({ name = name }))
  end
end

-- --- Derby server -> client ------------------------------------------------

D.onDerbyUpdate = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  if not host.fromCurrentServer(data) then return end

  local newPhase = data.derbyPhase or 'idle'
  -- Decided, running out the cool-down (see the stand-down below).
  D.derbyState.over = data.derbyOver == true
  if newPhase == 'running' and D.derbyState.phase ~= 'running' then
    -- Fresh derby: clean slate, resets included.
    D.derbyState.out = false
    D.derbyState.pending = false
    D.derbyState.runTime = 0
    D.derbyState.stoppedFor = 0
    host.resets.used = 0
    D.derbyClearWarnings()
  elseif newPhase ~= 'running' then
    if D.derbyState.phase == 'running' then D.derbyState.slot = nil end
    D.derbyClearWarnings()
  end
  -- An ended derby releases a form-up hold (only its own).
  if newPhase == 'idle' or newPhase == 'finished' then
    host.releaseGridHold('derby')
  end
  -- Practice is between sessions, and a derby is one.
  if (newPhase == 'forming' or newPhase == 'countdown' or newPhase == 'running')
     and host.practiceStop then
    host.practiceStop('derby')
  end
  D.derbyState.phase = newPhase

  D.derbyState.oobLimit  = tonumber(data.oobLimit)  or D.derbyState.oobLimit
  D.derbyState.demoLimit = tonumber(data.demoLimit) or D.derbyState.demoLimit
  if data.derbyMode == 'lms' or data.derbyMode == 'dm' then
    D.derbyState.mode = data.derbyMode
  end
  if type(data.maxResets) == 'number' then
    host.resets.max = math.floor(data.maxResets)
  end

  local boundary = {}
  if type(data.boundary) == 'table' then
    for i, m in ipairs(data.boundary) do
      local x, y, z = tonumber(m.x), tonumber(m.y), tonumber(m.z)
      if x and y and z then boundary[#boundary + 1] = { x = x, y = y, z = z } end
    end
  end
  -- Keep the existing table when the markers have not moved: swapping it IS
  -- the draw cache's invalidation, and the only one.
  local same = #boundary == #D.derbyState.boundary
  if same then
    for i, m in ipairs(boundary) do
      local o = D.derbyState.boundary[i]
      if o.x ~= m.x or o.y ~= m.y or o.z ~= m.z then same = false; break end
    end
  end
  if not same then D.derbyState.boundary = boundary end

  -- Server-owned, so every client draws the same arena; neither affects the
  -- out-of-bounds test.
  D.derbyState.boundaryMode = (data.boundaryMode == 'rect') and 'rect' or 'polygon'
  if type(data.wallHeight) == 'number' then D.derbyState.wallHeight = data.wallHeight end
  if type(data.wallDepth) == 'number' then D.derbyState.wallDepth = data.wallDepth end
  if D.derbyState.boundaryMode == 'rect' and type(data.shape) == 'table' then
    local s = data.shape
    local cx, cy, cz = tonumber(s.cx), tonumber(s.cy), tonumber(s.cz)
    if cx and cy and cz then
      D.derbyState.shape = {
        cx = cx, cy = cy, cz = cz,
        halfW = tonumber(s.halfW) or 0, halfL = tonumber(s.halfL) or 0,
        rot   = tonumber(s.rot) or 0,
      }
    end
  else
    D.derbyState.shape = nil
  end
  -- Synced here, not per frame, so a drag between broadcasts is not undone.
  D.syncCentreList()

  -- Derby starting grid (a placement + a facing per slot, like the race grid).
  local starts = {}
  if type(data.startPositions) == 'table' then
    for _, sp in ipairs(data.startPositions) do
      local x, y, z = tonumber(sp.x), tonumber(sp.y), tonumber(sp.z)
      if x and y and z then
        starts[#starts + 1] = { x = x, y = y, z = z,
          hx = tonumber(sp.hx) or 0, hy = tonumber(sp.hy) or 1 }
      end
    end
  end
  D.derbyState.starts = starts

  -- Stop policing if the server says we are out, or we are not a participant
  -- (joined after Start Derby).
  local myId = derbyLocalServerId()
  if myId and type(data.players) == 'table' then
    local mine = nil
    for _, p in ipairs(data.players) do
      if tonumber(p.id) == myId then mine = p; break end
    end
    -- `you` marks our row for the Ready button; the HUD says when we are first
    -- called, not after Not ready.
    local wasReady = D.derbyState.myReady
    D.derbyState.myReady = nil
    if mine and data.derbyPhase == 'forming' then D.derbyState.myReady = mine.ready end
    if mine then mine.you = true end
    if D.derbyState.myReady == false and wasReady == nil then
      host.pushNotice('derby', 'The derby is forming up',
        { sub = 'Press READY in Phoenix Race Manager (PRM) to take your slot' })
    end
    if mine then
      if mine.status ~= 'alive' then
        -- The ruling came back as an elimination.
        D.derbyState.out     = true
        D.derbyState.pending = false
      elseif D.derbyState.pending or D.derbyState.out then
        -- Still alive: the report was met with a life. Policing resumes, with
        -- the grace re-armed (this may arrive before onDerbyLifeLost moves the
        -- car, which is still sitting stopped).
        D.derbyState.out     = false
        D.derbyState.pending = false
        D.derbyState.runTime = 0
        D.derbyClearWarnings()
      end
    elseif D.derbyState.phase == 'running' then
      D.derbyState.out = true
    end
  end

  -- The stand-down, NOT for a driver already out: their wreck is a free-rolling
  -- obstacle (spectate.releaseControls) and standing it down re-applied the
  -- handbrake. Called AFTER `out` is read from this same payload, which matters
  -- on the broadcast that eliminates the last driver and ends the derby.
  derbyStandDown(D.derbyState.over and newPhase == 'running'
    and not D.derbyState.out)

  guihooks.trigger('RaceManagerDerby', data)
end

-- A LIFE SPENT, NOT A DERBY LOST: back to the start slot through the placement
-- queue (ghosted, solid once clear). NOT held: holding would be a second
-- penalty in a derby already running.
D.onDerbyLifeLost = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local lives = tonumber(data.lives) or 0
  local slot  = tonumber(data.slot)

  -- Clear the expired countdown before the car moves.
  D.derbyState.demoLeft = nil
  D.derbyState.oobLeft  = nil
  -- Back in, and policing again.
  D.derbyState.pending  = false
  D.derbyState.out      = false
  D.derbyClearWarnings()
  D.derbyState.stoppedFor = 0
  D.derbyState.runTime  = 0     -- re-arms the start grace for a car put down

  if slot then
    D.derbyState.slot = math.floor(slot)
    host.queueFieldPlacement({
      slot  = D.derbyState.slot,
      slots = D.derbyState.starts,
      hold  = false,
      holdSource = 'derby',
      order = 1, count = 1,      -- one car, not a field: no stagger to wait out
    })
  end
  host.pushNotice('derby', lives == 1
    and 'Counted out: 1 life left'
    or  ('Counted out: ' .. lives .. ' lives left'))
  log('I', 'raceManager', 'Derby: life lost, ' .. lives .. ' left, back to slot '
    .. tostring(slot))
end

D.onDerbyGridAssign = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  -- Not ready any more: off the slot, hold released.
  if data.release == true then
    D.derbyState.slot = nil
    host.releaseGridHold('derby')
    return
  end
  local slot = tonumber(data.slot)
  D.derbyState.slot = slot and math.floor(slot) or nil

  -- Through the placement queue, staggered by slot number. Form-up holds every
  -- participant until GO, slot or not; tagged 'derby' so a race phase change
  -- cannot release it.
  if D.derbyState.slot then
    host.queueFieldPlacement({
      slot  = D.derbyState.slot,
      slots = D.derbyState.starts,
      hold  = data.hold == true,
      holdSource = 'derby',
      -- A lone ready-up is 1 of 1 and lands at once.
      order = tonumber(data.order) or D.derbyState.slot,
      count = tonumber(data.count) or math.max(#D.derbyState.starts, D.derbyState.slot),
    })
  elseif data.hold == true then
    host.requestHold('derby')
  end
end

-- Derby countdown, on its own channel so neither countdown releases the other's
-- cars. GO (0) or an abort (-1) ends the hold.
D.onDerbyCountdown = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local count = tonumber(data.count)
  if count and count <= 0 then host.releaseGridHold('derby') end
  guihooks.trigger('RaceManagerCountdown', data)
  if host.lightsCountdown then host.lightsCountdown(count) end
end

-- The map's arena list.
D.onDerbyLayoutList = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    log('E', 'raceManager', 'RM_DerbyLayouts: undecodable payload')
    return
  end
  if type(data.layouts) ~= 'table' or #data.layouts == 0 then data.layouts = {} end
  guihooks.trigger('RaceManagerDerbyLayouts', data)
end

-- ===========================================================================
-- End of DEMO DERBY module
-- ===========================================================================

return D
