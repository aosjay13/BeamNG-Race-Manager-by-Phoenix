-- Race Manager: THE RENDERER, as its own module.
--
-- Everything this mod draws in the 3D world: the palette, gate geometry and its
-- cache, checkpoint and joker gates, the starting grid, pit stalls, direction
-- markers, and the per-frame pass that decides which of them a driver sees.
--
-- Split out of raceManager.lua for the reason the derby was, and after the same
-- groundwork. That file sits at Lua's 200-local ceiling, where the next `local`
-- anybody adds anywhere stops the whole mod compiling; a module gets its own
-- budget of 200 and this one takes fifteen names out of the main chunk.
--
-- WHY THIS WAS NOT POSSIBLE UNTIL NOW, and it is the useful part of the story.
-- Measured against the old code this needed twenty-five names from the host,
-- NINETEEN of them as getters -- because route, phase, armedWp and the rest were
-- separate top-level locals that get REBOUND, so a reference captured at init
-- would go stale. A module reaching back through nineteen accessors is not a
-- module; it is the same coupling with indirection and a per-frame call cost.
--
-- Grouping that state into `track` and `session` first turned every one of them
-- into a field on a table that is never itself rebound. The contract below is
-- eleven plain references and NO getters: `track.route` changes, `track` does
-- not, so this file sees every later change for free.
--
-- THE CONTRACT. Everything arrives once through init(host), and all of it is
-- either a stable table or a plain function:
--
--   track, session, edit   the models, by reference
--   marker, nudge, branch, pit   subsystem tables, by reference
--   TUNE                   tuning constants
--   gateDims, sampledVehicle, sessionRunning   plain functions
--
-- Nothing here writes host state. This file reads and draws, which is what
-- makes it the cheapest thing in the file to move and the right one to move
-- first.

local R = {}

-- Assigned once by init. Declared here so every function below closes over
-- them: a value captured at file load would be nil, because the host has not
-- called init yet when this chunk runs.
local track, session, edit, TUNE, marker, nudge, branch, pit
local gateDims, sampledVehicle, sessionRunning

function R.init(h)
  track, session, edit = h.track, h.session, h.edit
  TUNE   = h.TUNE
  marker, nudge, branch, pit = h.marker, h.nudge, h.branch, h.pit
  gateDims       = h.gateDims
  sampledVehicle = h.sampledVehicle
  sessionRunning = h.sessionRunning
end

local PALETTE = nil

local function palette()
  if PALETTE then return PALETTE end
  -- Every gate color is at FULL VALUE: the brightest form of its own hue,
  -- rather than that hue mixed with black. The hues themselves are unchanged --
  -- green next, orange route, white line, violet joker, amber pit -- because
  -- what a color means here is learned, and a driver who has learned that
  -- green is the gate they are heading for should not have to learn it twice.
  --
  -- What moved is value and alpha. These are drawn over whatever the map
  -- happens to be, in whatever light the level has: a gate at 70% alpha in a
  -- hue two thirds of the way to black is legible against tarmac at noon and
  -- close to invisible against a bright desert, a snow map, or a low sun. There
  -- is no cost to being certain here -- the shapes are thin cylinder edges, not
  -- fills, so a fully opaque gate still shows the track through the middle of
  -- itself, which is the part that matters.
  PALETTE = {
    finish    = ColorF(1, 1, 1, 1),            -- start/finish: white
    armed     = ColorF(0.25, 1, 0.45, 1),      -- next target: green
    route     = ColorF(1, 0.45, 0.05, 0.95),   -- rest of route: orange
    -- The gate AFTER the armed one, in a driver's view. Same orange, dimmed, so
    -- the corner after this one reads without competing with the one they are
    -- actually driving at.
    routeNext = ColorF(1, 0.45, 0.05, 0.45),
    -- The gate nudge mode has hold of. Magenta because it is not a state the
    -- track itself can be in, so it collides with nothing already learned.
    nudged    = ColorF(1, 0.2, 0.9, 1),
    joker     = ColorF(0.72, 0.35, 1, 1),      -- joker route: violet
    -- Still visibly duller than the rest, because "already taken" is what it
    -- has to say at a glance -- but lifted with everything else, so it reads as
    -- a gate that is spent rather than one that failed to draw.
    jokerUsed = ColorF(0.62, 0.62, 0.7, 0.6),  -- joker already taken: dimmed
    pit       = ColorF(1, 0.78, 0.15, 1),      -- pit stalls: amber
    -- Branch gates: cyan. Far enough from the joker's violet to be told apart at
    -- a glance, and from the route's orange, which is the pair that actually
    -- matters -- a branch gate substitutes for a main one and must never look
    -- like an extra checkpoint on the same lap.
    branch      = ColorF(0.2, 0.85, 0.95, 1),
    text      = ColorF(1, 1, 1, 1),
    -- The editor gate's filled surface. Deliberately faint: it has to show the
    -- gate's extent without hiding the road it is judged against.
    fill      = ColorF(0.35, 0.65, 1, 0.16),
    textBg    = ColorI(0, 0, 0, 160),
    -- The joker label's own backing, violet rather than the neutral black every
    -- other label uses. A driver reads this one at speed to decide whether the
    -- route beside them is one they still owe, and it has to be tellable from a
    -- checkpoint label at a glance.
    jokerLabelBg = ColorI(70, 20, 110, 190),
    -- A driver's fills. Fainter than the editor's: an admin is judging a gate
    -- against the track and wants to see its extent, a driver is driving through
    -- it at speed and wants to see the road.
    jokerFill    = ColorF(0.72, 0.35, 1, 0.13),
    jokerUsedFill = ColorF(0.62, 0.62, 0.7, 0.10),
    -- The FOOTPRINT is the rule, so it is the part that has to read. At 0.11
    -- over pale ground it was invisible and a stall showed as an outline the
    -- size of the track with nothing inside it.
    pitFill      = ColorF(1, 0.72, 0.1, 0.24),
    pitWall      = ColorF(1, 0.72, 0.1, 0.14),
    -- The chevron on the floor: which way the stall faces, and therefore which
    -- way the car is stood when it stops.
    pitArrow     = ColorF(1, 0.88, 0.35, 0.85),
    -- Direction markers. Cyan, because every other color on a track already
    -- means something a driver has learned -- green is the gate they are
    -- driving at, orange the rest of the route, violet the joker, amber the
    -- pits -- and a sign that is not any of those must not borrow one of them.
    markerLine   = ColorF(0.2, 0.95, 1, 0.95),
    markerFill   = ColorF(0.2, 0.85, 1, 0.13),
    markerSel    = ColorF(1, 1, 1, 1),
    -- PACKED INTEGERS, NOT ColorF, and that is not a style choice.
    --
    -- drawTriSolid takes `packedCol` -- one number built by the engine's global
    -- color(r,g,b,a) at 0..255 -- where every other call this file makes takes
    -- a ColorF. Handing it a ColorF is a hard error inside the C++ drawer, once
    -- per triangle per frame, which is a wall of exceptions and no marker.
    --
    -- Guarded, because `color` is a global from BeamNG's utils and a build
    -- without it should cost the marker faces rather than the whole draw pass.
    -- nil here means the fill is skipped and the board, posts and outline still
    -- draw: markers degrade to their previous look instead of vanishing.
    markerFace   = type(color) == 'function' and color(51, 242, 255, 240) or nil,
    markerEdgeP  = type(color) == 'function' and color(5, 15, 23, 235) or nil,
    -- The state glyph drawn across a joker gate: a cross while it is shut, a
    -- tick once it is spent. Both semi-transparent, because they are drawn over
    -- the piece of track the driver is about to aim at.
    glyphShut    = ColorF(1, 0.25, 0.25, 0.5),
    glyphDone    = ColorF(0.3, 1, 0.45, 0.5),
    -- Fainter than the other two: it sits on a gate the driver is aiming
    -- THROUGH, where the cross and the tick sit on one they must not take.
    glyphOpen    = ColorF(0.85, 0.7, 1, 0.28),
    -- Demo derby arena. Its own entries rather than its own table: the derby
    -- module keeps its state and its logic separate, but a color is a color,
    -- and building these per frame is what this exists to stop.
    derbyLive    = ColorF(0.9, 0.15, 0.15, 0.9),  -- live arena edges: red
    derbySetup   = ColorF(0.9, 0.6, 0.1, 0.8),    -- setup/finished edges: amber
    derbyLabelBg = ColorI(120, 0, 0, 180),
    -- The arena WALL panels, and the pair of alphas that separate an editor
    -- arena from a live one. The editor's is a surface you can see is there; the
    -- live one is a haze you read the edge of. Anything much heavier than this
    -- while driving turns a demo arena into a room with the lights off -- the
    -- wall is a boundary marker, not scenery, and there is another car on the
    -- far side of it that still has to be visible through it.
    derbyWallEdit = ColorF(0.95, 0.55, 0.1, 0.30),
    derbyWallLive = ColorF(0.9, 0.2, 0.15, 0.12),
    -- Editor floor: the same near-transparent blue the authoring gate fill uses,
    -- for the same reason -- show the extent without hiding the ground.
    derbyFloor   = ColorF(0.35, 0.65, 1, 0.10),
  }
  return PALETTE
end

-- Per-gate geometry cache.
--
-- A gate's four corners are fixed by its placement and its dimensions, and a
-- placed gate never moves -- yet all four were recomputed, and four vec3
-- allocated, for every gate on every frame. On a twenty-gate circuit that is
-- ~100 tables a frame thrown straight at the collector, which was the single
-- largest source of GC pressure in the mod.
--
-- Keyed on the waypoint table with WEAK keys, so a gate that is deleted or
-- replaced takes its entry with it. Deliberately not stored on the waypoint
-- itself: editorSave serialises those tables verbatim, and a cache of vec3s
-- would end up in the saved route file.
local gateCache = setmetatable({}, { __mode = 'k' })

-- Rebuilt only when something the geometry depends on has actually moved. The
-- dimensions are re-derived every frame because they are two clamps and a table
-- read, and that is far cheaper than the allocation it guards against -- a
-- global width change has to be picked up without anything telling us about it.
local function gateGeometry(wp)
  local w, h, d = gateDims(wp)
  local g = gateCache[wp]
  if g and g.w == w and g.h == h and g.d == d
      and g.x == wp.x and g.y == wp.y and g.z == wp.z
      and g.hx == wp.hx and g.hy == wp.hy then
    return g
  end

  local hw = w * 0.5
  local rx, ry = wp.hy, -wp.hx          -- lateral (width) axis
  -- corner(sr, up): center + lateral*sr*hw, then h ABOVE or d BELOW. The
  -- vertical is no longer symmetric, so the two ends are named rather than
  -- signed: `up` true is the top bar, false the bottom.
  local function corner(sr, up)
    return vec3(wp.x + rx * sr * hw, wp.y + ry * sr * hw,
                wp.z + (up and h or -d))
  end
  g = {
    w = w, h = h, d = d,
    x = wp.x, y = wp.y, z = wp.z, hx = wp.hx, hy = wp.hy,
    bl = corner(-1, false), br = corner(1, false),
    tl = corner(-1, true),  tr = corner(1, true),
  }
  g.mid = (g.tl + g.tr) * 0.5 + vec3(0, 0, 0.8)
  -- The middle of the gate's own face. `mid` floats above the top edge, which is
  -- right for an editor label sitting clear of the rectangle and wrong for a
  -- driver's, where the words want to be ON the gate they describe.
  g.center = (g.bl + g.tr) * 0.5
  -- The authoring direction arrow, cached with the corners for the same reason
  -- they are: it is fixed by the gate's placement, and rebuilding four vec3 per
  -- gate per frame is precisely the garbage this cache exists to stop.
  local ax, ay = wp.hx or 0, wp.hy or 1
  g.arrowBase = vec3(wp.x, wp.y, wp.z + 0.35)
  g.arrowTip  = vec3(wp.x + ax * 3.5, wp.y + ay * 3.5, wp.z + 0.35)
  local hx, hy = ay * 0.9, -ax * 0.9
  g.arrowL = vec3(g.arrowTip.x - ax * 1.1 + hx, g.arrowTip.y - ay * 1.1 + hy, g.arrowTip.z)
  g.arrowR = vec3(g.arrowTip.x - ax * 1.1 - hx, g.arrowTip.y - ay * 1.1 - hy, g.arrowTip.z)
  gateCache[wp] = g
  return g
end

-- A gate, drawn for whoever is looking at it.
--
-- `authoring` is the editor's view of a checkpoint and a driver's view of one
-- are different jobs, not different systems. An admin laying out a circuit needs
-- to see the trigger itself -- how wide it is, how high it reaches, which number
-- it is, which way through it counts -- across the whole track at once. A driver
-- needs to know where the next gate is and nothing else; labels and a filled box
-- across the racing line are clutter at speed, which is what the gate poles
-- replace during a session.
--
-- Both read the same checkpoint. Only the drawing differs.
local function drawGate(wp, color, label, authoring)
  local g = gateGeometry(wp)

  if authoring then
    -- The surface the crossing test actually uses, filled so its extent is
    -- unmistakable, and translucent so the road underneath stays visible --
    -- an admin is judging the gate against the track, not instead of it.
    local p = palette()
    debugDrawer:drawQuadSolid(g.bl, g.br, g.tr, g.tl, p.fill)
  end

  -- Verticals a touch thicker than the horizontals so the gate still reads as
  -- a gate at distance.
  debugDrawer:drawCylinder(g.bl, g.tl, TUNE.EDGE_RADIUS, color)
  debugDrawer:drawCylinder(g.br, g.tr, TUNE.EDGE_RADIUS, color)
  debugDrawer:drawCylinder(g.bl, g.br, TUNE.EDGE_RADIUS * 0.6, color)
  debugDrawer:drawCylinder(g.tl, g.tr, TUNE.EDGE_RADIUS * 0.6, color)

  local p = palette()
  debugDrawer:drawTextAdvanced(g.mid, String(label), p.text, true, false, p.textBg)

  if authoring then
    -- Which way through the gate counts. A rectangle alone is symmetrical and
    -- says nothing about direction, and a gate placed facing backwards is the
    -- classic way to build a circuit that cannot be completed. All four points
    -- come out of the cache above.
    debugDrawer:drawCylinder(g.arrowBase, g.arrowTip, 0.10, color)
    debugDrawer:drawCylinder(g.arrowL, g.arrowTip, 0.10, color)
    debugDrawer:drawCylinder(g.arrowR, g.arrowTip, 0.10, color)
  end
end

-- Starting grid markers: a flat slot outline on the ground with a short arrow
-- pointing the way the car will face, numbered from pole. Drawn while the
-- editor is visible and during the grid/countdown phases so drivers can see
-- where they are being placed.

local function drawStartPosition(sp, index, mine)
  local fx, fy = sp.hx, sp.hy
  local rx, ry = sp.hy, -sp.hx
  local hl, hw = TUNE.START_SLOT_LEN * 0.5, TUNE.START_SLOT_WIDE * 0.5
  local function corner(sf, sr)
    return vec3(sp.x + fx * sf * hl + rx * sr * hw,
                sp.y + fy * sf * hl + ry * sr * hw,
                sp.z + 0.05)
  end
  local color = mine and ColorF(0.2, 0.85, 0.35, 0.95)
    or (index == 1 and ColorF(1, 0.85, 0.2, 0.85) or ColorF(0.35, 0.65, 1, 0.75))
  local c = { corner(-1, -1), corner(-1, 1), corner(1, 1), corner(1, -1) }
  for i = 1, 4 do
    debugDrawer:drawCylinder(c[i], c[i % 4 + 1], 0.08, color)
  end
  -- WHICH WAY THE CAR WILL FACE, and it needs a head to say so.
  --
  -- This was a bare cylinder down the middle of the slot, which draws the AXIS
  -- and not the direction: a line from tail to head looks identical to one from
  -- head to tail, so an admin laying out a grid could not tell a slot facing
  -- down the track from one facing back up it until they drove onto it. Two
  -- barbs off the head fix it, the same shape paint.glyph draws for the joker's
  -- "take it" arrow.
  local tail = vec3(sp.x - fx * hl * 0.6, sp.y - fy * hl * 0.6, sp.z + 0.06)
  local head = vec3(sp.x + fx * hl * 0.9, sp.y + fy * hl * 0.9, sp.z + 0.06)
  debugDrawer:drawCylinder(tail, head, 0.06, color)
  -- Barbs swept back from the head, across the slot rather than along it, so the
  -- arrow reads from above (which is where an admin building a grid is looking)
  -- and from inside a car on the slot.
  local barb = hl * 0.42
  for _, sr in ipairs({ -1, 1 }) do
    debugDrawer:drawCylinder(head,
      vec3(head.x - fx * barb + rx * sr * barb * 0.8,
           head.y - fy * barb + ry * sr * barb * 0.8,
           head.z), 0.06, color)
  end

  debugDrawer:drawTextAdvanced(vec3(sp.x, sp.y, sp.z + 1.4),
    String('P' .. index .. (mine and ' (YOU)' or '')),
    ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 160))
end

local function drawStartPositions()
  if #track.startPositions == 0 or not debugDrawer then return end
  -- Editor-only furniture. These markers exist to lay out and check a grid, so
  -- they are drawn only while the editor panel is open -- they used to render
  -- for every racer, including drivers who can't edit anything. This is purely
  -- a render gate: `startPositions` itself is untouched and still drives grid
  -- placement (applyGridSlot), the slot count reported to the server, and the
  -- saved layout, for every client whether the editor is open or not.
  if not edit.open then return end
  -- Inside the editor, the same Hide/Show Gates toggle the checkpoints use.
  if not edit.visualize then return end
  for i, sp in ipairs(track.startPositions) do
    drawStartPosition(sp, i, session.gridSlot == i)
  end
end

-- Gate visibility (Module 3). The checkpoint boxes are drawn by every client,
-- admin or not: during an active session (countdown / qualifying / race) the
-- drawing is unconditional, because a driver who cannot see the gates cannot
-- race. The Hide/Show Gates toggle only applies outside a session, where it
-- exists to keep the editor view clean.
-- Gate labels, built once per route rather than per gate per frame.
--
-- Every label was a fresh string every frame, and the joker ones were three
-- concatenations each. The text does not depend on anything that changes between
-- frames -- only on the gate's index and the length of its route -- except for
-- the two joker suffixes, which have exactly three states, so all three are
-- precomputed and selected by lookup.
local labelCache = { routeLen = -1, jokerLen = -1, route = {}, joker = {} }

local function routeLabel(i, n)
  if labelCache.routeLen ~= n or labelCache.p2p ~= track.pointToPoint then
    labelCache.routeLen = n
    labelCache.p2p = track.pointToPoint
    labelCache.route = {}
  end
  local l = labelCache.route[i]
  if not l then
    if track.pointToPoint then
      -- A sprint stage has a start and a finish, not a line crossed twice.
      l = (i == n) and (i .. ' FINISH') or (i == 1 and '1 START' or ('CP ' .. i))
    else
      l = (i == n) and (i .. ' START/FINISH') or ('CP ' .. i)
    end
    labelCache.route[i] = l
  end
  return l
end

-- `state`: 'open' | 'used' | 'closed' (lap 1).
local function jokerLabel(i, n, state)
  if labelCache.jokerLen ~= n then
    labelCache.jokerLen = n
    labelCache.joker = {}
  end
  local set = labelCache.joker[i]
  if not set then
    local base = (i == n) and 'JOKER EXIT' or ('JOKER ' .. i .. '/' .. n)
    set = {
      open   = base,
      used   = base .. ' (used)',
      closed = base .. ' (lap 1: closed)',
    }
    labelCache.joker[i] = set
  end
  return set[state]
end

-- The stock BeamNG race markers (scenario/race_marker) are gone.
--
-- They were the driver's view of a gate until drawPoleGate took that over, and
-- they had been dead code since: the only sync call passed editorView = true,
-- so the module resolved nothing, built nothing and ticked an empty table every
-- frame. They could not be made bright or solid enough to see, and could not be
-- widened either, because their spacing IS the gate's width and wider poles
-- would mark a target that does not score. drawPoleGate draws the same two-pole
-- shape out of the editor's own cylinders instead.

-- THE DRIVER'S VIEW OF THE GATE THEY ARE AIMING AT.
--
-- Reported live as "racers cannot see the default BeamNG checkpoints". The stock
-- poles cannot just be widened: their spacing IS the gate's width, so poles
-- further apart than the trigger would show a target that does not score.
--
-- Only the gate being aimed at plus the next one dimmed, never the whole
-- circuit. `derbyLive` suppresses it entirely: a checkpoint hanging over a
-- demolition derby is authoring debris.
-- TWO POLES, IN THE EDITOR'S OWN STYLE.
--
-- The stock markers are the right shape but could not be made bright enough, so
-- the shape is redrawn out of the editor's own cylinders: full opacity, this
-- mod's colors, the gate's own height, label floating between them.
--
-- TWO VERTICALS AND NOTHING ELSE. No top bar, because a hoop reads as something
-- to aim through at one height and what is marked is the LINE between the poles
-- at any height. No fill or bottom edge either: a bar at road height is a thing
-- to drive into.
-- Drawing helpers that are not a gate. ONE local, because this file sits at
-- Lua's 200-active-locals ceiling and three bare names did not fit: the failure
-- is not a warning, the file stops compiling and the whole mod is gone.
local paint = {}

-- A CROSS or a TICK across a gate's face, for a joker whose state changes what
-- the driver must do.
--
-- Drawn rather than written because the two states are read at speed from a
-- distance, and "JOKER 1/2: closed" is a sentence at the moment a driver has
-- least attention to give a sentence. Sized off the gate but capped, so a
-- twenty-meter gate gets a symbol rather than scaffolding across the road.
function paint.glyph(g, kind)
  local p = palette()
  local half = math.min(g.w, g.h) * 0.22
  if half > 2.2 then half = 2.2 end
  if half < 0.6 then half = 0.6 end
  local c  = g.center
  -- The gate's own axes, so the glyph lies IN the gate's plane at any angle.
  local rx, ry = g.hy, -g.hx
  local function at(sr, su)
    return vec3(c.x + rx * sr * half, c.y + ry * sr * half, c.z + su * half)
  end
  local r = TUNE.POLE_RADIUS * 0.8
  if kind == 'open' then
    -- AN ARROW UP: take it. Faded hard on purpose, because unlike the cross and
    -- the tick this one is drawn on a gate the driver is about to aim through,
    -- and the whole point of the joker poles is that you can see the road
    -- between them.
    debugDrawer:drawCylinder(at(0, -1), at(0, 1), r * 0.8, p.glyphOpen)
    debugDrawer:drawCylinder(at(0, 1), at(-0.55, 0.3), r * 0.8, p.glyphOpen)
    debugDrawer:drawCylinder(at(0, 1), at(0.55, 0.3), r * 0.8, p.glyphOpen)
  elseif kind == 'shut' then
    debugDrawer:drawCylinder(at(-1, -1), at(1, 1), r, p.glyphShut)
    debugDrawer:drawCylinder(at(-1, 1), at(1, -1), r, p.glyphShut)
  elseif kind == 'done' then
    -- A tick: short stroke down into the corner, long stroke up and out.
    debugDrawer:drawCylinder(at(-0.9, 0.1), at(-0.25, -0.85), r, p.glyphDone)
    debugDrawer:drawCylinder(at(-0.25, -0.85), at(1, 1), r, p.glyphDone)
  end
end

-- A DIRECTION MARKER: a translucent panel with its symbol repeated across it.
--
-- REPEATED, because the panel is as wide as the admin drew it and a stage
-- marker gets drawn wide -- one arrow floating in the middle of a forty meter
-- board is a dot, and a single arrow STRETCHED to forty meters is a line with
-- a bend in it. A fixed-size symbol tiled across the span keeps the same shape
-- at every width, which is what a real sign does.
--
-- Built from segments rather than text: debugDrawer text does not shrink with
-- distance the way geometry does, so a glyph sized to read in the editor is a
-- speck at the two hundred meters where a marker actually has to work.
-- MARKER GEOMETRY, BUILT ONCE AND CACHED.
--
-- Every mark is a filled polygon rather than a line, which is the whole
-- difference between a wireframe and a painted road marking -- but it costs
-- four vertices per stroke instead of two, and a board can carry sixty marks.
-- Rebuilding that per frame would be exactly the garbage the gate cache was
-- written to stop, so it is built when the marker CHANGES and walked when it
-- does not.
--
-- Keyed on the marker table itself and invalidated by comparing the fields that
-- can move it, the same way gateGeometry does.
-- Module-local, NOT hung off the shared marker table.
--
-- It lived on that table when this code sat in the extension, where a table was
-- the only namespace going. Here it would be a trap: this file's locals stay nil
-- until init runs, so a write onto `marker` at LOAD time indexes a nil and the
-- module dies on require. Which is the honest signal -- geometry and its cache
-- are things the RENDERER knows, nothing outside this file ever called either,
-- and the contract above promises this module only reads host state.
local markerCache = setmetatable({}, { __mode = 'k' })

local function markerGeometry(wp)
  local w, h, d = gateDims(wp)
  local kind = wp.kind or 'right'
  local g = markerCache[wp]
  if g and g.w == w and g.h == h and g.d == d and g.kind == kind
      and g.x == wp.x and g.y == wp.y and g.z == wp.z
      and g.hx == wp.hx and g.hy == wp.hy then
    return g
  end

  local hw = w * 0.5
  local fx, fy = wp.hx or 0, wp.hy or 1
  local rx, ry = fy, -fx                -- lateral axis, to the driver's right
  local top, bot = wp.z + h, wp.z - d
  local span = h + d
  local function at(u, v)
    return vec3(wp.x + rx * u, wp.y + ry * u, v)
  end

  g = { w = w, h = h, d = d, kind = kind,
        x = wp.x, y = wp.y, z = wp.z, hx = wp.hx, hy = wp.hy,
        board = { at(-hw, bot), at(hw, bot), at(hw, top), at(-hw, top) },
        tris = {}, edge = {} }

  -- One stroke as a filled quad, emitted as two triangles.
  --
  -- Both ends are EXTENDED by half the thickness before the quad is built. Without
  -- that, the two arms of a chevron meet at a V with a wedge missing from the
  -- outside of the joint, which at any distance reads as a broken mark. Extending
  -- overshoots the corner slightly instead, and an overshoot at a mitre is
  -- invisible where a notch is not.
  local function stroke(into, x1, y1, x2, y2, halfT)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-5 then return end
    local ux, uy = dx / len, dy / len
    x1, y1 = x1 - ux * halfT, y1 - uy * halfT
    x2, y2 = x2 + ux * halfT, y2 + uy * halfT
    local nx, ny = -uy * halfT, ux * halfT
    local a, b = at(x1 + nx, y1 + ny), at(x2 + nx, y2 + ny)
    local c, e = at(x2 - nx, y2 - ny), at(x1 - nx, y1 - ny)
    into[#into + 1] = { a, b, c }
    into[#into + 1] = { a, c, e }
  end

  local glyph = marker.GLYPH[kind] or marker.GLYPH.right
  local function place(cx, cv, size)
    -- Thickness scales with the mark, so a big sign gets a bold mark rather
    -- than a large thin one.
    local t = size * TUNE.MARKER_STROKE
    for k = 1, #glyph do
      local q = glyph[k]
      -- The outline goes down FIRST and slightly fatter. Marks are drawn over
      -- whatever the map happens to be -- pale gravel, dark tarmac, grass at
      -- noon -- and a single flat color disappears against one of them. A dark
      -- border means the mark carries its own contrast everywhere.
      stroke(g.edge, cx + q[1] * size, cv + q[2] * size,
                     cx + q[3] * size, cv + q[4] * size, t * TUNE.MARKER_EDGE)
      stroke(g.tris, cx + q[1] * size, cv + q[2] * size,
                     cx + q[3] * size, cv + q[4] * size, t)
    end
  end

  if marker.TILES[kind] then
    local cell = TUNE.MARKER_CELL
    local cols = math.max(1, math.floor(w / cell + 0.5))
    local rows = math.max(1, math.floor(span / cell + 0.5))
    if cols * rows > TUNE.MARKER_MAX_MARKS then
      local scale = math.sqrt(cols * rows / TUNE.MARKER_MAX_MARKS)
      cols = math.max(1, math.floor(cols / scale))
      rows = math.max(1, math.floor(rows / scale))
    end
    local stepU, stepV = w / cols, span / rows
    local size = math.min(stepU, stepV) * 0.44
    for cix = 1, cols do
      local cx = -hw + stepU * (cix - 0.5)
      for riy = 1, rows do
        place(cx, bot + stepV * (riy - 0.5), size)
      end
    end
  else
    -- A U turn or a fork is a diagram, not a repeating mark: one of them,
    -- centerd, as large as the board allows.
    place(0, (top + bot) * 0.5, math.min(w, span) * 0.42)
  end

  g.postA, g.postB = at(-hw, bot), at(-hw, top)
  g.postC, g.postD = at(hw, bot), at(hw, top)
  markerCache[wp] = g
  return g
end

-- A direction marker: a translucent board carrying filled, outlined marks.
-- `lineCol` rather than `color`: the engine's packed-color builder is a GLOBAL
-- called color(), and a parameter of that name shadows it inside this function.
-- That is how the first version came to hand a ColorF to drawTriSolid.
function paint.markerPanel(wp, lineCol, fill)
  local g = markerGeometry(wp)
  local p = palette()

  -- The board. Translucent so the road behind it stays visible: this is
  -- signage, and a sign a driver cannot see through is an obstacle.
  debugDrawer:drawQuadSolid(g.board[1], g.board[2], g.board[3], g.board[4], fill)

  -- Outline first, mark on top. Both are solid fills; the only difference is
  -- that the outline was built fatter.
  --
  -- Skipped entirely when the packed colors are missing, which is the whole
  -- fallback: a build with no global color() draws the board, the posts and
  -- nothing else rather than throwing per triangle per frame.
  if p.markerFace and p.markerEdgeP then
    for i = 1, #g.edge do
      local t = g.edge[i]
      debugDrawer:drawTriSolid(t[1], t[2], t[3], p.markerEdgeP)
    end
    for i = 1, #g.tris do
      local t = g.tris[i]
      debugDrawer:drawTriSolid(t[1], t[2], t[3], p.markerFace)
    end
  end

  -- Edge posts, so the extent of the board reads at distance and in flat light
  -- where a translucent fill alone disappears.
  debugDrawer:drawCylinder(g.postA, g.postB, TUNE.POLE_RADIUS, lineCol)
  debugDrawer:drawCylinder(g.postC, g.postD, TUNE.POLE_RADIUS, lineCol)
end

-- THE PIT STALL IS A BOX, SO IT IS DRAWN AS ONE.
--
-- pit.inside tests a volume: the gate's width across, TUNE.PIT_DEPTH either way
-- along, the gate's height vertically, measured on the stall's own axes. Two
-- poles showed a PLANE for a rule that is a volume, and then the mod asked the
-- driver to "come to a stop inside the box" without ever drawing the box. This
-- draws the actual test.
--
-- The walls are low on purpose. The height half of the test excludes nobody -- a
-- car on the road is always within a few meters of the stall vertically -- so
-- drawing it at full gate height would be a tall pair of walls implying a
-- constraint that is not doing any work. The FOOTPRINT is the part that decides,
-- so the footprint is what is drawn honestly and the rest is kept out of the way.
function paint.pitBox(wp, color)
  local w = (gateDims(wp))
  local hw = w * 0.5
  local d  = TUNE.PIT_DEPTH
  local fx, fy = wp.hx or 0, wp.hy or 1
  local rx, ry = fy, -fx
  local z = wp.z
  -- corner(sr, sf): center + lateral*sr*hw + forward*sf*d
  local function corner(sr, sf, up)
    return vec3(wp.x + rx * sr * hw + fx * sf * d,
                wp.y + ry * sr * hw + fy * sf * d,
                z + (up or 0))
  end
  local p = palette()
  local bl, br = corner(-1, -1), corner(1, -1)
  local fl, fr = corner(-1,  1), corner(1,  1)
  -- The floor: where to stop, filled so the extent is unmistakable and faint
  -- enough that the road under it stays readable.
  debugDrawer:drawQuadSolid(bl, br, fr, fl, p.pitFill)
  -- Two side walls, open front and back: a stall is driven into and out of.
  local blu, flu = corner(-1, -1, TUNE.PIT_WALL_H), corner(-1, 1, TUNE.PIT_WALL_H)
  local bru, fru = corner(1, -1, TUNE.PIT_WALL_H), corner(1, 1, TUNE.PIT_WALL_H)
  debugDrawer:drawQuadSolid(bl, fl, flu, blu, p.pitWall)
  debugDrawer:drawQuadSolid(br, fr, fru, bru, p.pitWall)
  -- Corner posts, so the box has an outline at distance and in flat light where
  -- a translucent fill alone disappears.
  local r = TUNE.POLE_RADIUS
  debugDrawer:drawCylinder(bl, blu, r, color)
  debugDrawer:drawCylinder(br, bru, r, color)
  debugDrawer:drawCylinder(fl, flu, r, color)
  debugDrawer:drawCylinder(fr, fru, r, color)
  -- The line across the middle of the box: where the car actually wants to be.
  local ml = vec3(wp.x + rx * hw, wp.y + ry * hw, z + 0.05)
  local mr = vec3(wp.x - rx * hw, wp.y - ry * hw, z + 0.05)
  debugDrawer:drawCylinder(ml, mr, r * 0.6, color)
  -- A CHEVRON POINTING THE WAY THE STALL FACES.
  --
  -- The box alone is symmetrical, so it says where to stop and nothing about
  -- which way round. That matters now that stopping in one stands the car on
  -- the stall's heading: without this the car turning as it is serviced looks
  -- arbitrary rather than like being pointed back down the lane.
  --
  -- Sized off the stall's DEPTH rather than its width, so it stays car-sized on
  -- a stall that inherited a wide checkpoint's span.
  local p2 = palette()
  local tip  = vec3(wp.x + fx * d * 0.55, wp.y + fy * d * 0.55, z + 0.06)
  local tail = vec3(wp.x - fx * d * 0.35, wp.y - fy * d * 0.35, z + 0.06)
  local barb = math.min(hw, d * 0.5)
  local bl2  = vec3(tip.x - fx * d * 0.4 + rx * barb, tip.y - fy * d * 0.4 + ry * barb, z + 0.06)
  local br2  = vec3(tip.x - fx * d * 0.4 - rx * barb, tip.y - fy * d * 0.4 - ry * barb, z + 0.06)
  debugDrawer:drawCylinder(tail, tip, r * 0.5, p2.pitArrow)
  debugDrawer:drawCylinder(bl2, tip, r * 0.5, p2.pitArrow)
  debugDrawer:drawCylinder(br2, tip, r * 0.5, p2.pitArrow)
end

-- `fill` and `glyph` are for the joker and nothing else. An ordinary checkpoint
-- stays two bare poles: it is passed at speed, it means one thing, and anything
-- painted across it is one more object between a driver and the corner.
local function drawPoleGate(wp, color, label, fill, glyph)
  local g = gateGeometry(wp)
  local r = TUNE.POLE_RADIUS
  if fill then debugDrawer:drawQuadSolid(g.bl, g.br, g.tr, g.tl, fill) end
  debugDrawer:drawCylinder(g.bl, g.tl, r, color)
  debugDrawer:drawCylinder(g.br, g.tr, r, color)
  if glyph then paint.glyph(g, glyph) end
  if label then
    local p = palette()
    -- ON the gate, not floating above it. A label at `mid` hangs over the top
    -- edge, which reads as a sign near the gate rather than a fact about it, and
    -- from a car it can sit against the sky with nothing behind it.
    debugDrawer:drawTextAdvanced(fill and g.center or g.mid,
      String(label), p.text, true, false, p.textBg)
  end
end

local function drawDriverGate(derbyLive)
  if not debugDrawer or not edit.visualize then return end
  if derbyLive or session.spectatorLock then return end
  if #track.route == 0 then return end
  -- EVERY PHASE, not just a running session. A driver who loads a track and
  -- looks at it wants to see where the gates are as much as one racing through
  -- them, and the joker LABEL is drawn on those terms already, so gating the
  -- poles on the phase left a label floating over an invisible gate until the
  -- lights went out. The stock markers this replaced had no phase gate either.
  local p = palette()
  local n = #track.route

  -- NO TEXT ON ANY GATE, INCLUDING THE JOKER. The poles say where a gate is and
  -- the color says which one is next; a driver reading "CP 3" at speed learns
  -- nothing they can act on, and it is one more thing painted across the racing
  -- line.
  --
  -- The joker was the last exception, on the grounds that its STATE changes what
  -- a driver must do -- owed, taken, or forbidden on lap 1 -- and getting it
  -- wrong is a disqualification. That reasoning still holds; the words were just
  -- the wrong way to carry it. The glyph says the same thing (a cross for shut, a
  -- tick for done, an arrow for open) and says it at a glance, where
  -- "JOKER 1/2 (lap 1: closed)" is a sentence to read at racing speed. The fill
  -- and the symbol stay, the sentence goes.
  --
  -- The editor still numbers and labels everything, joker included: that is where
  -- the words are worth reading, and where there is time to read them.
  --
  -- ALL of a checkpoint's gates are drawn, not one of them. A branch gate is
  -- another way through the same checkpoint, so a driver has to be able to see
  -- both and pick; showing one would be choosing for them. On a head-on oval the
  -- two sit at opposite ends of the circuit and only one is ever in view anyway.
  local function poles(g, color) drawPoleGate(g, color, nil) end
  local a = session.armedWp
  if a < 1 or a > n then a = 1 end
  branch.eachAt(a, poles, p.armed)

  -- The ones after it, dimmed, so a corner reads before it arrives. Skipped on a
  -- one-gate route, where "the next one" is the one already drawn.
  --
  -- AND SKIPPED ON THE LAST LAP ONCE THE LINE IS THE ARMED GATE. The look-ahead
  -- wraps -- the gate after the start/finish is CP 1 -- and on the final lap
  -- that is CP 1 of a lap nobody is going to drive: crossing the line ends this
  -- driver's race. Drawing it lights a gate on track that means nothing, at the
  -- exact moment a driver is racing hardest and least wants to be asked to work
  -- out which of two lit gates is the one that matters.
  --
  -- Only the wrap is suppressed. Everywhere else on the last lap the look-ahead
  -- is as useful as it is on any other, so `a == n` is the whole condition.
  local lastLap = session.phase == 'racing' and not track.pointToPoint
    and session.totalLaps > 0 and session.localLap >= session.totalLaps
  if n > 1 and not (lastLap and a == n) then
    branch.eachAt(a % n + 1, poles, p.routeNext or p.route)
  end

  -- MARKERS, ALL OF THEM, ALWAYS.
  --
  -- Unlike a checkpoint there is no "next" marker to highlight and nothing to
  -- arm: a sign is useful precisely when the driver has not reached it yet, so
  -- there is no look-ahead window to limit this to. They are cheap -- a quad,
  -- a few segments and two posts each -- and a stage carries a handful.
  --
  -- Drawn for a driver as well as in the editor, which is the whole reason they
  -- exist: the editor pass above adds numbering and picks up the nudge
  -- selection, and this one is the sign as a driver sees it.
  if not edit.open then
    for _, wp in ipairs(marker.list) do
      paint.markerPanel(wp, p.markerLine, p.markerFill)
    end
  end

  -- The joker and the nearest pit stall, in the same style and the same colors
  -- they have always had. They used to be the stock markers' job (slots 3 and 4)
  -- and are drawn here now so a track has ONE checkpoint visual rather than two
  -- that do not match.
  if session.jokerEnabled and #track.jokerRoute > 0 then
    local j = session.jokerArmed
    if j < 1 or j > #track.jokerRoute then j = 1 end
    local wp = track.jokerRoute[j]
    if wp then
      local state = session.jokerTaken and 'used'
        or ((sessionRunning() and session.localLap <= 1) and 'closed' or 'open')
      -- The joker is the one gate whose STATE changes what a driver must do, so
      -- it is the one gate that earns a fill and a symbol. NO LABEL: the glyph
      -- carries the state on its own and carries it faster (see the note above),
      -- so the text was a sentence competing with the picture that had already
      -- said it. `jokerLabel` is still what the editor draws.
      local glyph = (state == 'used' and 'done')
        or (state == 'closed' and 'shut')
        or 'open'
      drawPoleGate(wp, session.jokerTaken and p.jokerUsed or p.joker, nil,
        session.jokerTaken and p.jokerUsedFill or p.jokerFill, glyph)
    end
  end
  if #track.pitRoute > 0 then
    local _, ppos = sampledVehicle()
    local best, bestD = 1, math.huge
    if ppos then
      for i, wp in ipairs(track.pitRoute) do
        local dx, dy = wp.x - ppos.x, wp.y - ppos.y
        local d = dx * dx + dy * dy
        if d < bestD then best, bestD = i, d end
      end
    end
    -- Amber, and unlabeled like the rest: a pit stall is somewhere you either
    -- meant to go or did not. Drawn as the BOX pit.inside actually tests, so
    -- "come to a stop inside the box" refers to something the driver can see.
    if track.pitRoute[best] then paint.pitBox(track.pitRoute[best], p.pit) end
  end
end

-- Is this the gate the mouse has hold of? Only ever true for the list the
-- editor is actually on, so a slot 2 selection on the grid does not light up
-- checkpoint 2 as well.
local function nudgeSelected(list, i)
  return nudge.on and nudge.sel == i and nudge.list == list
end

local function drawGates(derbyLive)
  if not debugDrawer then return end
  -- The full circuit of numbered rectangles is the EDITOR's view and only the
  -- editor's. A driver gets drawDriverGate above: the gate they are aiming at
  -- and the one after it, which is what they can act on. `visualize` still hides
  -- both for an admin who wants the unobstructed view while placing gates.
  if not (edit.open and session.isAdmin) then
    drawDriverGate(derbyLive)
    return
  end
  if not edit.visualize then return end
  local authoring = true
  -- Still needed below: which gate is armed, and whether the joker is open,
  -- only mean anything while a session is under way.
  local active = sessionRunning() or session.phase == 'countdown' or session.phase == 'grid'
  local p = palette()

  local n = #track.route
  for i, wp in ipairs(track.route) do
    local color
    if i == n then
      color = p.finish
    elseif active and i == session.armedWp then
      color = p.armed
    else
      color = p.route
    end
    -- A checkpoint with branch gates is labeled with how many, so an admin can
    -- see at a glance which corners are shared and which are taken two ways.
    local label = routeLabel(i, n)
    local alts = branch.bySlot[i]
    if alts and #alts > 0 then label = label .. ' (+' .. #alts .. ')' end
    if nudgeSelected(track.route, i) then color = p.nudged end
    drawGate(wp, color, label, authoring)
  end

  -- Branch gates: cyan, so they never read as part of the main lap, and labeled
  -- with the CHECKPOINT they belong to rather than their position in this list --
  -- a branch gate is not a checkpoint of its own, it is the other way of taking
  -- one that already exists, and the number has to say so.
  --
  -- Armed green on the same terms as its checkpoint, because it genuinely is
  -- armed: crossing it clears the slot exactly as the main gate would.
  for gi, g in ipairs(branch.list) do
    local slot = tonumber(g.slot) or 0
    local color = p.branch or p.joker
    if active and slot == session.armedWp then color = p.armed end
    if nudgeSelected(branch.list, gi) then color = p.nudged end
    drawGate(g, color, 'CP ' .. slot .. ' branch', authoring)
  end

  -- Pit stalls. Amber, and labeled as stalls rather than numbered gates: they
  -- are not part of the checkpoint sequence and must not look as though they
  -- are. Editor only -- a driver gets a pole on the nearest one instead.
  -- Direction markers. Drawn in the editor with a number, so an admin can tell
  -- the panel's list from what is on the ground.
  for i, wp in ipairs(marker.list) do
    local col = nudgeSelected(marker.list, i) and p.nudged or p.markerLine
    paint.markerPanel(wp, col, p.markerFill)
    debugDrawer:drawTextAdvanced(
      vec3(wp.x, wp.y, wp.z + (gateDims(wp)) * 0 + 1.2),
      String('MARKER ' .. i .. ' ' .. (marker.LABEL[wp.kind] or '')),
      p.text, true, false, p.textBg)
  end

  for i, wp in ipairs(track.pitRoute) do
    local col = nudgeSelected(track.pitRoute, i) and p.nudged or p.pit
    -- THE BOX, AND ONLY THE BOX.
    --
    -- This used to draw the footprint and then a full-height gate on top of it,
    -- which is two shapes for one rule and the taller one won: a stall read as a
    -- pair of tall amber poles, exactly like a checkpoint it is not, while the
    -- rectangle on the ground that actually decides the stop was lost underneath
    -- them.
    --
    -- A stall is a footprint. It is drawn as one, with its corner posts for
    -- distance, and the label floats over the middle where the car is meant to
    -- end up rather than being pinned to a gate that is no longer there.
    paint.pitBox(wp, col)
    debugDrawer:drawTextAdvanced(
      vec3(wp.x, wp.y, wp.z + TUNE.PIT_WALL_H + 0.9),
      String('PIT ' .. i), p.text, true, false, p.textBg)
  end

  -- Joker route: violet, so it never reads as part of the main lap. The next
  -- joker gate lights up green like the main route, and the whole set grays out
  -- once the joker has been used (or while it is still forbidden on lap 1).
  local jn = #track.jokerRoute
  local state = session.jokerTaken and 'used'
    or ((active and session.localLap <= 1) and 'closed' or 'open')
  for i, wp in ipairs(track.jokerRoute) do
    local color
    if session.jokerTaken then
      color = p.jokerUsed
    elseif active and session.jokerEnabled and i == session.jokerArmed then
      color = p.armed
    else
      color = p.joker
    end
    if nudgeSelected(track.jokerRoute, i) then color = p.nudged end
    drawGate(wp, color, jokerLabel(i, jn, state), authoring)
  end
end

-- ===========================================================================
-- DEMO DERBY: its own module now
-- ===========================================================================
-- Nine hundred lines of it used to sit here in a `do` block. It moved out
-- because this file reached Lua's 200 active-locals ceiling exactly, where
-- the next `local` anybody added ANYWHERE stopped the whole mod compiling,
-- and the derby was the cleanest seam in the file: its own state, its own
-- server events, its own guihooks channels, its own editor.
--
-- What it needs from here is handed over ONCE, below. Mutable scalars go as
-- getters rather than values: `phase` captured at load is whatever the phase
-- happened to be at load, forever.

-- ---------------------------------------------------------------------------
-- What the extension calls
-- ---------------------------------------------------------------------------
-- Five names, where the file previously reached into fifteen. Everything else
-- above is this module's own business.
R.palette            = palette
R.drawGates          = drawGates
R.drawStartPosition  = drawStartPosition
R.drawStartPositions = drawStartPositions

-- Gate labels are built once per route and cached. The extension invalidates
-- them when the route CHANGES SHAPE in a way the label text depends on --
-- switching between circuit and point-to-point, which changes what the last
-- gate is called. Exposed as a function rather than as the cache table: the
-- caller is saying "these are stale", not reaching into a data structure.
function R.invalidateLabels()
  labelCache.route = {}
end

return R
