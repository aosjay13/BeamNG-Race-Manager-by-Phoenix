-- Headless test for the persistent driver roster in server/RaceManager/main.lua.
--
-- Display names used to last exactly as long as a connection did, and the
-- reference documented that as a limitation. The roster is the anchor that was
-- missing: a name an admin gave somebody, written to disk, and the thing cup
-- points hang off.
--
-- What it must NEVER do is guess. BeamMP issues a fresh random guest name on
-- every join, so a guest name identifies nobody: matching on one would miss a
-- returning driver almost every time, and on the occasion two people were ever
-- issued the same name it would hand a stranger somebody else's identity and
-- the championship attached to it. Binding a connection to a driver is
-- therefore an admin action and only an admin action, and these are the
-- properties that keeps true:
--
--   * a name an admin sets is written to roster.json and survives a restart
--   * NOTHING is auto-assigned on join, however suggestive the guest name is
--   * a guest name that collides with one the roster has seen inherits nothing
--   * an admin can assign a connection to a saved driver, and their points
--     come with them
--   * an entry already held by a connected player cannot be taken
--   * points scored under a placeholder move onto the real driver when the
--     admin assigns them
--   * renaming a driver renames their entry rather than making a second one
--
-- Run from the repo root: lua5.3 tests/roster_test.lua

local connected = { [0] = 'Guest_A', [1] = 'Guest_B', [2] = 'Guest_C' }
local lastState = nil
local lastCup   = nil  -- last RM_CupUpdate payload
local aliasMsg  = {}   -- [pid] = last RM_AliasResult payload

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
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update'      then lastState = payload end
    if event == 'RM_CupUpdate'   then lastCup = payload end
    if event == 'RM_AliasResult' then aliasMsg[target] = payload end
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

local ROSTER = 'Resources/Server/RaceManager/roster.json'
local function readRoster()
  local f = io.open(ROSTER, 'r')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonDecode, text)
  return ok and data or nil
end
local function rosterNames()
  local data = readRoster()
  local out = {}
  for _, e in ipairs(data and data.entries or {}) do out[#out + 1] = e.name end
  table.sort(out)
  return table.concat(out, ',')
end
local function entryNamed(name)
  local data = readRoster()
  for _, e in ipairs(data and data.entries or {}) do
    if e.name == name then return e end
  end
  return nil
end
local function driver(pid)
  for _, d in ipairs(lastState and lastState.drivers or {}) do
    if d.id == pid then return d end
  end
end

-- A fresh plugin instance reading whatever is on disk. Every local in main.lua
-- is rebuilt, so this is exactly what a server restart looks like from here.
local function bootPlugin()
  dofile('server/RaceManager/main.lua')
  onInit()
  for id in pairs(connected) do RM_onPlayerJoin(id) end
  RM_onLogin(9, '{"password":"phoenix"}')
end

local function setName(target, name)
  RM_onSetAlias(9, '{"target":' .. target .. ',"alias":"' .. name .. '"}')
end

-- The admin control: assign a connection to a saved driver (entryId 0 clears).
local function assign(targetPid, entryId)
  RM_onCupBindDriver(9, '{"pid":' .. targetPid .. ',"entryId":' .. entryId .. '}')
end

-- Total race points held by one cup entry, read back off cup.json.
local function cupTotal(entryId)
  local f = io.open('Resources/Server/RaceManager/cup.json', 'r')
  if not f then return nil end
  local okp, data = pcall(jsonDecode, f:read('*a'))
  f:close()
  if not okp or type(data) ~= 'table' then return nil end
  for _, e in ipairs(data.entries or {}) do
    if e.entryId == entryId then
      local t = 0
      for _, r in ipairs(e.rounds or {}) do t = t + (r.racePts or 0) end
      return t
    end
  end
  return nil
end

bootPlugin()

-- ---------------------------------------------------------------------------
-- 1. Setting a display name writes a roster entry.
-- ---------------------------------------------------------------------------
check(readRoster() == nil, 'no roster file exists before any name is set')
setName(0, 'Phoenix')
setName(1, 'Ryder')
check(rosterNames() == 'Phoenix,Ryder', 'both names were written to roster.json')
check(entryNamed('Phoenix').guest == 'Guest_A',
  'the entry records the guest name the driver was using')
check(driver(0).alias == 'Phoenix', 'the name shows on the leaderboard as before')

local phoenixId = entryNamed('Phoenix').id
check(type(phoenixId) == 'number', 'the entry carries a stable numeric id')

-- ---------------------------------------------------------------------------
-- 2. The entry survives a restart -- but is NOT handed back automatically.
--
-- The file on disk is the point. What must not happen is the server deciding
-- for itself that whichever connection now holds "Guest_A" is Phoenix: after a
-- restart that name has been reissued at random and means nothing.
-- ---------------------------------------------------------------------------
lastState = nil
bootPlugin()
check(entryNamed('Phoenix') ~= nil, 'the saved driver survives a server restart')
check(entryNamed('Phoenix').id == phoenixId, 'and keeps its id')
check(driver(0).alias == nil,
  'but nobody is auto-assigned to it, even on the same guest name -- a guest '
    .. 'name is reissued at random and identifies no one')

-- The admin puts them back, which is the supported path.
assign(0, phoenixId)
check(driver(0).alias == 'Phoenix', 'an admin can assign a connection to a saved driver')
check(entryNamed('Phoenix').guest == 'Guest_A', 'and the entry notes who is on it now')

-- ---------------------------------------------------------------------------
-- 3. A colliding guest name inherits NOTHING.
--
-- The impersonation case, and the reason automatic matching was removed. A
-- different person turning up on a guest name the roster has seen before must
-- not become that driver -- or, once a cup is running, take their points.
-- ---------------------------------------------------------------------------
RM_onPlayerDisconnect(1)
connected[1] = 'Guest_A'            -- the exact name Phoenix's entry recorded
RM_onPlayerJoin(1)
check(driver(1).alias == nil,
  'a stranger issued a guest name the roster has seen is not assigned to it')
check(driver(0).alias == 'Phoenix', 'and the real driver keeps their name')

-- Nor can an admin hand it over while it is in use: the same protection from
-- the other direction.
assign(1, phoenixId)
check(driver(1).alias == nil, 'an entry held by a connected player cannot be taken')
local takeMsg = aliasMsg[9]
check(takeMsg and takeMsg.success == false
  and tostring(takeMsg.message):find('already assigned'),
  'and the admin is told why')

-- ---------------------------------------------------------------------------
-- 4. Assigning carries the driver's points with them.
--
-- A driver who reconnects mid-cup scores under a placeholder until an admin
-- recognizes them. Assigning has to move that, or an admin who gets to them
-- after a race has stranded everything they won.
-- ---------------------------------------------------------------------------
RM_onCupStart(9, '{"name":"Roster Cup"}')
RM_onCupSetScoring(9, '{"race":[30,27,25]}')
RM_onPlayerDisconnect(1)
connected[1] = 'Guest_LATE'
RM_onPlayerJoin(1)
check(driver(1).alias == nil, 'the returning driver arrives unassigned')

RM_onSetTotalLaps(9, '{"laps":1}')
RM_onGenerateGrid(9)
RM_onStartCountdown(9)
for _ = 1, 4 do RM_CountdownTick() end
RM_Tick(); RM_onLap(1, '{"lapTime":60.0}')
RM_Tick(); RM_onLap(0, '{"lapTime":61.0}')
RM_Tick(); RM_onLap(2, '{"lapTime":62.0}')

-- Past the hold at the flag: a race no longer closes on the tick the last car
-- crosses, so results are written a moment later (see race.endDelay).
for _ = 1, 70 do RM_Tick() end
local placeholder = nil
for _, e in ipairs(readRoster().entries) do
  if e.name == 'Guest_LATE' then placeholder = e end
end
check(placeholder ~= nil, 'an unassigned driver is scored under a placeholder entry')
check(placeholder.provisional == true, 'which is marked a placeholder, not a claim')
check(cupTotal(placeholder.id) == 30, 'and holds the points they won')

-- Now the admin recognizes them. Ryder's entry is free -- nobody is on it.
local ryderId = entryNamed('Ryder').id
assign(1, ryderId)
check(driver(1).alias == 'Ryder', 'the admin assigns them to the right driver')
check(cupTotal(ryderId) == 30, 'and the points they scored come with them')
local stillThere = false
for _, e in ipairs(readRoster().entries) do
  if e.id == placeholder.id then stillThere = true end
end
check(not stillThere, 'the placeholder is retired once its points have moved')

-- Unassigning detaches the connection and leaves the driver intact.
assign(1, 0)
check(driver(1).alias == nil, 'unassigning clears the name from the connection')
check(entryNamed('Ryder') ~= nil, 'the saved driver stays')
check(cupTotal(ryderId) == 30, 'and keeps every point')
RM_onCupReset(9)

-- ---------------------------------------------------------------------------
-- 5. Renaming a bound driver renames their entry.
--
-- An admin correcting a name must not strand the entry the points are on.
-- ---------------------------------------------------------------------------
local count = #(readRoster().entries)
setName(0, 'Phoenix Rising')
check(#(readRoster().entries) == count, 'a rename creates no extra entry')
check(entryNamed('Phoenix') == nil, 'the old name is gone')
check(entryNamed('Phoenix Rising') ~= nil
  and entryNamed('Phoenix Rising').id == phoenixId,
  'the entry kept its id through the rename, so anything keyed on it follows')

-- ---------------------------------------------------------------------------
-- 6. Clearing a name unbinds, but keeps the entry.
--
-- Clearing says "stop showing this", not "throw away the season".
-- ---------------------------------------------------------------------------
setName(0, '')
check(driver(0).alias == nil, 'the display name is cleared')
check(entryNamed('Phoenix Rising') ~= nil, 'the roster entry survives the clear')

-- ---------------------------------------------------------------------------
-- 7. A name in use by somebody else is still refused.
--
-- The roster must not become a back door around the impersonation guard.
-- ---------------------------------------------------------------------------
-- Put somebody on Ryder first, so the name really is taken.
assign(2, entryNamed('Ryder').id)
check(driver(2).alias == 'Ryder', 'a driver is assigned to Ryder')
setName(0, 'Ryder')
check(driver(0).alias == nil, 'a name held by a connected driver is refused')
local msg = aliasMsg[9]
check(msg and msg.success == false and tostring(msg.message):find('already in use'),
  'and the admin is told why')

-- ---------------------------------------------------------------------------
-- 8. Race records are untouched by any of this: the roster is a name store, not
--    a key. Drivers are still keyed by session id everywhere it matters.
-- ---------------------------------------------------------------------------
RM_onSetTotalLaps(9, '{"laps":1}')
RM_onGenerateGrid(9)
RM_onStartCountdown(9)
for _ = 1, 4 do RM_CountdownTick() end
-- Two crossings: a race's first one is never timed, so the second is what puts
-- a lap on the board.
RM_onLap(2, '{"lapTime":61.5}')
RM_onLap(2, '{"lapTime":61.5}')
check(driver(2).raceBest == 61.5, 'lap data still lands on the driver by session id')
RM_onEndRace(9)

-- ---------------------------------------------------------------------------
-- 4b. A placeholder is still a placeholder after a restart.
--
-- The flag is what lets its points be moved onto a real driver later. Lose it
-- across a restart and the entry loads as an ordinary saved driver: the merge
-- refuses (two named drivers are two people), the panel stops marking it, and
-- the points it is holding for somebody are stranded with nothing to say why.
-- ---------------------------------------------------------------------------
RM_onCupStart(9, '{"name":"Restart Cup"}')
RM_onCupSetScoring(9, '{"race":[30,27,25]}')
connected[1] = 'Guest_UNNAMED'
RM_onPlayerDisconnect(1)
RM_onPlayerJoin(1)
RM_onSetTotalLaps(9, '{"laps":1}')
RM_onGenerateGrid(9)
RM_onStartCountdown(9)
for _ = 1, 4 do RM_CountdownTick() end
RM_Tick(); RM_onLap(1, '{"lapTime":60.0}')
RM_Tick(); RM_onLap(0, '{"lapTime":61.0}')
RM_Tick(); RM_onLap(2, '{"lapTime":62.0}')

-- Past the hold at the flag, as above: the roster entry is written when the
-- session closes, not when the last car crosses.
for _ = 1, 70 do RM_Tick() end
local ph = nil
for _, e in ipairs(readRoster().entries) do
  if e.name == 'Guest_UNNAMED' then ph = e end
end
check(ph ~= nil and ph.provisional == true, 'an unassigned driver gets a placeholder')

bootPlugin()
-- Read back what the server LOADED, not what is on disk. The flag is written
-- correctly either way; the bug was dropping it on the way back in, so only the
-- in-memory view can see it. rosterList() is what the admin panel is given.
RM_onCupRequestState(9)
local phAfter = nil
for _, e in ipairs((lastCup and lastCup.roster) or {}) do
  if e.id == ph.id then phAfter = e end
end
check(phAfter ~= nil, 'the placeholder survives a restart')
check(phAfter ~= nil and phAfter.provisional == true,
  'and is still marked as a placeholder in the state the panel is given')

-- Which is what lets its points move when the admin finally identifies them.
local nomadId = entryNamed('Nomad') and entryNamed('Nomad').id
if nomadId then
  local before = cupTotal(ph.id) or 0
  assign(1, nomadId)
  check(cupTotal(nomadId) == before,
    'and the points move onto the real driver after a restart, not just before one')
end
RM_onCupReset(9)

removeTree('Resources')

if fails == 0 then
  print('roster_test: ' .. checks .. ' checks, 0 failures')
else
  print('roster_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
