-- Race Manager: THE DEMO DERBY, as its own module.
--
-- Last-car-standing on an arena floor: its own state tables, its own event
-- names (RM_Derby*), its own broadcast channel, and no share of the circuit
-- racing state machine. It was already written as an isolated section; this
-- makes the isolation structural.
--
-- WHY IT MOVED. main.lua sits against Lua's hard limit of 200 locals in the
-- main chunk, where the next `local` anybody adds stops the plugin compiling
-- and the server starts without it. This region alone accounted for 47 of
-- those slots -- measured by deleting it and compiling, not by counting -- so
-- taking it out moves the file from NINE free slots to fifty-six.
--
-- BeamMP puts each plugin folder on its own package.path, so main.lua can
-- require a sibling. BeamJoyCore on the same server does exactly this, which
-- is how the approach was confirmed rather than assumed.
--
-- THE CONTRACT. Twenty-one names arrive once through init(host), every one of
-- them a stable table or a plain function. No getters: the tables are cleared
-- in place rather than replaced, so a reference taken here at startup is still
-- the right table after any number of session resets.
--
-- Two more arrive later through setCupHooks, and cannot come through init: the
-- cup assigns them at the very end of main.lua, long after this module loads.
-- They are optional by design -- nil means no cup is running -- so the guards
-- around them are load-bearing, not defensive habit.
--
-- WHAT LEAVES THIS FILE is small: getDerbyLayouts, and two functions the host
-- installs into its own state (entryListChanged, underWay). The twenty-seven
-- RM_Derby* handlers stay global and cross the file boundary for free, because
-- BeamMP registers events by NAME -- MP.RegisterEvent('RM_DerbyStart',
-- 'RM_onDerbyStart') resolves the string when the event fires.
--
-- This module writes no host state. It reads, and it draws its own conclusions.

local D = {}

-- Assigned once by init. Declared up here so every function below closes over
-- them; a value captured at file load would be nil, because the host has not
-- called init yet when this chunk runs.
local LAYOUTS_DIR, MAX_LAYOUT_NAME, RM_PROTOCOL
local aliasNote, decodeString, displayName
local ensureLayoutsDir, ensureResultsDir, forceSpectate, getCurrentMap
local isEntrant, jsonParse, jsonStringify, onlinePlayers
local releaseSpectators, requireAuth, respawnField, uniqueResultsPath
local players, race, sanitizeCheckpoints

-- Set later by setCupHooks. nil is a legitimate state: no cup, no points.
local cupOnDerbyComplete, cupResultsLines

-- Assigned by the moved code below, handed back to the host at the end.
local derbyUnderWay, derbyEntryListChanged

-- Built in init from LAYOUTS_DIR, and declared UP HERE for a reason worth
-- keeping. It began as `local DERBY_LAYOUTS_FILE = LAYOUTS_DIR .. ...` beside
-- the code that uses it, which threw on require because LAYOUTS_DIR is nil
-- until init runs. Moving the assignment into init was not enough: the local
-- still sat eight hundred lines BELOW init, so the assignment compiled as a
-- write to a nil global and every read got nil. Lua resolves names at compile
-- time, and a declaration below its use is not a declaration at all.
local DERBY_LAYOUTS_FILE

function D.init(h)
  LAYOUTS_DIR, MAX_LAYOUT_NAME, RM_PROTOCOL = h.LAYOUTS_DIR, h.MAX_LAYOUT_NAME, h.RM_PROTOCOL
  aliasNote, decodeString, displayName = h.aliasNote, h.decodeString, h.displayName
  ensureLayoutsDir, ensureResultsDir = h.ensureLayoutsDir, h.ensureResultsDir
  forceSpectate, getCurrentMap = h.forceSpectate, h.getCurrentMap
  isEntrant, jsonParse, jsonStringify = h.isEntrant, h.jsonParse, h.jsonStringify
  onlinePlayers, releaseSpectators = h.onlinePlayers, h.releaseSpectators
  requireAuth, respawnField, uniqueResultsPath = h.requireAuth, h.respawnField, h.uniqueResultsPath
  players, race, sanitizeCheckpoints = h.players, h.race, h.sanitizeCheckpoints
  DERBY_LAYOUTS_FILE = LAYOUTS_DIR .. '/derbyArenas.json'
end

-- The cup installs itself at the bottom of main.lua, after this module has
-- loaded and been initialised, so these cannot come through init: they would
-- be nil at that point and captured nil forever.
function D.setCupHooks(onDerbyComplete, resultsLines)
  cupOnDerbyComplete, cupResultsLines = onDerbyComplete, resultsLines
end

-- ===========================================================================
-- DEMO DERBY (isolated module)
-- ===========================================================================
-- Completely independent of the circuit racing state machine above: its own
-- state tables, its own event names (RM_Derby*), its own broadcast channel
-- (RM_DerbyUpdate), its own tick timer and its own results file. Nothing in
-- this section reads or writes `race`, `players`, `lapFirsts` or the layout
-- store, so derby sessions can never disturb qualifying/racing and vice versa.
--
-- Flow: admin tunes the two timers and drops boundary markers (clients send
-- their vehicle position via RM_DerbyAddMarker), then Start Derby snapshots
-- every connected player as an active participant. Clients police themselves
-- (point-in-polygon + stopped-vehicle detection happen client-side, where the
-- physics live) and report RM_DerbyDisqualified / RM_DerbyDemolished; the
-- server is authoritative for the participant list, elimination order, the
-- last-man-standing win condition and the results .txt export.

local DERBY_DEFAULT_OOB_LIMIT  = 5    -- seconds allowed outside the boundary
local DERBY_DEFAULT_DEMO_LIMIT = 10   -- seconds stopped before demolished
local DERBY_MIN_LIMIT          = 1
local DERBY_MAX_LIMIT          = 120
local DERBY_TICK_MS            = 1000 -- derby clock resolution (1 s is plenty)
local DERBY_MAX_MARKERS        = 64

local DERBY_UNLIMITED_RESETS = -1
local DERBY_MAX_RESET_LIMIT  = 99
local DERBY_MAX_STARTS       = 64

-- Rectangle arenas. A rectangle is authored from its centre outward, so these
-- are HALF-extents: the sliders show the full width and length, which is what an
-- admin measures an arena in, and the half is what the corner maths wants.
local DERBY_MIN_EXTENT     = 5    -- metres; full width/length floor is 10 m
local DERBY_MAX_EXTENT     = 250  -- ceiling is 500 m a side
local DERBY_DEFAULT_EXTENT = 60
-- Wall height is a VISUAL property of either arena kind, never a gameplay one:
-- the out-of-bounds test is flat (see derbyPointInPolygon on the client), so a
-- wall that reaches higher does not change who is in or out. It exists so a
-- driver can see the edge of the arena from inside a car.
local DERBY_MIN_WALL     = 2
local DERBY_MAX_WALL     = 30
local DERBY_DEFAULT_WALL = 6
-- The wall's SKIRT, how far it drops below the boundary plane, runs 0 to 30 with
-- a default of 1.5. Spelled at its two use sites rather than named here: this
-- file is at Lua's 200-active-locals ceiling and three more names do not fit,
-- and going over does not warn, it stops compiling.

local derby = {
  phase     = 'idle',   -- idle | running | finished
  -- Who is in a derby. 'all' (the default) is the historical behaviour: every
  -- connected session becomes a participant. 'join' honours the same Join Race
  -- opt-in the circuit races use, so somebody who only wants to watch is not
  -- dragged in -- being entered means losing your car to freecam the moment you
  -- are eliminated, which is a poor thing to do to a spectator.
  --
  -- This READS the racing entry list rather than keeping a second one: players
  -- would otherwise have to opt in twice for no benefit. It is a read, so the
  -- derby still never mutates racing state.
  oobLimit  = DERBY_DEFAULT_OOB_LIMIT,
  -- SECONDS STOPPED BEFORE A DRIVER IS COUNTED OUT, and there is deliberately
  -- no way to switch it off.
  --
  -- It was made toggleable once, on the reasonable-sounding grounds that not
  -- every derby wants a stopped-car countdown. That misreads what the timer is
  -- for. It is not a rule laid over the derby, it is the only thing that
  -- DETECTS A WRECK: nothing else in the mod can tell a car that has been
  -- destroyed from one that is parked. With it off, a driver who is finished
  -- simply sits in the arena as a live entrant forever, the field never
  -- reduces, and the derby cannot reach a last man standing at all.
  --
  -- Out of bounds is not a substitute. It only fires on someone driving out,
  -- which a wreck by definition cannot do.
  --
  -- So it clamps to [1, 120] like the out-of-bounds timer, and 0 means one
  -- second rather than never. Reverted within the hour it was built, and the
  -- reason is written here rather than in the history because the idea sounds
  -- sensible enough to have again.
  demoLimit = DERBY_DEFAULT_DEMO_LIMIT,
  -- HOW THE DERBY IS SCORED: 'lms' or 'dm'.
  --
  -- Both run exactly the same rules. The stopped timer and the boundary are
  -- enforced identically, because the stopped timer is the wreck detector and
  -- neither mode works without it (see demoLimit above). The mode decides what
  -- an admin is asked to CONFIGURE, and one rule underneath:
  --
  --   lms  Last man standing. One life: the first time your car stops, you are
  --        out. Lives is not a setting because there is nothing to set.
  --   dm   Deathmatch. Lives are configurable, and a stopped timer spends one
  --        and puts the driver back on their start slot instead of ending them.
  --
  -- Held on the server rather than the UI because it FORCES lives to 1 in lms.
  -- A client that forgot to send lives, or an old one that cannot, must not be
  -- able to leave a three-life value sitting behind a mode that does not show
  -- it -- which would be a derby whose rules do not match its own panel.
  mode      = 'lms',
  -- HOW MANY TIMES A DRIVER MAY BE COUNTED OUT BEFORE THEY ARE OUT FOR GOOD.
  --
  -- 1 is exactly the behaviour that existed before this: the first time the
  -- stopped timer expires, you are eliminated. Set it higher and the timer
  -- expiring spends a life and puts the driver back on their start slot instead,
  -- so a derby becomes a scrap you can come back from rather than one mistake.
  --
  -- Only the STOPPED timer spends a life. Out of bounds is still an outright
  -- elimination: leaving the arena is a choice in a way that being wrecked is
  -- not, and a driver with lives in hand could otherwise use the boundary as a
  -- free teleport back into the middle of the fight.
  lives     = 1,
  -- How long a car coming back on a life is intangible for. Long enough to
  -- land, settle and drive off its own start slot -- which may well have
  -- somebody else's wreck parked on it by the time a life is spent.
  --
  -- A CONSTANT living on the config table, not a setting. It is here rather
  -- than in a local of its own because this chunk sits on Lua's
  -- 200-active-locals ceiling, and one more name does not compile -- the same
  -- reason `progress` is a table. Nothing writes it.
  respawnGhost = 4.0,
  maxResets = DERBY_UNLIMITED_RESETS,  -- vehicle resets per driver per derby
  time      = 0,        -- seconds since Start Derby (advanced by RM_DerbyTick)
  -- A COOL-DOWN between the win condition and the derby actually ending.
  --
  -- The arena is worth a few seconds after the last hit: the wrecks are all
  -- still standing where they were left, and ending on the instant snaps
  -- everyone back out of it before anyone has seen the result.
  --
  -- It also makes a derby TESTABLE ALONE. Solo, the win condition is true the
  -- moment it starts -- one car alive is one car standing -- so the running
  -- phase never lasts long enough to check anything that only applies during
  -- one, like the node grabber being switched off.
  endsAt    = nil,      -- derby.time the cool-down finishes at, nil = not won yet
  endReason = nil,
  -- Seconds the arena stays up after the derby is decided. On the table rather
  -- than a file-level constant for the register budget (see ARCHITECTURE.md).
  endDelay  = 5,
  boundary  = {},       -- ordered polygon vertices { x, y, z }
  -- HOW that polygon was authored. The polygon above stays the single source of
  -- truth for gameplay either way -- every client runs point-in-polygon against
  -- it and nothing else -- so this only decides which editor the admin gets:
  --
  --   'polygon'  drive the perimeter and drop a marker at each corner. Arbitrary
  --              shapes, which is the whole point: a demo arena is rarely a
  --              rectangle, and this is the mode that has always worked.
  --   'rect'     pick a centre and pull the extents out with sliders. Four
  --              corners are DERIVED from `shape` below, so the markers are not
  --              individually editable while this is on.
  --
  -- Old saved arenas carry neither field and load as 'polygon', which is what
  -- they have always been.
  boundaryMode = 'polygon',  -- polygon | rect
  shape     = nil,      -- { cx, cy, cz, halfW, halfL, rot } while mode is 'rect'
  wallHeight = DERBY_DEFAULT_WALL,  -- visual only; see the constant above
  wallDepth  = 1.5,                 -- how far it drops below the boundary plane
  startPositions = {},  -- derby starting grid { x, y, z, hx, hy }, slot 1 first
  winner    = nil,      -- winner's name once decided
}
local derbyPlayers = {} -- [pid] = { id, name, status, reason, elimTime, resets }
                        -- status: alive | eliminated | winner
-- Derby countdown. Its own value and its own client event, deliberately not
-- shared with the racing countdown: the two start procedures are independent
-- and neither may release the other's held cars.
-- A derby of more than this many lives is a derby nobody is ever knocked out of.
local DERBY_MAX_LIVES      = 9
local DERBY_COUNTDOWN_FROM = 3
local derbyCountdownValue  = nil

local function broadcastDerbyCountdown(count)
  MP.TriggerClientEvent(-1, 'RM_DerbyCountdown', Util.JsonEncode({ count = count }))
end

-- A derby is "active" from the moment the field is formed up, not just while it
-- is running. Setup actions -- editing the arena, changing the rules, loading a
-- saved arena -- are locked for all three phases: once cars are standing on
-- their slots and held, the ground must not move under them. Gameplay checks
-- (elimination, reset counting, the tick) stay strictly 'running', because none
-- of that should happen before GO.
local function derbyActive()
  return derby.phase == 'forming'
      or derby.phase == 'countdown'
      or derby.phase == 'running'
end

local function derbyClampLimit(n, default)
  n = tonumber(n)
  if not n then return default end
  if n < DERBY_MIN_LIMIT then return DERBY_MIN_LIMIT end
  if n > DERBY_MAX_LIMIT then return DERBY_MAX_LIMIT end
  return n
end

-- The same clamp against an arbitrary range, for the rectangle's extents and the
-- wall height. A non-number falls back rather than erroring: every one of these
-- arrives off a UI slider that an admin can also type into.
local function derbyClampNum(n, lo, hi, default)
  n = tonumber(n)
  if not n then return default end
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

-- Rotation is stored in radians and wrapped into [0, 2pi). The UI only offers
-- 0-90 degrees because a rectangle repeats every 90 (a quarter turn just swaps
-- width and length), but the wrap is done here so a hand-edited arenas file or a
-- future control cannot feed the corner maths an unbounded angle.
local function derbyWrapRot(n, default)
  n = tonumber(n)
  if not n then return default end
  local tau = math.pi * 2
  n = n % tau
  if n < 0 then n = n + tau end
  return n
end

-- The four corners of a rectangle authored from its centre.
--
-- All four sit at the CENTRE's z. That is deliberate and not a shortcut waiting
-- to be fixed: the out-of-bounds test ignores z entirely, so corner height
-- changes nothing about who is in the arena, and sampling terrain per corner
-- would make the walls agree with the ground on a slope while still enclosing
-- exactly the same footprint. A flat plane is the honest representation of what
-- the rule actually is. On sloped ground the walls are drawn tall enough to
-- intersect the terrain rather than hover over it (see the client's draw code).
--
-- Wound anticlockwise from the near-left corner so consecutive entries are
-- always adjacent -- a ring, never a bowtie, whatever the rotation.
local function derbyShapeToBoundary(shape)
  if type(shape) ~= 'table' then return {} end
  local rot = shape.rot or 0
  local c, s = math.cos(rot), math.sin(rot)
  local hw, hl = shape.halfW, shape.halfL
  local corners = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }
  local out = {}
  for i, sg in ipairs(corners) do
    local ox, oy = sg[1] * hw, sg[2] * hl
    out[i] = {
      x = shape.cx + ox * c - oy * s,
      y = shape.cy + ox * s + oy * c,
      z = shape.cz,
    }
  end
  return out
end

-- Fit a rectangle around an existing polygon, so switching a hand-driven arena
-- to rectangle mode adapts the admin's work instead of discarding it. Axis
-- aligned (rot 0) on purpose: a minimum-area fit could come back at some angle
-- nobody asked for, and the rotation slider is right there.
local function derbyShapeFromBoundary(poly)
  if type(poly) ~= 'table' or #poly < 3 then return nil end
  local minx, maxx = math.huge, -math.huge
  local miny, maxy = math.huge, -math.huge
  local zsum = 0
  for _, m in ipairs(poly) do
    if m.x < minx then minx = m.x end
    if m.x > maxx then maxx = m.x end
    if m.y < miny then miny = m.y end
    if m.y > maxy then maxy = m.y end
    zsum = zsum + m.z
  end
  return {
    cx = (minx + maxx) * 0.5,
    cy = (miny + maxy) * 0.5,
    cz = zsum / #poly,
    halfW = derbyClampNum((maxx - minx) * 0.5,
      DERBY_MIN_EXTENT, DERBY_MAX_EXTENT, DERBY_DEFAULT_EXTENT),
    halfL = derbyClampNum((maxy - miny) * 0.5,
      DERBY_MIN_EXTENT, DERBY_MAX_EXTENT, DERBY_DEFAULT_EXTENT),
    rot = 0,
  }
end

-- Validate a rectangle off the wire (or out of a saved arena). `base` supplies
-- the value for anything the payload leaves out, so a slider can send just the
-- field it changed. Returns nil when there is no centre to work from at all.
local function sanitizeDerbyShape(raw, base)
  if type(raw) ~= 'table' then return nil end
  base = base or {}
  local cx = tonumber(raw.cx) or base.cx
  local cy = tonumber(raw.cy) or base.cy
  local cz = tonumber(raw.cz) or base.cz
  if not (cx and cy and cz) then return nil end
  return {
    cx = cx, cy = cy, cz = cz,
    halfW = derbyClampNum(raw.halfW, DERBY_MIN_EXTENT, DERBY_MAX_EXTENT,
      base.halfW or DERBY_DEFAULT_EXTENT),
    halfL = derbyClampNum(raw.halfL, DERBY_MIN_EXTENT, DERBY_MAX_EXTENT,
      base.halfL or DERBY_DEFAULT_EXTENT),
    rot = derbyWrapRot(raw.rot, base.rot or 0),
  }
end

-- Participants ordered for display/results: winner first, then survivors,
-- then eliminated players latest-out first (2nd place = last one eliminated).
-- How many players would be in a derby started right now. While one is running
-- that is simply the field it started with; otherwise it depends on the entry
-- mode, so the admin can see an empty opt-in list before pressing Start.
local function derbyEligibleCount()
  if derbyActive() then
    local n = 0
    for _ in pairs(derbyPlayers) do n = n + 1 end
    return n
  end
  local n = 0
  -- onlinePlayers() rather than MP.GetPlayers() directly: this reads the racing
  -- entry list by id, and an id that does not compare equal to the key that
  -- record is stored under reads as "has not joined" for every driver on the
  -- server -- the same way it emptied the race grid.
  for id in pairs(onlinePlayers()) do
    local rec = players[id]
    if isEntrant(rec) then n = n + 1 end
  end
  return n
end

local function derbyClassification()
  local list = {}
  for _, rec in pairs(derbyPlayers) do
    -- Carry the display name onto the derby board. Re-read from the racing
    -- record every time rather than merging: a stamped value would go sticky
    -- and a name the admin CLEARED would never disappear from the standings.
    --
    -- Only while there IS a racing record, though. A driver who disconnects
    -- mid-derby has theirs deleted outright (they were 'waiting' as far as the
    -- racing state machine is concerned -- a derby does not put anyone on
    -- track), and nulling the name here would leave the cup scoring their
    -- result against nobody: no binding, no name to match on, so a fresh
    -- placeholder named after their guest name and a season parked on an entry
    -- they can no longer be joined to. The last name we knew is the right
    -- answer for a driver who has left.
    local owner = players[rec.id]
    if owner then rec.alias = owner.alias end
    list[#list + 1] = rec
  end
  table.sort(list, function (a, b)
    local rank = { winner = 0, alive = 1, eliminated = 2 }
    local ra, rb = rank[a.status] or 3, rank[b.status] or 3
    if ra ~= rb then return ra < rb end
    if ra == 2 and a.elimTime ~= b.elimTime then return a.elimTime > b.elimTime end
    return a.id < b.id
  end)
  return list
end

local function broadcastDerbyState(targetPid)
  MP.TriggerClientEvent(targetPid or -1, 'RM_DerbyUpdate', Util.JsonEncode({
    rmProtocol = RM_PROTOCOL,
    derbyPhase = derby.phase,
    -- How many would take part if the derby started right now, so the admin can
    -- see an empty opt-in field before pressing Start rather than after.
    entrants   = derbyEligibleCount(),
    oobLimit   = derby.oobLimit,
    demoLimit  = derby.demoLimit,
    derbyMode  = derby.mode,
    lives      = derby.lives,
    maxResets  = derby.maxResets,
    derbyTime  = derby.time,
    -- The derby is DECIDED and running out its cool-down. Clients stand their
    -- cars down on this: the result is settled, and a wreck still being driven
    -- into people for five seconds afterwards is not a cool-down, it is extra
    -- time nobody was given.
    derbyOver  = derby.endsAt ~= nil,
    boundary   = derby.boundary,
    -- The polygon above is what every client polices against, in both modes.
    -- These three only tell it which editor to show and how tall to draw the
    -- walls; a client too old to know about them reads `boundary` and behaves
    -- exactly as it always has.
    boundaryMode = derby.boundaryMode,
    shape      = derby.shape,
    wallHeight = derby.wallHeight,
    wallDepth  = derby.wallDepth,
    startPositions = derby.startPositions,
    winner     = derby.winner,
    players    = derbyClassification(),
  }))
end

-- Fills the forward declaration made up beside the racing entry list. Has to be
-- assigned down HERE, after broadcastDerbyState exists, or the closure would
-- capture a nil. Only matters outside a running derby: once one is under way
-- the field is fixed and the count is whatever it started with.
derbyUnderWay = function ()
  return derby.phase == 'forming' or derby.phase == 'countdown'
    or derby.phase == 'running'
end

derbyEntryListChanged = function ()
  if not derbyActive() then broadcastDerbyState() end
end

local function derbyFmtTime(t)
  if not t then return '--:--' end
  local m = math.floor(t / 60)
  return string.format('%d:%02d', m, math.floor(t - m * 60))
end

local function buildDerbyResultsText(cupRound)
  local list = derbyClassification()
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  add('==================================================')
  add(' RACE MANAGER - DEMO DERBY RESULTS')
  add(' ' .. os.date('%Y-%m-%d %H:%M:%S'))
  add(string.format(' Duration: %s | Drivers: %d | OOB limit: %gs | Stop limit: %gs',
    derbyFmtTime(derby.time), #list, derby.oobLimit, derby.demoLimit))
  add('==================================================')
  add('')
  -- The resets column only appears when the derby actually limited them.
  local resetCol = derby.maxResets >= 0 and string.format(' %-6s', 'Resets') or ''
  add(string.format('%-5s %-22s %-14s %-13s%s', 'Pos', 'Driver', 'Result', 'Eliminated At', resetCol))
  for i, rec in ipairs(list) do
    local result, elimAt
    if rec.status == 'winner' then
      result, elimAt = 'WINNER', 'survived'
    elseif rec.status == 'alive' then
      result, elimAt = 'Still running', '-'
    else
      result, elimAt = rec.reason or 'Eliminated', derbyFmtTime(rec.elimTime)
    end
    local resetVal = derby.maxResets >= 0
      and string.format(' %-6s', (rec.resets or 0) .. '/' .. derby.maxResets) or ''
    local tag = rec.status == 'winner' and '  << LAST MAN STANDING' or ''
    add(string.format('P%-4d %-22s %-14s %-13s%s%s%s',
      i, displayName(rec), result, elimAt, resetVal, aliasNote(rec), tag))
  end
  if #list == 0 then add('(no drivers)') end
  -- A derby banks a cup round exactly as a race does, so its results file
  -- carries the same section. Same call, same numbers, same layout -- a league
  -- reading two files from one evening should not have to learn two formats.
  local cupLines = cupResultsLines and cupResultsLines(cupRound) or nil
  for _, l in ipairs(cupLines or {}) do add(l) end
  add('')
  return table.concat(lines, '\n') .. '\n'
end

local function writeDerbyResults(cupRound)
  ensureResultsDir()
  local path = uniqueResultsPath('derby_results')
  local f, err = io.open(path, 'w')
  if not f then return false, tostring(err) end
  f:write(buildDerbyResultsText(cupRound))
  f:close()
  return true, path
end

-- Every driver in the derby gets their car back, through the same staggered,
-- ghosted respawn the racing side uses.
--
-- A derby ends with almost the WHOLE field removed -- that is what a derby is,
-- everyone but the last man standing has been eliminated and is watching from
-- freecam -- so it is the heaviest mass respawn in the mod, and it was the one
-- still firing a bare broadcast that put every car back on the same tick. That
-- is exactly the refused-spawn-and-interpenetration case the ordering exists to
-- prevent.
--
-- The field is snapshotted here and handed to respawnField, so the mechanism is
-- shared while the isolation is not broken: this reads derbyPlayers only, never
-- the racing tables. Elimination order is deliberately NOT the spawn order --
-- drivers return to slots handed out by ascending id at form-up, so coming back
-- in that same order puts them back the way they lined up.
local function respawnDerbyField()
  local participants = {}
  for _, rec in pairs(derbyPlayers) do
    participants[#participants + 1] = rec
  end
  table.sort(participants, function (a, b) return a.id < b.id end)
  respawnField('derby', participants)
end

-- Single exit point for every way a derby ends (last man standing, admin
-- ended, everyone eliminated): stop the clock, export results, announce.
-- Arm the cool-down rather than ending on the spot. Idempotent: a second
-- elimination landing inside the window (two cars going out together) must not
-- push the end further away, or a derby could be extended indefinitely by
-- wreckage still settling.
function derby.armEnd(reason)
  if derby.endsAt then return end
  derby.endsAt    = derby.time + derby.endDelay
  derby.endReason = reason
  MP.SendChatMessage(-1, string.format('[RaceManager] %s: derby ends in %d seconds.',
    reason, derby.endDelay))
  print('[RaceManager] Derby decided (' .. reason .. '), ending in '
    .. derby.endDelay .. 's')
  broadcastDerbyState()
end

local function finishDerby(reason)
  derby.phase = 'finished'
  MP.CancelEventTimer('RM_DerbyTick')
  -- The derby is over: every eliminated driver gets their car and camera back.
  -- Scoped to the 'derby' source so a racing DNF's spectator lock is untouched.
  respawnDerbyField()
  broadcastDerbyState()
  print('[RaceManager] Derby over: ' .. reason)
  -- Score it into the cup, if one is running. Only real derbies reach here --
  -- aborting before GO returns out of RM_onDerbyEnd without calling this -- so
  -- a start that never happened can never bank a round.
  --
  -- The classification is handed over rather than the cup coming to fetch it:
  -- this module's tables stay private, and the cup goes on being a consumer of
  -- results exactly as it is for a race. Does nothing unless a cup is running.
  --
  -- The round it banks is carried to the results file, for the same reason the
  -- racing side carries it: a cup at its round cap scores nothing, and a file
  -- that asked for "the current round" would print the last event's points.
  local cupRound = nil
  if cupOnDerbyComplete then
    cupRound = cupOnDerbyComplete(derbyClassification(), { duration = derby.time })
  end
  local ok, wrote, pathOrErr = pcall(writeDerbyResults, cupRound)
  if ok and wrote then
    local msg = derby.winner
      and ('[RaceManager] DEMO DERBY WINNER: ' .. derby.winner .. '! Results saved: ' .. pathOrErr)
      or  ('[RaceManager] Demo derby over (' .. reason .. '). Results saved: ' .. pathOrErr)
    MP.SendChatMessage(-1, msg)
    print('[RaceManager] Derby results written to ' .. pathOrErr)
  else
    print('[RaceManager] Failed to write derby results: ' .. tostring(ok and pathOrErr or wrote))
  end
end

-- Eliminate one participant; when exactly one is left standing the derby ends
-- itself and crowns the survivor.
local function derbyEliminate(pid, reason)
  if derby.phase ~= 'running' then return end
  local rec = derbyPlayers[pid]
  if not rec or rec.status ~= 'alive' then return end  -- duplicate reports are no-ops
  rec.status   = 'eliminated'
  rec.reason   = reason
  rec.elimTime = derby.time
  -- Forced spectator mode (Module 1): an eliminated driver loses their car and
  -- their camera goes to freecam until the derby ends. This only *sends* a
  -- client event - no racing state is read or written, so the isolation of this
  -- module is intact.
  forceSpectate(pid, reason .. ': you are out of this derby', 'derby')
  print(string.format('[RaceManager] Derby: %s eliminated (%s) at %s',
    rec.name, reason, derbyFmtTime(derby.time)))

  local alive, lastAlive = 0, nil
  for _, r in pairs(derbyPlayers) do
    if r.status == 'alive' then alive = alive + 1; lastAlive = r end
  end
  if alive == 1 then
    lastAlive.status = 'winner'
    derby.winner = displayName(lastAlive)
    derby.armEnd('last man standing: ' .. displayName(lastAlive))
  elseif alive == 0 then
    derby.armEnd('no survivors')
  else
    broadcastDerbyState()
  end
end

-- --- Derby event handlers (admin controls relayed by the client bridge) ----

function RM_onDerbySetConfig(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  derby.oobLimit  = derbyClampLimit(data.oobLimit,  derby.oobLimit)
  derby.demoLimit = derbyClampLimit(data.demoLimit, derby.demoLimit)
  -- Mode. Anything unrecognised leaves it alone rather than falling back to a
  -- default: a garbled payload should not quietly change how the night is
  -- scored.
  if data.mode == 'lms' or data.mode == 'dm' then derby.mode = data.mode end
  -- Lives. Floored at 1, because zero would eliminate the whole field on the
  -- first stopped timer and there is no sensible reading of "nought lives".
  local lives = tonumber(data.lives)
  if lives then
    lives = math.floor(lives)
    if lives < 1 then lives = 1 end
    if lives > DERBY_MAX_LIVES then lives = DERBY_MAX_LIVES end
    derby.lives = lives
  end
  -- LMS IS ONE LIFE, ENFORCED HERE AND NOT IN THE PANEL. Applied after the
  -- assignment above so it wins regardless of what the client sent, in either
  -- order, including from a client that does not know about modes at all.
  if derby.mode == 'lms' then derby.lives = 1 end
  -- Reset allowance, mirroring the race rule: negative = unlimited, 0 = none.
  local resets = tonumber(data.maxResets)
  if resets then
    resets = math.floor(resets)
    if resets < 0 then resets = DERBY_UNLIMITED_RESETS
    elseif resets > DERBY_MAX_RESET_LIMIT then resets = DERBY_MAX_RESET_LIMIT end
    derby.maxResets = resets
  end
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby config by %s: %s, OOB %gs, stop %gs, '
    .. 'lives %d, resets %s',
    MP.GetPlayerName(pid) or pid, string.upper(derby.mode), derby.oobLimit,
    derby.demoLimit, derby.lives,
    derby.maxResets < 0 and 'unlimited' or tostring(derby.maxResets)))
end

-- A rectangle's corners are derived from its shape, so the marker tools are
-- refused while that mode is on -- moving one corner of a rectangle is not an
-- operation that has an answer. The UI hides them too; this is the authoritative
-- half, because a stale client must not be able to bend a rectangle into
-- something `shape` no longer describes.
local function derbyMarkersEditable()
  return derby.boundaryMode ~= 'rect'
end

-- Admin dropped a boundary marker at their vehicle's position; the ordered
-- marker list is the arena polygon every client runs point-in-polygon against.
function RM_onDerbyAddMarker(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if not derbyMarkersEditable() then return end
  if #derby.boundary >= DERBY_MAX_MARKERS then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
  if not (x and y and z) then return end
  derby.boundary[#derby.boundary + 1] = { x = x, y = y, z = z }
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby marker %d placed by %s at %.1f, %.1f',
    #derby.boundary, MP.GetPlayerName(pid) or pid, x, y))
end

-- Start over. This is the one boundary control that stays live in BOTH modes:
-- clearing a rectangle drops the arena back to an empty drive-and-place one,
-- which is the state a fresh server boots in. Anything else would leave the
-- button either dead or lying about what it did.
function RM_onDerbyClearBoundary(pid)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  derby.boundary = {}
  derby.boundaryMode = 'polygon'
  derby.shape = nil
  broadcastDerbyState()
  print('[RaceManager] Derby boundary cleared by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Switch between the two arena editors. Neither direction throws the admin's
-- work away, which is the whole reason this is a mode rather than two separate
-- arenas: a rectangle becomes four ordinary markers you can then drag anywhere,
-- and a hand-driven arena becomes the rectangle that bounds it.
function RM_onDerbySetBoundaryMode(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local mode = data.mode
  if mode ~= 'rect' and mode ~= 'polygon' then return end
  if mode == derby.boundaryMode then return end

  if mode == 'polygon' then
    -- The four derived corners stay exactly where they are and simply become
    -- editable, so switching back is an edit and not a reset.
    derby.boundaryMode = 'polygon'
    derby.shape = nil
  else
    -- Fit the rectangle to whatever is already placed. With nothing to fit, the
    -- client sends its own vehicle position as the centre -- the same "stand
    -- where you want it and press the button" gesture every other placement in
    -- this mod uses.
    local shape = derbyShapeFromBoundary(derby.boundary)
    if not shape then
      local cx, cy, cz = tonumber(data.cx), tonumber(data.cy), tonumber(data.cz)
      if not (cx and cy and cz) then
        print('[RaceManager] Derby rectangle mode needs a centre: '
          .. 'nothing placed to fit, and no vehicle position sent')
        return
      end
      shape = { cx = cx, cy = cy, cz = cz,
                halfW = DERBY_DEFAULT_EXTENT, halfL = DERBY_DEFAULT_EXTENT, rot = 0 }
    end
    derby.boundaryMode = 'rect'
    derby.shape = shape
    derby.boundary = derbyShapeToBoundary(shape)
  end
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby boundary mode set to "%s" by %s',
    mode, MP.GetPlayerName(pid) or pid))
end

-- The rectangle editor's one write path: centre, extents, rotation and wall
-- height all arrive here, and a payload may carry any subset of them (a slider
-- sends only what it moved). Wall height is applied in either mode because it is
-- a property of the arena's drawing, not of the rectangle.
function RM_onDerbySetShape(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end

  local changed = false
  if data.wallHeight ~= nil then
    local h = derbyClampNum(data.wallHeight, DERBY_MIN_WALL, DERBY_MAX_WALL, derby.wallHeight)
    if h ~= derby.wallHeight then derby.wallHeight = h; changed = true end
  end
  if data.wallDepth ~= nil then
    local d = derbyClampNum(data.wallDepth, 0, 30, derby.wallDepth)
    if d ~= derby.wallDepth then derby.wallDepth = d; changed = true end
  end

  if derby.boundaryMode == 'rect' then
    local shape = sanitizeDerbyShape(data, derby.shape)
    if shape then
      derby.shape = shape
      derby.boundary = derbyShapeToBoundary(shape)
      changed = true
    end
  end

  if not changed then return end
  broadcastDerbyState()
  if derby.shape then
    print(string.format(
      '[RaceManager] Derby rectangle by %s: %.1f x %.1f m at %.1f, %.1f, %.0f deg, wall %.1f m',
      MP.GetPlayerName(pid) or pid, derby.shape.halfW * 2, derby.shape.halfL * 2,
      derby.shape.cx, derby.shape.cy, math.deg(derby.shape.rot), derby.wallHeight))
  else
    print(string.format('[RaceManager] Derby wall height set to %.1f m by %s',
      derby.wallHeight, MP.GetPlayerName(pid) or pid))
  end
end

-- Admin dropped a derby start position at their vehicle's placement (position
-- + facing). Slot 1 is placed first; Start Derby hands one slot per driver.
function RM_onDerbyAddStart(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if #derby.startPositions >= DERBY_MAX_STARTS then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
  if not (x and y and z) then return end
  derby.startPositions[#derby.startPositions + 1] = {
    x = x, y = y, z = z,
    hx = tonumber(data.hx) or 0, hy = tonumber(data.hy) or 1,
  }
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby start position %d placed by %s at %.1f, %.1f',
    #derby.startPositions, MP.GetPlayerName(pid) or pid, x, y))
end

function RM_onDerbyClearStarts(pid)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  derby.startPositions = {}
  broadcastDerbyState()
  print('[RaceManager] Derby start grid cleared by ' .. (MP.GetPlayerName(pid) or pid))
end

-- --- Editing a placed marker / start slot -----------------------------------
-- Both lists stay editable after placement, the way the race grid's slots do:
-- move one entry to where the admin's car is standing now, or drop it and let
-- the rest of the list close up. Neither is a bulk operation -- every other
-- entry keeps its position and its number.
--
-- One decoder for all four handlers, because all four ask the same question:
-- is this a well-formed request naming an entry that actually exists? Returns
-- the 1-based index and the decoded payload, or nil.
local function derbyEditRequest(rawData, list)
  if type(rawData) ~= 'string' or rawData == '' then return nil end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return nil end
  local index = tonumber(data.index)
  if not index then return nil end
  index = math.floor(index)
  if not list[index] then return nil end
  return index, data
end

function RM_onDerbyMoveMarker(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if not derbyMarkersEditable() then return end
  local index, data = derbyEditRequest(rawData, derby.boundary)
  if not index then return end
  local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
  if not (x and y and z) then return end
  derby.boundary[index] = { x = x, y = y, z = z }
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby marker %d moved by %s to %.1f, %.1f',
    index, MP.GetPlayerName(pid) or pid, x, y))
end

-- Deleting below three markers is allowed: the arena simply stops being a
-- polygon until enough are back, exactly as it is before the third is placed
-- and after Clear Boundary. The minimum is enforced where it matters -- an
-- arena cannot be saved, and out-of-bounds is not policed, without one.
function RM_onDerbyRemoveMarker(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if not derbyMarkersEditable() then return end
  local index = derbyEditRequest(rawData, derby.boundary)
  if not index then return end
  table.remove(derby.boundary, index)
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby marker %d deleted by %s (%d left)',
    index, MP.GetPlayerName(pid) or pid, #derby.boundary))
end

function RM_onDerbyMoveStart(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  local index, data = derbyEditRequest(rawData, derby.startPositions)
  if not index then return end
  local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
  if not (x and y and z) then return end
  derby.startPositions[index] = {
    x = x, y = y, z = z,
    hx = tonumber(data.hx) or 0, hy = tonumber(data.hy) or 1,
  }
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby start position %d moved by %s to %.1f, %.1f',
    index, MP.GetPlayerName(pid) or pid, x, y))
end

function RM_onDerbyRemoveStart(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  local index = derbyEditRequest(rawData, derby.startPositions)
  if not index then return end
  table.remove(derby.startPositions, index)
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby start position %d deleted by %s (%d left)',
    index, MP.GetPlayerName(pid) or pid, #derby.startPositions))
end

-- Client spent one of its derby resets (the client polices the allowance, the
-- server keeps the tally the standings show).
function RM_onDerbyVehicleReset(pid)
  if derby.phase ~= 'running' then return end
  local rec = derbyPlayers[pid]
  if not rec or rec.status ~= 'alive' then return end
  if derby.maxResets >= 0 and (rec.resets or 0) >= derby.maxResets then return end
  rec.resets = (rec.resets or 0) + 1
  print(string.format('[RaceManager] Derby: %s used reset %d/%s',
    rec.name, rec.resets, derby.maxResets < 0 and '∞' or tostring(derby.maxResets)))
  broadcastDerbyState()
end

-- Client blocked a derby reset the driver was no longer entitled to. Logged
-- only - the block itself already happened client-side and costs nothing.
function RM_onDerbyResetDenied(pid)
  if derby.phase ~= 'running' then return end
  local rec = derbyPlayers[pid]
  if not rec then return end
  print(string.format('[RaceManager] Derby: %s reset BLOCKED (allowance %s spent)',
    rec.name, derby.maxResets < 0 and 'unlimited' or tostring(derby.maxResets)))
end

-- ---------------------------------------------------------------------------
-- Derby arena layouts: persistent, per-map, same workflow as track layouts
-- ---------------------------------------------------------------------------
-- An arena is its boundary polygon plus the two timers. Admins build one with
-- the marker tool, save it under a name, and load it back on a later session -
-- loading broadcasts the boundary to every client at once, exactly the way a
-- track layout does. Stored in its own file so the derby module keeps owning
-- its own persistence.
-- DERBY_LAYOUTS_FILE is declared in the header and built in init: it reads
-- LAYOUTS_DIR, which is nil until the host hands it over.
local derbyLayouts = nil   -- lazy-loaded array of { name, map, boundary, ... }

local function loadDerbyLayoutsFromDisk()
  local f = io.open(DERBY_LAYOUTS_FILE, 'r')
  if not f then return {} end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' or type(data.layouts) ~= 'table' then
    print('[RaceManager] Could not parse ' .. DERBY_LAYOUTS_FILE .. ', starting with no arenas')
    return {}
  end
  local out = {}
  for _, l in ipairs(data.layouts) do
    if type(l) == 'table' and type(l.name) == 'string' and type(l.map) == 'string'
        and type(l.boundary) == 'table' and #l.boundary >= 3 then
      out[#out + 1] = l
    end
  end
  return out
end

local function getDerbyLayouts()
  if not derbyLayouts then
    derbyLayouts = loadDerbyLayoutsFromDisk()
    print('[RaceManager] Loaded ' .. #derbyLayouts .. ' saved derby arena(s) from '
      .. DERBY_LAYOUTS_FILE)
  end
  return derbyLayouts
end

local function saveDerbyLayoutsToDisk()
  ensureLayoutsDir()
  local f, ferr = io.open(DERBY_LAYOUTS_FILE, 'w')
  if not f then return false, tostring(ferr) end
  -- version 2 added the optional boundaryMode/shape/wallHeight fields. A v1
  -- entry is still a valid v2 entry -- it simply has none of them and loads as
  -- the drive-and-place arena it always was -- so nothing migrates and an older
  -- plugin reading this file still finds the `boundary` it cares about.
  f:write(jsonStringify({ version = 2, layouts = getDerbyLayouts() }))
  f:close()
  return true
end

-- Boundary markers are plain points; no heading, no dimensions.
local function sanitizeBoundary(raw)
  if type(raw) ~= 'table' then return nil end
  local out = {}
  for i, m in ipairs(raw) do
    if type(m) ~= 'table' then return nil end
    local x, y, z = tonumber(m.x), tonumber(m.y), tonumber(m.z)
    if not (x and y and z) then return nil end
    if i > DERBY_MAX_MARKERS then break end
    out[i] = { x = x, y = y, z = z }
  end
  if #out < 3 then return nil end
  return out
end

local function derbyLayoutsForCurrentMap()
  local map = getCurrentMap()
  local list = {}
  for _, l in ipairs(getDerbyLayouts()) do
    if l.map == map then list[#list + 1] = l end
  end
  table.sort(list, function (a, b) return a.name:lower() < b.name:lower() end)
  return list, map
end

local function sendDerbyLayoutList(targetPid)
  local list, map = derbyLayoutsForCurrentMap()
  MP.TriggerClientEvent(targetPid or -1, 'RM_DerbyLayouts',
    Util.JsonEncode({ map = map, layouts = list }))
  print(string.format('[RaceManager] Sending derby arena list to %s: %d arena(s), map %s',
    targetPid and tostring(targetPid) or 'all', #list, map))
end

function RM_onDerbyRequestLayouts(pid)
  sendDerbyLayoutList(pid)
end

-- Save the current boundary + timers as a named arena for this map. Same name
-- on the same map overwrites, which is the edit workflow.
function RM_onDerbySaveLayout(pid, rawData)
  if not requireAuth(pid) then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    print('[RaceManager] Derby arena save rejected: JSON decode failed')
    return
  end
  local name = type(data.name) == 'string'
    and data.name:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, MAX_LAYOUT_NAME) or ''
  local boundary = sanitizeBoundary(data.boundary)
  if name == '' then
    print('[RaceManager] Derby arena save rejected: missing name')
    return
  end
  if not boundary then
    print('[RaceManager] Derby arena save rejected: needs at least 3 valid markers')
    return
  end

  local resets = tonumber(data.maxResets)
  if resets then
    resets = math.floor(resets)
    if resets < 0 then resets = DERBY_UNLIMITED_RESETS
    elseif resets > DERBY_MAX_RESET_LIMIT then resets = DERBY_MAX_RESET_LIMIT end
  end
  -- A rectangle is saved as BOTH its shape and the polygon derived from it. The
  -- polygon is what makes the entry loadable by anything that has never heard of
  -- a rectangle (including an older plugin); the shape is what makes it editable
  -- with the sliders again instead of coming back as four loose markers.
  local rect = (data.boundaryMode == 'rect') and sanitizeDerbyShape(data.shape) or nil
  local map = getCurrentMap()
  local entry = {
    name      = name,
    map       = map,
    boundary  = boundary,
    boundaryMode = rect and 'rect' or 'polygon',
    shape     = rect,
    wallHeight = derbyClampNum(data.wallHeight, DERBY_MIN_WALL, DERBY_MAX_WALL, derby.wallHeight),
    wallDepth  = derbyClampNum(data.wallDepth, 0, 30, derby.wallDepth),
    oobLimit  = derbyClampLimit(data.oobLimit,  derby.oobLimit),
    demoLimit = derbyClampLimit(data.demoLimit, derby.demoLimit),
    maxResets = resets or derby.maxResets,
    -- Optional starting grid (same placement shape the race grid uses).
    startPositions = sanitizeCheckpoints(data.startPositions),
  }
  local all = getDerbyLayouts()
  local replaced = false
  for i, l in ipairs(all) do
    if l.map == map and l.name:lower() == name:lower() then
      all[i] = entry
      replaced = true
      break
    end
  end
  if not replaced then all[#all + 1] = entry end

  local wrote, werr = saveDerbyLayoutsToDisk()
  if not wrote then
    print('[RaceManager] Failed to write ' .. DERBY_LAYOUTS_FILE .. ': ' .. tostring(werr))
    return
  end
  local msg = string.format('[RaceManager] Derby arena "%s" (%d markers, %s) %s by %s',
    name, #boundary, map, replaced and 'updated' or 'saved', MP.GetPlayerName(pid) or pid)
  MP.SendChatMessage(-1, msg)
  print(msg)
  sendDerbyLayoutList(-1)
end

-- Load a saved arena: adopt its boundary and timers, then push the new derby
-- state to every client so their point-in-polygon test uses the new perimeter.
-- Refused while a derby is running - the arena cannot move under the drivers.
function RM_onDerbyLoadLayout(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' or type(data.name) ~= 'string' then return end

  local list, map = derbyLayoutsForCurrentMap()
  for _, l in ipairs(list) do
    if l.name:lower() == data.name:lower() then
      -- A COPY of the stored polygon, not the stored table itself. The live
      -- arena is edited in place now -- a marker moved or deleted, not just
      -- appended -- and sharing one table with the saved arena would mean
      -- editing the live one silently rewrote the saved one, which the next
      -- write of derbyArenas.json would then make permanent. (startPositions
      -- has always come back from sanitizeCheckpoints as a fresh table; this
      -- is the same guarantee for the boundary.)
      derby.boundary  = sanitizeBoundary(l.boundary) or {}
      -- A saved rectangle comes back as a rectangle, still editable by slider.
      -- Its corners are re-derived from the shape rather than trusted from the
      -- file: the two are written together, and if a hand-edited arenas file has
      -- ever disagreed, the shape is the one the sliders will act on.
      local rect = (l.boundaryMode == 'rect') and sanitizeDerbyShape(l.shape) or nil
      if rect then
        derby.boundaryMode = 'rect'
        derby.shape    = rect
        derby.boundary = derbyShapeToBoundary(rect)
      else
        derby.boundaryMode = 'polygon'
        derby.shape    = nil
      end
      derby.wallHeight = derbyClampNum(l.wallHeight,
        DERBY_MIN_WALL, DERBY_MAX_WALL, DERBY_DEFAULT_WALL)
      derby.oobLimit  = derbyClampLimit(l.oobLimit,  derby.oobLimit)
      derby.demoLimit = derbyClampLimit(l.demoLimit, derby.demoLimit)
      if type(l.maxResets) == 'number' then derby.maxResets = math.floor(l.maxResets) end
      derby.startPositions = sanitizeCheckpoints(l.startPositions) or {}
      broadcastDerbyState()
      local msg = string.format('[RaceManager] Derby arena "%s" loaded on %s by %s (%d markers)',
        l.name, map, MP.GetPlayerName(pid) or pid, #l.boundary)
      MP.SendChatMessage(-1, msg)
      print(msg)
      return
    end
  end
  print(string.format('[RaceManager] Derby arena load failed: no arena "%s" for map %s',
    data.name, map))
end

function RM_onDerbyDeleteLayout(pid, rawData)
  if not requireAuth(pid) then return end
  local name = decodeString(rawData, 'name')
  if not name or name == '' then return end
  local map = getCurrentMap()
  local all = getDerbyLayouts()
  for i, l in ipairs(all) do
    if l.map == map and l.name:lower() == name:lower() then
      table.remove(all, i)
      saveDerbyLayoutsToDisk()
      sendDerbyLayoutList(-1)
      print('[RaceManager] Derby arena "' .. l.name .. '" deleted by '
        .. (MP.GetPlayerName(pid) or pid))
      return
    end
  end
end


-- Form up: build the field, stand everyone on a slot and HOLD them there until
-- the countdown lets go. The derby's Generate Grid, and the same two-step shape
-- the circuit races use - form the grid, then start it.
function RM_onDerbyFormUp(pid)
  if not requireAuth(pid) then return end
  if derby.phase == 'running' or derby.phase == 'countdown' then return end
  derbyPlayers = {}
  derby.winner = nil
  derby.time   = 0
  for id in pairs(onlinePlayers()) do
    -- Same entry rule as a race: everyone takes part unless they are spectating.
    -- A player with no racing record has never pressed anything, so they are in.
    local rec = players[id]
    if (not rec) or isEntrant(rec) then
      derbyPlayers[id] = {
        id       = id,
        name     = MP.GetPlayerName(id) or ('Player ' .. id),
        status   = 'alive',
        reason   = nil,
        elimTime = nil,
        resets   = 0,
        -- Snapshotted at form-up rather than read live, so an admin changing the
        -- setting mid-derby cannot hand the survivors more chances than the
        -- drivers already knocked out got.
        lives    = derby.lives,
      }
    end
  end
  local count = 0
  for _ in pairs(derbyPlayers) do count = count + 1 end
  if count == 0 then
    -- Two different reasons, and telling them apart matters: an empty server is
    -- obvious, an empty entry list looks like a broken button.
    if optIn then
      print('[RaceManager] Derby form-up ignored: nobody has joined (opt-in entry is on)')
      MP.SendChatMessage(pid, '[RaceManager] Nobody has joined: press Join Race, '
        .. 'or switch derby entry to Everyone.')
    else
      print('[RaceManager] Derby form-up ignored: no players connected')
    end
    return
  end
  derby.phase = 'forming'
  releaseSpectators('derby')  -- fresh derby: nobody carries a stale penalty
  broadcastDerbyState()
  -- Slots go out AFTER the state broadcast, so every client already holds the
  -- slot list it is about to be told to use. Join order (pid ascending) is
  -- deterministic and fair enough for a derby. Everyone is held whether or not
  -- a slot was placed for them - a driver with nowhere to line up still waits
  -- for GO rather than getting a free run at the rest of the field.
  local ordered = {}
  for id in pairs(derbyPlayers) do ordered[#ordered + 1] = id end
  table.sort(ordered)
  for slot, id in ipairs(ordered) do
    local placed = (slot <= #derby.startPositions) and slot or nil
    -- REMEMBERED on the record, not recomputed later. Losing a life sends a
    -- driver back to the slot they started from, and rebuilding the order at
    -- that moment would hand them somebody else's slot the first time anybody
    -- disconnected: the list is keyed by pid and shrinks when one leaves.
    local rec = derbyPlayers[id]
    if rec then rec.slot = placed end
    MP.TriggerClientEvent(id, 'RM_DerbyGridAssign', Util.JsonEncode({
      slot = placed,
      hold = true,
    }))
  end
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] Demo derby forming up: %d driver%s held for the start.',
    count, count == 1 and '' or 's'))
  print('[RaceManager] Derby formed up by ' .. (MP.GetPlayerName(pid) or pid)
    .. ' (' .. count .. ' drivers, ' .. #derby.startPositions .. ' slots placed)')
end

function RM_onDerbyStart(pid)
  if not requireAuth(pid) then return end
  -- Form up first, so the field is standing still and held when the lights go
  -- out. Mirrors Start Countdown needing a generated grid.
  if derby.phase ~= 'forming' then
    if derby.phase ~= 'running' and derby.phase ~= 'countdown' then
      MP.SendChatMessage(pid, '[RaceManager] Press Form Up first: it places the '
        .. 'field and holds it for the countdown.')
    end
    return
  end
  derby.phase = 'countdown'
  derbyCountdownValue = DERBY_COUNTDOWN_FROM
  broadcastDerbyState()
  broadcastDerbyCountdown(derbyCountdownValue)
  MP.CreateEventTimer('RM_DerbyCountdownTick', 1000)
  print('[RaceManager] Derby countdown started by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_DerbyCountdownTick()
  if derby.phase ~= 'countdown' then
    MP.CancelEventTimer('RM_DerbyCountdownTick')
    -- Whatever ended the countdown (End Derby) must not leave the field held.
    broadcastDerbyCountdown(-1)
    return
  end
  derbyCountdownValue = derbyCountdownValue - 1
  if derbyCountdownValue > 0 then
    broadcastDerbyCountdown(derbyCountdownValue)
    return
  end
  -- GO! The same broadcast that clears the overlay releases every held car, so
  -- nobody can creep away early or be held a moment longer than their rivals.
  MP.CancelEventTimer('RM_DerbyCountdownTick')
  broadcastDerbyCountdown(0)
  derby.phase = 'running'
  derby.time  = 0
  MP.CreateEventTimer('RM_DerbyTick', DERBY_TICK_MS)
  broadcastDerbyState()
  local count = 0
  for _ in pairs(derbyPlayers) do count = count + 1 end
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] DEMO DERBY STARTED! %d drivers. Stay inside the arena and keep moving!', count))
  print('[RaceManager] Derby GO (' .. count .. ' drivers, '
    .. #derby.boundary .. ' boundary markers)')
end

-- End Derby (admin): if exactly one driver is still alive they take the win,
-- otherwise the derby closes with no winner.
function RM_onDerbyEnd(pid)
  if not requireAuth(pid) then return end
  -- Aborting before GO: no result to record, just put the field back. The
  -- countdown broadcast is what releases the held cars, so it has to go out
  -- even though nobody is racing yet -- otherwise everyone stays frozen.
  if derby.phase == 'forming' or derby.phase == 'countdown' then
    MP.CancelEventTimer('RM_DerbyCountdownTick')
    derbyCountdownValue = nil
    derby.phase  = 'idle'
    derby.winner = nil
    derby.time   = 0
    derbyPlayers = {}
    broadcastDerbyCountdown(-1)
    broadcastDerbyState()
    MP.SendChatMessage(-1, '[RaceManager] Demo derby start aborted.')
    print('[RaceManager] Derby start aborted by ' .. (MP.GetPlayerName(pid) or pid))
    return
  end
  if derby.phase ~= 'running' then
    -- Allow clearing a finished derby back to idle from the UI.
    if derby.phase == 'finished' then
      derby.phase = 'idle'
      derby.winner = nil
      derby.time = 0
      derbyPlayers = {}
      broadcastDerbyState()
      print('[RaceManager] Derby reset to idle by ' .. (MP.GetPlayerName(pid) or pid))
    end
    return
  end
  local alive, lastAlive = 0, nil
  for _, r in pairs(derbyPlayers) do
    if r.status == 'alive' then alive = alive + 1; lastAlive = r end
  end
  if alive == 1 then
    lastAlive.status = 'winner'
    derby.winner = displayName(lastAlive)
  end
  finishDerby('ended by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Client self-reports: out-of-bounds timer expired.
function RM_onDerbyDisqualified(pid)
  derbyEliminate(pid, 'Disqualified')
end

-- Client self-reports: stopped-vehicle timer expired.
-- THE STOPPED TIMER EXPIRED. Spend a life if there is one, and only eliminate
-- when there is not.
--
-- Deliberately not folded into derbyEliminate: that function is the one way a
-- driver leaves a derby and is called from the boundary, the admin and the
-- disconnect paths too. A life belongs to this route alone, so it is spent here.
function RM_onDerbyDemolished(pid)
  if derby.phase ~= 'running' then return end
  local rec = derbyPlayers[pid]
  if not rec or rec.status ~= 'alive' then return end
  local left = (rec.lives or 1) - 1
  if left <= 0 then
    rec.lives = 0
    derbyEliminate(pid, 'Demolished')
    return
  end
  rec.lives = left
  -- Back on the slot they started from. The client puts the car there through
  -- the same placement queue the form-up uses, which ghosts it on the way in and
  -- hands its collisions back once it has settled and the space is clear -- so a
  -- driver cannot be dropped into the middle of a scrum and welded to it.
  MP.TriggerClientEvent(pid, 'RM_DerbyLifeLost', Util.JsonEncode({
    lives = left,
    slot  = rec.slot,
  }))
  -- ...and EVERY client ghosts that car while it lands. The placement queue on
  -- the driver's own machine ghosts their rivals, which keeps them from welding
  -- INTO anybody -- but on every other machine the returning car appears solid,
  -- and that is the side the weld comes from. Broadcast, so both halves hold.
  MP.TriggerClientEvent(-1, 'RM_DerbyGhost', Util.JsonEncode({
    pid     = pid,
    seconds = derby.respawnGhost,
  }))
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] %s was counted out and is back on the grid (%d life%s left).',
    displayName(rec), left, left == 1 and '' or 's'))
  print(string.format('[RaceManager] Derby: %s spent a life (%d left) at %s',
    rec.name, left, derbyFmtTime(derby.time)))
  broadcastDerbyState()
end

function RM_onDerbyRequestState(pid)
  broadcastDerbyState(pid)
end

-- Registered as an ADDITIONAL handler on onPlayerJoin/onPlayerDisconnect so
-- the circuit-racing handlers above stay untouched.
function RM_Derby_onPlayerJoin(pid)
  broadcastDerbyState(pid)  -- late joiners spectate the running derby
end

function RM_Derby_onPlayerDisconnect(pid)
  if derby.phase == 'running' and derbyPlayers[pid]
      and derbyPlayers[pid].status == 'alive' then
    derbyEliminate(pid, 'Disqualified')
  end
end

function RM_DerbyTick()
  if derby.phase ~= 'running' then
    MP.CancelEventTimer('RM_DerbyTick')
    return
  end
  derby.time = derby.time + DERBY_TICK_MS / 1000.0
  -- The cool-down. The derby is already decided; this is the few seconds the
  -- arena stays up so the result can be seen, and the only stretch of a SOLO
  -- derby that is actually running.
  if derby.endsAt and derby.time >= derby.endsAt then
    local why = derby.endReason or 'derby over'
    derby.endsAt, derby.endReason = nil, nil
    finishDerby(why)
    return
  end
  broadcastDerbyState()
end

-- ---------------------------------------------------------------------------
-- What main.lua takes back
-- ---------------------------------------------------------------------------
-- Three names. Everything else above is this module's own business, and the
-- RM_Derby* handlers are already global.
--
-- underWay and entryListChanged are ASSIGNED BY THE HOST into its own state
-- rather than written from here. The host owns `race`; a module that reaches
-- over and sets a field on it is the load-order bug this file was careful to
-- avoid -- and it would fire at require time, when `race` is still nil.
D.getDerbyLayouts  = getDerbyLayouts
D.entryListChanged = derbyEntryListChanged
D.underWay         = derbyUnderWay

return D
