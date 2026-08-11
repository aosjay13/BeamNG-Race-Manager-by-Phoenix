-- Headless test for the persistent driver roster in server/RaceManager/main.lua.
--
-- Display names used to last exactly as long as a connection did, and the
-- reference documented that as a limitation: everyone is a guest, BeamMP
-- recycles session ids, and guest names are regenerated on every join, so there
-- was nothing to bind a lasting name to.
--
-- The roster is the anchor that was missing. It is an admin's decision written
-- to disk, and it is what cup points hang off -- so the properties below are not
-- cosmetic. If a name can be inherited by the wrong player, so can a
-- championship lead.
--
--   * a name an admin sets is written to roster.json and survives a restart
--   * a driver whose guest name still matches gets their name back automatically
--   * a RECYCLED session id does not, which is the impersonation case
--   * retyping an existing name BINDS to that entry rather than duplicating it
--     (this is how a reconnected driver returns to their points)
--   * renaming a bound driver renames their entry, it does not make a new one
--   * clearing a name unbinds but keeps the entry, points and all
--
-- Run from the repo root: lua5.3 tests/roster_test.lua

local connected = { [0] = 'Guest_A', [1] = 'Guest_B', [2] = 'Guest_C' }
local lastState = nil
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
-- 2. The name survives a server restart.
--
-- This is the whole point of the file on disk: the in-memory identity registry
-- is empty on a fresh boot, so anything that comes back came back from roster.json.
-- ---------------------------------------------------------------------------
lastState = nil
bootPlugin()
check(driver(0).alias == 'Phoenix', 'a display name survives a server restart')
check(driver(1).alias == 'Ryder', 'and so does the second one')
check(entryNamed('Phoenix').id == phoenixId, 'the entry keeps its id across the restart')

-- ---------------------------------------------------------------------------
-- 3. A recycled session id must NOT adopt the previous player's name.
--
-- BeamMP hands session ids out again, and the roster must not become a way to
-- inherit somebody else's identity -- or, once a cup is running, their points.
-- ---------------------------------------------------------------------------
RM_onPlayerDisconnect(1)
connected[1] = 'Guest_STRANGER'
RM_onPlayerJoin(1)
check(driver(1).alias == nil, 'a recycled session id does not adopt the roster name')
check(driver(1).name == 'Guest_STRANGER', 'the new player shows under their own guest name')
check(entryNamed('Ryder') ~= nil, 'the roster entry itself is kept, unclaimed')

-- ---------------------------------------------------------------------------
-- 4. Retyping an existing name BINDS to that entry rather than duplicating it.
--
-- This is the reconnect path, and it is the one that matters most: a driver
-- comes back under a fresh guest name, the admin types the name they had, and
-- they must land on the SAME entry -- that is what returns their points.
-- ---------------------------------------------------------------------------
connected[2] = 'Guest_REJOINED'
RM_onPlayerDisconnect(2)
RM_onPlayerJoin(2)
local before = #(readRoster().entries)
setName(2, 'Ryder')
check(#(readRoster().entries) == before, 'retyping a known name creates no second entry')
check(entryNamed('Ryder').guest == 'Guest_REJOINED',
  'the entry is re-pointed at the connection now using it')
check(driver(2).alias == 'Ryder', 'the driver is shown under the name again')

-- Case-insensitively, so an admin does not have to reproduce the capitalisation.
connected[1] = 'Guest_THIRD'
RM_onPlayerDisconnect(1)
RM_onPlayerJoin(1)
setName(1, 'Nomad')
local nomadId = entryNamed('Nomad').id
connected[1] = 'Guest_FOURTH'
RM_onPlayerDisconnect(1)
RM_onPlayerJoin(1)
setName(1, 'nOmAd')
check(entryNamed('Nomad') == nil, 'the stored name follows the latest spelling')
check(entryNamed('nOmAd') ~= nil and entryNamed('nOmAd').id == nomadId,
  'a name matched case-insensitively binds to the same entry, not a new one')

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
setName(0, 'Ryder')   -- pid 2 is bound to Ryder and connected
check(driver(0).alias == nil, 'a name held by a connected driver is refused')
local msg = aliasMsg[9]
check(msg and msg.success == false and tostring(msg.message):find('already in use'),
  'and the admin is told why')

-- ---------------------------------------------------------------------------
-- 8. Race records are untouched by any of this: the roster is a name store, not
--    a key. Drivers are still keyed by session id everywhere it matters.
-- ---------------------------------------------------------------------------
RM_onSetEntryMode(9, '{"mode":"all"}')
RM_onSetTotalLaps(9, '{"laps":1}')
RM_onGenerateGrid(9)
RM_onStartCountdown(9)
for _ = 1, 4 do RM_CountdownTick() end
RM_onLap(2, '{"lapTime":61.5}')
check(driver(2).raceBest == 61.5, 'lap data still lands on the driver by session id')
RM_onEndRace(9)

removeTree('Resources')

if fails == 0 then
  print('roster_test: ' .. checks .. ' checks, 0 failures')
else
  print('roster_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
