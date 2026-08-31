-- Headless test for the cup / series points module in server/RaceManager/main.lua.
--
-- The cup is a CONSUMER of race results: it reads the classification the
-- results file is built from and never decides anything about a race. The
-- properties pinned down here are the ones that make it safe to leave switched
-- on for a whole season:
--
--   * disabled, it does nothing whatsoever -- a plain race night is untouched
--   * position points come off the finishing order, and a DNF or a
--     disqualification scores nothing rather than being paid for last place
--   * qualifying points are HELD and banked by the race that follows, as part
--     of the same round
--   * bonuses are inert at zero and paid from the same awards the results file
--     prints, not recalculated
--   * points survive Start Qualifying, Reset Session and a server restart, and
--     are cleared by exactly one thing: ending the cup
--
-- Every assertion reads cup.json rather than any in-memory state, so the file
-- that has to survive a restart is the thing being tested throughout.
--
-- Run from the repo root: lua5.3 tests/cup_test.lua

local connected = { [0] = 'Guest_A', [1] = 'Guest_B', [2] = 'Guest_C', [3] = 'Guest_D' }
local lastState = nil
local lastChat  = nil
local lastCup   = nil   -- last RM_CupUpdate payload
local cupPushes = 0     -- how many went out

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
        local e = text:sub(pos + 1, pos + 1)
        if e == 'u' then
          local cp = tonumber(text:sub(pos + 2, pos + 5), 16) or err('bad \\u escape')
          out[#out + 1] = cp < 128 and string.char(cp) or '?'
          pos = pos + 6
        else
          out[#out + 1] = ({ n = '\n', r = '\r', t = '\t', b = '\b', f = '\f' })[e] or e
          pos = pos + 2
        end
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
        if text:sub(pos, pos) ~= '"' then err('expected key') end
        local k = parseString()
        ws()
        if text:sub(pos, pos) ~= ':' then err('expected :') end
        pos = pos + 1
        obj[k] = parseValue()
        ws()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == '}' then return obj end
        if sep ~= ',' then err('expected , or }') end
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
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == ']' then return arr end
        if sep ~= ',' then err('expected , or ]') end
      end
    end
    local lit = text:match('^true', pos) or text:match('^false', pos) or text:match('^null', pos)
    if lit then
      pos = pos + #lit
      if lit == 'true' then return true elseif lit == 'false' then return false end
      return nil
    end
    local num, nextPos = text:match('^(%-?%d+%.?%d*[eE]?[%+%-]?%d*)()', pos)
    if num then pos = nextPos; return tonumber(num) or err('bad number') end
    err('unexpected character')
  end
  local v = parseValue()
  ws()
  return v
end

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (_, msg) lastChat = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (_, event, payload)
    if event == 'RM_Update' then lastState = payload end
    if event == 'RM_CupUpdate' then lastCup = payload; cupPushes = cupPushes + 1 end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/gridmap_v2/info.json' end,
}
Util = { JsonEncode = function (t) return t end, JsonDecode = jsonDecode }

local function removeTree(path)
  if package.config:sub(1, 1) == '\\' then
    os.execute('rmdir /s /q "' .. path:gsub('/', '\\') .. '" 2>nul')
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end
removeTree('Resources')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local CUP = 'Resources/Server/RaceManager/Data/cup.json'
local function readCup()
  local f = io.open(CUP, 'r')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonDecode, text)
  return ok and data or nil
end
-- The persisted cup entry for a display name, and its derived total. Totals are
-- deliberately NOT stored, so summing here mirrors what the standings do.
local function cupEntry(name)
  local data = readCup()
  for _, e in ipairs(data and data.entries or {}) do
    if e.name == name then return e end
  end
  return nil
end
local function totalFor(name)
  local e = cupEntry(name)
  if not e then return nil end
  local total = 0
  for _, r in ipairs(e.rounds or {}) do
    total = total + (r.racePts or 0) + (r.qualiPts or 0)
    for _, v in pairs(r.bonus or {}) do total = total + v end
  end
  for _, a in ipairs(e.adjustments or {}) do total = total + (a.delta or 0) end
  return total
end
local function driver(pid)
  for _, d in ipairs(lastState and lastState.drivers or {}) do
    if d.id == pid then return d end
  end
end

local ADMIN = 9

local function bootPlugin()
  dofile('server/RaceManager/main.lua')
  onInit()
  for id in pairs(connected) do RM_onPlayerJoin(id) end
  RM_onLogin(ADMIN, '{"password":"phoenix"}')
end

-- Put the names back after a restart.
--
-- Nothing does this automatically, and deliberately so: BeamMP reissues guest
-- names at random, so the server cannot tell who has come back. Naming a driver
-- again is the admin action that reattaches them to their saved entry -- and
-- therefore to the points already on it.
local NAMES = { [0] = 'Phoenix', [1] = 'Ryder', [2] = 'Nomad', [3] = 'Falcon' }
local function identifyAll()
  for pid, name in pairs(NAMES) do
    if connected[pid] then
      RM_onSetAlias(ADMIN, '{"target":' .. pid .. ',"alias":"' .. name .. '"}')
    end
  end
end

-- Drive a complete race. `order` is the pids in the order they take the flag;
-- anyone connected and not listed is left out on track and ends up a DNF.
--
-- The clock is advanced between crossings, which is not decoration: finish
-- order is decided by finishTime, and a helper that reported every lap on the
-- same tick would leave every finisher tied and the order settled by the
-- fallback tie-breaks instead. That is a property of the harness, not of the
-- server -- RM_Tick runs ten times a second there.
local function runRace(laps, order)
  RM_onSetTotalLaps(ADMIN, '{"laps":' .. laps .. '}')
  RM_onGenerateGrid(ADMIN)
  RM_onStartCountdown(ADMIN)
  for _ = 1, 4 do RM_CountdownTick() end
  for _ = 1, laps do
    for _, pid in ipairs(order) do
      RM_Tick()
      RM_onLap(pid, '{"lapTime":' .. (60 + pid) .. '}')
    end
  end
  -- Past the hold at the flag. A race no longer closes on the tick the last car
  -- crosses, and a cup round is only banked when the session actually closes.
  for _ = 1, 70 do RM_Tick() end
end

local function runQuali(laps, times)
  RM_onSetQualiLimits(ADMIN, '{"laps":' .. laps .. ',"seconds":0}')
  RM_onStartQualifying(ADMIN)
  RM_onStartCountdown(ADMIN)
  for _ = 1, 4 do RM_CountdownTick() end
  -- The out lap. Qualifying opens with one crossing that is not timed and not
  -- part of the allowance, so a session of `laps` timed laps takes laps + 1
  -- trips past the line. The time given here is discarded by the server, which
  -- is what the quali scoring below is entitled to rely on.
  for pid in pairs(times) do RM_onLap(pid, '{"lapTime":50}') end
  for _ = 1, laps do
    for pid, t in pairs(times) do
      RM_onLap(pid, '{"lapTime":' .. t .. '}')
    end
  end
end

bootPlugin()

-- ---------------------------------------------------------------------------
-- 1. Disabled, the cup does not exist.
--
-- The default has to be total inertness: a server that never touches this
-- feature must not gain a file, a table or a line of behavior.
-- ---------------------------------------------------------------------------
runRace(1, { 0, 1, 2, 3 })
check(readCup() == nil, 'a race with no cup running writes no cup file at all')

-- ---------------------------------------------------------------------------
-- 2. Position points, from the default preset (30P Aggressive).
-- ---------------------------------------------------------------------------
RM_onCupStart(ADMIN, '{"name":"Winter Series"}')
check(readCup() ~= nil and readCup().enabled == true, 'starting a cup enables scoring')
check(readCup().round == 0, 'a new cup starts at round zero')

for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onSetAlias(ADMIN, '{"target":0,"alias":"Phoenix"}')
RM_onSetAlias(ADMIN, '{"target":1,"alias":"Ryder"}')
RM_onSetAlias(ADMIN, '{"target":2,"alias":"Nomad"}')
RM_onSetAlias(ADMIN, '{"target":3,"alias":"Falcon"}')

runRace(1, { 1, 0, 2, 3 })   -- Ryder wins, then Phoenix, Nomad, Falcon
check(readCup().round == 1, 'finishing a race banks one round')
check(totalFor('Ryder') == 30, 'P1 scores 30 on the 30P Aggressive preset')
check(totalFor('Phoenix') == 27, 'P2 scores 27')
check(totalFor('Nomad') == 25, 'P3 scores 25')
check(totalFor('Falcon') == 23, 'P4 scores 23')
check(cupEntry('Ryder').rounds[1].racePos == 1, 'the round records the finishing position')

-- ---------------------------------------------------------------------------
-- 2b. THE SEASON AS A GRID ORDER.
-- ---------------------------------------------------------------------------
-- Standings right now: Ryder 30, Phoenix 27, Nomad 25, Falcon 23. That is a
-- strict order with no ties, which is what makes the two modes below assertable
-- rather than "probably about right".
--
-- The check that matters is the REVERSE one, and specifically where a driver
-- with no cup entry goes in it. Reversing them onto pole would make "never race
-- a round" the quickest route to the front row -- the same trap the quali
-- reverse grid documents, and the same answer: unscored drivers stay at the
-- back in BOTH directions.
do
  local function gridOrder()
    local out = {}
    for _, d in ipairs(lastState.drivers) do
      if d.gridPos then out[d.gridPos] = d.id end
    end
    local names = {}
    for i = 1, #out do names[#names + 1] = tostring(out[i]) end
    return table.concat(names, ',')
  end

  -- NOTHING HERE ENDS A SESSION, and that is deliberate: ending one banks a cup
  -- round, which would shift every round number the rest of this file asserts
  -- on. Generate Grid can be pressed again from the grid, which is all these
  -- checks need.
  local roundsBefore = readCup().round
  RM_onSetGridMode(ADMIN, '{"mode":"points"}')
  check(lastState.gridMode == 'points', 'the championship grid order is accepted')
  RM_onGenerateGrid(ADMIN)
  -- Ryder (1) on pole, then Phoenix (0), Nomad (2), Falcon (3).
  check(gridOrder() == '1,0,2,3',
    'the points leader takes pole (got ' .. gridOrder() .. ')')

  RM_onSetGridMode(ADMIN, '{"mode":"pointsrev"}')
  check(lastState.gridMode == 'pointsrev', 'and so is its reverse')
  RM_onGenerateGrid(ADMIN)
  check(gridOrder() == '3,2,0,1',
    'reversed, the leader starts last of the drivers who have scored (got '
      .. gridOrder() .. ')')

  -- A DRIVER WITH NO CUP ENTRY. Never given an alias, so never bound to a
  -- roster entry, so no championship entry exists for them -- which is a
  -- different thing from having raced and scored nothing.
  -- NOT pid 9: that is ADMIN in this file, and joining over it would drop the
  -- authentication every call below depends on.
  connected[12] = 'Newcomer'
  RM_onPlayerJoin(12)
  RM_onGenerateGrid(ADMIN)
  local order = gridOrder()
  check(order:sub(-2) == '12',
    'an unscored driver lines up LAST on a reversed championship grid, not on '
      .. 'pole: otherwise scoring nothing all season is the fastest way to the '
      .. 'front row (got ' .. order .. ')')

  RM_onSetGridMode(ADMIN, '{"mode":"points"}')
  RM_onGenerateGrid(ADMIN)
  order = gridOrder()
  check(order:sub(-2) == '12', '...and last on an unreversed one too')

  connected[12] = nil
  RM_onPlayerDisconnect(12)
  RM_onSetGridMode(ADMIN, '{"mode":"quali"}')
  check(readCup().round == roundsBefore,
    'and none of it banked a cup round: a grid is not a result')
end

-- ---------------------------------------------------------------------------
-- 3. A DNF scores nothing.
--
-- The classification sorts non-finishers to the bottom, so without an explicit
-- test they would quietly be paid for whatever position that put them in.
-- ---------------------------------------------------------------------------
runRace(1, { 0, 1 })   -- Nomad and Falcon never take the flag
RM_onEndRace(ADMIN)    -- ends the race, making them DNF
check(readCup().round == 2, 'the second race banks a second round')
check(totalFor('Phoenix') == 27 + 30, 'the winner of race two adds a win')
local nomadRound2 = cupEntry('Nomad').rounds[2]
check(nomadRound2 ~= nil and nomadRound2.racePts == 0, 'a DNF scores no position points')
check(nomadRound2.status == 'dnf', 'and is recorded as a DNF rather than a placing')
check(nomadRound2.racePos == nil, 'a driver who did not finish has no finishing position')

-- ---------------------------------------------------------------------------
-- 4. Points survive everything a race night does to session state.
--
-- players{} is wiped by Start Qualifying and by Reset Session, and the whole
-- process goes away on a restart. None of that may touch a championship.
-- ---------------------------------------------------------------------------
local beforeReset = totalFor('Phoenix')
RM_onStartQualifying(ADMIN)
check(totalFor('Phoenix') == beforeReset, 'Start Qualifying does not disturb cup points')
RM_onEndRace(ADMIN)
RM_onResetLeaderboard(ADMIN)
check(totalFor('Phoenix') == beforeReset, 'Reset Session does not disturb cup points')

bootPlugin()
check(readCup().round == 2, 'the round count survives a server restart')
check(driver(0) ~= nil and driver(0).alias == nil,
  'a restart does not re-identify anybody on its own - guest names are reissued '
    .. 'at random, so only an admin can say who has come back')
identifyAll()
check(totalFor('Phoenix') == beforeReset, 'and so do the points')
check(readCup().name == 'Winter Series', 'and the cup keeps its name')

-- ---------------------------------------------------------------------------
-- 5. Qualifying points are held, then banked by the race that follows.
-- ---------------------------------------------------------------------------
RM_onCupSetScoring(ADMIN, '{"quali":[3,2,1]}')
check(#readCup().scoring.quali == 3, 'qualifying points are configurable and stored')

runQuali(1, { [0] = 95.0, [1] = 90.0, [2] = 92.0, [3] = 99.0 })  -- Ryder quickest
check(#readCup().pendingQuali == 4, 'qualifying is scored and held, not banked')
check(readCup().round == 2, 'holding it does not advance the round')

local roundsBefore = #cupEntry('Ryder').rounds
runRace(1, { 3, 2, 1, 0 })   -- Falcon wins the race, Ryder is third
check(#cupEntry('Ryder').rounds == roundsBefore + 1, 'the race banks exactly one round')
local ryderRound = cupEntry('Ryder').rounds[roundsBefore + 1]
check(ryderRound.qualiPos == 1, 'pole is recorded on the round the race created')
check(ryderRound.qualiPts == 3, 'and pays the qualifying points')
check(ryderRound.racePts == 25, 'alongside the race points for third')
check(#readCup().pendingQuali == 0, 'the held qualifying points are consumed')

-- ---------------------------------------------------------------------------
-- 6. Bonuses: inert at zero, paid from the same awards the results file prints.
-- ---------------------------------------------------------------------------
local flBefore = totalFor('Falcon')
RM_onCupSetScoring(ADMIN, '{"bonus":{"fastestLap":5,"hardCharger":3}}')
check(readCup().scoring.bonus.fastestLap == 5, 'a bonus value is stored')
check(readCup().scoring.bonus.halfwayLed == 0, 'the ones left alone stay at zero')

-- Falcon (pid 3) sets the quickest lap and wins from the back of the grid.
RM_onSetGridMode(ADMIN, '{"mode":"custom"}')
RM_onSetDriverGrid(ADMIN, '{"pid":0,"slot":1}')
RM_onSetDriverGrid(ADMIN, '{"pid":3,"slot":4}')
RM_onSetTotalLaps(ADMIN, '{"laps":2}')
RM_onGenerateGrid(ADMIN)
RM_onStartCountdown(ADMIN)
for _ = 1, 4 do RM_CountdownTick() end
for _ = 1, 2 do
  RM_Tick(); RM_onLap(3, '{"lapTime":50.0}')   -- Falcon: quickest lap, and leads
  RM_Tick(); RM_onLap(0, '{"lapTime":70.0}')
  RM_Tick(); RM_onLap(1, '{"lapTime":71.0}')
  RM_Tick(); RM_onLap(2, '{"lapTime":72.0}')
end
-- Past the hold at the flag: the round is banked when the session closes.
for _ = 1, 70 do RM_Tick() end

local falconRound = cupEntry('Falcon').rounds[#cupEntry('Falcon').rounds]
check(falconRound.bonus.fastestLap == 5, 'the fastest lap bonus is awarded')
check(falconRound.bonus.hardCharger == 3,
  'and the hard charger bonus, from the same award the results file reports')
check((falconRound.bonus.halfwayLed or 0) == 0, 'a bonus left at zero pays nothing')
check(totalFor('Falcon') == flBefore + falconRound.racePts + 5 + 3,
  'the total is the sum of its recorded parts')

-- ---------------------------------------------------------------------------
-- 6b. The results file carries the championship the race just fed.
--
-- A results file is what a league keeps; a cup that only exists inside the game
-- leaves the person compiling the standings retyping numbers off a screenshot.
-- The section is written from the cup's own tables, so the file and the panel
-- can never disagree about a total.
-- ---------------------------------------------------------------------------
local RESULTS_DIR = 'Resources/Server/RaceManager/Data/results'
local resultsPath = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
check(resultsPath ~= nil, 'the race announced a results file')
local rf = resultsPath and io.open(resultsPath, 'r')
check(rf ~= nil, 'and it exists on disk')
local results = rf and rf:read('a') or ''
if rf then rf:close() end

local cupSec = results:match('\n(%-%-%- CUP:.*)$') or ''
check(cupSec ~= '', 'the results file has a cup section')
check(cupSec:find('Winter Series', 1, true) and cupSec:find('round 4', 1, true),
  'named, and for the round this race actually banked')
check(cupSec:find('Pos', 1, true) and cupSec:find('Quali', 1, true)
  and cupSec:find('Bonus', 1, true) and cupSec:find('Total', 1, true),
  'with a column for each part of a score and the championship total')

-- The numbers are the cup's, not a second copy worked out here: every driver's
-- Total in the file has to be the total the standings hold.
for _, who in ipairs({ 'Phoenix', 'Ryder', 'Nomad', 'Falcon' }) do
  local total = cupSec:match('\n' .. 'P%d+%s+' .. who .. '%s+%S+%s+%S+%s+%S+%s+%S+%s+(%d+)')
  check(tonumber(total) == totalFor(who),
    'the file reports ' .. who .. "'s championship total as the cup holds it ("
      .. tostring(total) .. ' vs ' .. totalFor(who) .. ')')
end

-- Falcon's round: 35 for the win on the folk preset is not in force yet, so the
-- race points are whatever the current table pays -- but the bonuses are the
-- two just awarded, and they are named rather than buried in a total.
check(cupSec:find('BONUSES THIS ROUND', 1, true), 'the bonuses paid are listed')
check(cupSec:match('Fastest Lap: Falcon %(%+5%)'),
  'each one says what it was for, who got it and what it was worth')
check(cupSec:match('Hard Charger: Falcon %(%+3%)'), 'both of them')

-- ---------------------------------------------------------------------------
-- 7. Presets fill the table, and hand-editing marks it custom.
-- ---------------------------------------------------------------------------
RM_onCupSetPreset(ADMIN, '{"preset":"35p-folk"}')
check(readCup().scoring.race[1] == 35 and readCup().scoring.race[2] == 30,
  'a preset fills the position table')
check(readCup().scoring.preset == '35p-folk', 'and is recorded as the current preset')
RM_onCupSetPreset(ADMIN, '{"preset":"25p-moderate"}')
check(readCup().scoring.race[4] == 11, '25P Moderate has its own curve')
check(#readCup().scoring.race == 14, 'and stops where it stops')
RM_onCupSetScoring(ADMIN, '{"race":[10,5,1]}')
check(readCup().scoring.preset == 'custom', 'hand-editing the table marks it custom')
check(#readCup().scoring.race == 3, 'a shorter table scores only as deep as it goes')

RM_onCupSetPreset(ADMIN, '{"preset":"nonsense"}')
check(readCup().scoring.race[1] == 10, 'an unknown preset is ignored rather than applied')

-- A position past the end of the table scores nothing at all.
RM_onSetGridMode(ADMIN, '{"mode":"quali"}')
local fourthBefore = totalFor('Falcon')
runRace(1, { 0, 1, 2, 3 })
local last = cupEntry('Falcon').rounds[#cupEntry('Falcon').rounds]
check(last.racePts == 0, 'finishing past the end of the points table scores zero')
check(totalFor('Falcon') == fourthBefore, 'so the total does not move')

-- ---------------------------------------------------------------------------
-- 8. Only ending the cup clears it.
-- ---------------------------------------------------------------------------
check(totalFor('Phoenix') > 0, 'there are points to lose')
RM_onCupReset(ADMIN)
check(readCup().enabled == false, 'ending the cup disables scoring')
check(#readCup().entries == 0, 'and clears every standing')
check(readCup().round == 0, 'and the round count')

-- The roster is NOT cup property: ending a championship must not make an admin
-- re-name their whole grid.
local rf = io.open('Resources/Server/RaceManager/Data/roster.json', 'r')
local rtext = rf and rf:read('*a') or ''
if rf then rf:close() end
check(rtext:find('Phoenix', 1, true) ~= nil,
  'display names survive the cup being ended')

-- And with the cup off, racing writes nothing to it again.
runRace(1, { 0, 1, 2, 3 })
check(#readCup().entries == 0, 'a race after the cup ended scores nothing')

-- ---------------------------------------------------------------------------
-- 9. The broadcast channel.
--
-- The cup has its own channel, pushed only when something changes. It is
-- deliberately NOT folded into the main state broadcast, which goes out three
-- times a second to every client for the whole of a race -- so the test that
-- matters most here is the one about the race loop being left alone.
-- ---------------------------------------------------------------------------
RM_onCupStart(ADMIN, '{"name":"Broadcast Cup"}')
check(lastCup ~= nil, 'starting a cup pushes the cup state to clients')
check(lastCup.cupEnabled == true and lastCup.cupName == 'Broadcast Cup',
  'the payload carries the cup itself')
-- Not a hardcoded count. This asserted `== 5` and broke the moment a preset was
-- added, which tells you nothing except that somebody added one: the thing worth
-- protecting is that every entry is USABLE by the dropdown, not how many there
-- are. A preset missing its key cannot be picked and a preset missing its label
-- shows as a blank row, and neither fails anywhere else.
check(#lastCup.presets >= 5, 'and the list of scoring presets the server supports')
local presetsOk, byKey = true, {}
for _, p in ipairs(lastCup.presets) do
  if type(p.key) ~= 'string' or p.key == ''
     or type(p.label) ~= 'string' or p.label == '' then presetsOk = false end
  byKey[p.key] = p
end
check(presetsOk, 'every preset carries the key the dropdown sends and a label to show')

-- Collision Course: podium only, and nothing for turning up. Three deep rather
-- than three followed by twenty-one zeroes, because a position past the end of
-- the table already scores nothing.
RM_onCupSetPreset(ADMIN, '{"preset":"collision-course","target":"race"}')
check(byKey['collision-course'] ~= nil, 'Collision Course is offered as a preset')
check(#lastCup.racePoints == 3 and lastCup.racePoints[1] == 3
  and lastCup.racePoints[2] == 2 and lastCup.racePoints[3] == 1,
  'and pays 3, 2, 1 with nothing behind it')
check(#lastCup.bonuses == 4, 'and the bonus registry, so the panel renders itself from it')
check(lastCup.bonuses[1].key ~= nil and lastCup.bonuses[1].label ~= nil,
  'each bonus arrives with a key and a label')
local kinds = {}
for _, b in ipairs(lastCup.bonuses) do kinds[b.kind] = true end
check(kinds.race and kinds.derby,
  'and the discipline it belongs to, so the panel can file it under the right table')

-- Changing the rules pushes; asking for the state pushes; running the race loop
-- does not.
lastCup = nil
RM_onCupSetPreset(ADMIN, '{"preset":"24p-linear"}')
check(lastCup ~= nil and lastCup.racePoints[1] == 24, 'a scoring change is published')
lastCup = nil
RM_onCupRequestState(ADMIN)
check(lastCup ~= nil, 'a client asking for the cup state gets an answer')

for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onSetTotalLaps(ADMIN, '{"laps":3}')
RM_onGenerateGrid(ADMIN)
RM_onStartCountdown(ADMIN)
for _ = 1, 4 do RM_CountdownTick() end
local pushesBefore = cupPushes
for _ = 1, 40 do RM_Tick() end     -- four seconds of race loop
check(cupPushes == pushesBefore,
  'the race tick loop pushes no cup state at all - the cup costs nothing while racing')

-- Finishing the race does push, because the standings actually changed.
for lap = 1, 3 do
  for _, pid in ipairs({ 0, 1, 2, 3 }) do
    RM_Tick(); RM_onLap(pid, '{"lapTime":' .. (60 + pid) .. '}')
  end
  local _ = lap
end
-- Past the hold at the flag: the standings are published when the session closes.
for _ = 1, 70 do RM_Tick() end
check(cupPushes > pushesBefore, 'scoring a round publishes the new standings')
check(lastCup.standings[1] ~= nil and lastCup.standings[1].pos == 1,
  'the standings arrive ranked, with a position stamped on each row')
check(lastCup.standings[1].total >= lastCup.standings[#lastCup.standings].total,
  'and sorted best first')
check(lastCup.round == 1, 'and the round count comes with them')

-- ---------------------------------------------------------------------------
-- 10. Derbies score into the same cup.
--
-- A cup may be all races, all derbies or a mixture. Derbies score on their own
-- points table, keep their own stats, and add into one combined total.
--
-- The important difference from a race: in a derby, being eliminated IS the
-- result. Everybody in the classification scores a position, where a race pays
-- nothing to a driver who did not finish.
-- ---------------------------------------------------------------------------
local function runDerby(order, opts)
  -- `order` is the pids in elimination order, first out first. Everyone left
  -- over survives; the last one standing wins.
  opts = opts or {}
  RM_onDerbyFormUp(ADMIN)
  RM_onDerbyStart(ADMIN)
  for _ = 1, 5 do RM_DerbyCountdownTick() end
  for _, pid in ipairs(order) do
    RM_DerbyTick()
    RM_onDerbyDemolished(pid)
  end
  if opts.endEarly then RM_onDerbyEnd(ADMIN) end
  -- The last elimination DECIDES the derby; a short cool-down keeps the arena up
  -- afterwards so the result can be seen among the wrecks. Tick past it, or the
  -- round is never banked and nothing is scored.
  for _ = 1, 6 do RM_DerbyTick() end
end

RM_onCupStart(ADMIN, '{"name":"Mixed Series"}')
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onSetAlias(ADMIN, '{"target":0,"alias":"Phoenix"}')
RM_onSetAlias(ADMIN, '{"target":1,"alias":"Ryder"}')
RM_onSetAlias(ADMIN, '{"target":2,"alias":"Nomad"}')
RM_onSetAlias(ADMIN, '{"target":3,"alias":"Falcon"}')

-- Derby points default to the same preset as races, so an all-derby cup works
-- the moment it is started rather than silently scoring nothing.
check(readCup().scoring.derby[1] == 30,
  'derby points default to the race preset, so an all-derby cup scores out of the box')

-- Falcon(3) out first, then Nomad(2), then Phoenix(0) -> Ryder(1) survives.
runDerby({ 3, 2, 0 })
check(readCup().round == 1, 'a derby banks a round')
check(totalFor('Ryder') == 30, 'the last man standing takes P1 points')
check(totalFor('Phoenix') == 27, 'the driver eliminated last is P2')
check(totalFor('Nomad') == 25, 'then P3')
check(totalFor('Falcon') == 23,
  'and the first driver out still scores - elimination is the result of a derby')
local dRound = cupEntry('Ryder').rounds[1]
check(dRound.kind == 'derby', 'the round records which discipline it was')
check(dRound.status == 'winner', 'and that this driver actually survived')

-- Derby bonuses are separate from race bonuses and only paid on a derby.
RM_onCupSetScoring(ADMIN, '{"bonus":{"derbyWin":7}}')
runDerby({ 3, 2, 1 })   -- Phoenix survives this one
local pRound = cupEntry('Phoenix').rounds[#cupEntry('Phoenix').rounds]
check(pRound.bonus.derbyWin == 7, 'a derby bonus is paid to the survivor')
check((pRound.bonus.fastestLap or 0) == 0,
  'a RACE bonus is never paid on a derby, even when it is switched on')

-- A derby banks a cup round exactly as a race does, so its results file carries
-- the same section. A league reading two files from one evening should not have
-- to learn two formats -- or find the championship in only one of them.
do
  local path = lastChat and lastChat:match('(Resources/Server/RaceManager/Data/results/[%w%-_%.]+%.txt)')
  check(path ~= nil and path:find('derby_results', 1, true),
    'the derby announced a derby results file')
  local f = path and io.open(path, 'r')
  local text = f and f:read('a') or ''
  if f then f:close() end
  local sec = text:match('\n(%-%-%- CUP:.*)$') or ''
  check(sec ~= '', 'the derby results file has a cup section too')
  check(sec:find('Last Man Standing: Phoenix (+7)', 1, true),
    'and it names the derby bonus that was paid, like a race file names its own')
  local total = sec:match('\nP%d+%s+Phoenix%s+%S+%s+%S+%s+%S+%s+%S+%s+(%d+)')
  check(tonumber(total) == totalFor('Phoenix'),
    'with the same totals the cup holds')
end

-- A derby ENDED EARLY by an admin has no last man standing: several drivers are
-- still running, so somebody tops the classification without having won it.
-- Finishing first and surviving are different things, and only the second is
-- what the bonus is for.
runDerby({ 3 }, { endEarly = true })   -- Falcon out, admin calls time on the rest
local topRound = cupEntry('Phoenix').rounds[#cupEntry('Phoenix').rounds]
check(topRound.racePos == 1, 'a driver still running tops a derby that was ended early')
check(topRound.status == 'survived', 'and is recorded as still running, not as the winner')
check((topRound.bonus.derbyWin or 0) == 0,
  'nobody was last man standing, so that bonus pays nothing')
check(cupEntry('Falcon').rounds[#cupEntry('Falcon').rounds].status == 'eliminated',
  'the driver who was knocked out is still recorded as eliminated')

-- Race and derby stats stay separate, and combine into one total.
RM_onSetGridMode(ADMIN, '{"mode":"quali"}')
RM_onCupSetScoring(ADMIN, '{"race":[10,5,1]}')
runRace(1, { 0, 1, 2, 3 })
local st = lastCup.standings
local function row(name)
  for _, r in ipairs(st) do if r.name == name then return r end end
end
local phoenix = row('Phoenix')
check(phoenix.raceRounds == 1, 'race rounds are counted on their own')
check(phoenix.derbyRounds == 3, 'derby rounds are counted on their own')
check(phoenix.rounds == 4, 'and the combined count is both')
check(phoenix.racePts == 10, 'race points are reported separately')
check(phoenix.derbyTotal > 0, 'derby points are reported separately')
check(phoenix.total == phoenix.raceTotal + phoenix.derbyTotal + phoenix.adjustPts,
  'the combined total is exactly the two disciplines plus adjustments')
check(phoenix.raceWins == 1, 'race wins are tracked apart from derby wins')
check(phoenix.derbyWins == 1, 'and derby wins apart from race wins')
check(phoenix.pos ~= nil and phoenix.racePos ~= nil and phoenix.derbyPos ~= nil,
  'every row carries a combined, a race and a derby position')

-- Turning derby points off leaves races scoring normally.
RM_onCupSetScoring(ADMIN, '{"derby":[]}')
local beforeOff = totalFor('Ryder')
runDerby({ 3, 2, 0 })
check(totalFor('Ryder') == beforeOff,
  'with derby points off a derby scores nothing')
check(readCup().round > 0, 'and the cup is otherwise untouched')

-- With no cup running, a derby scores nothing at all.
RM_onCupReset(ADMIN)
runDerby({ 3, 2, 0 })
check(#readCup().entries == 0, 'a derby with no cup running scores nothing')

-- ---------------------------------------------------------------------------
-- 11. What a DNF is worth.
--
-- A retirement is not always a nil score. The position a driver was RUNNING in
-- when they stopped is kept whatever ended their race, and a league picks
-- whether that is worth nothing, worth its place in the final classification,
-- or worth the place it was held.
-- ---------------------------------------------------------------------------
RM_onCupStart(ADMIN, '{"name":"DNF Rules"}')
RM_onCupSetScoring(ADMIN, '{"race":[30,27,25,23]}')
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onSetGridMode(ADMIN, '{"mode":"custom"}')
RM_onSetDriverGrid(ADMIN, '{"pid":0,"slot":1}')
RM_onSetDriverGrid(ADMIN, '{"pid":1,"slot":2}')
RM_onSetDriverGrid(ADMIN, '{"pid":2,"slot":3}')
RM_onSetDriverGrid(ADMIN, '{"pid":3,"slot":4}')

-- Ryder(1) drops out while running SECOND, and the other three go on to finish.
-- That gap is the whole point of the option: the place he held (P2) and the
-- place he ends up classified in (P4, behind three finishers) are different
-- numbers, so each setting produces a visibly different score.
local function raceWithRetirement()
  RM_onSetTotalLaps(ADMIN, '{"laps":3}')
  RM_onGenerateGrid(ADMIN)
  RM_onStartCountdown(ADMIN)
  for _ = 1, 4 do RM_CountdownTick() end
  -- Lap 1 for everyone, in grid order. Phoenix leads; the running order behind
  -- him is the grid. Each scored lap pushes a broadcast, which is what stamps
  -- the live positions this test then relies on.
  RM_Tick(); RM_onLap(0, '{"lapTime":60.0}')
  RM_Tick(); RM_onLap(1, '{"lapTime":61.0}')
  RM_Tick(); RM_onLap(2, '{"lapTime":62.0}')
  RM_Tick(); RM_onLap(3, '{"lapTime":63.0}')
  -- Ryder's connection drops on lap 2, from second place.
  RM_onPlayerDisconnect(1)
  -- The rest run it out and take the flag, which closes the session.
  for _ = 1, 2 do
    RM_Tick(); RM_onLap(0, '{"lapTime":60.0}')
    RM_Tick(); RM_onLap(2, '{"lapTime":62.0}')
    RM_Tick(); RM_onLap(3, '{"lapTime":63.0}')
  end
  -- Past the hold at the flag: the round is banked when the session closes.
  for _ = 1, 70 do RM_Tick() end
  -- Back for the next one. The guest name is unchanged, so the roster
  -- recognizes him and hands his display name (and his entry) straight back.
  RM_onPlayerJoin(1)
end

-- (a) The default: a DNF scores nothing, exactly as it always did.
raceWithRetirement()
local ryderRound = cupEntry('Ryder').rounds[#cupEntry('Ryder').rounds]
check(ryderRound.status == 'dnf', 'a driver who never took the flag is a DNF')
check(ryderRound.racePts == 0, 'by default a DNF scores nothing')
check(ryderRound.dnfPos == nil, 'and is credited with no position at all')

-- TWO DIFFERENT FACTS, and they used to share one field.
--
-- `heldPos` is where the driver WAS when they stopped, which is what the cup's
-- "held" scoring pays and what the results file prints as "was P2". `dnfPos` is
-- where they CLASSIFY, which is behind every car that can still finish: retiring
-- from second of a running field does not keep second, because everybody still
-- going will come past.
check(lastState ~= nil, 'the session broadcast is available')
local held, classified = nil, nil
for _, d in ipairs(lastState.drivers or {}) do
  if d.name == 'Guest_B' then held, classified = d.heldPos, d.dnfPos end
end
check(held == 2, 'the position the driver was running in when they stopped is kept')
check(classified ~= nil and classified >= 2,
  'and the place they classify is separate, behind the cars still running')
check(cupEntry('Ryder') ~= nil,
  'a driver who disconnects mid-race is still scored against their OWN cup entry')
check(cupEntry('Guest_B') == nil,
  'and not filed under a fresh entry named after their guest name')

-- (b) Classified place: a DNF scores for where it ends up in the final order,
-- which is below every driver who finished.
RM_onCupSetScoring(ADMIN, '{"dnfScoring":"classified"}')
check(readCup().scoring.dnfScoring == 'classified', 'the DNF rule is stored')
raceWithRetirement()
ryderRound = cupEntry('Ryder').rounds[#cupEntry('Ryder').rounds]
check(ryderRound.dnfPos == 4, 'the DNF is classified behind all three finishers')
check(ryderRound.racePts == 23, 'and scores for that place, not for the one it held')
check(ryderRound.racePos == nil,
  'but it is still not a finishing position - a DNF cannot count as a win')

-- (c) Held place: a DNF scores for the position it was running in. Two drivers
-- can score the same position this way, which is the point of the option.
RM_onCupSetScoring(ADMIN, '{"dnfScoring":"held"}')
raceWithRetirement()
ryderRound = cupEntry('Ryder').rounds[#cupEntry('Ryder').rounds]
local nomadRound = cupEntry('Nomad').rounds[#cupEntry('Nomad').rounds]
check(ryderRound.dnfPos == 2, 'the DNF keeps the place it was running in')
check(ryderRound.racePts == 27, 'and is paid for it')
check(nomadRound.racePos == 2 and nomadRound.racePts == 27,
  'the driver who finished second is paid for second as well - both score it')

-- A DNF never counts as a win, however it is scored.
RM_onCupSetScoring(ADMIN, '{"dnfScoring":"held"}')
local st2 = lastCup.standings
local function findRow(name)
  for _, r in ipairs(st2) do if r.name == name then return r end end
end
check(findRow('Ryder').raceWins == 0, 'a retirement is never counted as a win')

-- ---------------------------------------------------------------------------
-- 12. Manual adjustments.
--
-- Kept as a ledger beside the earned points and never folded into them, so a
-- total can always be taken apart and checked.
-- ---------------------------------------------------------------------------
RM_onCupStart(ADMIN, '{"name":"Adjustments"}')
-- Bonuses off, so the arithmetic below is only about adjustments.
RM_onCupSetScoring(ADMIN,
  '{"race":[30,27,25,23],"dnfScoring":"none",'
  .. '"bonus":{"fastestLap":0,"halfwayLed":0,"hardCharger":0,"derbyWin":0}}')
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onSetGridMode(ADMIN, '{"mode":"quali"}')
runRace(1, { 0, 1, 2, 3 })

local phoenixId = nil
for _, r in ipairs(lastCup.standings) do
  if r.name == 'Phoenix' then phoenixId = r.entryId end
end
check(phoenixId ~= nil, 'the standings identify a driver by their cup entry id')
local earned = totalFor('Phoenix')
check(earned == 30, 'the race winner has their earned points')

RM_onCupAdjust(ADMIN, '{"entryId":' .. phoenixId .. ',"delta":-5,"reason":"Track limits"}')
check(totalFor('Phoenix') == earned - 5, 'a penalty comes off the total')
local pe = cupEntry('Phoenix')
check(#pe.adjustments == 1, 'and is recorded as its own ledger entry')
check(pe.adjustments[1].reason == 'Track limits', 'with the reason it was given')
check(pe.adjustments[1].by ~= nil and pe.adjustments[1].at ~= nil,
  'and who made it, and when')
check(pe.rounds[1].racePts == 30,
  'the points the driver EARNED are untouched - the adjustment is kept apart')

RM_onCupAdjust(ADMIN, '{"entryId":' .. phoenixId .. ',"delta":2,"reason":"Marshal error"}')
check(totalFor('Phoenix') == earned - 3, 'adjustments accumulate')
check(#cupEntry('Phoenix').adjustments == 2, 'each as its own entry')

-- Removing one deletes it rather than posting an opposite entry, so the ledger
-- stays a record of decisions rather than of corrections to corrections.
RM_onCupRemoveAdjust(ADMIN, '{"entryId":' .. phoenixId .. ',"index":1}')
check(#cupEntry('Phoenix').adjustments == 1, 'removing an adjustment deletes it')
check(cupEntry('Phoenix').adjustments[1].reason == 'Marshal error',
  'and leaves the other one alone')
check(totalFor('Phoenix') == earned + 2, 'the total follows')

-- The standings report earned and adjusted separately.
RM_onCupRequestState(ADMIN)
local prow = nil
for _, r in ipairs(lastCup.standings) do if r.name == 'Phoenix' then prow = r end end
check(prow.adjustPts == 2, 'the standings carry the adjustment total')
check(prow.raceTotal == 30, 'and the earned total, separately')
check(prow.total == 32, 'with the combined figure over both')
check(#prow.adjustments == 1, 'and the ledger itself, so it can be audited')

-- Dropping a round is the honest fix for a race scored wrongly.
RM_onCupDropRound(ADMIN, '{"entryId":' .. phoenixId .. ',"round":1}')
check(#cupEntry('Phoenix').rounds == 0, 'dropping a round removes it')
check(totalFor('Phoenix') == 2, 'leaving only the adjustments behind')

-- Guards.
RM_onCupAdjust(ADMIN, '{"entryId":99999,"delta":5}')
check(#cupEntry('Phoenix').adjustments == 1, 'an adjustment to an unknown entry is ignored')
RM_onCupAdjust(ADMIN, '{"entryId":' .. phoenixId .. ',"delta":0}')
check(#cupEntry('Phoenix').adjustments == 1, 'a zero adjustment is not recorded')
RM_onCupAdjust(5, '{"entryId":' .. phoenixId .. ',"delta":50}')
check(#cupEntry('Phoenix').adjustments == 1, 'a non-admin cannot adjust points')

-- Adjustments survive a restart, like everything else in a cup.
bootPlugin()
identifyAll()
check(totalFor('Phoenix') == 2, 'adjustments survive a server restart')
check(#cupEntry('Phoenix').adjustments == 1, 'and keep their ledger')

-- ---------------------------------------------------------------------------
-- 13. Held qualifying points follow a driver who is identified mid-round.
--
-- Qualifying is scored when it ends and banked by the race that follows, keyed
-- on the entry it was scored against. A driver identified in that window --
-- which is exactly what the Drivers panel is for -- changes entry, so the held
-- row has to come with them. It is looked up by entry id, and a stale one is
-- simply never found again: the driver quietly qualifies for nothing.
-- ---------------------------------------------------------------------------
RM_onCupStart(ADMIN, '{"name":"Mid-round"}')
RM_onCupSetScoring(ADMIN,
  '{"race":[30,27,25,23],"quali":[5,3,1],'
  .. '"bonus":{"fastestLap":0,"halfwayLed":0,"hardCharger":0,"derbyWin":0}}')
for id in pairs(connected) do RM_onPlayerJoin(id) end
identifyAll()

-- One driver loses their name: they come back on a new guest name, unassigned.
-- From the ROSTER, not the standings: a fresh cup has no standings yet, but the
-- saved drivers are exactly what the panel offers to assign.
RM_onCupRequestState(ADMIN)
local ryderId = nil
for _, e in ipairs(lastCup.roster or {}) do
  if e.name == 'Ryder' then ryderId = e.id end
end
check(ryderId ~= nil, 'the saved driver is on the roster the panel is given')
RM_onPlayerDisconnect(1)
connected[1] = 'Guest_RETURNED'
RM_onPlayerJoin(1)
check(driver(1) ~= nil and driver(1).alias == nil, 'the returning driver is unassigned')

-- They qualify on pole while still unassigned, so the held points are scored
-- against a placeholder.
runQuali(1, { [0] = 95.0, [1] = 90.0, [2] = 92.0, [3] = 99.0 })
check(#readCup().pendingQuali > 0, 'qualifying is held for the race that follows')

-- The admin recognizes them BEFORE the race, which is the whole point of the
-- panel: it should cost them nothing.
if ryderId then RM_onCupBindDriver(ADMIN, '{"pid":1,"entryId":' .. ryderId .. '}') end
check(driver(1).alias == 'Ryder', 'and is assigned to their saved driver')

runRace(1, { 1, 0, 2, 3 })
local round = cupEntry('Ryder').rounds[#cupEntry('Ryder').rounds]
check(round ~= nil and round.racePts == 30, 'they are scored for winning the race')
check(round.qualiPos == 1, 'and the pole they took while unassigned is still theirs')
check(round.qualiPts == 5, 'with the points it was worth')
RM_onCupReset(ADMIN)

-- ---------------------------------------------------------------------------
-- 14. A named driver who drops mid-derby is still scored as themselves.
--
-- A derby does not put anyone on track as far as the racing state machine is
-- concerned, so every racing record reads 'waiting' -- and a disconnecting
-- 'waiting' driver has their record deleted outright, display name and all.
-- The derby result is classified afterwards, so if the name goes with the
-- record the cup has nothing left to identify them by: no binding, no name to
-- match, and their round is filed against a placeholder they can never be
-- joined to again, because assigning needs a live connection.
-- ---------------------------------------------------------------------------
RM_onCupStart(ADMIN, '{"name":"Derby Drop"}')
RM_onCupSetScoring(ADMIN,
  '{"derby":[30,27,25,23],"bonus":{"fastestLap":0,"halfwayLed":0,"hardCharger":0,"derbyWin":0}}')
for id in pairs(connected) do RM_onPlayerJoin(id) end
identifyAll()
RM_onCupRequestState(ADMIN)
local rosterBefore = #(lastCup.roster or {})

-- An all-derby cup: no race has run, so nobody is on track as far as the racing
-- state machine is concerned. Reset Session puts every record back to 'waiting',
-- which is the state a derby night actually runs in -- and the one whose record
-- is deleted outright when a connection drops.
RM_onResetLeaderboard(ADMIN)

RM_onDerbyFormUp(ADMIN)
RM_onDerbyStart(ADMIN)
for _ = 1, 5 do RM_DerbyCountdownTick() end
RM_DerbyTick(); RM_onDerbyDemolished(3)
-- The precondition that makes this bite: a derby leaves the racing record
-- 'waiting', which is the status whose record is deleted outright on a drop.
check(driver(1) ~= nil and driver(1).status == 'waiting',
  'a driver in a derby is still "waiting" to the racing state machine')
-- Ryder's connection drops while the derby is still running.
RM_onPlayerDisconnect(1)
RM_Derby_onPlayerDisconnect(1)
connected[1] = nil
RM_DerbyTick(); RM_onDerbyDemolished(2)     -- leaves one alive: the derby is decided
for _ = 1, 6 do RM_DerbyTick() end          -- ...and ends after the cool-down

check(cupEntry('Ryder') ~= nil,
  'the driver who dropped mid-derby is scored against their own saved driver')
RM_onCupRequestState(ADMIN)
check(#(lastCup.roster or {}) == rosterBefore,
  'and no placeholder is invented for them')
connected[1] = 'Guest_B'
RM_onCupReset(ADMIN)

removeTree('Resources')


-- ---------------------------------------------------------------------------
-- Saving a scoring system
-- ---------------------------------------------------------------------------
-- A league spends an evening agreeing a points structure and it used to live
-- only inside the running cup. Saved systems sit in the same picker as the
-- built-ins and, crucially, survive End Cup -- which clears the standings and
-- deliberately leaves cup.scoring alone.
RM_onCupSetScoring(ADMIN, '{"race":[12,9,7,5,3,1]}')
RM_onCupSavePreset(ADMIN, '{"name":"Thursday League"}')

local function presetByKey(key)
  for _, p in ipairs(lastCup.presets or {}) do if p.key == key then return p end end
end
check(presetByKey('saved:thursday league') ~= nil, 'a saved system joins the preset list')
check(presetByKey('saved:thursday league').label == 'Thursday League',
  'under the name it was given')
check(presetByKey('saved:thursday league').saved == true,
  'and is flagged as saved, so the panel can offer Delete on it and not on a built-in')
check(presetByKey('25p-moderate') ~= nil and presetByKey('25p-moderate').saved ~= true,
  'while a built-in is not flagged')

-- Load it back over a different table.
RM_onCupSetPreset(ADMIN, '{"preset":"30p-aggressive","target":"race"}')
check(lastCup.racePoints[1] == 30, 'a built-in loads over it')
RM_onCupSetPreset(ADMIN, '{"preset":"saved:thursday league","target":"race"}')
check(#lastCup.racePoints == 6 and lastCup.racePoints[1] == 12
  and lastCup.racePoints[6] == 1, 'and the saved system loads back exactly as saved')

-- Saving the same name again REPLACES rather than duplicating, the way a layout
-- of the same name does.
RM_onCupSetScoring(ADMIN, '{"race":[50,40]}')
RM_onCupSavePreset(ADMIN, '{"name":"Thursday League"}')
local n = 0
for _, p in ipairs(lastCup.presets or {}) do
  if p.key == 'saved:thursday league' then n = n + 1 end
end
check(n == 1, 'saving over a name replaces it rather than adding a second')
RM_onCupSetPreset(ADMIN, '{"preset":"saved:thursday league","target":"race"}')
check(#lastCup.racePoints == 2 and lastCup.racePoints[1] == 50,
  'and it is the new table that comes back')

-- THE POINT OF SAVING ONE, part one: ending the cup must not take it with the
-- standings.
RM_onCupReset(ADMIN)
check(presetByKey('saved:thursday league') ~= nil,
  'a saved system survives End Cup, which is the whole reason to save one')

-- ...and part two, which is the half that actually needed asserting: it has to
-- be ON DISK. Every other assertion in this section reads the broadcast, and a
-- broadcast is happy to report a system that was never written down -- dropping
-- savedPresets from saveCupToDisk left all of them passing while the systems
-- evaporated on the next restart, which is exactly when somebody would reach
-- for one.
local savedOnDisk = readCup()
local onDisk = nil
for _, sp in ipairs(savedOnDisk and savedOnDisk.savedPresets or {}) do
  if sp.key == 'saved:thursday league' then onDisk = sp end
end
check(onDisk ~= nil, 'a saved system is written to cup.json')
check(onDisk and #onDisk.race == 2 and onDisk.race[1] == 50,
  'with its points table intact')

bootPlugin()
-- ASK FOR A FRESH BROADCAST FIRST. lastCup is whatever was last pushed, and a
-- reboot pushes nothing on its own -- so reading it straight after a restart
-- reads the payload from BEFORE the restart and reports the old list as
-- surviving. Both of these passed that way until this line was added.
lastCup = nil
RM_onCupRequestState(ADMIN)
check(lastCup ~= nil, 'the rebooted server answers a cup state request')
check(presetByKey('saved:thursday league') ~= nil,
  'and is still offered after a server restart')
RM_onCupSetPreset(ADMIN, '{"preset":"saved:thursday league","target":"race"}')
check(#lastCup.racePoints == 2 and lastCup.racePoints[1] == 50,
  'and still loads the table it was saved with')

-- An empty race table has nothing to save.
RM_onCupStart(ADMIN, '{"name":"Empty Save"}')
RM_onCupSetScoring(ADMIN, '{"race":[]}')
RM_onCupSavePreset(ADMIN, '{"name":"Nothing At All"}')
check(presetByKey('saved:nothing at all') == nil,
  'an empty points table is not saveable: there is nothing in it to save')

-- Built-ins cannot be deleted, saved ones can.
RM_onCupDeletePreset(ADMIN, '{"preset":"25p-moderate"}')
check(presetByKey('25p-moderate') ~= nil, 'a built-in preset cannot be deleted')
RM_onCupDeletePreset(ADMIN, '{"preset":"saved:thursday league"}')
check(presetByKey('saved:thursday league') == nil, 'a saved system can be')

-- A non-admin can neither save nor delete one.
RM_onCupSetScoring(ADMIN, '{"race":[9,6,3]}')
RM_onCupSavePreset(77, '{"name":"Not Mine"}')
check(presetByKey('saved:not mine') == nil, 'a non-admin cannot save a scoring system')

if fails == 0 then
  print('cup_test: ' .. checks .. ' checks, 0 failures')
else
  print('cup_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
