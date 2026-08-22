-- Headless test for server/RaceManager/main.lua (Lua 5.3, same as BeamMP).
-- Mocks the MP/Util API, then drives a full session:
-- quali laps -> generate grid -> countdown -> race with laps led -> finish
-- -> automatic results .txt export + chat announcement -> cache clear.
-- Run from the repo root: lua5.3 tests/server_test.lua

local connected = { [1] = 'Alice', [2] = 'Bob', [3] = 'Cara' }
local lastState = nil     -- last decoded RM_Update payload
local targetedStates = {} -- [pid] = last RM_Update sent to that pid alone
local lastChat = nil      -- last broadcast chat message
local lastLayouts = nil   -- last RM_Layouts payload
local lastHeld    = nil   -- last RM_SaveHeld payload (a refused overwrite)
local lastLogin   = nil   -- last RM_LoginResult payload
local appliedLayouts = {} -- [target] = last RM_ApplyLayout payload
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
    -- Kept PER TARGET as well as last-wins. The "you" fields (youAreAdmin,
    -- youSpectating) only ride on targeted sends, so a test that reads them off
    -- the global broadcast is reading a payload that never carried them.
    if event == 'RM_Update' then
      lastState = payload
      if target ~= -1 then targetedStates[target] = payload end
    end
    if event == 'RM_Layouts'     then lastLayouts = payload end
    if event == 'RM_ApplyLayout' then lastApplied = payload; appliedLayouts[target] = payload end
    if event == 'RM_ClearTrack'  then lastCleared = payload end
    if event == 'RM_SaveHeld'    then lastHeld    = payload end
    if event == 'RM_LoginResult' then lastLogin   = payload end
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
local function targetedState(pid) return targetedStates[pid] end

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

-- ---------------------------------------------------------------------------
-- Flags: advisory, admin-only, and never carried into the next session
-- ---------------------------------------------------------------------------
-- The flag is a FIELD, not a phase. There are fifty-odd `phase ==` tests across
-- the two Lua halves and most would be wrong by default for a new one, so a
-- caution rides alongside `racing` rather than replacing it. These checks are
-- what keep it that way.

removeTree('Resources')

dofile('server/RaceManager/main.lua')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
-- PAST THE HOLD AT THE FLAG. A race no longer closes on the tick the last car
-- crosses: it holds for race.endDelay seconds first, so finished drivers stay
-- ghosted long enough to see the finish. Anything that reads the results file
-- has to let that expire.
local function settleRace()
  for _ = 1, 70 do RM_Tick() end
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
-- Cleared first: server startup legitimately broadcasts once (clearing the track
-- is state the panel displays), so "nil since boot" is not what this is testing.
-- What it tests is that the REFUSED command changes nothing.
lastState = nil
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
check(lastState.entrants == 3, 'all three connected players are entered')

-- SPECTATING IS THE ONLY WAY OUT of the field, and it is the driver's own call:
-- no admin rights, no entry mode to set first.
RM_onSetSpectating(1, '{"spectating":true}')
RM_onSetSpectating(2, '{"spectating":true}')
RM_onSetSpectating(3, '{"spectating":true}')
check(lastState.entrants == 0, 'a server where everyone spectates has no field')
check(driver('Alice').spectating == true, 'the spectating flag is broadcast per driver')

-- Generate Grid with an empty entry list must not form a grid.
RM_onGenerateGrid(1)
check(lastState.phase == 'waiting', 'Generate Grid refused with no entrants')

-- Rejoining is the same button again. This is the path that had no way back:
-- a driver could sit out and then could not put themselves in.
RM_onSetSpectating(1, '{"spectating":false}')
-- AND THE PANEL HAS TO BE TOLD. youSpectating is a targeted field, and it was
-- built with `rec and rec.spectating == true or nil`, which cannot return false:
-- the `or` swallowed it, the key dropped out of the JSON, and the panel kept the
-- last value it saw. Spectating ON could be sent; spectating OFF could not, so a
-- driver rejoined the field and was still told they were spectating.
check(targetedState(1) ~= nil and targetedState(1).youSpectating == false,
  'a driver who rejoined is told so, not left with the last value')
-- A REDUNDANT REQUEST STILL ANSWERS. If the panel has drifted it will ask for a
-- state the server already holds; returning silently there is what leaves the
-- wrong answer on screen with no way to correct it. Every press is a resync.
targetedStates[1] = nil
RM_onSetSpectating(1, '{"spectating":false}')   -- already false
check(targetedState(1) ~= nil and targetedState(1).youSpectating == false,
  'asking for the state you are already in still resyncs the panel')
RM_onSetSpectating(2, '{"spectating":false}')
check(lastState.entrants == 2, 'rejoining puts a driver back in the field')
RM_onSetSpectating(3, '{"spectating":false}')
check(lastState.entrants == 3, 'and the last one back makes three')

-- Total laps setting (JSON path + clamping)
RM_onSetTotalLaps(1, '{"laps":2}')
check(lastState.totalLaps == 2, 'total laps set to 2')
RM_onSetTotalLaps(1, '{"laps":0}')
check(lastState.totalLaps == 1, 'laps clamped to minimum 1')
RM_onSetTotalLaps(1, '{"laps":2}')

-- Qualifying: Cara fastest, Bob middle, Alice slowest; Bob improves.
-- Qualifying runs the same lifecycle a race does - grid, hold, countdown, GO
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
-- counts CROSSINGS and is advanced by both - an out lap that left the counter
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
check(lastLayouts.layouts[1].height == 8 and lastLayouts.layouts[1].depth == 2,
  'saved layout gets the default height AND depth when the client omits them. '
    .. 'The default is weighted upward: the total is the 10 metres it always '
    .. 'was, but 8 of it is above the road instead of 5')

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

-- ---------------------------------------------------------------------------
-- PRIVATE LOAD: one admin opening a layout in their own editor
-- ---------------------------------------------------------------------------
-- Two admins on one map have to be able to build at the same time. Loading a
-- layout used to move the WHOLE SERVER onto it, so an admin opening a track to
-- work on it dragged everyone else onto it too and overwrote the other admin's
-- work in progress. `forEditing` is the private sense of the same request: the
-- layout goes to the one client that asked and no server state moves.
--
-- A second layout on this map, so "the server is on A" and "an admin opened B"
-- are distinguishable states rather than the same one.
local cpAlt = '[{"x":900,"y":10,"z":5,"hx":0,"hy":1},'
  .. '{"x":940,"y":80,"z":5,"hx":1,"hy":0},'
  .. '{"x":880,"y":140,"z":5,"hx":0,"hy":-1}]'
RM_onSaveLayout(1, '{"name":"Club Circuit","width":12,"checkpoints":' .. cpAlt .. '}')

-- The server is publicly on GP Circuit.
RM_onLoadLayout(2, '{"name":"GP Circuit"}')
check(appliedLayouts[-1] ~= nil and appliedLayouts[-1].width == 30,
  'public load broadcasts to every client')

-- Admin 1 opens the OTHER layout privately.
appliedLayouts = {}
lastCleared = nil
eventSeq = {}
RM_onLoadLayout(1, '{"name":"Club Circuit","forEditing":true}')
check(appliedLayouts[1] ~= nil and appliedLayouts[1].width == 12,
  'private load sends the layout to the admin who asked')
check(appliedLayouts[-1] == nil,
  'private load does NOT broadcast the layout to everyone')
check(lastCleared ~= nil, 'private load still purges the asking client first')

-- Nothing global moved. This is the assertion that matters: another client
-- asking the server what track it is on must still be told GP Circuit, because
-- race.layout was never touched.
appliedLayouts = {}
RM_onRequestState(2)
check(appliedLayouts[2] ~= nil and appliedLayouts[2].width == 30,
  'the server is still on the publicly loaded track after a private load')
check(appliedLayouts[2].name ~= 'Club Circuit',
  'a private load never becomes the raced track')

-- ...and the public path still works afterwards, so the two senses do not
-- interfere. An admin who opened a track to edit it can still put the server on
-- it when they are ready.
appliedLayouts = {}
RM_onLoadLayout(1, '{"name":"Club Circuit"}')
check(appliedLayouts[-1] ~= nil and appliedLayouts[-1].width == 12,
  'a layout opened privately can still be loaded publicly afterwards')

-- Private load obeys the same admin gate as the public one.
appliedLayouts = {}
RM_onLoadLayout(3, '{"name":"GP Circuit","forEditing":true}')
check(appliedLayouts[3] == nil, 'a non-admin cannot open a layout in the editor')

-- Put the map back the way this block found it: one layout, and the server on
-- it. The persistence and clear-state assertions below count what is on disk,
-- so a scratch layout left behind here fails them somewhere else entirely.
RM_onDeleteLayout(1, '{"name":"Club Circuit"}')
RM_onLoadLayout(1, '{"name":"GP Circuit"}')
check(lastLayouts ~= nil and #lastLayouts.layouts == 1,
  'the private-load block leaves the layout list as it found it')

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
-- DEPTH IS CARRIED NOW, and it is not the old one. The dropped field was a
-- third box dimension from when a gate was a volume. This one is the other half
-- of the vertical: height is how far a gate rises above the point it was placed
-- at, depth how far it drops below, so a gate can be tall enough to see without
-- an equal amount of it buried under the road.
check(saved and saved.checkpoints[1].depth == 6,
  'a per-checkpoint depth round-trips through save')
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
-- The silent-drop guard: an overwrite may not quietly empty a saved layout
-- ---------------------------------------------------------------------------
-- The bug this exists for: an admin loaded a track with a joker route, a pit
-- stall and a grid, nudged some pole heights, saved under the same name, and
-- got back a layout with none of them. A save writes whatever the sending
-- client is holding, and any client-side path that empties one collection while
-- leaving the route alone turned the next same-name save into permanent,
-- unannounced data loss. So the server now compares against what it already
-- holds and refuses rather than shreds.
local fullJson = '{"name":"Full Track","width":20,"height":10,"checkpoints":'
  .. '[{"x":0,"y":100,"z":0,"hx":0,"hy":1},{"x":0,"y":200,"z":0,"hx":0,"hy":1}]'
  .. ',"joker":[{"x":50,"y":150,"z":0,"hx":1,"hy":0}]'
  .. ',"pits":[{"x":-50,"y":100,"z":0,"hx":1,"hy":0}]'
  .. ',"startPositions":[{"x":0,"y":0,"z":0,"hx":0,"hy":1},{"x":4,"y":0,"z":0,"hx":0,"hy":1}]}'
RM_onSaveLayout(1, fullJson)
local function storedLayout(name)
  for _, l in ipairs(lastLayouts.layouts) do if l.name == name then return l end end
end
local full = storedLayout('Full Track')
check(full and full.joker and #full.joker == 1 and full.pits and #full.pits == 1
  and full.startPositions and #full.startPositions == 2,
  'the full track saves with its joker route, pit lane and grid')

-- The exact shape of the loss: same name, same gates, everything else gone.
local strippedJson = '{"name":"Full Track","width":20,"height":14,"checkpoints":'
  .. '[{"x":0,"y":100,"z":0,"hx":0,"hy":1},{"x":0,"y":200,"z":0,"hx":0,"hy":1}]}'
lastHeld, lastChat = nil, nil
RM_onSaveLayout(1, strippedJson)
check(lastHeld ~= nil, 'a save that would empty a section of the stored layout is held back')
check(lastHeld and lastHeld.name == 'Full Track', 'the held save names the layout at risk')
check(lastHeld and lastHeld.lost and lastHeld.lost.joker == 1
  and lastHeld.lost.pits == 1 and lastHeld.lost.startPositions == 2,
  'and says exactly what would have gone, so the admin can be asked')
RM_onRequestLayouts(1)
full = storedLayout('Full Track')
check(full and full.joker and #full.joker == 1 and full.pits and #full.pits == 1
  and full.startPositions and #full.startPositions == 2,
  'and NOTHING is written -- the saved layout still has all three')
check(full and full.height == 10, 'not even the part of the save that was fine')

-- Shrinking a section is ordinary editing and passes straight through. Only
-- emptying one outright is the accident being guarded against.
local fewerStarts = '{"name":"Full Track","width":20,"height":10,"checkpoints":'
  .. '[{"x":0,"y":100,"z":0,"hx":0,"hy":1},{"x":0,"y":200,"z":0,"hx":0,"hy":1}]'
  .. ',"joker":[{"x":50,"y":150,"z":0,"hx":1,"hy":0}]'
  .. ',"pits":[{"x":-50,"y":100,"z":0,"hx":1,"hy":0}]'
  .. ',"startPositions":[{"x":0,"y":0,"z":0,"hx":0,"hy":1}]}'
lastHeld = nil
RM_onSaveLayout(1, fewerStarts)
check(lastHeld == nil, 'deleting one start position of two is not held back')
full = storedLayout('Full Track')
check(full and #full.startPositions == 1, 'and the edit is saved')

-- The admin was asked, and said yes. That has to work, or the guard becomes a
-- wall around every track that ever had a joker route.
lastHeld = nil
RM_onSaveLayout(1, strippedJson:gsub('}$', ',"confirmDrop":true}'))
check(lastHeld == nil, 'a confirmed save is not held back')
full = storedLayout('Full Track')
check(full and full.joker == nil and full.pits == nil and full.startPositions == nil,
  'and the admin gets the stripped layout they explicitly asked for')
check(full and full.height == 14, 'along with the rest of that save')

-- A NEW layout has nothing to lose and is never held.
lastHeld = nil
RM_onSaveLayout(1, '{"name":"Brand New","width":20,"checkpoints":'
  .. '[{"x":0,"y":100,"z":0,"hx":0,"hy":1}]}')
check(lastHeld == nil, 'a first save under a fresh name is never held back')

-- ---------------------------------------------------------------------------
-- Deleting a layout
-- ---------------------------------------------------------------------------
RM_onDeleteLayout(1, '{"name":"brand new"}')   -- names match case-insensitively
RM_onRequestLayouts(1)
check(storedLayout('Brand New') == nil, 'a layout can be deleted, name case ignored')
check(storedLayout('Full Track') ~= nil, 'and only that one goes')

-- Non-admins cannot delete.
RM_onDeleteLayout(99, '{"name":"Full Track"}')
RM_onRequestLayouts(1)
check(storedLayout('Full Track') ~= nil, 'a non-admin cannot delete a layout')

-- The delete has to reach disk, or it comes back on the next restart.
dofile('server/RaceManager/main.lua')
onInit()
adminLogin(1); adminLogin(2)
RM_onRequestLayouts(1)
check(storedLayout('Brand New') == nil, 'the delete survives a server restart')

-- ---------------------------------------------------------------------------
-- Ghost drivers: a driver who disconnected mid-race is kept as DNF for the
-- results file, but must be purged by the next Generate Grid - otherwise the
-- ghost turns 'racing' at GO, never laps, and blocks the auto-finish forever.
-- (State is fresh here: the file was just re-dofile'd + onInit'd above.)
-- ---------------------------------------------------------------------------
RM_onPlayerJoin(1); RM_onPlayerJoin(2); RM_onPlayerJoin(3)
RM_onSetTotalLaps(1, '{"laps":1}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
connected[3] = nil
RM_onPlayerDisconnect(3)                -- Cara drops mid-race -> DNF
lastChat = nil
RM_onLap(1, '{"lapTime":90}')
RM_onLap(2, '{"lapTime":91}')
settleRace()
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
settleRace()
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
-- A long race, so nobody takes the flag part-way through this and stops being
-- eligible to score laps.
RM_onSetTotalLaps(1, '{"laps":10}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()

RM_onRequestState(1)
check(lastState.bestLapPid == nil, 'no fastest lap before anyone has set one')

-- The first crossing of a race is never timed (a grid sits just before the line,
-- so it is a few metres, not a lap), so it takes two crossings to put a time on
-- the board at all.
RM_onLap(1, '{"lapTime":95.5}')
check(lastState.bestLapPid == nil, 'the first crossing sets no fastest lap')
RM_onLap(1, '{"lapTime":95.5}')
check(lastState.bestLapPid == 1, 'the first TIMED lap is the fastest lap')
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
lastChat = nil
settleRace()

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
lastChat = nil
settleRace()

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
lastChat = nil
settleRace()

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
RM_onSetTotalLaps(1, '{"laps":1}')
RM_onGenerateGrid(1)
RM_onStartCountdown(1)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
lastChat = nil
RM_onLap(1, '{"lapTime":90.0}'); RM_Tick()
RM_onLap(2, '{"lapTime":91.0}'); RM_Tick()
RM_onLap(3, '{"lapTime":92.0}'); RM_Tick()
RM_onLap(4, '{"lapTime":93.0}')
lastChat = nil
settleRace()
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
-- Branch gates: persistence and validation
-- ---------------------------------------------------------------------------
-- A branch gate is another way through a checkpoint that already exists, and it
-- carries the checkpoint it belongs to. The server never tests a crossing -- it
-- has no physics -- so its whole job here is to validate the shape, keep it on
-- disk and hand it back out.
--
-- NOTHING HERE DECIDES A DIRECTION. There is no lane to assign, so a grid slot
-- carries no tag and a driver record has no lane field: the way a start position
-- points is what sends a car one way round or the other, and that is read on the
-- client. The absence is asserted below, because it used to be the opposite.
adminLogin(1)
MP.Settings.Map = 0
hostedMap = '/levels/gridmap_v2/info.json'
RM_onRequestLayouts(1)

local branchJson = '[{"slot":1,"x":-100,"y":0,"z":0,"hx":0,"hy":1},'
  .. '{"slot":3,"x":100,"y":0,"z":0,"hx":0,"hy":-1}]'

lastLayouts = nil
RM_onSaveLayout(1, '{"name":"Suicide Oval","width":20,"checkpoints":' .. cpJson
  .. ',"branches":' .. branchJson .. ',"gridOffLine":true}')
local saved
for _, l in ipairs(lastLayouts and lastLayouts.layouts or {}) do
  if l.name == 'Suicide Oval' then saved = l end
end
check(saved ~= nil, 'a layout with branch gates saves')
check(saved and type(saved.branches) == 'table' and #saved.branches == 2,
  'both branch gates survive the round trip, as a flat list')
check(saved and saved.branches[1].slot == 1 and saved.branches[2].slot == 3,
  'each keeps the CHECKPOINT it is another way through -- which is what makes it a branch')
check(saved and saved.branches[1].x == -100 and saved.branches[2].x == 100,
  'and its own coordinates')
check(saved and saved.gridOffLine == true, 'the grid-off-line flag travels with the track')

-- An ordinary layout emits no branches key at all, so nothing about a plain
-- circuit changes on disk.
for _, l in ipairs(lastLayouts.layouts) do
  if l.name == 'GP Circuit' then
    check(l.branches == nil, 'a layout with no branch gates stores no branches key')
    check(l.gridOffLine == false, 'and is not marked grid-off-line')
  end
end

-- SEVERAL BRANCH GATES MAY SHARE A CHECKPOINT, and that is the feature: three
-- ways through one corner is three gates on the same slot. The version this
-- replaced rejected a duplicate slot outright.
lastLayouts = nil
RM_onSaveLayout(1, '{"name":"Three Ways","width":20,"checkpoints":' .. cpJson
  .. ',"branches":[{"slot":1,"x":10,"y":0,"z":0,"hx":0,"hy":1},'
  .. '{"slot":1,"x":20,"y":0,"z":0,"hx":0,"hy":1}]}')
local three
for _, l in ipairs(lastLayouts and lastLayouts.layouts or {}) do
  if l.name == 'Three Ways' then three = l end
end
check(three ~= nil and #three.branches == 2,
  'two branch gates on ONE checkpoint save: a shared slot is the point, not a clash')

-- Validation. Every one of these is a gate no driver could ever be asked for, so
-- the whole save is refused rather than quietly stored without it. Clamping a
-- bad slot into range would arm the gate at a different corner instead.
local function rejects(what, branches)
  local before = #lastLayouts.layouts
  RM_onSaveLayout(1, '{"name":"Bad ' .. what .. '","width":20,"checkpoints":' .. cpJson
    .. ',"branches":' .. branches .. '}')
  check(#lastLayouts.layouts == before, 'rejected: ' .. what)
end
rejects('checkpoint past the end of the route',
  '[{"slot":9,"x":1,"y":2,"z":3,"hx":0,"hy":1}]')
rejects('checkpoint below one',
  '[{"slot":0,"x":1,"y":2,"z":3,"hx":0,"hy":1}]')
rejects('no checkpoint number at all',
  '[{"x":1,"y":2,"z":3,"hx":0,"hy":1}]')
rejects('a gate with no coordinates', '[{"slot":1}]')
rejects('an empty branch list', '[]')

-- Loading it arms the session with the branch gates and the out lap.
RM_onLoadLayout(1, '{"name":"Suicide Oval"}')
lastState = nil
RM_onRequestState(1)
check(lastState.hasBranches == true,
  'loading the track tells every client it has other ways through its checkpoints')
check(lastState.gridOffLine == true, 'and that its grid is away from the line')
check(lastState.qualiOutLap == true,
  'so a RACE on it owes an out lap -- the part lap from the grid is not timed')

-- THE GRID CARRIES NO DIRECTION. Half the slots face the other way, which is the
-- whole of how a head-on field is split now, and the server neither reads nor
-- reports anything about it.
local startJson = '[{"x":0,"y":-100,"z":0,"hx":1,"hy":0},'
  .. '{"x":0,"y":-108,"z":0,"hx":1,"hy":0},'
  .. '{"x":0,"y":-100,"z":0,"hx":-1,"hy":0},'
  .. '{"x":0,"y":-92,"z":0,"hx":-1,"hy":0}]'
RM_onStartPositionCount(1, '{"count":4,"positions":' .. startJson
  .. ',"gridOffLine":true}')

RM_onSetTotalLaps(1, '{"laps":3}')
RM_onGenerateGrid(1)
lastState = nil
RM_onRequestState(1)
local bySlot = {}
for _, d in ipairs(lastState.drivers) do
  if d.gridPos then bySlot[d.gridPos] = d end
end
check(bySlot[1] and bySlot[1].lane == nil, 'no driver carries a lane: slot 1')
check(bySlot[3] and bySlot[3].lane == nil,
  'nor a slot facing the other way: the heading is the direction, and it stays on the client')
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
  'the launch sets no Best Lap -- a standing start is not a lap time')
check(lastState.bestLapPid == nil,
  'and cannot take fastest lap of the race, which is the whole point of it')
check(driver('Alice').outLap == false, 'the untimed lap is spent after one crossing')
check(driver('Alice').currentLap == 2, 'and it COUNTED: the driver is on lap 2')

-- From here every crossing is a real lap and is scored normally.
RM_onLap(1, '{"lapTime":42.0}')
check(driver('Alice').raceBest == 42.0, 'the first timed lap goes on the board')
lastState = nil
RM_onRequestState(1)
check(lastState.bestLapPid == 1, 'and takes fastest lap')

-- A THREE LAP RACE IS THREE CROSSINGS. The first of them counts toward the
-- distance -- it is a racing lap, it just sets no time -- so the flag falls on
-- the third, not the fourth.
--
-- That is the difference between this and qualifying's out lap, which is a lap
-- given AWAY: not timed AND not one of the laps you were promised, so it is
-- added on top of the allowance.
RM_onLap(1, '{"lapTime":41.0}')
check(driver('Alice').status == 'finished',
  'the flag falls on the third CROSSING, because the first one counted')
check(driver('Alice').raceBest == 41.0, 'and the last lap is scored like any other')
check(driver('Alice').currentLap == 3, 'three crossings, three laps')

-- NO LANE SURVIVES THE RACE EITHER, because there was never one to carry. Two
-- cars at opposite ends of a head-on oval are ranked next to each other because
-- they have cleared the same checkpoints, and that is the whole claim.
check(driver('Cara').lane == nil and driver('Dan').lane == nil,
  'a driver gridded on a turned-around slot carries no lane through the race')
RM_onEndRace(1)

-- ---------------------------------------------------------------------------
-- A LATE JOINER GETS THE TRACK
-- ---------------------------------------------------------------------------
-- The layout used to be broadcast once, at the moment an admin pressed Load, and
-- never again -- so it reached exactly the people already connected. Anyone who
-- joined afterwards had no gates at all, and the workaround was for the admin to
-- wait until the whole field had spawned before loading. A track is state, not an
-- announcement.
do
  RM_onLoadLayout(1, '{"name":"Suicide Oval"}')
  appliedLayouts = {}

  -- Somebody arrives after the load and asks for state, which is what a client
  -- does on joining a server.
  connected[9] = 'LateJoiner'
  RM_onPlayerJoin(9)
  RM_onRequestState(9)
  check(appliedLayouts[9] ~= nil,
    'a client that joins after the load is sent the track when it asks for state')
  check(appliedLayouts[9] and #appliedLayouts[9].checkpoints == 3,
    'and it is the whole layout, gates and all')

  -- And forming a grid puts it in front of everyone, whoever was missing it.
  appliedLayouts = {}
  RM_onGenerateGrid(1)
  check(appliedLayouts[-1] ~= nil,
    'forming a grid re-sends the track to the whole field')

  -- A purge forgets it, so a joiner is never handed a track the rest of the
  -- server has just been told to drop.
  RM_onClearTrackState(1)
  appliedLayouts = {}
  RM_onRequestState(9)
  check(appliedLayouts[9] == nil, 'after a purge there is no track to hand out')
  connected[9] = nil
  RM_onPlayerDisconnect(9)
end

-- ---------------------------------------------------------------------------
-- JOINING IN THE MIDDLE OF A SESSION
-- ---------------------------------------------------------------------------
-- Somebody who connects mid-race has no grid slot, no laps and no out lap behind
-- them. In "everyone races" mode they were put on the timing screen as a
-- participant anyway, which makes a nonsense of the classification -- and they
-- arrive with a car, a spawn point and no idea a race is running, which is how a
-- leader ends up in a wall.
do
  RM_onSetTotalLaps(1, '{"laps":5}')
  RM_onGenerateGrid(1)
  RM_onStartCountdown(1)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
  check(lastState.phase == 'racing', 'a race is running')

  connected[8] = 'Latecomer'
  RM_onPlayerJoin(8)
  local late
  for _, d in ipairs(lastState.drivers) do if d.name == 'Latecomer' then late = d end end
  check(late ~= nil, 'the new arrival appears on the driver list')
  check(late and late.bystander == true,
    'flagged a bystander: clients ghost that car so it cannot interfere')
  check(late and late.status == 'waiting',
    'and is NOT put into the running session, whatever the entry mode says')
  check(late and late.gridPos == nil, 'with no grid slot invented for them')

  -- The next grid is where entry is decided again, so that is where they stop
  -- being a bystander.
  RM_onEndRace(1)
  RM_onGenerateGrid(1)
  for _, d in ipairs(lastState.drivers) do if d.name == 'Latecomer' then late = d end end
  check(late and not late.bystander,
    'forming the next grid clears the flag -- they are in that race properly')
  check(late and late.gridPos ~= nil, 'and they get a slot on it')
  RM_onEndRace(1)
  connected[8] = nil
  RM_onPlayerDisconnect(8)
end

-- ---------------------------------------------------------------------------
-- ONE PLAYER'S EDITOR CANNOT GIVE THE WHOLE SERVER AN OUT LAP
-- ---------------------------------------------------------------------------
-- RM_StartPositionCount is sent by pushRouteState, which fires constantly and
-- from EVERY client, not just an admin. It carries whether that client thinks
-- its grid is off the start/finish line -- so one player with start positions
-- sitting in their local editor could flip the rule for the whole server, and a
-- race would quietly give its first lap away and announce it to everybody.
--
-- A loaded layout is authored, saved and shared. It is the authority on its own
-- grid, and a live client report does not get to overrule it.
do
  -- Out of any grid or session first: the report is refused outright while one is
  -- under way, and a test that passed on THAT guard would prove nothing about
  -- the one being tested here.
  RM_onEndRace(1)
  check(lastState.phase ~= 'grid', 'not on a grid, so the report is not refused outright')
  RM_onLoadLayout(1, '{"name":"Suicide Oval"}')   -- saved with gridOffLine = true
  -- Loading does not broadcast state on its own, so ask for one: otherwise this
  -- reads a snapshot from before the load and proves nothing.
  RM_onRequestState(1)
  check(lastState.gridOffLine == true, 'the loaded layout says its grid is off the line')

  -- A non-admin client reports the opposite from its own editor.
  RM_onStartPositionCount(3, '{"count":0,"positions":[],"gridOffLine":false}')
  RM_onRequestState(1)
  check(lastState.gridOffLine == true,
    'a client report does not overrule the loaded layout')

  -- And the other way round: no layout loaded, so the report IS the only source
  -- of truth and is taken.
  RM_onClearTrackState(1)
  RM_onStartPositionCount(1, '{"count":0,"positions":[],"gridOffLine":true}')
  RM_onRequestState(1)
  check(lastState.gridOffLine == true,
    'with no layout loaded the client report is used, which is the unsaved path')
  RM_onStartPositionCount(1, '{"count":0,"positions":[],"gridOffLine":false}')
  RM_onRequestState(1)
  check(lastState.gridOffLine == false, 'and it can be turned back off the same way')
end

-- Clean up the directory tree the test created in the repo root
-- ---------------------------------------------------------------------------
-- A refused admin command answers the client
-- ---------------------------------------------------------------------------
-- Reported live: every admin button silently stopped working, with no error
-- anywhere, and logging out and back in was the only cure anybody stumbled onto.
--
-- The client caches its own admin flag so it survives the pause menu, and
-- `youAreAdmin` only rides targeted replies. Session ids are REUSED, so a
-- reconnect clears the auth server-side while the panel goes on showing admin
-- controls the server is quietly refusing. Nothing told the client.
lastLogin = nil
RM_onEndRace(4242)                    -- a pid that never logged in
check(lastLogin ~= nil,
  'a refused admin command answers the client instead of only logging it')
check(lastLogin and lastLogin.success == false,
  'and the answer corrects the flag the client was caching')
check(lastLogin and lastLogin.lapsed == true,
  'flagged as a LAPSE, not a failed password: nobody typed anything, so the '
    .. 'panel must not accuse them of getting it wrong')

-- ---------------------------------------------------------------------------
-- A loaded layout owns its own joker route
-- ---------------------------------------------------------------------------
-- Reported live: a track with joker gates needed loading TWICE before the joker
-- toggle would unlock.
--
-- Clients report their placed joker count constantly, from every client, not
-- just the admin. Right after a load, one that had not applied the layout yet --
-- or a spectator with an empty editor -- reported zero and wiped the count the
-- layout had just set. The second load worked because by then everyone was
-- reporting the route they had.
RM_onSaveLayout(1, '{"name":"Joker Track","width":20,"checkpoints":'
  .. '[{"x":0,"y":100,"z":0,"hx":0,"hy":1},{"x":0,"y":200,"z":0,"hx":0,"hy":1}]'
  .. ',"joker":[{"x":50,"y":150,"z":0,"hx":1,"hy":0},{"x":50,"y":160,"z":0,"hx":1,"hy":0}]}')
-- ONE LOAD, AND NOTHING ELSE. lastState is cleared first so this can only pass
-- if the load itself broadcast: that is the entire bug. Loading set jokerGates,
-- startSlots, pointToPoint and the lanes and told nobody, and RM_Tick does not
-- run while no session is going, so nothing else was coming. The joker toggle
-- stayed locked until some unrelated thing pushed state, and clicking Load
-- Layout a second time was the reliable way to find one.
lastState = nil
RM_onLoadLayout(1, '{"name":"Joker Track"}')
check(lastState ~= nil,
  'loading a layout broadcasts state by itself, without a second click')
check(lastState.jokerGates == 2, 'loading a joker track reports its two gates')

-- A client that has not applied it yet says zero. It must not be believed.
RM_onStartPositionCount(2, '{"count":0,"positions":[],"jokerGates":0}')
RM_onRequestState(1)
check(lastState.jokerGates == 2,
  'a client reporting zero does NOT wipe the count a loaded layout set')

-- With no layout loaded the client IS the authority, which is how a track built
-- in the editor and never saved still gets a joker lap.
-- Clearing the track is the same class of change and had the same gap.
lastState = nil
RM_onClearTrackState(1)
check(lastState ~= nil and lastState.jokerGates == 0,
  'and clearing the track broadcasts too, rather than leaving the panel showing '
    .. 'the layout that is no longer loaded')
RM_onStartPositionCount(2, '{"count":0,"positions":[],"jokerGates":3}')
RM_onRequestState(1)
check(lastState.jokerGates == 3,
  'with no layout loaded the editor is still believed')

-- ---------------------------------------------------------------------------
-- Sitting out: a self-declared spectator the field runs without
-- ---------------------------------------------------------------------------
-- Racers pressed a button labelled "Spectate" expecting to watch a race and got
-- a dismissed login box. What they actually wanted was to not be IN the race,
-- and under 'everyone races' entry there was no way to say so short of leaving
-- the server.
connected[11] = 'Sitter'
RM_onPlayerJoin(11)
RM_onRequestState(11)
local before = lastState.entrants

-- The player who opted out has to be TOLD, and `youSpectating` is targeted-only
-- like youAreAdmin: the global payload is one message for the whole server and
-- cannot say "you" to anybody. Without a targeted send they are the only person
-- not told, so their count drops to zero while their panel still reads "you are
-- entered" and the button still offers to do what they just did.
lastState = nil
RM_onSetSpectating(11, '{"spectating":true}')
check(lastState ~= nil and lastState.youSpectating == true,
  'opting out sends the player their own state, not just everybody the count')
RM_onRequestState(11)
check(lastState.entrants == before - 1,
  'a spectator is out of the field even under "everyone races", which is the '
    .. 'entry mode that had no opt-out at all')
check(lastState.youSpectating == true, 'and is told so')

-- No admin rights needed: it is their own participation.
check(true, 'RM_onSetSpectating takes no admin check by design')

-- Rejoining is refused while a session runs, the same rule joining has.
RM_onGenerateGrid(1, '')
RM_onStartCountdown(1, '')
for _ = 1, 4 do RM_CountdownTick() end
RM_onSetSpectating(11, '{"spectating":false}')
RM_onRequestState(11)
check(lastState.youSpectating == true,
  'and cannot rejoin a session already under way')

-- NEITHER DIRECTION MID-SESSION. Sitting out decides whether you are in the
-- field, and the field is decided when the grid forms. Leaving a race you are
-- already in is RETIRING, which is a different thing with a different result.
connected[12] = 'Quitter'
RM_onPlayerJoin(12)
RM_onSetSpectating(12, '{"spectating":true}')
RM_onRequestState(12)
check(lastState.youSpectating ~= true,
  'and nobody can switch to spectating mid-session either: that is what Retire '
    .. 'is for')

RM_onEndRace(1, '')
RM_onSetSpectating(11, '{"spectating":false}')
RM_onRequestState(11)
check(lastState.youSpectating ~= true, 'and rejoin once it is over')
connected[11], connected[12] = nil, nil

-- ---------------------------------------------------------------------------
-- Retiring: classified behind the field, and later is better
-- ---------------------------------------------------------------------------
-- A driver retiring from P2 of four does not keep second. The cars still going
-- will all come past, so they are last of those who took part. Retire later and
-- fewer cars are left to pass you, which is how motorsport has always ordered
-- retirements.
for pid = 20, 23 do
  connected[pid] = 'R' .. pid
  RM_onPlayerJoin(pid)
end
RM_onGenerateGrid(1, '')
RM_onStartCountdown(1, '')
for _ = 1, 4 do RM_CountdownTick() end

local function recOf(pid)
  RM_onRequestState(pid)
  for _, d in ipairs(lastState.drivers or {}) do
    if d.name == 'R' .. pid then return d end
  end
end

-- Four on track (plus Alice, who is also entered under 'all'). The first to
-- retire is classified last of everyone who can still finish.
RM_onRetire(20)
local first = recOf(20)
check(first ~= nil and first.status == 'dnf', 'retiring is a DNF, not a vanishing')
local firstPos = first and first.dnfPos
check(firstPos ~= nil, 'and it is classified')

-- The next to retire classifies AHEAD of the first: one fewer car is left to
-- come past.
RM_onRetire(21)
local second = recOf(21)
check(second and second.dnfPos ~= nil, 'the second retirement is classified too')
check(second and firstPos and second.dnfPos < firstPos,
  'and places AHEAD of the earlier one (' .. tostring(second.dnfPos) .. ' vs '
    .. tostring(firstPos) .. '): retiring later means fewer cars still to pass you')

-- The two facts stay separate.
check(second and second.heldPos ~= nil,
  'the place it was running in is kept as well, for the results line and for a '
    .. 'cup paying retirements at the position they held')

-- And a retirement is still SCORED: it holds a position and takes points like
-- any other DNF. Somebody who stops is still somebody who took part.
check(second and second.dnfPos ~= nil and second.status == 'dnf',
  'a retirement is classified and scoreable, not removed from the results')

-- Retiring outside a session does nothing. Ending the race retires everyone
-- still out as a DNF anyway, so this checks the CALL is refused rather than the
-- status, by watching for the chat line it answers with.
RM_onEndRace(1, '')
lastChat = nil
RM_onRetire(23)
check(type(lastChat) == 'string' and lastChat:find('Nothing to retire', 1, true),
  'retiring with no session running is refused, and says so')
for pid = 20, 23 do connected[pid] = nil end

-- LAST IN THE FILE ON PURPOSE. This block starts a race, and everything above
-- it either needs no session running (loading and deleting a layout are both
-- refused mid-race) or depends on driver records a reset would clear.
adminLogin(1)
RM_onSetFlag(1, '{"flag":"yellow"}')
check(lastState.flag == nil or lastState.flag == 'green',
  'a flag with no session running is refused: a caution with nobody on track '
    .. 'is noise')

-- Put a session on track.
connected[1] = 'Alice'
connected[2] = 'Bob'
RM_onPlayerJoin(1); RM_onPlayerJoin(2)
RM_onGenerateGrid(1, '')
RM_onStartCountdown(1, '')
for _ = 1, 4 do RM_CountdownTick() end
check(lastState.phase == 'racing', 'a race is running')
check(lastState.flag == 'green', 'and it starts green')

lastChat = nil
RM_onSetFlag(1, '{"flag":"yellow"}')
check(lastState.flag == 'yellow', 'an admin can call a caution')
check(lastState.phase == 'racing',
  'and the session is still RACING: the flag rides alongside the phase rather '
    .. 'than replacing it, so nothing that tests the phase changes behaviour')
check(type(lastChat) == 'string' and lastChat:find('YELLOW', 1, true),
  'the field is told in chat, because the panel is not where a driver is looking')

-- pid 2 is an admin by this point in the file, so an unauthenticated pid is
-- used rather than assuming.
RM_onSetFlag(99, '{"flag":"green"}')
check(lastState.flag == 'yellow', 'a non-admin cannot wave a flag')

RM_onSetFlag(1, '{"flag":"chartreuse"}')
check(lastState.flag == 'yellow', 'and an invented colour is ignored')

-- RED IS A CONDITION, NOT A STATE CHANGE. Stop, something gets cleaned up, then
-- yellow and back to green. Nothing ends, nobody is frozen, and the phase does
-- not move: the race is still running underneath it the whole time.
lastChat = nil
RM_onSetFlag(1, '{"flag":"red"}')
check(lastState.flag == 'red', 'an admin can call a red flag')
check(lastState.phase == 'racing',
  'and the session is STILL RACING: red stops the cars, not the session')
check(type(lastChat) == 'string' and lastChat:find('RED FLAG', 1, true),
  'the field is told')
check(type(lastChat) == 'string' and lastChat:find('still running', 1, true),
  'and told the session has not ended, because red is the one flag that looks '
    .. 'like it should have ended it')

-- The sequence a marshal actually runs.
RM_onSetFlag(1, '{"flag":"yellow"}')
check(lastState.flag == 'yellow', 'red goes to yellow')

RM_onSetFlag(1, '{"flag":"green"}')
check(lastState.flag == 'green', 'the admin can go back to green')

-- A caution belongs to the session it was called in.
RM_onSetFlag(1, '{"flag":"yellow"}')
RM_onEndRace(1, '')
RM_onGenerateGrid(1, '')
RM_onStartCountdown(1, '')
for _ = 1, 4 do RM_CountdownTick() end
check(lastState.flag == 'green',
  'the next session starts green: a caution carried into the next race is the '
    .. 'kind of state nobody thinks to check')

-- ---------------------------------------------------------------------------
-- THE HOLD AT THE FLAG: a race does not close on the tick the last car crosses
-- ---------------------------------------------------------------------------
-- Finishing ghosts a driver's car in place rather than removing it, and the
-- ghosts lift when the SESSION ends. Closing the session on the same tick the
-- last car crossed meant nobody ever saw the finish they had just driven to.
-- The derby has held for five seconds since it was built; a race now does too.
do
  RM_onEndRace(1)
  RM_onResetLeaderboard(1)
  for _, pid in ipairs({ 1, 2, 3, 4 }) do RM_onSetSpectating(pid, '{"spectating":false}') end
  RM_onSetTotalLaps(1, '{"laps":1}')
  RM_onGenerateGrid(1)
  RM_onStartCountdown(1)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()

  lastChat = nil
  RM_onLap(1, '{"lapTime":40.0}')      -- Alice is home
  check(driver('Alice').status == 'finished', 'the first driver takes the flag')
  check(lastState and lastState.phase == 'racing',
    'and the session is still running, because somebody is still out')

  RM_onLap(2, '{"lapTime":41.0}')
  RM_onLap(3, '{"lapTime":42.0}')
  RM_onLap(4, '{"lapTime":43.0}')      -- and now the whole field is home
  check(lastState and lastState.phase == 'racing',
    'the last car crossing does NOT close the session on that tick')
  check(type(lastChat) == 'string' and lastChat:find('results in', 1, true),
    'the hold is announced instead (chat: ' .. tostring(lastChat) .. ')')

  -- Four seconds in, still held. The ghosts are still on, because they are
  -- derived from the phase and the phase is still 'racing'.
  for _ = 1, 40 do RM_Tick() end
  check(lastState and lastState.phase == 'racing', 'four seconds later it is still held')
  check(lastState and type(lastState.ghostFinished) == 'table'
    and #lastState.ghostFinished == 4,
    'and every finished driver is still ghosted during the hold')

  -- Past five, it closes and writes the results.
  lastChat = nil
  for _ = 1, 20 do RM_Tick() end
  check(lastState and lastState.phase == 'finished', 'past the hold, the session closes')
  check(#(lastState.ghostFinished or {}) == 0,
    'and the ghost list empties, which is what hands every car back its collisions')

  -- A SECOND driver finishing inside the window must not push the end away, or a
  -- bunched finish could extend a race indefinitely. The derby's arm is
  -- idempotent for the same reason.
  RM_onEndRace(1)
  RM_onResetLeaderboard(1)
  for _, pid in ipairs({ 1, 2, 3, 4 }) do RM_onSetSpectating(pid, '{"spectating":false}') end
  RM_onSetTotalLaps(1, '{"laps":1}')
  RM_onGenerateGrid(1)
  RM_onStartCountdown(1)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
  RM_onLap(1, '{"lapTime":40.0}')
  RM_onLap(2, '{"lapTime":41.0}')
  RM_onLap(3, '{"lapTime":42.0}')
  RM_onLap(4, '{"lapTime":43.0}')
  for _ = 1, 20 do RM_Tick() end       -- two seconds into the hold
  RM_onLap(1, '{"lapTime":39.0}')      -- a stray report from a finished driver
  for _ = 1, 40 do RM_Tick() end       -- would take us past five in total
  check(lastState and lastState.phase == 'finished',
    'a late report inside the window does not push the end further away')
end

-- ===========================================================================
-- A driver done with qualifying is a ghost, not an obstacle
-- ===========================================================================
-- Retiring from qualifying goes through the same path a race finish does:
-- status 'finished', the spectator lock, and the CAR IS KEPT -- a finisher
-- watches the rest of the session from their own car rather than having it
-- taken away.
--
-- What was missing is the half that makes keeping it safe. ghostFinished, the
-- list every client ghosts, was built only while the phase was 'racing' or
-- 'countdown', so a driver who had used their qualifying laps sat on the
-- circuit fully SOLID while everybody else was still on a hot lap. That is
-- worse in qualifying than in a race: there is no pack to hide in, and a single
-- contact ruins a single-lap session.
do
  local qCps = '[{"x":0,"y":100,"z":0,"hx":0,"hy":1},{"x":0,"y":200,"z":0,"hx":0,"hy":1}]'
  adminLogin(1)
  RM_onSaveLayout(1, '{"name":"Quali","width":20,"checkpoints":' .. qCps
    .. ',"startPositions":' .. qCps .. '}')
  RM_onLoadLayout(1, '{"name":"Quali"}')
  RM_onSetQualiLimits(1, '{"laps":1,"seconds":0}')
  RM_onStartQualifying(1)
  RM_onStartCountdown(1)
  for _ = 1, 8 do RM_CountdownTick() end
  check(lastState.phase == 'qualifying', 'qualifying is running')

  local function ghostedIds()
    local t = {}
    for _, id in ipairs(lastState.ghostFinished or {}) do t[tonumber(id)] = true end
    return t
  end
  check(next(ghostedIds()) == nil, 'nobody is a finished-ghost while everyone is still out')

  -- Alice uses her allowance. A one-lap limit is more than one CROSSING when an
  -- out lap is owed, so she is driven round until the server retires her; the
  -- assertion below is on the outcome rather than on the crossing count.
  for _ = 1, 4 do RM_onLap(1, '{"lapTime":40.0}') end
  local done = ghostedIds()
  check(done[1] == true,
    'a driver who has used their qualifying laps is ghosted for everyone else')
  check(done[2] ~= true, 'and a driver still on a hot lap is not')

  -- The handoff at the end of the session: the list empties, so every client
  -- hands the collisions back rather than leaving a field of ghosts behind.
  RM_onEndRace(1)
  settleRace()
  check(next(ghostedIds()) == nil,
    'the finished-ghost list empties when qualifying ends, so collisions come back')

  RM_onDeleteLayout(1, '{"name":"Quali"}')
end

-- ===========================================================================
-- LIFECYCLE: three races back to back leave the server in the same place
-- ===========================================================================
-- The client half of this lives in lifecycle_test.lua; this is the durable
-- half, where the driver records, the flag, the fastest lap and the whole race
-- table live. State that accumulates here is the kind that makes the third race
-- of an evening score differently from the first for no visible reason.
--
-- A DIFF, not a checklist: the same complete race run three times, with every
-- field the state broadcast carries compared afterwards. A checklist only ever
-- covers the fields somebody thought of.
do
  local function fieldsOf(st)
    local out = {}
    for _, k in ipairs({ 'phase', 'flag', 'totalLaps', 'maxResets', 'jokerEnabled',
        'jokerGates', 'startSlots', 'gridOffLine', 'pointToPoint', 'finalLap',
        'bestLapTime', 'bestLapPid', 'resetMode', 'ghostQuali', 'qualiLapLimit',
        'qualiTimeLimit' }) do
      out[k] = tostring(st[k])
    end
    out['#drivers'] = tostring(#(st.drivers or {}))
    local resets, laps = 0, 0
    for _, d in ipairs(st.drivers or {}) do
      resets = resets + (tonumber(d.resets) or 0)
      laps   = laps   + (tonumber(d.lap) or 0)
    end
    out['sum(resets)'] = tostring(resets)
    out['sum(laps)']   = tostring(laps)
    return out
  end

  local auditCps = '[{"x":0,"y":100,"z":0,"hx":0,"hy":1},{"x":0,"y":200,"z":0,"hx":0,"hy":1}]'
  adminLogin(1)
  RM_onSaveLayout(1, '{"name":"Audit","width":20,"checkpoints":' .. auditCps
    .. ',"startPositions":' .. auditCps .. '}')

  local function runRace(n)
    RM_onLoadLayout(1, '{"name":"Audit"}')
    RM_onSetTotalLaps(1, '{"laps":1}')
    RM_onSetMaxResets(1, '{"maxResets":3}')
    RM_onGenerateGrid(1)
    RM_onStartCountdown(1)
    for _ = 1, 8 do RM_CountdownTick() end
    -- Something worth leaving behind: a caution, a reset spent, a fastest lap.
    RM_onSetFlag(1, '{"flag":"yellow"}')
    RM_onVehicleReset(1)
    RM_onSetFlag(1, '{"flag":"green"}')
    -- EVERY entrant takes the flag. One left out there and the race never
    -- closes, the next Generate Grid is refused, and the audit silently reports
    -- one long race as three identical ones. That is exactly what the first
    -- version of this did, until the assertion below was added.
    for pid in pairs(connected) do
      RM_onLap(pid, '{"lapTime":' .. (39 + pid) .. '.0}')
    end
    settleRace()
    check(lastState.phase == 'finished' or lastState.phase == 'waiting',
      'audit race ' .. n .. ' actually finished (phase ' .. tostring(lastState.phase) .. ')')
    return fieldsOf(lastState)
  end

  local r1, r2, r3 = runRace(1), runRace(2), runRace(3)
  local function diffFields(a, b)
    local out = {}
    for k, v in pairs(a) do
      if b[k] ~= v then out[#out + 1] = k .. ': ' .. tostring(v) .. ' -> ' .. tostring(b[k]) end
    end
    table.sort(out)
    return out
  end
  local d12, d23 = diffFields(r1, r2), diffFields(r2, r3)
  for _, l in ipairs(d12) do print('  server drift 1->2: ' .. l) end
  for _, l in ipairs(d23) do print('  server drift 2->3: ' .. l) end
  check(#d12 == 0, 'the second race leaves the server exactly where the first did')
  check(#d23 == 0, 'and so does the third: nothing accumulates across races')

  -- The reset allowance in particular, because it is per RACE and is the most
  -- obvious thing to get wrong: one spent in every race, rather than a tally
  -- climbing 1, 2, 3 across the evening.
  check(r1['sum(resets)'] == '1' and r3['sum(resets)'] == '1',
    'the reset allowance starts over every race rather than carrying forward')

  RM_onDeleteLayout(1, '{"name":"Audit"}')
end

removeTree('Resources')

if fails == 0 then
  io.stdout:write(('ALL PASS (%d checks)\n'):format(checks))
else
  io.stdout:write(('%d/%d FAILED\n'):format(fails, checks))
  os.exit(1)
end
