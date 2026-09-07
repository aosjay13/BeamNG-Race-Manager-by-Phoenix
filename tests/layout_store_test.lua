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

-- TWO MIGRATIONS RUN HERE, one after the other, and this file exercises both:
--
--   1. the server's own data moves under Data/, away from the .lua a release
--      replaces;
--   2. the flat layouts.json inside it splits into one file per map.
--
-- So the legacy file is seeded where an UPGRADING server actually has it -- at
-- the top level, beside main.lua -- and the store it ends up being read from is
-- the copy inside Data/.
local DIR    = 'Resources/Server/RaceManager'
local DATA   = DIR .. '/Data'
local LEGACY = DIR .. '/layouts.json'
local FLAT   = DATA .. '/layouts.json'
local FOLDER = DATA .. '/Race Layout'

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
writeFile(LEGACY, '{"version":1,"layouts":[' ..
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
check(exists(LEGACY),
  'the original is KEPT where it was: a migration that deletes the only copy of '
    .. 'what it is migrating is not a migration')
check(exists(FLAT),
  'and a copy of it landed in Data/ on the way past, which is what the layout '
    .. 'store then split per map')

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

-- ---------------------------------------------------------------------------
-- A FILE THAT DOES NOT PARSE IS LEFT ALONE
-- ---------------------------------------------------------------------------
-- The one that cost a track. The cleanup at the end of a save removes any track
-- file with no layouts in memory, because that is how a map whose last layout
-- was deleted loses its file. A file that fails to PARSE is also absent from
-- memory -- for an entirely different reason -- and used to be deleted by the
-- same rule. So one corrupt file plus one save on an UNRELATED map destroyed a
-- track permanently, and nothing in the save had anything to do with that map.
--
-- Made worse by the write: every save rewrote every map's file, truncating each
-- one before it had bytes to put back, so the corruption this deletes on was
-- also something a save could cause.
removeTree(DIR)
local BS = string.char(92)
os.execute(package.config:sub(1, 1) == BS
  and ('mkdir "' .. FOLDER:gsub('/', BS) .. '" 2>nul')
  or  ('mkdir -p "' .. FOLDER .. '"'))

writeFile(FOLDER .. '/italy.json', '{"version":1,"map":"italy","layouts":[' ..
  '{"name":"Club","map":"italy","width":20,"checkpoints":[' .. gate(10) .. ']}' ..
  ']}')
local CORRUPT = '{"version":1,"map":"west_coast_usa","layouts":[{"name":"Coa'
writeFile(FOLDER .. '/west_coast_usa.json', CORRUPT)

currentMap = 'italy'
boot()
check(#lastLayouts.layouts == 1, 'the good map still loads beside a corrupt one')

-- A save on italy. Nothing here concerns west_coast_usa at all.
RM_onSaveLayout(0, '{"name":"Second","checkpoints":[' .. gate(50) .. ']}')
RM_onRequestLayouts(0)
check(#lastLayouts.layouts == 2, 'the new italy track saves')

check(exists(FOLDER .. '/west_coast_usa.json'),
  'and the corrupt file is STILL THERE: unreadable is not the same fact as '
    .. 'deleted, and a save on another map is no evidence about this one')
local cf = io.open(FOLDER .. '/west_coast_usa.json', 'r')
local ctext = cf:read('*a'); cf:close()
check(ctext == CORRUPT,
  'byte for byte as it was, so whatever is wrong with it is still there to be '
    .. 'looked at rather than half rewritten')

-- ...and repairing it by hand brings the track back, which is the whole point of
-- not having deleted it.
writeFile(FOLDER .. '/west_coast_usa.json',
  '{"version":1,"map":"west_coast_usa","layouts":[' ..
  '{"name":"Coast","map":"west_coast_usa","width":20,"checkpoints":[' .. gate(40) .. ']}' ..
  ']}')
currentMap = 'west_coast_usa'
boot()
check(#lastLayouts.layouts == 1 and lastLayouts.layouts[1].name == 'Coast',
  'a repaired file loads normally: the data was recoverable the whole time')

-- ---------------------------------------------------------------------------
-- A SAVE WRITES THE MAP THAT CHANGED, AND NOT THE OTHERS
-- ---------------------------------------------------------------------------
-- Saving one track used to rewrite the folder: 29 files and 700 KB on a real
-- server, every save, every file stamped the same second so nothing showed which
-- track had actually been touched. The cost is not really the bytes, it is that
-- every unrelated map went through the write path for a change that had nothing
-- to do with it.
local function mtime(path)
  local cmd
  if package.config:sub(1, 1) == BS then
    local q = string.char(39)
    cmd = 'powershell -NoProfile -Command "(Get-Item ' .. q
      .. path:gsub('/', BS) .. q .. ').LastWriteTime.Ticks"'
  else
    cmd = 'stat -c %Y "' .. path .. '" 2>/dev/null'
  end
  local h = io.popen(cmd)
  local out = h and h:read('*a') or ''
  if h then h:close() end
  return (out:gsub('%s', ''))
end

-- One save first, so both files are in the exact form the writer produces.
-- Until then they differ from it by their formatting alone, and a comparison
-- against the bytes on disk quite correctly rewrites them. It converges after
-- one save and stays converged.
currentMap = 'italy'
boot()
RM_onSaveLayout(0, '{"name":"Converge","checkpoints":[' .. gate(60) .. ']}')

-- THE FILE IS STILL A NORMAL TEXT FILE FOR THIS PLATFORM. These are meant to be
-- opened and hand edited, so on Windows they keep CRLF like every other Windows
-- text file. That is why the writer uses text mode on both sides rather than
-- binary: binary would strip the line endings off all 29 files on the first save
-- after an upgrade, for nothing.
local cr = io.open(FOLDER .. '/italy.json', 'rb')
local raw = cr:read('*a'); cr:close()
if package.config:sub(1, 1) == BS then
  check(raw:find(string.char(13) .. string.char(10), 1, true) ~= nil,
    'a written layout file keeps CRLF line endings on Windows, so it opens in '
      .. 'any editor exactly as it did before')
else
  check(raw:find(string.char(13), 1, true) == nil,
    'and carries no carriage returns anywhere else')
end

local before = mtime(FOLDER .. '/west_coast_usa.json')
check(before ~= '', 'the timestamp of the untouched map is readable (got "'
  .. before .. '")')

RM_onSaveLayout(0, '{"name":"Third","checkpoints":[' .. gate(70) .. ']}')

local it = io.open(FOLDER .. '/italy.json', 'r')
local ittext = it:read('*a'); it:close()
check(ittext:find('Third', 1, true), 'the map that changed is written')
check(mtime(FOLDER .. '/west_coast_usa.json') == before,
  'and the map that did not change is not touched at all')

-- No debris. A .tmp left behind means a write that failed, so one sitting there
-- after a clean save would be a lie about the state of the store.
local debris = false
for _, name in ipairs({ 'italy.json.tmp', 'west_coast_usa.json.tmp' }) do
  if exists(FOLDER .. '/' .. name) then debris = true end
end
check(not debris, 'a successful save leaves no .tmp behind')

removeTree(DIR)

if fails == 0 then
  print(string.format('layout_store_test: %d checks, 0 failures', checks))
else
  print(string.format('layout_store_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
