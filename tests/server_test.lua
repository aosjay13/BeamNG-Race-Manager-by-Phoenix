-- Headless test for server/RaceManager/main.lua (Lua 5.3, same as BeamMP).
-- Mocks the MP/Util API, then drives a full session:
-- quali laps -> generate grid -> countdown -> race with laps led -> finish
-- -> automatic results .txt export + chat announcement -> cache clear.
-- Run from the repo root: lua5.3 tests/server_test.lua

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara' }
local lastState = nil     -- last decoded RM_Update payload
local lastChat = nil      -- last broadcast chat message
local lastLayouts = nil   -- last RM_Layouts payload
local lastApplied = nil   -- last RM_ApplyLayout payload
local lastCleared = nil   -- last RM_ClearTrack payload
local eventSeq = {}       -- ordered names of broadcast client events
local timers = {}
local hostedMap = '/levels/gridmap_v2/info.json'  -- what MP.Get(Map) reports

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) lastChat = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    eventSeq[#eventSeq + 1] = event
    if event == 'RM_Update'      then lastState   = payload end
    if event == 'RM_Layouts'     then lastLayouts = payload end
    if event == 'RM_ApplyLayout' then lastApplied = payload end
    if event == 'RM_ClearTrack'  then lastCleared = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  Settings = { Map = 0 },
  Get = function (setting) return hostedMap end,
}

Util = {
  -- Passthrough: the tests inspect the table directly.
  JsonEncode = function (t) return t end,
  -- Naive decoder: JSON object/array syntax mapped onto Lua table literals,
  -- enough for {"lapTime":93.2} and the nested layout save payloads.
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

-- ---------------------------------------------------------------------------
-- Track layouts: save, strict map filter, load broadcast, persistence
-- ---------------------------------------------------------------------------
local cpJson = '[{"x":100.5,"y":200.25,"z":50,"hx":0,"hy":1},'
  .. '{"x":150,"y":260,"z":51,"hx":1,"hy":0},'
  .. '{"x":90,"y":300,"z":50,"hx":0,"hy":-1}]'

-- Save the currently placed checkpoints as a named layout
lastChat = nil
RM_onSaveLayout(1, '{"name":"GP Circuit","width":24,"checkpoints":' .. cpJson .. '}')
check(type(lastChat) == 'string' and lastChat:find('GP Circuit', 1, true)
  and lastChat:find('gridmap_v2', 1, true), 'chat announces layout save with map name')
check(io.open('Resources/Server/RaceManager/layouts.json', 'r') ~= nil,
  'layouts.json written to disk')
check(lastLayouts ~= nil and lastLayouts.map == 'gridmap_v2'
  and #lastLayouts.layouts == 1, 'save broadcasts refreshed layout list')
check(lastLayouts.layouts[1].width == 24
  and #lastLayouts.layouts[1].checkpoints == 3, 'saved layout keeps width and gates')

-- Same name on the same map overwrites instead of duplicating
RM_onSaveLayout(1, '{"name":"gp circuit","width":30,"checkpoints":' .. cpJson .. '}')
check(#lastLayouts.layouts == 1 and lastLayouts.layouts[1].width == 30,
  'same-name save overwrites the existing layout')

-- Strict map filter: hosting another map hides gridmap layouts entirely
hostedMap = '/levels/east_coast_usa/info.json'
RM_onRequestLayouts(1)
check(lastLayouts.map == 'east_coast_usa' and #lastLayouts.layouts == 0,
  'layouts strictly filtered to the hosted map')
RM_onSaveLayout(2, '{"name":"Coast Run","width":18,"checkpoints":' .. cpJson .. '}')
check(#lastLayouts.layouts == 1 and lastLayouts.layouts[1].name == 'Coast Run',
  'second map keeps its own separate layout list')
hostedMap = '/levels/gridmap_v2/info.json'
RM_onRequestLayouts(1)
check(#lastLayouts.layouts == 1 and lastLayouts.layouts[1].name == 'gp circuit',
  'switching back restores the first map\'s layouts')

-- Load broadcasts a state purge first, then the checkpoints, to every client
lastApplied = nil
lastCleared = nil
eventSeq = {}
RM_onLoadLayout(2, '{"name":"GP CIRCUIT"}')
check(lastApplied ~= nil and #lastApplied.checkpoints == 3
  and lastApplied.checkpoints[1].x == 100.5 and lastApplied.width == 30,
  'load broadcasts RM_ApplyLayout with saved checkpoints (case-insensitive)')
check(lastCleared ~= nil, 'load broadcasts RM_ClearTrack purge')
local clearIdx, applyIdx
for i, ev in ipairs(eventSeq) do
  if ev == 'RM_ClearTrack' and not clearIdx then clearIdx = i end
  if ev == 'RM_ApplyLayout' and not applyIdx then applyIdx = i end
end
check(clearIdx and applyIdx and clearIdx < applyIdx,
  'RM_ClearTrack is sent before RM_ApplyLayout')
lastApplied = nil
RM_onLoadLayout(2, '{"name":"Coast Run"}')
check(lastApplied == nil, 'layout from another map cannot be loaded')

-- Explicit clear-state command: purges clients and re-reads layouts from disk
lastCleared = nil
lastLayouts = nil
RM_onClearTrackState(1)
check(lastCleared ~= nil, 'RM_ClearTrackState broadcasts RM_ClearTrack')
check(lastLayouts ~= nil and #lastLayouts.layouts == 1
  and lastLayouts.layouts[1].name == 'gp circuit',
  'clear state re-reads persisted layouts from disk and rebroadcasts the list')

-- Malformed save payloads are rejected without touching the stored layouts
RM_onSaveLayout(1, 'not json at all {{{')
RM_onSaveLayout(1, '{"name":"","width":10,"checkpoints":' .. cpJson .. '}')
RM_onSaveLayout(1, '{"name":"Bad CPs","width":10,"checkpoints":[{"x":1,"y":2}]}')
RM_onRequestLayouts(1)
check(#lastLayouts.layouts == 1, 'malformed saves rejected, layout list unchanged')

-- Persistence: simulated server restart must re-read layouts.json from disk
-- (this also round-trips the real JSON encoder/parser).
dofile('server/RaceManager/main.lua')
onInit()
lastLayouts = nil
RM_onRequestLayouts(1)
check(lastLayouts ~= nil and #lastLayouts.layouts == 1
  and lastLayouts.layouts[1].name == 'gp circuit'
  and lastLayouts.layouts[1].checkpoints[1].y == 200.25,
  'layouts survive a server restart via layouts.json')

-- Clean up the directory tree the test created in the repo root
os.execute('rm -rf Resources')

if fails == 0 then
  io.stdout:write(('ALL PASS (%d checks)\n'):format(checks))
else
  io.stdout:write(('%d/%d FAILED\n'):format(fails, checks))
  os.exit(1)
end
