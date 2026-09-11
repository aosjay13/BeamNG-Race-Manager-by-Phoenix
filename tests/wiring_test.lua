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

-- The plugin is more than its entry point now: the demo derby and the drag
-- ladder are required siblings, and between them they define every RM_Derby*
-- and RM_Drag* handler registered below. Registration is BY STRING, so a handler living in another file is
-- resolved identically at fire time -- but a check that only reads main.lua
-- would call every one of them missing.
--
-- Concatenated rather than searched file by file, because the question this
-- test asks is "does a global by this name exist anywhere in the plugin", and
-- that is exactly what BeamMP asks when the event fires.
local serverModules = { 'derby', 'drag' }
local plugin = server
for _, m in ipairs(serverModules) do
  plugin = plugin .. readFile('server/RaceManager/' .. m .. '.lua')
end
local client = readFile('lua/ge/extensions/raceManager.lua')
local ui     = readFile('ui/modules/apps/RaceManager/app.js')

-- The client modules, for the export check further down. Read separately from
-- `client` because what they prove is different: a name reaches the UI either
-- because raceManager.lua defines it, or because it is MERGED onto M from one
-- of these -- and the merge is a quoted string in a list, which on its own
-- proves nothing about whether the module actually has the function.
local clientModules = {}
for _, m in ipairs({ 'derby', 'drag', 'render' }) do
  clientModules[#clientModules + 1] = readFile('lua/ge/extensions/raceManager/' .. m .. '.lua')
end

-- Everything the server plugin registers a handler for.
local registered = {}
for name in plugin:gmatch("MP%.RegisterEvent%s*%(%s*'([%w_]+)'") do
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
for name in plugin:gmatch("MP%.CreateEventTimer%s*%(%s*'([%w_]+)'") do
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
for name in plugin:gmatch("MP%.TriggerClientEvent%s*%([^,]+,%s*'([%w_]+)'") do
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
for event, handler in plugin:gmatch("MP%.RegisterEvent%s*%(%s*'[%w_]+'%s*,%s*'([%w_]+)'()") do
  local _ = handler
end
for event, handler in plugin:gmatch("MP%.RegisterEvent%s*%(%s*'([%w_]+)'%s*,%s*'([%w_]+)'") do
  -- Our own handlers are global functions defined in this file. BeamMP's base
  -- hooks (onPlayerJoin and friends) are ours too -- every name we register
  -- points at a function we define.
  expect(plugin:find('function ' .. handler .. '%s*%(') ~= nil,
    'event "' .. event .. '" is registered to handler "' .. handler
      .. '", which is not defined in the server plugin (main.lua or a module)')
end

-- ---------------------------------------------------------------------------
-- 5. The five build stamps must agree.
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

-- FIVE places, not four. tools/deploy.py names the release zip after the
-- version too, and being outside the mod it was outside this check -- so the
-- build was already once produced as RaceManager-v0.9.0.zip from a 0.9.1 tree.
-- A zip whose name disagrees with the stamp inside it is exactly the confusion
-- the stamp exists to prevent.
local stamps = {
  ['tools/deploy.py']                      =
    readFile('tools/deploy.py'):match("RELEASE_NAME%s*=%s*'RaceManager%-v([^']+)%.zip'"),
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

-- ---------------------------------------------------------------------------
-- A module init may not take a REASSIGNED host table by reference
-- ---------------------------------------------------------------------------
-- The client modules are handed pieces of the extension's state through
-- init(host). Tables go by reference so both halves see the same object -- but
-- that only holds for a table the extension CLEARS IN PLACE. A field the
-- extension REASSIGNS (`track.startPositions = starts`) leaves the module
-- holding the old object forever, and nothing about that is visible at the
-- call site: the two lines look identical.
--
-- It has now cost two bugs. `track.route` is reassigned when a layout loads,
-- which was caught while writing the drag module. `track.startPositions` is
-- reassigned by the same path, which was NOT caught -- it was passed by
-- reference under a comment asserting the opposite, and every car staged for a
-- drag pass was placed against the empty table the mod booted with. The
-- symptom is "Start position 1 is not placed on this track" on a track that
-- plainly has one, which sends you looking at the editor.
--
-- So the compiler cannot see it and a reviewer reads past it: this is the only
-- thing that catches it. A reassigned field must be passed as a GETTER
-- (`field = function () return track.x end`), which is resolved at call time
-- and therefore always current.
do
  -- Which `track` fields does the extension reassign? A bare `track.x = ` at
  -- the start of a statement. Comparisons (`==`) are excluded by requiring a
  -- single `=`, and `track.x.y = ` by requiring the name to end at the space.
  local reassigned = {}
  -- A newline, optional indent, then `track.x = `. Anchored on the line
  -- start so `race.track.x` and a comment mentioning one do not count.
  for name in client:gmatch('\n%s*track%.([%a_][%w_]*)%s*=[^=]') do
    reassigned[name] = true
  end
  expect(reassigned.route ~= nil,
    'found the reassignment sites (route is one of them)')
  expect(reassigned.startPositions ~= nil,
    'and startPositions, the field this check exists for')

  -- Now every `x = track.y,` inside a MODULE INIT CALL, and only those.
  --
  -- Scoped to the init blocks on purpose. The same line shape appears all over
  -- this file in payload tables -- `pushRouteState` builds one every frame --
  -- and there it is correct: a payload is a snapshot being sent somewhere, not
  -- a reference somebody keeps. Flagging those would bury the real finding in
  -- noise, and a lint with noise in it gets switched off.
  local scanned, passed, mentions = 0, 0, 0
  for body in client:gmatch('%.init%((%b{})%)') do
    scanned = scanned + 1
    for _ in body:gmatch('track%.') do mentions = mentions + 1 end
    for field in body:gmatch('=%s*track%.([%a_][%w_]*)%s*,') do
      passed = passed + 1
      expect(not reassigned[field],
        'a module init is handed track.' .. field .. ' BY REFERENCE, and the '
          .. 'extension reassigns it, so the module holds the old table for '
          .. 'ever. Pass a getter instead: function () return track.'
          .. field .. ' end')
    end
  end
  expect(scanned >= 3, 'found the module init calls (got ' .. scanned .. ')')
  -- ZERO BY-REFERENCE FIELDS IS THE GOAL, not a broken scan, so the sanity
  -- check is that the init blocks mention `track` at all. Without it a rename
  -- of that local would leave this passing while checking nothing -- and every
  -- field would be flagged clean because none of them matched the pattern any
  -- more. `passed` is reported so the number is visible when it is not zero.
  expect(mentions > 0, 'the init blocks still take track state (got '
    .. mentions .. ' mention(s), ' .. passed .. ' of them by reference)')
end

-- ---------------------------------------------------------------------------
-- Every raceManager.x() the UI calls actually exists on the extension
-- ---------------------------------------------------------------------------
-- The UI reaches Lua through bngApi.engineLua('raceManager.thing()'), which is
-- a STRING. Nothing checks it: a typo, a renamed function or a module whose
-- entry points were never merged onto M all fail the same silent way -- the
-- button does nothing, no console says why, and it looks like a server problem.
--
-- A name counts as exported three ways, and all three are real:
--   * `function M.name` or `M.name =` in the extension itself
--   * merged from a module: the extension names it as a quoted string in one of
--     the `M[name] = mod[name]` lists, AND a module defines it
-- The second half of that pair is what makes this worth running: a merge list
-- entry with no function behind it is exactly as dead as a typo, and reads as
-- correct.
do
  local wanted, seen = {}, {}
  for name in ui:gmatch("raceManager%.([%a][%w_]*)%s*%(") do
    if not seen[name] then seen[name] = true; wanted[#wanted + 1] = name end
  end
  expect(#wanted > 20, 'found the UI calls into the extension (got ' .. #wanted .. ')')
  for _, name in ipairs(wanted) do
    local direct = client:find('function M%.' .. name .. '%s*%(') ~= nil
                or client:find('M%.' .. name .. '%s*=') ~= nil
    local merged = false
    if not direct and client:find("'" .. name .. "'", 1, true) then
      for _, mod in ipairs(clientModules) do
        if mod:find('function D%.' .. name .. '%s*%(') ~= nil
           or mod:find('D%.' .. name .. '%s*=') ~= nil then
          merged = true
          break
        end
      end
    end
    expect(direct or merged,
      'the UI calls raceManager.' .. name .. '(), which nothing on the extension '
        .. 'defines or merges onto M: that button does nothing and says nothing')
  end
end

if fails == 0 then
  print('wiring_test: ' .. checks .. ' checks, 0 failures')
else
  print('wiring_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
