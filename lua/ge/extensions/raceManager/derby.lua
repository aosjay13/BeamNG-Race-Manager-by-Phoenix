-- Race Manager: DEMO DERBY, as its own module.
--
-- Split out of raceManager.lua because that file sat at exactly Lua's 200
-- active-locals ceiling, where the next `local` anybody added anywhere stopped
-- the whole mod compiling. A module gets its own budget, and this one was
-- already the cleanest seam in the file: separate state, its own server events
-- (RM_Derby*), its own guihooks channels, its own editor.
--
-- THE CONTRACT. Nothing here reaches back into the extension by name. Everything
-- it needs arrives once through `init(host)`:
--
--   * plain functions (playerVehicle, pushNotice, releaseGridHold, ...) are
--     called straight off the host table
--   * mutable scalars the extension owns (phase, isAdmin, visualize, ...) come
--     through GETTERS, because a value captured at init would be a snapshot of
--     whatever it happened to be when the file loaded
--   * tables (spectate, startPositions) and the shared derby reset allowance
--     come by reference, so both halves see the same object rather than copies
--     that drift
--
-- The reset allowance is genuinely shared and stays that way: the reset code in
-- the extension polices race and derby resets through one path, so this module
-- writes `host.resets.used` and that code reads it.

local D = {}
local host

-- Called once by the extension, before anything else here runs.
--
-- The two callbacks below are INSTALLED here rather than at load time, and that
-- ordering is the whole reason this function exists: at load `host` is still
-- nil, so a top-level `host.x = ...` is an index of nil and the module never
-- finishes loading. Both are the extension asking the derby a question it
-- cannot answer for itself.
function D.init(h)
  host = h
  -- The reset code asks this before policing the derby allowance: only a live
  -- derby with this driver still in it spends or blocks derby resets.
  host.resets.active = function ()
    return D.derbyState.phase == 'running' and not D.derbyState.out
  end
  -- Spectator input asks this: a driver stood down at the end of a derby keeps
  -- their steering but loses the reset, which would reload the vehicle out from
  -- under the freeze and hand them a driveable car in a settled result.
  host.spectate.derbyStoodDown = function () return D.derbyState.stoodDown == true end
end

-- ===========================================================================
-- DEMO DERBY (isolated module)
-- ===========================================================================
-- Fully independent of the circuit racing logic above: separate state, its
-- own server events (RM_Derby*), its own guihooks channels and its own
-- update/draw functions. It never touches `route`, `host.phase()`, `armedWp` or any
-- other racing variable, so a derby can never disturb qualifying/racing.
--
-- Client responsibilities (only the client has physics access):
--   * Place boundary markers at the local vehicle's position (admin action;
--     the server owns the ordered marker list and broadcasts it to everyone).
--   * Ray-casting point-in-polygon test of the local vehicle against the
--     arena polygon every frame; leaving it starts the out-of-bounds
--     countdown and a flashing full-screen warning. Re-entering clears it;
--     reaching zero reports RM_DerbyDisqualified.
--   * Track the local vehicle's speed; sitting below the jiggle threshold
--     starts the demolished countdown ("keep moving or you're out");
--     reaching zero reports RM_DerbyDemolished.
--   * Draw the boundary poles + perimeter rope in the 3D world.

local DERBY_STOP_SPEED    = 0.7   -- m/s; below this the car counts as stopped
                                  -- (generous enough to swallow physics jiggle)
-- Seconds after GO before the stopped-vehicle check arms. This used to exist
-- because there was no start procedure at all: cars sat parked waiting for
-- someone to say go, and would have been on the demolished clock immediately.
-- Form-up and the countdown removed that reason, but the timer is kept for the
-- one that is left -- a car released at GO takes a moment to actually move, and
-- nobody should be eliminated for reaction time. Deliberately unchanged rather
-- than retuned: it is a gameplay value, and shortening it is a balance call for
-- an admin to ask for, not a side effect of adding a countdown.
local DERBY_START_GRACE   = 5
-- HOW LONG A CAR MAY SIT STILL BEFORE THE STOPPED TIMER EVEN STARTS.
--
-- Separate from the countdown, and it is what makes the countdown mean
-- something. Stopping is a normal part of driving a derby: you back off a wall,
-- pause to pick a target, stop dead to turn around. Starting the clock the
-- instant the wheels stop turning put a flashing elimination warning on screen
-- for every one of those, which is noise -- and noise on a warning is how a
-- real one gets ignored.
--
-- So the total time from stopping to being counted out is this PLUS the
-- configured timer. Deliberately: the grace is for driving, the timer is for
-- being wrecked, and they are answering different questions.
--
-- Ten after a race night at five: five was enough to stop the warning flashing
-- on every pause, and still short enough to catch a driver lining a run up.
local DERBY_STOP_GRACE    = 10
local DERBY_POLE_HEIGHT   = 6     -- fallback wall height, until the server says
-- Fallback skirt, likewise. This used to BE the answer: a hardcoded drop with no
-- way to change it, so on uneven ground the wall floated above every dip and
-- there was nothing an admin could do about it. Declared HERE rather than beside
-- the wall builder that uses it, because D.derbyState reads it hundreds of lines
-- earlier and a local used before its declaration is a nil global, not an error.
local DERBY_WALL_SKIRT    = 1.5
local DERBY_POLE_RADIUS   = 0.2

-- One table rather than a dozen file-scope locals, for the same reason the
-- tunables at the top of the file are one table: Lua caps a function at 200
-- locals, the top level of this file is a function, and going over does not warn
-- -- the file fails to compile and the mod is simply not there. This block was
-- the largest cohesive group left.
D.derbyState = {
  phase     = 'idle',   -- idle | running | finished (mirrored from server)
  -- The derby is decided and running out its cool-down. The cars are stood down
  -- for it -- see derbyStandDown.
  over      = false,
  boundary  = {},       -- ordered polygon vertices { x, y, z }
  -- Which editor authored the polygon above, mirrored from the server. Gameplay
  -- reads `boundary` in both cases and nothing else -- these only decide what
  -- the ARENA IS DRAWN LIKE, and which controls the admin panel offers.
  boundaryMode = 'polygon',  -- polygon | rect
  shape     = nil,      -- { cx, cy, cz, halfW, halfL, rot } while mode is 'rect'
  wallHeight = DERBY_POLE_HEIGHT,
  wallDepth  = DERBY_WALL_SKIRT,
  -- True while an admin has the Derby Editor sub-tab open. The editor's arena
  -- and a driver's arena are different drawings of the same boundary, exactly
  -- the way an authoring checkpoint and a race one are (see drawGate).
  editorOpen = false,
  oobLimit  = 5,        -- seconds (mirrored from server config)
  demoLimit = 10,
  mode = 'lms',   -- server-owned; mirrored so the offline panel matches
  starts    = {},       -- derby starting grid { x, y, z, hx, hy } (mirrored)
  slot      = nil,      -- start slot the server assigned us for this derby
  visualize = true,     -- Hide/Show toggle for the boundary + grid visuals
  oobLeft   = nil,      -- active out-of-bounds countdown, nil = inside
  demoLeft  = nil,      -- active stopped countdown, nil = moving
  -- THE SERVER SAYS WE ARE NOT IN THIS DERBY: eliminated, or never a
  -- participant (joined after Start Derby). Authoritative, and only the server
  -- broadcast sets it.
  out       = false,
  -- WE HAVE REPORTED SOMETHING AND ARE WAITING FOR THE RULING. Stops the same
  -- timer firing twice into the round trip, and nothing more.
  --
  -- These were ONE FLAG, and lives are what broke that. `out` was set the
  -- moment a timer expired, on the reasoning that a timer expiring meant
  -- elimination -- true until a driver could be sent back with a life instead.
  -- Nothing cleared it for that case, so a driver who lost one life stopped
  -- policing for the rest of the derby: no stopped timer, no out-of-bounds
  -- timer, no further reports. And since a field that cannot report cannot be
  -- eliminated, the derby then ran until an admin pressed End Derby.
  pending   = false,
  runTime   = 0,        -- local seconds since this derby went running
  warnShown = false,    -- whether the UI currently shows a warning
}


-- STAND THE CAR DOWN AT THE END OF A DERBY.
--
-- The result is settled and the arena stays up for a few seconds so it can be
-- seen; a wreck still being driven into people for those seconds is not a
-- cool-down, it is extra time nobody was given.
--
-- Freezing ALONE is not enough, and that is the whole of this function. The grid
-- hold uses the same freeze and gets away with it because a car on the grid is
-- stationary with nothing pressed. A derby ends with somebody's foot flat to the
-- floor, and a freeze applied over that captures the throttle: the engine sits
-- screaming against a locked car and lets go the instant the freeze lifts. So
-- the inputs are neutralised FIRST -- throttle off, brakes on -- and the freeze
-- goes over the top of a car that is already trying to stop.
--
-- Controls are deliberately left ENABLED. There is nothing left to win, the car
-- cannot move, and taking someone's steering away as a prize for having been in
-- a derby is worse than pointless. What IS taken away is the reset: a reset would
-- reload the vehicle out from under the freeze and hand them a driveable car in
-- the middle of a settled result.

local function derbyStandDown(down)
  if down == D.derbyState.stoodDown then return end
  D.derbyState.stoodDown = down
  local veh = host.playerVehicle()
  if down then
    if veh then
      -- Order matters: let go of the throttle before anything locks.
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

-- Standard ray-casting point-in-polygon test on the XY plane (the arena is a
-- 2D perimeter; height is ignored so jumps/ramps don't false-positive).
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

-- Local pid, so we can tell whether the server already eliminated us. Read
-- through the host at the CALL, never captured: a value taken at load time is a
-- snapshot, and at load time the host does not exist yet.
local function derbyLocalServerId() return host.localServerId() end

D.derbyUpdate = function (dt)
  if D.derbyState.phase ~= 'running' or D.derbyState.out or D.derbyState.pending then
    D.derbyClearWarnings()
    return
  end
  D.derbyState.runTime = D.derbyState.runTime + dt
  local veh = host.playerVehicle()
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

  -- Stopped-vehicle ("demolished") check. Held off for the start grace
  -- period so a grid of cars parked for the start isn't counting down
  -- before anyone has had a chance to move.
  --
  -- TWO CLOCKS, NOT ONE. `stoppedFor` runs from the moment the car stops;
  -- `demoLeft` only starts once that has passed DERBY_STOP_GRACE. Moving at any
  -- point clears both, so the grace is granted again on the next stop rather
  -- than being spent once per derby.
  local vel = veh:getVelocity()
  local speed = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
  if speed > DERBY_STOP_SPEED or D.derbyState.runTime < DERBY_START_GRACE then
    D.derbyState.stoppedFor = 0
    if D.derbyState.demoLeft then D.derbyState.demoLeft = nil; changed = true end
  else
    D.derbyState.stoppedFor = (D.derbyState.stoppedFor or 0) + dt
    -- Still inside the grace: no countdown, and NOTHING PUSHED. The warning
    -- panel is driven by demoLeft, so leaving it nil is what keeps the screen
    -- quiet while a driver is simply turning around.
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

-- Arena walls. The perimeter is drawn as a closed run of vertical panels -- one
-- quad per edge, standing from the boundary up to the wall height -- rather than
-- the poles and rope it used to be. The same builder serves both arena kinds,
-- because by the time it runs a rectangle is just a four-vertex polygon.
--
-- Two things about the geometry are worth knowing before changing it:
--
--   * A rectangle's corners all sit at the CENTRE's z (see the server's
--     derbyShapeToBoundary), so on sloped ground the ring is a flat plane cut
--     through the hill. The walls therefore start BELOW the boundary z and run
--     up from there: dropping the base by a skirt means the panel intersects the
--     terrain on the uphill side instead of hovering over it, and the arena
--     still reads as enclosed. A hand-placed polygon takes its z from the car
--     that placed each marker, so it follows the ground already -- the skirt
--     costs it nothing.
--   * Every panel is emitted TWICE, with the winding reversed the second time.
--     Drivers stand inside this box looking out, which is the one view a
--     single-sided quad would be invisible from.
local function derbyBuildWalls(boundary, height, depth)
  local n = #boundary
  local walls = {}
  if n < 2 then return walls end
  for i = 1, n do
    local a = boundary[i]
    local b = boundary[i % n + 1]
    -- Two markers is a line, not a ring: draw the single panel once rather than
    -- the same panel twice back to back.
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

-- Boundary visualization. Mirrors the race editor's Hide/Show Gates rule:
-- unconditional while the derby runs (drivers must see the arena), the toggle
-- only applies outside of one.
D.derbyDrawBoundary = function ()
  if not debugDrawer then return end
  if D.derbyState.phase ~= 'running' and not D.derbyState.visualize then return end

  -- Who is looking. An admin with the Derby Editor open is judging the arena and
  -- needs its exact limits, its corners and its numbers; everyone else is
  -- driving in it and needs to know where the edge is and nothing more. A derby
  -- from form-up onward is always the driving view, even for that admin -- by
  -- then cars are standing on the grid and the panel is not what anyone is
  -- looking at.
  local authoring = D.derbyState.editorOpen and host.isAdmin()
    and D.derbyState.phase ~= 'running' and D.derbyState.phase ~= 'countdown'
    and D.derbyState.phase ~= 'forming'

  -- Derby starting grid slots, numbered from slot 1. Authoring furniture: they
  -- exist to lay the slots out and check spacing, so they belong to an admin
  -- with the editor open -- the same rule drawStartPositions applies to the race
  -- grid, which this used to be the exception to. Every driver on the server got
  -- a field of numbered outlines whether or not a derby was anywhere near
  -- starting, and they stayed up through form-up and the countdown.
  --
  -- The one case that is not authoring: a driver being PUT on a slot. While the
  -- field forms up, your own slot is drawn for you and nobody else's is, so you
  -- can see where you have been placed without the other nineteen outlines.
  -- Once the derby runs, nothing here is drawn at all -- every car has left its
  -- slot by then. The boundary below is NOT hidden: leaving it is what
  -- eliminates you, so a driver has to be able to see it.
  if D.derbyState.phase ~= 'running' then
    if authoring then
      for i, sp in ipairs(D.derbyState.starts) do
        host.drawStartPosition(sp, i, D.derbyState.slot == i)
      end
    elseif D.derbyState.slot and D.derbyState.starts[D.derbyState.slot] then
      host.drawStartPosition(D.derbyState.starts[D.derbyState.slot], D.derbyState.slot, true)
    end
  end
  local boundary = D.derbyState.boundary
  local n = #boundary
  if n == 0 then return end

  -- Same story as the race gates: an arena perimeter is fixed geometry redrawn
  -- every frame, and it was rebuilding all of it each time.
  --
  -- The cache lives on D.derbyState rather than in a new file-scope local, because
  -- this file is close enough to Lua's 200-local ceiling that a new one there is
  -- a cost of its own. It is keyed on the boundary table itself: D.onDerbyUpdate
  -- keeps the existing table when the markers have not moved, so identity is
  -- enough to say "nothing about this arena has changed". Wall height and the
  -- authoring flag are part of the key too -- both change the geometry without
  -- the boundary moving, and a cache that missed them would draw a resized
  -- arena at its old height, or keep the editor's floor through a live derby.
  local height = D.derbyState.wallHeight or DERBY_POLE_HEIGHT
  local depth  = D.derbyState.wallDepth or DERBY_WALL_SKIRT
  local cache = D.derbyState.draw
  -- Depth is part of the cache key for the same reason height is: it changes the
  -- geometry without any marker moving, and a cache that missed it would keep
  -- drawing the arena at its old skirt.
  if not cache or cache.src ~= boundary or cache.height ~= height
      or cache.depth ~= depth or cache.authoring ~= authoring then
    cache = { src = boundary, height = height, depth = depth, authoring = authoring }
    cache.walls = derbyBuildWalls(boundary, height, depth)
    -- Corner posts, the full height of the wall. Both views draw them -- they
    -- are what stops a translucent wall from disappearing against a bright sky
    -- -- but the driving view draws them thinner, so they mark the corners
    -- without becoming scenery.
    cache.posts = {}
    for i, m in ipairs(boundary) do
      local base = vec3(m.x, m.y, m.z - depth)
      cache.posts[i] = { a = base, b = vec3(m.x, m.y, m.z + height) }
    end
    -- A rail along the top of the wall, and one along the ground. The ground
    -- rail is the line a driver actually judges the edge by at speed.
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
      -- Editor-only furniture, built once with everything else: a numbered label
      -- over each corner, the arena's headline label, and -- for a rectangle --
      -- the centre crosshair and a readout of what the sliders currently say.
      local first = boundary[1]
      cache.labelAt = vec3(first.x, first.y, first.z + height + 0.8)
      local s = D.derbyState.shape
      if D.derbyState.boundaryMode == 'rect' and s then
        cache.label = string.format('DERBY ARENA: %.0f x %.0f m', s.halfW * 2, s.halfL * 2)
        -- A rectangle is convex and has exactly four corners, so its floor is
        -- one quad with no triangulation to get wrong.
        if n == 4 then
          cache.floor = {}
          for i, m in ipairs(boundary) do
            cache.floor[i] = vec3(m.x, m.y, m.z + 0.06)
          end
        end
        cache.centre = {
          at = vec3(s.cx, s.cy, s.cz),
          -- A cross through the centre, turned with the rectangle, so the
          -- rotation slider has something to visibly turn.
          armA = { a = vec3(s.cx - math.cos(s.rot) * 3, s.cy - math.sin(s.rot) * 3, s.cz + 0.1),
                   b = vec3(s.cx + math.cos(s.rot) * 3, s.cy + math.sin(s.rot) * 3, s.cz + 0.1) },
          armB = { a = vec3(s.cx + math.sin(s.rot) * 3, s.cy - math.cos(s.rot) * 3, s.cz + 0.1),
                   b = vec3(s.cx - math.sin(s.rot) * 3, s.cy + math.cos(s.rot) * 3, s.cz + 0.1) },
          label = string.format('CENTRE: %.0f deg', math.deg(s.rot)),
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

  -- The walls themselves. Twice each, winding reversed, so the panel is there
  -- from inside the arena as well as outside it.
  for _, w in ipairs(cache.walls) do
    debugDrawer:drawQuadSolid(w.bl, w.br, w.tr, w.tl, face)
    debugDrawer:drawQuadSolid(w.tl, w.tr, w.br, w.bl, face)
  end

  if authoring then
    -- The enclosed area, filled, so the extent is unmistakable. Editor-only: a
    -- translucent floor over the whole playing surface is the last thing a
    -- driver needs.
    --
    -- Rectangles only, and deliberately so. Filling an arbitrary polygon means
    -- triangulating it, and the cheap way (a fan from vertex 1) paints OUTSIDE
    -- the arena the moment the shape is concave -- which a hand-driven demo
    -- arena very often is. A floor that lies about the limits is worse than no
    -- floor, and the walls, posts and rails already state them exactly.
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
    if cache.centre then
      debugDrawer:drawCylinder(cache.centre.armA.a, cache.centre.armA.b, 0.12, edge)
      debugDrawer:drawCylinder(cache.centre.armB.a, cache.centre.armB.b, 0.12, edge)
      debugDrawer:drawTextAdvanced(cache.centre.labelAt, String(cache.centre.label),
        p.text, true, false, p.derbyLabelBg)
    end
  else
    -- Driving view: no labels, no corner numbers, no floor. Just enough edge to
    -- read the wall against the sky and the ground.
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
  local veh = host.playerVehicle()
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
-- Switch between driving the perimeter marker by marker and pulling a rectangle
-- out from a centre. Neither loses the other's work: see the server handler.
-- The vehicle position rides along as the centre to use when there is no
-- existing arena to fit a rectangle around.
function D.derbySetBoundaryMode(mode)
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  mode = (mode == 'rect') and 'rect' or 'polygon'
  local payload = { mode = mode }
  local veh = host.playerVehicle()
  if veh then
    local pos = veh:getPosition()
    payload.cx, payload.cy, payload.cz = pos.x, pos.y, pos.z
  elseif mode == 'rect' and #D.derbyState.boundary < 3 then
    guihooks.trigger('RaceManagerEditorMsg', {
      msg = 'Get in a vehicle first: the rectangle needs a centre' })
    return
  end
  TriggerServerEvent('RM_DerbySetBoundaryMode', jsonEncode(payload))
end

-- Re-centre the rectangle on the car. The derby's "Move Here", and the same
-- gesture every other placement in this mod uses.
function D.derbySetShapeCenter()
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local veh = host.playerVehicle()
  if not veh then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Get in a vehicle first' })
    return
  end
  local pos = veh:getPosition()
  TriggerServerEvent('RM_DerbySetShape',
    jsonEncode({ cx = pos.x, cy = pos.y, cz = pos.z }))
end

-- Size, turn and wall height, straight off the sliders. Every argument is
-- optional: the server keeps whatever this payload leaves out, so a slider only
-- ever sends the thing it moved. Width and length arrive as the FULL span an
-- admin reads off the panel; the server stores half-extents.
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

-- The parameter is `resetLimit`, not `maxResets`: the latter is also the name of
-- the RACE allowance this file holds, and a parameter quietly shadowing it is
-- the kind of thing that reads correctly and means something else.
-- `lives` is optional so an older UI, which sends three arguments, still sets
-- the two timers and the reset allowance instead of failing on arity.
-- `mode` is last for the same reason `lives` was: an older UI sends four
-- arguments, and the server leaves the mode alone when it does not recognise
-- what it is given -- including nil.
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
-- Same workflow as the race grid: drive to each slot, press the button, slot 1
-- first. The server owns the list and hands each participant a slot number at
-- Start Derby; this client puts its own car there.
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
-- The derby's answer to moveStartPosition / removeStartPosition / preview,
-- with one difference that decides the whole shape of these: the race grid is
-- this client's own list, while the SERVER owns the arena. So a move sends the
-- index plus the placement the car is standing on and waits for the broadcast
-- to come back; only the preview is answered locally, because standing your own
-- car somewhere is nobody else's business.
function D.derbyMoveMarker(index)
  index = math.floor(tonumber(index) or 0)
  if index < 1 then return end
  if not host.inMultiplayer() then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Demo Derby needs a BeamMP server' })
    return
  end
  local veh = host.playerVehicle()
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

-- Preview, the race editor's "Go": stand the car on a placed entry so the
-- creator can see where it actually is. Purely local and never freezes -- this
-- is editor convenience, exactly like previewStartPosition.
function D.derbyPreviewStartPosition(index)
  index = math.floor(tonumber(index) or 0)
  local sp = D.derbyState.starts[index]
  if not sp then return end
  if not host.placeOnStartPosition(sp) then
    guihooks.trigger('RaceManagerEditorMsg', { msg = 'Could not move the vehicle' })
  end
end

-- A boundary marker is a position with no facing of its own, so the car keeps
-- the heading it already has rather than being spun to an arbitrary one.
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

-- The Derby Editor sub-tab opening and closing. Client-local and purely a
-- render gate, exactly like setEditorOpen for the race checkpoints: it decides
-- whether this client draws the arena's authoring view or its driving view, and
-- touches no derby state the server owns.
function D.setDerbyEditorOpen(open)
  D.derbyState.editorOpen = open == true
end

-- Hide/Show the derby boundary + start grid visuals (client-local, like the
-- race editor's gate toggle). Pushed to the UI so the button label follows.
function D.derbyToggleVisualize()
  D.derbyState.visualize = not D.derbyState.visualize
  guihooks.trigger('RaceManagerDerbyVisual', { visualize = D.derbyState.visualize })
end


-- Form up: stand every participant on their slot and hold them there, ready
-- for the countdown. The derby equivalent of Generate Grid.
function D.derbyFormUp()
  if host.inMultiplayer() then TriggerServerEvent('RM_DerbyFormUp', '') end
end

function D.derbyStart()
  if host.inMultiplayer() then TriggerServerEvent('RM_DerbyStart', '') end
end

function D.derbyEnd()
  if host.inMultiplayer() then TriggerServerEvent('RM_DerbyEnd', '') end
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

-- --- Derby arena layouts (server-side, persistent, per-map) ----------------
-- The same save/load workflow the race layouts use, kept inside the derby
-- module: an arena is its boundary polygon plus the two timers, stored on the
-- server under a name and broadcast to every client when loaded.
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
  -- The derby starting grid travels with the arena, exactly the way the race
  -- grid travels with a track layout.
  local starts = nil
  if #D.derbyState.starts > 0 then
    starts = {}
    for i, sp in ipairs(D.derbyState.starts) do
      starts[i] = { x = sp.x, y = sp.y, z = sp.z, hx = sp.hx, hy = sp.hy }
    end
  end
  -- A rectangle is saved as its shape AND the polygon it produced, so the arena
  -- comes back editable by slider rather than as four loose markers -- and stays
  -- loadable by anything that only knows about the polygon.
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
  -- Decided and running out the cool-down. Stood down while that is true, and
  -- released the moment the derby is no longer running -- so a car is never left
  -- frozen by a derby that has ended, whatever order the broadcasts arrive in.
  D.derbyState.over = data.derbyOver == true
  derbyStandDown(D.derbyState.over and newPhase == 'running')
  if newPhase == 'running' and D.derbyState.phase ~= 'running' then
    -- Fresh derby: re-arm local detection from a clean slate. The derby reset
    -- allowance is per-derby, so it starts over too.
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
  -- A derby that ends or is reset while cars are still held on the form-up grid
  -- has to let them go. Only ever releases a hold this module imposed.
  if newPhase == 'idle' or newPhase == 'finished' then
    host.releaseGridHold('derby')
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
  -- Keep the table we already have when the markers have not actually moved.
  -- Every broadcast used to install a brand new one -- once a second while a
  -- derby runs, and on every marker drop while an admin builds an arena -- which
  -- is garbage on its own, and would also throw away the draw cache below on
  -- every push for an arena that had not changed at all.
  --
  -- Swapping the table IS the invalidation, and deliberately the only one: the
  -- cache is keyed on this table's identity, so a new arena can never be drawn
  -- with an old one's geometry, and there is no second rule here to forget to
  -- apply somewhere else.
  local same = #boundary == #D.derbyState.boundary
  if same then
    for i, m in ipairs(boundary) do
      local o = D.derbyState.boundary[i]
      if o.x ~= m.x or o.y ~= m.y or o.z ~= m.z then same = false; break end
    end
  end
  if not same then D.derbyState.boundary = boundary end

  -- Which editor authored that polygon, and how tall to draw its walls. Both are
  -- server-owned so every client draws the same arena; neither affects the
  -- out-of-bounds test, which reads `boundary` and nothing else.
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

  -- If the server already knows we're out (e.g. reconnect race), stop
  -- policing. Same if we're not in the participant list at all: we joined
  -- after Start Derby and are a spectator - a parked spectator must not get
  -- OUT OF BOUNDS / VEHICLE STOPPED overlays for a derby they aren't in.
  local myId = derbyLocalServerId()
  if myId and type(data.players) == 'table' then
    local mine = nil
    for _, p in ipairs(data.players) do
      if tonumber(p.id) == myId then mine = p; break end
    end
    if mine then
      if mine.status ~= 'alive' then
        -- The ruling came back as an elimination.
        D.derbyState.out     = true
        D.derbyState.pending = false
      elseif D.derbyState.pending or D.derbyState.out then
        -- ...and this is the other answer: still alive, so whatever we reported
        -- was met with a life rather than an elimination. Policing resumes.
        --
        -- THE GRACE IS RE-ARMED HERE TOO, not only in onDerbyLifeLost. The two
        -- messages are sent one after the other and nothing guarantees which
        -- lands first; if this one wins the race, the car has not been moved
        -- yet and is still sitting stopped exactly where the timer expired.
        -- Resuming without re-arming would spend the next life within a frame.
        D.derbyState.out     = false
        D.derbyState.pending = false
        D.derbyState.runTime = 0
        D.derbyClearWarnings()
      end
    elseif D.derbyState.phase == 'running' then
      D.derbyState.out = true
    end
  end

  guihooks.trigger('RaceManagerDerby', data)
end

-- Start Derby handed this client a start slot: stand the car on it, facing
-- the placed heading. No freeze/hold - the derby's start grace period covers
-- the line-up, and the teleport is flagged so it never counts as a reset.
-- A LIFE SPENT, NOT A DERBY LOST. The stopped timer expired, the server took a
-- life off this driver and sent them back to the slot they started from.
--
-- Everything physical about it is the form-up path: the same placement queue,
-- which ghosts the car on the way in and hands its collisions back only once it
-- has settled AND the space around it is provably clear. That is what stops a
-- driver being dropped into the middle of a scrum and welded to whatever was
-- standing on their slot.
--
-- NOT held. A form-up holds cars for the countdown; this driver is rejoining a
-- derby that is already running, and holding them would be a second penalty on
-- top of the life they just lost.
D.onDerbyLifeLost = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local lives = tonumber(data.lives) or 0
  local slot  = tonumber(data.slot)

  -- The countdown that just expired has to go before the car moves, or the
  -- driver lands on their slot with the overlay still counting and loses the
  -- next life to the timer they already paid for.
  D.derbyState.demoLeft = nil
  D.derbyState.oobLeft  = nil
  -- Back in, and policing again. This is the flag that used to be left set: the
  -- timer that expired reported an elimination and got a life, and the client
  -- went on believing it was out for the rest of the derby.
  D.derbyState.pending  = false
  D.derbyState.out      = false
  D.derbyClearWarnings()
  D.derbyState.stoppedFor = 0
  D.derbyState.runTime  = 0     -- re-arms the start grace, so a car put down
                                -- stationary is not immediately on the clock

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
  local slot = tonumber(data.slot)
  D.derbyState.slot = slot and math.floor(slot) or nil

  -- Through the same placement queue the race grid uses. A derby form-up is a
  -- whole field being teleported onto adjacent slots at once, which is the same
  -- physical problem: ghosted, staggered by slot number, collisions back once
  -- the field has settled. The derby assigns slots 1..N in order, so the slot
  -- number IS this car's place in the sequence.
  --
  -- Form-up holds every participant until the countdown lets them go, whether
  -- or not a slot was placed for them: a car with nowhere to line up still has
  -- to wait for GO rather than getting a free run at everyone else. Tagged
  -- 'derby' so a racing host.phase() change can never release it.
  if D.derbyState.slot then
    host.queueFieldPlacement({
      slot  = D.derbyState.slot,
      slots = D.derbyState.starts,
      hold  = data.hold == true,
      holdSource = 'derby',
      order = D.derbyState.slot,
      count = math.max(#D.derbyState.starts, D.derbyState.slot),
    })
  elseif data.hold == true then
    -- No slot placed for this driver: hold them where they stand.
    host.requestHold('derby')
  end
end

-- Derby countdown, on its own channel so the racing countdown and this one can
-- never release each other's cars. GO (0) or an abort (-1) ends the hold; the
-- overlay itself is the shared UI one, since a countdown looks the same either
-- way and there is nothing mode-specific about drawing 3, 2, 1.
D.onDerbyCountdown = function (rawData)
  local ok, data = pcall(jsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local count = tonumber(data.count)
  if count and count <= 0 then host.releaseGridHold('derby') end
  guihooks.trigger('RaceManagerCountdown', data)
end

-- Map-filtered arena list from the server.
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
