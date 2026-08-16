-- Load/performance test for server/RaceManager/main.lua.
--
-- A full grid running a long race is the shape this plugin has to survive: 20
-- drivers, 50 laps, an hour of wall clock, on a server that also has to run
-- BeamMP. The question this file answers is not "does it work" -- the other
-- tests cover that -- but "does it still work an hour in, and does it cost the
-- same at the end as it did at the start".
--
-- Three things are measured, because three different things can go wrong:
--
--   1. THROUGHPUT. Time per server tick and per state broadcast with a full
--      field, so the cost of a busy session is a number rather than a hope.
--   2. DRIFT. The same measurement early in a session and late in it, and
--      across a whole evening of back-to-back races. Work that grows with the
--      number of laps completed is invisible in a short test and fatal in a
--      long one.
--   3. LEAKS. Lua heap after a forced collection, once at the start and again
--      at the end. State that accumulates per lap (or per race) shows up here.
--
-- It also re-checks the leaderboard on every single broadcast: positions must
-- be 1..N, unique, with nobody missing. A sort comparator that is not a strict
-- weak ordering is allowed to raise "invalid order function" in Lua, and with a
-- full field of drivers on identical laps that is exactly the input that finds
-- it.
--
-- Unlike the other tests, Util.JsonEncode here is a REAL encoder. The mock in
-- the rest of the suite hands the table straight back, which is convenient for
-- assertions and would hide the entire cost of serialising a 20-driver payload
-- three times a second -- the single largest thing a broadcast does.
--
-- Run from the repo root: lua5.3 tests/stress_test.lua

local DRIVERS   = 20      -- a full BeamMP-sized grid
local LAPS      = 50      -- "as many laps as needed", and then some
local LAP_TICKS = 200     -- server ticks per lap (20 s at 100 ms), so the field
                          -- is genuinely circulating rather than teleporting
local PROGRESS_EVERY = 3  -- ticks between telemetry reports per driver (~3 Hz),
                          -- matching what the client bridge actually sends

local connected = {}
for i = 1, DRIVERS do connected[i] = string.format('Guest_%03d', i) end

local lastState   = nil
local broadcasts  = 0
local encodedBytes = 0
local harnessTime = 0   -- CPU spent decoding/auditing inside this file
local cupPushes   = 0   -- RM_CupUpdate messages seen

-- ---------------------------------------------------------------------------
-- A real JSON codec for the mock, so serialisation cost is measured.
-- ---------------------------------------------------------------------------
local function jsonEncode(v)
  local t = type(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'number' then return string.format('%.10g', v) end
  if t == 'string' then
    return '"' .. v:gsub('[%c"\\]', function (c)
      if c == '"' then return '\\"' end
      if c == '\\' then return '\\\\' end
      return string.format('\\u%04x', c:byte())
    end) .. '"'
  end
  if t == 'table' then
    local parts = {}
    if #v > 0 or next(v) == nil then
      for _, item in ipairs(v) do parts[#parts + 1] = jsonEncode(item) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, item in pairs(v) do
      if type(k) == 'string' then
        parts[#parts + 1] = jsonEncode(k) .. ':' .. jsonEncode(item)
      end
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

local function jsonDecode(text)
  if type(text) ~= 'string' then error('json: not a string', 0) end
  local pos = 1
  local function err(msg) error(('json: %s at %d'):format(msg, pos), 0) end
  local function ws() pos = text:match('^[ \t\r\n]*()', pos) end
  local parseValue
  local function parseString()
    pos = pos + 1
    local out = {}
    while true do
      local c = text:sub(pos, pos)
      if c == '' then err('unterminated string') end
      if c == '"' then pos = pos + 1; break end
      if c == '\\' then
        out[#out + 1] = text:sub(pos + 1, pos + 1)
        pos = pos + 2
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  parseValue = function ()
    ws()
    local c = text:sub(pos, pos)
    if c == '"' then return parseString() end
    if c == '{' then
      pos = pos + 1
      local obj = {}
      ws()
      if text:sub(pos, pos) == '}' then pos = pos + 1; return obj end
      while true do
        ws()
        local k = parseString()
        ws(); pos = pos + 1          -- ':'
        obj[k] = parseValue()
        ws()
        local sep = text:sub(pos, pos); pos = pos + 1
        if sep == '}' then return obj end
      end
    end
    if c == '[' then
      pos = pos + 1
      local arr = {}
      ws()
      if text:sub(pos, pos) == ']' then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parseValue()
        ws()
        local sep = text:sub(pos, pos); pos = pos + 1
        if sep == ']' then return arr end
      end
    end
    local lit = text:match('^true', pos) or text:match('^false', pos) or text:match('^null', pos)
    if lit then
      pos = pos + #lit
      if lit == 'true' then return true elseif lit == 'false' then return false end
      return nil
    end
    local num, nextPos = text:match('^(%-?%d+%.?%d*[eE]?[%+%-]?%d*)()', pos)
    if num then pos = nextPos; return tonumber(num) end
    err('unexpected character')
  end
  return parseValue()
end

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- The leaderboard audit, run on EVERY broadcast rather than at the end: a
-- position table that goes wrong for one tick in ten thousand is exactly the
-- kind of fault that never reproduces when you go looking for it.
local badBoards, boardsChecked = 0, 0
local function auditBoard(drivers)
  boardsChecked = boardsChecked + 1
  -- The invariant the app depends on, stated as strictly as it can be: the
  -- driver at index i carries position i. Nothing weaker will do.
  --
  -- assignPositions writes `rec.position = i` while walking the sorted array,
  -- so position IS the index and the wire array is built in that same order.
  -- That is what lets the leaderboard render the array as it arrives instead of
  -- re-sorting twenty rows on every digest -- which, on a low-end machine
  -- rendering three updates a second, is work worth not doing. If this ever
  -- stops holding, the table silently renders in the wrong order.
  for i = 1, #drivers do
    if drivers[i].position ~= i then
      badBoards = badBoards + 1
      return
    end
  end
end

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (_, event, payload)
    if event == 'RM_CupUpdate' then cupPushes = cupPushes + 1 end
    if event == 'RM_Update' then
      broadcasts = broadcasts + 1
      encodedBytes = encodedBytes + #payload
      -- Decoding and auditing every payload is the TEST's work, not the
      -- plugin's, and it costs more than the plugin does. Timed separately so
      -- it can be subtracted: otherwise the headline figure would mostly be a
      -- measurement of this file.
      local t0 = os.clock()
      local ok, data = pcall(jsonDecode, payload)
      if ok and type(data) == 'table' and type(data.drivers) == 'table' then
        lastState = data
        auditBoard(data.drivers)
      end
      harnessTime = harnessTime + (os.clock() - t0)
    end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/gridmap_v2/info.json' end,
}
Util = { JsonEncode = jsonEncode, JsonDecode = jsonDecode }

local function removeTree(path)
  if package.config:sub(1, 1) == '\\' then
    os.execute('rmdir /s /q "' .. path:gsub('/', '\\') .. '" 2>nul')
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end
removeTree('Resources')

dofile('server/RaceManager/main.lua')
onInit()

local ADMIN = 99
connected[ADMIN] = 'Admin'
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onLogin(ADMIN, '{"password":"phoenix"}')

-- ---------------------------------------------------------------------------
-- One race, driven tick by tick the way the server actually runs one.
-- ---------------------------------------------------------------------------
-- Returns the elapsed CPU seconds for the first and second halves separately,
-- which is what makes drift visible: the two must be comparable, or something
-- is getting more expensive as laps accumulate.
local function runRace(laps, opts)
  opts = opts or {}
  RM_onSetTotalLaps(ADMIN, '{"laps":' .. laps .. '}')
  RM_onGenerateGrid(ADMIN)
  RM_onStartCountdown(ADMIN)
  for _ = 1, 4 do RM_CountdownTick() end

  local halfway = math.floor(laps / 2)
  local firstHalf, secondHalf = 0, 0
  local tickCount = 0

  for lap = 1, laps do
    local started = os.clock()
    for t = 1, LAP_TICKS do
      RM_Tick()
      tickCount = tickCount + 1
      -- Telemetry from every driver still circulating, at the rate the client
      -- bridge sends it. This is the busiest inbound path on the server: a full
      -- grid reporting three times a second, every one of them decoded.
      if t % PROGRESS_EVERY == 0 then
        for pid = 1, DRIVERS do
          RM_onProgress(pid, string.format(
            '{"lap":%d,"cp":%d,"dist":%.1f}', lap, (t * 8) // LAP_TICKS, 900 - t * 4))
        end
      end
    end
    -- The whole field crosses the line, a few milliseconds apart, in an order
    -- that shuffles from lap to lap so the comparator is exercised rather than
    -- handed the same answer every time.
    for i = 1, DRIVERS do
      local pid = ((lap + i) % DRIVERS) + 1
      RM_Tick()
      RM_onLap(pid, string.format('{"lapTime":%.3f}', 60 + (i % 7) * 0.35))
    end
    local spent = os.clock() - started
    if lap <= halfway then firstHalf = firstHalf + spent else secondHalf = secondHalf + spent end
  end
  if opts.endRace then RM_onEndRace(ADMIN) end
  return firstHalf, secondHalf, tickCount
end

print(string.format('stress_test: %d drivers, %d laps, %d ticks/lap', DRIVERS, LAPS, LAP_TICKS))

-- ---------------------------------------------------------------------------
-- 1. Baseline: a long race with NO cup running.
-- ---------------------------------------------------------------------------
collectgarbage(); collectgarbage()
local heapStart = collectgarbage('count')
broadcasts, encodedBytes, harnessTime = 0, 0, 0

-- Warm up once and throw it away: the first race pays for JIT-less Lua's
-- string interning and grows the heap to its working size, and charging that
-- to the baseline would flatter every later comparison.
runRace(4, { endRace = true })

local baseFirst, baseSecond, baseTicks, baseHarness, baseTotal
for attempt = 1, 3 do
  broadcasts, encodedBytes, harnessTime = 0, 0, 0
  local f, sc, tk = runRace(LAPS, { endRace = true })
  local net = f + sc - harnessTime
  if baseTotal == nil or net < baseTotal then
    baseFirst, baseSecond, baseTicks, baseHarness, baseTotal = f, sc, tk, harnessTime, net
  end
end
local baseBroadcasts, baseBytes = broadcasts, encodedBytes

local simSeconds = baseTicks / 10.0    -- the server ticks at 100 ms
print(string.format('  no cup   : %.3fs plugin CPU for %.0fs of racing (%.2f%% of one core)',
  baseTotal, simSeconds, baseTotal / simSeconds * 100))
print(string.format('             %.1f us/tick, %.1f us/broadcast, %d bytes/broadcast',
  baseTotal / baseTicks * 1e6, baseTotal / math.max(baseBroadcasts, 1) * 1e6,
  baseBytes // math.max(baseBroadcasts, 1)))
print(string.format('             outbound %.0f KB/s to each client (%.1f Mbit/s for %d of them)',
  baseBytes / 1024 / simSeconds, baseBytes * 8 / 1e6 / simSeconds * DRIVERS, DRIVERS))
print(string.format('             (test harness overhead excluded: %.3fs)', baseHarness))

check(badBoards == 0, string.format(
  'the leaderboard was valid on all %d broadcasts (%d bad)', boardsChecked, badBoards))
check(boardsChecked > 1000, 'the run actually produced a meaningful number of broadcasts')

-- Drift within a single race. The second half of a 50-lap race must not cost
-- meaningfully more than the first: anything that grows per completed lap
-- (lapFirsts, a results buffer, a leaked table) shows up as a rising number.
local drift = baseSecond / math.max(baseFirst, 1e-9)
print(string.format('  drift    : first half %.3fs, second half %.3fs (x%.2f)',
  baseFirst, baseSecond, drift))
check(drift < 1.35, string.format(
  'a lap late in the race costs about what a lap early in it costs (x%.2f) - '
    .. 'a rising figure means per-lap state is accumulating in the hot path', drift))

-- ---------------------------------------------------------------------------
-- 2. The same race with a cup running, and a season already behind it.
--
-- This is the question the cup has to answer: it is a consumer of results and
-- must cost nothing at all while cars are on track. The cup is loaded up with
-- a realistic history first, so any per-tick work that scales with cup size
-- would have something to scale against.
-- ---------------------------------------------------------------------------
RM_onCupStart(ADMIN, '{"name":"Stress Series"}')
RM_onCupSetScoring(ADMIN,
  '{"quali":[3,2,1],"bonus":{"fastestLap":5,"halfwayLed":3,"hardCharger":2,"derbyWin":5},'
  .. '"dnfScoring":"held"}')
-- Twenty rounds of history for a full field, so cupStandings has real work to
-- do whenever it IS called.
for _ = 1, 20 do runRace(1, { endRace = true }) end

local cupRounds = nil
do
  local f = io.open('Resources/Server/RaceManager/cup.json', 'r')
  local data = f and jsonDecode(f:read('*a'))
  if f then f:close() end
  cupRounds = data and data.round or 0
  check(cupRounds >= 20, 'the cup really did accumulate a season of rounds')
  check(data and #data.entries >= DRIVERS, 'with an entry per driver')
end

collectgarbage(); collectgarbage()
broadcasts, encodedBytes, harnessTime = 0, 0, 0
badBoards, boardsChecked = 0, 0

local cupTotal, cupTicks, cupFirst, cupSecond
local cupPushesDuringRacing = 0
for attempt = 1, 3 do
  broadcasts, encodedBytes, harnessTime = 0, 0, 0
  cupPushes = 0
  local f, sc, tk = runRace(LAPS, { endRace = true })
  -- Scoring at the flag pushes exactly one cup update; anything beyond that
  -- would mean cup work happening while cars were on track.
  cupPushesDuringRacing = math.max(cupPushesDuringRacing, cupPushes - 1)
  local net = f + sc - harnessTime
  if cupTotal == nil or net < cupTotal then
    cupTotal, cupTicks, cupFirst, cupSecond = net, tk, f, sc
  end
end

print(string.format('  with cup : %.3fs total, %d ticks, %d broadcasts (cup at round %d)',
  cupTotal, cupTicks, broadcasts, cupRounds))

check(badBoards == 0, 'the leaderboard stayed valid with a cup running too')

-- The cup is scored once, at the flag. Racing with one must cost what racing
-- without one costs; a measurable difference means something cup-shaped found
-- its way into the tick loop or the broadcast.
local overhead = cupTotal / math.max(baseTotal, 1e-9)
print(string.format('  overhead : x%.3f versus no cup', overhead))
-- The structural claim, which a stopwatch cannot make: while cars are on track
-- the cup produces NO work at all. Timing can only ever suggest this; a count
-- of zero proves it.
check(cupPushesDuringRacing == 0, string.format(
  'a race with a cup running pushes no cup state until the flag (%d extra '
    .. 'pushes seen) - the cup is a consumer of results, not a participant',
  cupPushesDuringRacing))
-- And a loose bound on the wall clock. A cup with a season in it is live heap,
-- and live heap costs the collector something on every cycle, so this is not
-- expected to be exactly 1.0 -- only to be nowhere near a problem.
check(overhead < 1.5, string.format(
  'running a cup does not meaningfully slow the race loop (x%.3f)', overhead))

-- ---------------------------------------------------------------------------
-- 3. A whole evening: ten races back to back, cup on.
--
-- Sessions are torn down and rebuilt between races, and the cup, the roster and
-- the identity registry all persist across them. If any of those grows without
-- bound, the tenth race is slower than the first.
-- ---------------------------------------------------------------------------
local firstRace, lastRace = nil, nil
for i = 1, 10 do
  local a, b = runRace(4, { endRace = true })
  if i == 1 then firstRace = a + b end
  if i == 10 then lastRace = a + b end
end
local eveningDrift = lastRace / math.max(firstRace, 1e-9)
print(string.format('  evening  : race 1 %.3fs, race 10 %.3fs (x%.2f)',
  firstRace, lastRace, eveningDrift))
check(eveningDrift < 1.35, string.format(
  'the tenth race of the night costs about what the first did (x%.2f)', eveningDrift))
check(badBoards == 0, 'and the leaderboard held up across the whole evening')

-- ---------------------------------------------------------------------------
-- 4. Memory.
-- ---------------------------------------------------------------------------
collectgarbage(); collectgarbage()
local heapEnd = collectgarbage('count')
local growthKb = heapEnd - heapStart
print(string.format('  memory   : %.0f KB -> %.0f KB after %d races (+%.0f KB)',
  heapStart, heapEnd, 32, growthKb))
-- A cup with a season in it and a roster of twenty is SUPPOSED to retain
-- memory; that is what persistence means. What must not happen is unbounded
-- growth, so the bound is generous but finite.
check(growthKb < 2048, string.format(
  'retained memory is bounded (+%.0f KB) - a cup and a roster are meant to be '
    .. 'kept, per-lap garbage is not', growthKb))

-- ---------------------------------------------------------------------------
-- 5. The comparator itself, on the input most likely to break it.
--
-- table.sort is entitled to raise "invalid order function for sorting" when the
-- comparator is not a strict weak ordering, and a full field on identical laps
-- with no telemetry is the degenerate case: every metric ties and the ordering
-- falls all the way through to the last tie-break.
-- ---------------------------------------------------------------------------
RM_onResetLeaderboard(ADMIN)
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onSetTotalLaps(ADMIN, '{"laps":3}')
RM_onGenerateGrid(ADMIN)
RM_onStartCountdown(ADMIN)
for _ = 1, 4 do RM_CountdownTick() end
local sortOk = true
for _ = 1, 200 do
  local ok = pcall(RM_Tick)
  if not ok then sortOk = false; break end
end
check(sortOk, 'a full field with every metric tied still sorts without raising')
check(badBoards == 0, 'and still produces a valid leaderboard')
RM_onEndRace(ADMIN)

-- ---------------------------------------------------------------------------
-- 6. The ordering invariant in EVERY phase, not just while racing.
--
-- The leaderboard renders the drivers array in the order it arrives, so
-- "position == index" has to hold everywhere the app might be showing it: on
-- the grid, during the countdown, in qualifying, and at the flag with a field
-- of finishers, retirements and disqualifications mixed together. That last one
-- is the awkward case -- three different classification buckets, ordered by
-- three different rules -- and it is exactly where a wrong assumption would
-- show up as a table in the wrong order.
-- ---------------------------------------------------------------------------
local phaseBoards = 0
local function auditPhase(label)
  local before = badBoards
  -- The public way to force a broadcast: the same request the UI app sends
  -- every time it mounts.
  RM_onRequestState(ADMIN)
  phaseBoards = phaseBoards + 1
  check(badBoards == before,
    'the drivers array is in position order during phase "' .. label .. '"')
  check(lastState ~= nil and #lastState.drivers > 0,
    'phase "' .. label .. '" broadcast a populated field')
end

RM_onResetLeaderboard(ADMIN)
for id in pairs(connected) do RM_onPlayerJoin(id) end
auditPhase('waiting')

RM_onSetQualiLimits(ADMIN, '{"laps":2,"seconds":0}')
RM_onStartQualifying(ADMIN)
auditPhase('grid (qualifying)')
RM_onStartCountdown(ADMIN)
auditPhase('countdown')
for _ = 1, 4 do RM_CountdownTick() end
for i = 1, DRIVERS do
  RM_Tick(); RM_onLap(i, string.format('{"lapTime":%.3f}', 90 + (i % 5) * 0.4))
end
auditPhase('qualifying')
RM_onEndRace(ADMIN)

-- A deliberately mixed final field: some finish cleanly, some are disqualified
-- by the joker ruling for never taking the route, and the rest are retired
-- where they stand. Armed BEFORE the grid forms -- the regulations are locked
-- once a session is under way, which is the whole point of that guard.
-- The track needs a joker route before the rule can be armed: without one the
-- ruling would disqualify the whole field for missing a route that is not there,
-- so the server refuses it.
RM_onStartPositionCount(ADMIN, '{"count":0,"positions":[],"jokerGates":3}')
RM_onSetJokerEnabled(ADMIN, '{"enabled":true}')
RM_onSetTotalLaps(ADMIN, '{"laps":2}')
RM_onGenerateGrid(ADMIN)
auditPhase('grid (race)')
RM_onStartCountdown(ADMIN)
for _ = 1, 4 do RM_CountdownTick() end
for lap = 1, 2 do
  for i = 1, DRIVERS do
    local pid = i
    if pid <= 12 then
      RM_Tick()
      if lap == 1 and pid <= 10 then RM_onJokerLap(pid, '{"lap":1}') end
      RM_onLap(pid, string.format('{"lapTime":%.3f}', 60 + (i % 6) * 0.3))
    end
  end
  auditPhase('racing (lap ' .. lap .. ')')
end
RM_onEndRace(ADMIN)
auditPhase('finished (finishers, DSQ and DNF mixed)')

do
  local finishers, dsq, dnf = 0, 0, 0
  for _, d in ipairs(lastState.drivers) do
    if d.status == 'finished' then finishers = finishers + 1
    elseif d.status == 'dsq' then dsq = dsq + 1
    elseif d.status == 'dnf' then dnf = dnf + 1 end
  end
  print(string.format('  phases   : %d broadcasts audited; final field %d finished, %d DSQ, %d DNF',
    phaseBoards, finishers, dsq, dnf))
  check(finishers > 0 and dsq > 0 and dnf > 0,
    'the final broadcast really did mix all three classification buckets')
end

removeTree('Resources')

print(string.format('stress_test: %d checks, %d failures (%d leaderboards audited)',
  checks, fails, boardsChecked))
if fails > 0 then os.exit(1) end
