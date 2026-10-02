-- Race Manager: LAP RECORDS, a persistent leaderboard per map and layout.
--
-- Each driver's best lap of every qualifying and race session goes on the board
-- for the saved layout that session ran on. One row per driver, fastest first.
--
-- NOTHING GLOBAL AT FILE SCOPE. "records" sorts after "main", so BeamMP runs
-- this file on its own after main.lua has loaded it, and a file-scope handler
-- would replace the initialised one. The RM_Records* globals come from init().
--
-- THE FILE IS THE TRUTH, not memory. Every read opens it, and every write reads
-- it first, so an admin's hand edit shows up the next time the board is opened
-- and is never written over with an older copy. A file that does not parse is
-- never written at all: the session's laps are dropped instead, and logged.
--
-- Scored ONCE per session, from finishSession. Nothing here runs while cars
-- are on track.

local M = {}
local host

-- Data/Lap Records/<map>.json, beside Race Layout and Derby Arena.
M.FOLDER = 'Lap Records'
M.KEEP = 100     -- rows kept per layout
M.SHOW = 50      -- rows sent to the panel
M.MAX_LAYOUT_NAME = 40

local function dir() return host.DATA_DIR .. '/' .. M.FOLDER end

-- Named the way Race Layout names its files, so a map's two files match.
function M.fileFor(map)
  local safe = tostring(map or 'unknown'):gsub('[^%w%-_%.]', '_')
  if safe == '' then safe = 'unknown' end
  return dir() .. '/' .. safe .. '.json'
end

local function trim(s)
  return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- To the millisecond: the client reports more digits than anyone can drive to,
-- and a tie that differs in the ninth place is not a win.
local function ms(t) return math.floor(t * 1000 + 0.5) / 1000 end

-- One row from the file. Scalar fields nobody here knows about (a "note" an
-- admin typed in) are kept, so a rewrite does not strip them.
local function clean(e)
  if type(e) ~= 'table' then return nil end
  local t = tonumber(e.time)
  local driver = type(e.driver) == 'string' and trim(e.driver) or ''
  if not t or t ~= t or t <= 0 or t == math.huge or driver == '' then return nil end
  local row = {}
  for k, v in pairs(e) do
    local kind = type(v)
    if type(k) == 'string' and (kind == 'string' or kind == 'number' or kind == 'boolean') then
      row[k] = v
    end
  end
  row.driver, row.time = driver, ms(t)
  return row
end

local function find(board, driver)
  local key = driver:lower()
  for i, row in ipairs(board.laps) do
    if row.driver:lower() == key then return row, i end
  end
end

-- Faster replaces slower; a slower lap for a driver already on the board is ignored.
local function put(board, row)
  local have, i = find(board, row.driver)
  if have and have.time <= row.time then return false end
  if i then board.laps[i] = row else board.laps[#board.laps + 1] = row end
  return true
end

-- Fastest first. A tie goes to whoever set it first, as a record should.
local function settle(board)
  table.sort(board.laps, function (a, b)
    if a.time ~= b.time then return a.time < b.time end
    return tostring(a.date or '') < tostring(b.date or '')
  end)
  for i = #board.laps, M.KEEP + 1, -1 do board.laps[i] = nil end
end

-- { [lower layout name] = { name, laps } }, plus whether it is safe to write.
-- false only for a file that exists and does not parse.
function M.read(map)
  local path = M.fileFor(map)
  local f = io.open(path, 'r')
  if not f then return {}, true end
  local text = f:read('*a')
  f:close()
  local ok, data = pcall(host.jsonParse, text)
  if not ok or type(data) ~= 'table' then
    print('[RaceManager] Could not parse ' .. path .. ': lap records on this map are '
      .. 'not shown or saved until it is fixed. It is left exactly as it is.')
    return {}, false
  end
  local boards = {}
  for name, laps in pairs(type(data.layouts) == 'table' and data.layouts or {}) do
    if type(name) == 'string' and trim(name) ~= '' and type(laps) == 'table' then
      local key = trim(name):lower()
      boards[key] = boards[key] or { name = trim(name), laps = {} }
      for _, e in ipairs(laps) do
        local row = clean(e)
        if row then put(boards[key], row) end
      end
      settle(boards[key])
    end
  end
  return boards, true
end

-- A map with no records left loses its file, as a map with no layouts does.
function M.write(map, boards)
  local layouts, any = {}, false
  for _, b in pairs(boards) do
    if #b.laps > 0 then layouts[b.name] = b.laps; any = true end
  end
  local path = M.fileFor(map)
  if not any then
    host.removeFile(path)
    return true
  end
  host.makeDirectory(host.DATA_DIR)
  host.makeDirectory(dir())
  local status, err = host.writeFile(path, host.jsonStringify({
    version = 1, map = map, layouts = layouts }))
  if not status then
    print('[RaceManager] Failed to write ' .. path .. ': ' .. tostring(err))
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- To the panel
-- ---------------------------------------------------------------------------
-- The board asked for, else the loaded layout's, else the first with records.
-- `exact` names the board even when it is empty: a board just cleared has to
-- reach the people looking at it as empty, not as some other layout.
local function payload(map, boards, want, ok, exact)
  local list = {}
  for _, b in pairs(boards) do
    if #b.laps > 0 then
      list[#list + 1] = { name = b.name, count = #b.laps,
        time = b.laps[1].time, driver = b.laps[1].driver }
    end
  end
  table.sort(list, function (a, b) return a.name:lower() < b.name:lower() end)

  local loaded = type(host.race.layout) == 'table' and host.race.layout.name or nil
  local pickName = exact and want or nil
  for _, name in ipairs({ want or false, loaded or false }) do
    if name and not pickName and (boards[name:lower()] or (loaded and name:lower() == loaded:lower())) then
      pickName = name
    end
  end
  pickName = pickName or (list[1] and list[1].name)
  local board = pickName and boards[pickName:lower()]

  local rows = {}
  for i = 1, math.min(board and #board.laps or 0, M.SHOW) do
    local e = board.laps[i]
    rows[i] = { pos = i, driver = e.driver, time = e.time, car = e.car,
      date = e.date, session = e.session }
  end
  return {
    map = map, mapLabel = host.mapLabel(map), loaded = loaded,
    layouts = list,
    layout = board and board.name or pickName,
    laps = rows, total = board and #board.laps or 0,
    file = M.FOLDER .. '/' .. M.fileFor(map):match('[^/]+$'),
    error = not ok and 'The lap records file for this map could not be read. '
      .. 'Fix it or delete it on the server: nothing is written over it.' or nil,
  }
end

local function send(target, want, changed)
  local map = host.getCurrentMap()
  local boards, ok = M.read(map)
  local out = payload(map, boards, want, ok, changed)
  out.changed = changed or nil
  MP.TriggerClientEvent(target, 'RM_Records', Util.JsonEncode(out))
end

local function decode(raw)
  local ok, data = pcall(Util.JsonDecode, raw or '')
  if ok and type(data) == 'table' then return data end
  return {}
end

local function layoutArg(data)
  local name = type(data.layout) == 'string' and trim(data.layout) or ''
  if name == '' or #name > M.MAX_LAYOUT_NAME then return nil end
  return name
end

-- Anyone: the board is public.
function M.request(pid, raw)
  send(pid, layoutArg(decode(raw)))
end

-- ---------------------------------------------------------------------------
-- Scoring a session
-- ---------------------------------------------------------------------------
-- `kind` is 'quali' or 'race'. raceBest is the session's best TIMED lap in both:
-- a qualifying out lap and a race's standing first lap never set one.
function M.onSession(kind)
  local layout = host.race.layout
  if type(layout) ~= 'table' or type(layout.name) ~= 'string' then
    print('[RaceManager] Lap records: no saved layout is loaded, so this session sets none')
    return
  end
  -- A circuit run as a sprint times something else, so it cannot share a board.
  if (host.race.pointToPoint == true) ~= (layout.pointToPoint == true) then
    print('[RaceManager] Lap records: "' .. layout.name .. '" was run '
      .. (host.race.pointToPoint and 'point to point' or 'as a circuit')
      .. ', not as saved, so this session sets none')
    return
  end

  local date = os.date('%Y-%m-%d')
  local laps = {}
  for _, rec in pairs(host.players) do
    local t = tonumber(rec.raceBest)
    -- Disqualified is out of the classification, and off the board with it.
    if t and t > 0 and rec.status ~= 'dsq' then
      laps[#laps + 1] = { pid = rec.id, row = {
        driver = host.displayName(rec), time = ms(t), date = date, session = kind,
        car = rec.bestCar or rec.carLabel,
      } }
    end
  end
  if #laps == 0 then return end

  local map = host.getCurrentMap()
  local boards, ok = M.read(map)
  if not ok then
    print('[RaceManager] Lap records from this session were NOT saved: '
      .. M.fileFor(map) .. ' does not parse')
    return
  end
  local key = layout.name:lower()
  local board = boards[key] or { name = layout.name, laps = {} }
  boards[key] = board
  local was = board.laps[1]

  local improved = {}
  for _, l in ipairs(laps) do
    if put(board, l.row) then improved[#improved + 1] = l end
  end
  if #improved == 0 then return end
  settle(board)
  if not M.write(map, boards) then return end

  local top = board.laps[1]
  local record = top and (not was or top.time < was.time)
  if record then
    local before = was and (' (was ' .. host.fmtLap(was.time) .. ', ' .. was.driver .. ')')
      or ' (the first on this track)'
    MP.SendChatMessage(-1, string.format('[RaceManager] NEW LAP RECORD on "%s": %s %s%s',
      board.name, top.driver, host.fmtLap(top.time), before))
  end
  for _, l in ipairs(improved) do
    local _, pos = find(board, l.row.driver)
    if pos and not (record and pos == 1) then
      MP.SendChatMessage(l.pid, string.format(
        '[RaceManager] Your best on "%s": %s, P%d of %d on the lap records.',
        board.name, host.fmtLap(l.row.time), pos, #board.laps))
    end
  end
  print(string.format('[RaceManager] Lap records, %s "%s": %d improved, %d on the board',
    map, board.name, #improved, #board.laps))
  send(-1, board.name, true)
end

-- ---------------------------------------------------------------------------
-- Admin: clearing (full admin only, there is no undo)
-- ---------------------------------------------------------------------------
local function editable(pid)
  local map = host.getCurrentMap()
  local boards, ok = M.read(map)
  if not ok then
    MP.SendChatMessage(pid, '[RaceManager] ' .. M.fileFor(map)
      .. ' does not parse, so it cannot be changed from here. Fix it on the server.')
    return nil
  end
  return map, boards
end

function M.clear(pid, raw)
  if not host.requireFull(pid) then return end
  local name = layoutArg(decode(raw))
  if not name then return end
  local map, boards = editable(pid)
  if not map then return end
  local board = boards[name:lower()]
  if not board then return send(pid, name) end
  boards[name:lower()] = nil
  if not M.write(map, boards) then return send(pid, name) end
  local msg = string.format('[RaceManager] Lap records for "%s" cleared by %s (%d time%s)',
    board.name, MP.GetPlayerName(pid) or pid, #board.laps, #board.laps == 1 and '' or 's')
  MP.SendChatMessage(-1, msg)
  print(msg)
  send(-1, board.name, true)
end

-- One row, for a lap that should not stand.
function M.remove(pid, raw)
  if not host.requireFull(pid) then return end
  local data = decode(raw)
  local name = layoutArg(data)
  local driver = type(data.driver) == 'string' and trim(data.driver) or ''
  if not name or driver == '' then return end
  local map, boards = editable(pid)
  if not map then return end
  local board = boards[name:lower()]
  if not board then return send(pid, name) end
  -- Not `board and find(...)`: `and` keeps only the first return value.
  local row, i = find(board, driver)
  if not row then return send(pid, name) end
  table.remove(board.laps, i)
  if not M.write(map, boards) then return send(pid, name) end
  local msg = string.format('[RaceManager] %s removed %s %s from the "%s" lap records',
    MP.GetPlayerName(pid) or pid, row.driver, host.fmtLap(row.time), board.name)
  MP.SendChatMessage(-1, msg)
  print(msg)
  send(-1, board.name, true)
end

function M.init(h)
  host = h
  M.host = h
  function RM_onRecordsRequest(pid, raw) M.request(pid, raw) end
  function RM_onRecordsClear(pid, raw) M.clear(pid, raw) end
  function RM_onRecordsRemove(pid, raw) M.remove(pid, raw) end
end

return M
