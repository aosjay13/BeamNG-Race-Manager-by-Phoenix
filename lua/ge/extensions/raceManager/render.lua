-- Race Manager: THE RENDERER, as its own module.
--
-- Everything this mod draws in the 3D world: the palette, gate geometry and its
-- cache, checkpoint and joker gates, the starting grid, pit stalls, direction
-- markers, and the per-frame pass that decides which of them a driver sees.
--
-- THE CONTRACT: everything arrives once through init(host), as stable tables
-- or plain functions, never getters (`track.route` is rebound, `track` is not):
--
--   track, session, edit   the models, by reference
--   marker, nudge, branch, pit   subsystem tables, by reference
--   TUNE                   tuning constants
--   gateDims, sampledVehicle, sessionRunning, jokerClosed   plain functions
--
-- Nothing here writes host state.

local R = {}

-- Assigned by init; declared here so every function below closes over them.
local track, session, edit, TUNE, marker, nudge, branch, pit
local gateDims, sampledVehicle, sessionRunning, jokerClosed

function R.init(h)
  track, session, edit = h.track, h.session, h.edit
  TUNE   = h.TUNE
  marker, nudge, branch, pit = h.marker, h.nudge, h.branch, h.pit
  gateDims       = h.gateDims
  sampledVehicle = h.sampledVehicle
  sessionRunning = h.sessionRunning
  -- The host's joker rule, so the gate is drawn on the terms it is enforced on.
  jokerClosed    = h.jokerClosed
end

local PALETTE = nil

local function palette()
  if PALETTE then return PALETTE end
  -- Every gate color is at FULL VALUE and near-full alpha: they are drawn over
  -- any map in any light. The hues are learned (green next, orange route, white
  -- line, violet joker, amber pit) and must not change. Built once: ColorF does
  -- not exist while this file loads.
  PALETTE = {
    finish    = ColorF(1, 1, 1, 1),            -- start/finish: white
    armed     = ColorF(0.25, 1, 0.45, 1),      -- next target: green
    route     = ColorF(1, 0.45, 0.05, 0.95),   -- rest of route: orange
    -- The gate after the armed one, dimmed so it does not compete.
    routeNext = ColorF(1, 0.45, 0.05, 0.45),
    -- The gate nudge mode holds: magenta, a color the track never uses.
    nudged    = ColorF(1, 0.2, 0.9, 1),
    joker     = ColorF(0.72, 0.35, 1, 1),      -- joker route: violet
    -- Duller, so "already taken" reads at a glance, but still clearly drawn.
    jokerUsed = ColorF(0.62, 0.62, 0.7, 0.6),  -- joker already taken: dimmed
    pit       = ColorF(1, 0.78, 0.15, 1),      -- pit stalls: amber
    -- Branch gates: cyan, never confusable with an extra route checkpoint.
    branch      = ColorF(0.2, 0.85, 0.95, 1),
    text      = ColorF(1, 1, 1, 1),
    -- The editor gate's fill: faint, so the road shows through.
    fill      = ColorF(0.35, 0.65, 1, 0.16),
    textBg    = ColorI(0, 0, 0, 160),
    -- The joker label's violet backing, tellable from a checkpoint's at speed.
    jokerLabelBg = ColorI(70, 20, 110, 190),
    -- A driver's fills, fainter than the editor's.
    jokerFill    = ColorF(0.72, 0.35, 1, 0.13),
    jokerUsedFill = ColorF(0.62, 0.62, 0.7, 0.10),
    -- The stall FOOTPRINT is the rule, so it has to read (0.11 vanished).
    pitFill      = ColorF(1, 0.72, 0.1, 0.24),
    pitWall      = ColorF(1, 0.72, 0.1, 0.14),
    -- The floor chevron: which way the car is stood when it stops.
    pitArrow     = ColorF(1, 0.88, 0.35, 0.85),
    -- Stalls other than the nearest: same amber, dimmer.
    pitFar       = ColorF(1, 0.72, 0.1, 0.45),
    -- See-through walls in two bands, fading upward.
    pitWallLow   = ColorF(1, 0.72, 0.1, 0.34),
    pitWallHigh  = ColorF(1, 0.72, 0.1, 0.12),
    -- The front edge, where the nose stops: white, because amber is the box.
    pitStop      = ColorF(1, 1, 1, 0.95),
    -- The box the car is in turns green: in, now stop.
    pitIn        = ColorF(0.25, 1, 0.45, 1),
    pitInFill    = ColorF(0.25, 1, 0.45, 0.22),
    pitInLow     = ColorF(0.25, 1, 0.45, 0.34),
    pitInHigh    = ColorF(0.25, 1, 0.45, 0.12),
    -- Direction markers: cyan, borrowing no color with a learned meaning.
    markerLine   = ColorF(0.2, 0.95, 1, 0.95),
    markerFill   = ColorF(0.2, 0.85, 1, 0.13),
    markerSel    = ColorF(1, 1, 1, 1),
    -- PACKED INTEGERS, NOT ColorF: drawTriSolid takes the global color(r,g,b,a)
    -- (0..255), and a ColorF throws once per triangle per frame. nil without
    -- `color`: the faces are skipped and the rest of the marker draws.
    markerFace   = type(color) == 'function' and color(51, 242, 255, 240) or nil,
    markerEdgeP  = type(color) == 'function' and color(5, 15, 23, 235) or nil,
    -- The joker state glyph: a cross while shut, a tick once spent.
    glyphShut    = ColorF(1, 0.25, 0.25, 0.5),
    glyphDone    = ColorF(0.3, 1, 0.45, 0.5),
    -- Fainter: it sits on a gate the driver aims THROUGH.
    glyphOpen    = ColorF(0.85, 0.7, 1, 0.28),
    -- The P on a pit entry gate, white like a parking sign's.
    glyphPit     = ColorF(1, 1, 1, 0.9),
    -- Demo derby arena.
    derbyLive    = ColorF(0.9, 0.15, 0.15, 0.9),  -- live arena edges: red
    derbySetup   = ColorF(0.9, 0.6, 0.1, 0.8),    -- setup/finished edges: amber
    derbyLabelBg = ColorI(120, 0, 0, 180),
    -- Arena walls: a visible surface in the editor, a faint haze live (a car on
    -- the far side must still show through).
    derbyWallEdit = ColorF(0.95, 0.55, 0.1, 0.30),
    derbyWallLive = ColorF(0.9, 0.2, 0.15, 0.12),
    -- Editor floor: shows the extent without hiding the ground.
    derbyFloor   = ColorF(0.35, 0.65, 1, 0.10),
    -- Start-slot outlines.
    slotMine     = ColorF(0.2, 0.85, 0.35, 0.95),   -- the slot that is yours
    slotPole     = ColorF(1, 0.85, 0.2, 0.85),      -- P1
    slotOther    = ColorF(0.35, 0.65, 1, 0.75),     -- everyone else
  }
  -- A stall's colors as sets, picked by state with a table lookup.
  local P = PALETTE
  P.pitSets = {
    near  = { line = P.pit,    fill = P.pitFill,   low = P.pitWallLow, high = P.pitWallHigh, arrow = P.pitArrow },
    far   = { line = P.pitFar, fill = P.pitFill,   low = P.pitWall,    high = P.pitWall,     arrow = P.pitArrow },
    inbox = { line = P.pitIn,  fill = P.pitInFill, low = P.pitInLow,   high = P.pitInHigh,   arrow = P.pitIn },
    sel   = { line = P.nudged, fill = P.pitFill,   low = P.pitWallLow, high = P.pitWallHigh, arrow = P.pitArrow },
  }
  return PALETTE
end

-- Per-gate geometry cache, so a steady frame allocates no vec3s (it was the
-- largest source of GC pressure). WEAK keys, so a deleted gate takes its entry;
-- not stored on the waypoint, which is serialised verbatim.
local gateCache = setmetatable({}, { __mode = 'k' })

-- Rebuilt only when placement or dimensions moved. Dimensions are re-derived
-- each frame (two clamps), so a size change needs no notification.
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
  -- corner(sr, up): `up` true is the top bar (h above), false the bottom (d below).
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
  -- The middle of the gate's face (`mid` floats above it, for editor labels).
  g.center = (g.bl + g.tr) * 0.5
  -- The authoring direction arrow, cached with the corners.
  local ax, ay = wp.hx or 0, wp.hy or 1
  g.arrowBase = vec3(wp.x, wp.y, wp.z + 0.35)
  g.arrowTip  = vec3(wp.x + ax * 3.5, wp.y + ay * 3.5, wp.z + 0.35)
  local hx, hy = ay * 0.9, -ax * 0.9
  g.arrowL = vec3(g.arrowTip.x - ax * 1.1 + hx, g.arrowTip.y - ay * 1.1 + hy, g.arrowTip.z)
  g.arrowR = vec3(g.arrowTip.x - ax * 1.1 - hx, g.arrowTip.y - ay * 1.1 - hy, g.arrowTip.z)
  gateCache[wp] = g
  return g
end

-- A gate. `authoring`: the editor's full view (fill, label, direction arrow) of
-- the same checkpoint a driver sees as poles.
local function drawGate(wp, color, label, authoring)
  local g = gateGeometry(wp)

  if authoring then
    -- The crossing test's surface, filled and translucent.
    local p = palette()
    debugDrawer:drawQuadSolid(g.bl, g.br, g.tr, g.tl, p.fill)
  end

  -- Verticals thicker than the horizontals, so it reads as a gate at distance.
  debugDrawer:drawCylinder(g.bl, g.tl, TUNE.EDGE_RADIUS, color)
  debugDrawer:drawCylinder(g.br, g.tr, TUNE.EDGE_RADIUS, color)
  debugDrawer:drawCylinder(g.bl, g.br, TUNE.EDGE_RADIUS * 0.6, color)
  debugDrawer:drawCylinder(g.tl, g.tr, TUNE.EDGE_RADIUS * 0.6, color)

  local p = palette()
  debugDrawer:drawTextAdvanced(g.mid, String(label), p.text, true, false, p.textBg)

  if authoring then
    -- Which way through the gate counts: a rectangle alone is symmetrical.
    debugDrawer:drawCylinder(g.arrowBase, g.arrowTip, 0.10, color)
    debugDrawer:drawCylinder(g.arrowL, g.arrowTip, 0.10, color)
    debugDrawer:drawCylinder(g.arrowR, g.arrowTip, 0.10, color)
  end
end

-- Gate labels, built once per route instead of a fresh string per gate per
-- frame. Joker labels have three states, all precomputed.
local labelCache = {
  routeLen = -1, jokerLen = -1,
  route = {}, joker = {}, alt = {}, branch = {}, marker = {}, pit = {}, slot = {},
}

local function routeLabel(i, n)
  if labelCache.routeLen ~= n or labelCache.p2p ~= track.pointToPoint then
    labelCache.routeLen = n
    labelCache.p2p = track.pointToPoint
    labelCache.route = {}
    labelCache.alt = {}
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

-- A checkpoint label with its branch count, invalidated by the count too.
local function routeAltLabel(i, n, alts)
  local base = routeLabel(i, n)      -- runs first: it clears `alt` when stale
  if alts == 0 then return base end
  local e = labelCache.alt[i]
  if not e or e.n ~= alts then
    e = { n = alts, s = base .. ' (+' .. alts .. ')' }
    labelCache.alt[i] = e
  end
  return e.s
end

-- A branch gate's label is a pure function of its slot.
local function branchLabel(slot)
  local l = labelCache.branch[slot]
  if not l then
    l = 'CP ' .. slot .. ' branch'
    labelCache.branch[slot] = l
  end
  return l
end

-- A marker's label carries its symbol, which can change, so it is checked.
local function markerLabel(i, kind)
  local e = labelCache.marker[i]
  if not e or e.kind ~= kind then
    e = { kind = kind, s = 'MARKER ' .. i .. ' ' .. (marker.LABEL[kind] or '') }
    labelCache.marker[i] = e
  end
  return e.s
end

local function pitLabel(i)
  local l = labelCache.pit[i]
  if not l then
    l = 'PIT ' .. i
    labelCache.pit[i] = l
  end
  return l
end

-- Two per slot: plain, and yours.
local function slotLabel(i, mine)
  local e = labelCache.slot[i]
  if not e then
    e = { plain = 'P' .. i, mine = 'P' .. i .. ' (YOU)' }
    labelCache.slot[i] = e
  end
  return mine and e.mine or e.plain
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

-- Start-slot geometry cache, on gateCache's terms. Slot sizes are TUNE
-- constants, so placement alone decides staleness.
local slotCache = setmetatable({}, { __mode = 'k' })

local function slotGeometry(sp)
  local g = slotCache[sp]
  if g and g.x == sp.x and g.y == sp.y and g.z == sp.z
      and g.hx == sp.hx and g.hy == sp.hy then
    return g
  end

  local fx, fy = sp.hx, sp.hy
  local rx, ry = sp.hy, -sp.hx
  local hl, hw = TUNE.START_SLOT_LEN * 0.5, TUNE.START_SLOT_WIDE * 0.5
  local function corner(sf, sr)
    return vec3(sp.x + fx * sf * hl + rx * sr * hw,
                sp.y + fy * sf * hl + ry * sr * hw,
                sp.z + 0.05)
  end
  local head = vec3(sp.x + fx * hl * 0.9, sp.y + fy * hl * 0.9, sp.z + 0.06)
  -- Barbs across the slot, readable from above and from the car.
  local barb = hl * 0.42
  g = {
    x = sp.x, y = sp.y, z = sp.z, hx = sp.hx, hy = sp.hy,
    c = { corner(-1, -1), corner(-1, 1), corner(1, 1), corner(1, -1) },
    tail = vec3(sp.x - fx * hl * 0.6, sp.y - fy * hl * 0.6, sp.z + 0.06),
    head = head,
    barbL = vec3(head.x - fx * barb + rx * barb * 0.8,
                 head.y - fy * barb + ry * barb * 0.8, head.z),
    barbR = vec3(head.x - fx * barb - rx * barb * 0.8,
                 head.y - fy * barb - ry * barb * 0.8, head.z),
    label = vec3(sp.x, sp.y, sp.z + 1.4),
  }
  slotCache[sp] = g
  return g
end

local function drawStartPosition(sp, index, mine)
  local g = slotGeometry(sp)
  local p = palette()
  local color = mine and p.slotMine
    or (index == 1 and p.slotPole or p.slotOther)
  local c = g.c
  for i = 1, 4 do
    debugDrawer:drawCylinder(c[i], c[i % 4 + 1], 0.08, color)
  end
  -- The arrow needs a head: a bare axis line looks the same both ways round.
  debugDrawer:drawCylinder(g.tail, g.head, 0.06, color)
  debugDrawer:drawCylinder(g.head, g.barbL, 0.06, color)
  debugDrawer:drawCylinder(g.head, g.barbR, 0.06, color)

  debugDrawer:drawTextAdvanced(g.label, String(slotLabel(index, mine)),
    p.text, true, false, p.textBg)
end

local function drawStartPositions()
  if #track.startPositions == 0 or not debugDrawer then return end
  -- Editor furniture only, drawn while the editor is open. startPositions
  -- itself still drives placement, the server count and the saved layout.
  if not edit.open then return end
  -- Inside the editor, the Hide/Show Gates toggle applies.
  if not edit.visualize then return end
  for i, sp in ipairs(track.startPositions) do
    drawStartPosition(sp, i, session.gridSlot == i)
  end
end

-- Drawing helpers that are not a gate, on ONE local for the locals ceiling.
local paint = {}

-- The joker state glyph across a gate's face: drawn, not written, because it is
-- read at speed. Sized off the gate, capped. Its points hang off the gate's own
-- cache and go stale with it.
local function glyphPoints(g)
  local gp = g.glyph
  if gp then return gp end
  local half = math.min(g.w, g.h) * 0.22
  if half > 2.2 then half = 2.2 end
  if half < 0.6 then half = 0.6 end
  local c = g.center
  -- The gate's own axes: the glyph lies in the gate's plane.
  local rx, ry = g.hy, -g.hx
  local function at(sr, su)
    return vec3(c.x + rx * sr * half, c.y + ry * sr * half, c.z + su * half)
  end
  gp = {
    bl = at(-1, -1), br = at(1, -1), tl = at(-1, 1), tr = at(1, 1),
    -- The up-arrow's stem and its two barbs.
    down = at(0, -1), up = at(0, 1), armL = at(-0.55, 0.3), armR = at(0.55, 0.3),
    -- The tick's elbow.
    tickA = at(-0.9, 0.1), tickB = at(-0.25, -0.85),
    -- The P: a stem and a bowl with its corners cut.
    pBase = at(-0.5, -1), pTop = at(-0.5, 1), pTopR = at(0.2, 1),
    pUpper = at(0.55, 0.7), pLower = at(0.55, 0.35), pMidR = at(0.2, 0.05),
    pMid = at(-0.5, 0.05),
    -- A label clear of the glyph.
    label = at(0, 1.5),
  }
  g.glyph = gp
  return gp
end

function paint.glyph(g, kind)
  local p = palette()
  local at = glyphPoints(g)
  local r = TUNE.POLE_RADIUS * 0.8
  if kind == 'open' then
    -- An arrow up: take it. Faded hard, on a gate the driver aims through.
    debugDrawer:drawCylinder(at.down, at.up, r * 0.8, p.glyphOpen)
    debugDrawer:drawCylinder(at.up, at.armL, r * 0.8, p.glyphOpen)
    debugDrawer:drawCylinder(at.up, at.armR, r * 0.8, p.glyphOpen)
  elseif kind == 'shut' then
    debugDrawer:drawCylinder(at.bl, at.tr, r, p.glyphShut)
    debugDrawer:drawCylinder(at.tl, at.br, r, p.glyphShut)
  elseif kind == 'done' then
    -- A tick: short stroke down into the corner, long stroke up and out.
    debugDrawer:drawCylinder(at.tickA, at.tickB, r, p.glyphDone)
    debugDrawer:drawCylinder(at.tickB, at.tr, r, p.glyphDone)
  elseif kind == 'pit' then
    -- A P for the pit entry: yellow alone did not say "pits".
    local w = r * 1.2
    debugDrawer:drawCylinder(at.pBase, at.pTop, w, p.glyphPit)
    debugDrawer:drawCylinder(at.pTop, at.pTopR, w, p.glyphPit)
    debugDrawer:drawCylinder(at.pTopR, at.pUpper, w, p.glyphPit)
    debugDrawer:drawCylinder(at.pUpper, at.pLower, w, p.glyphPit)
    debugDrawer:drawCylinder(at.pLower, at.pMidR, w, p.glyphPit)
    debugDrawer:drawCylinder(at.pMidR, at.pMid, w, p.glyphPit)
  end
end

-- A DIRECTION MARKER: a translucent board with its symbol TILED across it, so
-- the shape holds at any width (one arrow on a 40 m board is a dot). Filled
-- polygons, built when the marker changes and cached (a board can carry sixty
-- marks). Module-local, not on the shared marker table: this module's locals
-- are nil until init, so a load-time write onto `marker` would kill require.
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
        -- The editor label's position, cached with the rest.
        label = vec3(wp.x, wp.y, wp.z + 1.2),
        tris = {}, edge = {} }

  -- One stroke as a filled quad (two triangles), both ends EXTENDED by half the
  -- thickness so a chevron's mitre overshoots rather than notches.
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
  local function place(cx, cv, size, ratio)
    -- Thickness scales with the mark. Shapes take their own thinner ratio: a
    -- shared one gave a 10 m U turn a 3.2 m outline and it collapsed into a blob.
    local t = size * ratio
    for k = 1, #glyph do
      local q = glyph[k]
      -- The dark outline goes down first, slightly fatter, so the mark carries
      -- its own contrast on any ground.
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
        place(cx, bot + stepV * (riy - 0.5), size, TUNE.MARKER_STROKE)
      end
    end
  else
    -- A shape is a diagram: one, centered, as large as the board allows.
    place(0, (top + bot) * 0.5, math.min(w, span) * 0.42, TUNE.MARKER_SHAPE_STROKE)
  end

  g.postA, g.postB = at(-hw, bot), at(-hw, top)
  g.postC, g.postD = at(hw, bot), at(hw, top)
  markerCache[wp] = g
  return g
end

-- A direction marker: a translucent board carrying filled, outlined marks.
-- `lineCol`, not `color`: that would shadow the engine's global color().
function paint.markerPanel(wp, lineCol, fill)
  local g = markerGeometry(wp)
  local p = palette()

  -- The board, translucent: a sign a driver cannot see through is an obstacle.
  debugDrawer:drawQuadSolid(g.board[1], g.board[2], g.board[3], g.board[4], fill)

  -- Outline first, then the mark. Skipped without packed colors (see palette).
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

  -- Edge posts, so the board's extent reads in flat light.
  debugDrawer:drawCylinder(g.postA, g.postB, TUNE.POLE_RADIUS, lineCol)
  debugDrawer:drawCylinder(g.postC, g.postD, TUNE.POLE_RADIUS, lineCol)
end

-- THE PIT STALL: a car-sized box (pit.dims) on the ground, opaque outline,
-- walls on both sides and the front fading upward, the rear open as the way in,
-- a white stop bar, and green while the car is in it. (A translucent floor
-- read as tarmac; poles did not say where to stop.) Geometry cached per stall.
local pitCache = setmetatable({}, { __mode = 'k' })

-- Ground under (x, y), probed from just above (a driven stall floats half a
-- meter up). Short range, so a roof is never found. Rebuilds only.
local function stallGround(x, y, z)
  if type(castRayStatic) ~= 'function' then return nil end
  local ok, dist = pcall(castRayStatic, vec3(x, y, z + 1), vec3(0, 0, -1), 3)
  if ok and type(dist) == 'number' and dist < 3 then return z + 1 - dist end
  return nil
end

local function pitGeometry(wp)
  local w, len = pit.dims(wp)
  local _, gh = gateDims(wp)     -- only for the retired poles, below
  local g = pitCache[wp]
  if g and g.w == w and g.len == len and g.h == gh
      and g.x == wp.x and g.y == wp.y and g.z == wp.z
      and g.hx == wp.hx and g.hy == wp.hy then
    return g
  end

  local hw, hl = w * 0.5, len * 0.5
  local fx, fy = wp.hx or 0, wp.hy or 1
  local rx, ry = fy, -fx
  local base = stallGround(wp.x, wp.y, wp.z) or wp.z
  local H = TUNE.PIT_WALL_H
  -- Each corner on its own ground, at floor, band split and wall top.
  local function corner(sr, sf)
    local x = wp.x + rx * sr * hw + fx * sf * hl
    local y = wp.y + ry * sr * hw + fy * sf * hl
    local z = stallGround(x, y, wp.z) or base
    return vec3(x, y, z + 0.04), vec3(x, y, z + H * 0.45), vec3(x, y, z + H)
  end
  g = { w = w, len = len, h = gh, x = wp.x, y = wp.y, z = wp.z, hx = wp.hx, hy = wp.hy }
  g.bl, g.blM, g.blT = corner(-1, -1)
  g.br, g.brM, g.brT = corner( 1, -1)
  g.fl, g.flM, g.flT = corner(-1,  1)
  g.fr, g.frM, g.frT = corner( 1,  1)
  -- The chevron, sized off the box.
  local cz = base + 0.06
  local tip  = vec3(wp.x + fx * hl * 0.55, wp.y + fy * hl * 0.55, cz)
  local barb = math.min(hw * 0.6, hl * 0.4)
  g.tip   = tip
  g.tail  = vec3(wp.x - fx * hl * 0.45, wp.y - fy * hl * 0.45, cz)
  g.barbL = vec3(tip.x - fx * hl * 0.4 + rx * barb, tip.y - fy * hl * 0.4 + ry * barb, cz)
  g.barbR = vec3(tip.x - fx * hl * 0.4 - rx * barb, tip.y - fy * hl * 0.4 - ry * barb, cz)
  g.label = vec3(wp.x, wp.y, base + H + 0.6)
  -- The retired two-pole marker's points, for paint.pitPoles.
  g.ml  = vec3(wp.x + rx * hw, wp.y + ry * hw, wp.z + 0.05)
  g.mr  = vec3(wp.x - rx * hw, wp.y - ry * hw, wp.z + 0.05)
  g.mlu = vec3(wp.x + rx * hw, wp.y + ry * hw, wp.z + gh)
  g.mru = vec3(wp.x - rx * hw, wp.y - ry * hw, wp.z + gh)
  pitCache[wp] = g
  return g
end

-- The floor alone, one draw. Unused (pitBox draws it); kept for a cheaper far
-- stall.
function paint.pitFloor(wp)
  local g = pitGeometry(wp)
  debugDrawer:drawQuadSolid(g.bl, g.br, g.fr, g.fl, palette().pitFill)
end

-- One stall. `set` is a palette().pitSets entry. `full` (the aimed stall, and
-- every editor stall): two-band walls, stop bar, chevron, 14 draws; else 8.
function paint.pitBox(wp, set, full)
  local g = pitGeometry(wp)
  debugDrawer:drawQuadSolid(g.bl, g.br, g.fr, g.fl, set.fill)
  -- The outline on the ground; the rear edge is the way in.
  debugDrawer:drawCylinder(g.bl, g.br, 0.08, set.line)
  debugDrawer:drawCylinder(g.bl, g.fl, 0.08, set.line)
  debugDrawer:drawCylinder(g.br, g.fr, 0.08, set.line)
  if not full then
    debugDrawer:drawCylinder(g.fl, g.fr, 0.08, set.line)
    debugDrawer:drawQuadSolid(g.bl, g.fl, g.flT, g.blT, set.low)
    debugDrawer:drawQuadSolid(g.br, g.fr, g.frT, g.brT, set.low)
    debugDrawer:drawQuadSolid(g.fl, g.fr, g.frT, g.flT, set.low)
    return
  end
  local p = palette()
  -- The stop bar.
  debugDrawer:drawCylinder(g.fl, g.fr, 0.14, p.pitStop)
  -- Sides and front, fading upward. No rear wall: it would read as a barrier.
  debugDrawer:drawQuadSolid(g.bl,  g.fl,  g.flM, g.blM, set.low)
  debugDrawer:drawQuadSolid(g.blM, g.flM, g.flT, g.blT, set.high)
  debugDrawer:drawQuadSolid(g.br,  g.fr,  g.frM, g.brM, set.low)
  debugDrawer:drawQuadSolid(g.brM, g.frM, g.frT, g.brT, set.high)
  debugDrawer:drawQuadSolid(g.fl,  g.fr,  g.frM, g.flM, set.low)
  debugDrawer:drawQuadSolid(g.flM, g.frM, g.frT, g.flT, set.high)
  debugDrawer:drawCylinder(g.tail, g.tip, 0.07, set.arrow)
  debugDrawer:drawCylinder(g.tip, g.barbL, 0.07, set.arrow)
  debugDrawer:drawCylinder(g.tip, g.barbR, 0.07, set.arrow)
end

-- The two-pole stall marker this replaced. Unused, kept per the fallback rule:
-- it is the version that read at the longest distance, if a lane ever needs it.
function paint.pitPoles(wp, color)
  local g = pitGeometry(wp)
  local r = TUNE.POLE_RADIUS
  debugDrawer:drawCylinder(g.ml, g.mlu, r, color)
  debugDrawer:drawCylinder(g.mr, g.mru, r, color)
  debugDrawer:drawCylinder(g.ml, g.mr, r * 0.6, color)
end

-- `fill` and `glyph` are for the joker and pit entry. An ordinary checkpoint
-- is two bare poles: it is passed at speed and means one thing.
local function drawPoleGate(wp, color, label, fill, glyph)
  local g = gateGeometry(wp)
  local r = TUNE.POLE_RADIUS
  if fill then debugDrawer:drawQuadSolid(g.bl, g.br, g.tr, g.tl, fill) end
  debugDrawer:drawCylinder(g.bl, g.tl, r, color)
  debugDrawer:drawCylinder(g.br, g.tr, r, color)
  if glyph then paint.glyph(g, glyph) end
  if label then
    local p = palette()
    -- On the gate, not above it, where it reads as a nearby sign.
    local at = (glyph == 'pit' and glyphPoints(g).label) or (fill and g.center or g.mid)
    debugDrawer:drawTextAdvanced(at, String(label), p.text, true, false, p.textBg)
  end
end

-- branch.eachAt's callback, built once rather than every frame.
local function poles(g, color) drawPoleGate(g, color, nil) end

local function drawDriverGate(derbyLive)
  if not debugDrawer or not edit.visualize then return end
  if derbyLive or session.spectatorLock then return end
  if #track.route == 0 then return end
  -- Every phase, not only a session: a driver looking over a track wants the
  -- gates too.
  local p = palette()
  local n = #track.route

  -- NO TEXT ON ANY GATE: the poles say where and the color says which. The
  -- joker carries its state as a glyph instead (cross, tick, arrow). The editor
  -- still labels everything. ALL of a checkpoint's gates are drawn: a branch
  -- gate is the driver's choice.
  local a = session.armedWp
  if a < 1 or a > n then a = 1 end
  branch.eachAt(a, poles, p.armed)

  -- The gate after, dimmed. Skipped on a one-gate route, and on the last lap
  -- when the line is armed: the wrap would light CP 1 of a lap nobody drives.
  local lastLap = session.phase == 'racing' and not track.pointToPoint
    and session.totalLaps > 0 and session.localLap >= session.totalLaps
  if n > 1 and not (lastLap and a == n) then
    branch.eachAt(a % n + 1, poles, p.routeNext or p.route)
  end

  -- Markers, all of them, always: there is no "next" sign. The editor pass
  -- draws them with numbers instead.
  if not edit.open then
    for _, wp in ipairs(marker.list) do
      paint.markerPanel(wp, p.markerLine, p.markerFill)
    end
  end

  -- The joker and the pit lane, in the same style.
  if session.jokerEnabled and #track.jokerRoute > 0 then
    local j = session.jokerArmed
    if j < 1 or j > #track.jokerRoute then j = 1 end
    local wp = track.jokerRoute[j]
    if wp then
      local state = session.jokerTaken and 'used'
        or ((sessionRunning() and jokerClosed()) and 'closed' or 'open')
      -- The joker's state changes what a driver must do, so it earns a fill
      -- and a glyph (no label).
      local glyph = (state == 'used' and 'done')
        or (state == 'closed' and 'shut')
        or 'open'
      drawPoleGate(wp, session.jokerTaken and p.jokerUsed or p.joker, nil,
        session.jokerTaken and p.jokerUsedFill or p.jokerFill, glyph)
    end
  end
  -- With an ENTRY GATE only that gate shows while racing; the stalls appear
  -- once in the lane (a hundred draws down to three). A track without one shows
  -- every stall, as before.
  local gated = #track.pitEntry > 0
  if gated and not pit.inLane then
    -- One gate at the mouth: poles, a panel and a big P, no words.
    for _, wp in ipairs(track.pitEntry) do
      drawPoleGate(wp, p.pit, nil, p.pitFill, 'pit')
    end
  elseif #track.pitRoute > 0 then
    local _, ppos = sampledVehicle()
    local best, bestD = 1, math.huge
    if ppos then
      for i, wp in ipairs(track.pitRoute) do
        local dx, dy = wp.x - ppos.x, wp.y - ppos.y
        local d = dx * dx + dy * dy
        if d < bestD then best, bestD = i, d end
      end
    end
    -- Every stall; the nearest in full, GREEN once the car is in it.
    local sets = p.pitSets
    for i, wp in ipairs(track.pitRoute) do
      if i ~= best then paint.pitBox(wp, sets.far, false) end
    end
    local near = track.pitRoute[best]
    if near then
      local inBox = pit.active or (ppos ~= nil and pit.inside(near, ppos))
      paint.pitBox(near, inBox and sets.inbox or sets.near, true)
    end
    -- The way out, drawn only from inside the lane.
    if gated then
      for _, wp in ipairs(track.pitExit) do
        drawPoleGate(wp, p.pitFar, 'PIT OUT', p.pitFill, nil)
      end
    end
  end
end

-- Is this the gate the mouse holds? Only for the list being edited.
local function nudgeSelected(list, i)
  return nudge.on and nudge.sel == i and nudge.list == list
end

local function drawGates(derbyLive)
  if not debugDrawer then return end
  -- The full numbered circuit is the EDITOR's view; a driver gets
  -- drawDriverGate.
  if not (edit.open and session.isAdmin) then
    drawDriverGate(derbyLive)
    return
  end
  if not edit.visualize then return end
  local authoring = true
  -- Which gate is armed, and the joker state, only mean anything in a session.
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
    -- Labeled with its branch count.
    local alts = branch.bySlot[i]
    local label = routeAltLabel(i, n, alts and #alts or 0)
    if nudgeSelected(track.route, i) then color = p.nudged end
    drawGate(wp, color, label, authoring)
  end

  -- Branch gates: cyan, labeled with the CHECKPOINT they serve, and armed green
  -- with it (crossing one clears the slot).
  for gi, g in ipairs(branch.list) do
    local slot = tonumber(g.slot) or 0
    local color = p.branch or p.joker
    if active and slot == session.armedWp then color = p.armed end
    if nudgeSelected(branch.list, gi) then color = p.nudged end
    drawGate(g, color, branchLabel(slot), authoring)
  end

  -- Direction markers, numbered to match the panel's list.
  for i, wp in ipairs(marker.list) do
    local col = nudgeSelected(marker.list, i) and p.nudged or p.markerLine
    paint.markerPanel(wp, col, p.markerFill)
    local g = markerGeometry(wp)
    debugDrawer:drawTextAdvanced(g.label, String(markerLabel(i, wp.kind)),
      p.text, true, false, p.textBg)
  end

  for i, wp in ipairs(track.pitRoute) do
    -- Pit stalls: the same box a driver sees, so the size set is the size got.
    local sets = p.pitSets
    paint.pitBox(wp, nudgeSelected(track.pitRoute, i) and sets.sel or sets.near, true)
    debugDrawer:drawTextAdvanced(pitGeometry(wp).label, String(pitLabel(i)),
      p.text, true, false, p.textBg)
  end

  -- The lane's mouth and exit in the editor too (the driver path hides them
  -- outside the lane, which while editing is always). Labels go through
  -- drawPoleGate: gateGeometry has no label point.
  for i, wp in ipairs(track.pitEntry) do
    local col = nudgeSelected(track.pitEntry, i) and p.nudged or p.pit
    drawPoleGate(wp, col, 'PIT IN ' .. i, p.pitFill, 'pit')
  end
  for i, wp in ipairs(track.pitExit) do
    local col = nudgeSelected(track.pitExit, i) and p.nudged or p.pitFar
    drawPoleGate(wp, col, 'PIT OUT ' .. i, p.pitFill, nil)
  end

  -- Joker route: violet; the next gate green; greyed once used or while shut.
  local jn = #track.jokerRoute
  local state = session.jokerTaken and 'used'
    or ((active and jokerClosed()) and 'closed' or 'open')
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

-- ---------------------------------------------------------------------------
-- What the extension calls
-- ---------------------------------------------------------------------------
R.palette            = palette
R.drawGates          = drawGates
R.drawStartPosition  = drawStartPosition
R.drawStartPositions = drawStartPositions

-- Invalidate the cached gate labels (circuit/sprint changes the last gate's).
function R.invalidateLabels()
  labelCache.route = {}
end

return R
