-- Headless test for ENDING AND RESTARTING A RACE in server/RaceManager/main.lua:
-- that every race that was run lands in a results file, however it ended.
--
-- Reported after a race night: a race on the stream matched no results file.
-- The last car out had retired, the race stayed RUNNING with nobody left to end
-- it, and the way to run it again was Reset, which saved nothing and wiped
-- qualifying with it. Pinned here: retiring last closes the session; Reset saves
-- a race under way first; Restart from grid saves the stopped race, keeps the
-- grid and qualifying, banks no cup round for it, and puts the rerun in the
-- same file.
--
-- Run from the repo root: lua5.3 tests/restart_test.lua

local connected = { [0] = 'Admin', [1] = 'Leader', [2] = 'Second', [3] = 'Lapped' }
local lastState = nil
local lastChat  = nil
local chatLog   = {}
local spectated = {}
local timers    = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg)
    lastChat = msg
    chatLog[#chatLog + 1] = msg
  end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update'        then lastState = payload end
    if event == 'RM_ForceSpectate' then spectated[target] = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  RemoveVehicle = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/gridmap_v2/info.json' end,
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
local function driver(pid)
  for _, d in ipairs(lastState.drivers) do
    if d.id == pid then return d end
  end
end
local function lap(pid) RM_onLap(pid, '{"lapTime":60.0}') end
local function seconds(n) for _ = 1, math.floor(n * 10) do RM_Tick() end end
local function go()
  RM_onGenerateGrid(0)
  RM_onStartCountdown(0)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
end
-- Every results path announced since the log was cleared, in order.
local function savedPaths()
  local out = {}
  for _, m in ipairs(chatLog) do
    local p = m:match('(Resources/Server/RaceManager/Data/results/[%w%-_%.]+%.txt)')
    if p then out[#out + 1] = p end
  end
  return out
end
local function read(path)
  local f = path and io.open(path, 'r')
  if not f then return '' end
  local t = f:read('*a'); f:close()
  return t
end
local function count(text, needle)
  local n, at = 0, 1
  while true do
    local i = text:find(needle, at, true)
    if not i then return n end
    n, at = n + 1, i + 1
  end
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}'); RM_onSetReadyCheck(0, '{"on":false}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetRaceLimits(0, '{"laps":2,"seconds":0,"mode":"laps"}')
RM_onSetFinishRule(0, '{"after":1,"seconds":0}')

-- ---------------------------------------------------------------------------
-- The last car out retiring ends the race
-- ---------------------------------------------------------------------------
chatLog = {}
go()
for _ = 1, 2 do for _, p in ipairs({ 1, 2, 3 }) do lap(p) end end
lap(0)
check(driver(0).status == 'racing', 'the admin is the last car out')
RM_onRetire(0)
check(lastState.phase ~= 'racing', 'retiring as the last car out closes the race, as a disconnect does')
check(#savedPaths() == 1, 'and it is saved')
check(read(savedPaths()[1]):find('Ended: every driver is home or out', 1, true) ~= nil,
  'the file says how the race ended')

-- ---------------------------------------------------------------------------
-- Restart from grid: saved, same grid, qualifying kept, the rerun in one file
-- ---------------------------------------------------------------------------
-- Qualifying, so there are times to keep. Admin fastest, then Lapped, Second,
-- Leader: the reverse of the pids.
RM_onSetQualiLimits(0, '{"laps":1,"seconds":0}')
RM_onStartQualifying(0)
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
for _, p in ipairs({ 0, 1, 2, 3 }) do lap(p) end
for _, p in ipairs({ 0, 1, 2, 3 }) do RM_onLap(p, string.format('{"lapTime":%d}', 70 - p)) end
seconds(1)
go()
local grid = {}
for pid = 0, 3 do grid[pid] = driver(pid).gridPos end
check(grid[3] == 1 and grid[0] == 4, 'the grid is in qualifying order')
check(driver(3).qualiBest ~= nil, 'with the qualifying times on the board')

-- Cup running, to prove the stopped race banks nothing.
RM_onCupStart(0, '{"name":"Restart Cup"}')
local function cupRounds()
  local f = io.open('Resources/Server/RaceManager/Data/cup.json', 'r')
  local text = f and f:read('*a') or ''
  if f then f:close() end
  return tonumber(text:match('"round"%s*:%s*(%d+)')) or 0
end
local roundsBefore = cupRounds()

chatLog = {}
lap(3); lap(2)
RM_onRestartFromGrid(1)
check(lastState.phase ~= 'grid', 'a driver cannot restart the race')
RM_onRestartFromGrid(0)
check(lastState.phase == 'grid', 'Restart from grid puts the field back on the grid')
for pid = 0, 3 do
  check(driver(pid).gridPos == grid[pid], 'driver ' .. pid .. ' starts from the same slot ('
    .. tostring(driver(pid).gridPos) .. ', was ' .. tostring(grid[pid]) .. ')')
end
check(driver(3).qualiBest ~= nil and driver(0).qualiBest ~= nil, 'qualifying is kept')
check(cupRounds() == roundsBefore, 'the stopped race banks no cup round')
local stopped = savedPaths()[1]
check(stopped ~= nil, 'the stopped race is saved')
check(read(stopped):find('Ended: Restarted from the grid by Admin', 1, true) ~= nil,
  'marked as restarted, not scored in the cup')

-- The rerun, run to the flag.
chatLog = {}
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
for _ = 1, 2 do for _, p in ipairs({ 3, 2, 1, 0 }) do lap(p) end end
seconds(6)
check(lastState.phase == 'finished', 'the rerun finishes')
check(savedPaths()[1] == stopped, 'and is added to the stopped race\'s file (got '
  .. tostring(savedPaths()[1]) .. ')')
local text = read(stopped)
check(count(text, 'SESSION RESULTS') == 2, 'one file, both races')
check(text:find('RESTART: the race above was stopped and run again', 1, true) ~= nil,
  'under a banner saying which is the rerun')
check(cupRounds() == roundsBefore + 1, 'and the rerun is the one round the cup banks')
RM_onCupReset(0)

-- The next race is a race of its own.
chatLog = {}
go()
for _ = 1, 2 do for _, p in ipairs({ 3, 2, 1, 0 }) do lap(p) end end
seconds(6)
check(savedPaths()[1] ~= nil and savedPaths()[1] ~= stopped, 'the race after it gets its own file')

-- ---------------------------------------------------------------------------
-- Reset saves a race under way before clearing it
-- ---------------------------------------------------------------------------
chatLog = {}
go()
lap(3); lap(2)
RM_onResetLeaderboard(0)
check(lastState.phase == 'waiting', 'Reset clears the session')
check(#savedPaths() == 1, 'but the race it cleared was saved first')

if package.config:sub(1, 1) == '\\' then
  os.execute('rmdir /s /q "Resources" 2>nul')
else
  os.execute('rm -rf Resources')
end

if fails == 0 then
  print(string.format('restart_test: %d checks, 0 failures', checks))
else
  print(string.format('restart_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
