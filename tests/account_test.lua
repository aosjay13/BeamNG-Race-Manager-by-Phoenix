-- Headless test for roster recognition by BeamMP account, in
-- server/RaceManager/main.lua.
--
-- A guest gets a random name on every join, so the roster never matches one.
-- A logged-in player has an account id issued by BeamMP auth: once an admin
-- binds that player to a driver, the roster recognizes the account on join.
-- What must hold:
--
--   * binding a logged-in player links their account; a guest links nothing
--   * a linked account gets its name back on join, after a restart too
--   * a guest is never recognized, whatever their name
--   * a driver who drops and rejoins on a new id keeps their name, and the
--     race they dropped out of is scored to their entry, not a placeholder
--   * a departed driver's binding is not handed to the next holder of the id
--   * an unnamed logged-in driver keeps ONE placeholder across joins
--   * the league name can be added while a placeholder carries it, and
--     assigning merges the placeholder and moves the link
--   * results do not print "Ryder [Ryder]"
--   * unassigning, or clearing the name, drops the link
--   * an entry somebody connected holds is not taken on join
--
-- Run from the repo root: lua tests/account_test.lua

local connected = { [0] = 'Phoenix', [1] = 'Ryder', [2] = 'guest4471' }
-- BeamMP account ids by player name. A name not here is a guest.
local accounts  = { Phoenix = '1001', Ryder = '1002', Stranger = '1003' }
local lastState = nil
local lastCup   = nil
local aliasMsg  = {}
local chatLog   = {}

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
  -- Shaped like BeamMP's: ip always, beammp only for a logged-in player.
  GetPlayerIdentifiers = function (pid)
    local name = connected[pid]
    if not name then return nil end
    return { ip = '127.0.0.1', beammp = accounts[name] }
  end,
  IsPlayerGuest = function (pid)
    local name = connected[pid]
    return name ~= nil and accounts[name] == nil
  end,
  SendChatMessage = function (_, msg) chatLog[#chatLog + 1] = tostring(msg) end,
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

local ROSTER = 'Resources/Server/RaceManager/Data/roster.json'
local function readRoster()
  local f = io.open(ROSTER, 'r')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonDecode, text)
  return ok and data or nil
end
-- Every entry on disk with this name (a placeholder can share one).
local function entriesNamed(name)
  local out = {}
  for _, e in ipairs((readRoster() or {}).entries or {}) do
    if e.name == name then out[#out + 1] = e end
  end
  return out
end
local function entryNamed(name, provisional)
  for _, e in ipairs(entriesNamed(name)) do
    if (e.provisional == true) == (provisional == true) then return e end
  end
  return nil
end
local function driver(pid)
  for _, d in ipairs(lastState and lastState.drivers or {}) do
    if d.id == pid then return d end
  end
end
-- What the admin panel is given: the roster view and the connection list.
local function cupView()
  lastCup = nil
  RM_onCupRequestState(9)
  return lastCup or {}
end
local function rosterRow(name)
  for _, e in ipairs(cupView().roster or {}) do
    if e.name == name and e.provisional ~= true then return e end
  end
end
local function connRow(pid)
  for _, c in ipairs(cupView().connected or {}) do
    if c.pid == pid then return c end
  end
end
local function cupTotal(entryId)
  local f = io.open('Resources/Server/RaceManager/Data/cup.json', 'r')
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

local function login()
  RM_onLogin(9, '{"password":"phoenix"}'); RM_onSetReadyCheck(9, '{"on":false}')
end
-- A fresh plugin instance reading whatever is on disk: a server restart.
local function bootPlugin()
  dofile('server/RaceManager/main.lua')
  onInit()
  for id in pairs(connected) do RM_onPlayerJoin(id) end
  login()
end
local function setName(target, name)
  RM_onSetAlias(9, '{"target":' .. target .. ',"alias":"' .. name .. '"}')
end
local function assign(targetPid, entryId)
  RM_onCupBindDriver(9, '{"pid":' .. targetPid .. ',"entryId":' .. entryId .. '}')
end
local function leave(pid)
  connected[pid] = nil
  RM_onPlayerDisconnect(pid)
end
local function arrive(pid, name)
  connected[pid] = name
  RM_onPlayerJoin(pid)
end
local function startRace()
  RM_onSetTotalLaps(9, '{"laps":1}')
  RM_onGenerateGrid(9)
  RM_onStartCountdown(9)
  for _ = 1, 4 do RM_CountdownTick() end
end
-- Each pid crosses once, in order; then past the hold at the flag.
local function finishRace(order)
  for _, pid in ipairs(order) do RM_Tick(); RM_onLap(pid, '{"lapTime":60.0}') end
  for _ = 1, 70 do RM_Tick() end
end
local function lastResults()
  local path = nil
  for _, m in ipairs(chatLog) do
    local p = m:match('(Resources/Server/RaceManager/Data/results/[%w%-_%.]+%.txt)')
    if p then path = p end
  end
  if not path then return '' end
  local f = io.open(path, 'r')
  if not f then return '' end
  local text = f:read('*a')
  f:close()
  return text
end

bootPlugin()

-- ---------------------------------------------------------------------------
-- 1. Binding a logged-in player links their account; a guest links nothing.
-- ---------------------------------------------------------------------------
setName(0, 'Phoenix Racing')
setName(2, 'Gus')
check(entryNamed('Phoenix Racing') and entryNamed('Phoenix Racing').account == '1001',
  'naming a logged-in player stores their BeamMP account on the entry')
check(entryNamed('Gus') and entryNamed('Gus').account == nil,
  'naming a guest stores no account: there is none to store')
check(connRow(0) and connRow(0).isGuest == false, 'the panel marks a logged-in player')
check(connRow(2) and connRow(2).isGuest == true, 'and marks a guest as a guest')
check(rosterRow('Phoenix Racing') and rosterRow('Phoenix Racing').linked == true,
  'the roster view shows the entry is recognized on join')
check(rosterRow('Gus') and rosterRow('Gus').linked == false, 'and that a guest entry is not')

-- ---------------------------------------------------------------------------
-- 2. After a restart the account is recognized; the guest is not.
-- ---------------------------------------------------------------------------
bootPlugin()
check(driver(0) and driver(0).alias == 'Phoenix Racing',
  'a logged-in player gets their name back on join with no admin action')
check(rosterRow('Phoenix Racing') and rosterRow('Phoenix Racing').boundPid == 0,
  'and is bound to their entry, so their points follow')
check(driver(2) and driver(2).alias == nil,
  'a guest is not recognized: a guest name is random per join')

-- ---------------------------------------------------------------------------
-- 3. A guest is never recognized, even under the name the entry last saw.
-- ---------------------------------------------------------------------------
leave(0)
accounts.Phoenix = nil
arrive(4, 'Phoenix')
check(driver(4) and driver(4).alias == nil,
  'a guest using the name an entry was last seen under is not given it')
leave(4)
accounts.Phoenix = '1001'
arrive(0, 'Phoenix')
check(driver(0) and driver(0).alias == 'Phoenix Racing', 'the real account is')

-- ---------------------------------------------------------------------------
-- 4. A driver who drops mid-race and rejoins on a new id.
--
-- Their old record stays on the board as a DNF, still carrying the name. It
-- must not block the name on the new connection (same account, same driver),
-- and the race they dropped out of is scored to their entry rather than to a
-- fresh "Phoenix" placeholder.
-- ---------------------------------------------------------------------------
RM_onCupStart(9, '{"name":"Account Cup"}')
RM_onCupSetScoring(9, '{"race":[30,27,25]}')
startRace()
leave(0)
arrive(5, 'Phoenix')
check(driver(5) and driver(5).alias == 'Phoenix Racing',
  'rejoining on a new id keeps the name, though the old record still holds it')
finishRace({ 1, 2 })
check(#entriesNamed('Phoenix') == 0,
  'the race they dropped out of is not scored to a new placeholder')
local ryderPh = entryNamed('Ryder', true)
check(ryderPh ~= nil and ryderPh.account == '1002',
  'an unnamed logged-in driver is scored to a placeholder that keeps their account')
check(ryderPh and cupTotal(ryderPh.id) == 30, 'holding the points they won')

-- The departed record's id goes to somebody else after the grid purge. They
-- must arrive owning nothing.
RM_onGenerateGrid(9)
arrive(0, 'Stranger')
check(connRow(0) and connRow(0).entryId == nil,
  'a new connection on a departed driver\'s id is not bound to their entry')
check(driver(0) and driver(0).alias == nil, 'and is not given their name')
RM_onResetLeaderboard(9)
check(connRow(5) and connRow(5).isGuest == false,
  'Reset rebuilds every record, and a logged-in player is still marked as one')

-- ---------------------------------------------------------------------------
-- 5. An unnamed logged-in driver keeps one placeholder across joins.
-- ---------------------------------------------------------------------------
leave(1)
arrive(6, 'Ryder')
check(connRow(6) and ryderPh and connRow(6).entryId == ryderPh.id,
  'rejoining puts them back on their own placeholder')
check(driver(6) and driver(6).alias == nil, 'with no display name: they have none yet')
startRace()
finishRace({ 6, 5, 2, 0 })
check(#entriesNamed('Ryder') == 1, 'a second race makes no second placeholder')
check(ryderPh and cupTotal(ryderPh.id) == 60, 'both races are on the one placeholder')

-- ---------------------------------------------------------------------------
-- 6. The league name, added while a placeholder carries it.
-- ---------------------------------------------------------------------------
aliasMsg[9] = nil
RM_onRosterAdd(9, '{"name":"Ryder"}')
check(aliasMsg[9] and aliasMsg[9].success == true,
  'an admin can add "Ryder" though a placeholder is named Ryder')
local ryder = entryNamed('Ryder')
check(ryder ~= nil and ryder.account == nil, 'it is a separate, unlinked entry')
assign(6, ryder and ryder.id or -1)
check(driver(6) and driver(6).alias == 'Ryder', 'assigning gives them the name')
check(#entriesNamed('Ryder') == 1, 'and merges the placeholder away')
check(ryder and cupTotal(ryder.id) == 60, 'with its points')
check(entryNamed('Ryder') and entryNamed('Ryder').account == '1002',
  'and the account link moves onto the named entry')

bootPlugin()
check(driver(6) and driver(6).alias == 'Ryder', 'after a restart Ryder is recognized')
check(driver(5) and driver(5).alias == 'Phoenix Racing', 'and so is Phoenix')
check(driver(0) and driver(0).alias == nil, 'and the stranger is still nobody')

-- ---------------------------------------------------------------------------
-- 7. Results do not print the account name beside an identical display name.
-- ---------------------------------------------------------------------------
startRace()
finishRace({ 6, 5, 2, 0 })
local text = lastResults()
check(text:find('Ryder', 1, true) ~= nil, 'the results file was written')
check(text:find('[Ryder]', 1, true) == nil, 'and has no "Ryder [Ryder]"')
check(text:find('[Phoenix]', 1, true) ~= nil,
  'a different display name still carries the real name beside it')
RM_onResetLeaderboard(9)

-- ---------------------------------------------------------------------------
-- 8. Unassigning, or clearing the name, drops the link.
-- ---------------------------------------------------------------------------
assign(6, 0)
check(rosterRow('Ryder') and rosterRow('Ryder').linked == false,
  'unassigning stops the account being recognized')
check(entryNamed('Ryder') ~= nil, 'and keeps the driver')
setName(5, '')
check(rosterRow('Phoenix Racing') and rosterRow('Phoenix Racing').linked == false,
  'clearing a name does the same')
bootPlugin()
check(driver(6) and driver(6).alias == nil, 'an unassigned account is not put back on join')
check(driver(5) and driver(5).alias == nil, 'nor is a cleared one')

-- A disconnect is not an unassign.
setName(5, 'Phoenix Racing')
leave(5)
check(rosterRow('Phoenix Racing') and rosterRow('Phoenix Racing').linked == true,
  'naming them again relinks, and leaving keeps the link')

-- ---------------------------------------------------------------------------
-- 9. An entry somebody connected holds is not taken on join.
-- ---------------------------------------------------------------------------
assign(2, rosterRow('Phoenix Racing').id)
check(driver(2) and driver(2).alias == 'Phoenix Racing', 'an admin hands the entry to the guest')
arrive(5, 'Phoenix')
check(driver(5) and driver(5).alias == nil, 'the account owner joining does not take it back')
check(driver(2) and driver(2).alias == 'Phoenix Racing', 'the guest keeps it')

-- First alphabetically: a running cup and roster left here would be inherited
-- by every suite after it.
removeTree('Resources')

if fails == 0 then
  print('account_test: ' .. checks .. ' checks, 0 failures')
else
  print('account_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
