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

-- Strict recursive-descent JSON decoder. The plugin calls Util.JsonDecode under
-- pcall and treats a raised error as "reject this payload", so a payload that
-- is not valid JSON has to raise rather than silently produce a table -- which
-- is what the tests for malformed saves are actually asserting.
local function jsonDecode(text)
  if type(text) ~= 'string' then error('json: not a string', 0) end
  local pos = 1
  local function err(msg) error(('json: %s at %d'):format(msg, pos), 0) end
  local function ws() pos = text:match('^[ \t\r\n]*()', pos) end
  local parseValue
  local function parseString()
    pos = pos + 1  -- opening quote
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
  if pos <= #text then err('trailing garbage') end
  return v
end

Util = {
  -- Passthrough: the tests inspect the table directly.
  JsonEncode = function (t) return t end,
  JsonDecode = jsonDecode,
}

-- The suite writes into ./Resources and asserts on file counts, so a tree left
-- behind by an aborted run has to go before anything is loaded -- otherwise
-- stale layouts.json entries fail the layout-count checks. "rm -rf" is not a
-- command on Windows, where a good few BeamMP servers are hosted.
local function removeTree(path)
  if package.config:sub(1, 1) == '\\' then
    os.execute('rmdir /s /q "' .. path:gsub('/', '\\') .. '" 2>nul')
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end

-- Existence check that always closes the handle: an open handle keeps the file
-- locked on Windows, which would then defeat removeTree at the end of the run.
local function fileExists(path)
  local f = path and io.open(path, 'r')
  if f then f:close(); return true end
  return false
end

removeTree('Resources')

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

-- ---------------------------------------------------------------------------
-- Admin authentication: admin events now require a prior RM_Login with the
-- master password. Verify rejection, grant, and password rotation before the
-- rest of the suite logs in and drives the session.
-- ---------------------------------------------------------------------------
local function adminLogin(pid) RM_onLogin(pid, '{"password":"phoenix"}') end

RM_onLogin(1, '{"password":"wrong"}')          -- bad password: no admin rights
RM_onStartQualifying(1)
check(lastState == nil, 'admin command ignored before authentication')

adminLogin(1)                                   -- correct password: pid 1 admin
check(lastState ~= nil and lastState.adminPresent == true,
  'successful login broadcasts adminPresent=true to everyone')
adminLogin(2)

-- Change the master password (authed admin only) to an arbitrary value: the old
-- password then fails and the new one works. pid 7 probes the change.
RM_onChangePassword(1, '{"password":"n3w P@ss!"}')
lastState = nil
RM_onLogin(7, '{"password":"phoenix"}')         -- old password now invalid
RM_onSetTotalLaps(7, '{"laps":9}')
check(lastState == nil, 'login with the old password fails after a change')
RM_onLogin(7, '{"password":"n3w P@ss!"}')       -- new (arbitrary) password accepted
RM_onSetTotalLaps(7, '{"laps":9}')
check(lastState ~= nil and lastState.totalLaps == 9,
  'admin can set the password to an arbitrary value and log in with it')
RM_onChangePassword(7, '{"password":"phoenix"}')  -- restore default for the suite

-- Logout drops one admin's rights but adminPresent stays true while others
-- remain; it only flips false once the last admin logs out.
RM_onLogout(7)
check(lastState.adminPresent == true, 'adminPresent stays true while pids 1 & 2 are admin')
lastState = nil

-- Players connect. By default everyone on the server is in the field, so a
-- server nobody has configured grids the people who turned up.
RM_onPlayerJoin(1); RM_onPlayerJoin(2); RM_onPlayerJoin(3)
check(#lastState.drivers == 3, 'three drivers after join')
check(lastState.phase == 'waiting', 'initial phase waiting')
check(lastState.entryMode == 'all', 'race entry defaults to everyone racing')
check(lastState.entrants == 3, 'all three connected players are entered')

-- Switched to opt-in, connecting is NOT entering: the field is empty until
-- drivers press Join Race.
RM_onSetEntryMode(1, '{"mode":"join"}')
check(lastState.entrants == 0, 'nobody is entered before anyone joins')

-- Generate Grid with an empty entry list must not form a grid.
RM_onGenerateGrid(1)
check(lastState.phase == 'waiting', 'Generate Grid refused with no entrants')

-- Everyone enters the race.
RM_onJoinRace(1, '{"join":true}')
RM_onJoinRace(2, '{"join":true}')
RM_onJoinRace(3, '{"join":true}')
check(lastState.entrants == 3, 'three entrants after joining')
check(driver('Alice').joined == true, 'the entry flag is broadcast per driver')

-- Leaving takes a driver back out of the field, then they rejoin for the race.
RM_onJoinRace(3, '{"join":false}')
check(lastState.entrants == 2, 'leaving removes a driver from the entry list')
RM_onJoinRace(3, '{"join":true}')
check(lastState.entrants == 3, 'and rejoining puts them back')

-- Total laps setting (JSON path + clamping)
RM_onSetTotalLaps(1, '{"laps":2}')
check(lastState.totalLaps == 2, 'total laps set to 2')
RM_onSetTotalLaps(1, '{"laps":0}')
check(lastState.totalLaps == 1, 'laps clamped to minimum 1')
RM_onSetTotalLaps(1, '{"laps":2}')

-- Qualifying: Cara fastest, Bob middle, Alice slowest; Bob improves.
-- Qualifying runs the same lifecycle a race does — grid, hold, countdown, GO —
-- and reports its laps on the same event, so there is one lap path rather than
-- two that can drift apart.
RM_onStartQualifying(1)
check(lastState.phase == 'grid', 'Start Qualifying forms a grid')
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
check(lastState.phase == 'qualifying', 'phase qualifying after GO')
-- Out laps first: everyone gives one away off the standing start, and nothing
-- set on it reaches the board.
RM_onLap(1, '{"lapTime":50.0}')
RM_onLap(2, '{"lapTime":50.0}')
RM_onLap(3, '{"lapTime":50.0}')
check(driver('Bob').qualiBest == nil, 'nothing from the out lap reaches Best Lap')
RM_onLap(1, '{"lapTime":95.5}')
RM_onLap(2, '{"lapTime":99.0}')
RM_onLap(2, '{"lapTime":92.1}')   -- improvement
RM_onLap(2, '{"lapTime":97.0}')   -- slower, must not overwrite
RM_onLap(3, '{"lapTime":90.0}')
check(driver('Bob').qualiBest == 92.1, 'best lap keeps the fastest (92.1)')
check(driver('Bob').qualiLaps == 3, 'and every timed lap is counted')
-- Alice has crossed twice: the out lap, then one timed lap. The lap counter
-- counts CROSSINGS and is advanced by both — an out lap that left the counter
-- where it was would rank her against the field a lap down.
check(driver('Alice').currentLap == 3, 'a qualifying driver advances a lap like a racer')
check(driver('Alice').qualiLaps == 1, 'while the allowance only counts the timed one')

-- A lap reported outside a running session is ignored.
RM_onEndRace(1)
check(lastState.phase == 'waiting', 'ending qualifying drops back to waiting')
check(lastState.drivers[1].name == 'Cara', 'provisional order: Cara P1')
check(lastState.drivers[2].name == 'Bob',  'provisional order: Bob P2')
check(lastState.drivers[3].name == 'Alice','provisional order: Alice P3')
local aliceLap = driver('Alice').currentLap
RM_onLap(1, '{"lapTime":80}')
check(driver('Alice').currentLap == aliceLap, 'a lap outside a session is ignored')

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
-- Pos, then Start, then Driver: the race table carries the grid slot each
-- driver started from, which is what makes a finishing position mean anything.
check(raceSec:match('P1%s+%S+%s+Bob') and raceSec:find('RACE WINNER', 1, true),
  'Bob is the race winner in race section')
check(not raceSec:match('P%d+%s+Cara%s[^\n]*WINNER'), 'pole sitter is not tagged winner')
check(raceSec:match('DNF%s+%S+%s+Alice'), 'Alice listed as DNF')
check(raceSec:find('1:31.500', 1, true), "Bob's best race lap formatted in race section")
check(qualiSec:find('1:30.000', 1, true), "Cara's quali best formatted in quali section")
-- The lap count in this section is TIMED laps, and every driver crossed the line
-- once more than that. A results file is read months later by somebody who was
-- not there, so the format line has to say which laps were counted rather than
-- leave a discrepancy nobody can settle afterwards.
check(qualiSec:find('out lap not timed', 1, true),
  'the qualifying format line records that the out lap was not timed')
check(qualiSec:match('Cara%s+1:30%.000%s+1'),
  "Cara's out lap is not in her lap count")

-- Clear Results Cache: all .txt files removed, chat confirms
lastChat = nil
RM_onClearResults(2)
check(not fileExists(resultsPath), 'results file deleted by cache clear')
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
-- Alice (pid 1) disconnected mid-race above, which cleared her admin flag;
-- re-authenticate before the layout admin commands below.
adminLogin(1)
local cpJson = '[{"x":100.5,"y":200.25,"z":50,"hx":0,"hy":1},'
  .. '{"x":150,"y":260,"z":51,"hx":1,"hy":0},'
  .. '{"x":90,"y":300,"z":50,"hx":0,"hy":-1}]'

-- Save the currently placed checkpoints as a named layout
lastChat = nil
RM_onSaveLayout(1, '{"name":"GP Circuit","width":24,"checkpoints":' .. cpJson .. '}')
check(type(lastChat) == 'string' and lastChat:find('GP Circuit', 1, true)
  and lastChat:find('gridmap_v2', 1, true), 'chat announces layout save with map name')
check(fileExists('Resources/Server/RaceManager/layouts.json'),
  'layouts.json written to disk')
check(lastLayouts ~= nil and lastLayouts.map == 'gridmap_v2'
  and #lastLayouts.layouts == 1, 'save broadcasts refreshed layout list')
check(lastLayouts.layouts[1].width == 24
  and #lastLayouts.layouts[1].checkpoints == 3, 'saved layout keeps width and gates')
check(lastLayouts.layouts[1].height == 10,
  'saved layout gets the default height when the client omits it')

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
adminLogin(1); adminLogin(2)  -- restart reset auth state; re-authenticate admins
lastLayouts = nil
RM_onRequestLayouts(1)
check(lastLayouts ~= nil and #lastLayouts.layouts == 1
  and lastLayouts.layouts[1].name == 'gp circuit'
  and lastLayouts.layouts[1].checkpoints[1].y == 200.25,
  'layouts survive a server restart via layouts.json')

-- Gate dimensions + per-checkpoint overrides round-trip through save/persist.
-- A checkpoint is a flat width x height rectangle: there is no depth field any
-- more, and one arriving from an old client is dropped rather than stored.
-- (Added after the count assertions above so this second layout doesn't skew
-- them; the whole Resources tree is deleted at the end of the suite.)
local cpOvr = '[{"x":1,"y":2,"z":3,"hx":0,"hy":1,"width":40,"height":25,"depth":6},'
  .. '{"x":4,"y":5,"z":6,"hx":1,"hy":0}]'
local startJson = '[{"x":10,"y":20,"z":30,"hx":0,"hy":1},{"x":10,"y":15,"z":30,"hx":0,"hy":1}]'
RM_onSaveLayout(1, '{"name":"Banked Oval","width":30,"height":20,"checkpoints":' .. cpOvr
  .. ',"startPositions":' .. startJson .. '}')
local saved
for _, l in ipairs(lastLayouts.layouts) do if l.name == 'Banked Oval' then saved = l end end
check(saved ~= nil and saved.height == 20, 'saved layout keeps the layout-wide height')
check(saved and saved.checkpoints[1].width == 40 and saved.checkpoints[1].height == 25,
  'per-checkpoint override round-trips through save')
check(saved and saved.checkpoints[1].depth == nil,
  'a depth sent by an old client is dropped, not persisted')
check(saved and saved.checkpoints[2].width == nil and saved.checkpoints[2].height == nil,
  'a checkpoint without an override stays override-free')
-- The starting grid is saved with the track.
check(saved and saved.startPositions and #saved.startPositions == 2
  and saved.startPositions[1].x == 10, 'start positions are saved with the layout')
check(lastState.startSlots == 2, 'the server tracks how many start positions exist')
-- Load broadcasts the override fields and the grid to clients too.
lastApplied = nil
RM_onLoadLayout(1, '{"name":"Banked Oval"}')
check(lastApplied ~= nil and lastApplied.height == 20
  and lastApplied.checkpoints[1].width == 40,
  'ApplyLayout broadcast carries the height and gate overrides')
check(lastApplied and lastApplied.startPositions
  and #lastApplied.startPositions == 2, 'ApplyLayout broadcast carries the starting grid')

-- ---------------------------------------------------------------------------
-- Ghost drivers: a driver who disconnected mid-race is kept as DNF for the
-- results file, but must be purged by the next Generate Grid — otherwise the
-- ghost turns 'racing' at GO, never laps, and blocks the auto-finish forever.
-- (State is fresh here: the file was just re-dofile'd + onInit'd above.)
-- ---------------------------------------------------------------------------
RM_onPlayerJoin(1); RM_onPlayerJoin(2); RM_onPlayerJoin(3)
-- This block predates the entry list, so it uses the "everyone races" mode.
RM_onSetEntryMode(1, '{"mode":"all"}')
RM_onSetTotalLaps(1, '{"laps":1}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
connected[3] = nil
RM_onPlayerDisconnect(3)                -- Cara drops mid-race -> DNF
lastChat = nil
RM_onLap(1, '{"lapTime":90}')
RM_onLap(2, '{"lapTime":91}')
check(lastState.phase == 'finished', 'ghost setup: race 1 finished')
check(driver('Cara') ~= nil and driver('Cara').status == 'dnf',
  'ghost setup: Cara kept as DNF for the race 1 results')
local ghostPath1 = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')

RM_onGenerateGrid(1)                    -- next race, no Reset in between
check(#lastState.drivers == 2, 'Generate Grid purges disconnected ghost records')
check(driver('Cara') == nil, 'ghost driver no longer listed')
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lastChat = nil
RM_onLap(1, '{"lapTime":90}')
RM_onLap(2, '{"lapTime":91}')
check(lastState.phase == 'finished', 'race 2 auto-finishes without the ghost')
connected[3] = 'Cara'

-- Two sessions ending within the same second must not overwrite each other's
-- results file: the second one gets a _2 suffix.
local ghostPath2 = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
check(ghostPath1 and ghostPath2 and ghostPath1 ~= ghostPath2,
  'same-second sessions write distinct results files')
check(fileExists(ghostPath1) and fileExists(ghostPath2),
  'both results files exist on disk')

-- ===========================================================================
-- Fastest lap of the session
-- ===========================================================================
-- One driver's time is painted gold on every leaderboard, so the server has to
-- own "who is fastest" rather than each client deciding for itself. It is kept
-- incrementally as laps are scored -- a lap arrives a few times a minute, a
-- broadcast goes out three times a second, so scanning the field per broadcast
-- would be the wrong way round.
RM_onLogin(1, '{"password":"phoenix"}')
RM_onResetLeaderboard(1)
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onJoinRace(1, '{"join":true}')
RM_onJoinRace(2, '{"join":true}')
-- A long race, so nobody takes the flag part-way through this and stops being
-- eligible to score laps.
RM_onSetTotalLaps(1, '{"laps":10}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()

RM_onRequestState(1)
check(lastState.bestLapPid == nil, 'no fastest lap before anyone has set one')

RM_onLap(1, '{"lapTime":95.5}')
check(lastState.bestLapPid == 1, 'the first lap set is the fastest lap')
check(math.abs(lastState.bestLapTime - 95.5) < 1e-6, 'and its time is broadcast')

RM_onLap(2, '{"lapTime":97.0}')
check(lastState.bestLapPid == 1, 'a slower lap does not take the fastest lap')

RM_onLap(2, '{"lapTime":94.25}')
check(lastState.bestLapPid == 2, 'a quicker lap takes it')
check(math.abs(lastState.bestLapTime - 94.25) < 1e-6, 'and the time follows')

-- It belongs to the SESSION: a new one starts with nobody holding it, or the
-- gold would be sitting on a time set in a race that is over.
RM_onEndRace(1)
RM_onResetLeaderboard(1)
RM_onRequestState(1)
check(lastState.bestLapPid == nil, 'a new session starts with no fastest lap')
connected[3] = 'Cara'

-- ===========================================================================
-- Results file: the Start column and the Hard Charger
-- ===========================================================================
-- Where a driver STARTED is half of what makes a result readable -- "P2" means
-- nothing without knowing they qualified eighth -- and the Hard Charger is the
-- driver who gained the most places between the two.
RM_onLogin(1, '{"password":"phoenix"}')
RM_onResetLeaderboard(1)
connected[3] = 'Cara'
for id in pairs(connected) do RM_onPlayerJoin(id) end
for id in pairs(connected) do RM_onJoinRace(id, '{"join":true}') end
RM_onSetTotalLaps(1, '{"laps":1}')
-- A known grid: Alice pole, Bob second, Cara third.
RM_onSetGridMode(1, '{"mode":"custom"}')
RM_onSetDriverGrid(1, '{"pid":1,"slot":1}')
RM_onSetDriverGrid(1, '{"pid":2,"slot":2}')
RM_onSetDriverGrid(1, '{"pid":3,"slot":3}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()

-- Cara wins from P3, Alice second from pole, Bob third from P2.
lastChat = nil
RM_onLap(3, '{"lapTime":90.0}')
RM_onLap(1, '{"lapTime":91.0}')
RM_onLap(2, '{"lapTime":92.0}')

local hcPath = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
local hcFile = hcPath and io.open(hcPath, 'r')
local hcText = hcFile and hcFile:read('*a') or ''
if hcFile then hcFile:close() end

check(hcText:find('Start', 1, true) ~= nil, 'the results table has a Start column')
-- Cara started P3 and won, so her row carries both.
local caraRow = nil
for line in hcText:gmatch('[^\n]+') do
  if line:find('Cara', 1, true) and line:find('^P1%s') then caraRow = line end
end
check(caraRow ~= nil, 'the winning row is present')
check(caraRow and caraRow:find('P3', 1, true) ~= nil,
  'and records the grid slot she started from')

check(hcText:find('HARD CHARGER', 1, true) ~= nil, 'the results name a Hard Charger')
local hcLine = nil
for line in hcText:gmatch('[^\n]+') do
  if line:find('HARD CHARGER', 1, true) then hcLine = line end
end
check(hcLine and hcLine:find('Cara', 1, true) ~= nil,
  'the Hard Charger is the driver who gained the most places')
check(hcLine and hcLine:find('+2', 1, true) ~= nil, 'and the gain is stated')

-- A tie on places gained goes to the driver who finished higher. Bob and Dan
-- both gain two places; Bob finishes first and Dan second, so it is Bob's.
RM_onResetLeaderboard(1)
connected[4] = 'Dan'
for id in pairs(connected) do RM_onPlayerJoin(id) end
for id in pairs(connected) do RM_onJoinRace(id, '{"join":true}') end
RM_onSetTotalLaps(1, '{"laps":1}')
RM_onSetGridMode(1, '{"mode":"custom"}')
-- Custom slots are renumbered to 1..N in the order given, so these ARE the
-- grid positions the race starts from.
RM_onSetDriverGrid(1, '{"pid":3,"slot":1}')   -- Cara  P1
RM_onSetDriverGrid(1, '{"pid":1,"slot":2}')   -- Alice P2
RM_onSetDriverGrid(1, '{"pid":2,"slot":3}')   -- Bob   P3
RM_onSetDriverGrid(1, '{"pid":4,"slot":4}')   -- Dan   P4
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lastChat = nil
-- Finishing order, spaced on the server clock so it is unambiguous.
RM_onLap(2, '{"lapTime":90.0}'); RM_Tick()    -- Bob   P3 -> P1  (+2)
RM_onLap(4, '{"lapTime":91.0}'); RM_Tick()    -- Dan   P4 -> P2  (+2)
RM_onLap(3, '{"lapTime":92.0}'); RM_Tick()    -- Cara  P1 -> P3
RM_onLap(1, '{"lapTime":93.0}')               -- Alice P2 -> P4

local tiePath = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
local tieFile = tiePath and io.open(tiePath, 'r')
local tieText = tieFile and tieFile:read('*a') or ''
if tieFile then tieFile:close() end
local tieLine = nil
for line in tieText:gmatch('[^\n]+') do
  if line:find('HARD CHARGER', 1, true) then tieLine = line end
end
check(tieLine and tieLine:find('Bob', 1, true) ~= nil,
  'a tie on places gained goes to the higher finisher')
check(tieLine and tieLine:find('Dan', 1, true) == nil,
  'and not to the driver who gained the same but finished lower')

-- ===========================================================================
-- Half-way leader
-- ===========================================================================
-- Who led at half distance, rounded UP on an odd number of laps: a 5-lap race
-- is decided at lap 3, the same as a 6-lap one.
RM_onResetLeaderboard(1)
for id in pairs(connected) do RM_onPlayerJoin(id) end
for id in pairs(connected) do RM_onJoinRace(id, '{"join":true}') end
RM_onSetTotalLaps(1, '{"laps":5}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lastChat = nil
-- Alice leads laps 1 and 2, Cara takes the lead on lap 3 (half way) and keeps
-- it. The half-way leader must be Cara, not the eventual winner by default and
-- not whoever led the first lap.
-- Every entrant has to complete every lap or the race never ends: Dan is still
-- on the entry list from the tie case above.
for _ = 1, 2 do
  RM_onLap(1, '{"lapTime":90.0}'); RM_Tick()
  RM_onLap(3, '{"lapTime":91.0}'); RM_Tick()
  RM_onLap(2, '{"lapTime":92.0}'); RM_Tick()
  RM_onLap(4, '{"lapTime":93.0}'); RM_Tick()
end
for _ = 3, 5 do
  RM_onLap(3, '{"lapTime":89.0}'); RM_Tick()
  RM_onLap(1, '{"lapTime":90.0}'); RM_Tick()
  RM_onLap(2, '{"lapTime":92.0}'); RM_Tick()
  RM_onLap(4, '{"lapTime":93.0}'); RM_Tick()
end

local hwPath = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
local hwFile = hwPath and io.open(hwPath, 'r')
local hwText = hwFile and hwFile:read('*a') or ''
if hwFile then hwFile:close() end
local hwLine = nil
for line in hwText:gmatch('[^\n]+') do
  if line:find('HALF-WAY LEADER', 1, true) then hwLine = line end
end
check(hwLine ~= nil, 'the results name a half-way leader')
check(hwLine and hwLine:find('Cara', 1, true) ~= nil,
  'the half-way leader is whoever led the half-way lap')
check(hwLine and hwLine:find('lap 3 of 5', 1, true) ~= nil,
  'a 5-lap race rounds half distance up to lap 3')

-- A one-lap race has no half way -- lap 1 is the flag.
RM_onResetLeaderboard(1)
for id in pairs(connected) do RM_onPlayerJoin(id) end
for id in pairs(connected) do RM_onJoinRace(id, '{"join":true}') end
RM_onSetTotalLaps(1, '{"laps":1}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lastChat = nil
RM_onLap(1, '{"lapTime":90.0}'); RM_Tick()
RM_onLap(2, '{"lapTime":91.0}'); RM_Tick()
RM_onLap(3, '{"lapTime":92.0}'); RM_Tick()
RM_onLap(4, '{"lapTime":93.0}')
local shortPath = lastChat and lastChat:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
local shortFile = shortPath and io.open(shortPath, 'r')
local shortText = shortFile and shortFile:read('*a') or ''
if shortFile then shortFile:close() end
check(shortText ~= '' and shortText:find('HALF-WAY LEADER', 1, true) == nil,
  'a one-lap race reports no half-way leader')

-- ===========================================================================
-- Point to point: a sprint stage is one traversal
-- ===========================================================================
-- Setting a circuit to one lap times the same thing, which is why that was the
-- workaround. The difference is that it reads as a one-lap circuit everywhere,
-- and the lap count stops being a setting the admin has to remember.
RM_onLogin(1, '{"password":"phoenix"}')
RM_onResetLeaderboard(1)
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onJoinRace(1, '{"join":true}')
RM_onSetTotalLaps(1, '{"laps":7}')
RM_onSetPointToPoint(1, '{"enabled":true}')
check(lastState.pointToPoint == true, 'the track can be set to point to point')

RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lastChat = nil
-- One traversal finishes the stage, even though Laps still says seven.
RM_onLap(1, '{"lapTime":95.0}')
check(driver('Alice') and driver('Alice').status ~= 'racing',
  'crossing the last gate once finishes a point-to-point stage')
check(lastState.totalLaps == 7,
  'and the lap setting is kept, not clamped, so a circuit layout restores it')

-- Switched back to a circuit, the lap count means what it says again.
RM_onResetLeaderboard(1)
RM_onSetPointToPoint(1, '{"enabled":false}')
check(lastState.pointToPoint == false, 'and it can be switched back to a circuit')
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onJoinRace(1, '{"join":true}')
RM_onSetTotalLaps(1, '{"laps":2}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
RM_onLap(1, '{"lapTime":95.0}')
check(driver('Alice') and driver('Alice').status == 'racing',
  'a two-lap circuit is not finished by one lap')
RM_onLap(1, '{"lapTime":94.0}')
check(driver('Alice') and driver('Alice').status ~= 'racing', 'the second lap finishes it')

-- The mode is locked once a session is under way: the shape of a race must not
-- change under the drivers running it.
RM_onResetLeaderboard(1)
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onJoinRace(1, '{"join":true}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_onSetPointToPoint(1, '{"enabled":true}')
check(lastState.pointToPoint == false, 'the mode cannot be changed mid-session')
RM_onEndRace(1)

-- adminPresent flips false only once every admin has logged out (so non-admin
-- clients know they can bypass the login and just spectate).
RM_onLogout(1); RM_onLogout(2)
lastState = nil
RM_onRequestState(1)
check(lastState.adminPresent == false, 'adminPresent is false after all admins log out')

-- ---------------------------------------------------------------------------
-- Branching routes: persistence, validation, and the lane a grid slot decides
-- ---------------------------------------------------------------------------
-- A branch is a sparse set of per-slot gate overrides on the main route. The
-- server never tests a crossing -- it has no physics -- so its whole job here is
-- to validate the shape, keep it on disk, hand it back out, and decide which
-- lane each grid slot puts a driver in.
adminLogin(1)
MP.Settings.Map = 0
hostedMap = '/levels/gridmap_v2/info.json'
RM_onRequestLayouts(1)

local branchJson = '[{"id":"ccw","name":"Counter-clockwise","gates":['
  .. '{"slot":1,"x":-100,"y":0,"z":0,"hx":0,"hy":1},'
  .. '{"slot":3,"x":100,"y":0,"z":0,"hx":0,"hy":-1}]}]'

lastLayouts = nil
RM_onSaveLayout(1, '{"name":"Suicide Oval","width":20,"checkpoints":' .. cpJson
  .. ',"branches":' .. branchJson .. ',"gridOffLine":true}')
local saved
for _, l in ipairs(lastLayouts and lastLayouts.layouts or {}) do
  if l.name == 'Suicide Oval' then saved = l end
end
check(saved ~= nil, 'a layout with lanes saves')
check(saved and type(saved.branches) == 'table' and #saved.branches == 1,
  'the lane survives the round trip')
check(saved and saved.branches[1].id == 'ccw'
  and saved.branches[1].name == 'Counter-clockwise', 'lane id and name are kept')
check(saved and #saved.branches[1].gates == 2, 'both override gates are kept')
check(saved and saved.branches[1].gates[1].slot == 1
  and saved.branches[1].gates[2].slot == 3,
  'each gate keeps the SLOT it stands in for -- which is what makes it an override')
check(saved and saved.gridOffLine == true, 'the grid-off-line flag travels with the track')

-- An ordinary layout emits no branches key at all, so nothing about a plain
-- circuit changes on disk.
for _, l in ipairs(lastLayouts.layouts) do
  if l.name == 'GP Circuit' then
    check(l.branches == nil, 'a layout with no lanes stores no branches key')
    check(l.gridOffLine == false, 'and is not marked grid-off-line')
  end
end

-- Validation. Every one of these is a lane that would put half a field on a
-- line that is not there, so the whole save is refused rather than quietly
-- stored without it.
local function rejects(what, branches)
  local before = #lastLayouts.layouts
  RM_onSaveLayout(1, '{"name":"Bad ' .. what .. '","width":20,"checkpoints":' .. cpJson
    .. ',"branches":' .. branches .. '}')
  check(#lastLayouts.layouts == before, 'rejected: ' .. what)
end
rejects('slot past the end of the route',
  '[{"id":"x","gates":[{"slot":9,"x":1,"y":2,"z":3,"hx":0,"hy":1}]}]')
rejects('slot below one',
  '[{"id":"x","gates":[{"slot":0,"x":1,"y":2,"z":3,"hx":0,"hy":1}]}]')
rejects('two gates on the same slot',
  '[{"id":"x","gates":[{"slot":1,"x":1,"y":2,"z":3,"hx":0,"hy":1},'
    .. '{"slot":1,"x":4,"y":5,"z":6,"hx":0,"hy":1}]}]')
rejects('a lane with no gates', '[{"id":"x","gates":[]}]')
rejects('a lane with no id', '[{"gates":[{"slot":1,"x":1,"y":2,"z":3,"hx":0,"hy":1}]}]')
rejects('two lanes sharing an id',
  '[{"id":"x","gates":[{"slot":1,"x":1,"y":2,"z":3,"hx":0,"hy":1}]},'
    .. '{"id":"x","gates":[{"slot":2,"x":1,"y":2,"z":3,"hx":0,"hy":1}]}]')
rejects('a gate with no coordinates', '[{"id":"x","gates":[{"slot":1}]}]')

-- Loading it arms the session with the lanes and the out lap.
RM_onLoadLayout(1, '{"name":"Suicide Oval"}')
lastState = nil
RM_onRequestState(1)
check(lastState.hasBranches == true, 'loading the track tells every client it has lanes')
check(lastState.gridOffLine == true, 'and that its grid is away from the line')
check(lastState.qualiOutLap == true,
  'so a RACE on it owes an out lap -- the part lap from the grid is not timed')

-- THE LANE A GRID SLOT DECIDES. This is the only place a driver's direction is
-- settled: the server hands out the slot and reads the tag off it, so nothing is
-- asked of the client and nothing has to be trusted.
local startJson = '[{"x":0,"y":-100,"z":0,"hx":1,"hy":0},'
  .. '{"x":0,"y":-108,"z":0,"hx":1,"hy":0},'
  .. '{"x":0,"y":-100,"z":0,"hx":-1,"hy":0,"branch":"ccw"},'
  .. '{"x":0,"y":-92,"z":0,"hx":-1,"hy":0,"branch":"ccw"}]'
RM_onStartPositionCount(1, '{"count":4,"positions":' .. startJson
  .. ',"gridOffLine":true,"laneNames":[{"id":"ccw","name":"Counter-clockwise"}]}')

RM_onSetEntryMode(1, '{"mode":"all"}')
RM_onSetTotalLaps(1, '{"laps":3}')
RM_onGenerateGrid(1)
lastState = nil
RM_onRequestState(1)
local bySlot = {}
for _, d in ipairs(lastState.drivers) do
  if d.gridPos then bySlot[d.gridPos] = d end
end
check(bySlot[1] and bySlot[1].lane == nil, 'slot 1 races the main route')
check(bySlot[2] and bySlot[2].lane == nil, 'slot 2 races the main route')
check(bySlot[3] and bySlot[3].lane == 'ccw', 'slot 3 races the other way round')
check(bySlot[4] and bySlot[4].lane == 'ccw', 'slot 4 races the other way round')
check(bySlot[1] and bySlot[1].outLap == true,
  'and everyone on the grid owes the out lap first')

-- THE OUT LAP ON A RACE, which is what stops a head-on grid posting a fastest
-- lap nobody drove. The cars start scattered round the circuit, so the run to
-- the first crossing is a fraction of a lap.
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lastState = nil
RM_onRequestState(1)
check(lastState.phase == 'racing', 'the head-on race starts')

-- The part lap. A wildly quick "lap time" that would win fastest lap outright.
RM_onLap(1, '{"lapTime":9.5}')
lastState = nil
RM_onRequestState(1)
check(driver('Alice').raceBest == nil,
  'the part lap from the grid sets no Best Lap')
check(lastState.bestLapPid == nil,
  'and cannot take fastest lap of the race, which is the whole point of it')
check(driver('Alice').outLap == false, 'the out lap is spent after one crossing')
check(driver('Alice').currentLap == 2, 'but it still counted as a crossing')

-- From here every crossing is a real lap and is scored normally.
RM_onLap(1, '{"lapTime":42.0}')
check(driver('Alice').raceBest == 42.0, 'the first timed lap goes on the board')
lastState = nil
RM_onRequestState(1)
check(lastState.bestLapPid == 1, 'and takes fastest lap')

-- A three lap race owes four crossings: the out lap plus three racing laps.
RM_onLap(1, '{"lapTime":41.0}')
check(driver('Alice').status ~= 'finished', 'still running after two timed laps')
RM_onLap(1, '{"lapTime":40.5}')
check(driver('Alice').status == 'finished',
  'the flag falls on the third TIMED lap, not the third crossing')
check(driver('Alice').raceBest == 40.5, 'the last lap is scored like any other')

-- The lane a driver ran is recorded on their row for the results file.
check(driver('Cara').lane == 'ccw' or driver('Dan').lane == 'ccw',
  'a driver gridded on a tagged slot carries that lane through the race')
RM_onEndRace(1)

-- Clean up the directory tree the test created in the repo root
removeTree('Resources')

if fails == 0 then
  io.stdout:write(('ALL PASS (%d checks)\n'):format(checks))
else
  io.stdout:write(('%d/%d FAILED\n'):format(fails, checks))
  os.exit(1)
end
