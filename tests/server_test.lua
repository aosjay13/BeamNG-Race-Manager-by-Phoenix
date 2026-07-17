-- Headless test for server/RaceManager/main.lua (Lua 5.3, same as BeamMP).
-- Mocks the MP/Util API, then drives a full session:
-- quali laps -> generate grid -> countdown -> race with laps led -> finish
-- -> automatic results .txt export + chat announcement -> cache clear.
-- Run from the repo root: lua5.3 tests/server_test.lua

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara' }
local lastState = nil     -- last decoded RM_Update payload
local lastChat = nil      -- last broadcast chat message
local timers = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) lastChat = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
}

Util = {
  -- Passthrough: the tests inspect the table directly.
  JsonEncode = function (t) return t end,
  -- Naive flat-object decoder, enough for {"lapTime":93.2} / {"laps":2}.
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('^%s*{', '{')
    return load('return ' .. body)()
  end,
}

dofile('server/RaceManager/main.lua')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function driver(name)
  for _, d in ipairs(lastState.drivers) do
    if d.name == name then return d end
  end
end

onInit()

-- Players join
RM_onPlayerJoin(1); RM_onPlayerJoin(2); RM_onPlayerJoin(3)
check(#lastState.drivers == 3, 'three drivers after join')
check(lastState.phase == 'waiting', 'initial phase waiting')

-- Total laps setting (JSON path + clamping)
RM_onSetTotalLaps(1, '{"laps":2}')
check(lastState.totalLaps == 2, 'total laps set to 2')
RM_onSetTotalLaps(1, '{"laps":0}')
check(lastState.totalLaps == 1, 'laps clamped to minimum 1')
RM_onSetTotalLaps(1, '{"laps":2}')

-- Qualifying: Cara fastest, Bob middle, Alice slowest; Bob improves.
RM_onStartQualifying(1)
check(lastState.phase == 'qualifying', 'phase qualifying')
RM_onQualiLap(1, '{"lapTime":95.5}')
RM_onQualiLap(2, '{"lapTime":99.0}')
RM_onQualiLap(2, '{"lapTime":92.1}')   -- improvement
RM_onQualiLap(2, '{"lapTime":97.0}')   -- slower, must not overwrite
RM_onQualiLap(3, '{"lapTime":90.0}')
check(driver('Bob').qualiBest == 92.1, 'best lap keeps the fastest (92.1)')
check(lastState.drivers[1].name == 'Cara', 'provisional order: Cara P1')
check(lastState.drivers[2].name == 'Bob',  'provisional order: Bob P2')
check(lastState.drivers[3].name == 'Alice','provisional order: Alice P3')

-- Quali lap during wrong phase is ignored
RM_onLap(1, '{"lapTime":80}')
check(driver('Alice').currentLap == 0, 'race lap ignored during quali')

-- Generate grid: fastest first
RM_onGenerateGrid(1)
check(lastState.phase == 'grid', 'phase grid after generate')
check(driver('Cara').gridPos == 1 and driver('Bob').gridPos == 2
  and driver('Alice').gridPos == 3, 'grid locked fastest-to-slowest')
check(driver('Cara').status == 'gridded', 'drivers gridded')

-- Countdown -> GO
RM_onStartCountdown(1)
check(lastState.phase == 'countdown', 'phase countdown')
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()  -- 2, 1, GO
check(lastState.phase == 'racing', 'phase racing after GO')
check(driver('Cara').currentLap == 1, 'currentLap starts at 1')

-- Advance the race clock so finish times are non-zero
for _ = 1, 50 do RM_Tick() end  -- +5.0s

-- Lap 1: Bob crosses first (leads), then Cara, then Alice
RM_onLap(2, '{"lapTime":93.0}')
RM_onLap(3, '{"lapTime":94.0}')
RM_onLap(1, '{"lapTime":96.0}')
check(driver('Bob').lapsLed == 1 and driver('Cara').lapsLed == 0, 'Bob led lap 1')
check(driver('Bob').currentLap == 2, 'Bob on lap 2')

-- Lap 2 (final): Bob crosses first -> leads lap 2 and WINS, even though
-- Cara took pole. Pole sitter and race winner must stay distinct in the
-- exported results.
for _ = 1, 50 do RM_Tick() end
RM_onLap(2, '{"lapTime":91.5}')
check(driver('Bob').lapsLed == 2, 'Bob led lap 2 as well')
check(driver('Bob').status == 'finished'
  and math.abs(driver('Bob').finishTime - 10.0) < 0.001,
  'Bob finished at ~10.0s after final lap')
check(lastState.phase == 'racing', 'race continues while others on track')
check(driver('Bob').raceBest == 91.5, 'race best lap tracked')

for _ = 1, 10 do RM_Tick() end
RM_onLap(3, '{"lapTime":96.0}')
check(driver('Cara').status == 'finished', 'Cara finished P2')
check(driver('Cara').lapsLed == 0, 'no laps led for second finisher')

-- Extra lap reports after finishing are ignored
local before = driver('Bob').finishTime
RM_onLap(2, '{"lapTime":50}')
check(driver('Bob').finishTime == before, 'post-finish lap report ignored')

-- Alice disconnects mid-race -> DNF; she was the last active racer, so the
-- race closes and the results file is written automatically.
lastChat = nil
RM_onPlayerDisconnect(1)
check(driver('Alice').status == 'dnf', 'disconnect mid-race is DNF')
check(lastState.phase == 'finished', 'race closed when last racer left')
check(lastState.drivers[1].name == 'Bob' and lastState.drivers[2].name == 'Cara',
  'final order: Bob, Cara')

-- Results export: chat announcement names the saved file's directory
local RESULTS_DIR = 'Resources/Server/RaceManager/results'
check(type(lastChat) == 'string' and lastChat:find('Session complete', 1, true)
  and lastChat:find(RESULTS_DIR, 1, true),
  'chat broadcast announces results path')

local resultsPath = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
check(resultsPath ~= nil, 'chat message contains a .txt path')
local rf = resultsPath and io.open(resultsPath, 'r')
check(rf ~= nil, 'results file exists on disk')
local content = rf and rf:read('a') or ''
if rf then rf:close() end

local qPos = content:find('--- QUALIFYING RESULTS ---', 1, true)
local rPos = content:find('--- RACE RESULTS ---', 1, true)
check(qPos and rPos and qPos < rPos, 'quali section precedes race section')
local qualiSec = content:sub(qPos or 1, rPos or -1)
local raceSec  = content:sub(rPos or 1)
check(qualiSec:match('P1%s+Cara') and qualiSec:find('POLE POSITION', 1, true),
  'Cara on pole in qualifying section')
check(raceSec:match('P1%s+Bob') and raceSec:find('RACE WINNER', 1, true),
  'Bob is the race winner in race section')
check(not raceSec:match('P%d+%s+Cara%s[^\n]*WINNER'), 'pole sitter is not tagged winner')
check(raceSec:match('DNF%s+Alice'), 'Alice listed as DNF')
check(raceSec:find('1:31.500', 1, true), "Bob's best race lap formatted in race section")
check(qualiSec:find('1:30.000', 1, true), "Cara's quali best formatted in quali section")

-- Clear Results Cache: all .txt files removed, chat confirms
lastChat = nil
RM_onClearResults(2)
check(io.open(resultsPath, 'r') == nil, 'results file deleted by cache clear')
check(type(lastChat) == 'string' and lastChat:find('cache cleared', 1, true),
  'chat broadcast confirms cache clear')

-- Reset returns to waiting with fresh records
connected[1] = 'Alice'
RM_onResetLeaderboard(2)
check(lastState.phase == 'waiting', 'reset returns to waiting')
check(driver('Bob').lapsLed == 0 and driver('Bob').qualiBest == nil, 'reset wipes records')

-- Clean up the directory tree the test created in the repo root
os.execute('rm -rf Resources')

if fails == 0 then
  io.stdout:write(('ALL PASS (%d checks)\n'):format(checks))
else
  io.stdout:write(('%d/%d FAILED\n'):format(fails, checks))
  os.exit(1)
end
