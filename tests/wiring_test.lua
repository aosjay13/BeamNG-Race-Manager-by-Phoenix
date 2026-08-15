-- Static audit of the event wiring between the three layers.
--
-- Why this exists: every other test in this suite mocks MP.RegisterEvent as a
-- no-op and then calls the handlers DIRECTLY, so registration is the one link
-- nothing exercises. That blind spot has now produced the same bug twice --
-- RM_SetAlias, where an admin pressed Set and nothing reached the server, and
-- RM_DerbyCountdownTick, where the derby countdown created a timer, ticked, and
-- froze on 3 forever because nothing was listening. Both looked like dead
-- buttons and neither left a trace in any console.
--
-- Nothing here runs the plugin. It reads the three sources as text and checks
-- that every event one layer sends has somebody registered to receive it.
-- Run from the repo root: lua5.3 tests/wiring_test.lua

local fails, checks = 0, 0
local function expect(cond, msg)
  checks = checks + 1
  if not cond then
    fails = fails + 1
    print('FAIL: ' .. msg)
  end
end

local function readFile(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local s = f:read('*a')
  f:close()
  return s
end

local server = readFile('server/RaceManager/main.lua')
local client = readFile('lua/ge/extensions/raceManager.lua')
local ui     = readFile('ui/modules/apps/RaceManager/app.js')

-- Everything the server plugin registers a handler for.
local registered = {}
for name in server:gmatch("MP%.RegisterEvent%s*%(%s*'([%w_]+)'") do
  registered[name] = true
end
expect(next(registered) ~= nil, 'found MP.RegisterEvent calls in the server plugin')

-- ---------------------------------------------------------------------------
-- 1. Every timer the server creates must have a registered handler.
--
-- MP.CreateEventTimer fires an event on an interval; if nothing is registered
-- under that name the timer runs forever and does nothing at all.
-- ---------------------------------------------------------------------------
local timers = {}
for name in server:gmatch("MP%.CreateEventTimer%s*%(%s*'([%w_]+)'") do
  timers[name] = true
end
expect(next(timers) ~= nil, 'found MP.CreateEventTimer calls in the server plugin')
for name in pairs(timers) do
  expect(registered[name],
    'timer "' .. name .. '" is created but never registered, so it ticks into '
      .. 'nothing (this is exactly how the derby countdown stuck on 3)')
end

-- ---------------------------------------------------------------------------
-- 2. Every event the CLIENT sends upstream must be registered on the server.
--
-- An unregistered event is dropped silently by BeamMP: the control appears to
-- do nothing and no console anywhere reports it.
-- ---------------------------------------------------------------------------
local sentUpstream = {}
for name in client:gmatch("TriggerServerEvent%s*%(%s*'([%w_]+)'") do
  sentUpstream[name] = true
end
expect(next(sentUpstream) ~= nil, 'found TriggerServerEvent calls in the client bridge')
for name in pairs(sentUpstream) do
  expect(registered[name],
    'the client sends "' .. name .. '" but the server registers no handler for '
      .. 'it, so pressing that control does nothing and says nothing')
end

-- ---------------------------------------------------------------------------
-- 3. Every event the SERVER pushes downstream must be dispatched by the client.
--
-- The client routes incoming events through one DISPATCH table; a name missing
-- from it is received and thrown away.
-- ---------------------------------------------------------------------------
local dispatchBlock = client:match('local DISPATCH = {(.-)\n}')
expect(dispatchBlock ~= nil, 'found the client DISPATCH table')

local dispatched = {}
if dispatchBlock then
  for name in dispatchBlock:gmatch('([%w_]+)%s*=') do
    dispatched[name] = true
  end
end

local sentDownstream = {}
for name in server:gmatch("MP%.TriggerClientEvent%s*%([^,]+,%s*'([%w_]+)'") do
  sentDownstream[name] = true
end
expect(next(sentDownstream) ~= nil, 'found MP.TriggerClientEvent calls in the server plugin')
for name in pairs(sentDownstream) do
  expect(dispatched[name],
    'the server sends "' .. name .. '" to clients but it is not in the client '
      .. 'DISPATCH table, so the client receives it and throws it away')
end

-- ---------------------------------------------------------------------------
-- 4. Handlers named in a registration must actually exist.
--
-- MP.RegisterEvent takes the handler name as a STRING, so a typo cannot be
-- caught by the compiler -- it resolves to nil at fire time.
-- ---------------------------------------------------------------------------
for event, handler in server:gmatch("MP%.RegisterEvent%s*%(%s*'[%w_]+'%s*,%s*'([%w_]+)'()") do
  local _ = handler
end
for event, handler in server:gmatch("MP%.RegisterEvent%s*%(%s*'([%w_]+)'%s*,%s*'([%w_]+)'") do
  -- Our own handlers are global functions defined in this file. BeamMP's base
  -- hooks (onPlayerJoin and friends) are ours too -- every name we register
  -- points at a function we define.
  expect(server:find('function ' .. handler .. '%s*%(') ~= nil,
    'event "' .. event .. '" is registered to handler "' .. handler
      .. '", which is not defined in the server plugin')
end

-- ---------------------------------------------------------------------------
-- 5. The four build stamps must agree.
--
-- This mod ships as three separately-deployed pieces -- the server plugin is
-- copied to Resources/Server, the client zip is pushed by BeamMP, and BeamNG
-- caches UI files -- so any one of them can be older than the others. That
-- failure is silent in the worst way: Angular ignores a call to a scope function
-- a stale app.js does not have, so a button does nothing and no console
-- anywhere says a word. The stamp exists so the three can be compared at a
-- glance, which only works if they are actually kept in step.
--
-- Remembering to bump all of them has already failed once (two client-side
-- fixes shipped under one stamp, so the build line read as matching while a
-- client was a fix behind). Checking it here is cheaper than remembering.
-- ---------------------------------------------------------------------------
local appJs   = readFile('ui/modules/apps/RaceManager/app.js')
local appJson = readFile('ui/modules/apps/RaceManager/app.json')

local stamps = {
  ['server/RaceManager/main.lua']          = server:match("RM_BUILD%s*=%s*'([^']+)'"),
  ['lua/ge/extensions/raceManager.lua']    = client:match("RM_BUILD%s*=%s*'([^']+)'"),
  ['ui/modules/apps/RaceManager/app.js']   = appJs:match("APP_BUILD%s*=%s*'([^']+)'"),
  ['ui/modules/apps/RaceManager/app.json'] = appJson:match('"version"%s*:%s*"([^"]+)"'),
}

local reference, referenceFrom = nil, nil
for where, stamp in pairs(stamps) do
  expect(stamp ~= nil, 'found a build stamp in ' .. where)
  if stamp and not reference then reference, referenceFrom = stamp, where end
end
for where, stamp in pairs(stamps) do
  expect(stamp == reference,
    where .. ' is stamped "' .. tostring(stamp) .. '" but ' .. tostring(referenceFrom)
      .. ' is "' .. tostring(reference) .. '" -- the pieces are deployed '
      .. 'separately, and a stamp that disagrees is exactly the mismatch it '
      .. 'exists to make visible')
end

-- The stamp is the released package version, so it has to look like one: the
-- git tag the package is published under is this with a "v" in front.
expect(reference ~= nil and reference:match('^%d+%.%d+%.%d+$') ~= nil,
  'the build stamp is a plain semver ("' .. tostring(reference)
    .. '"), matching the release tag it ships under')

-- ---------------------------------------------------------------------------
-- NO ENTRY POINT MAY BE DEFINED TWICE, IN ANY LAYER
-- ---------------------------------------------------------------------------
-- Defining the same name twice is last-one-wins in both Lua and JavaScript, and
-- it is completely silent: no error, no console line, nothing in any log. The
-- button still works. It just runs somebody else's function.
--
-- This cost two rounds of testing on one bug. The Start Grid tab's start-position
-- generator was called `generateGrid` -- a name already used, further down each
-- file, by the admin control that FORMS THE RACE GRID and holds the field for a
-- countdown. So pressing Generate in the editor started the race. It was renamed
-- in app.js first, which fixed nothing, BECAUSE THE COLLISION EXISTED IN BOTH
-- LAYERS and only one had been looked at.
--
-- That is the lesson this check encodes: an entry point is a name in three
-- files, and finding a collision in one of them says nothing about the others.
-- All three are swept here, together, for exactly that reason.
local function noDupes(label, source, pattern)
  local seen, dupes = {}, {}
  for name in source:gmatch(pattern) do
    if seen[name] then dupes[#dupes + 1] = name else seen[name] = true end
  end
  expect(#dupes == 0, label .. ' defines these more than once, so the later '
    .. 'definition silently replaces the earlier: ' .. table.concat(dupes, ', '))
end

noDupes('the client bridge (M.*)',      client, '\nfunction M%.([%a_][%w_]*)')
noDupes('the server plugin (RM_* globals)', server, '\nfunction (RM_[%a_][%w_]*)')
noDupes('the UI app ($scope handlers)', ui,     '%$scope%.([%a_][%w_]*)%s*=%s*function')

if fails == 0 then
  print('wiring_test: ' .. checks .. ' checks, 0 failures')
else
  print('wiring_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
