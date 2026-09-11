-- Race Manager: DRAG RACING, as its own module.
--
-- A tournament ladder run down a drag strip: its own state tables, its own
-- event names (RM_Drag*), its own broadcast channel (RM_DragUpdate), its own
-- persistence file and its own results export. Nothing here reads or writes the
-- circuit racing state machine, so a ladder can never disturb qualifying or a
-- race and vice versa. Same isolation the demo derby keeps, for the same
-- reasons and by the same means.
--
-- WHY IT IS A MODULE AND NOT A SECTION OF main.lua. That file sits against
-- Lua's hard limit of 200 locals in the main chunk, where the next `local`
-- anybody adds stops the plugin compiling and the server starts without it. A
-- required sibling gets its own budget. BeamMP puts each plugin folder on its
-- own package.path, which is how derby.lua already loads.
--
-- THE STRIP IS THE LOADED TRACK LAYOUT, and that is the whole reuse:
--
--   * a point-to-point layout is already "driven once, first gate to last",
--     which is what a drag strip is
--   * its LAST gate is the finish line, and the client already knows how to
--     detect a crossing (it has the physics; this file does not)
--   * its START POSITIONS are the lanes, and the client already knows how to
--     teleport a car onto one and freeze it there
--
-- So there is no strip editor here. An admin builds a two-gate sprint stage
-- with two to eight start positions in the track editor, saves it, loads it,
-- and it is a drag strip. Nothing in this file authors geometry.
--
-- WHAT THIS FILE OWNS is the tournament: who is in it, who they race, who
-- advances, who is out, and the ladder that steps through it. Timing arrives
-- from the clients, who measured it; ranking a pass, deciding a round and
-- building the next one happen here.
--
-- THE CONTRACT. Everything arrives once through init(host): stable tables or
-- plain functions, never getters, because the tables main.lua owns are cleared
-- in place rather than replaced -- a reference taken at startup is still the
-- right table after any number of session resets.
--
-- WHAT LEAVES is two names: warm (a boot-time load of the saved ladder) and
-- entryListChanged (a driver joined or left the entry list). The RM_Drag*
-- handlers stay global and cross the file boundary for free, because BeamMP
-- registers events by NAME -- the string is resolved when the event fires.

local D = {}

-- Assigned once by init. Declared up here so every function below closes over
-- them; a value captured at file load would be nil, because the host has not
-- called init when this chunk runs.
local LAYOUTS_DIR, RM_PROTOCOL
local displayName, ensureLayoutsDir, ensureResultsDir
local forceSpectate, isEntrant, jsonParse, jsonStringify
local onlinePlayers, releaseSpectators, requireAuth, uniqueResultsPath
local players, race

-- Set later by setCupHooks, and nil is a legitimate state: no cup, no points.
-- They cannot arrive through init because the cup installs itself at the very
-- end of main.lua, long after this module has loaded and been initialised --
-- they would be captured nil and stay nil forever. The guards around them are
-- load-bearing, not defensive habit. Same arrangement the derby keeps.
local cupOnDragComplete, cupResultsLines

-- Built in init from LAYOUTS_DIR. Declared up here and assigned there, never
-- beside the code that reads it: Lua resolves names at compile time, so a
-- `local` declared below its use is not a declaration at all -- the reads
-- compile as nil globals and the file works exactly as badly as it looks like
-- it should not. derby.lua carries the same note for the same bug.
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

-- The christmas tree, as the two patterns anybody actually runs.
--
-- These are the SHAPE of the tree, not its timing on this machine: the server
-- sends the pattern and the client runs the lights on its own clock, because a
-- reaction time measured across a network measures the network. See
-- broadcastTree.
-- HOW A CAR GETS ONTO THE LINE.
--
--   hold    placed exactly on the start position and frozen there. The
--           original behaviour, and still the right one for an eight-wide
--           shootout where waiting for eight people to creep into the beams
--           is most of the evening.
--   rollup  placed a few metres BEHIND the line and left free. The driver
--           rolls forward into the beams themselves, which is what staging
--           actually is -- and it is what makes the two blue bulbs mean
--           something rather than being decoration.
local DRAG_STAGE_MODES = { hold = true, rollup = true }
-- How far behind the start position a rolled-up car is placed. Far enough to
-- creep, short enough that it is not a drive.
local DRAG_ROLLUP_BACK = 5.0
-- The beams, as a signed distance to the start position along its heading:
-- negative is short of the line. Pre-stage lights first, stage a little
-- further in, and rolling well past the line drops you out of the beams again
-- so a driver who overshoots can simply back up rather than being stuck
-- staged in the wrong place.
local DRAG_PRESTAGE_AT = -1.2
local DRAG_STAGE_AT    = -0.35
local DRAG_STAGE_PAST  =  2.0
-- Once every lane is in the beams, the pause before the tree drops. Not zero:
-- the last car to stage has earned the same half-second to settle its hands
-- that everybody else got, and a tree that fires on the same tick as the bulb
-- is a tree nobody was ready for.
local DRAG_STAGE_SETTLE = 1.2
local DRAG_TREE_PATTERNS = { pro = true, sportsman = true }
local DRAG_FORMATS = { single = true, double = true, points = true }
local DRAG_SEEDS   = { random = true, order = true, quali = true, manual = true }

-- ===========================================================================
-- State
-- ===========================================================================
-- THREE TABLES, not thirty locals. The same discipline the rest of the plugin
-- keeps, and here it also draws the seam the persistence file is written along:
-- `drag` is the RULES (what an admin set up), `ladder` is the TOURNAMENT (who
-- is in it and what has happened), `pass` is the RUN IN FRONT OF YOU. Only the
-- first two are worth saving -- a pass interrupted by a server restart is a
-- pass that has to be run again, and pretending otherwise would restore a
-- countdown to cars that are no longer staged.

local drag = {
  -- idle      no tournament: the config panel is all there is
  -- ready     a ladder exists and the next pass is waiting to be called
  -- staging   this pass's cars are being placed on their lanes and held
  -- tree      the lights are running
  -- running   the field is on the strip, times are coming in
  -- complete  somebody won it
  phase   = 'idle',
  -- HOW THE LADDER NARROWS.
  --   single   one loss and you are out
  --   double   two losses and you are out; the losers go to their own bracket
  --   points   nobody is knocked out by a single pass: every entrant runs every
  --            round, scores by finishing position, and the CUT (below) takes
  --            the bottom off the board between rounds
  format  = 'single',
  -- Cars per pass. Two is a drag race; eight is a shootout with everybody on
  -- the line at once. Clamped against the strip's start positions at build
  -- time, because a lane with nowhere to line up is not a lane.
  lanes   = 2,
  -- How many of those cars come out of the pass still in the tournament. One
  -- with two lanes is the classic ladder; four with eight lanes is "top half
  -- of the shootout goes through".
  --
  -- IT IS A CEILING, NOT A PROMISE. A pass with three cars in it cannot
  -- advance four, and the round that decides the tournament advances exactly
  -- one whatever this says. See passAdvanceCount.
  advance = 1,
  -- points format only: how many are cut from the BOTTOM of the standings
  -- after each round. 0 runs every entrant to the end and ranks them on total
  -- points, which is a series night rather than a knockout.
  cut     = 0,
  -- points format only: how many rounds it runs. Ignored by the ladders, whose
  -- length is decided by the field.
  rounds  = 3,
  tree    = 'sportsman',
  seed    = 'random',
  -- Roll-up by default, because it is what a drag strip does and it is the
  -- reason the pre-stage and stage bulbs exist. 'hold' is one press away for
  -- a shootout that wants the field placed and frozen.
  stageMode = 'rollup',
  -- rollup only: does the tree drop by itself once every lane is in the
  -- beams, the way a starter does it, or does an admin press Run?
  --
  -- BOTH ARE USEFUL, which is why this is a setting rather than a decision.
  -- Automatic is the real thing and takes the admin out of the loop for a
  -- forty-pass evening; manual is what you want the first time you run a new
  -- strip, or when somebody is still explaining the rules on voice comms.
  --
  -- RUN IS ALWAYS AVAILABLE EITHER WAY. Under automatic it is an override for
  -- the driver who will not stage, which is the same job the courtesy-stage
  -- rule does at a real strip.
  autoStart = true,
  -- rollup only: how long the pass waits for the field to stage before the
  -- tree drops on whoever is in the beams. A car still creeping at that point
  -- is simply late, which is a result rather than a deadlock -- and an
  -- unattended server must not be able to sit on one pass for ever.
  stageWait = 45,
  -- BRACKET RACING, in the sense the drag strip means it rather than the
  -- tournament-tree sense. Every entrant declares a DIAL-IN -- the elapsed
  -- time they expect to run -- and the slower car is given that difference as
  -- a head start, so a street car and a race car can meet on equal terms. Run
  -- quicker than your own dial and you BREAK OUT, which loses the pass.
  --
  -- Off by default: it needs every entrant to have a dial, and a ladder run
  -- without it is the heads-up race everyone already expects.
  dialIn   = false,
  breakout = true,   -- dialIn only: does running under your dial lose the pass?
  timeout  = 60,
  -- Seconds the result stands on screen before the ladder offers the next
  -- pass. The derby has had one of these since it was built; a pass is over in
  -- ten seconds and without a hold the board would blink through a whole round.
  holdResult = 8,
}

local ladder = {
  -- Entrants in SEED ORDER, which is the order the bracket is built from and
  -- never changes once the ladder is built. Each entry:
  --   id       BeamMP player id, or nil once they have disconnected
  --   name     the name they entered under, kept so a disconnected entrant is
  --            still a person on the board rather than a hole in it
  --   seed     1..n, their place in the draw
  --   wins/losses/passes  their record
  --   status   'in' | 'out' | 'champion' | 'withdrawn'
  --   outRound which round knocked them out, for the finishing order
  --   dial     bracket racing: their declared elapsed time
  --   bestET / bestRT / bestSpeed / lastET / lastRT / lastSpeed
  --   points   points format only: running total
  entrants = {},
  -- Rounds, oldest first. Each is
  --   { n, side = 'w'|'l'|'f', label, passes = { ... }, done }
  -- and each pass is
  --   { lanes = { seedIndex, ... }, bye, done, results = { ... }, winner }
  --
  -- GENERATED ONE ROUND AT A TIME, never as a whole tree up front. A double
  -- elimination bracket's losers side depends on who lost, byes depend on how
  -- many are left, and a driver who disconnects mid-tournament changes both --
  -- so a tree drawn at the start would be wrong by the second round and would
  -- have to be redrawn anyway. Building the next round when the current one
  -- ends is the same answer with none of the redrawing.
  rounds   = {},
  round    = 0,   -- index into rounds; 0 before the first is built
  pass     = 0,   -- index into that round's passes; 0 before the first is called
  champion = nil, -- display name, once there is one
  started  = nil, -- os.time() the ladder was built
  -- The tournament is over and this is what it looked like. Held rather than
  -- recomputed because entrants leave: the finishing order has to be the one
  -- that was true when the last pass ran.
  finishOrder = nil,
}

-- The pass in front of you, or an empty shell between passes. Rebuilt from
-- scratch every time rather than cleared field by field, because a stale field
-- from the last pass is exactly the bug the derby's endsAt note describes.
local pass = { lanes = {}, times = {}, time = 0, greenAt = nil }

-- A PRACTICE PASS: one run down the strip that scores nothing.
--
-- It exists for two reasons and both are real. A bracket needs a field, so
-- until one turns up there is no way to try the strip at all -- no staging, no
-- tree, no red light, no elapsed time -- and "does the finish line work" should
-- not be a question you need eight people to answer. And in bracket racing a
-- driver has to declare a dial-in before they run, which on a strip they have
-- never seen is a guess; a practice pass is where the number comes from.
--
-- It runs the REAL pass machinery -- the same staging, the same tree, the same
-- timing, the same ranking -- against a round that is deliberately NOT in
-- ladder.rounds. That is the whole trick: nothing has to know it is practice
-- except the three places that would otherwise write a result down.
local practice = { on = false, round = nil }

-- The round the pass in front of you belongs to. A practice round is not part
-- of the ladder and never will be, so every reader goes through here rather
-- than reaching into ladder.rounds and finding the wrong one.
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

-- Seconds as a drag strip reads them: three decimals, because the third one is
-- the one that decides passes. A DNF has no time and says so rather than
-- printing a zero somebody will read as a very good run.
local function fmtET(t)
  if not t then return '--' end
  return string.format('%.3f', t)
end

local function fmtSpeed(v)
  if not v then return '--' end
  return string.format('%.1f', v)
end

-- Is there a pass on the strip right now? 'result' counts: the cars are still
-- sitting at the top end while the board holds the times up, and every rule
-- this gates -- config changes, dial changes -- would be changing a pass that
-- has already been run.
local function dragActive()
  return drag.phase == 'staging' or drag.phase == 'tree'
      or drag.phase == 'running' or drag.phase == 'result'
end

-- The lazy seed, exactly as main.lua does it for the random grid draw. Two
-- ladders drawn in the same second is not a fairness problem, and nothing else
-- on the server depends on the stream.
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

-- How many lanes the loaded strip actually has. The layout owns this: an admin
-- who saved four start positions built a four-wide strip, and asking for eight
-- does not make four more appear.
--
-- Reads race.startPositions, which is the ONLY thing this module reads from the
-- host's racing state -- and it is a read of the loaded TRACK, not of a
-- session. Nothing here writes it.
local function stripLanes()
  return #(race.startPositions or {})
end

-- The finish line is the last gate of the loaded layout, and the strip needs at
-- least one gate to have one. Returned as a count rather than the gate itself:
-- the server has no physics and never tests a crossing, so all it can usefully
-- do is refuse to start a tournament on a track with no finish.
local function stripGates()
  return race.slotCount or 0
end

-- ===========================================================================
-- THE DRAW
-- ===========================================================================
-- Splitting a seeded field into passes, the way a bracket sheet does it.
--
-- SERPENTINE, not "first `lanes` in the first pass". Walk the seeds in order,
-- filling the passes left to right, then right to left, then left to right
-- again. With two lanes that produces exactly the classic sheet -- 1 v 8, 2 v
-- 7, 3 v 6, 4 v 5 -- and with eight it spreads the quick cars across the
-- shootouts instead of stacking the top half into one of them.
--
-- It also gets the BYES right for free. Three cars over two passes leaves the
-- first pass holding one seed, and that seed is number one: the strongest
-- entrant is the one the sheet gives the free run to, which is the rule every
-- ladder uses and the one nobody has to be told.
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

-- How many cars come out of this pass still in the tournament.
--
-- Three rules, and the order matters. A pass that is the whole of what is left
-- decides the tournament and advances exactly one, whatever the admin set. A
-- bye advances its single entrant. Otherwise the admin's number applies, capped
-- so a pass always eliminates somebody -- advancing four from a pass of three
-- is a round that changes nothing, run forever.
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
-- FOUR TIERS, and no time in a lower tier ever beats one in a higher.
--
--   1  a clean run
--   2  a BREAKOUT: quicker than your own dial-in, which is a loss in bracket
--      racing however fast it was. Between two of them the one who broke out by
--      the LESS takes it, which is the actual rule and not a tie-break
--   3  a RED LIGHT: left before the green. Still a run, still gets a time on
--      the board, still loses to anybody who left legally
--   4  no time at all: never finished, or the pass timed out under them
--
-- Inside tiers 1 and 3 the order is WHO GOT THERE FIRST, measured as the head
-- start their dial-in bought them plus their reaction plus their elapsed time.
-- With no dial-ins that is just reaction plus ET, which is the same question.
-- Every number in it was measured by the client that ran it, on one clock, so
-- nothing here is comparing two machines' idea of when the green was.
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
-- One channel, RM_DragUpdate, carrying the whole tournament. The panel is a
-- board -- entrants, the ladder, the pass in front of you -- and a board that
-- arrives in pieces is a board that can be caught disagreeing with itself.
--
-- The ladder is sent WHOLE rather than as a diff for the same reason the racing
-- driver table is: a client that joined mid-tournament, or reconnected, or
-- missed a packet has no way to ask for the piece it is short of, and a
-- tournament is at most a few dozen small rows.
local function entrantRow(e)
  return {
    seed = e.seed, name = e.name, status = e.status,
    wins = e.wins, losses = e.losses, passes = e.passes,
    dial = e.dial, points = e.points, outRound = e.outRound,
    bestET = e.bestET, bestRT = e.bestRT, bestSpeed = e.bestSpeed,
    lastET = e.lastET, lastRT = e.lastRT, lastSpeed = e.lastSpeed,
    -- Present on the server right now. A tournament runs for an evening and
    -- people drop out of it; a board that cannot show who is missing is a board
    -- an admin has to guess against before calling the next pass.
    online = e.id ~= nil,
    -- THE SESSION ID, and it rides along for exactly one reason: this is ONE
    -- broadcast to everybody, so it cannot say "you". The client compares it
    -- against its own id and marks its own row before handing the board to the
    -- panel -- which is where the answer lives, since the server has no way to
    -- personalise a message it sends once. The racing driver table carries ids
    -- for the same reason.
    id = e.id,
  }
end

-- `live` is the times table of a pass that is still running, and it is the
-- whole reason this takes an argument.
--
-- A finished pass keeps its numbers in p.results, which is written when the
-- pass settles. Reading only that meant the board showed nothing at all WHILE
-- the pass was on -- lanes coming home one at a time, and a panel that stayed
-- blank until the last of them did. Watching the times land is most of what a
-- drag board is for.
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
      -- A LANE IS ONLY DNF ONCE IT HAS BEEN SETTLED. Mid-pass, a car with no
      -- time is a car still driving -- calling that a DNF would put the word on
      -- the board over every driver for the whole of every run.
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

-- The pass in front of you, as the staging lights see it. Separate from the
-- board row above because this one carries the LIVE fields -- who is staged,
-- how long the pass has run -- which mean nothing on a finished pass and would
-- be dead weight on every row of the ladder.
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
    -- The near bulb, reported separately: a driver creeping up shows
    -- pre-staged for a second or two before the stage bulb catches, and that
    -- is the part everybody in the pits is watching.
    lane.prestaged = pass.prestaged and pass.prestaged[i] == true
    lane.home   = pass.times and pass.times[i] ~= nil
    -- THE RED LIGHT SHOWS THE MOMENT IT HAPPENS, not when the pass settles. It
    -- is reported at the launch and the time at the finish, so between the two
    -- the foul lives only here -- and the seconds where everybody in the pits
    -- wants to know whether that light was red are exactly those.
    if pass.fouled and pass.fouled[i] and not lane.foul then
      lane.foul = true
      lane.rt   = lane.rt or pass.fouled[i]
    end
  end
  return row
end

-- THE PASS ONLY, without the ladder underneath it.
--
-- A lane reporting its time changes one row and nothing else, and there are up
-- to eight of them in the fifteen seconds a pass takes. The full board is not
-- small: a sixty-four car single elimination is sixty-three passes and a
-- hundred and twenty-six lane rows, and encoding all of it eight times over
-- while cars are on the strip is the kind of cost this plugin has learned to
-- watch for elsewhere (see the note on the results file and a huge grid).
--
-- So a lane report sends the live pass and the phase, and leaves `board` and
-- `entrants` OUT. The client keeps whatever it last had for those -- they have
-- not changed -- and the full state goes out when the pass settles, which is
-- when they do.
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
    -- Whether what is on the strip is a PRACTICE pass. The panel has to be able
    -- to say so plainly: the controls look identical, and a warm-up mistaken
    -- for a round of the tournament is the worst thing to be unsure about while
    -- sitting on the line.
    practice = practice.on,
    entrants = entrants, board = boardRows(), current = livePass(),
  }))
end

-- ===========================================================================
-- Persistence
-- ===========================================================================
-- A tournament is an evening, not a session. Sixteen entrants over four rounds
-- is an hour of racing, and losing the ladder to a server restart in the middle
-- of it means running the whole thing again, so it is written to disk on every
-- change, exactly the way the cup is.
--
-- WHAT IS NOT SAVED is the pass in front of you. A pass interrupted by a
-- restart is a pass that has to be run again: the cars are no longer staged,
-- the tree is no longer running, and restoring a countdown to an empty strip
-- would be worse than admitting the pass was lost. The ladder comes back at the
-- pass boundary before it.
--
-- ENTRANTS COME BACK BY NAME, NOT BY PLAYER ID. BeamMP recycles session ids and
-- hands out a fresh guest name on every join, so neither is an identity. The id
-- is guaranteed to be wrong after a restart; the name is at least what the
-- board said. A restored entrant nobody on the server answers to is kept, shown
-- offline, and can be withdrawn or claimed by hand. The alternative is a ladder
-- full of holes an admin has no way to fix.
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
                            -- WITHOUT THIS a restored final settles as an
                            -- ordinary round: it would advance `advance`
                            -- entrants instead of one, and the double
                            -- elimination reset would never be offered.
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

-- Rehydrate. Rounds hold SEED NUMBERS on disk and entrant tables in memory, so
-- the load has to resolve one into the other, and a seed that does not resolve
-- drops the pass rather than putting a nil in a lane. A nil lane is the sort of
-- thing that only shows up at staging, with the field already waiting.
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
  -- ONLINE ENTRANTS ARE RE-BOUND AT BOOT, and this is the only place a restored
  -- name is matched against a live player. Nobody is connected during onInit on
  -- a cold start, so in practice this only does anything after a plugin reload
  -- with the field still on the server, which is exactly when it matters.
  if #ladder.entrants > 0 then dragEntryListChanged() end
end

-- ===========================================================================
-- THE LADDER
-- ===========================================================================
-- Rounds are built ONE AT A TIME, as the one before them ends. See the note on
-- ladder.rounds for why: a tree drawn up front is wrong by the second round.
--
-- Everything below is pure bookkeeping over the entrant list. Nothing here
-- touches a car, a client or a timer, which is what makes the whole tournament
-- testable headless -- tests/drag_test.lua runs a sixteen-entrant ladder to a
-- champion without a single vehicle existing.

-- Is this the round that decides it? The whole remaining field fits in one
-- pass, so there is nothing left to narrow.
--
-- Stated as a question about the FIELD rather than about the round, because
-- that is what makes it true for every format at once: two cars with two lanes
-- is a final for the same reason six cars with eight lanes is.
local function isFinalField(live)
  return #live <= drag.lanes
end

local function roundLabel(side, live, final)
  -- Side 'f' is the round the two brackets MEET IN, which happens at most
  -- twice: the final, and the reset when the entrant who arrived undefeated
  -- loses it. Both are side 'f' because both draw from the whole remaining
  -- field, so the reset is renamed by its caller rather than guessed at here --
  -- naming every 'f' round a reset labelled the ordinary final as one.
  if side == 'f' then return 'Final' end
  local n = #ladder.rounds + 1
  if drag.format == 'points' then
    return 'Round ' .. n .. ' of ' .. drag.rounds
  end
  if side == 'l' then
    return final and 'Losers Final' or ('Losers Round ' .. n)
  end
  if final then return 'Final' end
  -- ...and in a double, the round that halves the winners bracket is NOT the
  -- one that produces the finalists: the losers side still has to feed one in.
  -- Calling it the semifinal would promise a final two rounds early.
  if drag.format == 'double' then return 'Winners Round ' .. n end
  -- SEMIFINAL is a fact about what this round produces, not a name for a round
  -- number: how many come out of it, and do they fit one pass? A four-lane
  -- strip reaches its semifinal a round earlier than a two-lane one, and
  -- calling both of them "Round 3" tells a driver nothing.
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
      -- A BYE IS A PASS, not a line on a sheet. The entrant still stages, still
      -- runs, still puts an ET on the board -- they simply cannot lose it. Drag
      -- racing has always worked this way, because a bye run is where you go
      -- looking for a number without risking the round.
      bye = #g == 1, done = false, results = nil, delay = nil,
    }
  end
  ladder.rounds[#ladder.rounds + 1] = r
  ladder.round = #ladder.rounds
  -- POINTED AT THE FIRST PASS, not at nothing. A round that has been drawn but
  -- not started still has a pass that is up next, and an admin wants to read
  -- who is in it before pressing Stage -- so a fresh round shows its first pass
  -- rather than a blank panel that only fills in once the cars are placed.
  ladder.pass  = 1
  return r
end

-- The order a pool is drawn in. Seed order for the ladders, because the seed is
-- the whole point of a seeded draw and re-sorting it on form would undo it.
-- Points runs on the standings instead: everybody races every round, so the
-- draw is the only place the leaderboard can shape the night.
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
    -- The reset. Somebody arrived at the final undefeated and did not win it,
    -- so they have spent the second life the format promised them and the two
    -- of them go again on level terms.
    if ladder.resetPending then
      ladder.resetPending = false
      pushRound('f', { drawOrder(live) }, true, live).label = 'Final (reset)'
      return true
    end
    local won, lost = undefeated(), inLosers()
    -- The final needs BOTH brackets down to what fits one pass. With the
    -- winners side still holding two or more, a pass between them is a winners
    -- round however few are left overall.
    if isFinalField(live) and #won <= 1 then
      pushRound('f', { drawOrder(live) }, true, live)
      return true
    end
    -- Alternate the two sides, which is what keeps the losers bracket from
    -- piling up into one enormous round at the end. Whichever side cannot run
    -- (fewer than two entrants) hands the round back to the other.
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
    -- Neither side can field a pass and the field does not fit one either.
    -- Reachable only through withdrawals, and it is a finished tournament
    -- rather than a stuck one.
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
-- Every number in `results` was measured by the client that ran the lane. This
-- is where they become a place in a tournament.
-- BEING KNOCKED OUT DOES NOT COST YOU YOUR CAR, and that is the difference
-- between a tournament and a derby.
--
-- A derby is one event and ends within minutes of your elimination, so standing
-- a knocked-out driver down until it does costs them nothing. A ladder runs for
-- an hour: losing in round one and being locked in freecam for the next forty
-- minutes is not a rule, it is a punishment for turning up. Somebody who is out
-- is simply never called for another pass.
--
-- What IS enforced is the strip while a pass is on it -- see stagePass, which
-- stands down everybody who is not in the pass and releases them when it ends.
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
  -- A PRACTICE PASS IS RANKED AND THEN FORGOTTEN. It is timed exactly the way a
  -- real one is -- somebody has to be able to see who got there first, and a
  -- breakout is worth knowing about before it costs a round -- but no win, no
  -- loss, no elimination and no best-ever number comes out of it. The entrants
  -- in it are throwaway records anyway (see RM_onDragPractice); writing to them
  -- would be writing to nothing, and writing to the LADDER's records instead
  -- would let a warm-up lap improve a tournament stat.
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
    -- BEST is best-EVER, across the whole tournament, and a red light does not
    -- poison it: the ET was still run, and a driver who left early still went
    -- down the strip. Only a pass with no time at all has nothing to record.
    if t.et and (not e.bestET or t.et < e.bestET) then e.bestET = t.et end
    if t.rt and t.rt > 0 and (not e.bestRT or t.rt < e.bestRT) then e.bestRT = t.rt end
    if t.speed and (not e.bestSpeed or t.speed > e.bestSpeed) then e.bestSpeed = t.speed end
    if i == 1 then e.wins = e.wins + 1 end
    if drag.format == 'points' then
      -- Scored on the CONFIGURED lane count rather than on how many happened to
      -- be in this pass, so winning a short pass is worth exactly what winning
      -- a full one is. Nobody should be better off for a thin round.
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
      -- A FINAL ELIMINATES EVERYBODY WHO DID NOT WIN IT, with one exception
      -- that is the whole of what double elimination means: an entrant who
      -- arrived undefeated has a life left, keeps it, and gets the reset.
      if isFinal and e.losses < limit then
        ladder.resetPending = true
      elseif isFinal or e.losses >= limit then
        eliminate(e, r.n, 'Knocked out in ' .. r.label)
      end
    end
  end
  p.done = true
end

-- The bottom of the board goes home. Points format only: the ladders knock
-- people out a pass at a time, and this is the equivalent for a format where
-- losing a pass costs you points rather than your place in the tournament.
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
-- A tournament produces a WHOLE ORDER, not just a winner. Read the ladder
-- backwards: whoever is still in comes first, then the round that knocked you
-- out (later is better), then how many passes you won, then the seed you
-- started from.
--
-- Points is ranked on points and nothing else until the tie-breaks, because
-- that is what the format is.
-- THE FINISHING ORDER, as entrant tables. Both the results file and the cup
-- read this, and they must not disagree: one sort, one answer, two consumers.
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

-- What the cup is handed. The entrant records themselves, in finishing order,
-- with the ALIAS re-read live from the racing record rather than used as
-- snapshotted -- a name an admin assigned or cleared during the tournament has
-- to reach the standings, and a stamped value would go sticky. Exactly what the
-- derby's classification does, and for the same reason.
--
-- The last alias we knew is kept for a driver who has since left: nulling it
-- would score their season onto a fresh placeholder they can never be joined
-- back to.
local function dragClassification()
  local list = finishOrderList()
  for _, e in ipairs(list) do
    local owner = e.id and players[e.id] or nil
    if owner then e.alias = owner.alias end
  end
  return list
end

-- The quickest single pass anybody made all meeting, and who made it.
--
-- A RED LIGHT STILL COUNTS. The car went down the strip and the clocks caught
-- it; leaving early lost that pass and says nothing about the time. Low ET of
-- the meet is a fact about the run, not a reward for a clean one.
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
  -- A drag tournament banks a cup round exactly as a race and a derby do, so
  -- its results file carries the same section in the same layout. A league
  -- reading three files from one evening should not have to learn three
  -- formats.
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
  -- Score it into the cup, if one is running and it pays for drag racing. The
  -- classification is handed over rather than the cup coming to fetch it, so
  -- this module's tables stay private and the cup goes on being a consumer of
  -- results exactly as it is for a race. Does nothing unless a cup is running.
  --
  -- The round it banks is carried into the results file for the reason the
  -- other two carry theirs: a cup at its round cap scores nothing, and a file
  -- that asked for "the current round" would print the last event's points.
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
-- Three admin presses per pass: Stage puts the cars on their lanes and holds
-- them, Run drops the tree, and the result settles itself. The same shape the
-- derby uses (Form Up, Start) and the races use (Generate Grid, Start
-- Countdown), because an admin should not have to learn a third one.

-- How long the lights take, in seconds, from the moment Run is pressed.
--
-- The PRE-ROLL is randomised and is the reason the tree is worth having: a
-- fixed delay is a number a driver learns, and a driver who has learned it is
-- not reacting to anything. It is drawn HERE and sent to every lane, so all of
-- them see the same tree -- a per-client random would hand somebody a shorter
-- one.
-- THE FLOOR IS 1.5s AND IT IS LOAD-BEARING, not a rounded-off taste call. The
-- client stands the field on its lanes with the same staggered placement the
-- racing grid uses -- 0.18s a lane -- so an eight-wide field is still landing
-- 1.26s after Stage was pressed. The hold does not come off and the launch is
-- not measured until this driver's own first amber, so the pre-roll is what
-- that lands inside. Shorten it and a car released mid-flight reads as having
-- launched, which is a red light nobody earned.
local DRAG_TREE_PREROLL_MIN = 1.5
local DRAG_TREE_PREROLL_MAX = 2.5
local DRAG_TREE_PRO         = 0.4   -- three ambers together, green 0.4s later
local DRAG_TREE_SPORTSMAN   = 1.5   -- ambers 0.5s apart, green 0.5s after

local function treeLightsFor(pattern)
  return pattern == 'pro' and DRAG_TREE_PRO or DRAG_TREE_SPORTSMAN
end

-- THE HEAD START EACH LANE IS OWED, in seconds.
--
-- Bracket racing in the drag strip sense: everybody declares the elapsed time
-- they expect to run, and the SLOWER car leaves first by exactly the difference
-- between the two dials. Run your own number and you arrive together, which is
-- the whole idea -- a street car and a race car can meet on equal terms and the
-- pass is decided by who drove better, not by who bought more engine.
--
-- Returned as a delay applied AFTER the green: the biggest dial waits zero, and
-- everybody else waits until their own difference has run off.
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
    -- NO DIAL IS NO HEAD START, deliberately. An entrant who never set one is
    -- treated as the quickest car on the property and leaves last, which is the
    -- outcome that cannot be gamed by simply not answering.
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

-- The next pass in this round that has not been run, or nil when the round is
-- done. Scanned rather than incremented, so an aborted pass is offered again
-- instead of being skipped.
local function nextPassIndex()
  local r = activeRound()
  if not r then return nil end
  for i, p in ipairs(r.passes) do
    if not p.done then return i end
  end
  return nil
end

local settlePass  -- assigned below; the tick and the reports both reach it

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
  -- THE STRIP IS CLOSED WHILE A PASS IS ON IT. Everybody who is not in this one
  -- stands down until it settles -- the drivers already knocked out, the ones
  -- waiting for a later pass, and anybody who wandered in to watch.
  --
  -- Scoped to the pass rather than to the tournament, which is the whole point:
  -- between passes every one of them has their car back. Scoped to the 'drag'
  -- source too, so a racing DNF's own spectator lock is neither lifted nor
  -- imposed by any of this.
  local inPass = {}
  for _, e in ipairs(p.lanes) do
    if e.id then inPass[e.id] = true end
  end
  for id in pairs(onlinePlayers()) do
    if not inPass[id] then
      forceSpectate(id, 'A drag pass is on the strip', 'drag')
    end
  end
  local rollup = drag.stageMode == 'rollup'
  for i, e in ipairs(p.lanes) do
    if e.id then
      -- UNDER 'HOLD' THE CAR IS STAGED THE MOMENT IT IS PLACED. There is
      -- nothing for the driver to do and nothing to wait for, so the bulbs
      -- are lit from the start and Run is live immediately. Under 'rollup'
      -- nobody is staged yet: the client reports it when the car reaches the
      -- beams.
      pass.staged[i] = not rollup
      pass.prestaged[i] = not rollup
      MP.TriggerClientEvent(e.id, 'RM_DragLane', Util.JsonEncode({
        lane = i, slot = i, count = #p.lanes,
        -- The freeze and the roll-up are the same decision seen twice: a car
        -- that is held cannot creep, and a car that must creep cannot be held.
        hold = not rollup, rollup = rollup,
        back = rollup and DRAG_ROLLUP_BACK or nil,
        prestageAt = rollup and DRAG_PRESTAGE_AT or nil,
        stageAt = rollup and DRAG_STAGE_AT or nil,
        stagePast = rollup and DRAG_STAGE_PAST or nil,
        dial = e.dial, delay = p.delay[i],
      }))
    else
      -- OFFLINE ENTRANTS ARE ALREADY DNF, before the tree has even run. There is
      -- nobody to stage and nobody to time, and leaving the lane pending would
      -- hold the whole pass open until the timeout for a car that does not
      -- exist.
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
  -- The tick runs through STAGING too under roll-up: something has to notice
  -- that the field is in the beams, and something has to give up waiting.
  if rollup then MP.CreateEventTimer('RM_DragTick', DRAG_TICK_MS) end
  broadcastDragState()
  return true
end

-- Is every lane that can stage actually staged?
--
-- A lane with nobody in it is not counted: it was written off at staging (see
-- above) and waiting for a car that does not exist would hold the pass to its
-- timeout every time somebody dropped out.
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

-- Drop the tree. The lights RUN ON THE CLIENT, not here, and that is a
-- deliberate trade rather than a shortcut.
--
-- A reaction time is the gap between the green coming on and the car leaving,
-- and it is decided in the third decimal place. Timing that from the server
-- would measure the network: whoever was furthest from the box would post the
-- worst light regardless of how they drove. So the server sends the SHAPE of
-- the tree -- the pattern, the pre-roll it drew, and this lane's head start --
-- and each client runs its own lights and measures its own reaction against
-- them, on one clock, the same way it already times its own laps.
--
-- What that costs is that two clients start their trees a few tens of
-- milliseconds apart, so the cars are not exactly level on screen. What it buys
-- is that the numbers the pass is decided on were all measured the same way.
-- For a drag race, where the lanes never interact, that is the right way round.
local function runPass()
  local p, r = currentPass()
  if not p then return false end
  seedOnce()
  local preroll = DRAG_TREE_PREROLL_MIN
    + math.random() * (DRAG_TREE_PREROLL_MAX - DRAG_TREE_PREROLL_MIN)
  pass.tree = preroll + treeLightsFor(drag.tree)
  drag.phase = 'tree'
  pass.time = 0
  for i, e in ipairs(p.lanes) do
    if e.id then
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
    -- A LANE THAT RED-LIGHTED AND THEN NEVER GOT THERE is still a red light.
    -- The foul is reported at the launch and the result at the finish, so a car
    -- that fouled and then failed to finish has one and not the other; without
    -- this the board records it as an ordinary no-show and the reason it lost
    -- disappears. It changes no outcome -- both are the bottom tier -- and it
    -- is the difference between a result and an explanation.
    if not t.foul and pass.fouled and pass.fouled[i] then
      t.foul = true
      t.rt = t.rt or pass.fouled[i]
    end
    -- The moment this car got there, measured from the green the whole pass
    -- shared: the head start its dial bought it, plus how long it sat, plus how
    -- long the run took. With no dial-ins the first term is zero for everybody
    -- and this is simply reaction plus ET.
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
  MP.SendChatMessage(-1, string.format('[RaceManager] Drag %s pass %d: %s takes it (%s / %s)%s',
    r.label, ladder.pass, top and top.entrant.name or '?',
    top and fmtET(top.rt) or '--', top and fmtET(top.et) or '--',
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
  -- A practice pass is one pass and then over. It leaves the ladder exactly
  -- where it found it, which is the point: an admin can run one between rounds
  -- to let somebody re-dial without the tournament noticing.
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
    -- HOLD MODE HAS NOTHING TO WAIT FOR and must never start itself. Its cars
    -- are staged the instant they are placed, so an automatic start would fire
    -- the tree on the same tick as the placement -- a green light for a field
    -- that is still landing.
    --
    -- Checked here rather than relying on stagePass not creating the timer.
    -- "It is safe because nothing calls it" is not a rule, it is a coincidence
    -- waiting for the next caller, and this branch already has three.
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
      -- THE TREE DROPS ON WHOEVER IS IN THE BEAMS. A car still creeping is
      -- late, which is a result rather than a deadlock -- and an unattended
      -- server must not be able to sit on one pass for ever.
      MP.SendChatMessage(-1, '[RaceManager] Drag: courtesy stage expired, the '
        .. 'tree is coming down.')
      runPass()
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
-- The field is snapshotted ONCE, when the admin builds it, and never re-read.
-- A tournament whose entry list drifted under it would redraw its own bracket
-- every time somebody joined the server to watch.
local function shuffle(list)
  seedOnce()
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
end

-- Everyone the ladder could be drawn from: connected, and not sitting it out.
-- Same entry rule the races and the derby use, and for the same reason -- a
-- driver who has never pressed anything has not opted out of anything.
local function candidates()
  local list = {}
  for id in pairs(onlinePlayers()) do
    local rec = players[id]
    if (not rec) or isEntrant(rec) then
      list[#list + 1] = {
        id = id,
        name = rec and displayName(rec) or (MP.GetPlayerName(id) or ('Player ' .. id)),
        -- THE ALIAS, carried separately from the name the board shows. The cup
        -- identifies a driver through the roster, and the roster matches on the
        -- display name an admin typed -- never on the BeamMP guest name, which
        -- is reissued at random on every join and identifies nobody. Without
        -- this a tournament would score every round against a fresh
        -- placeholder.
        alias = rec and rec.alias or nil,
        -- The qualifying time this driver set on the strip, if a session was
        -- run on it. A point-to-point layout timed once IS a qualifying pass,
        -- so seeding a ladder off it needs nothing new -- and with dial-ins on
        -- it is also the honest first guess at somebody's number.
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
    -- A HAND DRAW WITH NO HAND IN IT IS NOT A RANDOM ONE. The order arrives
    -- with the build; if none came, fall back to join order rather than to the
    -- shuffle -- an admin who chose to seed the ladder themselves and then got
    -- a random draw has been given the one thing they ruled out.
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
  -- ADVANCE CANNOT REACH THE LANE COUNT. Advancing everybody out of a pass is a
  -- round that narrows nothing, and the ladder would run until the round cap
  -- stopped it. Applied after both assignments so it wins in either order.
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
  -- THE STRIP HAS TO EXIST FIRST. Everything below assumes a finish line to
  -- cross and a lane to line up in, and neither of them is this module's to
  -- create -- they arrive with the loaded track layout.
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

-- ONE PASS DOWN THE STRIP THAT SCORES NOTHING.
--
-- Everybody eligible, up to the lane count, staged and timed exactly as a real
-- pass is. Two presses instead of three -- Practice puts them on the line, Run
-- drops the tree -- because a warm-up should not need the ceremony a round of
-- the tournament does.
--
-- It works with ONE driver, which is most of why it exists: a bracket needs a
-- field, and until one turns up there is otherwise no way to find out whether
-- the finish line is where you think it is. The other reason is the dial-in --
-- declaring the time you expect to run, on a strip you have never seen, is a
-- guess until you have made a pass down it.
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
  -- Capped by the lanes the STRIP has rather than by the configured lane count:
  -- a practice pass is about the strip, and warming up should not mean editing
  -- the tournament rules first.
  local room = math.min(stripLanes(), DRAG_MAX_LANES)
  local lanes = {}
  for i = 1, math.min(#list, room) do
    local c = list[i]
    -- THROWAWAY RECORDS, not the ladder's. A practice pass writes nothing down,
    -- so these live for one run and are dropped. The DIAL is copied off the
    -- ladder entry when there is one, because running a handicap start is one of
    -- the things people practise.
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
  runPass()
end

-- Wave a pass off. Nothing is scored, the cars go back, and the same pass is
-- offered again -- which is what nextPassIndex scanning rather than
-- incrementing is for.
function RM_onDragAbort(pid)
  if not requireAuth(pid) then return end
  if drag.phase ~= 'staging' and drag.phase ~= 'tree' and drag.phase ~= 'running' then return end
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
  MP.SendChatMessage(-1, '[RaceManager] Drag pass waved off. Re-staging.')
  print('[RaceManager] Drag pass aborted by ' .. (MP.GetPlayerName(pid) or pid))
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

-- Pull an entrant out. Their remaining passes are walkovers for whoever else is
-- in them, which is the honest outcome: the alternative is a lane that never
-- reports and a pass that runs to its timeout.
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

-- A car reached the beams, or left them.
--
-- ONLY THE CLIENT CAN KNOW THIS. The beams are a distance from the start
-- position measured along its heading, and this server has no physics and no
-- idea where any car is -- the same division of labour the lap timer and the
-- finish line already use.
--
-- Reported on CHANGE rather than every frame: two booleans over a network at
-- sixty hertz would be sixty times the traffic for a fact that moves twice.
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

-- A red light, reported the moment it happens so the board can light the bulb
-- while the car is still going down the strip. The RUN still counts: a foul is
-- a losing pass, not a cancelled one, and the driver still puts an ET up.
function RM_onDragFoul(pid, rawData)
  if drag.phase ~= 'tree' and drag.phase ~= 'running' then return end
  local rt = nil
  if type(rawData) == 'string' and rawData ~= '' then
    local ok, data = pcall(Util.JsonDecode, rawData)
    if ok and type(data) == 'table' then rt = tonumber(data.rt) end
  end
  -- MATCHED AGAINST THE LANES, not against the entrant list. A practice pass
  -- has no entrants -- its lanes are throwaway records that were never added to
  -- the ladder -- so looking the sender up there found nobody and the report
  -- was dropped on the floor. The lane is what a result belongs to anyway.
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
      -- BREAKING OUT is only a thing when there is a dial to break out of, and
      -- only when the rule is switched on. Decided HERE rather than on the
      -- client, so a client cannot decide it did not happen.
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
    -- Whether what is on the strip is a PRACTICE pass. The panel has to be able
    -- to say so plainly: the controls look identical, and a warm-up mistaken
    -- for a round of the tournament is the worst thing to be unsure about while
    -- sitting on the line.
    practice = practice.on,
    entrants = entrants, board = boardRows(), current = livePass(),
  }))
end

-- Somebody joined, left, or changed their mind about racing. The ladder does
-- NOT redraw itself -- the field was snapshotted when it was built and that is
-- the point of a bracket -- but the ids have to follow the people.
dragEntryListChanged = function ()
  if #ladder.entrants == 0 then return end
  local online = onlinePlayers()
  local claimed = {}
  local changed = false
  for _, e in ipairs(ladder.entrants) do
    if e.id and not online[e.id] then e.id = nil; changed = true end
    if e.id then claimed[e.id] = true end
  end
  -- A NAME COMING BACK RECLAIMS ITS SEED. This is the one place a name is
  -- treated as an identity, and it is a deliberate, narrow exception: inside a
  -- tournament that is already running, the alternative to matching on the name
  -- is a driver who reconnected and can no longer race the ladder they are in.
  -- Nothing outside this file is bound by it, and no championship points hang
  -- on it -- see the roster's note on why automatic recognition is refused
  -- everywhere else.
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
  -- A LANE THAT HAS GONE HOME CANNOT REPORT, so it is DNF the moment the
  -- connection goes. Without this the pass sits open until it times out.
  -- Checked before the ladder, and separately from it, because a practice pass
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
