-- Headless test for MAP SWITCHING and MAP VOTES (server/RaceManager/maps.lua),
-- run against the real server plugin in Lua 5.3, the same as BeamMP.
-- Run from the repo root: lua5.3 tests/maps_test.lua
--
-- Builds a scratch server folder with real zip files in it, then switches maps
-- the way an admin and a lobby would. Nothing here starts a process: the
-- module's process calls are stood in for through maps.sys.

local connected = {}
local sent = {}          -- [event] = list of { target, payload }
local dropped = {}       -- [pid] = kick reason
local timers, timerCreates = {}, 0
local hostedMap = '/levels/erxmp_bullet/info.json'

for i = 1, 5 do connected[i] = 'Driver' .. i end

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    sent[event] = sent[event] or {}
    table.insert(sent[event], { target = target, payload = payload })
  end,
  DropPlayer = function (pid, reason) dropped[pid] = reason end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name)
    timers[name] = true
    if name == 'RM_MapTick' then timerCreates = timerCreates + 1 end
  end,
  CancelEventTimer = function (name) timers[name] = nil end,
  Settings = { Map = 0 },
  Get = function () return hostedMap end,
  Set = function (_, value) hostedMap = value end,
}

Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

dofile('server/RaceManager/main.lua')
local maps = require('maps')
local CFG = maps.host.CFG
local realBusy = maps.host.busy
local function underWay(on)
  maps.host.busy = on and function () return 'a session is running' end or realBusy
end

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local function last(event, target)
  local list = sent[event] or {}
  for i = #list, 1, -1 do
    if target == nil or list[i].target == target then return list[i].payload end
  end
end

local function tick(n)
  for _ = 1, n or 1 do RM_MapTick() end
end

-- ---------------------------------------------------------------------------
-- A scratch server folder
-- ---------------------------------------------------------------------------
local IS_WINDOWS = package.config:sub(1, 1) == '\\'
local base = (os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp'):gsub('\\', '/')
local root = base .. '/rm_maps_test_' .. os.time()

local function mkdir(p)
  if IS_WINDOWS then os.execute('mkdir "' .. p:gsub('/', '\\') .. '" 2>nul')
  else os.execute('mkdir -p "' .. p .. '"') end
end

local function write(p, s)
  local f = assert(io.open(p, 'wb'))
  f:write(s)
  f:close()
end

local function read(p)
  local f = io.open(p, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function exists(p) return read(p) ~= nil end

-- A zip of empty stored entries. Enough for a central-directory reader, which
-- is all the module is.
local function makeZip(path, names, opts)
  opts = opts or {}
  local body, cd, offset = {}, {}, 0
  for _, name in ipairs(names) do
    local lh = string.pack('<I4I2I2I2I2I2I4I4I4I2I2', 0x04034b50, 20, 0, 0, 0, 0, 0, 0, 0, #name, 0) .. name
    body[#body + 1] = lh
    cd[#cd + 1] = string.pack('<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4',
      0x02014b50, 20, 20, 0, 0, 0, 0, 0, 0, 0, #name, 0, 0, 0, 0, 0, offset) .. name
    offset = offset + #lh
  end
  local cdData = table.concat(cd)
  local tail
  if opts.zip64 then
    tail = string.pack('<I4I8I2I2I4I4I8I8I8I8', 0x06064b50, 44, 45, 45, 0, 0,
        #names, #names, #cdData, offset)
      .. string.pack('<I4I4I8I4', 0x07064b50, 0, offset + #cdData, 1)
      .. string.pack('<I4I2I2I2I2I4I4I2', 0x06054b50, 0, 0, 0xFFFF, 0xFFFF,
        0xFFFFFFFF, 0xFFFFFFFF, 0)
  else
    local comment = opts.comment or ''
    tail = string.pack('<I4I2I2I2I2I4I4I2', 0x06054b50, 0, 0, #names, #names,
      #cdData, offset, #comment) .. comment
  end
  write(path, table.concat(body) .. cdData .. tail)
end

local CONFIG = table.concat({
  '# This is the BeamMP-Server config file.',
  '[General]',
  'Port = 30814',
  'AuthKey = "secret"',
  'Name = "Map = trap"',
  'Map = "/levels/erxmp_bullet/info.json"',
  'ResourceFolder = "Resources"',
  '',
  '[Misc]',
  'ImScaredOfUpdates = false',
  '',
}, '\r\n')

mkdir(root .. '/custom_maps')
mkdir(root .. '/Resources/Client')
write(root .. '/ServerConfig.toml', CONFIG)
makeZip(root .. '/Resources/Client/bullets erx.zip',
  { 'levels/erxmp_bullet/info.json', 'levels/erxmp_bullet/main.level.json' })
makeZip(root .. '/Resources/Client/cars.zip', { 'vehicles/buggy/buggy.jbeam' })
makeZip(root .. '/custom_maps/crandon.zip', { 'levels/crandon/info.json' },
  { comment = 'a zip comment with PK in it' })
makeZip(root .. '/custom_maps/pack.zip',
  { 'Levels/PackA/info.json', 'levels/packb/info.json', 'levels/packb/art/x.dds' },
  { zip64 = true })
makeZip(root .. '/custom_maps/italy_mod.zip', { 'levels/italy/info.json' })
write(root .. '/custom_maps/notazip.zip', 'this is not a zip')

maps.paths.root = root

local spawned, exited, probed = {}, 0, 0
maps.sys = {
  popen = function () return nil end,
  execute = function (cmd) spawned[#spawned + 1] = cmd; return true end,
  exit = function () exited = exited + 1 end,
}
local realProbe = maps.probe
maps.probe = function ()
  probed = probed + 1
  return { pid = 4242, exe = 'C:\\BeamNG Server\\BeamMP-Server.exe', name = 'BeamMP-Server.exe',
    cmd = '"C:\\BeamNG Server\\BeamMP-Server.exe"', cwd = 'C:\\BeamNG Server',
    parent = 'explorer.exe', args = {}, mt = {} }
end

-- ---------------------------------------------------------------------------
-- 1. Nothing global at file scope
-- ---------------------------------------------------------------------------
-- BeamMP runs every .lua in the plugin folder on its own, and maps sorts after
-- main. A handler defined at load would be replaced by an uninitialised copy.
do
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile('server/RaceManager/maps.lua', 't', env))
  chunk()
  local leaked = {}
  for k in pairs(env) do leaked[#leaked + 1] = k end
  check(#leaked == 0, 'maps.lua defines no globals when BeamMP runs it on its own (found: '
    .. table.concat(leaked, ', ') .. ')')
  check(type(RM_onMapSwitch) == 'function' and type(RM_onMapVoteStart) == 'function',
    'and main.lua installed the handlers through init')
end

-- ---------------------------------------------------------------------------
-- 2. Reading zips
-- ---------------------------------------------------------------------------
local function levels(file) return table.concat(maps.zipLevels(file) or {}, ',') end
check(levels(root .. '/Resources/Client/bullets erx.zip') == 'erxmp_bullet',
  'a map zip names its level from levels/<name>/info.json')
check(levels(root .. '/Resources/Client/cars.zip') == '', 'a vehicle zip has no level')
check(levels(root .. '/custom_maps/crandon.zip') == 'crandon', 'a zip comment does not hide the directory')
check(levels(root .. '/custom_maps/pack.zip') == 'PackA,packb',
  'a ZIP64 archive with two levels, and the folder keeps its case')
check(levels(root .. '/custom_maps/notazip.zip') == '', 'a broken zip is no map and no crash')

-- ---------------------------------------------------------------------------
-- 3. Rewriting the config
-- ---------------------------------------------------------------------------
do
  local out = maps.rewriteMap(CONFIG, '/levels/crandon/info.json')
  check(out ~= nil and out:find('Map = "/levels/crandon/info.json"\r\n', 1, true) ~= nil,
    'the Map line takes the new value')
  check(out and out:gsub('/levels/crandon/', '/levels/erxmp_bullet/', 1) == CONFIG,
    'and every other byte is untouched, CRLF included')
  check(out and out:find('Name = "Map = trap"', 1, true) ~= nil,
    'a value that merely contains "Map =" is not the Map line')
  check(maps.rewriteMap("Map = '/levels/x/info.json'\n", '/levels/y/info.json')
    == 'Map = "/levels/y/info.json"\n', 'a single-quoted Map line is rewritten too')
  check(maps.rewriteMap('[General]\nPort = 1\n', '/levels/y/info.json') == nil,
    'no Map line is an error, not a guess')
end

-- ---------------------------------------------------------------------------
-- 4. The catalog
-- ---------------------------------------------------------------------------
local list, byName = maps.catalog()
check(byName.erxmp_bullet and byName.erxmp_bullet.current and byName.erxmp_bullet.where == 'client',
  'the running map is found in Resources/Client')
check(byName.crandon and byName.crandon.where == 'store' and byName.crandon.zip == 'crandon.zip',
  'a stored map is offered with its zip')
check(byName.packa and byName.packb and byName.packa.zip == 'pack.zip', 'both levels of a pack are offered')
check(byName.italy and byName.italy.zip == 'italy_mod.zip',
  'a map zip wins a level name over the stock level')
check(byName.gridmap_v2 and byName.gridmap_v2.where == 'stock', 'stock levels are offered')
check(byName.gridmap == nil, 'the old gridmap, which has no level any more, is not')
check(list[#list].where == 'stock' and list[1].where ~= 'stock', 'custom maps list first')

-- ---------------------------------------------------------------------------
-- 5. Who may switch
-- ---------------------------------------------------------------------------
local ADMIN, MOD, DRIVER = 1, 2, 3
RM_onLogin(ADMIN, '{"password":"phoenix"}')
RM_onChangePassword(ADMIN, '{"password":"tuesday","role":"moderator"}')
RM_onLogin(MOD, '{"password":"tuesday"}')

RM_onMapRequest(DRIVER, '')
local st = last('RM_Maps', DRIVER)
check(st and st.list and #st.list > 10, 'anyone may see the list: a driver picks from it to call a vote')
RM_onMapRequest(DRIVER, '{"list":false}')
st = last('RM_Maps', DRIVER)
check(st and st.list == nil and st.voting == true, 'a joining client gets the state without the list')

RM_onMapSwitch(DRIVER, '{"map":"crandon"}')
check(maps.state.phase == 'idle', 'a driver cannot switch the map outright')

RM_onMapSwitch(ADMIN, '{"map":"erxmp_bullet"}')
check(maps.state.phase == 'idle' and last('RM_Maps', ADMIN).error:find('already the map'),
  'switching to the map already running is refused, and says why')

RM_onMapSwitch(ADMIN, '{"map":"nowhere"}')
check(maps.state.phase == 'idle', 'an unknown map is refused')

-- A session under way blocks it: the restart would end the race.
check(realBusy() == nil, 'nothing is under way on a fresh server')
underWay(true)
RM_onMapSwitch(ADMIN, '{"map":"crandon"}')
check(maps.state.phase == 'idle' and last('RM_Maps', ADMIN).error:find('session'),
  'not while a session is running')
underWay(false)

-- ---------------------------------------------------------------------------
-- 6. A moderator switches, and stops it
-- ---------------------------------------------------------------------------
maps.sys.exit = nil  -- manual: stage it and stop there
RM_onMapSwitch(MOD, '{"map":"crandon"}')
check(maps.state.phase == 'countdown' and maps.state.left == maps.COUNTDOWN,
  'a moderator starts the countdown: running the night is their job')
check(maps.state.method == 'manual', 'with no exit() the switch can only be staged')
local b = last('RM_Maps', -1)
check(b and b.phase == 'countdown' and b.targetLabel == 'crandon', 'everyone is told it is coming')
tick(3)
RM_onMapCancel(MOD)
check(maps.state.phase == 'idle' and not timers.RM_MapTick, 'Stop during the countdown puts everything back')
check(next(dropped) == nil, 'and nobody was disconnected')

-- ---------------------------------------------------------------------------
-- 6a. Display names
-- ---------------------------------------------------------------------------
do
  local NAMES = root .. '/Resources/Server/RaceManager/Data/mapNames.json'
  local function entry(name)
    for _, e in ipairs(last('RM_Maps', -1).list or {}) do
      if e.name == name then return e end
    end
  end

  RM_onMapRename(DRIVER, '{"map":"crandon","label":"Crandon"}')
  check(not exists(NAMES), 'a driver cannot rename a map')

  RM_onMapRename(MOD, '{"map":"crandon","label":"  Crandon   International\tRaceway "}')
  local e = entry('crandon')
  check(e and e.label == 'Crandon International Raceway' and e.custom == true and e.default == 'crandon',
    'a moderator names a map, tidied, and everyone gets the new list')
  check((read(NAMES) or ''):find('"crandon": "Crandon International Raceway"', 1, true) ~= nil,
    'it is kept in Data/mapNames.json under the level name')
  check(maps.labelFor('CRANDON') == 'Crandon International Raceway', 'looked up in any case')
  check(exists(root .. '/custom_maps/crandon.zip') and read(root .. '/ServerConfig.toml') == CONFIG,
    'display only: no zip moved and the config is untouched')

  RM_onMapRename(ADMIN, '{"map":"erxmp_bullet","label":"Bullet"}')
  RM_onMapRequest(DRIVER, '{"list":false}')
  check(last('RM_Maps', DRIVER).currentLabel == 'Bullet', 'the current map\'s name reaches every client')
  check(maps.labelFor('gridmap_v2') == 'Gridmap v2', 'an unnamed stock level keeps its own name')

  RM_onMapRename(ADMIN, '{"map":"gridmap_v2","label":"' .. string.rep('x', 60) .. '"}')
  check(#entry('gridmap_v2').label == maps.MAX_LABEL, 'a long name is cut to ' .. maps.MAX_LABEL)
  check(maps.cleanLabel(string.rep('é', 60)) == string.rep('é', maps.MAX_LABEL),
    'a long name is cut on a character, never inside one: RM_Maps must encode')
  check(maps.cleanLabel('ok\255name') == 'okname', 'a byte that is not UTF-8 is dropped')
  RM_onMapRename(ADMIN, '{"map":"gridmap_v2","label":"Gridmap v2"}')
  check(entry('gridmap_v2').custom == nil, 'naming a map its own default name clears it')
  RM_onMapRename(ADMIN, '{"map":"nowhere","label":"X"}')
  check(last('RM_Maps', ADMIN).error:find('No map called'), 'an unknown map is refused')

  -- By hand, keyed in any case.
  write(NAMES, '{\n  "PackA": "Pack Alpha",\n  "crandon": "Crandon"\n}\n')
  RM_onMapRequest(DRIVER, '')
  local list = last('RM_Maps', DRIVER).list
  local byLevel = {}
  for _, m in ipairs(list) do byLevel[m.name] = m end
  check(byLevel.PackA.label == 'Pack Alpha' and byLevel.crandon.label == 'Crandon',
    'a hand edit shows the next time the list is built')
  check(byLevel.erxmp_bullet.label == 'erxmp_bullet', 'and a name taken out of the file is gone')

  write(NAMES, '{ "crandon": oops')
  RM_onMapRename(ADMIN, '{"map":"crandon","label":"Again"}')
  check(read(NAMES) == '{ "crandon": oops', 'a file that does not parse is never written over')
  check(last('RM_Maps', ADMIN).error:find('does not parse'), 'and the admin is told why')

  write(NAMES, '{"crandon": "Crandon"}')
  RM_onMapRename(ADMIN, '{"map":"crandon","label":""}')
  check(not exists(NAMES), 'clearing the last name removes the file')
  check(maps.labelFor('crandon') == 'crandon', 'and the level name is back')
end

-- ---------------------------------------------------------------------------
-- 7. The switch itself (manual)
-- ---------------------------------------------------------------------------
RM_onMapSwitch(ADMIN, '{"map":"crandon"}')
tick(maps.COUNTDOWN)
check(maps.state.phase == 'kicking' and dropped[DRIVER] and dropped[ADMIN],
  'at zero everyone is disconnected, admins included')
check(RM_Map_onPlayerAuth() ~= nil, 'and joining is refused while the files move')
tick(maps.SETTLE)
check(maps.state.phase == 'staged', 'manual: staged and waiting for a restart')
check(RM_Map_onPlayerAuth() == nil, 'a staged switch lets people back in')
check(exists(root .. '/Resources/Client/crandon.zip') and not exists(root .. '/custom_maps/crandon.zip'),
  'the new map zip moved into Resources/Client')
check(exists(root .. '/custom_maps/bullets erx.zip') and not exists(root .. '/Resources/Client/bullets erx.zip'),
  'the old one moved out to custom_maps')
check(exists(root .. '/Resources/Client/cars.zip'), 'vehicle mods stay where they are')
check(read(root .. '/ServerConfig.toml') == CONFIG:gsub('erxmp_bullet', 'crandon'),
  'ServerConfig.toml says crandon, and nothing else changed')
check(not exists(root .. '/ServerConfig.toml.rm-tmp'), 'no temp file left behind')
check(hostedMap == '/levels/crandon/info.json', 'the running server was told too')

-- The restart, simulated: a new plugin boot on the new map.
maps.state = { phase = 'idle' }
maps.ticking = false
dropped = {}
RM_Map_onPlayerAuth()
maps.warm()
check(maps.last and maps.last.ok and maps.last.to == 'crandon', 'after the restart the switch reads as done')
check(not exists(root .. '/Resources/Server/RaceManager/Data/mapSwitch.json'), 'and the record is cleared')

-- ---------------------------------------------------------------------------
-- 8. A failed move puts everything back
-- ---------------------------------------------------------------------------
maps.sys.exit = function () exited = exited + 1 end
RM_onMapSwitch(ADMIN, '{"map":"packb"}')
os.remove(root .. '/custom_maps/pack.zip')   -- gone between the pick and the move
tick(maps.COUNTDOWN + maps.SETTLE)
check(maps.state.phase == 'idle' and maps.lastError and maps.lastError:find('missing'),
  'a missing zip fails the switch and says so')
check(exists(root .. '/Resources/Client/crandon.zip') and not exists(root .. '/custom_maps/crandon.zip'),
  'and the running map zip is back in Resources/Client')
check(read(root .. '/ServerConfig.toml'):find('crandon', 1, true), 'and the config was never touched')
check(exited == 0, 'and the server keeps running')
makeZip(root .. '/custom_maps/pack.zip', { 'Levels/PackA/info.json', 'levels/packb/info.json' })

-- ---------------------------------------------------------------------------
-- 9. Relaunch: the helper is started, then the server stops
-- ---------------------------------------------------------------------------
dropped = {}
spawned = {}
RM_onMapSwitch(ADMIN, '{"map":"gridmap_v2"}')
check(maps.state.method == 'relaunch', 'auto, and not under the Management Tool: relaunch')
tick(maps.COUNTDOWN + maps.SETTLE)
check(exited == 1, 'exit() is called once the files are in place')
check(#spawned == 1 and spawned[1]:find('relaunch', 1, true), 'after the helper was started')
local script = read(root .. '/Resources/Server/RaceManager/Data/'
  .. (IS_WINDOWS and 'relaunch.cmd' or 'relaunch.sh')) or ''
check(script:find('4242', 1, true) ~= nil, 'the helper waits on this server\'s PID')
check(script:find(':30814 ', 1, true) ~= nil, 'and on its UDP port: a new server that cannot bind it shuts down')
if IS_WINDOWS then
  -- `start` hands the old server's sockets to the helper and on to the new
  -- server, which then cannot bind UDP. This was the live failure.
  check(spawned[1]:find('Start-Process', 1, true) ~= nil and not spawned[1]:find('^start '),
    'the helper is launched through Start-Process, which inherits no sockets')
  check(not script:find('\n[^\n%%]*[^\\]find ', 1) and script:find('System32\\find.exe', 1, true) ~= nil,
    'and calls find, tasklist and netstat by full path, not whatever is first on PATH')
end
check(exists(root .. '/custom_maps/crandon.zip') and not exists(root .. '/Resources/Client/crandon.zip'),
  'a stock map needs no zip, and the custom one went back to custom_maps')
check(read(root .. '/ServerConfig.toml'):find('Map = "/levels/gridmap_v2/info.json"', 1, true),
  'the config points at the stock level')
maps.state = { phase = 'idle' }
maps.ticking = false
maps.warm()
check(not exists(root .. '/Resources/Server/RaceManager/Data/relaunch.cmd')
  and not exists(root .. '/Resources/Server/RaceManager/Data/relaunch.sh'),
  'the next boot deletes the helper')

-- ---------------------------------------------------------------------------
-- 10. Choosing the restart
-- ---------------------------------------------------------------------------
do
  local tool = { parent = 'BeamMP.Server.Management.Tool.v3.1.exe', mtconfig = 'True', mt = {} }
  local m = maps.resolveRestart(tool)
  check(m == 'relaunch', 'the tool with its config check never saved (off): relaunch')
  tool.mt = { checkRestartCfgTimer = 'True', checkRestartCfgTimerSeconds = '20' }
  local m2, grace = maps.resolveRestart(tool)
  check(m2 == 'watch' and grace == 35, 'the tool with its check on: watch, and wait its interval plus 15s')
  local m3, grace3 = maps.resolveRestart({ parent = 'BeamMP.Server.Management.Tool.v3.1.exe', mt = {} })
  check(m3 == 'watch' and grace3 == CFG.mapRestartGrace, 'the tool with unreadable settings: watch, for the configured grace')
  CFG.mapRestart = 'exit'
  check(maps.resolveRestart({ mt = {} }) == 'exit', 'a service manager: exit')
  CFG.mapRestart = 'auto'
  local exitFn = maps.sys.exit
  maps.sys.exit = nil
  check(maps.resolveRestart({ parent = 'explorer.exe', mt = {} }) == 'manual',
    'a BeamMP with no exit() cannot relaunch: manual')
  check(maps.resolveRestart({ parent = 'BeamMP.Server.Management.Tool.v3.1.exe', mt = {} }) == 'watch',
    'but the tool can still restart it: the config watch needs no exit()')
  maps.sys.exit = exitFn
end

-- Watch: nothing restarts it, so it restarts itself once the grace is up.
do
  exited, spawned = 0, {}
  maps.probe = function ()
    return { pid = 4242, parent = 'BeamMP.Server.Management.Tool.v3.1.exe', mtconfig = 'True',
      mt = { checkRestartCfgTimer = 'True', checkRestartCfgTimerSeconds = '10' },
      cwd = 'C:\\BeamNG Server', args = {} }
  end
  RM_onMapSwitch(ADMIN, '{"map":"crandon"}')
  tick(maps.COUNTDOWN + maps.SETTLE)
  check(maps.state.phase == 'restarting' and exited == 0, 'watch: the tool gets its chance first')
  tick(maps.state.grace - 1)
  check(exited == 0, 'the whole of it')
  tick(1)
  check(exited == 1 and #spawned == 1, 'then Race Manager restarts the server itself')
  maps.state = { phase = 'idle' }
  maps.ticking = false
  maps.warm()
end

-- ---------------------------------------------------------------------------
-- 11. Voting
-- ---------------------------------------------------------------------------
maps.probe = function () return { pid = 4242, parent = 'explorer.exe', args = {}, mt = {} } end
maps.sys.exit = nil          -- votes that pass stage a manual switch here
local function resetSwitch()
  maps.state = { phase = 'idle' }
  maps.ticking = false
  dropped = {}
end

CFG.mapVotePercent = 60      -- 5 connected: 3 yes needed
local creates = timerCreates
RM_onMapVoteStart(DRIVER, '{"map":"packa"}')
check(maps.vote and maps.vote.target.name == 'PackA', 'a driver calls a vote')
local v = last('RM_Maps', -1).vote
check(v and v.yes == 1 and v.needed == 3 and v.total == 5, 'the caller is a yes; 3 of 5 are needed at 60%')
RM_onMapVoteStart(4, '{"map":"italy"}')
check(maps.vote.target.name == 'PackA', 'one vote at a time')
RM_onMapVote(4, '{"yes":true}')
check(maps.vote ~= nil, 'two of five is not enough')
RM_onMapVote(5, '{"yes":true}')
check(maps.vote == nil and maps.state.phase == 'countdown' and maps.state.target.name == 'PackA',
  'three of five passes, and the countdown starts at once')
check(timerCreates == creates + 1, 'one timer for the vote and the switch that followed, not two')
RM_onMapCancel(ADMIN)
check(maps.state.phase == 'idle', 'an admin can still stop the countdown a vote started')

-- Not voting counts as no: it fails the moment it cannot pass.
check(hostedMap == '/levels/crandon/info.json', 'the lobby is on crandon for these votes')
RM_onMapVoteStart(ADMIN, '{"map":"italy"}')
check(maps.vote ~= nil, 'an admin calls a vote')
RM_onMapVote(2, '{"yes":false}')
RM_onMapVote(3, '{"yes":false}')
check(maps.vote ~= nil, 'one yes, two no, two undecided: it could still pass')
RM_onMapVote(4, '{"yes":false}')
check(maps.vote == nil and maps.state.phase == 'idle', 'three no of five: it cannot reach 3 yes, so it fails early')

-- An admin-called failure sets no cooldown; a driver's does.
RM_onMapVoteStart(DRIVER, '{"map":"italy"}')
tick(maps.VOTE_SECONDS)
check(maps.vote == nil and maps.state.phase == 'idle', 'a vote nobody joins fails when time is up')
RM_onMapVoteStart(4, '{"map":"italy"}')
check(maps.vote == nil and last('RM_Maps', 4).error:find('seconds'),
  'a driver waits out the cooldown after a failed vote')
check(last('RM_Notice', 4) ~= nil, 'and is told on the HUD, not just in chat')
RM_onMapVoteStart(ADMIN, '{"map":"italy"}')
check(maps.vote ~= nil, 'an admin does not wait')
RM_onMapVoteCancel(DRIVER)
check(maps.vote ~= nil, 'a driver cannot stop a vote')
RM_onMapVoteCancel(MOD)
check(maps.vote == nil, 'a moderator can')
maps.voteCooldownUntil = 0

-- Locking.
RM_onMapVoteConfig(DRIVER, '{"enabled":false}')
check(CFG.mapVoting == true, 'a driver cannot lock voting')
RM_onMapVoteConfig(MOD, '{"enabled":false}')
check(CFG.mapVoting == false and last('RM_Maps', -1).voting == false, 'a race director locks voting')
RM_onMapVoteStart(DRIVER, '{"map":"italy"}')
check(maps.vote == nil and last('RM_Maps', DRIVER).error:find('locked'), 'a driver cannot call one while locked')
RM_onMapVoteStart(MOD, '{"map":"italy"}')
check(maps.vote ~= nil, 'an admin still can')
RM_onMapVoteCancel(MOD)
RM_onMapVoteConfig(ADMIN, '{"enabled":true,"percent":80}')
check(CFG.mapVoting == true and CFG.mapVotePercent == 80, 'unlocked, and the pass mark moved')
RM_onMapVoteStart(DRIVER, '{"map":"italy"}')
RM_onMapVoteConfig(ADMIN, '{"enabled":false}')
check(maps.vote == nil, "locking stops a driver's vote already running")
RM_onMapVoteConfig(ADMIN, '{"enabled":true,"percent":0}')
check(CFG.mapVotePercent == 80, 'a pass mark of 0% is refused')
RM_onMapVoteConfig(ADMIN, '{"percent":150}')
check(CFG.mapVotePercent == 80, 'and so is 150%')
CFG.mapVotePercent = 60

-- An admin switches over a vote.
RM_onMapVoteStart(DRIVER, '{"map":"italy"}')
RM_onMapSwitch(ADMIN, '{"map":"packb"}')
check(maps.vote == nil and maps.state.phase == 'countdown' and maps.state.target.name == 'packb',
  'an admin switches at will, over a vote in progress')
resetSwitch()

-- Leaving shrinks the lobby; a lone driver passes on their own.
local saved = connected
connected = { [3] = 'Driver3' }
RM_onMapVoteStart(DRIVER, '{"map":"italy"}')
check(maps.vote == nil and maps.state.phase == 'countdown', 'alone on the server, calling a vote passes it')
resetSwitch()
connected = saved

RM_onMapVoteStart(DRIVER, '{"map":"italy"}')
RM_onMapVote(4, '{"yes":true}')
connected[5] = nil; connected[2] = nil; RM_Map_onPlayerDisconnect(5); RM_Map_onPlayerDisconnect(2)
tick(1)
check(maps.vote == nil and maps.state.phase == 'countdown', 'two of three after two leave: passes on the next tick')
resetSwitch()
connected[5] = 'Driver5'; connected[2] = 'Driver2'

underWay(true)
RM_onMapVoteStart(DRIVER, '{"map":"italy"}')
check(maps.vote == nil, 'no vote while a session is running')
underWay(false)

-- ---------------------------------------------------------------------------
-- 12. The real probe does not throw without a shell
-- ---------------------------------------------------------------------------
maps.sys.popen = function () error('no shell here') end
local ok, info = pcall(realProbe)
check(ok and type(info) == 'table' and info.pid == nil, 'a probe that cannot run returns an empty answer')

-- ---------------------------------------------------------------------------
-- Clean up
-- ---------------------------------------------------------------------------
if IS_WINDOWS then os.execute('rmdir /s /q "' .. root:gsub('/', '\\') .. '"')
else os.execute('rm -rf "' .. root .. '"') end

print(string.format('maps_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
