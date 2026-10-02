-- Race Manager: MAP SWITCHING, as its own module.
--
-- BeamMP reads its map and hashes Resources/Client once, at startup, so a new
-- map means three things: move the map zips, rewrite the Map line in
-- ServerConfig.toml, and restart. This file does all three.
--
-- NOTHING GLOBAL AT FILE SCOPE. BeamMP runs every .lua in the plugin folder on
-- its own, alphabetically, and "maps" sorts AFTER "main". A handler defined at
-- file scope would be redefined by that second, never-initialised copy on top
-- of the one main.lua set up, and every map command would hit nil upvalues.
-- So the handlers are installed by init(). derby.lua and drag.lua get away
-- with file-scope handlers only because they sort before main.lua.
--
-- THE MAP STORE IS THE MANAGEMENT TOOL'S: inactive map zips wait in
-- custom_maps/ beside the executable, the active one sits in Resources/Client.
-- Using the same folders keeps the tool's own map list right after a switch.
--
-- VOTING lets a driver call a switch; it passes at CFG.mapVotePercent of
-- everyone connected. Admins switch at will, call votes, stop them, and lock
-- voting with CFG.mapVoting.
--
-- RESTART is CFG.mapRestart:
--   auto      under the Management Tool: watch. Anything else: relaunch.
--   watch     let the tool's "Check for config update and restart" do it
--   relaunch  start a helper that waits for this process to end and starts
--             the server again, then exit()
--   exit      exit() and let a service manager or panel start it again
--   manual    stage the switch and wait for somebody to restart by hand

local M = {}
local host

local IS_WINDOWS = package.config:sub(1, 1) == '\\'

-- Relative to the server's working directory, which is where BeamMP keeps
-- ServerConfig.toml. Tests point `root` at a scratch folder.
M.paths = {
  root   = '',
  config = 'ServerConfig.toml',
  store  = 'custom_maps',
  data   = 'Resources/Server/RaceManager/Data',
}

-- Process control, as a table so the tests can stand in for it. `exit` is
-- BeamMP's graceful shutdown (3.1+); os.exit would skip the server's own.
M.sys = {
  popen   = io.popen,
  execute = os.execute,
  exit    = rawget(_G, 'exit'),
}

-- Seconds of warning before everyone is disconnected.
M.COUNTDOWN = 10
-- Seconds between the kick and the file work, so the server has closed any
-- download streams that would hold a zip open and block the move.
M.SETTLE = 2

-- Stock levels, from content/levels of BeamNG 0.39. Level names are the ones
-- the Management Tool writes, so a map chosen in either place matches the
-- per-map layout files. `gridmap` is left out: its zip has no level any more.
M.STOCK = {
  { 'automation_test_track', 'Automation Test Track' },
  { 'cliff',                 'Cliff' },
  { 'derby',                 'Derby' },
  { 'driver_training',       'Driver Training' },
  { 'east_coast_usa',        'East Coast USA' },
  { 'glow_city',             'Glow City' },
  { 'gridmap_v2',            'Gridmap v2' },
  { 'hirochi_raceway',       'Hirochi Raceway' },
  { 'industrial',            'Industrial' },
  { 'italy',                 'Italy' },
  { 'johnson_valley',        'Johnson Valley' },
  { 'jungle_rock_island',    'Jungle Rock Island' },
  { 'small_island',          'Small Island' },
  { 'smallgrid',             'Small Grid' },
  { 'utah',                  'Utah' },
  { 'west_coast_usa',        'West Coast USA' },
}

-- idle | countdown | kicking | restarting | staged
M.state = { phase = 'idle' }
M.last = nil        -- how the previous switch ended, shown on the Admin tab
M.zipCache = {}     -- [path] = { size = bytes, levels = { ... } }

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------
local function at(p)
  if M.paths.root == '' then return p end
  return M.paths.root .. '/' .. p
end

local function readFile(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function exists(path)
  local f = io.open(path, 'rb')
  if f then f:close(); return true end
  return false
end

-- A few tries a few tenths apart. A handle left by the Management Tool's
-- config read or a download stream fails a rename for a moment, not for good.
local function pause(seconds)
  local stop = os.clock() + seconds
  while os.clock() < stop do end
end

-- BeamMP's FS.Rename replaces an existing destination on Windows; os.rename
-- does not. The destination is checked afterwards either way, because the two
-- disagree about what they return.
local function rename(from, to)
  for try = 1, 4 do
    if FS and FS.Rename then
      pcall(FS.Rename, from, to)
    else
      os.rename(from, to)
    end
    if exists(to) and not exists(from) then return true end
    if try < 4 then pause(0.25) end
  end
  return false
end

local function move(from, to)
  if not exists(from) then return false, from .. ' is missing' end
  if exists(to) then return false, to .. ' already exists' end
  if not rename(from, to) then return false, 'could not move ' .. from .. ' to ' .. to end
  return true
end

-- The config's ResourceFolder, so a server that renamed Resources still works.
local function resourceFolder()
  local text = readFile(at(M.paths.config)) or ''
  return text:match('\n[ \t]*ResourceFolder[ \t]*=[ \t]*"([^"\r\n]+)"') or 'Resources'
end

local function clientDir() return at(resourceFolder() .. '/Client') end
local function storeDir() return at(M.paths.store) end

local function zipsIn(dir)
  local out = {}
  local ok, names = pcall(host.listDirectory, dir)
  for _, name in ipairs(ok and names or {}) do
    if name:lower():match('%.zip$') then out[#out + 1] = name end
  end
  table.sort(out, function (a, b) return a:lower() < b:lower() end)
  return out
end

-- ---------------------------------------------------------------------------
-- Which levels a zip holds
-- ---------------------------------------------------------------------------
-- Every levels/<name>/info.json in the central directory. Only the tail and
-- the directory are read, never the archive: map zips run to gigabytes.
-- The level folder name is NOT the zip name (DardsBarkRiverInternational.zip
-- holds bark_river_sc), which is why this has to open them at all.
function M.zipLevels(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local size = f:seek('end')
  local hit = M.zipCache[path]
  if hit and hit.size == size then f:close(); return hit.levels end
  local levels = {}
  M.zipCache[path] = { size = size, levels = levels }
  if not size or size < 22 then f:close(); return levels end

  -- End of central directory: 22 bytes plus a comment of up to 64 KB.
  local tailLen = math.min(size, 22 + 65535)
  f:seek('set', size - tailLen)
  local tail = f:read(tailLen) or ''
  local eocd, from = nil, 1
  while true do
    local i = tail:find('PK\5\6', from, true)
    if not i then break end
    eocd, from = i, i + 1
  end
  if not eocd or #tail - eocd + 1 < 22 then f:close(); return levels end
  local count, cdSize, cdOffset = string.unpack('<I2I4I4', tail, eocd + 10)

  -- ZIP64: the real numbers are in a second record the locator points at.
  if count == 0xFFFF or cdSize == 0xFFFFFFFF or cdOffset == 0xFFFFFFFF then
    local loc = eocd - 20
    if loc >= 1 and tail:sub(loc, loc + 3) == 'PK\6\7' then
      f:seek('set', (string.unpack('<I8', tail, loc + 8)))
      local rec = f:read(56)
      if rec and #rec == 56 and rec:sub(1, 4) == 'PK\6\6' then
        count, cdSize, cdOffset = string.unpack('<I8I8I8', rec, 33)
      end
    end
  end
  -- A directory this large is a corrupt number, not a map.
  if cdSize <= 0 or cdSize > 64 * 1024 * 1024 or cdOffset + cdSize > size then
    f:close()
    return levels
  end
  f:seek('set', cdOffset)
  local cd = f:read(cdSize) or ''
  f:close()

  local seen, p = {}, 1
  for _ = 1, count do
    if p + 45 > #cd or cd:sub(p, p + 3) ~= 'PK\1\2' then break end
    local nameLen, extraLen, commentLen = string.unpack('<I2I2I2', cd, p + 28)
    local name = cd:sub(p + 46, p + 45 + nameLen):gsub('\\', '/')
    local level, file = name:match('^[Ll][Ee][Vv][Ee][Ll][Ss]/([^/]+)/([^/]+)$')
    if level and file:lower() == 'info.json' and not seen[level:lower()] then
      seen[level:lower()] = true
      levels[#levels + 1] = level
    end
    p = p + 46 + nameLen + extraLen + commentLen
  end
  return levels
end

local function same(a, b)
  return type(a) == 'string' and type(b) == 'string' and a:lower() == b:lower()
end

-- ---------------------------------------------------------------------------
-- Display names
-- ---------------------------------------------------------------------------
-- A level name is often all a zip has to go by (bark_river_sc), so any map can
-- be given a name to show instead. DISPLAY ONLY: the zip, ServerConfig.toml and
-- every per-map file in Data keep the level name.
--
-- Data/mapNames.json maps level name to label. Re-read whenever the list is
-- built, so a hand edit shows on the next Refresh. A file that does not parse
-- is never written over.
M.MAX_LABEL = 40
M.names = nil       -- [lower level name] = { name, label }
M.namesOk = true

local function namesPath() return at(M.paths.data .. '/mapNames.json') end

-- Control characters out, spaces collapsed. nil for nothing left.
-- VALID UTF-8 ONLY, cut on a character: Util.JsonEncode throws on a broken
-- byte, and the label rides every RM_Maps push.
function M.cleanLabel(raw)
  if type(raw) ~= 'string' then return nil end
  local s = raw:gsub('%c', ' ')
  if not utf8.len(s) then s = s:gsub('[\128-\255]', '') end
  s = s:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  if s == '' then return nil end
  if utf8.len(s) > M.MAX_LABEL then
    s = s:sub(1, utf8.offset(s, M.MAX_LABEL + 1) - 1):gsub(' $', '')
  end
  return s
end

function M.loadNames()
  local names, ok = {}, true
  local text = readFile(namesPath())
  if text then
    local parsed, data = pcall(host.jsonParse, text)
    ok = parsed and type(data) == 'table'
    for k, v in pairs(ok and data or {}) do
      local label = type(k) == 'string' and M.cleanLabel(v)
      if label then names[k:lower()] = { name = k, label = label } end
    end
    if not ok then
      print('[RaceManager] Could not parse ' .. namesPath()
        .. ': map display names are off until it is fixed. It is left as it is.')
    end
  end
  M.names, M.namesOk = names, ok
  return names
end

-- The last name removed takes the file with it: an empty table writes as [].
local function saveNames()
  local out, any = {}, false
  for _, e in pairs(M.names) do out[e.name] = e.label; any = true end
  if not any then
    host.removeFile(namesPath())
    return readFile(namesPath()) == nil
  end
  host.makeDirectory(at(M.paths.data))
  return host.writeFile(namesPath(), host.jsonStringify(out)) ~= nil
end

local function stockLabel(name)
  for _, s in ipairs(M.STOCK) do
    if same(s[1], name) then return s[2] end
  end
end

function M.labelFor(name)
  if type(name) ~= 'string' then return name end
  local e = (M.names or M.loadNames())[name:lower()]
  return e and e.label or stockLabel(name) or name
end

-- ---------------------------------------------------------------------------
-- The catalog
-- ---------------------------------------------------------------------------
-- Every map this server can be switched to:
--   { name, label, default, custom, zip, where = 'client' | 'store' | 'stock', current }
-- A map zip wins a level name over the stock level of the same name, since it
-- is what the clients would load. Resources/Client wins over custom_maps.
function M.catalog()
  M.loadNames()
  local current = host.getCurrentMap()
  local list, byName = {}, {}
  local function add(e)
    local key = e.name:lower()
    if byName[key] then
      if e.zip then
        print('[RaceManager] Map "' .. e.name .. '" is in both ' .. tostring(byName[key].zip)
          .. ' and ' .. e.zip .. '; using ' .. tostring(byName[key].zip or 'the stock level'))
      end
      return
    end
    e.current = same(e.name, current)
    local named = M.names[key]
    e.default = e.label
    e.label = named and named.label or e.label
    e.custom = named ~= nil or nil
    byName[key] = e
    list[#list + 1] = e
  end
  for _, place in ipairs({ { clientDir(), 'client' }, { storeDir(), 'store' } }) do
    for _, file in ipairs(zipsIn(place[1])) do
      for _, level in ipairs(M.zipLevels(place[1] .. '/' .. file) or {}) do
        add({ name = level, label = level, zip = file, where = place[2] })
      end
    end
  end
  for _, s in ipairs(M.STOCK) do add({ name = s[1], label = s[2], where = 'stock' }) end
  table.sort(list, function (a, b)
    local ka, kb = a.where == 'stock' and 1 or 0, b.where == 'stock' and 1 or 0
    if ka ~= kb then return ka < kb end
    return a.label:lower() < b.label:lower()
  end)
  M.catalogCache = list
  return list, byName
end

-- ---------------------------------------------------------------------------
-- ServerConfig.toml
-- ---------------------------------------------------------------------------
-- Only the Map value changes; every other byte, line endings included, stays
-- as it was. BeamMP rewrites this file at every start, and the Management
-- Tool restarts on ANY difference, so a reformatted file would restart twice.
function M.rewriteMap(text, value)
  local out, n = ('\n' .. text):gsub('(\n[ \t]*Map[ \t]*=[ \t]*)["\'][^"\'\r\n]*["\']',
    function (lead) return lead .. '"' .. value .. '"' end, 1)
  if n ~= 1 then return nil end
  return out:sub(2)
end

-- Written beside and renamed over, so the tool never reads half a file: a
-- truncated config restarts the server with its AuthKey missing.
local function writeConfig(value)
  local path = at(M.paths.config)
  local text = readFile(path)
  if not text then return false, 'ServerConfig.toml is not in the server folder' end
  local new = M.rewriteMap(text, value)
  if not new then return false, 'ServerConfig.toml has no Map line' end
  local tmp = path .. '.rm-tmp'
  local f = io.open(tmp, 'wb')
  if not f then return false, 'cannot write ' .. tmp end
  f:write(new)
  f:close()
  -- os.rename cannot replace a file on Windows, so there it needs BeamMP's.
  local canReplace = (FS and FS.Rename) or not IS_WINDOWS
  if not (canReplace and rename(tmp, path)) then
    os.remove(tmp)
    for try = 1, 4 do
      f = io.open(path, 'wb')
      if f then f:write(new); f:close(); break end
      if try < 4 then pause(0.25) end
    end
  end
  if readFile(path) ~= new then return false, 'ServerConfig.toml did not take the change' end
  return true
end

-- ---------------------------------------------------------------------------
-- Who started this server
-- ---------------------------------------------------------------------------
-- The chain on Windows is BeamMP-Server -> cmd (io.popen) -> powershell, so
-- the server is the grandparent of $PID and ITS parent tells us whether the
-- Management Tool is in charge. The tool keeps its restart settings in
-- user.config, and an unsaved setting is absent there, which means off.
-- No double quotes inside: the whole thing rides in one cmd argument.
local PS_PROBE = table.concat({
  "$p = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID);",
  "$c = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $p.ParentProcessId);",
  "$s = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $c.ParentProcessId);",
  "$t = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $s.ParentProcessId);",
  "'pid=' + $s.ProcessId; 'exe=' + $s.ExecutablePath; 'name=' + $s.Name;",
  "'cmd=' + $s.CommandLine; 'cwd=' + (Get-Location).Path; 'parent=' + $t.Name;",
  "if ($t.Name -like '*Management*') {",
  "  $u = Get-ChildItem -Path ($env:LOCALAPPDATA + '\\*\\BeamMP.Server.Management*\\*\\user.config')",
  "    -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1;",
  "  'mtconfig=' + [bool]$u;",
  "  if ($u) { $x = [xml](Get-Content -Raw $u.FullName);",
  "    foreach ($n in $x.configuration.userSettings.ChildNodes.setting) { 'mt.' + $n.name + '=' + $n.value } }",
  "}",
}, ' ')

-- /bin/sh from popen is a direct child, so $PPID is the server.
local SH_PROBE = table.concat({
  'echo pid=$PPID;',
  'echo exe=$(readlink /proc/$PPID/exe);',
  'echo cwd=$(readlink /proc/$PPID/cwd);',
  'echo parent=$(ps -o comm= -p $(ps -o ppid= -p $PPID) 2>/dev/null);',
  "tr '\\000' '\\n' < /proc/$PPID/cmdline | tail -n +2 | sed 's/^/arg=/'",
}, ' ')

-- { pid, exe, name, cmd, cwd, parent, args = {}, mt = { setting = value } }.
-- Blocks for a second or so on Windows, which is why it runs once, at the
-- start of a switch, when no session is running.
function M.probe()
  local info = { args = {}, mt = {} }
  local cmd = IS_WINDOWS
    and ('powershell -NoProfile -NonInteractive -Command "' .. PS_PROBE .. '"')
    or SH_PROBE
  local ok, pipe = pcall(M.sys.popen, cmd)
  if ok and pipe then
    for line in pipe:lines() do
      local k, v = line:match('^([%w%.]+)=(.*)$')
      if k then
        v = v:gsub('%s+$', '')
        if k == 'arg' then info.args[#info.args + 1] = v
        elseif k:sub(1, 3) == 'mt.' then info.mt[k:sub(4)] = v
        else info[k] = v end
      end
    end
    pipe:close()
  end
  info.pid = tonumber(info.pid)
  if not info.cwd or info.cwd == '' then
    ok, pipe = pcall(M.sys.popen, IS_WINDOWS and 'cd' or 'pwd')
    if ok and pipe then
      info.cwd = (pipe:read('l') or ''):gsub('%s+$', '')
      pipe:close()
    end
  end
  return info
end

-- ---------------------------------------------------------------------------
-- Restarting
-- ---------------------------------------------------------------------------
local function cfg(key, fallback)
  local v = host.CFG and host.CFG[key]
  if v == nil then return fallback end
  return v
end

local function serverPort()
  local text = readFile(at(M.paths.config)) or ''
  return tonumber(text:match('\n[ \t]*Port[ \t]*=[ \t]*(%d+)')) or 30814
end

-- Picks the method and says, in one sentence, what will happen.
function M.resolveRestart(info)
  local want = cfg('mapRestart', 'auto')
  local underTool = type(info.parent) == 'string' and info.parent:lower():find('management') ~= nil
  local grace = cfg('mapRestartGrace', 90)
  local note
  if want == 'auto' then want = underTool and 'watch' or 'relaunch' end
  if want == 'watch' and underTool and info.mtconfig == 'True' then
    local secs = tonumber(info.mt.checkRestartCfgTimerSeconds) or 0
    if info.mt.checkRestartCfgTimer == 'True' and secs > 0 then
      return 'watch', secs + 15, 'The Management Tool restarts the server within '
        .. secs .. ' seconds of the change.'
    end
    want = 'relaunch'
    note = "The Management Tool's config check is off, so Race Manager restarts "
      .. 'the server itself, outside the tool. Turn on "Check for config update '
      .. 'and restart" to keep the tool in charge.'
  end
  -- Only these two stop the server from here; watch leaves it to the tool.
  if (want == 'relaunch' or want == 'exit') and not M.sys.exit then
    return 'manual', grace, 'This BeamMP build cannot stop itself. Restart the server by hand to finish.'
  end
  if want == 'watch' then
    return 'watch', grace, 'Waiting up to ' .. grace .. ' seconds for the config '
      .. 'check to restart the server'
      .. (M.sys.exit and ', then Race Manager restarts it itself.' or '.')
  end
  if want == 'relaunch' then
    return 'relaunch', grace, note or 'Race Manager starts the server again once it has stopped.'
  end
  if want == 'exit' then
    return 'exit', grace, 'The server stops, and your service manager starts it again.'
  end
  return 'manual', grace, 'Restart the server by hand to finish.'
end

local function batQuote(s) return (tostring(s):gsub('%%', '%%%%')) end
local function shQuote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function psQuote(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end

-- The helper that outlives this process. It waits until the old server is gone
-- (its PID when the probe found one) AND its UDP port is free, then starts the
-- same command line in the same folder, and gives up after five minutes.
--
-- THE PORT, NOT ONLY THE PID: a new server that cannot bind UDP shuts itself
-- straight down, and the log says only "bind() failed".
function M.relaunchScript(info)
  local cwd = (info.cwd and info.cwd ~= '') and info.cwd or '.'
  local port = serverPort()
  if IS_WINDOWS then
    local exe = (info.exe and info.exe ~= '') and info.exe or (cwd .. '\\BeamMP-Server.exe')
    local image = (info.name and info.name ~= '') and info.name or exe:match('[^\\/]+$')
    local command = (info.cmd and info.cmd ~= '') and info.cmd or ('"' .. exe .. '"')
    -- Full paths: with Git or Cygwin on PATH, `find` is the Unix one, every
    -- check reads as "gone", and the new server starts on top of the old.
    local sys32 = '%SystemRoot%\\System32\\'
    local lines = {
      '@echo off',
      'rem Written by Race Manager for a map switch. Safe to delete.',
      'title Race Manager: restarting BeamMP',
      'cd /d "' .. batQuote(cwd) .. '"',
      'set n=0',
      ':wait',
    }
    if info.pid then
      lines[#lines + 1] = sys32 .. 'tasklist.exe /NH /FI "PID eq ' .. info.pid .. '" 2>nul | '
        .. sys32 .. 'find.exe /I "' .. image .. '" >nul'
      lines[#lines + 1] = 'if not errorlevel 1 goto again'
    end
    for _, l in ipairs({
      sys32 .. 'netstat.exe -ano | ' .. sys32 .. 'find.exe "UDP" | '
        .. sys32 .. 'find.exe ":' .. port .. ' " >nul',
      'if errorlevel 1 goto start',
      ':again',
      'set /a n+=1',
      'if %n% geq 300 exit /b 1',
      sys32 .. 'PING.EXE -n 2 127.0.0.1 >nul',
      'goto wait',
      ':start',
      'start "BeamMP-Server" ' .. batQuote(command),
      '',
    }) do lines[#lines + 1] = l end
    return table.concat(lines, '\r\n')
  end
  local exe = (info.exe and info.exe ~= '') and info.exe or './BeamMP-Server'
  local argv = { shQuote(exe) }
  for _, a in ipairs(info.args or {}) do argv[#argv + 1] = shQuote(a) end
  local alive = info.pid and ('kill -0 ' .. info.pid .. ' 2>/dev/null || ') or ''
  return table.concat({
    '#!/bin/bash',
    '# Written by Race Manager for a map switch. Safe to delete.',
    -- Anything inherited from the old server, closed. A socket still open here
    -- keeps its port. bash only: dash reads "exec 12>&-" as a command and exits.
    -- 255 is bash reading this file.
    'if [ -n "$BASH_VERSION" ]; then',
    '  for fd in /proc/$$/fd/*; do n=${fd##*/}',
    '    case $n in 0|1|2|255) ;; *) eval "exec $n>&-" ;; esac',
    '  done 2>/dev/null',
    'fi',
    'cd ' .. shQuote(cwd) .. ' || exit 1',
    'n=0',
    'while ' .. alive .. "ss -uln 2>/dev/null | grep -q ':" .. port .. " '; do",
    '  n=$((n+1)); [ $n -ge 300 ] && exit 1',
    '  sleep 1',
    'done',
    'exec ' .. table.concat(argv, ' '),
    '',
  }, '\n')
end

local function scriptPath()
  return at(M.paths.data .. (IS_WINDOWS and '/relaunch.cmd' or '/relaunch.sh'))
end

-- NOT `start` FROM HERE. Anything this process starts inherits its open
-- sockets and files, and `start` passes them on again, so the helper, and the
-- server it starts, kept the old server's UDP socket and the new one could
-- not bind its own port. Start-Process goes through ShellExecute, which
-- inherits nothing. The cmd and powershell in between exit at once.
local function spawnRelauncher(info)
  host.makeDirectory(at(M.paths.data))
  local path = scriptPath()
  local f = io.open(path, 'wb')
  if not f then return false end
  f:write(M.relaunchScript(info))
  f:close()
  local ok, res
  if IS_WINDOWS then
    local cwd = (info.cwd and info.cwd ~= '') and info.cwd or nil
    local abs = path
    if not abs:match('^%a:') and cwd then abs = cwd .. '\\' .. path end
    abs = abs:gsub('/', '\\')
    ok, res = pcall(M.sys.execute, 'powershell -NoProfile -NonInteractive -Command "'
      .. 'Start-Process -FilePath ' .. psQuote(abs)
      .. (cwd and (' -WorkingDirectory ' .. psQuote(cwd)) or '')
      .. ' -WindowStyle Minimized"')
  else
    local log = at(M.paths.data .. '/relaunch.log')
    ok, res = pcall(M.sys.execute, '(command -v bash >/dev/null && nohup bash ' .. shQuote(path)
      .. ' || nohup sh ' .. shQuote(path) .. ') > ' .. shQuote(log) .. ' 2>&1 < /dev/null &')
  end
  -- os.execute is true only for exit code 0: PowerShell exits 1 if Start-Process failed.
  return ok and res == true
end

local function stopServer(why)
  print('[RaceManager] Map switch: stopping the server (' .. why .. ')')
  M.sys.exit()
end

-- ---------------------------------------------------------------------------
-- State to the panel
-- ---------------------------------------------------------------------------
-- Everyone gets it, because drivers vote and need to see a switch coming.
-- Each push is the whole state except the list, which is sent only when asked
-- for: building it opens every map zip's directory.

-- One timer for the vote and the switch. BeamMP starts a second timer if the
-- same name is created twice, and every countdown would run at double speed.
local function timerOn()
  if M.ticking then return end
  M.ticking = true
  MP.CreateEventTimer('RM_MapTick', 1000)
end

local function timerOff()
  if not M.ticking then return end
  M.ticking = false
  MP.CancelEventTimer('RM_MapTick')
end

-- Voting: anyone may call one, and it passes when the yes votes reach
-- mapVotePercent of EVERYONE connected, so staying quiet counts against it.
M.VOTE_SECONDS  = 30
M.VOTE_COOLDOWN = 60    -- after a failed vote, before a driver may call another
M.vote = nil            -- { id, target, by, byAdmin, yes = {}, no = {}, left }
M.voteSeq = 0
M.voteCooldownUntil = 0

function M.tally()
  local v = M.vote
  local total, yes, no = 0, 0, 0
  for pid in pairs(MP.GetPlayers() or {}) do
    total = total + 1
    if v.yes[pid] then yes = yes + 1 elseif v.no[pid] then no = no + 1 end
  end
  local pct = tonumber(cfg('mapVotePercent', 60)) or 60
  local needed = math.max(1, math.ceil(total * pct / 100 - 1e-9))
  return yes, no, total, needed
end

local function snapshot(withList, err)
  local s, v = M.state, M.vote
  local current = host.getCurrentMap()
  local out = {
    current = current,
    phase   = s.phase,
    target  = s.target and s.target.name or nil,
    targetLabel = s.target and s.target.label or nil,
    by      = s.by,
    left    = s.left,
    method  = s.method,
    note    = s.note,
    error   = err or M.lastError,
    last    = M.last,
    restart = cfg('mapRestart', 'auto'),
    voting  = cfg('mapVoting', true) == true,
    votePercent = cfg('mapVotePercent', 60),
    voteWait = math.max(0, M.voteCooldownUntil - os.time()),
  }
  if v then
    local yes, no, total, needed = M.tally()
    out.vote = { id = v.id, map = v.target.name, label = v.target.label, by = v.by,
      yes = yes, no = no, total = total, needed = needed, left = v.left }
  end
  if withList then
    local list = {}
    for _, e in ipairs(M.catalog()) do
      list[#list + 1] = { name = e.name, label = e.label, zip = e.zip,
        where = e.where, current = e.current, default = e.default, custom = e.custom }
    end
    out.list = list
  end
  -- After the list, which re-reads the names.
  out.currentLabel = M.labelFor(current)
  return out
end

local function send(pid, withList, err)
  MP.TriggerClientEvent(pid, 'RM_Maps', Util.JsonEncode(snapshot(withList, err)))
end

local function broadcast()
  MP.TriggerClientEvent(-1, 'RM_Maps', Util.JsonEncode(snapshot(false)))
end

-- A refusal, to the one person who asked. A toast, because most drivers have
-- no chat app, and on the panel under the Map controls.
local function tell(pid, msg)
  MP.TriggerClientEvent(pid, 'RM_Notice', Util.JsonEncode({
    kind = 'session', msg = 'Map', sub = msg,
  }))
  send(pid, false, msg)
end

-- ---------------------------------------------------------------------------
-- The switch
-- ---------------------------------------------------------------------------
local function reset()
  M.state = { phase = 'idle' }
  if not M.vote then timerOff() end
end

local function fail(msg)
  print('[RaceManager] Map switch failed: ' .. msg)
  M.lastError = msg
  M.last = { ok = false, to = M.state.target and M.state.target.label, note = msg, at = os.time() }
  reset()
  broadcast()
end

local function pendingPath() return at(M.paths.data .. '/mapSwitch.json') end

local function kickEveryone()
  local label = M.state.target.label
  local reason = M.state.method == 'manual'
    and ('Race Manager: switching the map to ' .. label .. '. Rejoin once the server has been restarted.')
    or ('Race Manager: the server is restarting onto ' .. label .. '. Rejoin in about a minute.')
  for pid in pairs(MP.GetPlayers() or {}) do
    if MP.DropPlayer then pcall(MP.DropPlayer, pid, reason) end
  end
end

-- The map by name, if it can be switched to.
local function pick(name)
  local list, byName = M.catalog()
  local target = type(name) == 'string' and byName[name:lower()]
  if not target then return nil, 'No map called "' .. tostring(name) .. '" on this server.' end
  if target.current then return nil, target.label .. ' is already the map.' end
  return target, list
end

-- Start the countdown. Shared by an admin's switch and a vote that passed.
local function begin(name, by)
  if M.state.phase ~= 'idle' then return false, 'A map switch is already under way.' end
  local busy = host.busy()
  if busy then return false, 'Not while ' .. busy .. ': end it first.' end
  local target, list = pick(name)
  if not target then return false, list end
  local fromEntry
  for _, e in ipairs(list) do if e.current then fromEntry = e end end

  local info = M.probe()
  local method, grace, note = M.resolveRestart(info)
  M.lastError = nil
  M.state = {
    phase = 'countdown', left = M.COUNTDOWN, target = target, fromEntry = fromEntry,
    from = host.getCurrentMap(), probe = info, method = method, grace = grace, note = note,
    by = by,
  }
  print(string.format('[RaceManager] Map switch to %s by %s: %s (parent %s, pid %s)',
    target.name, by, method, tostring(info.parent), tostring(info.pid)))
  MP.SendChatMessage(-1, string.format('[RaceManager] Switching the map to %s (%s). '
    .. 'Everyone is disconnected in %d seconds and the server restarts.',
    target.label, by, M.COUNTDOWN))
  host.notifyField('session', 'Map change to ' .. target.label,
    'The server restarts in ' .. M.COUNTDOWN .. ' seconds. Rejoin in about a minute.')
  timerOn()
  broadcast()
  return true
end

-- Move the zips, rewrite the config, then restart. Any failure before the
-- config is written puts the zips back, and the server carries on as it was.
function M.execute()
  local s = M.state
  local target, from = s.target, s.fromEntry
  local client, store = clientDir(), storeDir()
  local moved = {}
  local function undo()
    for i = #moved, 1, -1 do rename(moved[i][2], moved[i][1]) end
  end

  if from and from.where == 'client' and from.zip and from.zip ~= target.zip then
    host.makeDirectory(store)
    local a, b = client .. '/' .. from.zip, store .. '/' .. from.zip
    local ok, err = move(a, b)
    if not ok then return fail(err) end
    moved[#moved + 1] = { a, b }
  end
  if target.where == 'store' then
    local a, b = store .. '/' .. target.zip, client .. '/' .. target.zip
    local ok, err = move(a, b)
    if not ok then undo(); return fail(err) end
    moved[#moved + 1] = { a, b }
  end

  local value = '/levels/' .. target.name .. '/info.json'
  local ok, err = writeConfig(value)
  if not ok then undo(); return fail(err) end
  -- In memory too, so a server that is never restarted still hands the new
  -- map to anyone joining. Harmless when it is.
  if MP.Set and MP.Settings and MP.Settings.Map ~= nil then
    pcall(MP.Set, MP.Settings.Map, value)
  end

  host.makeDirectory(at(M.paths.data))
  local f = io.open(pendingPath(), 'w')
  if f then
    f:write(host.jsonStringify({
      to = target.name, label = target.label, from = s.from, at = os.time(), method = s.method,
    }))
    f:close()
  end
  print(string.format('[RaceManager] Map switch: ServerConfig.toml now says %s (%s)',
    value, s.method))

  if s.method == 'relaunch' then
    if spawnRelauncher(s.probe) then return stopServer('relaunch') end
    s.method, s.note = 'manual', 'Could not start the relaunch helper. Restart the server by hand.'
  elseif s.method == 'exit' then
    return stopServer('exit')
  elseif s.method == 'watch' then
    s.phase, s.left = 'restarting', s.grace
    return
  end
  s.phase = 'staged'
  timerOff()
  print('[RaceManager] Map switch staged: restart the server to load ' .. target.label)
end

-- ---------------------------------------------------------------------------
-- The vote
-- ---------------------------------------------------------------------------
local function endVote(passed, why)
  local v = M.vote
  M.vote = nil
  print(string.format('[RaceManager] Map vote for %s %s: %s', v.target.name,
    passed and 'passed' or 'failed', why))
  if passed then
    local ok, err = begin(v.target.name, 'vote called by ' .. v.by)
    if not ok then
      host.notifyField('session', 'Map vote passed', 'But not switching: ' .. err)
    end
  else
    if not v.byAdmin then M.voteCooldownUntil = os.time() + M.VOTE_COOLDOWN end
    host.notifyField('session', 'Map vote failed', v.target.label .. ': ' .. why)
  end
  if M.state.phase == 'idle' then timerOff() end
  broadcast()
end

-- Settled as soon as it can be: a pass the moment enough have said yes, a
-- fail the moment the undecided could not carry it any more.
local function checkVote()
  local yes, no, total, needed = M.tally()
  if yes >= needed then
    return endVote(true, yes .. ' of ' .. total .. ' voted yes')
  end
  if yes + (total - yes - no) < needed then
    return endVote(false, yes .. ' of ' .. total .. ' voted yes, ' .. needed .. ' needed')
  end
  broadcast()
end

function M.voteStart(pid, raw)
  local admin = host.isAdmin(pid)
  if M.vote then return tell(pid, 'A map vote is already running.') end
  if M.state.phase ~= 'idle' then return tell(pid, 'A map switch is already under way.') end
  if not admin then
    if cfg('mapVoting', true) ~= true then
      return tell(pid, 'Map voting is locked by the race director.')
    end
    local wait = M.voteCooldownUntil - os.time()
    if wait > 0 then return tell(pid, 'Another map vote can be called in ' .. wait .. ' seconds.') end
  end
  local busy = host.busy()
  if busy then return tell(pid, 'Not while ' .. busy .. '.') end
  local ok, data = pcall(Util.JsonDecode, raw or '')
  local target, err = pick(ok and type(data) == 'table' and data.map)
  if not target then return tell(pid, err) end

  M.voteSeq = M.voteSeq + 1
  local by = MP.GetPlayerName(pid) or ('player ' .. pid)
  M.vote = { id = M.voteSeq, target = target, by = by, byAdmin = admin,
    yes = { [pid] = true }, no = {}, left = M.VOTE_SECONDS }
  print(string.format('[RaceManager] Map vote for %s called by %s', target.name, by))
  host.notifyField('session', 'Map vote: ' .. target.label,
    by .. ' wants to switch. Vote in the Race Manager app.')
  timerOn()
  checkVote()
end

function M.castVote(pid, raw)
  local v = M.vote
  if not v then return end
  local ok, data = pcall(Util.JsonDecode, raw or '')
  local yes = ok and type(data) == 'table' and data.yes == true
  v.yes[pid] = yes or nil
  v.no[pid] = (not yes) or nil
  checkVote()
end

local function stopVote(why)
  local label = M.vote.target.label
  M.vote = nil
  if M.state.phase == 'idle' then timerOff() end
  print('[RaceManager] Map vote for ' .. label .. ' stopped: ' .. why)
  host.notifyField('session', 'Map vote stopped', label .. ': ' .. why)
  broadcast()
end

function M.voteCancel(pid)
  if not host.requireAuth(pid) then return end
  if not M.vote then return send(pid, false) end
  stopVote('stopped by the race director')
end

-- The lock and the pass mark. Written to config.json, so a lock set on race
-- night survives the restart a switch causes.
function M.voteConfig(pid, raw)
  if not host.requireAuth(pid) then return end
  local ok, data = pcall(Util.JsonDecode, raw or '')
  if not ok or type(data) ~= 'table' then return end
  if type(data.enabled) == 'boolean' then host.CFG.mapVoting = data.enabled end
  local pct = tonumber(data.percent)
  if pct then
    pct = math.floor(pct)
    if pct >= 1 and pct <= 100 then host.CFG.mapVotePercent = pct end
  end
  host.saveConfig()
  print(string.format('[RaceManager] Map voting %s, passes at %d%%',
    host.CFG.mapVoting and 'open' or 'locked', host.CFG.mapVotePercent))
  if M.vote and not host.CFG.mapVoting and not M.vote.byAdmin then
    return stopVote('voting was locked')
  end
  if M.vote then return checkVote() end
  broadcast()
end

function M.onPlayerDisconnect(pid)
  if not M.vote then return end
  M.vote.yes[pid], M.vote.no[pid] = nil, nil
end

-- ---------------------------------------------------------------------------
-- The clock
-- ---------------------------------------------------------------------------
function M.tick()
  if M.vote then
    M.vote.left = M.vote.left - 1
    if M.vote.left > 0 then return checkVote() end
    local yes, _, total, needed = M.tally()
    return endVote(yes >= needed, yes .. ' of ' .. total .. ' voted yes, '
      .. needed .. ' needed, time up')
  end
  local s = M.state
  if s.phase == 'countdown' then
    s.left = s.left - 1
    if s.left == 5 then
      host.notifyField('session', 'Map change to ' .. s.target.label,
        'Everyone is disconnected in 5 seconds')
    end
    if s.left > 0 then return broadcast() end
    s.phase, s.left = 'kicking', M.SETTLE
    kickEveryone()
  elseif s.phase == 'kicking' then
    s.left = s.left - 1
    if s.left > 0 then return end
    M.execute()
  elseif s.phase == 'restarting' then
    s.left = s.left - 1
    if s.left > 0 then return end
    print('[RaceManager] Map switch: nothing restarted the server in ' .. s.grace
      .. ' seconds; restarting it from here')
    if M.sys.exit and spawnRelauncher(s.probe) then
      return stopServer('relaunch after the wait')
    end
    s.phase = 'staged'
    timerOff()
    print('[RaceManager] Map switch staged: restart the server to load ' .. s.target.label)
  end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
-- The list is for everyone: a driver picks from it to call a vote. A joining
-- client asks for the state alone ({"list":false}), which reads no zips.
function M.request(pid, raw)
  local ok, data = pcall(Util.JsonDecode, raw ~= '' and raw or '{}')
  send(pid, not (ok and type(data) == 'table' and data.list == false))
end

-- Either tier: a display name is undone by renaming it back. An empty label
-- (or the default one) goes back to the default.
function M.rename(pid, raw)
  if not host.requireAuth(pid) then return end
  local ok, data = pcall(Util.JsonDecode, raw or '')
  if not ok or type(data) ~= 'table' or type(data.map) ~= 'string' then return end
  local _, byName = M.catalog()
  local e = byName[data.map:lower()]
  if not e then return tell(pid, 'No map called "' .. data.map .. '" on this server.') end
  if not M.namesOk then
    return tell(pid, 'mapNames.json in the Data folder does not parse. Fix it on the server first.')
  end
  local label = M.cleanLabel(data.label)
  if label == e.default then label = nil end
  M.names[e.name:lower()] = label and { name = e.name, label = label } or nil
  if not saveNames() then return tell(pid, 'Could not write mapNames.json.') end
  print(string.format('[RaceManager] Map %s is now shown as "%s" (%s)', e.name,
    label or e.default, MP.GetPlayerName(pid) or pid))
  -- Everyone's list: the name shows in their vote menu and in a switch too.
  MP.TriggerClientEvent(-1, 'RM_Maps', Util.JsonEncode(snapshot(true)))
end

-- An admin switches at will, and that includes over a vote in progress.
function M.switch(pid, raw)
  if not host.requireAuth(pid) then return end
  local ok, data = pcall(Util.JsonDecode, raw or '')
  local name = ok and type(data) == 'table' and data.map
  if type(name) ~= 'string' or name == '' then return end
  local target, err = pick(name)
  if not target then return tell(pid, err) end
  if M.state.phase ~= 'idle' then return tell(pid, 'A map switch is already under way.') end
  local busy = host.busy()
  if busy then return tell(pid, 'Not while ' .. busy .. ': end it first.') end
  if M.vote then stopVote('the race director switched the map') end
  local by = MP.GetPlayerName(pid) or ('player ' .. pid)
  local started
  started, err = begin(name, by)
  if not started then tell(pid, err) end
end

function M.cancel(pid)
  if not host.requireAuth(pid) then return end
  if M.state.phase ~= 'countdown' then return send(pid, false) end
  local label = M.state.target.label
  reset()
  print('[RaceManager] Map switch to ' .. label .. ' cancelled')
  host.notifyField('session', 'Map change cancelled', 'Staying on this map')
  broadcast()
end

-- Joining while the old server is still up but its map zip has moved would
-- fail the download or land on a map about to disappear.
function M.onPlayerAuth()
  local p = M.state.phase
  if p == 'kicking' or p == 'restarting' then
    return 'The server is switching maps. Try again in a minute.'
  end
end

-- After a restart: did the switch take?
function M.warm()
  for _, name in ipairs({ '/relaunch.cmd', '/relaunch.sh' }) do
    local p = at(M.paths.data .. name)
    if exists(p) then host.removeFile(p) end
  end
  local text = readFile(pendingPath())
  if not text then return end
  host.removeFile(pendingPath())
  local ok, rec = pcall(host.jsonParse, text)
  if not ok or type(rec) ~= 'table' or type(rec.to) ~= 'string' then return end
  local now = host.getCurrentMap()
  local took = same(now, rec.to)
  local secs = tonumber(rec.at) and (os.time() - rec.at) or nil
  M.last = {
    ok = took, to = rec.label or rec.to, at = rec.at, secs = secs,
    note = not took and ('The server came back on ' .. tostring(now) .. ', not ' .. rec.to) or nil,
  }
  if took then
    print(string.format('[RaceManager] Map switch to %s complete%s', rec.to,
      secs and (' (' .. secs .. ' s)') or ''))
  else
    print('[RaceManager] Map switch did not take: ' .. M.last.note)
  end
end

-- The RM_Map* globals, installed here and not at file scope: see the top.
function M.init(h)
  host = h
  M.host = h   -- for tests: CFG and busy() are locals of main.lua
  function RM_onMapRequest(pid, raw) M.request(pid, raw) end
  function RM_onMapSwitch(pid, raw) M.switch(pid, raw) end
  function RM_onMapCancel(pid) M.cancel(pid) end
  function RM_onMapVoteStart(pid, raw) M.voteStart(pid, raw) end
  function RM_onMapVote(pid, raw) M.castVote(pid, raw) end
  function RM_onMapVoteCancel(pid) M.voteCancel(pid) end
  function RM_onMapVoteConfig(pid, raw) M.voteConfig(pid, raw) end
  function RM_onMapRename(pid, raw) M.rename(pid, raw) end
  function RM_MapTick() M.tick() end
  function RM_Map_onPlayerAuth() return M.onPlayerAuth() end
  function RM_Map_onPlayerDisconnect(pid) M.onPlayerDisconnect(pid) end
end

return M
