-- Headless test for display aliases in server/RaceManager/main.lua (Lua 5.3,
-- same as BeamMP).
--
-- Aliases are a PRESENTATION layer over BeamMP's random guest names. Everyone on
-- the server is a guest, so there is no stable identity to bind a name to: the
-- session id is recycled between players and the guest name is regenerated on
-- every join. The properties that matter, and that this file pins down:
--
--   * race logic never sees an alias -- players are still keyed by session id,
--     and lap/checkpoint/position data is untouched by a rename
--   * an alias can never collide with, or impersonate, another driver
--   * a recycled session id does NOT inherit the previous player's alias
--   * the results .txt records the name raced under, plus the real guest name,
--     so a rename cannot rewrite history
--   * validation keeps the fixed-width results columns intact
--
-- Run from the repo root: lua5.3 tests/alias_test.lua

local connected = { [1] = 'Guest_1111', [2] = 'Guest_2222', [3] = 'Guest_3333' }
local lastState = nil     -- last RM_Update payload
local chatTo    = {}      -- [pid] = last direct chat message
local timers    = {}
local hostedMap = '/levels/gridmap_v2/info.json'

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chatTo[target] = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
  end,
  RemoveVehicle = function () end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  Settings = { Map = 0 },
  Get = function () return hostedMap end,
}

Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

dofile('server/RaceManager/main.lua')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function driver(id)
  for _, d in ipairs(lastState.drivers) do
    if d.id == id then return d end
  end
end
local function setAlias(admin, target, alias)
  RM_onSetAlias(admin, string.format('{"target":%d,"alias":"%s"}', target, alias))
end

onInit()
RM_onLogin(1, '{"password":"phoenix"}')
for id in pairs(connected) do RM_onPlayerJoin(id) end

-- ---------------------------------------------------------------------------
-- 1. Default state: no alias, real guest name shown
-- ---------------------------------------------------------------------------
check(driver(2).alias == nil, 'a driver starts with no alias')
check(driver(2).name == 'Guest_2222', 'the real guest name is broadcast')

-- ---------------------------------------------------------------------------
-- 2. Admin-only. An unauthenticated session cannot rename anybody.
-- ---------------------------------------------------------------------------
setAlias(3, 2, 'Hijack')       -- player 3 never logged in
check(driver(2).alias == nil, 'a non-admin cannot set an alias')

setAlias(1, 2, 'Bob Racer')
check(driver(2).alias == 'Bob Racer', 'an admin can set an alias')

-- ---------------------------------------------------------------------------
-- 3. Race logic is untouched: the driver is still keyed by session id, and a
--    rename moves no timing data.
-- ---------------------------------------------------------------------------
RM_onStartQualifying(1)
RM_onQualiLap(2, '{"lapTime":61.5}')
local beforeRename = driver(2).qualiBest
setAlias(1, 2, 'Renamed Mid Session')
check(driver(2).id == 2, 'the driver is still keyed by its BeamMP session id')
check(driver(2).qualiBest == beforeRename, 'a rename does not touch lap times')
check(driver(2).name == 'Guest_2222', 'the real name is still carried alongside')
RM_onEndRace(1)

-- ---------------------------------------------------------------------------
-- 4. Collisions and impersonation
-- ---------------------------------------------------------------------------
setAlias(1, 2, 'Taken Name')
setAlias(1, 3, 'Taken Name')
check(driver(3).alias == nil, 'an alias already in use is refused')
check(chatTo[1] and chatTo[1]:find('already in use'), 'the admin is told why it was refused')

setAlias(1, 3, 'taken name')
check(driver(3).alias == nil, 'the collision check is case-insensitive')

setAlias(1, 3, 'Guest_1111')
check(driver(3).alias == nil, 'an alias cannot impersonate another driver\'s real name')

for _, reserved in ipairs({ 'admin', 'ADMIN', 'Server', 'console', 'Race Manager' }) do
  setAlias(1, 3, reserved)
  check(driver(3).alias == nil, 'the reserved name "' .. reserved .. '" is refused')
end

setAlias(1, 3, 'Guest_9999')
check(driver(3).alias == nil, 'an alias cannot pose as an unnamed guest')

-- ---------------------------------------------------------------------------
-- 5. Validation. The results file pads the Driver column with %-22s and Lua
--    pads by BYTES, so anything wide or multi-byte would shear the table.
-- ---------------------------------------------------------------------------
setAlias(1, 3, 'ab')
check(driver(3).alias == nil, 'shorter than the minimum is refused')

setAlias(1, 3, string.rep('x', 21))
check(driver(3).alias == nil, 'longer than the maximum is refused')

setAlias(1, 3, string.rep('x', 20))
check(driver(3).alias == string.rep('x', 20), 'exactly the maximum is accepted')

for _, bad in ipairs({ 'Bad<b>Name', 'semi;colon', 'pipe|break', 'quote"mark', 'tilde~x' }) do
  setAlias(1, 3, bad)
  check(driver(3).alias == string.rep('x', 20),
    'markup/punctuation "' .. bad .. '" is refused')
end

-- Non-whitespace control characters (ANSI escapes and friends) are the ones
-- that could scramble a console or a results file, and they are refused.
for _, byte in ipairs({ 27, 1, 7 }) do
  setAlias(1, 3, 'esc' .. string.char(byte) .. 'aped')
  check(driver(3).alias == string.rep('x', 20),
    'control byte ' .. byte .. ' is refused')
end

-- Whitespace control characters are NORMALISED rather than refused: a tab
-- pasted into the box collapses to a space, which cannot break a column or
-- inject anything, so there is nothing to reject.
RM_onSetAlias(1, '{"target":3,"alias":"tab\there"}')
check(driver(3).alias == 'tab here', 'a tab is collapsed to a space, not refused')

setAlias(1, 3, '  Spaced   Out  ')
check(driver(3).alias == 'Spaced Out', 'surrounding and repeated whitespace is collapsed')

-- ---------------------------------------------------------------------------
-- 6. Clearing falls back to the real name -- never blank.
-- ---------------------------------------------------------------------------
setAlias(1, 3, '')
check(driver(3).alias == nil, 'a blank alias clears it')
check(driver(3).name == 'Guest_3333', 'the real name is still there to fall back to')

-- ---------------------------------------------------------------------------
-- 7. A recycled session id must NOT inherit the previous player's alias.
--    This is the accidental-impersonation case: BeamMP hands out session ids
--    again after a disconnect, and the record can outlive the connection.
-- ---------------------------------------------------------------------------
setAlias(1, 2, 'Departing Driver')
check(driver(2).alias == 'Departing Driver', 'alias set before the disconnect')
RM_onStartQualifying(1)
RM_onQualiLap(2, '{"lapTime":59.9}')   -- give the record a reason to survive
RM_onPlayerDisconnect(2)
connected[2] = 'Guest_7777'             -- a DIFFERENT person inherits id 2
RM_onPlayerJoin(2)
check(driver(2).alias == nil, 'a recycled session id does not inherit the alias')
check(driver(2).name == 'Guest_7777', 'the display name is refreshed to the new player')
RM_onEndRace(1)

-- ---------------------------------------------------------------------------
-- 8. Results are a snapshot: the name raced under, plus the real guest name so
--    the file stays traceable back to the session.
-- ---------------------------------------------------------------------------
RM_onResetLeaderboard(1)
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onSetEntryMode(1, '{"mode":"all"}')
setAlias(1, 3, 'Cara Speed')
RM_onSetTotalLaps(1, '{"laps":1}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
for _ = 1, 12 do RM_CountdownTick() end
RM_onLap(3, '{"lapTime":58.2}')
RM_onEndRace(1)

-- The server announces the exact path it wrote, so read that rather than
-- enumerating the directory (which needs a shell and is not portable).
local announced = chatTo[-1] or ''
local path = announced:match('Results saved on the server: (.+)$')
check(path ~= nil, 'the server announces where the results were written')

local text = nil
if path then
  local rf = io.open(path, 'r')
  if rf then text = rf:read('*a'); rf:close() end
end
check(text ~= nil, 'the announced results file can be read back')

if text then
  check(text:find('Cara Speed', 1, true) ~= nil,
    'the results file records the name the driver raced under')
  check(text:find('[Guest_3333]', 1, true) ~= nil,
    'the results file also records the real guest name, so it stays traceable')
  check(text:find('Guest_1111', 1, true) ~= nil,
    'drivers without an alias still appear under their real name')
end

if fails == 0 then
  print('alias_test: ' .. checks .. ' checks, 0 failures')
else
  print('alias_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
