-- Race Manager - BeamMP server plugin (Lua 5.3)
--
-- Authoritative session state machine for circuit racing:
--
--   waiting -> qualifying -> grid -> countdown -> racing -> finished
--                 (quali)   (grid locked)          (race)
--
-- Qualifying: clients time their own laps (the server has no physics access)
-- and report each completed lap; the server keeps the Best Lap per driver.
-- Generate Grid sorts drivers fastest-to-slowest by quali Best Lap and locks
-- in starting positions. Race mode shows the grid, then the countdown starts
-- the race. During the race clients report every completed lap; the server
-- tracks Current Lap, race Best Lap, Laps Led (first driver to complete each
-- lap), and flags the finish when a driver completes the configured lap count.
-- All timing that must be fair across drivers (finish order, laps led) is
-- decided by arrival order / the server clock.
--
-- Author: Phoenix

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local TICK_MS            = 100   -- server clock resolution
local PUSH_EVERY_TICKS   = 5     -- broadcast state every N ticks (500 ms)
local COUNTDOWN_FROM     = 3     -- 3, 2, 1, GO!
local DEFAULT_TOTAL_LAPS = 5
local MAX_TOTAL_LAPS     = 500

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local race = {
  phase     = 'waiting',  -- waiting | qualifying | grid | countdown | racing | finished
  time      = 0.0,        -- seconds since GO (advanced by RM_Tick while racing)
  totalLaps = DEFAULT_TOTAL_LAPS,
}
local players = {}          -- [playerID] = per-player record
local tickCounter = 0
local countdownValue = nil  -- current countdown number while phase == 'countdown'
local lapFirsts = {}        -- [lapNumber] = pid of the first driver to complete that lap

-- ---------------------------------------------------------------------------
-- Admin authentication
-- ---------------------------------------------------------------------------
-- BeamMP guest account IDs rotate constantly, so admin rights are gated by a
-- shared password rather than a name/ID whitelist. A player sends RM_Login with
-- the current master password; on a match their session ID is recorded in
-- authenticatedPlayers and every admin-level event checks that table before
-- acting. The default below is meant to be rotated on the fly (RM_ChangePassword)
-- once an admin is logged in -- change it before the first public session.
local DEFAULT_ADMIN_PASSWORD = 'phoenix'
local adminPassword = DEFAULT_ADMIN_PASSWORD
local authenticatedPlayers = {}   -- [playerID] = true while that session is an admin

local function isAuthenticated(pid)
  return authenticatedPlayers[pid] == true
end

-- Guard placed at the top of every admin-level event handler. Any command from
-- a session that has not logged in is dropped (and logged so it's diagnosable).
local function requireAuth(pid)
  if authenticatedPlayers[pid] then return true end
  print('[RaceManager] Ignored admin command from unauthenticated player ' .. tostring(pid))
  return false
end

local function newRecord(pid)
  return {
    id         = pid,
    name       = MP.GetPlayerName(pid) or ('Player ' .. pid),
    status     = 'waiting',  -- waiting | qualifying | gridded | racing | finished | dnf
    gridPos    = nil,        -- locked-in starting position (Generate Grid)
    qualiBest  = nil,        -- best qualifying lap (seconds)
    raceBest   = nil,        -- best race lap (seconds)
    currentLap = 0,          -- lap the driver is currently on (1-based once racing)
    lapsLed    = 0,          -- laps this driver crossed the line first on
    finishTime = nil,        -- server race clock at final-lap completion
  }
end

local function ensurePlayer(pid)
  if not players[pid] then
    players[pid] = newRecord(pid)
  end
  return players[pid]
end

local function decodeNumber(rawData, field)
  if type(rawData) ~= 'string' or rawData == '' then return nil end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return nil end
  local n = tonumber(data[field])
  return n
end

local function decodeString(rawData, field)
  if type(rawData) ~= 'string' or rawData == '' then return nil end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return nil end
  local v = data[field]
  if v == nil then return nil end
  return tostring(v)
end

-- ---------------------------------------------------------------------------
-- Broadcast
-- ---------------------------------------------------------------------------
local function buildDrivers()
  local list = {}
  for _, rec in pairs(players) do
    list[#list + 1] = rec
  end
  if race.phase == 'qualifying' or race.phase == 'waiting' then
    -- Provisional grid order: fastest quali Best Lap first, no-time last.
    table.sort(list, function (a, b)
      local ta, tb = a.qualiBest, b.qualiBest
      if ta and tb then
        if ta ~= tb then return ta < tb end
      elseif ta ~= tb then
        return ta ~= nil  -- drivers with a time ahead of drivers without
      end
      return a.id < b.id
    end)
  else
    -- Race order: finished first (by finish time), then racers by laps
    -- completed (laps led breaks ties), then gridded by position, DNFs last.
    table.sort(list, function (a, b)
      local ra = a.status == 'dnf' and 2 or (a.finishTime and 0 or 1)
      local rb = b.status == 'dnf' and 2 or (b.finishTime and 0 or 1)
      if ra ~= rb then return ra < rb end
      if ra == 0 then return a.finishTime < b.finishTime end
      if a.currentLap ~= b.currentLap then return a.currentLap > b.currentLap end
      if a.lapsLed ~= b.lapsLed then return a.lapsLed > b.lapsLed end
      return (a.gridPos or math.huge) < (b.gridPos or math.huge)
    end)
  end
  return list
end

local function broadcastState(targetPid)
  local payload = Util.JsonEncode({
    phase     = race.phase,
    raceTime  = race.time,
    totalLaps = race.totalLaps,
    drivers   = buildDrivers(),
  })
  MP.TriggerClientEvent(targetPid or -1, 'RM_Update', payload)
end

local function broadcastCountdown(count)
  MP.TriggerClientEvent(-1, 'RM_Countdown', Util.JsonEncode({ count = count }))
end

-- ---------------------------------------------------------------------------
-- Admin authentication events
-- ---------------------------------------------------------------------------
-- A client submits the master password. On a match the session is marked as an
-- admin and told to reveal its editor/admin controls; on a miss any prior
-- admin flag for that session is cleared and a failure is reported.
function RM_onLogin(pid, rawData)
  local pass = decodeString(rawData, 'password')
  if pass ~= nil and pass == adminPassword then
    authenticatedPlayers[pid] = true
    MP.TriggerClientEvent(pid, 'RM_LoginResult', Util.JsonEncode({ success = true }))
    print('[RaceManager] Admin login OK: ' .. (MP.GetPlayerName(pid) or pid))
  else
    authenticatedPlayers[pid] = nil
    MP.TriggerClientEvent(pid, 'RM_LoginResult', Util.JsonEncode({ success = false }))
    print('[RaceManager] Admin login FAILED: ' .. (MP.GetPlayerName(pid) or pid))
  end
end

-- An already-authenticated admin rotates the master password. The new password
-- takes effect immediately for future logins; sessions already logged in stay
-- logged in. The password itself is never broadcast -- only a notice that it
-- changed (and by whom) goes to the server state so every open UI can reflect it.
function RM_onChangePassword(pid, rawData)
  if not requireAuth(pid) then return end
  local newPass = decodeString(rawData, 'password')
  if not newPass or newPass == '' then return end
  adminPassword = newPass
  MP.TriggerClientEvent(-1, 'RM_PasswordChanged', Util.JsonEncode({
    changedBy = MP.GetPlayerName(pid) or ('Player ' .. pid),
  }))
  print('[RaceManager] Admin password changed by ' .. (MP.GetPlayerName(pid) or pid))
end

-- ---------------------------------------------------------------------------
-- Results logging
-- ---------------------------------------------------------------------------
-- Written automatically when a race session ends; one .txt per session so
-- league standings / broadcast scripts can pick them up.
local RESULTS_DIR = 'Resources/Server/RaceManager/results'

local function fmtLap(t)
  if not t then return 'no time' end
  local m = math.floor(t / 60)
  return string.format('%d:%06.3f', m, t - m * 60)
end

-- BeamMP ships an FS API; the io/os fallback keeps headless tests runnable.
local function ensureResultsDir()
  if FS and FS.CreateDirectory then
    FS.CreateDirectory(RESULTS_DIR)
  else
    os.execute('mkdir -p "' .. RESULTS_DIR .. '"')
  end
end

-- Timestamped result path that never overwrites: sessions ending within the
-- same second get a _2, _3, ... suffix instead of clobbering the previous file.
local function uniqueResultsPath(prefix)
  local base = RESULTS_DIR .. '/' .. os.date(prefix .. '_%Y-%m-%d_%H-%M-%S')
  local path = base .. '.txt'
  local n = 1
  while true do
    local f = io.open(path, 'r')
    if not f then return path end
    f:close()
    n = n + 1
    path = base .. '_' .. n .. '.txt'
  end
end

local function listResultFiles()
  local names = {}
  if FS and FS.ListFiles then
    for _, entry in pairs(FS.ListFiles(RESULTS_DIR) or {}) do
      local name = tostring(entry):match('[^/\\]+$')
      if name and name:match('%.txt$') then names[#names + 1] = name end
    end
  else
    local p = io.popen('ls -1 "' .. RESULTS_DIR .. '" 2>/dev/null')
    if p then
      for name in p:lines() do
        if name:match('%.txt$') then names[#names + 1] = name end
      end
      p:close()
    end
  end
  return names
end

local function clearResultsCache()
  local removed = 0
  for _, name in ipairs(listResultFiles()) do
    local path = RESULTS_DIR .. '/' .. name
    local ok
    if FS and FS.Remove then
      ok = FS.Remove(path) ~= false
    else
      ok = os.remove(path) ~= nil
    end
    if ok then removed = removed + 1 end
  end
  return removed
end

-- Qualifying classification: the locked grid if one exists, otherwise best
-- quali lap. This is deliberately independent of the race outcome so the
-- pole sitter and the race winner stay distinct in the output.
local function qualiClassification()
  local list = {}
  for _, rec in pairs(players) do list[#list + 1] = rec end
  table.sort(list, function (a, b)
    if a.gridPos and b.gridPos then return a.gridPos < b.gridPos end
    if (a.gridPos ~= nil) ~= (b.gridPos ~= nil) then return a.gridPos ~= nil end
    local ta, tb = a.qualiBest, b.qualiBest
    if ta and tb then
      if ta ~= tb then return ta < tb end
    elseif ta ~= tb then
      return ta ~= nil
    end
    return a.id < b.id
  end)
  return list
end

-- Race classification: finishers by finish time, then unclassified by laps
-- completed, DNFs last (same ordering the live table uses).
local function raceClassification()
  local list = {}
  for _, rec in pairs(players) do list[#list + 1] = rec end
  table.sort(list, function (a, b)
    local ra = a.status == 'dnf' and 2 or (a.finishTime and 0 or 1)
    local rb = b.status == 'dnf' and 2 or (b.finishTime and 0 or 1)
    if ra ~= rb then return ra < rb end
    if ra == 0 then return a.finishTime < b.finishTime end
    if a.currentLap ~= b.currentLap then return a.currentLap > b.currentLap end
    if a.lapsLed ~= b.lapsLed then return a.lapsLed > b.lapsLed end
    return (a.gridPos or math.huge) < (b.gridPos or math.huge)
  end)
  return list
end

local function buildResultsText()
  local quali = qualiClassification()
  local final = raceClassification()
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  add('==================================================')
  add(' RACE MANAGER - SESSION RESULTS')
  add(' ' .. os.date('%Y-%m-%d %H:%M:%S'))
  add(string.format(' Race distance: %d lap%s | Drivers: %d',
    race.totalLaps, race.totalLaps == 1 and '' or 's', #final))
  add('==================================================')
  add('')
  add('--- QUALIFYING RESULTS ---')
  add(string.format('%-5s %-22s %s', 'Pos', 'Driver', 'Best Lap'))
  for i, rec in ipairs(quali) do
    local tag = (i == 1 and rec.qualiBest) and '  << POLE POSITION' or ''
    add(string.format('P%-4d %-22s %-10s%s', i, rec.name, fmtLap(rec.qualiBest), tag))
  end
  if #quali == 0 then add('(no drivers)') end
  add('')
  add('--- RACE RESULTS ---')
  add(string.format('%-5s %-22s %-10s %-9s %s', 'Pos', 'Driver', 'Best Lap', 'Laps Led', 'Finish'))
  for i, rec in ipairs(final) do
    local classified = rec.finishTime ~= nil
    local pos = classified and ('P' .. i) or 'DNF'
    local finish = classified and fmtLap(rec.finishTime) or 'DNF'
    local tag = (i == 1 and classified) and '  << RACE WINNER' or ''
    add(string.format('%-5s %-22s %-10s %-9d %-10s%s',
      pos, rec.name, fmtLap(rec.raceBest), rec.lapsLed or 0, finish, tag))
  end
  if #final == 0 then add('(no drivers)') end
  add('')
  return table.concat(lines, '\n') .. '\n'
end

local function writeResults()
  ensureResultsDir()
  local path = uniqueResultsPath('results')
  local text = buildResultsText()
  local f, err = io.open(path, 'w')
  if not f then return false, tostring(err) end
  f:write(text)
  f:close()
  return true, path
end

-- Single exit point for every way a race ends (all finished, admin ended,
-- last racer disconnected): flip the phase, log the results file, announce
-- it in chat.
local function finishRace(reason)
  race.phase = 'finished'
  broadcastState()
  print('[RaceManager] Race over: ' .. reason)
  local ok, wrote, pathOrErr = pcall(writeResults)
  if ok and wrote then
    MP.SendChatMessage(-1, '[RaceManager] Session complete! Results saved on the server: ' .. pathOrErr)
    print('[RaceManager] Results written to ' .. pathOrErr)
  else
    print('[RaceManager] Failed to write results: ' .. tostring(ok and pathOrErr or wrote))
  end
end

-- ---------------------------------------------------------------------------
-- Session state machine (UI commands relayed by the client bridge)
-- ---------------------------------------------------------------------------

-- Start Qualifying: snapshot connected players and wipe all session data.
-- Allowed any time outside an active countdown/race.
function RM_onStartQualifying(pid)
  if not requireAuth(pid) then return end
  if race.phase == 'countdown' or race.phase == 'racing' then return end
  MP.CancelEventTimer('RM_CountdownTick')
  players = {}
  lapFirsts = {}
  race.time = 0.0
  for id in pairs(MP.GetPlayers()) do
    local rec = ensurePlayer(id)
    rec.status = 'qualifying'
  end
  race.phase = 'qualifying'
  broadcastState()
  print('[RaceManager] Qualifying started by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Generate Grid: sort by quali Best Lap (fastest first, no-time last) and
-- lock in starting positions. Drivers who join afterwards go to the back on
-- the next Generate Grid. Also usable from waiting/finished: with no quali
-- times everyone ties and the grid falls back to join order.
function RM_onGenerateGrid(pid)
  if not requireAuth(pid) then return end
  if race.phase == 'countdown' or race.phase == 'racing' then return end
  race.time = 0.0
  lapFirsts = {}
  -- Purge ghost records first: drivers kept after disconnecting (DNF/finished,
  -- so the previous results file could list them) must not be re-gridded — a
  -- ghost would be flipped to 'racing' at GO, never report a lap, and block
  -- the "all drivers finished" auto-finish forever.
  local online = MP.GetPlayers()
  for id in pairs(players) do
    if online[id] == nil then players[id] = nil end
  end
  -- Make sure every connected player has a record so nobody is left off grid.
  for id in pairs(online) do ensurePlayer(id) end
  local ordered = {}
  for _, rec in pairs(players) do ordered[#ordered + 1] = rec end
  table.sort(ordered, function (a, b)
    local ta, tb = a.qualiBest, b.qualiBest
    if ta and tb then
      if ta ~= tb then return ta < tb end
    elseif ta ~= tb then
      return ta ~= nil
    end
    return a.id < b.id
  end)
  for gridPos, rec in ipairs(ordered) do
    rec.gridPos    = gridPos
    rec.status     = 'gridded'
    rec.raceBest   = nil
    rec.currentLap = 0
    rec.lapsLed    = 0
    rec.finishTime = nil
  end
  race.phase = 'grid'
  broadcastState()
  print('[RaceManager] Grid generated by ' .. (MP.GetPlayerName(pid) or pid)
    .. ' (' .. #ordered .. ' drivers, pole: '
    .. (ordered[1] and ordered[1].name or 'n/a') .. ')')
end

-- Host sets the race distance. Locked once the countdown/race is under way.
function RM_onSetTotalLaps(pid, rawData)
  if not requireAuth(pid) then return end
  if race.phase == 'countdown' or race.phase == 'racing' then return end
  local n = decodeNumber(rawData, 'laps')
  if not n then return end
  n = math.floor(n)
  if n < 1 then n = 1 elseif n > MAX_TOTAL_LAPS then n = MAX_TOTAL_LAPS end
  race.totalLaps = n
  broadcastState()
  print('[RaceManager] Total laps set to ' .. n .. ' by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_onStartCountdown(pid)
  if not requireAuth(pid) then return end
  if race.phase ~= 'grid' then return end
  race.phase = 'countdown'
  countdownValue = COUNTDOWN_FROM
  broadcastState()
  broadcastCountdown(countdownValue)
  MP.CreateEventTimer('RM_CountdownTick', 1000)
  print('[RaceManager] Countdown started by ' .. (MP.GetPlayerName(pid) or pid))
end

function RM_CountdownTick()
  if race.phase ~= 'countdown' then
    MP.CancelEventTimer('RM_CountdownTick')
    return
  end
  countdownValue = countdownValue - 1
  if countdownValue > 0 then
    broadcastCountdown(countdownValue)
    return
  end
  -- GO!
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(0)
  race.phase = 'racing'
  race.time = 0.0
  lapFirsts = {}
  for _, rec in pairs(players) do
    if rec.status == 'gridded' then
      rec.status     = 'racing'
      rec.currentLap = 1
      rec.raceBest   = nil
      rec.lapsLed    = 0
      rec.finishTime = nil
    end
  end
  broadcastState()
  print('[RaceManager] GO! (' .. race.totalLaps .. ' laps)')
end

-- End Session: during a race anyone still on track becomes DNF; during
-- qualifying the session closes but Best Laps are kept so the grid can
-- still be generated.
function RM_onEndRace(pid)
  if not requireAuth(pid) then return end
  if race.phase == 'racing' or race.phase == 'countdown' then
    MP.CancelEventTimer('RM_CountdownTick')
    broadcastCountdown(-1)  -- hide any countdown overlay
    for _, rec in pairs(players) do
      if rec.status == 'racing' or rec.status == 'gridded' then
        rec.status = 'dnf'
      end
    end
    finishRace('ended by ' .. (MP.GetPlayerName(pid) or pid))
  elseif race.phase == 'qualifying' then
    race.phase = 'waiting'
    broadcastState()
    print('[RaceManager] Qualifying closed by ' .. (MP.GetPlayerName(pid) or pid))
  end
end

function RM_onResetLeaderboard(pid)
  if not requireAuth(pid) then return end
  MP.CancelEventTimer('RM_CountdownTick')
  broadcastCountdown(-1)
  players = {}
  lapFirsts = {}
  race.phase = 'waiting'
  race.time = 0.0
  for id in pairs(MP.GetPlayers()) do
    ensurePlayer(id)
  end
  broadcastState()
  print('[RaceManager] Session reset by ' .. (MP.GetPlayerName(pid) or pid))
end

-- ---------------------------------------------------------------------------
-- Lap reports from clients
-- ---------------------------------------------------------------------------

-- Qualifying: client completed a timed lap; keep the best.
function RM_onQualiLap(pid, rawData)
  if race.phase ~= 'qualifying' then return end
  local rec = ensurePlayer(pid)
  if rec.status ~= 'qualifying' then rec.status = 'qualifying' end
  local lapTime = decodeNumber(rawData, 'lapTime')
  if not lapTime or lapTime <= 0 then return end
  if not rec.qualiBest or lapTime < rec.qualiBest then
    rec.qualiBest = lapTime
    print(string.format('[RaceManager] %s quali best: %.3fs', rec.name, lapTime))
  end
  broadcastState()
end

-- Race: client crossed the start/finish line after all checkpoints.
-- Server decides Laps Led (first report per lap number wins — one arrival
-- order for everyone) and the finish (lap count reached).
function RM_onLap(pid, rawData)
  if race.phase ~= 'racing' then return end
  local rec = ensurePlayer(pid)
  if rec.status ~= 'racing' then return end
  local lapTime = decodeNumber(rawData, 'lapTime')
  if lapTime and lapTime > 0 and (not rec.raceBest or lapTime < rec.raceBest) then
    rec.raceBest = lapTime
  end

  local completed = rec.currentLap
  if not lapFirsts[completed] then
    lapFirsts[completed] = pid
    rec.lapsLed = rec.lapsLed + 1
  end

  if completed >= race.totalLaps then
    rec.status = 'finished'
    rec.finishTime = race.time
    print(string.format('[RaceManager] %s finished %d laps at %.3fs (led %d)',
      rec.name, completed, race.time, rec.lapsLed))
    -- Everyone done (finished or dnf)? Close the race.
    for _, r in pairs(players) do
      if r.status == 'racing' then
        broadcastState()
        return
      end
    end
    finishRace('all drivers finished')
    return
  else
    rec.currentLap = completed + 1
  end
  broadcastState()
end

-- Clear Results Cache: delete every saved .txt in the results folder.
function RM_onClearResults(pid)
  if not requireAuth(pid) then return end
  local ok, removed = pcall(clearResultsCache)
  if not ok then
    print('[RaceManager] Failed to clear results cache: ' .. tostring(removed))
    return
  end
  local msg = string.format('[RaceManager] Results cache cleared by %s (%d file%s removed from %s)',
    MP.GetPlayerName(pid) or pid, removed, removed == 1 and '' or 's', RESULTS_DIR)
  MP.SendChatMessage(-1, msg)
  print(msg)
end

-- Client asks for current state (UI app just opened).
function RM_onRequestState(pid)
  broadcastState(pid)
end

-- ---------------------------------------------------------------------------
-- Track layouts: persistent, per-map checkpoint configurations
-- ---------------------------------------------------------------------------
-- Admins build a gate route with the in-game editor, then save it here under a
-- name. Layouts persist in layouts.json across server restarts and are keyed
-- by the BeamNG level name; the UI only ever sees layouts for the map this
-- server is currently hosting. Loading a layout broadcasts the checkpoints to
-- every connected client at once so the whole grid races the same track.
local LAYOUTS_DIR  = 'Resources/Server/RaceManager'
local LAYOUTS_FILE = LAYOUTS_DIR .. '/layouts.json'
local MAX_LAYOUT_NAME = 40
local layouts = nil  -- lazy-loaded array of { name, map, width, checkpoints }

-- Self-contained JSON encode/decode for the layouts file. Util.JsonEncode is
-- still used for network payloads, but persistence gets its own (strict,
-- mock-independent) codec so the headless tests exercise the real file format.
local function jsonStringify(v)
  local t = type(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'number' then return string.format('%.10g', v) end
  if t == 'string' then
    return '"' .. v:gsub('[%c"\\]', function (c)
      if c == '"' then return '\\"' end
      if c == '\\' then return '\\\\' end
      if c == '\n' then return '\\n' end
      if c == '\r' then return '\\r' end
      if c == '\t' then return '\\t' end
      return string.format('\\u%04x', c:byte())
    end) .. '"'
  end
  if t == 'table' then
    local parts = {}
    if #v > 0 or next(v) == nil then  -- array (empty tables encode as [])
      for _, item in ipairs(v) do parts[#parts + 1] = jsonStringify(item) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    for k, item in pairs(v) do
      if type(k) == 'string' then
        parts[#parts + 1] = jsonStringify(k) .. ':' .. jsonStringify(item)
      end
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  return 'null'
end

local function jsonParse(text)
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
          local hex = text:sub(pos + 2, pos + 5)
          local cp = tonumber(hex, 16) or err('bad \\u escape')
          out[#out + 1] = cp < 128 and string.char(cp) or '?'
          pos = pos + 6
        else
          local map = { n = '\n', r = '\r', t = '\t', b = '\b', f = '\f' }
          out[#out + 1] = map[e] or e
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

-- The BeamMP server config names the hosted level as "/levels/<name>/info.json";
-- everything is normalized down to the bare level name ("gridmap_v2") so saved
-- layouts compare cleanly no matter which form the API returns.
local function normalizeMapName(raw)
  if type(raw) ~= 'string' then return nil end
  local name = raw:match('/?[Ll]evels/([^/]+)') or raw
  name = name:gsub('%.json$', ''):gsub('/info$', ''):gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then return nil end
  return name
end

local function getCurrentMap()
  -- Primary: the BeamMP settings API.
  if MP.Get and MP.Settings and MP.Settings.Map ~= nil then
    local ok, raw = pcall(MP.Get, MP.Settings.Map)
    local name = ok and normalizeMapName(raw)
    if name then return name end
  end
  -- Fallback: parse ServerConfig.toml in the server's working directory.
  local f = io.open('ServerConfig.toml', 'r')
  if f then
    for line in f:lines() do
      local raw = line:match('^%s*Map%s*=%s*"([^"]*)"')
      if raw then
        f:close()
        return normalizeMapName(raw) or 'unknown'
      end
    end
    f:close()
  end
  return 'unknown'
end

local function ensureLayoutsDir()
  if FS and FS.CreateDirectory then
    FS.CreateDirectory(LAYOUTS_DIR)
  else
    os.execute('mkdir -p "' .. LAYOUTS_DIR .. '"')
  end
end

local function loadLayoutsFromDisk()
  local f = io.open(LAYOUTS_FILE, 'r')
  if not f then return {} end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(jsonParse, text)
  if not ok or type(data) ~= 'table' or type(data.layouts) ~= 'table' then
    print('[RaceManager] Could not parse ' .. LAYOUTS_FILE .. ', starting with no layouts')
    return {}
  end
  local out = {}
  for _, l in ipairs(data.layouts) do
    if type(l) == 'table' and type(l.name) == 'string' and type(l.map) == 'string'
        and type(l.checkpoints) == 'table' and #l.checkpoints > 0 then
      out[#out + 1] = l
    end
  end
  return out
end

local function getLayouts()
  if not layouts then
    layouts = loadLayoutsFromDisk()
    print('[RaceManager] Loaded ' .. #layouts .. ' saved layout(s) from ' .. LAYOUTS_FILE)
  end
  return layouts
end

local function saveLayoutsToDisk()
  ensureLayoutsDir()
  local f, ferr = io.open(LAYOUTS_FILE, 'w')
  if not f then return false, tostring(ferr) end
  f:write(jsonStringify({ version = 1, layouts = getLayouts() }))
  f:close()
  return true
end

-- Checkpoints as the client editor stores them: position + normalized travel
-- heading (the gate's rotation) + the shared gate dimensions saved per layout.
-- Per-checkpoint width/height/depth overrides are optional and only kept when
-- present, so a gate with no override inherits the layout-wide defaults.
local function sanitizeCheckpoints(raw)
  if type(raw) ~= 'table' then return nil end
  local out = {}
  for i, cp in ipairs(raw) do
    if type(cp) ~= 'table' then return nil end
    local x, y, z = tonumber(cp.x), tonumber(cp.y), tonumber(cp.z)
    if not (x and y and z) then return nil end
    out[i] = { x = x, y = y, z = z, hx = tonumber(cp.hx) or 0, hy = tonumber(cp.hy) or 1 }
    if tonumber(cp.width)  then out[i].width  = tonumber(cp.width)  end
    if tonumber(cp.height) then out[i].height = tonumber(cp.height) end
    if tonumber(cp.depth)  then out[i].depth  = tonumber(cp.depth)  end
  end
  if #out == 0 then return nil end
  return out
end

-- Strict map filter: the UI only ever sees layouts saved for the map this
-- server is hosting right now.
local function layoutsForCurrentMap()
  local map = getCurrentMap()
  local list = {}
  for _, l in ipairs(getLayouts()) do
    if l.map == map then list[#list + 1] = l end
  end
  table.sort(list, function (a, b) return a.name:lower() < b.name:lower() end)
  return list, map
end

local function sendLayoutList(targetPid)
  local list, map = layoutsForCurrentMap()
  local gates = 0
  for _, l in ipairs(list) do gates = gates + #l.checkpoints end
  print(string.format('[RaceManager] Sending layout list to %s: %d layout(s), %d gate(s) total, map %s',
    targetPid and tostring(targetPid) or 'all', #list, gates, map))
  MP.TriggerClientEvent(targetPid or -1, 'RM_Layouts',
    Util.JsonEncode({ map = map, layouts = list }))
end

function RM_onRequestLayouts(pid)
  sendLayoutList(pid)
end

-- Strict track-state purge. Drops the in-memory layout cache (the next access
-- re-reads layouts.json from disk, so nothing stale survives in a global) and
-- orders every client to delete its checkpoint arrays and 3D gate visuals.
-- Broadcast on server boot and immediately before a new layout is applied, so
-- ghost checkpoints from an earlier session can never leak into a new one.
local function clearTrackState(reason)
  layouts = nil
  MP.TriggerClientEvent(-1, 'RM_ClearTrack', Util.JsonEncode({ reason = reason or 'clear' }))
  print('[RaceManager] Track state cleared: ' .. (reason or 'clear'))
end

-- Client/UI asked for an explicit full clear (also refreshes everyone's list).
function RM_onClearTrackState(pid)
  if not requireAuth(pid) then return end
  clearTrackState('requested by ' .. (MP.GetPlayerName(pid) or pid))
  sendLayoutList(-1)
end

-- Save the checkpoints the client bundled up as a named layout for the current
-- map. Same name on the same map overwrites (that's the edit workflow); the
-- refreshed list goes to every client so all open UIs stay in sync.
-- Every rejection branch logs its reason so a dropped save is diagnosable.
function RM_onSaveLayout(pid, rawData)
  if not requireAuth(pid) then return end
  print(string.format('[RaceManager] RM_SaveLayout from %s: %s byte(s)',
    MP.GetPlayerName(pid) or pid, type(rawData) == 'string' and #rawData or 'non-string'))
  if type(rawData) ~= 'string' or rawData == '' then
    print('[RaceManager] Save rejected: empty payload')
    return
  end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then
    print('[RaceManager] Save rejected: JSON decode failed (' .. tostring(data) .. ')')
    return
  end

  local name = type(data.name) == 'string'
    and data.name:gsub('^%s+', ''):gsub('%s+$', ''):sub(1, MAX_LAYOUT_NAME) or ''
  local checkpoints = sanitizeCheckpoints(data.checkpoints)
  if name == '' then
    print('[RaceManager] Save rejected: missing/empty layout name')
    return
  end
  if not checkpoints then
    print('[RaceManager] Save rejected: checkpoint array missing or malformed')
    return
  end

  local map = getCurrentMap()
  local entry = {
    name        = name,
    map         = map,
    width       = tonumber(data.width)  or 20,
    height      = tonumber(data.height) or 10,
    depth       = tonumber(data.depth)  or 4,
    checkpoints = checkpoints,
  }
  local all = getLayouts()
  local replaced = false
  for i, l in ipairs(all) do
    if l.map == map and l.name:lower() == name:lower() then
      all[i] = entry
      replaced = true
      break
    end
  end
  if not replaced then all[#all + 1] = entry end

  local wrote, werr = saveLayoutsToDisk()
  if not wrote then
    print('[RaceManager] Failed to write ' .. LAYOUTS_FILE .. ': ' .. tostring(werr))
    return
  end
  local msg = string.format('[RaceManager] Layout "%s" (%d gates, %s) %s by %s',
    name, #checkpoints, map, replaced and 'updated' or 'saved', MP.GetPlayerName(pid) or pid)
  MP.SendChatMessage(-1, msg)
  print(msg)
  sendLayoutList(-1)
end

-- Load a saved layout: look it up under the current map only and broadcast the
-- checkpoint set to every connected client, which instantly rebuilds its gates.
-- Locked once a countdown/race is under way — nobody swaps the track mid-race.
function RM_onLoadLayout(pid, rawData)
  if not requireAuth(pid) then return end
  if race.phase == 'countdown' or race.phase == 'racing' then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' or type(data.name) ~= 'string' then return end

  local list, map = layoutsForCurrentMap()
  for _, l in ipairs(list) do
    if l.name:lower() == data.name:lower() then
      -- Purge first: every client must drop its existing gates before the new
      -- set arrives, so no checkpoint from a previous layout can survive.
      clearTrackState('loading layout "' .. l.name .. '"')
      print(string.format('[RaceManager] Broadcasting RM_ApplyLayout: "%s", %d checkpoint(s), width %s',
        l.name, #l.checkpoints, tostring(l.width)))
      MP.TriggerClientEvent(-1, 'RM_ApplyLayout', Util.JsonEncode(l))
      local msg = string.format('[RaceManager] Layout "%s" loaded on %s by %s (%d gates)',
        l.name, map, MP.GetPlayerName(pid) or pid, #l.checkpoints)
      MP.SendChatMessage(-1, msg)
      print(msg)
      return
    end
  end
  print(string.format('[RaceManager] Load failed: no layout "%s" for map %s', data.name, map))
end

-- ===========================================================================
-- DEMO DERBY (isolated module)
-- ===========================================================================
-- Completely independent of the circuit racing state machine above: its own
-- state tables, its own event names (RM_Derby*), its own broadcast channel
-- (RM_DerbyUpdate), its own tick timer and its own results file. Nothing in
-- this section reads or writes `race`, `players`, `lapFirsts` or the layout
-- store, so derby sessions can never disturb qualifying/racing and vice versa.
--
-- Flow: admin tunes the two timers and drops boundary markers (clients send
-- their vehicle position via RM_DerbyAddMarker), then Start Derby snapshots
-- every connected player as an active participant. Clients police themselves
-- (point-in-polygon + stopped-vehicle detection happen client-side, where the
-- physics live) and report RM_DerbyDisqualified / RM_DerbyDemolished; the
-- server is authoritative for the participant list, elimination order, the
-- last-man-standing win condition and the results .txt export.

local DERBY_DEFAULT_OOB_LIMIT  = 5    -- seconds allowed outside the boundary
local DERBY_DEFAULT_DEMO_LIMIT = 10   -- seconds stopped before demolished
local DERBY_MIN_LIMIT          = 1
local DERBY_MAX_LIMIT          = 120
local DERBY_TICK_MS            = 1000 -- derby clock resolution (1 s is plenty)
local DERBY_MAX_MARKERS        = 64

local derby = {
  phase     = 'idle',   -- idle | running | finished
  oobLimit  = DERBY_DEFAULT_OOB_LIMIT,
  demoLimit = DERBY_DEFAULT_DEMO_LIMIT,
  time      = 0,        -- seconds since Start Derby (advanced by RM_DerbyTick)
  boundary  = {},       -- ordered polygon vertices { x, y, z }
  winner    = nil,      -- winner's name once decided
}
local derbyPlayers = {} -- [pid] = { id, name, status, reason, elimTime }
                        -- status: alive | eliminated | winner

local function derbyClampLimit(n, default)
  n = tonumber(n)
  if not n then return default end
  if n < DERBY_MIN_LIMIT then return DERBY_MIN_LIMIT end
  if n > DERBY_MAX_LIMIT then return DERBY_MAX_LIMIT end
  return n
end

-- Participants ordered for display/results: winner first, then survivors,
-- then eliminated players latest-out first (2nd place = last one eliminated).
local function derbyClassification()
  local list = {}
  for _, rec in pairs(derbyPlayers) do list[#list + 1] = rec end
  table.sort(list, function (a, b)
    local rank = { winner = 0, alive = 1, eliminated = 2 }
    local ra, rb = rank[a.status] or 3, rank[b.status] or 3
    if ra ~= rb then return ra < rb end
    if ra == 2 and a.elimTime ~= b.elimTime then return a.elimTime > b.elimTime end
    return a.id < b.id
  end)
  return list
end

local function broadcastDerbyState(targetPid)
  MP.TriggerClientEvent(targetPid or -1, 'RM_DerbyUpdate', Util.JsonEncode({
    derbyPhase = derby.phase,
    oobLimit   = derby.oobLimit,
    demoLimit  = derby.demoLimit,
    derbyTime  = derby.time,
    boundary   = derby.boundary,
    winner     = derby.winner,
    players    = derbyClassification(),
  }))
end

local function derbyFmtTime(t)
  if not t then return '--:--' end
  local m = math.floor(t / 60)
  return string.format('%d:%02d', m, math.floor(t - m * 60))
end

local function buildDerbyResultsText()
  local list = derbyClassification()
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  add('==================================================')
  add(' RACE MANAGER - DEMO DERBY RESULTS')
  add(' ' .. os.date('%Y-%m-%d %H:%M:%S'))
  add(string.format(' Duration: %s | Drivers: %d | OOB limit: %gs | Stop limit: %gs',
    derbyFmtTime(derby.time), #list, derby.oobLimit, derby.demoLimit))
  add('==================================================')
  add('')
  add(string.format('%-5s %-22s %-14s %s', 'Pos', 'Driver', 'Result', 'Eliminated At'))
  for i, rec in ipairs(list) do
    local result, elimAt
    if rec.status == 'winner' then
      result, elimAt = 'WINNER', 'survived'
    elseif rec.status == 'alive' then
      result, elimAt = 'Still running', '-'
    else
      result, elimAt = rec.reason or 'Eliminated', derbyFmtTime(rec.elimTime)
    end
    local tag = rec.status == 'winner' and '  << LAST MAN STANDING' or ''
    add(string.format('P%-4d %-22s %-14s %-13s%s', i, rec.name, result, elimAt, tag))
  end
  if #list == 0 then add('(no drivers)') end
  add('')
  return table.concat(lines, '\n') .. '\n'
end

local function writeDerbyResults()
  ensureResultsDir()
  local path = uniqueResultsPath('derby_results')
  local f, err = io.open(path, 'w')
  if not f then return false, tostring(err) end
  f:write(buildDerbyResultsText())
  f:close()
  return true, path
end

-- Single exit point for every way a derby ends (last man standing, admin
-- ended, everyone eliminated): stop the clock, export results, announce.
local function finishDerby(reason)
  derby.phase = 'finished'
  MP.CancelEventTimer('RM_DerbyTick')
  broadcastDerbyState()
  print('[RaceManager] Derby over: ' .. reason)
  local ok, wrote, pathOrErr = pcall(writeDerbyResults)
  if ok and wrote then
    local msg = derby.winner
      and ('[RaceManager] DEMO DERBY WINNER: ' .. derby.winner .. '! Results saved: ' .. pathOrErr)
      or  ('[RaceManager] Demo derby over (' .. reason .. '). Results saved: ' .. pathOrErr)
    MP.SendChatMessage(-1, msg)
    print('[RaceManager] Derby results written to ' .. pathOrErr)
  else
    print('[RaceManager] Failed to write derby results: ' .. tostring(ok and pathOrErr or wrote))
  end
end

-- Eliminate one participant; when exactly one is left standing the derby ends
-- itself and crowns the survivor.
local function derbyEliminate(pid, reason)
  if derby.phase ~= 'running' then return end
  local rec = derbyPlayers[pid]
  if not rec or rec.status ~= 'alive' then return end  -- duplicate reports are no-ops
  rec.status   = 'eliminated'
  rec.reason   = reason
  rec.elimTime = derby.time
  print(string.format('[RaceManager] Derby: %s eliminated (%s) at %s',
    rec.name, reason, derbyFmtTime(derby.time)))

  local alive, lastAlive = 0, nil
  for _, r in pairs(derbyPlayers) do
    if r.status == 'alive' then alive = alive + 1; lastAlive = r end
  end
  if alive == 1 then
    lastAlive.status = 'winner'
    derby.winner = lastAlive.name
    finishDerby('last man standing: ' .. lastAlive.name)
  elseif alive == 0 then
    finishDerby('no survivors')
  else
    broadcastDerbyState()
  end
end

-- --- Derby event handlers (admin controls relayed by the client bridge) ----

function RM_onDerbySetConfig(pid, rawData)
  if not requireAuth(pid) then return end
  if derby.phase == 'running' then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  derby.oobLimit  = derbyClampLimit(data.oobLimit,  derby.oobLimit)
  derby.demoLimit = derbyClampLimit(data.demoLimit, derby.demoLimit)
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby config by %s: OOB %gs, stop %gs',
    MP.GetPlayerName(pid) or pid, derby.oobLimit, derby.demoLimit))
end

-- Admin dropped a boundary marker at their vehicle's position; the ordered
-- marker list is the arena polygon every client runs point-in-polygon against.
function RM_onDerbyAddMarker(pid, rawData)
  if not requireAuth(pid) then return end
  if derby.phase == 'running' then return end
  if #derby.boundary >= DERBY_MAX_MARKERS then return end
  if type(rawData) ~= 'string' or rawData == '' then return end
  local ok, data = pcall(Util.JsonDecode, rawData)
  if not ok or type(data) ~= 'table' then return end
  local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
  if not (x and y and z) then return end
  derby.boundary[#derby.boundary + 1] = { x = x, y = y, z = z }
  broadcastDerbyState()
  print(string.format('[RaceManager] Derby marker %d placed by %s at %.1f, %.1f',
    #derby.boundary, MP.GetPlayerName(pid) or pid, x, y))
end

function RM_onDerbyClearBoundary(pid)
  if not requireAuth(pid) then return end
  if derby.phase == 'running' then return end
  derby.boundary = {}
  broadcastDerbyState()
  print('[RaceManager] Derby boundary cleared by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Start Derby: snapshot every connected player as an active participant and
-- start the derby clock. A fresh start from 'finished' wipes the last session.
function RM_onDerbyStart(pid)
  if not requireAuth(pid) then return end
  if derby.phase == 'running' then return end
  derbyPlayers = {}
  derby.winner = nil
  derby.time   = 0
  for id in pairs(MP.GetPlayers()) do
    derbyPlayers[id] = {
      id       = id,
      name     = MP.GetPlayerName(id) or ('Player ' .. id),
      status   = 'alive',
      reason   = nil,
      elimTime = nil,
    }
  end
  local count = 0
  for _ in pairs(derbyPlayers) do count = count + 1 end
  if count == 0 then
    print('[RaceManager] Derby start ignored: no players connected')
    return
  end
  derby.phase = 'running'
  MP.CreateEventTimer('RM_DerbyTick', DERBY_TICK_MS)
  broadcastDerbyState()
  MP.SendChatMessage(-1, string.format(
    '[RaceManager] DEMO DERBY STARTED! %d drivers. Stay inside the arena and keep moving!', count))
  print('[RaceManager] Derby started by ' .. (MP.GetPlayerName(pid) or pid)
    .. ' (' .. count .. ' drivers, ' .. #derby.boundary .. ' boundary markers)')
end

-- End Derby (admin): if exactly one driver is still alive they take the win,
-- otherwise the derby closes with no winner.
function RM_onDerbyEnd(pid)
  if not requireAuth(pid) then return end
  if derby.phase ~= 'running' then
    -- Allow clearing a finished derby back to idle from the UI.
    if derby.phase == 'finished' then
      derby.phase = 'idle'
      derby.winner = nil
      derby.time = 0
      derbyPlayers = {}
      broadcastDerbyState()
      print('[RaceManager] Derby reset to idle by ' .. (MP.GetPlayerName(pid) or pid))
    end
    return
  end
  local alive, lastAlive = 0, nil
  for _, r in pairs(derbyPlayers) do
    if r.status == 'alive' then alive = alive + 1; lastAlive = r end
  end
  if alive == 1 then
    lastAlive.status = 'winner'
    derby.winner = lastAlive.name
  end
  finishDerby('ended by ' .. (MP.GetPlayerName(pid) or pid))
end

-- Client self-reports: out-of-bounds timer expired.
function RM_onDerbyDisqualified(pid)
  derbyEliminate(pid, 'Disqualified')
end

-- Client self-reports: stopped-vehicle timer expired.
function RM_onDerbyDemolished(pid)
  derbyEliminate(pid, 'Demolished')
end

function RM_onDerbyRequestState(pid)
  broadcastDerbyState(pid)
end

-- Registered as an ADDITIONAL handler on onPlayerJoin/onPlayerDisconnect so
-- the circuit-racing handlers above stay untouched.
function RM_Derby_onPlayerJoin(pid)
  broadcastDerbyState(pid)  -- late joiners spectate the running derby
end

function RM_Derby_onPlayerDisconnect(pid)
  if derby.phase == 'running' and derbyPlayers[pid]
      and derbyPlayers[pid].status == 'alive' then
    derbyEliminate(pid, 'Disqualified')
  end
end

function RM_DerbyTick()
  if derby.phase ~= 'running' then
    MP.CancelEventTimer('RM_DerbyTick')
    return
  end
  derby.time = derby.time + DERBY_TICK_MS / 1000.0
  broadcastDerbyState()
end

-- ===========================================================================
-- End of DEMO DERBY module
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Clock + lifecycle
-- ---------------------------------------------------------------------------
function RM_Tick()
  if race.phase ~= 'racing' then return end
  race.time = race.time + TICK_MS / 1000.0
  tickCounter = tickCounter + 1
  if tickCounter >= PUSH_EVERY_TICKS then
    tickCounter = 0
    broadcastState()
  end
end

function RM_onPlayerJoin(pid)
  local rec = ensurePlayer(pid)
  -- Joining mid-quali means you can set a time; mid-race you spectate.
  if race.phase == 'qualifying' then rec.status = 'qualifying' end
  broadcastState()
end

function RM_onPlayerDisconnect(pid)
  -- Session IDs are reused, so a disconnecting admin must drop its auth flag;
  -- the next player to inherit this ID starts with no admin rights.
  authenticatedPlayers[pid] = nil
  local rec = players[pid]
  if not rec then return end
  if rec.status == 'racing' or rec.status == 'gridded' then
    rec.status = 'dnf'
  elseif rec.status == 'waiting' or (rec.status == 'qualifying' and not rec.qualiBest) then
    players[pid] = nil
  end
  -- If the last active racer just dropped, the race is over.
  if race.phase == 'racing' then
    for _, r in pairs(players) do
      if r.status == 'racing' then
        broadcastState()
        return
      end
    end
    finishRace('no racers left on track')
    return
  end
  broadcastState()
end

function onInit()
  MP.RegisterEvent('RM_Login',            'RM_onLogin')
  MP.RegisterEvent('RM_ChangePassword',   'RM_onChangePassword')
  MP.RegisterEvent('RM_StartQualifying',  'RM_onStartQualifying')
  MP.RegisterEvent('RM_GenerateGrid',     'RM_onGenerateGrid')
  MP.RegisterEvent('RM_SetTotalLaps',     'RM_onSetTotalLaps')
  MP.RegisterEvent('RM_StartCountdown',   'RM_onStartCountdown')
  MP.RegisterEvent('RM_EndRace',          'RM_onEndRace')
  MP.RegisterEvent('RM_ResetLeaderboard', 'RM_onResetLeaderboard')
  MP.RegisterEvent('RM_QualiLap',         'RM_onQualiLap')
  MP.RegisterEvent('RM_ClearResults',     'RM_onClearResults')
  MP.RegisterEvent('RM_Lap',              'RM_onLap')
  MP.RegisterEvent('RM_RequestState',     'RM_onRequestState')
  MP.RegisterEvent('RM_RequestLayouts',   'RM_onRequestLayouts')
  MP.RegisterEvent('RM_SaveLayout',       'RM_onSaveLayout')
  MP.RegisterEvent('RM_LoadLayout',       'RM_onLoadLayout')
  MP.RegisterEvent('RM_ClearTrackState',  'RM_onClearTrackState')
  -- Demo Derby module (isolated event namespace; see the DEMO DERBY section).
  MP.RegisterEvent('RM_DerbySetConfig',     'RM_onDerbySetConfig')
  MP.RegisterEvent('RM_DerbyAddMarker',     'RM_onDerbyAddMarker')
  MP.RegisterEvent('RM_DerbyClearBoundary', 'RM_onDerbyClearBoundary')
  MP.RegisterEvent('RM_DerbyStart',         'RM_onDerbyStart')
  MP.RegisterEvent('RM_DerbyEnd',           'RM_onDerbyEnd')
  MP.RegisterEvent('RM_DerbyDisqualified',  'RM_onDerbyDisqualified')
  MP.RegisterEvent('RM_DerbyDemolished',    'RM_onDerbyDemolished')
  MP.RegisterEvent('RM_DerbyRequestState',  'RM_onDerbyRequestState')
  MP.RegisterEvent('RM_DerbyTick',          'RM_DerbyTick')
  MP.RegisterEvent('onPlayerJoin',          'RM_Derby_onPlayerJoin')
  MP.RegisterEvent('onPlayerDisconnect',    'RM_Derby_onPlayerDisconnect')
  MP.RegisterEvent('onPlayerJoin',        'RM_onPlayerJoin')
  MP.RegisterEvent('onPlayerDisconnect',  'RM_onPlayerDisconnect')
  MP.RegisterEvent('RM_Tick',             'RM_Tick')
  MP.RegisterEvent('RM_CountdownTick',    'RM_CountdownTick')
  MP.CreateEventTimer('RM_Tick', TICK_MS)
  -- Boot from a clean slate: any client still connected across a plugin
  -- reload drops its stale gates, then the layout cache is re-warmed from disk.
  clearTrackState('server startup')
  getLayouts()  -- warm the layout cache so saved tracks survive the restart visibly
  print('[RaceManager] Server plugin loaded (circuit edition, map: ' .. getCurrentMap() .. ')')
end
