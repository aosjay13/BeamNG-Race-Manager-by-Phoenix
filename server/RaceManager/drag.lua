-- Race Manager: DRAG RACING, as its own module.
--
-- A tournament ladder down a drag strip: its own state, events (RM_Drag*),
-- broadcast channel (RM_DragUpdate), persistence and results, isolated from
-- the racing state machine as the derby is (and for Lua's 200-locals ceiling).
--
-- THE STRIP IS THE LOADED TRACK LAYOUT: a point-to-point layout is driven once,
-- its LAST gate is the finish (the client detects crossings) and its START
-- POSITIONS are the lanes. No strip editor: a two-gate sprint stage with two to
-- eight start positions is a drag strip. This file owns the tournament; the
-- timing arrives from the clients that measured it.
--
-- THE CONTRACT: everything arrives once through init(host), stable tables or
-- plain functions. Back out go warm (boot-time ladder load) and
-- entryListChanged; the RM_Drag* handlers are globals, registered by NAME.

local D = {}

-- Assigned by init: a value captured at file load would be nil.
local LAYOUTS_DIR, RM_PROTOCOL
local displayName, ensureLayoutsDir, ensureResultsDir
local forceSpectate, isEntrant, jsonParse, jsonStringify
local onlinePlayers, releaseSpectators, requireAuth, uniqueResultsPath
local players, race

-- Set later by setCupHooks (the cup is assigned at the end of main.lua); nil
-- means no cup, so the guards are load-bearing.
local cupOnDragComplete, cupResultsLines

-- Built in init, declared up here: a local declared below its use compiles the
-- reads as nil globals.
local DRAG_FILE

function D.setCupHooks(onDragComplete, resultsLines)
  cupOnDragComplete, cupResultsLines = onDragComplete, resultsLines
end

function D.init(h)
  LAYOUTS_DIR, RM_PROTOCOL = h.LAYOUTS_DIR, h.RM_PROTOCOL
  displayName, ensureLayoutsDir = h.displayName, h.ensureLayoutsDir
  ensureResultsDir, forceSpectate = h.ensureResultsDir, h.forceSpectate
  isEntrant, jsonParse, jsonStringify = h.isEntrant, h.jsonParse, h.jsonStringify
  onlinePlayers, releaseSpectators = h.onlinePlayers, h.releaseSpectators
  requireAuth, uniqueResultsPath = h.requireAuth, h.uniqueResultsPath
  players, race = h.players, h.race
  DRAG_FILE = LAYOUTS_DIR .. '/dragLadder.json'
end

-- ===========================================================================
-- Tunables
-- ===========================================================================
local DRAG_MIN_LANES   = 2
local DRAG_MAX_LANES   = 8     -- eight-wide is already twice anything real
local DRAG_MAX_FIELD   = 64
local DRAG_MIN_TIMEOUT = 10    -- seconds a pass may run before the field is DNF'd
local DRAG_MAX_TIMEOUT = 600
local DRAG_TICK_MS     = 250   -- pass clock resolution; the timeout is the only
                               -- thing it drives, so it need not be finer
local DRAG_MAX_ROUNDS  = 32    -- ladder generation is bounded, so a bug is a
                               -- stopped tournament rather than a hung server
local DRAG_MAX_DIAL    = 99.999
local DRAG_MAX_ET      = 999.0 -- anything above this is a client bug, not a pass

-- How a car gets onto the line:
--   hold    on the start position, frozen (an eight-wide shootout)
--   rollup  a few metres BEHIND the line and free: the driver rolls into the
--           beams, which is what makes the stage bulbs mean something
local DRAG_STAGE_MODES = { hold = true, rollup = true }
-- How far behind the start position a rolled-up car is placed. Far enough to
-- creep, short enough that it is not a drive.
local DRAG_ROLLUP_BACK = 5.0
-- The beams, as a signed distance along the start heading (negative is short
-- of the line). Rolling well past drops out again, so an overshoot can back up.
local DRAG_PRESTAGE_AT = -1.2
local DRAG_STAGE_AT    = -0.35
local DRAG_STAGE_PAST  =  2.0
-- The pause before the tree once every lane is staged: the last car gets the
-- same moment to settle that everybody else had.
local DRAG_STAGE_SETTLE = 1.2
-- The tree's SHAPE only: the client runs the lights on its own clock, because a
-- reaction time measured across a network measures the network.
local DRAG_TREE_PATTERNS = { pro = true, sportsman = true }
local DRAG_FORMATS = { single = true, double = true, points = true }
local DRAG_SEEDS   = { random = true, order = true, quali = true, manual = true }

-- ===========================================================================
-- State
-- ===========================================================================
-- Three tables, not thirty locals: `drag` the RULES, `ladder` the TOURNAMENT,
-- `pass` the run in front of you. Only the first two are saved: a pass cut by a
-- restart is run again.

local drag = {
  -- idle      no tournament: the config panel is all there is
  -- ready     a ladder exists and the next pass is waiting to be called
  -- staging   this pass's cars are being placed on their lanes and held
  -- tree      the lights are running
  -- running   the field is on the strip, times are coming in
  -- complete  somebody won it
  phase   = 'idle',
  -- How the ladder narrows:
  --   single   one loss and you are out
  --   double   two losses; the losers go to their own bracket
  --   points   everybody runs every round, scores by position, and the CUT
  --            takes the bottom off between rounds
  format  = 'single',
  -- Cars per pass (two is a drag race, eight a shootout), clamped to the strip's
  -- start positions at build time.
  lanes   = 2,
  -- How many come out of a pass still in. A CEILING: a pass of three cannot
  -- advance four, and the deciding round advances one (passAdvanceCount).
  advance = 1,
  -- Points format: how many are cut from the bottom after each round. 0 runs
  -- everyone to the end (a series night).
  cut     = 0,
  -- points format only: how many rounds it runs. Ignored by the ladders, whose
  -- length is decided by the field.
  rounds  = 3,
  tree    = 'sportsman',
  seed    = 'random',
  -- Roll-up by default: it is what a strip does, and why the stage bulbs exist.
  stageMode = 'rollup',
  -- Rollup: the tree drops by itself once every lane is staged, or an admin
  -- presses Run (a new strip, or rules still being explained). Run is always
  -- available, as the override for a driver who will not stage.
  autoStart = true,
  -- Rollup: how long a pass waits for the field before the tree drops on whoever
  -- is staged. A late car is a result, not a deadlock.
  stageWait = 45,
  -- BRACKET RACING: each entrant declares a DIAL-IN (their expected ET) and the
  -- slower car gets the difference as a head start. Quicker than your dial is a
  -- BREAKOUT, which loses. Off by default: everyone needs a dial.
  dialIn   = false,
  breakout = true,   -- dialIn only: does running under your dial lose the pass?
  timeout  = 60,
  -- Seconds the result stands before the next pass, or the board blinks through
  -- a round.
  holdResult = 8,
}

local ladder = {
  -- Entrants in SEED ORDER, fixed once the ladder is built. Each entry:
  --   id       BeamMP player id, nil once disconnected
  --   name     kept so a disconnected entrant is still on the board
  --   seed     1..n, their place in the draw
  --   wins/losses/passes  their record
  --   status   'in' | 'out' | 'champion' | 'withdrawn'
  --   outRound which round knocked them out, for the finishing order
  --   dial     bracket racing: their declared elapsed time
  --   bestET / bestRT / bestSpeed / lastET / lastRT / lastSpeed
  --   points   points format only: running total
  entrants = {},
  -- Rounds, oldest first:
  --   { n, side = 'w'|'l'|'f', label, passes = { ... }, done }
  --   pass = { lanes = { seedIndex, ... }, bye, done, results = { ... }, winner }
  -- Generated ONE ROUND AT A TIME: losers sides, byes and withdrawals would
  -- make a tree drawn up front wrong by the second round.
  rounds   = {},
  round    = 0,   -- index into rounds; 0 before the first is built
  pass     = 0,   -- index into that round's passes; 0 before the first is called
  champion = nil, -- display name, once there is one
  started  = nil, -- os.time() the ladder was built
  -- The finishing order when the last pass ran, held: entrants leave.
  finishOrder = nil,
}

-- The pass in front of you. Rebuilt whole each time: a stale field is the bug
-- the derby's endsAt note describes.
local pass = { lanes = {}, times = {}, time = 0, greenAt = nil }

-- A PRACTICE PASS: one run that scores nothing (try the strip without a field,
-- find a dial-in). The REAL machinery, on a round NOT in ladder.rounds; only the
-- three places that write a result need to know.
local practice = { on = false, round = nil }

-- The round the current pass belongs to (practice is not in the ladder).
local function activeRound()
  if practice.on then return practice.round end
  return ladder.rounds[ladder.round]
end

-- Assigned by the code below, handed back to the host at the end.
local dragWarm, dragEntryListChanged

-- ===========================================================================
-- Small helpers
-- ===========================================================================
local function clampInt(v, lo, hi, fallback)
  v = tonumber(v)
  if not v then return fallback end
  v = math.floor(v + 0.5)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function clampNum(v, lo, hi, fallback)
  v = tonumber(v)
  if not v then return fallback end
  if v ~= v then return fallback end          -- NaN: a client sent garbage
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Three decimals (the third decides passes). A DNF says so, never a zero.
local function fmtET(t)
  if not t then return '--' end
  return string.format('%.3f', t)
end

local function fmtSpeed(v)
  if not v then return '--' end
  return string.format('%.1f', v)
end

-- A pass on the strip? 'result' counts: config or dial changes would change a
-- pass already run.
local function dragActive()
  return drag.phase == 'staging' or drag.phase == 'tree'
      or drag.phase == 'running' or drag.phase == 'result'
end

-- The lazy seed, as main.lua's random grid draw.
local randomSeeded = false
local function seedOnce()
  if randomSeeded then return end
  math.randomseed(os.time() + os.clock() * 1000)
  randomSeeded = true
end

-- The entrant a player id belongs to, or nil. A linear scan over at most
-- DRAG_MAX_FIELD entries, called on events rather than on a tick.
local function entrantFor(pid)
  for _, e in ipairs(ladder.entrants) do
    if e.id == pid then return e end
  end
  return nil
end

-- Entrants still in the tournament, in seed order. The one question the whole
-- ladder is built from.
local function stillIn()
  local live = {}
  for _, e in ipairs(ladder.entrants) do
    if e.status == 'in' then live[#live + 1] = e end
  end
  return live
end

-- ...and the losers pool, which only double elimination has. An entrant is in
-- it when they have exactly one loss and are still alive.
local function inLosers()
  local live = {}
  for _, e in ipairs(ladder.entrants) do
    if e.status == 'in' and e.losses > 0 then live[#live + 1] = e end
  end
  return live
end

local function undefeated()
  local live = {}
  for _, e in ipairs(ladder.entrants) do
    if e.status == 'in' and e.losses == 0 then live[#live + 1] = e end
  end
  return live
end

-- Lanes the loaded strip has (its saved start positions). race.startPositions
-- is the ONLY host racing state this module reads, and never writes.
local function stripLanes()
  return #(race.startPositions or {})
end

-- Gates on the loaded layout (the last is the finish); a count, so a strip with
-- no finish is refused.
local function stripGates()
  return race.slotCount or 0
end

-- ===========================================================================
-- THE DRAW
-- ===========================================================================
-- Split a seeded field into passes, SERPENTINE (left to right, then back): two
-- lanes give the classic 1v8, 2v7, 3v6, 4v5, eight spread the quick cars, and
-- a bye goes to seed one.
local function serpentine(list, lanes)
  local n = #list
  if n == 0 then return {} end
  local count = math.ceil(n / lanes)
  local passes = {}
  for i = 1, count do passes[i] = {} end
  local i = 1
  while i <= n do
    -- Which way this row runs. Row 1 is left to right, row 2 right to left.
    local row = math.floor((i - 1) / count)
    for k = 1, count do
      if i > n then break end
      local target = (row % 2 == 0) and k or (count - k + 1)
      local t = passes[target]
      t[#t + 1] = list[i]
      i = i + 1
    end
  end
  return passes
end

-- How many come out of this pass: the deciding pass advances one, a bye its
-- entrant, otherwise the admin's number capped so a pass always eliminates.
local function passAdvanceCount(size, isFinal)
  if isFinal then return 1 end
  if size <= 1 then return 1 end
  local n = drag.advance
  if n < 1 then n = 1 end
  if n > size - 1 then n = size - 1 end
  return n
end

-- ===========================================================================
-- RANKING A PASS
-- ===========================================================================
-- FOUR TIERS; no time in a lower tier beats a higher one:
--   1  a clean run
--   2  a BREAKOUT (quicker than your dial): the one who broke out by LESS wins
--   3  a RED LIGHT: still timed, loses to any legal start
--   4  no time at all
-- Inside tiers 1 and 3, who got there first: dial head start + reaction + ET,
-- each measured on one client's clock.
local function passTier(t)
  if not t.et then return 4 end
  if t.foul then return 3 end
  if t.brokeOut then return 2 end
  return 1
end

local function rankPass(times)
  local order = {}
  for i = 1, #times do order[i] = times[i] end
  table.sort(order, function (a, b)
    local ta, tb = passTier(a), passTier(b)
    if ta ~= tb then return ta < tb end
    if ta == 2 then
      -- Both broke out: closest to their own dial wins. breakBy is negative
      -- (they ran under), so the larger number is the smaller mistake.
      local ba, bb = a.breakBy or -math.huge, b.breakBy or -math.huge
      if ba ~= bb then return ba > bb end
    end
    if ta == 4 then
      -- Nobody finished: there is nothing to rank on, so lane order stands and
      -- the sort stays stable rather than inventing an outcome.
      return (a.lane or 0) < (b.lane or 0)
    end
    local fa = a.finishMoment or math.huge
    local fb = b.finishMoment or math.huge
    if fa ~= fb then return fa < fb end
    return (a.lane or 0) < (b.lane or 0)
  end)
  for i, t in ipairs(order) do t.pos = i end
  return order
end

-- ===========================================================================
-- The broadcast
-- ===========================================================================
-- One channel, RM_DragUpdate, carrying the whole board, sent WHOLE (a client
-- that joined or missed a packet cannot ask for a piece; a few dozen rows).
local function entrantRow(e)
  return {
    seed = e.seed, name = e.name, status = e.status,
    wins = e.wins, losses = e.losses, passes = e.passes,
    dial = e.dial, points = e.points, outRound = e.outRound,
    bestET = e.bestET, bestRT = e.bestRT, bestSpeed = e.bestSpeed,
    lastET = e.lastET, lastRT = e.lastRT, lastSpeed = e.lastSpeed,
    -- Present on the server now, so the board shows who is missing.
    online = e.id ~= nil,
    -- The id, so each client can mark its own row in a broadcast to everyone.
    id = e.id,
  }
end

-- `live` is a running pass's times: results are only written when it settles,
-- and the board must show times landing.
local function passRow(p, live)
  local lanes = {}
  for i, e in ipairs(p.lanes) do
    local t = (p.results and p.results[i]) or (live and live[i]) or nil
    lanes[#lanes + 1] = {
      seed = e.seed, name = e.name, lane = i,
      delay = p.delay and p.delay[i] or 0,
      dial  = e.dial,
      rt = t and t.rt, et = t and t.et, speed = t and t.speed,
      foul = t and t.foul or false, brokeOut = t and t.brokeOut or false,
      -- DNF only once settled: mid-pass, no time is a car still driving.
      dnf = (p.results ~= nil) and (t == nil or t.et == nil) or false,
      pos = t and t.pos, through = t and t.through or false,
    }
  end
  return { lanes = lanes, bye = p.bye == true, done = p.done == true,
           winner = p.winner, label = p.label }
end

local function boardRows()
  local out = {}
  for _, r in ipairs(ladder.rounds) do
    local passes = {}
    for _, p in ipairs(r.passes) do passes[#passes + 1] = passRow(p) end
    out[#out + 1] = { n = r.n, side = r.side, label = r.label,
                      done = r.done == true, passes = passes }
  end
  return out
end

-- The current pass for the staging lights: the LIVE fields (staged, run time),
-- dead weight on the ladder rows.
local function livePass()
  local r = activeRound()
  local idx = practice.on and 1 or ladder.pass
  local p = r and r.passes[idx] or nil
  if not p then return nil end
  local row = passRow(p, pass.lanes == p.lanes and pass.times or nil)
  row.round = r.n
  row.roundLabel = r.label
  row.index = idx
  row.count = #r.passes
  row.practice = practice.on or nil
  row.time = pass.time
  for i, lane in ipairs(row.lanes) do
    lane.staged = pass.staged and pass.staged[i] == true
    -- Pre-stage separately: a creeping car shows it before the stage bulb.
    lane.prestaged = pass.prestaged and pass.prestaged[i] == true
    lane.home   = pass.times and pass.times[i] ~= nil
    -- The ready check: false is a driver called and not yet on the strip.
    -- The id lets each client find its own lane for the Ready button.
    lane.id     = p.lanes[i] and p.lanes[i].id or nil
    if pass.ready and pass.lanes == p.lanes then lane.ready = pass.ready[i] end
    -- The red light shows at the launch, not when the pass settles.
    if pass.fouled and pass.fouled[i] and not lane.foul then
      lane.foul = true
      lane.rt   = lane.rt or pass.fouled[i]
    end
  end
  return row
end

-- THE PASS ONLY: a lane report changes one row, up to eight times a pass, and a
-- 64-car ladder is 126 lane rows. `board` and `entrants` are left OUT (the
-- client keeps its copy); the full state goes when the pass settles.
local function broadcastDragPass()
  local r = ladder.rounds[ladder.round]
  MP.TriggerClientEvent(-1, 'RM_DragUpdate', Util.JsonEncode({
    rmProtocol = RM_PROTOCOL,
    dragPhase  = drag.phase,
    round = ladder.round, roundLabel = r and r.label or nil,
    roundSide = r and r.side or nil, roundCount = #ladder.rounds,
    passIndex = ladder.pass, passCount = r and #r.passes or 0,
    practice = practice.on,
    current = livePass(),
  }))
end

local function broadcastDragState()
  local entrants = {}
  for _, e in ipairs(ladder.entrants) do entrants[#entrants + 1] = entrantRow(e) end
  local r = ladder.rounds[ladder.round]
  MP.TriggerClientEvent(-1, 'RM_DragUpdate', Util.JsonEncode({
    rmProtocol = RM_PROTOCOL,
    dragPhase  = drag.phase,
    format = drag.format, lanes = drag.lanes, advance = drag.advance,
    cut = drag.cut, roundLimit = drag.rounds, tree = drag.tree, seed = drag.seed,
    dialIn = drag.dialIn, breakout = drag.breakout, timeout = drag.timeout,
    holdResult = drag.holdResult, stageMode = drag.stageMode,
    autoStart = drag.autoStart, stageWait = drag.stageWait,
    -- What the LOADED TRACK offers, so the panel can say "this strip has four
    -- lanes" instead of letting an admin set eight and find out at staging.
    stripLanes = stripLanes(), stripGates = stripGates(),
    round = ladder.round, roundLabel = r and r.label or nil,
    roundSide = r and r.side or nil, roundCount = #ladder.rounds,
    passIndex = ladder.pass, passCount = r and #r.passes or 0,
    champion = ladder.champion, finishOrder = ladder.finishOrder,
    -- A PRACTICE pass, said plainly: the controls look identical.
    practice = practice.on,
    entrants = entrants, board = boardRows(), current = livePass(),
  }))
end

-- ===========================================================================
-- Persistence
-- ===========================================================================
-- A tournament is an evening: written on every change, as the cup is. The pass
-- in front of you is NOT saved (its cars are no longer staged after a restart).
-- Entrants come back BY NAME (ids are recycled, guest names random); one nobody
-- answers to stays, offline, to withdraw or claim.
local function ladderToDisk()
  local entrants = {}
  for _, e in ipairs(ladder.entrants) do
    entrants[#entrants + 1] = {
      seed = e.seed, name = e.name, alias = e.alias, status = e.status,
      wins = e.wins, losses = e.losses, passes = e.passes,
      dial = e.dial, points = e.points, outRound = e.outRound,
      bestET = e.bestET, bestRT = e.bestRT, bestSpeed = e.bestSpeed,
    }
  end
  local rounds = {}
  for _, r in ipairs(ladder.rounds) do
    local passes = {}
    for _, p in ipairs(r.passes) do
      local seeds, results = {}, {}
      for i, e in ipairs(p.lanes) do
        seeds[i] = e.seed
        local t = p.results and p.results[i]
        if t then
          results[i] = { rt = t.rt, et = t.et, speed = t.speed, foul = t.foul,
                         brokeOut = t.brokeOut, pos = t.pos, through = t.through }
        end
      end
      passes[#passes + 1] = { seeds = seeds, bye = p.bye, done = p.done,
                              winner = p.winner, label = p.label,
                              delay = p.delay,
                              results = p.results and results or nil }
    end
    rounds[#rounds + 1] = { n = r.n, side = r.side, label = r.label,
                            -- or a restored final settles as a plain round
                            final = r.final, done = r.done, passes = passes }
  end
  return {
    config = {
      format = drag.format, lanes = drag.lanes, advance = drag.advance,
      cut = drag.cut, rounds = drag.rounds, tree = drag.tree, seed = drag.seed,
      dialIn = drag.dialIn, breakout = drag.breakout, timeout = drag.timeout,
      holdResult = drag.holdResult, stageMode = drag.stageMode,
      autoStart = drag.autoStart, stageWait = drag.stageWait,
    },
    ladder = {
      entrants = entrants, rounds = rounds,
      round = ladder.round, pass = ladder.pass,
      champion = ladder.champion, started = ladder.started,
      finishOrder = ladder.finishOrder,
      resetPending = ladder.resetPending,
    },
  }
end

local function saveLadder()
  ensureLayoutsDir()
  local f, ferr = io.open(DRAG_FILE, 'w')
  if not f then
    print('[RaceManager] Could not write ' .. DRAG_FILE .. ': ' .. tostring(ferr))
    return false
  end
  f:write(jsonStringify(ladderToDisk()))
  f:close()
  return true
end

-- Rehydrate: seeds on disk become entrant tables; a seed that does not resolve
-- drops its pass rather than putting a nil in a lane.
local function loadLadder()
  local f = io.open(DRAG_FILE, 'r')
  if not f then return end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' then
    print('[RaceManager] Could not parse ' .. DRAG_FILE .. ', starting with no ladder')
    return
  end
  local cfg = type(data.config) == 'table' and data.config or {}
  if DRAG_FORMATS[cfg.format] then drag.format = cfg.format end
  if DRAG_TREE_PATTERNS[cfg.tree] then drag.tree = cfg.tree end
  if DRAG_STAGE_MODES[cfg.stageMode] then drag.stageMode = cfg.stageMode end
  if type(cfg.autoStart) == 'boolean' then drag.autoStart = cfg.autoStart end
  drag.stageWait = clampInt(cfg.stageWait, 5, 300, drag.stageWait)
  if DRAG_SEEDS[cfg.seed] then drag.seed = cfg.seed end
  drag.lanes   = clampInt(cfg.lanes,   DRAG_MIN_LANES, DRAG_MAX_LANES, drag.lanes)
  drag.advance = clampInt(cfg.advance, 1, DRAG_MAX_LANES - 1, drag.advance)
  drag.cut     = clampInt(cfg.cut,     0, DRAG_MAX_FIELD, drag.cut)
  drag.rounds  = clampInt(cfg.rounds,  1, DRAG_MAX_ROUNDS, drag.rounds)
  drag.timeout = clampInt(cfg.timeout, DRAG_MIN_TIMEOUT, DRAG_MAX_TIMEOUT, drag.timeout)
  drag.holdResult = clampInt(cfg.holdResult, 0, 60, drag.holdResult)
  drag.dialIn   = cfg.dialIn == true
  drag.breakout = cfg.breakout ~= false

  local saved = type(data.ladder) == 'table' and data.ladder or {}
  if type(saved.entrants) ~= 'table' or #saved.entrants == 0 then return end
  local bySeed = {}
  for _, row in ipairs(saved.entrants) do
    if type(row) == 'table' and type(row.name) == 'string' then
      local e = {
        id = nil, seed = clampInt(row.seed, 1, DRAG_MAX_FIELD, #ladder.entrants + 1),
        name = row.name, status = row.status or 'in',
        wins = clampInt(row.wins, 0, 999, 0), losses = clampInt(row.losses, 0, 999, 0),
        passes = clampInt(row.passes, 0, 999, 0),
        points = clampInt(row.points, 0, 99999, 0),
        outRound = tonumber(row.outRound),
        alias = type(row.alias) == 'string' and row.alias or nil,
        dial = tonumber(row.dial), bestET = tonumber(row.bestET),
        bestRT = tonumber(row.bestRT), bestSpeed = tonumber(row.bestSpeed),
      }
      ladder.entrants[#ladder.entrants + 1] = e
      bySeed[e.seed] = e
    end
  end
  table.sort(ladder.entrants, function (a, b) return a.seed < b.seed end)
  for _, r in ipairs(type(saved.rounds) == 'table' and saved.rounds or {}) do
    if type(r) == 'table' and type(r.passes) == 'table' then
      local passes = {}
      for _, p in ipairs(r.passes) do
        local lanes, okPass = {}, true
        for _, s in ipairs(type(p.seeds) == 'table' and p.seeds or {}) do
          local e = bySeed[s]
          if not e then okPass = false; break end
          lanes[#lanes + 1] = e
        end
        if okPass and #lanes > 0 then
          passes[#passes + 1] = { lanes = lanes, bye = p.bye == true,
                                  done = p.done == true, winner = p.winner,
                                  label = p.label, delay = p.delay,
                                  results = p.results }
        end
      end
      ladder.rounds[#ladder.rounds + 1] = {
        n = tonumber(r.n) or (#ladder.rounds + 1),
        side = r.side or 'w', label = r.label or ('Round ' .. (#ladder.rounds + 1)),
        final = r.final == true, done = r.done == true, passes = passes }
    end
  end
  ladder.round    = clampInt(saved.round, 0, #ladder.rounds, 0)
  ladder.pass     = clampInt(saved.pass,  0, DRAG_MAX_FIELD, 0)
  ladder.champion = saved.champion
  ladder.started  = tonumber(saved.started)
  ladder.finishOrder = type(saved.finishOrder) == 'table' and saved.finishOrder or nil
  ladder.resetPending = saved.resetPending == true
  -- A ladder always comes back AT REST. Whatever was staged or running when the
  -- server went down went down with it, and the pass is re-called by hand.
  drag.phase = ladder.champion and 'complete' or 'ready'
  print(string.format('[RaceManager] Drag ladder restored: %d entrant(s), %d round(s), %s',
    #ladder.entrants, #ladder.rounds, ladder.champion
      and ('won by ' .. ladder.champion) or 'in progress'))
end

-- Boot-time load, called from the host once the filesystem helpers exist.
dragWarm = function ()
  loadLadder()
  -- Re-bind online entrants by name (only matters after a plugin reload).
  if #ladder.entrants > 0 then dragEntryListChanged() end
end

-- ===========================================================================
-- THE LADDER
-- ===========================================================================
-- Pure bookkeeping over the entrant list, one round at a time: no car, client
-- or timer, so tests/drag_test.lua runs a whole ladder headless.

-- Does the remaining field fit one pass? Asked of the FIELD, so it holds in
-- every format.
local function isFinalField(live)
  return #live <= drag.lanes
end

local function roundLabel(side, live, final)
  -- Side 'f' is where the brackets meet: the final, and the reset (renamed by
  -- its caller).
  if side == 'f' then return 'Final' end
  local n = #ladder.rounds + 1
  if drag.format == 'points' then
    return 'Round ' .. n .. ' of ' .. drag.rounds
  end
  if side == 'l' then
    return final and 'Losers Final' or ('Losers Round ' .. n)
  end
  if final then return 'Final' end
  -- In a double, halving the winners bracket is not a semifinal: the losers
  -- side still feeds one in.
  if drag.format == 'double' then return 'Winners Round ' .. n end
  -- A semifinal is what a round produces (its survivors fit one pass), not a
  -- round number.
  local groups = serpentine(live, drag.lanes)
  local through = 0
  for _, g in ipairs(groups) do
    through = through + (#g == 1 and 1 or passAdvanceCount(#g, false))
  end
  if through <= drag.lanes then return 'Semifinal' end
  return 'Round ' .. n
end

-- Add a round to the ladder from an already-drawn set of groups.
local function pushRound(side, groups, final, live)
  local r = { n = #ladder.rounds + 1, side = side, done = false, passes = {},
              final = final == true, label = roundLabel(side, live or {}, final) }
  for _, g in ipairs(groups) do
    r.passes[#r.passes + 1] = {
      lanes = g,
      -- A bye is a pass: staged, run and timed, it just cannot be lost.
      bye = #g == 1, done = false, results = nil, delay = nil,
    }
  end
  ladder.rounds[#ladder.rounds + 1] = r
  ladder.round = #ladder.rounds
  -- At the first pass, so a fresh round shows who is up next.
  ladder.pass  = 1
  return r
end

-- Seed order for the ladders; points draws on the standings.
local function drawOrder(pool)
  local list = {}
  for i, e in ipairs(pool) do list[i] = e end
  if drag.format == 'points' then
    table.sort(list, function (a, b)
      if a.points ~= b.points then return a.points > b.points end
      return a.seed < b.seed
    end)
  else
    table.sort(list, function (a, b) return a.seed < b.seed end)
  end
  return list
end

local finishTournament   -- assigned below; buildNextRound is its other caller

-- Build the round that comes next, or end the tournament because there is no
-- such round. Returns true when a round was built.
local function buildNextRound()
  if #ladder.rounds >= DRAG_MAX_ROUNDS then
    finishTournament('round limit reached')
    return false
  end
  local live = stillIn()
  if #live == 0 then finishTournament('no entrants left'); return false end
  if #live == 1 and drag.format ~= 'points' then
    finishTournament('won by ' .. live[1].name)
    return false
  end

  if drag.format == 'points' then
    -- Every entrant runs every round; the CUT between rounds is what narrows
    -- the field, and a night with no cut ranks the whole board on points.
    if #ladder.rounds >= drag.rounds or #live == 1 then
      finishTournament('all rounds run')
      return false
    end
    pushRound('w', serpentine(drawOrder(live), drag.lanes), false, live)
    return true
  end

  if drag.format == 'double' then
    -- The reset: the undefeated finalist lost, so the two go again.
    if ladder.resetPending then
      ladder.resetPending = false
      pushRound('f', { drawOrder(live) }, true, live).label = 'Final (reset)'
      return true
    end
    local won, lost = undefeated(), inLosers()
    -- The final needs both brackets down to one pass.
    if isFinalField(live) and #won <= 1 then
      pushRound('f', { drawOrder(live) }, true, live)
      return true
    end
    -- Alternate the sides so the losers bracket does not pile up; a side that
    -- cannot run hands the round over.
    local lastSide = ladder.rounds[#ladder.rounds] and ladder.rounds[#ladder.rounds].side
    local wantLosers = (lastSide == 'w') and #lost >= 2
    if not wantLosers and #won < 2 then wantLosers = #lost >= 2 end
    if wantLosers then
      pushRound('l', serpentine(drawOrder(lost), drag.lanes), false, lost)
      return true
    end
    if #won >= 2 then
      pushRound('w', serpentine(drawOrder(won), drag.lanes), false, won)
      return true
    end
    -- Reachable only through withdrawals: finished, not stuck.
    finishTournament('no pass can be drawn')
    return false
  end

  -- Single elimination.
  local final = isFinalField(live)
  pushRound('w', serpentine(drawOrder(live), drag.lanes), final, live)
  return true
end

-- ===========================================================================
-- Settling a pass
-- ===========================================================================
-- Knocked out does not cost your car (a ladder runs an hour, unlike a derby):
-- you are simply not called again. stagePass stands the others down while a
-- pass is on the strip.
local function eliminate(e, roundIndex, reason)
  e.status   = 'out'
  e.outRound = roundIndex
  if e.id then
    MP.SendChatMessage(e.id, '[RaceManager] ' .. (reason or 'Knocked out of the drag ladder')
      .. '. Your car is your own again; you will not be called for another pass.')
  end
end

local function applyResult(p, r, isFinal)
  local ranked = rankPass(p.results)
  -- A practice pass is ranked and then forgotten: no win, loss, elimination or
  -- best number reaches any record.
  if practice.on then
    p.winner = ranked[1] and ranked[1].entrant.name or nil
    for _, t in ipairs(ranked) do t.through = false end
    p.done = true
    return
  end
  local through = p.bye and 1 or passAdvanceCount(#p.lanes, isFinal)
  local winner = ranked[1]
  p.winner = winner and winner.entrant.name or nil
  for i, t in ipairs(ranked) do
    local e = t.entrant
    e.passes  = e.passes + 1
    e.lastET, e.lastRT, e.lastSpeed = t.et, t.rt, t.speed
    -- Best-EVER; a red light still ran its ET.
    if t.et and (not e.bestET or t.et < e.bestET) then e.bestET = t.et end
    if t.rt and t.rt > 0 and (not e.bestRT or t.rt < e.bestRT) then e.bestRT = t.rt end
    if t.speed and (not e.bestSpeed or t.speed > e.bestSpeed) then e.bestSpeed = t.speed end
    if i == 1 then e.wins = e.wins + 1 end
    if drag.format == 'points' then
      -- On the CONFIGURED lane count, so a thin pass is worth a full one.
      local pts = drag.lanes - i + 1
      if pts < 0 then pts = 0 end
      e.points = e.points + pts
      t.through = true
    elseif i <= through then
      t.through = true
    else
      t.through = false
      e.losses  = e.losses + 1
      local limit = (drag.format == 'double') and 2 or 1
      -- A final eliminates every loser, except (double) one who arrived
      -- undefeated: they get the reset.
      if isFinal and e.losses < limit then
        ladder.resetPending = true
      elseif isFinal or e.losses >= limit then
        eliminate(e, r.n, 'Knocked out in ' .. r.label)
      end
    end
  end
  p.done = true
end

-- Points format: the bottom of the board goes home.
local function applyCut(r)
  if drag.cut <= 0 then return end
  local live = stillIn()
  if #live <= 1 then return end
  table.sort(live, function (a, b)
    if a.points ~= b.points then return a.points > b.points end
    -- Level on points is broken by the best ET anybody ran, then by seed, so a
    -- cut is never decided by table order.
    local ea, eb = a.bestET or math.huge, b.bestET or math.huge
    if ea ~= eb then return ea < eb end
    return a.seed < b.seed
  end)
  -- Never cut the whole field: one entrant has to survive to be ranked first.
  local n = drag.cut
  if n > #live - 1 then n = #live - 1 end
  for i = #live - n + 1, #live do
    eliminate(live[i], r.n, 'Cut after ' .. r.label)
  end
end

-- ===========================================================================
-- The finishing order
-- ===========================================================================
-- The WHOLE finishing order: still in, then the later knockout, passes won,
-- seed (points: points first). One sort for the results file and the cup.
local function finishOrderList()
  local list = {}
  for _, e in ipairs(ladder.entrants) do
    if e.status ~= 'withdrawn' then list[#list + 1] = e end
  end
  if drag.format == 'points' then
    table.sort(list, function (a, b)
      if a.points ~= b.points then return a.points > b.points end
      local ea, eb = a.bestET or math.huge, b.bestET or math.huge
      if ea ~= eb then return ea < eb end
      return a.seed < b.seed
    end)
  else
    table.sort(list, function (a, b)
      local ao = a.status == 'out' and (a.outRound or 0) or math.huge
      local bo = b.status == 'out' and (b.outRound or 0) or math.huge
      if ao ~= bo then return ao > bo end
      if a.wins ~= b.wins then return a.wins > b.wins end
      local ea, eb = a.bestET or math.huge, b.bestET or math.huge
      if ea ~= eb then return ea < eb end
      return a.seed < b.seed
    end)
  end
  return list
end

local function buildFinishOrder()
  local out = {}
  for i, e in ipairs(finishOrderList()) do
    out[i] = { pos = i, name = e.name, seed = e.seed, wins = e.wins,
               losses = e.losses, passes = e.passes, points = e.points,
               bestET = e.bestET, bestRT = e.bestRT, bestSpeed = e.bestSpeed,
               outRound = e.outRound }
  end
  return out
end

-- What the cup is handed: entrants in finishing order, the alias re-read live
-- (as the derby does); a departed driver keeps the last one known.
local function dragClassification()
  local list = finishOrderList()
  for _, e in ipairs(list) do
    local owner = e.id and players[e.id] or nil
    if owner then e.alias = owner.alias end
  end
  return list
end

-- The meeting's quickest pass and its driver. A red light still counts.
local function lowETEntrant()
  local best = nil
  for _, e in ipairs(ladder.entrants) do
    if e.bestET and (not best or e.bestET < best.bestET) then best = e end
  end
  return best
end

local function writeResults(cupRound)
  ensureResultsDir()
  local path = uniqueResultsPath('drag_results')
  local f, ferr = io.open(path, 'w')
  if not f then return false, tostring(ferr) end
  local FORMAT_NAME = { single = 'Single elimination', double = 'Double elimination',
                        points = 'Points shootout' }
  f:write('RACE MANAGER - DRAG TOURNAMENT\n')
  f:write(os.date('%Y-%m-%d %H:%M:%S') .. '\n')
  f:write(string.rep('=', 72) .. '\n\n')
  f:write('Format      : ' .. (FORMAT_NAME[drag.format] or drag.format) .. '\n')
  f:write('Lanes       : ' .. drag.lanes .. ' per pass\n')
  if drag.format == 'points' then
    f:write('Cut         : ' .. (drag.cut > 0 and (drag.cut .. ' per round') or 'none') .. '\n')
  else
    f:write('Advancing   : ' .. drag.advance .. ' per pass\n')
  end
  f:write('Tree        : ' .. drag.tree .. '\n')
  f:write('Dial-in     : ' .. (drag.dialIn
    and ('on' .. (drag.breakout and ' (breakout loses)' or ' (no breakout rule)')) or 'off') .. '\n')
  f:write('Entrants    : ' .. #ladder.entrants .. '\n')
  if ladder.champion then f:write('WINNER      : ' .. ladder.champion .. '\n') end
  f:write('\n' .. string.rep('-', 72) .. '\nFINAL ORDER\n' .. string.rep('-', 72) .. '\n')
  f:write(string.format('%-4s %-22s %-5s %-5s %-8s %-7s %-7s\n',
    'Pos', 'Driver', 'Seed', 'W-L', 'Best ET', 'Best RT', 'Best MPH'))
  for _, row in ipairs(ladder.finishOrder or {}) do
    f:write(string.format('%-4d %-22s %-5d %-5s %-8s %-7s %-7s\n',
      row.pos, row.name:sub(1, 22), row.seed,
      row.wins .. '-' .. row.losses,
      fmtET(row.bestET), fmtET(row.bestRT), fmtSpeed(row.bestSpeed)))
  end
  f:write('\n' .. string.rep('-', 72) .. '\nTHE LADDER\n' .. string.rep('-', 72) .. '\n')
  for _, r in ipairs(ladder.rounds) do
    f:write('\n' .. r.label .. '\n')
    for pi, p in ipairs(r.passes) do
      f:write(string.format('  Pass %d%s\n', pi, p.bye and '  (bye run)' or ''))
      local ranked = {}
      for i, e in ipairs(p.lanes) do
        ranked[#ranked + 1] = { e = e, t = p.results and p.results[i] or nil, lane = i }
      end
      table.sort(ranked, function (a, b)
        local pa = a.t and a.t.pos or math.huge
        local pb = b.t and b.t.pos or math.huge
        if pa ~= pb then return pa < pb end
        return a.lane < b.lane
      end)
      for _, row in ipairs(ranked) do
        local t = row.t
        local note = ''
        if t then
          if t.foul then note = '  RED LIGHT'
          elseif t.brokeOut then note = '  BROKE OUT'
          elseif not t.et then note = '  DNF' end
          if t.through then note = note .. '  -> through' end
        end
        f:write(string.format('    L%d %-22s RT %-7s ET %-8s %-6s mph%s\n',
          row.lane, row.e.name:sub(1, 22),
          t and fmtET(t.rt) or '--', t and fmtET(t.et) or '--',
          t and fmtSpeed(t.speed) or '--', note))
      end
    end
  end
  -- The cup section, in the same layout as a race's and a derby's.
  for _, l in ipairs((cupResultsLines and cupRound
      and cupResultsLines(cupRound)) or {}) do
    f:write(l .. '\n')
  end
  f:write('\n')
  f:close()
  return true, path
end

finishTournament = function (reason)
  drag.phase = 'complete'
  MP.CancelEventTimer('RM_DragTick')
  local live = stillIn()
  if #live == 1 and drag.format ~= 'points' then
    live[1].status = 'champion'
    ladder.champion = live[1].name
  end
  ladder.finishOrder = buildFinishOrder()
  if not ladder.champion and ladder.finishOrder[1] then
    ladder.champion = ladder.finishOrder[1].name
    local top = ladder.entrants[1]
    for _, e in ipairs(ladder.entrants) do
      if e.name == ladder.champion then top = e; break end
    end
    if top then top.status = 'champion' end
  end
  -- Everybody gets their car and their camera back. Scoped to the 'drag'
  -- source, so a racing DNF's spectator lock is untouched by a ladder ending.
  releaseSpectators('drag')
  saveLadder()
  broadcastDragState()
  print('[RaceManager] Drag tournament over: ' .. tostring(reason))
  -- Score it into the cup (handed the classification). The banked round goes to
  -- the results file: at the round cap, "the current round" is the last one.
  local cupRound = nil
  if cupOnDragComplete then
    local low = lowETEntrant()
    local okCup, banked = pcall(cupOnDragComplete, dragClassification(), {
      lowETPid = low and low.id or nil,
      format   = drag.format,
      entrants = #ladder.entrants,
    })
    if okCup then cupRound = banked
    else print('[RaceManager] Cup scoring failed for the drag round: ' .. tostring(banked)) end
  end
  local ok, wrote, pathOrErr = pcall(writeResults, cupRound)
  if ok and wrote then
    MP.SendChatMessage(-1, '[RaceManager] DRAG TOURNAMENT WINNER: '
      .. tostring(ladder.champion) .. '! Results saved: ' .. tostring(pathOrErr))
    print('[RaceManager] Drag results written to ' .. tostring(pathOrErr))
  else
    print('[RaceManager] Failed to write drag results: '
      .. tostring(ok and pathOrErr or wrote))
  end
end

-- Every pass in the round is done. Score whatever the format scores between
-- rounds, then draw the next one.
local function roundComplete()
  local r = ladder.rounds[ladder.round]
  if not r then return end
  r.done = true
  if drag.format == 'points' then applyCut(r) end
  print('[RaceManager] Drag: ' .. r.label .. ' complete')
  if buildNextRound() then
    drag.phase = 'ready'
    saveLadder()
    broadcastDragState()
    local nr = ladder.rounds[ladder.round]
    MP.SendChatMessage(-1, '[RaceManager] Drag: ' .. nr.label .. ' is up, '
      .. #nr.passes .. ' pass' .. (#nr.passes == 1 and '' or 'es') .. ' to run.')
  end
end

-- ===========================================================================
-- RUNNING A PASS
-- ===========================================================================
-- Stage holds the cars on their lanes, Run drops the tree, the result settles
-- itself (as Form Up / Start and Generate Grid / Start Countdown).

-- How long the lights take from Run. The PRE-ROLL is random (a fixed delay is
-- learned, not reacted to), drawn HERE so every lane sees the same tree.
-- THE 1.5s FLOOR IS LOAD-BEARING: the staggered placement lands an eight-wide
-- field 1.26s after Stage, and a car released mid-flight reads as a red light.
local DRAG_TREE_PREROLL_MIN = 1.5
local DRAG_TREE_PREROLL_MAX = 2.5
local DRAG_TREE_PRO         = 0.4   -- three ambers together, green 0.4s later
local DRAG_TREE_SPORTSMAN   = 1.5   -- ambers 0.5s apart, green 0.5s after

local function treeLightsFor(pattern)
  return pattern == 'pro' and DRAG_TREE_PRO or DRAG_TREE_SPORTSMAN
end

-- The head start each lane is owed: the SLOWER dial leaves first by the
-- difference, so run your number and you arrive together. A delay after the
-- green; the biggest dial waits zero.
local function laneDelays(lanes)
  local delay = {}
  if not drag.dialIn then
    for i = 1, #lanes do delay[i] = 0 end
    return delay
  end
  local slowest = nil
  for _, e in ipairs(lanes) do
    local d = e.dial
    if d and (not slowest or d > slowest) then slowest = d end
  end
  for i, e in ipairs(lanes) do
    -- No dial, no head start: not answering cannot be gamed.
    delay[i] = (slowest and e.dial) and (slowest - e.dial) or (slowest or 0)
    if delay[i] < 0 then delay[i] = 0 end
  end
  return delay
end

-- The pass the ladder is pointing at, or nil.
local function currentPass()
  local r = activeRound()
  return r and r.passes[practice.on and 1 or ladder.pass] or nil, r
end

-- The next unrun pass, or nil. Scanned, so an aborted pass is offered again.
local function nextPassIndex()
  local r = activeRound()
  if not r then return nil end
  for i, p in ipairs(r.passes) do
    if not p.done then return i end
  end
  return nil
end

local settlePass  -- assigned below; the tick and the reports both reach it

-- Put one lane's car on the strip. `order` and `count` stagger a batch; a
-- lone ready-up is 1 of 1 and lands at once.
function drag.sendLane(i, e, p, order, count)
  local rollup = drag.stageMode == 'rollup'
  -- Under 'hold' a car is staged when placed; under 'rollup' the client reports
  -- it reaching the beams.
  pass.staged[i] = not rollup
  pass.prestaged[i] = not rollup
  MP.TriggerClientEvent(e.id, 'RM_DragLane', Util.JsonEncode({
    lane = i, slot = i, count = count or #p.lanes, order = order or i,
    -- The freeze and the roll-up are the same decision seen twice: a car
    -- that is held cannot creep, and a car that must creep cannot be held.
    hold = not rollup, rollup = rollup,
    back = rollup and DRAG_ROLLUP_BACK or nil,
    prestageAt = rollup and DRAG_PRESTAGE_AT or nil,
    stageAt = rollup and DRAG_STAGE_AT or nil,
    stagePast = rollup and DRAG_STAGE_PAST or nil,
    dial = e.dial, delay = p.delay[i],
  }))
end

-- Put this pass's cars on their lanes and hold them there.
local function stagePass(index)
  local r = activeRound()
  local p = r and r.passes[index]
  if not p then return false end
  if not practice.on then ladder.pass = index end
  p.delay = laneDelays(p.lanes)
  pass = { lanes = p.lanes, times = {}, staged = {}, prestaged = {},
           time = 0, greenAt = nil, tree = nil, resultUntil = nil,
           -- rollup only: how long the field has been creeping, and when the
           -- tree is due once everybody is in the beams.
           armAt = nil }
  drag.phase = 'staging'
  releaseSpectators('drag')   -- a fresh pass: nobody carries a stale lock
  -- The strip is closed while a pass is on it: everyone else stands down until
  -- it settles, under the 'drag' source (a racing lock is never touched).
  local inPass = {}
  for _, e in ipairs(p.lanes) do
    if e.id then inPass[e.id] = true end
  end
  for id in pairs(onlinePlayers()) do
    if not inPass[id] then
      forceSpectate(id, 'A drag pass is on the strip', 'drag')
    end
  end
  -- Ready check: Stage CALLS the pass; a car goes on when its driver presses
  -- Ready (drag.sendLane). Not ready at the tree is a no-show.
  local called = race.readyCheck == true
  pass.ready = {}
  for i, e in ipairs(p.lanes) do
    if e.id then
      pass.ready[i] = not called
      if called then
        pass.staged[i], pass.prestaged[i] = false, false
      else
        drag.sendLane(i, e, p, i, #p.lanes)
      end
    else
      -- Offline entrants are DNF already, or the pass waits out its timeout.
      pass.staged[i] = false
      pass.times[i] = { entrant = e, lane = i, rt = nil, et = nil, speed = nil,
                        foul = false, brokeOut = false }
    end
  end
  local names = {}
  for _, e in ipairs(p.lanes) do names[#names + 1] = e.name end
  MP.SendChatMessage(-1, practice.on
    and string.format('[RaceManager] Drag practice pass: %s. Nothing is scored.',
      table.concat(names, ', '))
    or string.format('[RaceManager] Drag %s, pass %d/%d: %s%s',
      r.label, index, #r.passes, table.concat(names, ' vs '),
      p.bye and '  (bye run)' or ''))
  print(string.format('[RaceManager] Drag pass staged: %s pass %d (%s)',
    r.label, index, table.concat(names, ', ')))
  if called then
    MP.SendChatMessage(-1, '[RaceManager] Drag: press Ready in PRM - Main '
      .. 'to put your car on the strip.')
  end
  -- The tick runs through STAGING too under roll-up: something has to notice
  -- that the field is in the beams, and something has to give up waiting.
  if drag.stageMode == 'rollup' then MP.CreateEventTimer('RM_DragTick', DRAG_TICK_MS) end
  broadcastDragState()
  return true
end

-- Is every lane that can stage staged? An empty lane (written off at staging)
-- is not counted.
local function allStaged()
  local p = currentPass()
  if not p then return false end
  local any = false
  for i, e in ipairs(p.lanes) do
    if e.id then
      any = true
      if not pass.staged[i] then return false end
    end
  end
  return any
end

-- Drop the tree. The lights RUN ON THE CLIENT: a reaction time from the server
-- would measure the network. The server sends the pattern, the pre-roll and
-- the lane's head start; each client times itself on one clock. The lanes start
-- a few ms apart, which does not matter when they never interact.
local function runPass()
  local p, r = currentPass()
  if not p then return false end
  -- Not ready at the tree is a no-show (bottom of the pass, stood down). Nobody
  -- ready: nothing runs.
  local anyReady, noShow = false, {}
  for i, e in ipairs(p.lanes) do
    if e.id then
      if pass.ready and pass.ready[i] == false then
        noShow[#noShow + 1] = i
      else
        anyReady = true
      end
    end
  end
  if not anyReady and #noShow > 0 then return false end
  if #noShow > 0 then
    local names = {}
    for _, i in ipairs(noShow) do
      local e = p.lanes[i]
      pass.times[i] = { entrant = e, lane = i, rt = nil, et = nil, speed = nil,
                        foul = false, brokeOut = false }
      forceSpectate(e.id, 'You were not ready for this pass', 'drag')
      names[#names + 1] = e.name
    end
    MP.SendChatMessage(-1, '[RaceManager] Drag: ' .. table.concat(names, ', ')
      .. ' not ready, no-show this pass.')
  end
  seedOnce()
  local preroll = DRAG_TREE_PREROLL_MIN
    + math.random() * (DRAG_TREE_PREROLL_MAX - DRAG_TREE_PREROLL_MIN)
  pass.tree = preroll + treeLightsFor(drag.tree)
  drag.phase = 'tree'
  pass.time = 0
  for i, e in ipairs(p.lanes) do
    if e.id and not (pass.ready and pass.ready[i] == false) then
      MP.TriggerClientEvent(e.id, 'RM_DragTree', Util.JsonEncode({
        pattern = drag.tree, preroll = preroll, delay = p.delay and p.delay[i] or 0,
        lane = i, timeout = drag.timeout, dial = e.dial,
        breakout = drag.dialIn and drag.breakout,
      }))
    end
  end
  -- Everybody watching gets the tree too, on the same numbers, so a spectator
  -- and a driver see the same lights come on.
  MP.TriggerClientEvent(-1, 'RM_DragTreeWatch', Util.JsonEncode({
    pattern = drag.tree, preroll = preroll,
  }))
  MP.CreateEventTimer('RM_DragTick', DRAG_TICK_MS)
  broadcastDragState()
  print(string.format('[RaceManager] Drag tree dropped: %s pass %d (%s, preroll %.2fs)',
    r.label, ladder.pass, drag.tree, preroll))
  return true
end

-- Has every lane reported? A lane with no player in it reported at staging.
local function allHome()
  local p = currentPass()
  if not p then return false end
  for i = 1, #p.lanes do
    if pass.times[i] == nil then return false end
  end
  return true
end

settlePass = function (reason)
  local p, r = currentPass()
  if not p then return end
  MP.CancelEventTimer('RM_DragTick')
  local results = {}
  for i, e in ipairs(p.lanes) do
    local t = pass.times[i] or { entrant = e, lane = i, foul = false, brokeOut = false }
    t.entrant, t.lane = e, i
    -- Fouled and never finished is still a red light (same tier as a no-show,
    -- but the reason it lost is kept).
    if not t.foul and pass.fouled and pass.fouled[i] then
      t.foul = true
      t.rt = t.rt or pass.fouled[i]
    end
    -- Arrival from the shared green: dial head start + reaction + ET.
    if t.et then
      t.finishMoment = (p.delay and p.delay[i] or 0) + math.max(t.rt or 0, 0) + t.et
    end
    results[i] = t
  end
  p.results = results
  applyResult(p, r, r.final == true)
  drag.phase = 'result'
  pass.resultUntil = drag.holdResult
  pass.time = 0
  local top = nil
  for _, t in ipairs(results) do if t.pos == 1 then top = t end end
  -- All three numbers in chat, labelled (two of them are seconds).
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] Drag %s pass %d: %s takes it (RT %s, ET %s, %s mph)%s',
    r.label, ladder.pass, top and top.entrant.name or '?',
    top and fmtET(top.rt) or '--', top and fmtET(top.et) or '--',
    top and fmtSpeed(top.speed) or '--',
    p.bye and '  (bye run)' or ''))
  print('[RaceManager] Drag pass settled: ' .. tostring(reason))
  saveLadder()
  broadcastDragState()
  MP.CreateEventTimer('RM_DragTick', DRAG_TICK_MS)
end

-- The result has stood on screen long enough. Point the ladder at the next
-- pass, or close the round out.
local function afterResult()
  MP.CancelEventTimer('RM_DragTick')
  -- The strip is open again: everybody stood down for this pass gets their car
  -- and their camera back, whether they are still in the tournament or not.
  releaseSpectators('drag')
  pass = { lanes = {}, times = {}, staged = {}, time = 0 }
  -- A practice pass leaves the ladder exactly where it was.
  if practice.on then
    practice.on, practice.round = false, nil
    drag.phase = (#ladder.entrants > 0)
      and (ladder.champion and 'complete' or 'ready') or 'idle'
    broadcastDragState()
    return
  end
  local nextIndex = nextPassIndex()
  if nextIndex then
    ladder.pass = nextIndex
    drag.phase = 'ready'
    saveLadder()
    broadcastDragState()
    return
  end
  roundComplete()
end

function RM_DragTick()
  if drag.phase ~= 'staging' and drag.phase ~= 'tree'
      and drag.phase ~= 'running' and drag.phase ~= 'result' then
    MP.CancelEventTimer('RM_DragTick')
    return
  end
  pass.time = pass.time + DRAG_TICK_MS / 1000
  -- STAGING, under roll-up. Two things can end it: the field gets into the
  -- beams, or it runs out of patience.
  if drag.phase == 'staging' then
    -- Hold mode must never start itself: its cars are staged on placement, so
    -- the tree would fire on a landing field. Checked here, not left to
    -- stagePass never creating the timer.
    if drag.stageMode ~= 'rollup' then
      MP.CancelEventTimer('RM_DragTick')
      return
    end
    if drag.autoStart and allStaged() then
      -- Armed rather than fired, so the last car to stage gets the same
      -- moment to settle everybody else got.
      pass.armAt = pass.armAt or (pass.time + DRAG_STAGE_SETTLE)
    else
      -- Somebody rolled back out of the beams: the tree is no longer coming
      -- and the count starts again when they return.
      pass.armAt = nil
    end
    if pass.armAt and pass.time >= pass.armAt then
      runPass()
    elseif pass.time >= drag.stageWait then
      -- The tree drops on whoever is staged: a late car is a result.
      MP.SendChatMessage(-1, '[RaceManager] Drag: courtesy stage expired, the '
        .. 'tree is coming down.')
      -- Nobody ready at all: nothing to run, so the pass is waved off and
      -- offered again rather than scored as everybody failing to turn up.
      if not runPass() then drag.waveOff('nobody was ready') end
    end
    return
  end
  if drag.phase == 'result' then
    if pass.time >= (pass.resultUntil or 0) then afterResult() end
    return
  end
  if drag.phase == 'tree' then
    if pass.time < (pass.tree or 0) then return end
    drag.phase = 'running'
    broadcastDragPass()
    return
  end
  if allHome() then settlePass('every lane home'); return end
  -- The timeout is measured from the GREEN, not from the button: a two second
  -- pre-roll should not come out of the time a driver has to make the run.
  if pass.time - (pass.tree or 0) >= drag.timeout then
    settlePass('timed out')
  end
end

-- ===========================================================================
-- Building the ladder
-- ===========================================================================
-- The field is snapshotted ONCE, at build, or the bracket would redraw itself
-- every time somebody joined to watch.
local function shuffle(list)
  seedOnce()
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
end

-- Everyone the ladder could be drawn from: connected and entered (isEntrant).
local function candidates()
  local list = {}
  for id in pairs(onlinePlayers()) do
    local rec = players[id]
    if (not rec) or isEntrant(rec) then
      list[#list + 1] = {
        id = id,
        name = rec and displayName(rec) or (MP.GetPlayerName(id) or ('Player ' .. id)),
        -- The alias, separately: the roster matches on it, never on the guest
        -- name, or every round scores against a fresh placeholder.
        alias = rec and rec.alias or nil,
        -- Their qualifying time on the strip, for seeding (and a first dial).
        best = rec and rec.qualiBest or nil,
      }
    end
  end
  return list
end

local function seedField(list, order)
  if drag.seed == 'order' then
    table.sort(list, function (a, b) return a.id < b.id end)
  elseif drag.seed == 'quali' then
    table.sort(list, function (a, b)
      if a.best and b.best then
        if a.best ~= b.best then return a.best < b.best end
      elseif a.best ~= b.best then
        return a.best ~= nil     -- a time beats no time
      end
      return a.id < b.id
    end)
  elseif drag.seed == 'manual' then
    -- A manual draw with no order falls back to join order, never the shuffle
    -- the admin ruled out.
    local rank = {}
    for i, id in ipairs(type(order) == 'table' and order or {}) do
      rank[tonumber(id) or -1] = i
    end
    table.sort(list, function (a, b)
      local ra, rb = rank[a.id] or math.huge, rank[b.id] or math.huge
      if ra ~= rb then return ra < rb end
      return a.id < b.id
    end)
  else
    shuffle(list)
  end
  return list
end

local function clearLadder()
  MP.CancelEventTimer('RM_DragTick')
  practice.on, practice.round = false, nil
  ladder.entrants, ladder.rounds = {}, {}
  ladder.round, ladder.pass = 0, 0
  ladder.champion, ladder.started, ladder.finishOrder = nil, nil, nil
  ladder.resetPending = false
  pass = { lanes = {}, times = {}, staged = {}, time = 0 }
  drag.phase = 'idle'
end

-- --- Drag event handlers (admin controls relayed by the client bridge) -----

function RM_onDragSetConfig(pid, rawData)
  if not requireAuth(pid) then return end
  -- The rules may be changed between passes but never during one: a pass
  -- staged under two lanes and settled under four is not a pass.
  if dragActive() then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  -- ANYTHING UNRECOGNIZED LEAVES THE SETTING ALONE rather than falling back to
  -- a default. A garbled payload must not quietly change how a night is scored.
  if DRAG_FORMATS[data.format] then drag.format = data.format end
  if DRAG_TREE_PATTERNS[data.tree] then drag.tree = data.tree end
  if DRAG_STAGE_MODES[data.stageMode] then drag.stageMode = data.stageMode end
  if type(data.autoStart) == 'boolean' then drag.autoStart = data.autoStart end
  drag.stageWait = clampInt(data.stageWait, 5, 300, drag.stageWait)
  if DRAG_SEEDS[data.seed] then drag.seed = data.seed end
  drag.lanes   = clampInt(data.lanes,   DRAG_MIN_LANES, DRAG_MAX_LANES, drag.lanes)
  drag.advance = clampInt(data.advance, 1, DRAG_MAX_LANES - 1, drag.advance)
  drag.cut     = clampInt(data.cut,     0, DRAG_MAX_FIELD, drag.cut)
  drag.rounds  = clampInt(data.rounds,  1, DRAG_MAX_ROUNDS, drag.rounds)
  drag.timeout = clampInt(data.timeout, DRAG_MIN_TIMEOUT, DRAG_MAX_TIMEOUT, drag.timeout)
  drag.holdResult = clampInt(data.holdResult, 0, 60, drag.holdResult)
  if type(data.dialIn)   == 'boolean' then drag.dialIn   = data.dialIn end
  if type(data.breakout) == 'boolean' then drag.breakout = data.breakout end
  -- Advance must stay below the lane count, or a pass narrows nothing. After
  -- both assignments, so it wins in either order.
  if drag.advance > drag.lanes - 1 then drag.advance = drag.lanes - 1 end
  saveLadder()
  broadcastDragState()
  print(string.format('[RaceManager] Drag config by %s: %s, %d lane(s), %d through, '
    .. '%s tree, seed %s, dial-in %s',
    MP.GetPlayerName(pid) or pid, drag.format, drag.lanes, drag.advance,
    drag.tree, drag.seed, drag.dialIn and 'on' or 'off'))
end

function RM_onDragBuild(pid, rawData)
  if not requireAuth(pid) then return end
  if dragActive() then return end
  local order = nil
  if type(rawData) == 'string' and rawData ~= '' then
    local ok, data = pcall(Util.JsonDecode, rawData)
    if ok and type(data) == 'table' then order = data.order end
  end
  -- The strip (a finish and a lane) comes with the loaded track layout.
  if stripGates() < 1 then
    MP.SendChatMessage(pid, '[RaceManager] Load a track layout first: the drag '
      .. 'strip is a point-to-point layout, and its last gate is the finish line.')
    return
  end
  if stripLanes() < DRAG_MIN_LANES then
    MP.SendChatMessage(pid, '[RaceManager] The loaded layout has '
      .. stripLanes() .. ' start position(s). A drag strip needs at least '
      .. DRAG_MIN_LANES .. ', one per lane.')
    return
  end
  local list = candidates()
  if #list < 2 then
    MP.SendChatMessage(pid, '[RaceManager] Not enough entrants: a ladder needs '
      .. 'at least two drivers who have not opted out.')
    return
  end
  if #list > DRAG_MAX_FIELD then
    MP.SendChatMessage(pid, '[RaceManager] Too many entrants (' .. #list
      .. '); the ladder holds ' .. DRAG_MAX_FIELD .. '.')
    return
  end
  clearLadder()
  -- THE STRIP CAPS THE LANES, not the admin. Eight lanes on a four-lane strip
  -- would stage four cars on top of each other.
  if drag.lanes > stripLanes() then
    drag.lanes = stripLanes()
    if drag.advance > drag.lanes - 1 then drag.advance = drag.lanes - 1 end
    MP.SendChatMessage(pid, '[RaceManager] Lanes reduced to ' .. drag.lanes
      .. ': that is what the loaded strip has start positions for.')
  end
  seedField(list, order)
  for i, c in ipairs(list) do
    ladder.entrants[i] = {
      id = c.id, seed = i, name = c.name, alias = c.alias, status = 'in',
      wins = 0, losses = 0, passes = 0, points = 0,
      -- Their qualifying time is the first guess at their dial-in, because it
      -- is the only number anybody has yet. They can change it before they run.
      dial = drag.dialIn and c.best or nil,
      bestET = nil, bestRT = nil, bestSpeed = nil,
    }
  end
  ladder.started = os.time()
  buildNextRound()
  drag.phase = 'ready'
  releaseSpectators('drag')
  saveLadder()
  broadcastDragState()
  local r = ladder.rounds[ladder.round]
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] DRAG LADDER: %d entrants, %s, %d lane%s per pass. %s is up.',
    #ladder.entrants, drag.format, drag.lanes, drag.lanes == 1 and '' or 's',
    r and r.label or 'Round 1'))
  print(string.format('[RaceManager] Drag ladder built by %s: %d entrants, %s, seed %s',
    MP.GetPlayerName(pid) or pid, #ladder.entrants, drag.format, drag.seed))
end

-- One pass that scores nothing: up to the lane count, staged and timed as a
-- real pass, two presses (Practice, Run). Works with ONE driver: to find the
-- finish line, or a dial-in.
function RM_onDragPractice(pid)
  if not requireAuth(pid) then return end
  if dragActive() then return end
  if stripGates() < 1 or stripLanes() < 1 then
    MP.SendChatMessage(pid, '[RaceManager] Load a track layout first: the drag '
      .. 'strip is a point-to-point layout with a start position to line up on.')
    return
  end
  local list = candidates()
  if #list == 0 then
    MP.SendChatMessage(pid, '[RaceManager] Nobody to run: everybody connected is '
      .. 'sitting this one out.')
    return
  end
  table.sort(list, function (a, b) return a.id < b.id end)
  -- Capped by the strip's lanes, not the configured count.
  local room = math.min(stripLanes(), DRAG_MAX_LANES)
  local lanes = {}
  for i = 1, math.min(#list, room) do
    local c = list[i]
    -- Throwaway records for one run; the dial is copied from the ladder entry.
    local dial = nil
    for _, e in ipairs(ladder.entrants) do
      if e.id == c.id then dial = e.dial; break end
    end
    lanes[i] = { id = c.id, name = c.name, seed = i, dial = dial,
                 wins = 0, losses = 0, passes = 0, points = 0, status = 'in' }
  end
  practice.on = true
  practice.round = {
    n = 0, side = 'p', label = 'Practice pass', final = false, done = false,
    passes = { { lanes = lanes, bye = false, done = false, results = nil } },
  }
  stagePass(1)
  print(string.format('[RaceManager] Drag practice pass by %s (%d car%s)',
    MP.GetPlayerName(pid) or pid, #lanes, #lanes == 1 and '' or 's'))
end

function RM_onDragStage(pid)
  if not requireAuth(pid) then return end
  if drag.phase ~= 'ready' then
    if drag.phase == 'idle' then
      MP.SendChatMessage(pid, '[RaceManager] Build the ladder first.')
    end
    return
  end
  local index = nextPassIndex()
  if not index then
    -- Every pass in the round is already run: close it out rather than leaving
    -- the admin pressing a button that does nothing.
    roundComplete()
    return
  end
  stagePass(index)
end

function RM_onDragRun(pid)
  if not requireAuth(pid) then return end
  if drag.phase ~= 'staging' then
    if drag.phase == 'ready' then
      MP.SendChatMessage(pid, '[RaceManager] Press Stage first: it puts the cars '
        .. 'on their lanes and holds them for the tree.')
    end
    return
  end
  if not runPass() then
    MP.SendChatMessage(pid, '[RaceManager] Nobody in this pass is ready yet. Wait '
      .. 'for Ready, or press Ready All to put every car on the strip.')
  end
end

-- READY, for a drag pass. The driver's own call; an admin may make it for a
-- lane driver by naming them. Not ready takes the car off the strip again.
function RM_onDragReady(pid, rawData)
  local ok, data = pcall(Util.JsonDecode, (rawData and rawData ~= '') and rawData or '{}')
  if not ok or type(data) ~= 'table' then data = {} end
  local target = pid
  if data.pid ~= nil and tonumber(data.pid) ~= pid then
    if not requireAuth(pid) then return end
    target = tonumber(data.pid)
  end
  local p = currentPass()
  if drag.phase ~= 'staging' or not p or not pass.ready then return end
  for i, e in ipairs(p.lanes) do
    if e.id == target then
      if data.ready ~= false and pass.ready[i] == false then
        pass.ready[i] = true
        drag.sendLane(i, e, p, 1, 1)
        print('[RaceManager] Drag: ' .. e.name .. ' is ready (lane ' .. i .. ')')
        drag.announceIfAllReady(p)
      elseif data.ready == false and pass.ready[i] == true and race.readyCheck then
        pass.ready[i], pass.staged[i], pass.prestaged[i] = false, false, false
        MP.TriggerClientEvent(e.id, 'RM_DragLane', Util.JsonEncode({ release = true }))
        print('[RaceManager] Drag: ' .. e.name .. ' is not ready any more')
      end
      break
    end
  end
  broadcastDragState()
end

function RM_onDragReadyAll(pid)
  if not requireAuth(pid) then return end
  local p = currentPass()
  if drag.phase ~= 'staging' or not p or not pass.ready then return end
  local todo = {}
  for i, e in ipairs(p.lanes) do
    if e.id and pass.ready[i] == false then todo[#todo + 1] = i end
  end
  for n, i in ipairs(todo) do
    pass.ready[i] = true
    drag.sendLane(i, p.lanes[i], p, n, #todo)
  end
  print(string.format('[RaceManager] Drag Ready All by %s: %d placed',
    MP.GetPlayerName(pid) or pid, #todo))
  broadcastDragState()
end

function drag.announceIfAllReady(p)
  local ready, total = 0, 0
  for i, e in ipairs(p.lanes) do
    if e.id then
      total = total + 1
      if pass.ready[i] ~= false then ready = ready + 1 end
    end
  end
  if total > 0 and ready == total then
    race.tellAdmins(string.format('Everyone in this drag pass is ready (%d/%d).', ready, total))
  end
end

-- Wave a pass off: nothing scored, the cars go back, the pass is offered again.
function RM_onDragAbort(pid)
  if not requireAuth(pid) then return end
  if drag.phase ~= 'staging' and drag.phase ~= 'tree' and drag.phase ~= 'running' then return end
  drag.waveOff('by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Wave the pass off: nothing scored, the same pass offered again. From the
-- admin's button, and from a courtesy stage that ran out with nobody ready.
function drag.waveOff(why)
  MP.CancelEventTimer('RM_DragTick')
  local p = currentPass()
  if p then p.results, p.delay = nil, nil end
  pass = { lanes = {}, times = {}, staged = {}, time = 0 }
  -- A waved-off PRACTICE pass is simply gone. There is nothing to re-offer: the
  -- round it belonged to was built for it and exists nowhere else.
  local wasPractice = practice.on
  practice.on, practice.round = false, nil
  drag.phase = wasPractice
    and ((#ladder.entrants > 0)
      and (ladder.champion and 'complete' or 'ready') or 'idle')
    or 'ready'
  -- The abort broadcast is what releases every held car, so it has to go out
  -- even though nobody ran: without it the lane cars stay frozen.
  MP.TriggerClientEvent(-1, 'RM_DragAborted', Util.JsonEncode({ reason = 'waved off' }))
  releaseSpectators('drag')
  broadcastDragState()
  MP.SendChatMessage(-1, '[RaceManager] Drag pass waved off (' .. why .. '). Re-staging.')
  print('[RaceManager] Drag pass waved off: ' .. why)
end

function RM_onDragClear(pid)
  if not requireAuth(pid) then return end
  clearLadder()
  MP.TriggerClientEvent(-1, 'RM_DragAborted', Util.JsonEncode({ reason = 'ladder cleared' }))
  releaseSpectators('drag')
  saveLadder()
  broadcastDragState()
  print('[RaceManager] Drag ladder cleared by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Pull an entrant out: their passes are walkovers, not a lane that never
-- reports.
function RM_onDragWithdraw(pid, rawData)
  if not requireAuth(pid) then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local seed = tonumber(data.seed)
  for _, e in ipairs(ladder.entrants) do
    if e.seed == seed and e.status ~= 'withdrawn' then
      e.status = 'withdrawn'
      if e.id then forceSpectate(e.id, 'Withdrawn from the drag ladder', 'drag') end
      print('[RaceManager] Drag: ' .. e.name .. ' withdrawn by '
        .. (MP.GetPlayerName(pid) or pid))
      saveLadder()
      broadcastDragState()
      return
    end
  end
end

-- A driver declaring their own dial-in, or an admin setting one for them. Both
-- land here; `seed` is what tells them apart, and only an admin may send it.
function RM_onDragSetDial(pid, rawData)
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local target = nil
  if data.seed ~= nil then
    if not requireAuth(pid) then return end
    local seed = tonumber(data.seed)
    for _, e in ipairs(ladder.entrants) do
      if e.seed == seed then target = e; break end
    end
  else
    target = entrantFor(pid)
  end
  if not target then return end
  -- NOT WHILE THE CAR IS ON THE LINE. A dial changed between staging and the
  -- green would move a head start that has already been handed out.
  if dragActive() then
    for _, e in ipairs(pass.lanes or {}) do
      if e == target then return end
    end
  end
  local dial = tonumber(data.dial)
  target.dial = dial and clampNum(dial, 0.1, DRAG_MAX_DIAL, nil) or nil
  saveLadder()
  broadcastDragState()
end

-- --- Client -> server: what happened in a lane -----------------------------

-- A car reached the beams, or left them: only the client can know (no physics
-- here). Reported on CHANGE, not per frame.
function RM_onDragStaged(pid, rawData)
  if drag.phase ~= 'staging' then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  for i, lane in ipairs(pass.lanes or {}) do
    if lane.id == pid then
      local was = pass.staged[i]
      pass.staged[i]    = data.staged == true
      pass.prestaged[i] = data.prestaged == true or pass.staged[i]
      if was ~= pass.staged[i] then
        print(string.format('[RaceManager] Drag: %s %s lane %d',
          lane.name, pass.staged[i] and 'staged in' or 'rolled out of', i))
      end
      broadcastDragPass()
      return
    end
  end
end

-- A red light, reported at the launch so the bulb lights during the run. The
-- run still counts: a foul loses, it does not cancel.
function RM_onDragFoul(pid, rawData)
  if drag.phase ~= 'tree' and drag.phase ~= 'running' then return end
  local rt = nil
  if type(rawData) == 'string' and rawData ~= '' then
    local ok, data = pcall(Util.JsonDecode, rawData)
    if ok and type(data) == 'table' then rt = tonumber(data.rt) end
  end
  -- Matched against the LANES: a practice pass has no entrants.
  for i, lane in ipairs(pass.lanes or {}) do
    if lane.id == pid then
      -- Held on the pass rather than written into times: the lane has not
      -- finished yet, and a times entry is what allHome counts.
      pass.fouled = pass.fouled or {}
      pass.fouled[i] = rt and clampNum(rt, -9.999, 0, -0.001) or -0.001
      broadcastDragPass()
      return
    end
  end
end

-- A completed run. Every number in it was measured by this client against the
-- tree this client ran, which is the whole reason the tree runs there.
function RM_onDragResult(pid, rawData)
  if drag.phase ~= 'tree' and drag.phase ~= 'running' then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local p = currentPass()
  if not p then return end
  -- By LANE, for the reason spelled out in RM_onDragFoul: a practice pass has
  -- no entrant list to be found in.
  for i, lane in ipairs(p.lanes) do
    if lane.id == pid then
      local e = lane
      if pass.times[i] then return end   -- a duplicate report is a no-op
      local foul = data.foul == true or (pass.fouled and pass.fouled[i] ~= nil)
      local rt = tonumber(data.rt)
      if foul then
        -- A red light is a NEGATIVE light: how far before the green they left.
        rt = clampNum(rt, -9.999, 0, (pass.fouled and pass.fouled[i]) or -0.001)
      else
        rt = rt and clampNum(rt, 0, 99.999, nil) or nil
      end
      local et = tonumber(data.et)
      et = et and clampNum(et, 0.001, DRAG_MAX_ET, nil) or nil
      local t = {
        entrant = e, lane = i, rt = rt, et = et,
        speed = tonumber(data.speed) and clampNum(data.speed, 0, 999, nil) or nil,
        foul = foul, brokeOut = false,
      }
      -- A breakout needs a dial and the rule on; decided HERE, not by the client.
      if drag.dialIn and drag.breakout and e.dial and t.et and t.et < e.dial then
        t.brokeOut = true
        t.breakBy  = t.et - e.dial
      end
      pass.times[i] = t
      broadcastDragPass()
      if allHome() then settlePass('every lane home') end
      return
    end
  end
end

function RM_onDragRequestState(pid)
  local entrants = {}
  for _, e in ipairs(ladder.entrants) do entrants[#entrants + 1] = entrantRow(e) end
  local r = ladder.rounds[ladder.round]
  MP.TriggerClientEvent(pid, 'RM_DragUpdate', Util.JsonEncode({
    rmProtocol = RM_PROTOCOL,
    dragPhase = drag.phase,
    format = drag.format, lanes = drag.lanes, advance = drag.advance,
    cut = drag.cut, roundLimit = drag.rounds, tree = drag.tree, seed = drag.seed,
    dialIn = drag.dialIn, breakout = drag.breakout, timeout = drag.timeout,
    holdResult = drag.holdResult, stageMode = drag.stageMode,
    autoStart = drag.autoStart, stageWait = drag.stageWait,
    stripLanes = stripLanes(), stripGates = stripGates(),
    round = ladder.round, roundLabel = r and r.label or nil,
    roundSide = r and r.side or nil, roundCount = #ladder.rounds,
    passIndex = ladder.pass, passCount = r and #r.passes or 0,
    champion = ladder.champion, finishOrder = ladder.finishOrder,
    -- A PRACTICE pass, said plainly: the controls look identical.
    practice = practice.on,
    entrants = entrants, board = boardRows(), current = livePass(),
  }))
end

-- The entry list moved. The ladder does NOT redraw; the ids follow the people.
dragEntryListChanged = function ()
  if #ladder.entrants == 0 then return end
  local online = onlinePlayers()
  local claimed = {}
  local changed = false
  for _, e in ipairs(ladder.entrants) do
    if e.id and not online[e.id] then e.id = nil; changed = true end
    if e.id then claimed[e.id] = true end
  end
  -- A name coming back reclaims its seed: a deliberate, narrow exception (inside
  -- a running ladder only, no points hang on it) to refusing name matching.
  for _, e in ipairs(ladder.entrants) do
    if not e.id and e.status ~= 'withdrawn' then
      for id, name in pairs(online) do
        local rec = players[id]
        local shown = rec and displayName(rec) or name
        if not claimed[id] and shown == e.name then
          e.id, claimed[id] = id, true
          changed = true
          break
        end
      end
    end
  end
  if changed then broadcastDragState() end
end

function RM_Drag_onPlayerDisconnect(pid)
  -- A lane whose driver left is DNF at once. Before the ladder: a practice pass
  -- has lanes and no entrants.
  local settled = false
  if dragActive() then
    for i, lane in ipairs(pass.lanes or {}) do
      if lane.id == pid then
        lane.id = nil
        if not pass.times[i] then
          pass.times[i] = { entrant = lane, lane = i, foul = false, brokeOut = false }
          if allHome() then settlePass('lane disconnected'); settled = true end
        end
      end
    end
  end
  local e = entrantFor(pid)
  if not e and not settled then return end
  if e then e.id = nil end
  if not settled then broadcastDragState() end
end

D.warm = function () dragWarm() end
D.entryListChanged = function () dragEntryListChanged() end
D.underWay = function () return dragActive() end

-- ===========================================================================
-- End of DRAG RACING module
-- ===========================================================================

return D
