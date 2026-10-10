-- Race Manager: THE DEMO DERBY, as its own module.
--
-- Last car standing on an arena floor: its own state, events (RM_Derby*) and
-- broadcast channel, sharing nothing of the racing state machine. Moved out of
-- main.lua for Lua's 200-locals ceiling (BeamMP puts each plugin folder on
-- package.path, so main.lua can require a sibling).
--
-- THE CONTRACT: names arrive once through init(host), each a stable table
-- (cleared in place, never replaced) or a plain function. The cup hooks arrive
-- later through setCupHooks; nil means no cup, so their guards are
-- load-bearing. Back out go getDerbyLayouts and two functions the host installs
-- (entryListChanged, underWay); the RM_Derby* handlers are globals, registered
-- by NAME. This module writes no host state.

local D = {}

-- Assigned by init: a value captured at file load would be nil.
local LAYOUTS_DIR, MAX_LAYOUT_NAME, RM_PROTOCOL
local aliasNote, decodeString, displayName
local ensureLayoutsDir, ensureResultsDir, forceSpectate, getCurrentMap
local isEntrant, jsonParse, jsonStringify, onlinePlayers
local releaseSpectators, requireAuth, respawnField, uniqueResultsPath
local requireAdmin
local players, race, sanitizeCheckpoints

-- Set later by setCupHooks. nil is a legitimate state: no cup, no points.
local cupOnDerbyComplete, cupResultsLines

-- Assigned by the moved code below, handed back to the host at the end.
local derbyUnderWay, derbyEntryListChanged

-- Built in init and declared UP HERE: a local declared below init compiles its
-- assignment there as a write to a nil global.
local DERBY_LAYOUTS_FILE
-- One file per map, as the racing layouts; the flat derbyArenas.json is only
-- read to migrate (see getDerbyLayouts).
local DERBY_ARENAS_DIR
local listDirectory, makeDirectory, removeFile

function D.init(h)
  LAYOUTS_DIR, MAX_LAYOUT_NAME, RM_PROTOCOL = h.LAYOUTS_DIR, h.MAX_LAYOUT_NAME, h.RM_PROTOCOL
  aliasNote, decodeString, displayName = h.aliasNote, h.decodeString, h.displayName
  ensureLayoutsDir, ensureResultsDir = h.ensureLayoutsDir, h.ensureResultsDir
  forceSpectate, getCurrentMap = h.forceSpectate, h.getCurrentMap
  isEntrant, jsonParse, jsonStringify = h.isEntrant, h.jsonParse, h.jsonStringify
  onlinePlayers, releaseSpectators = h.onlinePlayers, h.releaseSpectators
  requireAuth, respawnField, uniqueResultsPath = h.requireAuth, h.respawnField, h.uniqueResultsPath
  requireAdmin = h.requireAdmin
  players, race, sanitizeCheckpoints = h.players, h.race, h.sanitizeCheckpoints
  listDirectory, makeDirectory = h.listDirectory, h.makeDirectory
  removeFile = h.removeFile
  DERBY_LAYOUTS_FILE = LAYOUTS_DIR .. '/derbyArenas.json'
  DERBY_ARENAS_DIR   = LAYOUTS_DIR .. '/Derby Arena'
end

-- Not through init: the cup is assigned at the end of main.lua, after init.
function D.setCupHooks(onDerbyComplete, resultsLines)
  cupOnDerbyComplete, cupResultsLines = onDerbyComplete, resultsLines
end

-- ===========================================================================
-- DEMO DERBY
-- ===========================================================================
-- The admin sets the timers and drops boundary markers; Start Derby snapshots
-- the field. Clients police themselves (point-in-polygon and stopped-car
-- detection, where the physics live) and report RM_DerbyDisqualified /
-- RM_DerbyDemolished; the server owns the field, the elimination order, the
-- win and the results file.

local DERBY_DEFAULT_OOB_LIMIT  = 5    -- seconds allowed outside the boundary
local DERBY_DEFAULT_DEMO_LIMIT = 10   -- seconds stopped before demolished
local DERBY_MIN_LIMIT          = 1
local DERBY_MAX_LIMIT          = 120
local DERBY_TICK_MS            = 1000 -- derby clock resolution (1 s is plenty)
local DERBY_MAX_MARKERS        = 64

local DERBY_UNLIMITED_RESETS = -1
local DERBY_MAX_RESET_LIMIT  = 99
local DERBY_MAX_STARTS       = 64

-- Rectangle arenas, as HALF-extents from the center (the sliders show full size).
local DERBY_MIN_EXTENT     = 5    -- meters; full width/length floor is 10 m
local DERBY_MAX_EXTENT     = 250  -- ceiling is 500 m a side
local DERBY_DEFAULT_EXTENT = 60
-- Wall height is VISUAL only: the out-of-bounds test is flat.
local DERBY_MIN_WALL     = 2
local DERBY_MAX_WALL     = 30
local DERBY_DEFAULT_WALL = 6
-- The wall's skirt (0 to 30, default 1.5) is spelled at its two use sites: no
-- locals to spare.

local derby = {
  phase     = 'idle',   -- idle | running | finished
  -- Who is in a derby follows the racing entry list (isEntrant): one opt-in,
  -- only ever read.
  oobLimit  = DERBY_DEFAULT_OOB_LIMIT,
  -- Seconds stopped before a driver is counted out. NO OFF SWITCH: it is the
  -- only thing that detects a wreck (out of bounds needs a car that can still
  -- drive), so without it the field never reduces. 0 clamps to 1. Tried and
  -- reverted once; the idea sounds sensible enough to have again.
  demoLimit = DERBY_DEFAULT_DEMO_LIMIT,
  -- How the derby is scored; both run the same rules (the stopped timer is the
  -- wreck detector):
  --   lms  last man standing: one life, the first stop is out
  --   dm   deathmatch: configurable lives, a stop respawns on the start slot
  -- The server forces lives to 1 in lms, so no client can leave a hidden value.
  mode      = 'lms',
  -- Times a driver may be counted out before they are out for good (1 is the
  -- classic derby). Only the STOPPED timer spends a life: out of bounds is out,
  -- or the boundary would be a free teleport.
  lives     = 1,
  -- Seconds a returning car is intangible (its slot may hold a wreck). A
  -- constant on the config table: no locals to spare.
  respawnGhost = 4.0,
  maxResets = DERBY_UNLIMITED_RESETS,  -- vehicle resets per driver per derby
  time      = 0,        -- seconds since Start Derby (advanced by RM_DerbyTick)
  -- A cool-down between the win and the end, so the wrecks are seen (and a solo
  -- derby, decided at once, can be tested while running).
  endsAt    = nil,      -- derby.time the cool-down finishes at, nil = not won yet
  endReason = nil,
  -- Seconds the arena stays up after the derby is decided. On the table rather
  -- than a file-level constant for the register budget (see ARCHITECTURE.md).
  endDelay  = 5,
  boundary  = {},       -- ordered polygon vertices { x, y, z }
  -- How the polygon was authored; the polygon alone is policed either way:
  --   'polygon'  drive the perimeter, a marker per corner (any shape)
  --   'rect'     a center and slider extents; corners DERIVED from `shape`
  -- Old arenas carry neither and load as 'polygon'.
  boundaryMode = 'polygon',  -- polygon | rect
  shape     = nil,      -- { cx, cy, cz, halfW, halfL, rot } while mode is 'rect'
  wallHeight = DERBY_DEFAULT_WALL,  -- visual only; see the constant above
  wallDepth  = 1.5,                 -- how far it drops below the boundary plane
  startPositions = {},  -- derby starting grid { x, y, z, hx, hy }, slot 1 first
  winner    = nil,      -- winner's name once decided
  -- The saved arena on screen, for the Layouts menu's LOADED tag. Every edit to
  -- the boundary, the grid or the wall clears it: it is no saved arena then.
  arena     = nil,
}
local derbyPlayers = {} -- [pid] = { id, name, status, reason, elimTime, resets }
                        -- status: alive | eliminated | winner
-- More lives than this and nobody is ever knocked out. The countdown has its
-- own value and client event: neither start may release the other's cars.
local DERBY_MAX_LIVES      = 9
local DERBY_COUNTDOWN_FROM = 3
local derbyCountdownValue  = nil

local function broadcastDerbyCountdown(count)
  MP.TriggerClientEvent(-1, 'RM_DerbyCountdown', Util.JsonEncode({ count = count }))
end

-- Active from form-up, not just running: setup is locked for all three phases
-- (the ground must not move under held cars). Gameplay checks stay 'running'.
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

-- The same clamp over any range; a non-number falls back (sliders can be typed).
local function derbyClampNum(n, lo, hi, default)
  n = tonumber(n)
  if not n then return default end
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

-- Radians, wrapped into [0, 2pi): the UI offers 0-90 (a rectangle repeats), the
-- wrap guards a hand-edited file.
local function derbyWrapRot(n, default)
  n = tonumber(n)
  if not n then return default end
  local tau = math.pi * 2
  n = n % tau
  if n < 0 then n = n + tau end
  return n
end

-- The four corners of a rectangle, all at the CENTER's z (the out-of-bounds
-- test ignores z). Anticlockwise from near-left: a ring, never a bowtie.
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

-- Fit an axis-aligned rectangle around a polygon, so switching modes adapts
-- the admin's work.
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

-- Validate a rectangle; `base` fills what the payload omits. nil with no center.
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

-- Drivers in a derby started now: the running field, else by entry mode.
local function derbyEligibleCount()
  if derbyActive() then
    local n = 0
    for _ in pairs(derbyPlayers) do n = n + 1 end
    return n
  end
  local n = 0
  -- onlinePlayers(), not MP.GetPlayers(): the id must match the racing record's
  -- key (a mismatch once emptied the race grid).
  for id in pairs(onlinePlayers()) do
    local rec = players[id]
    if isEntrant(rec) then n = n + 1 end
  end
  return n
end

local function derbyClassification()
  local list = {}
  for _, rec in pairs(derbyPlayers) do
    -- The display name, re-read each time (a stamped one would outlive a
    -- cleared name). With no racing record (a driver who left) the last known
    -- name stays, or the cup would score them against nobody.
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
    -- Decided and cooling down: clients stand their cars down (no extra time).
    derbyOver  = derby.endsAt ~= nil,
    boundary   = derby.boundary,
    -- Which editor, and how tall the walls; `boundary` alone is policed.
    boundaryMode = derby.boundaryMode,
    shape      = derby.shape,
    wallHeight = derby.wallHeight,
    wallDepth  = derby.wallDepth,
    startPositions = derby.startPositions,
    winner     = derby.winner,
    arena      = derby.arena,
    players    = derbyClassification(),
  }))
end

-- Fill the host's forward declarations, here after broadcastDerbyState exists.
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
  -- The cup section, as a race's results file has.
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

-- Every driver gets their car back through the racing side's staggered, ghosted
-- respawn: a derby ends with nearly the whole field removed. In form-up slot
-- order (ascending id).
local function respawnDerbyField()
  local participants = {}
  for _, rec in pairs(derbyPlayers) do
    participants[#participants + 1] = rec
  end
  table.sort(participants, function (a, b) return a.id < b.id end)
  -- The drivers benched for not being ready get their cars back with the rest.
  respawnField('derby', participants, derby.benched)
  derby.benched = {}
end

-- Arm the cool-down rather than ending on the spot. Idempotent: two cars going
-- out together must not push the end away.
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
  -- Cleared HERE, where every ending funnels: an endsAt left set by ending
  -- during the cool-down made the NEXT derby born over (every car stood down,
  -- then demolished by the stopped timer).
  derby.endsAt, derby.endReason = nil, nil
  MP.CancelEventTimer('RM_DerbyTick')
  -- The derby is over: every eliminated driver gets their car and camera back.
  -- Scoped to the 'derby' source so a racing DNF's spectator lock is untouched.
  respawnDerbyField()
  broadcastDerbyState()
  print('[RaceManager] Derby over: ' .. reason)
  -- Score it into the cup (only real derbies reach here). The banked round goes
  -- to the results file: at the round cap, "the current round" is the last one.
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
  -- Forced spectator: the car goes, freecam until the derby ends.
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
  -- An unrecognised mode is ignored: garbage must not change the scoring.
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
  -- LMS is one life, enforced HERE, after the assignment, whatever was sent.
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

-- A rectangle's corners are derived, so marker edits are refused in that mode
-- (the UI hides them; this is the authoritative half).
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
  derby.arena = nil
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby marker %d placed by %s at %.1f, %.1f',
    #derby.boundary, MP.GetPlayerName(pid) or pid, x, y))
end

-- Start over: live in BOTH modes; a cleared rectangle is an empty polygon arena.
function RM_onDerbyClearBoundary(pid)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  derby.boundary = {}
  derby.boundaryMode = 'polygon'
  derby.shape = nil
  derby.arena = nil
  broadcastDerbyState()
  print('[RaceManager] Derby boundary cleared by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Switch editors without losing work: a rectangle becomes four markers, a
-- polygon the rectangle bounding it.
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
    -- Fit to what is placed; with nothing, the client's car is the center.
    local shape = derbyShapeFromBoundary(derby.boundary)
    if not shape then
      local cx, cy, cz = tonumber(data.cx), tonumber(data.cy), tonumber(data.cz)
      if not (cx and cy and cz) then
        print('[RaceManager] Derby rectangle mode needs a center: '
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
  derby.arena = nil
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby boundary mode set to "%s" by %s',
    mode, MP.GetPlayerName(pid) or pid))
end

-- The rectangle editor's one write path; a payload carries any subset (a
-- slider sends what it moved). Wall height applies in either mode.
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
  derby.arena = nil
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
  derby.arena = nil
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby start position %d placed by %s at %.1f, %.1f',
    #derby.startPositions, MP.GetPlayerName(pid) or pid, x, y))
end

function RM_onDerbyClearStarts(pid)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  derby.startPositions = {}
  derby.arena = nil
  broadcastDerbyState()
  print('[RaceManager] Derby start grid cleared by ' .. (MP.GetPlayerName(pid) or pid))
end

-- --- Editing a placed marker / start slot -----------------------------------
-- Move one entry to the admin's car, or drop it and the list closes up. One
-- decoder for all four handlers: the 1-based index and the payload, or nil.
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
  derby.arena = nil
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby marker %d moved by %s to %.1f, %.1f',
    index, MP.GetPlayerName(pid) or pid, x, y))
end

-- Deleting below three is allowed: no polygon (so no save and no policing)
-- until there are three again.
function RM_onDerbyRemoveMarker(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if not derbyMarkersEditable() then return end
  local index = derbyEditRequest(rawData, derby.boundary)
  if not index then return end
  table.remove(derby.boundary, index)
  derby.arena = nil
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
  derby.arena = nil
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
  derby.arena = nil
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
-- An arena: boundary, start grid and timers, saved by name and broadcast on
-- load like a track layout. DERBY_LAYOUTS_FILE is built in init.
local derbyLayouts = nil   -- lazy-loaded array of { name, map, boundary, ... }

-- The arena store, one file per map, shaped like the racing layouts'.
local function derbyFileFor(map)
  local safe = tostring(map or 'unknown'):gsub('[^%w%-_%.]', '_')
  if safe == '' then safe = 'unknown' end
  return DERBY_ARENAS_DIR .. '/' .. safe .. '.json'
end

-- `fallbackMap` is the filename's map, for an entry that names none.
local function readDerbyFile(path, fallbackMap)
  local f = io.open(path, 'r')
  if not f then return {} end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' or type(data.layouts) ~= 'table' then
    print('[RaceManager] Could not parse ' .. path .. ', skipping it')
    return {}
  end
  local out = {}
  for _, l in ipairs(data.layouts) do
    if type(l) == 'table' and type(l.name) == 'string'
        and type(l.boundary) == 'table' and #l.boundary >= 3 then
      if type(l.map) ~= 'string' or l.map == '' then l.map = fallbackMap end
      if type(l.map) == 'string' and l.map ~= '' then out[#out + 1] = l end
    end
  end
  return out
end

-- nil when the folder is missing (MIGRATE). An empty list is a folder emptied
-- on purpose, which must not resurrect the old file.
local function readDerbyFolder()
  local names = listDirectory(DERBY_ARENAS_DIR)
  if #names == 0 then
    local probe = io.open(DERBY_ARENAS_DIR .. '/.rm', 'a')
    if not probe then return nil end
    probe:close()
    removeFile(DERBY_ARENAS_DIR .. '/.rm')
    return {}
  end
  local out = {}
  for _, name in ipairs(names) do
    local base = name:match('^(.*)%.json$')
    if base then
      for _, l in ipairs(readDerbyFile(DERBY_ARENAS_DIR .. '/' .. name, base)) do
        out[#out + 1] = l
      end
    end
  end
  return out
end

-- Forward declared: a save reads the live list through getDerbyLayouts, and the
-- first getDerbyLayouts writes the migrated folder out through a save.
local getDerbyLayouts

local function saveDerbyLayoutsToDisk()
  ensureLayoutsDir()
  makeDirectory(DERBY_ARENAS_DIR)
  local byMap = {}
  for _, l in ipairs(getDerbyLayouts()) do
    local m = l.map or 'unknown'
    if not byMap[m] then byMap[m] = {} end
    table.insert(byMap[m], l)
  end
  local failed = nil
  for map, list in pairs(byMap) do
    local f, ferr = io.open(derbyFileFor(map), 'w')
    if not f then
      failed = failed or tostring(ferr)
    else
      -- v2 added boundaryMode/shape/wallHeight; a v1 entry loads as a polygon.
      f:write(jsonStringify({ version = 2, map = map, layouts = list }))
      f:close()
    end
  end
  -- A map whose last arena was deleted loses its file, or the next boot reads it
  -- and hands the arena back.
  for _, name in ipairs(listDirectory(DERBY_ARENAS_DIR)) do
    local base = name:match('^(.*)%.json$')
    if base then
      local live = false
      for map in pairs(byMap) do
        if derbyFileFor(map) == DERBY_ARENAS_DIR .. '/' .. name then live = true break end
      end
      if not live then removeFile(DERBY_ARENAS_DIR .. '/' .. name) end
    end
  end
  if failed then return false, failed end
  return true
end

getDerbyLayouts = function ()
  if not derbyLayouts then
    local folder = readDerbyFolder()
    if folder then
      derbyLayouts = folder
      print(string.format('[RaceManager] Loaded %d saved derby arena(s) from %s/',
        #derbyLayouts, DERBY_ARENAS_DIR))
    else
      derbyLayouts = readDerbyFile(DERBY_LAYOUTS_FILE, nil)
      print(string.format('[RaceManager] Migrating %d derby arena(s) from %s into %s/',
        #derbyLayouts, DERBY_LAYOUTS_FILE, DERBY_ARENAS_DIR))
      local ok, err = saveDerbyLayoutsToDisk()
      if ok then
        print('[RaceManager] Migration done. ' .. DERBY_LAYOUTS_FILE
          .. ' is kept as a backup and is no longer read.')
      else
        print('[RaceManager] Arena migration FAILED (' .. tostring(err) .. ')')
      end
    end
  end
  return derbyLayouts
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
  -- A rectangle saves BOTH its shape (slider-editable) and its polygon
  -- (loadable by anything).
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
  -- The arena on screen is the one just saved.
  derby.arena = name
  broadcastDerbyState()
end

-- Load a saved arena and push it to every client. Refused during a derby.
function RM_onDerbyLoadLayout(pid, rawData)
  if not requireAuth(pid) then return end
  if derbyActive() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' or type(data.name) ~= 'string' then return end

  local list, map = derbyLayoutsForCurrentMap()
  for _, l in ipairs(list) do
    if l.name:lower() == data.name:lower() then
      -- A COPY: the live arena is edited in place, and a shared table would
      -- rewrite the saved one.
      derby.boundary  = sanitizeBoundary(l.boundary) or {}
      -- A saved rectangle comes back slider-editable, corners re-derived.
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
      derby.arena = l.name
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

-- ADMIN ONLY, as track layouts: nothing puts a deleted arena back.
function RM_onDerbyDeleteLayout(pid, rawData)
  if not requireAdmin(pid) then return end
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


-- Form up: build the field, stand everyone on a slot and HOLD them until the
-- countdown (the derby's Generate Grid).
function RM_onDerbyFormUp(pid)
  if not requireAuth(pid) then return end
  if derby.phase == 'running' or derby.phase == 'countdown' then return end
  derbyPlayers = {}
  derby.winner = nil
  derby.time   = 0
  -- Belt and braces on the leak above: a derby being formed is not a derby that
  -- has been decided, whatever the last one left behind.
  derby.endsAt, derby.endReason = nil, nil
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
        -- Snapshotted: a mid-derby change must not favour the survivors.
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
  derby.benched = {}
  -- THE READY CHECK: with it on, form-up CALLS the field. Every participant
  -- keeps a slot, and their car goes onto it only when they press Ready.
  local called = race.readyCheck == true
  for _, rec in pairs(derbyPlayers) do rec.ready = not called end
  broadcastDerbyState()
  -- Slots go out AFTER the state broadcast, in pid order. A driver with no slot
  -- is still held for GO.
  local ordered = {}
  for id in pairs(derbyPlayers) do ordered[#ordered + 1] = id end
  table.sort(ordered)
  for slot, id in ipairs(ordered) do
    local placed = (slot <= #derby.startPositions) and slot or nil
    -- REMEMBERED: a lost life returns here, and a rebuilt order shifts when
    -- anyone leaves.
    local rec = derbyPlayers[id]
    if rec then rec.slot = placed end
    if not called then
      MP.TriggerClientEvent(id, 'RM_DerbyGridAssign', Util.JsonEncode({
        slot = placed,
        hold = true,
      }))
    end
  end
  MP.SendChatMessage(-1, called
    and string.format('[RaceManager] Demo derby forming up: press Ready in '
      .. 'Phoenix Race Manager (PRM) to take your slot (%d driver%s).', count, count == 1 and '' or 's')
    or string.format('[RaceManager] Demo derby forming up: %d driver%s held for the start.',
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
  -- Whoever is still not ready sits this derby out: stood down with no car,
  -- so nothing loose can drive into the arena, and given it back at the end.
  local ready, out = 0, {}
  for _, rec in pairs(derbyPlayers) do
    if rec.ready == false then out[#out + 1] = rec else ready = ready + 1 end
  end
  if ready == 0 then
    MP.SendChatMessage(pid, '[RaceManager] Nobody is ready yet. Wait for Ready, '
      .. 'or press Ready All to place everyone.')
    return
  end
  if #out > 0 then
    local names = {}
    for _, rec in ipairs(out) do
      derbyPlayers[rec.id] = nil
      derby.benched[#derby.benched + 1] = rec
      names[#names + 1] = displayName(rec)
      forceSpectate(rec.id, 'You were not ready: sitting this derby out', 'derby')
    end
    table.sort(names)
    MP.SendChatMessage(-1, '[RaceManager] Derby starting without '
      .. table.concat(names, ', ') .. ' (not ready).')
    print('[RaceManager] Derby: not ready at the start, benched: ' .. table.concat(names, ', '))
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
  -- Aborting before GO: no result. The countdown broadcast releases the held
  -- cars, so it still goes out.
  if derby.phase == 'forming' or derby.phase == 'countdown' then
    MP.CancelEventTimer('RM_DerbyCountdownTick')
    derbyCountdownValue = nil
    derby.phase  = 'idle'
    derby.winner = nil
    derby.time   = 0
    derbyPlayers = {}
    -- Benched at Start Derby and aborted in the countdown: cars back.
    if derby.benched and #derby.benched > 0 then
      respawnField('derby', {}, derby.benched)
    end
    derby.benched = {}
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

-- The stopped timer expired: spend a life if there is one, else eliminate. Not
-- in derbyEliminate (also the boundary, admin and disconnect paths): a life
-- belongs to this route alone.
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
  -- Back on their start slot through the form-up's placement queue (ghosted
  -- until clear).
  MP.TriggerClientEvent(pid, 'RM_DerbyLifeLost', Util.JsonEncode({
    lives = left,
    slot  = rec.slot,
  }))
  -- ...and EVERY client ghosts it while it lands: elsewhere it would appear
  -- solid, and the weld comes from that side.
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

-- ---------------------------------------------------------------------------
-- Ready check
-- ---------------------------------------------------------------------------
-- With race.readyCheck on, Form Up calls the field (rec.ready = false) and a
-- car goes onto its slot and is held when its driver presses Ready. A lone
-- ready-up lands at once (order 1 of 1); Ready All staggers its batch.
function derby.readyUp(rec, order, count)
  rec.ready = true
  MP.TriggerClientEvent(rec.id, 'RM_DerbyGridAssign', Util.JsonEncode({
    slot = rec.slot, hold = true, order = order or 1, count = count or 1,
  }))
end

function derby.announceIfAllReady()
  local ready, total = 0, 0
  for _, rec in pairs(derbyPlayers) do
    total = total + 1
    if rec.ready ~= false then ready = ready + 1 end
  end
  if total > 0 and ready == total then
    race.tellAdmins(string.format('Everyone is ready for the derby (%d/%d). '
      .. 'Start when you like.', ready, total))
  end
end

-- The driver's own call; an admin may make it for somebody else by naming them.
-- Not ready takes the car off the slot and lets the hold go.
function RM_onDerbyReady(pid, rawData)
  local ok, data = pcall(Util.JsonDecode, (rawData and rawData ~= '') and rawData or '{}')
  if not ok or type(data) ~= 'table' then data = {} end
  local target = pid
  if data.pid ~= nil and tonumber(data.pid) ~= pid then
    if not requireAuth(pid) then return end
    target = tonumber(data.pid)
  end
  local rec = target and derbyPlayers[target]
  if derby.phase ~= 'forming' or not rec then
    broadcastDerbyState(pid)
    return
  end
  if data.ready ~= false and rec.ready == false then
    derby.readyUp(rec)
    print('[RaceManager] Derby: ' .. rec.name .. ' is ready')
    derby.announceIfAllReady()
  elseif data.ready == false and rec.ready == true and race.readyCheck then
    rec.ready = false
    MP.TriggerClientEvent(rec.id, 'RM_DerbyGridAssign', Util.JsonEncode({ release = true }))
    print('[RaceManager] Derby: ' .. rec.name .. ' is not ready any more')
  end
  broadcastDerbyState()
end

function RM_onDerbyReadyAll(pid)
  if not requireAuth(pid) then return end
  if derby.phase ~= 'forming' then return end
  local called = {}
  for _, rec in pairs(derbyPlayers) do
    if rec.ready == false then called[#called + 1] = rec end
  end
  table.sort(called, function (a, b) return (a.slot or math.huge) < (b.slot or math.huge) end)
  for i, rec in ipairs(called) do derby.readyUp(rec, i, #called) end
  print(string.format('[RaceManager] Derby Ready All by %s: %d placed',
    MP.GetPlayerName(pid) or pid, #called))
  broadcastDerbyState()
end

-- Registered as an ADDITIONAL handler on onPlayerJoin/onPlayerDisconnect so
-- the circuit-racing handlers above stay untouched.
function RM_Derby_onPlayerJoin(pid)
  -- Arriving while the field is being called: a place in it and a Ready
  -- button, behind the last slot handed out.
  local rec = players[pid]
  if derby.phase == 'forming' and race.readyCheck and not derbyPlayers[pid]
      and ((not rec) or isEntrant(rec)) then
    local top = 0
    for _, r in pairs(derbyPlayers) do
      if r.slot and r.slot > top then top = r.slot end
    end
    local slot = top + 1
    derbyPlayers[pid] = {
      id = pid, name = MP.GetPlayerName(pid) or ('Player ' .. pid),
      status = 'alive', resets = 0, lives = derby.lives, ready = false,
      slot = (slot <= #derby.startPositions) and slot or nil,
    }
    broadcastDerbyState()
    return
  end
  broadcastDerbyState(pid)  -- late joiners spectate the running derby
end

function RM_Derby_onPlayerDisconnect(pid)
  if derby.phase == 'running' and derbyPlayers[pid]
      and derbyPlayers[pid].status == 'alive' then
    derbyEliminate(pid, 'Disqualified')
  elseif derby.phase == 'forming' and derbyPlayers[pid] then
    -- Gone before the lights: out of the field, not a car-less participant.
    derbyPlayers[pid] = nil
    broadcastDerbyState()
    derby.announceIfAllReady()
  end
end

function RM_DerbyTick()
  if derby.phase ~= 'running' then
    MP.CancelEventTimer('RM_DerbyTick')
    return
  end
  derby.time = derby.time + DERBY_TICK_MS / 1000.0
  -- The cool-down runs out (the only running stretch of a solo derby).
  if derby.endsAt and derby.time >= derby.endsAt then
    -- finishDerby clears these; read the reason out before it does.
    local why = derby.endReason or 'derby over'
    finishDerby(why)
    return
  end
  broadcastDerbyState()
end

-- ---------------------------------------------------------------------------
-- What main.lua takes back
-- ---------------------------------------------------------------------------
-- underWay and entryListChanged are ASSIGNED BY THE HOST into its own state: a
-- write to `race` from here would run at require time, when it is nil.
D.getDerbyLayouts  = getDerbyLayouts
D.entryListChanged = derbyEntryListChanged
D.underWay         = derbyUnderWay

return D
