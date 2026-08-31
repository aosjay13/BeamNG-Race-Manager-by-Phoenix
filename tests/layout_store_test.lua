-- Headless test for THE PER-MAP LAYOUT STORE and the migration into it.
--
-- Layouts used to live in one layouts.json: every track ever built on the
-- server, in one blob. To see which maps had races you parsed it, to hand-edit
-- one gate you scrolled past three hundred KB of others, and every save
-- rewrote the lot. They live one file per map now, in a folder.
--
-- THIS FILE IS ABOUT THE MIGRATION, because that is the half that can lose a
-- league's whole season. Three properties, and each of them has a way of being
-- got wrong that looks fine on the day and is a disaster a week later:
--
--   * THE FLAT FILE IS READ EXACTLY ONCE. It has to be read, or an upgrade
--     loses every track. It must never be read AGAIN, or every layout anybody
--     deletes comes back on the next restart -- and it is kept on disk, because
--     a migration that deletes the only copy of the data it is migrating is not
--     a migration.
--
--   * AN EMPTY FOLDER IS NOT A MISSING FOLDER. "No folder" means migrate; "a
--     folder with nothing in it" means somebody deleted their last layout and
--     must not have it handed back. A store that cannot tell those apart
--     resurrects deleted tracks exactly once, on the boot after the deletion.
--
--   * A MAP WHOSE LAST LAYOUT IS DELETED LOSES ITS FILE. Left behind, it is
--     read again next boot -- which is the one bug a per-map store can have
--     that a single file cannot.
--
-- Run from the repo root: lua5.3 tests/layout_store_test.lua

local DIR    = 'Resources/Server/RaceManager'
local FLAT   = DIR .. '/layouts.json'
local FOLDER = DIR .. '/Race Layout'

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end
local function exists(path)
  local f = io.open(path, 'r')
  if f then f:close(); return true end
  return false
end
local function removeTree(path)
  if package.config:sub(1, 1) == '\\' then
    os.execute('rmdir /s /q "' .. path:gsub('/', '\\') .. '" 2>nul')
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end
local function writeFile(path, text)
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end

removeTree(DIR)
os.execute(package.config:sub(1, 1) == '\\'
  and ('mkdir "' .. DIR:gsub('/', '\\') .. '" 2>nul')
  or  ('mkdir -p "' .. DIR .. '"'))

-- Two tracks on two different maps, in the old flat file.
local function gate(x) return string.format('{"x":%d,"y":0,"z":0,"hx":0,"hy":1}', x) end
writeFile(FLAT, '{"version":1,"layouts":[' ..
  '{"name":"Club","map":"italy","width":20,"checkpoints":[' .. gate(10) .. ',' .. gate(20) .. ']},' ..
  '{"name":"Oval","map":"italy","width":20,"checkpoints":[' .. gate(30) .. ']},' ..
  '{"name":"Coast","map":"west_coast_usa","width":20,"checkpoints":[' .. gate(40) .. ']}' ..
  ']}')

local connected = { [0] = 'Admin' }
local lastLayouts, currentMap = nil, 'italy'
MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function () return { [0] = 'Admin' } end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Layouts' then lastLayouts = payload end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
  RemoveVehicle = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/' .. currentMap .. '/info.json' end,
}
Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

-- A fresh server, reading the code from scratch. Called again below to stand in
-- for a restart, which is the only way to prove anything about persistence.
local function boot()
  lastLayouts = nil
  dofile('server/RaceManager/main.lua')
  onInit()
  RM_onLogin(0, '{"password":"phoenix"}')
  RM_onPlayerJoin(0)
  RM_onRequestLayouts(0)
end

-- ---------------------------------------------------------------------------
-- The migration
-- ---------------------------------------------------------------------------
boot()
check(#lastLayouts.layouts == 2,
  'the two italy tracks come through the migration (got '
    .. #lastLayouts.layouts .. ')')
check(exists(FOLDER .. '/italy.json'), 'italy has a file of its own')
check(exists(FOLDER .. '/west_coast_usa.json'),
  'and so does the map the server is not even on: a migration moves the whole '
    .. 'store, not the part that happens to be loaded')
check(exists(FLAT),
  'the flat file is KEPT: a migration that deletes the only copy of what it is '
    .. 'migrating is not a migration')

-- ...and the file is named after the map, which is the whole point: the track
-- list is a directory listing.
local f = io.open(FOLDER .. '/italy.json', 'r')
local text = f:read('*a'); f:close()
check(text:find('Club', 1, true) and text:find('Oval', 1, true),
  'both italy tracks are in the italy file')
check(not text:find('Coast', 1, true), 'and the west coast track is not')

-- ---------------------------------------------------------------------------
-- The flat file is never read again
-- ---------------------------------------------------------------------------
-- Rewritten with a track that was never in the folder. If the store still reads
-- it, that track appears -- and so would every layout anybody ever deleted.
writeFile(FLAT, '{"version":1,"layouts":[' ..
  '{"name":"Ghost","map":"italy","width":20,"checkpoints":[' .. gate(99) .. ']}' ..
  ']}')
boot()
check(#lastLayouts.layouts == 2,
  'the flat file is not read a second time (got ' .. #lastLayouts.layouts .. ')')
local ghost = false
for _, l in ipairs(lastLayouts.layouts) do if l.name == 'Ghost' then ghost = true end end
check(not ghost, 'so a track only the old file knows about never comes back')

-- ---------------------------------------------------------------------------
-- Deleting the last layout on a map removes its file
-- ---------------------------------------------------------------------------
RM_onDeleteLayout(0, '{"name":"Club"}')
RM_onDeleteLayout(0, '{"name":"Oval"}')
RM_onRequestLayouts(0)
check(#lastLayouts.layouts == 0, 'both italy tracks are deleted')
check(not exists(FOLDER .. '/italy.json'),
  'and italy.json goes with them, or the next boot reads it and hands them back')
check(exists(FOLDER .. '/west_coast_usa.json'), 'the other map is untouched')

boot()
check(#lastLayouts.layouts == 0, 'and they stay deleted across a restart')

currentMap = 'west_coast_usa'
boot()
check(#lastLayouts.layouts == 1,
  'the surviving map still loads from the folder (got '
    .. #lastLayouts.layouts .. ')')
check(lastLayouts.layouts[1].name == 'Coast', 'and it is the right track')

-- ---------------------------------------------------------------------------
-- AN EMPTY FOLDER IS NOT A MISSING ONE
-- ---------------------------------------------------------------------------
-- The state that separates the two answers: every layout deleted, so the folder
-- exists and holds nothing, while the flat file is still on disk with tracks in
-- it. A store that reads "no files" as "not migrated yet" reloads the flat file
-- here and hands back every track the admin just deleted -- once, on the boot
-- after the deletion, which is the hardest kind of bug to catch on a race night.
--
-- This is the check that has to be driven all the way to an EMPTY folder. With
-- one map's file still present the naive implementation passes, because it never
-- sees a count of zero.
RM_onDeleteLayout(0, '{"name":"Coast"}')
RM_onRequestLayouts(0)
check(#lastLayouts.layouts == 0, 'the last track on the last map is deleted')
local left = 0
for _, n in ipairs({ 'italy', 'west_coast_usa' }) do
  if exists(FOLDER .. '/' .. n .. '.json') then left = left + 1 end
end
check(left == 0, 'and the folder is now empty')
check(exists(FLAT), 'while the flat file still sits there full of tracks')

boot()
check(#lastLayouts.layouts == 0,
  'an EMPTY folder still means "migrated", not "migrate me": nothing comes back '
    .. '(got ' .. #lastLayouts.layouts .. ')')
currentMap = 'italy'
boot()
check(#lastLayouts.layouts == 0, 'on any map')

-- ---------------------------------------------------------------------------
-- A hand-written file needs no map on every entry
-- ---------------------------------------------------------------------------
-- The point of a file named after the map is not repeating the map inside it.
-- An entry that DOES carry one keeps it, so moving a file between folders does
-- not silently re-home the tracks in it.
writeFile(FOLDER .. '/small_island.json', '{"version":1,"layouts":[' ..
  '{"name":"Handwritten","width":20,"checkpoints":[' .. gate(7) .. ']},' ..
  '{"name":"Explicit","map":"italy","width":20,"checkpoints":[' .. gate(8) .. ']}' ..
  ']}')
currentMap = 'small_island'
boot()
check(#lastLayouts.layouts == 1,
  'an entry with no map takes it from the filename (got '
    .. #lastLayouts.layouts .. ')')
check(lastLayouts.layouts[1].name == 'Handwritten', 'and it is the right one')

currentMap = 'italy'
boot()
check(#lastLayouts.layouts == 1,
  'while an entry that names its own map keeps it, wherever the file is')
check(lastLayouts.layouts[1].name == 'Explicit', 'and shows up under that map')
check(not exists(FOLDER .. '/italy.json'),
  '...without an italy.json existing at all: the map on the entry decides where '
    .. 'a track belongs, and the filename is for people')

removeTree(DIR)

if fails == 0 then
  print(string.format('layout_store_test: %d checks, 0 failures', checks))
else
  print(string.format('layout_store_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
