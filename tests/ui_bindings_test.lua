-- Static check of the Race Manager UI app's two-way bindings
-- (ui/modules/apps/RaceManager/app.html + app.js).
--
-- Why this exists: every control in the app sits inside an `ng-if` (the admin
-- panels, the editor, the derby panel, the driver bar), and an ng-if creates a
-- CHILD scope. AngularJS resolves reads up the prototype chain but writes land
-- on the child, so `ng-model="lapsInput"` makes the typed value shadow the
-- controller's own `lapsInput`: the "Set" button then posts the stale default
-- to the server, and the server's echo back updates a property the visible
-- input no longer reads. That is exactly how the Laps and Max-resets fields
-- broke - the server console logged a change, the panel kept showing the
-- default. Binding through an object (`settingsUi.laps`) resolves the object on
-- the controller scope and mutates it in place, so both directions work.
--
-- The rule this file enforces: every ng-model path in the template contains a
-- dot, and the object it hangs off is initialised in the controller.
-- Run from the repo root: lua5.3 tests/ui_bindings_test.lua

local fails, checks = 0, 0
local function expect(cond, msg)
  checks = checks + 1
  if not cond then
    fails = fails + 1
    print('FAIL: ' .. msg)
  end
end

-- A CSS rule at the top level of the sheet starts on its own line with two
-- spaces. Anchoring on that matters: `%.rm%-driverbar {` also matches the tail
-- of `.rm-minimal .rm-driverbar {`, which appears FIRST in the stylesheet -- so
-- an unanchored pattern silently reads the mode override instead of the base
-- rule, and a check on the base rule passes or fails for the wrong reason.
local NL = string.char(10)

local function readFile(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local s = f:read('*a')
  f:close()
  return s
end

local html = readFile('ui/modules/apps/RaceManager/app.html')
local js   = readFile('ui/modules/apps/RaceManager/app.js')

-- ---------------------------------------------------------------------------
-- 1. Every ng-model binds through an object ("always have a dot")
-- ---------------------------------------------------------------------------
local models, roots = {}, {}
for path in html:gmatch('ng%-model%s*=%s*"([^"]+)"') do
  models[#models + 1] = path
  local root = path:match('^([%w_$]+)%.')
  expect(root ~= nil,
    'ng-model="' .. path .. '" is a bare primitive: an ng-if child scope will '
      .. 'shadow it, so the control edits a copy nobody reads')
  if root then roots[root] = true end
end
expect(#models > 0, 'found ng-model bindings to check in app.html')

-- ---------------------------------------------------------------------------
-- 2. Every object a control binds through is initialised on the controller
--    scope (otherwise the first keystroke auto-creates it on the child scope,
--    which reintroduces the same shadowing).
-- ---------------------------------------------------------------------------
for root in pairs(roots) do
  expect(js:find('$scope.' .. root .. ' = {', 1, true) ~= nil,
    '$scope.' .. root .. ' is never initialised as an object in app.js')
end

-- ---------------------------------------------------------------------------
-- 3. The race settings specifically: template, command handler and the
--    server-state handler must all name the same path, or the round trip
--    (type -> Set -> server -> echo -> input) breaks at whichever end differs.
-- ---------------------------------------------------------------------------
local function bound(path)
  return html:find('ng%-model%s*=%s*"' .. path:gsub('%.', '%%.') .. '"') ~= nil
end

expect(bound('settingsUi.laps'),   'Laps input binds settingsUi.laps')
expect(bound('settingsUi.resets'), 'Max resets input binds settingsUi.resets')
-- No global gate width/height any more. They bound a single setting that every
-- gate without an override read LIVE, so nudging a slider resized the whole
-- circuit retroactively with nothing to undo it. A gate takes its size when it
-- is placed, inherits it from the gate before, and is edited on its own row.
expect(not bound('settingsUi.width'),
  'there is no global Gate width control: resizing one gate must not move others')
expect(not bound('settingsUi.height'), 'and no global Gate height control')
expect(bound('cpEdit.width') and bound('cpEdit.height'),
  'gate size is edited on the gate itself')
expect(bound('settingsUi.qualiLaps'), 'Quali lap limit input binds settingsUi.qualiLaps')
expect(bound('settingsUi.qualiMins'), 'Quali time limit input binds settingsUi.qualiMins')

-- ...and they are never both on screen. A qualifying session runs to a lap
-- allowance OR to a clock; the server holds both numbers and treats 0 as
-- unlimited, so both at once is a state it can hold, and two boxes side by side
-- is how it gets armed by accident.
do
  expect(html:find("setQualiLimitMode('laps')", 1, true) ~= nil
    and html:find("setQualiLimitMode('timed')", 1, true) ~= nil,
    'the panel offers a Laps / Timed choice for the qualifying session length')
  local gated = {
    laps  = { model = 'settingsUi.qualiLaps', what = 'lap allowance' },
    timed = { model = 'settingsUi.qualiMins', what = 'time limit' },
  }
  for mode, g in pairs(gated) do
    local block = html:match('ng%-if="isQualiLimitMode%(\'' .. mode .. '\'%)"(.-)</span>')
    expect(block ~= nil and block:find(g.model, 1, true) ~= nil,
      'the ' .. g.what .. ' input is not inside the ' .. mode .. ' mode block')
    -- One input, and it is that one: a second copy anywhere else in the
    -- template would render alongside it and both would be on screen again.
    local _, n = html:gsub('ng%-model="' .. g.model:gsub('%.', '%%.') .. '"', '')
    expect(n == 1,
      'expected exactly one ' .. g.model .. ' input (found ' .. n .. ')')
  end
  -- The mode that is not in use has to be sent as 0, or switching the toggle
  -- leaves the old limit armed under a panel that no longer shows it.
  local push = js:match('function pushQualiLimits%(%)(.-)\n%s*}')
  expect(push ~= nil, 'found pushQualiLimits in the controller')
  expect(push ~= nil and push:find("=== 'laps'", 1, true) ~= nil
    and push:find("=== 'timed'", 1, true) ~= nil,
    'pushQualiLimits sends both numbers unconditionally, so the limit the '
      .. 'panel is not showing stays armed on the server')
end
expect(bound('derbyUi.name'),      'Derby arena name input binds derbyUi.name')
expect(bound('lbUi.opacity'),      'Leaderboard opacity slider binds lbUi.opacity')

-- DEPTH IS BACK, meaning something new. The field that was removed was a third
-- box dimension from when a gate was a volume. This one is the other half of the
-- vertical: height is how far a gate rises above the point it was placed at,
-- depth how far it drops below, so a gate can be tall enough to see without an
-- equal amount of it buried under the road.
expect(html:find('cpEdit.depth', 1, true) ~= nil,
  'a gate can be given its own depth')
expect(js:find('cpEdit.depth', 1, true) ~= nil,
  'and the controller reads it')

-- Both ends of the override travel together. A gate carrying a height and NO
-- depth is read as a legacy full-span gate and split in half, so sending one
-- without the other would silently reinterpret the number the admin just typed.
local ovr = js:match('%$scope%.applyCheckpointOverride = function %(%)(.-)\n%s*};')
expect(ovr ~= nil, 'applyCheckpointOverride found')
expect(ovr and ovr:find('cpEdit.depth', 1, true) ~= nil,
  'applyCheckpointOverride sends depth alongside width and height, never alone')

-- UI -> server: the apply handlers read the value the inputs actually write.
expect(js:find('$scope.settingsUi.laps', 1, true) ~= nil,
  'applyTotalLaps reads settingsUi.laps')
expect(js:find('$scope.settingsUi.resets', 1, true) ~= nil,
  'applyMaxResets reads settingsUi.resets')

-- ---------------------------------------------------------------------------
-- 3b. The session settings apply themselves, and they debounce
--
-- They used to sit behind a Set button, and forgetting to press it is a silent
-- failure that surfaces as the wrong race distance. They now apply on change --
-- which is only safe with a debounce: without one, typing "125" sends 1, then
-- 12, then 125, and each of those is a setting the server really applied and
-- really broadcast to every client on the way past.
-- ---------------------------------------------------------------------------
do
  local applying = 0
  for tag in html:gmatch('<input[^>]->') do
    if tag:find('ng%-change=') and tag:find('ng%-model="settingsUi%.') then
      applying = applying + 1
      local field = tag:match('ng%-model="(settingsUi%.[%w_]+)"') or '?'
      expect(tag:find('ng%-model%-options=') ~= nil and tag:find('debounce', 1, true) ~= nil,
        field .. ' applies on change with no debounce: every keystroke would be '
          .. 'a separate setting, applied and broadcast')
      -- blur has to commit immediately, or clicking away from a box leaves the
      -- typed value sitting there unapplied -- the same failure as the button.
      expect(tag:find('blur', 1, true) ~= nil,
        field .. ' debounces without a blur:0 rule, so leaving the field does '
          .. 'not commit what was typed')
    end
  end
  expect(applying >= 4,
    'expected the laps, resets and both qualifying inputs to apply themselves '
      .. '(found ' .. applying .. ')')
  -- ...and the buttons they replaced are gone, or the panel still teaches that
  -- a typed number does nothing until something is pressed.
  for _, fn in ipairs({ 'applyTotalLaps', 'applyMaxResets', 'applyQualiLimits' }) do
    expect(html:find('ng%-click="' .. fn .. '%(%)"') == nil,
      fn .. ' is still on a button: the field applies itself now, and a Set '
        .. 'button beside it says otherwise')
  end
end

-- server -> UI: the state broadcast re-seeds the same inputs, so a clamped or
-- another admin's value shows up in the panel.
expect(js:find('$scope.settingsUi.laps = data.totalLaps', 1, true) ~= nil,
  'RaceManagerUpdate re-seeds settingsUi.laps from the server totalLaps')
expect(js:find('$scope.settingsUi.resets = data.maxResets', 1, true) ~= nil,
  'RaceManagerUpdate re-seeds settingsUi.resets from the server maxResets')

-- The displayed values stay read-only mirrors of the server state.
expect(html:find('{{ totalLaps }}', 1, true) ~= nil,
  'the Laps row still displays the authoritative totalLaps')
expect(js:find('$scope.totalLaps = data.totalLaps', 1, true) ~= nil,
  'totalLaps is mirrored from the server broadcast')
expect(js:find('$scope.maxResets = data.maxResets', 1, true) ~= nil,
  'maxResets is mirrored from the server broadcast')

-- ---------------------------------------------------------------------------
-- 4. Race entry, the starting grid and the qualifying rules are wired end to
--    end: a control in the template, a handler that sends the command, and a
--    server field the state handler mirrors back.
-- ---------------------------------------------------------------------------
local function wired(command, handler, msg)
  expect(html:find(handler .. '(', 1, true) ~= nil, msg .. ': template calls ' .. handler)
  expect(js:find('raceManager.' .. command, 1, true) ~= nil,
    msg .. ': the handler sends raceManager.' .. command)
end

wired('setSpectating',      'setSpectating',      'Sit out / rejoin')
wired('setGridMode',        'setGridMode',        'Grid order')
wired('setDriverGridSlot',  'pinGridSlot',        'Custom grid slot')
wired('setGhostQuali',      'toggleGhostQuali',   'Ghost qualifying')
-- NO HANDLER MAY BE DEFINED TWICE ON $scope.
--
-- Assigning the same key twice is last-one-wins and silent: no error, no console
-- line, nothing in any log. The button keeps working, it just runs somebody
-- else's function.
--
-- This has already happened once and it was expensive. The Start Grid tab's
-- "Generate" button was written as $scope.generateGrid -- a name this file
-- already used, further down, for the admin control that FORMS THE RACE GRID.
-- The later definition won, so pressing Generate in the editor teleported the
-- admin onto a grid slot and froze them there for a countdown, and placed no
-- start positions at all. The symptom pointed at the editor; the cause was a
-- name three hundred lines away.
--
-- State fields are exempt: `$scope.drivers = []` at init and `$scope.drivers =
-- data.drivers` in the broadcast handler is the normal shape of every mirror in
-- this file. Only FUNCTIONS are checked, because only a function is a behaviour
-- that can be silently replaced by a different one.
do
  local seen, dupes = {}, {}
  for name in js:gmatch('%$scope%.([%a_][%w_]*)%s*=%s*function') do
    if seen[name] then dupes[#dupes + 1] = name else seen[name] = true end
  end
  expect(#dupes == 0,
    'these $scope handlers are defined more than once, so the later one silently '
      .. 'replaces the earlier: ' .. table.concat(dupes, ', '))
end

-- THE COLLAPSED HUD MUST ALWAYS BE ABLE TO UNCOLLAPSE ITSELF.
--
-- Collapsing hides every direct child of .rm-root except a short keep-list. If
-- the bar carrying the toggle is not on that list, pressing it once hides the
-- app AND the only control that brings it back -- and the way out is the game's
-- app editor, which nobody reading a leaderboard is going to guess at.
--
-- Exactly one of the two bars renders at a time: the header is ng-if
-- !minimalMode() and the driver bar is ng-if minimalMode(), which are exact
-- complements. So BOTH have to carry the toggle and BOTH have to survive the
-- collapse, or the half of the time the other one is showing is unrecoverable.
do
  local rule = html:match('%.rm%-collapsed%s*>%s*%*([^{]*){')
  expect(rule ~= nil, 'found the .rm-collapsed hide rule')
  for _, keep in ipairs({ 'rm-header', 'rm-driverbar' }) do
    expect(rule ~= nil and rule:find(':not(.' .. keep .. ')', 1, true) ~= nil,
      'collapsing must not hide .' .. keep .. ' - it carries the button that '
        .. 'brings the app back')
  end
  -- The alerts are the app telling a driver something is happening to them, not
  -- panels they went looking for. A countdown nobody can see is a race start
  -- nobody can see.
  for _, keep in ipairs({ 'rm-countdown', 'rm-vehicle-error', 'rm-notice',
                          'rm-derby-warning', 'rm-spectator-bar' }) do
    expect(rule ~= nil and rule:find(':not(.' .. keep .. ')', 1, true) ~= nil,
      '.' .. keep .. ' must survive a collapse: it is an alert, not a panel')
  end
  -- And the toggle itself has to exist in both bars.
  local header = html:match('<div class="rm%-header".-\n  </div>')
  local bar    = html:match('<div class="rm%-driverbar".-\n  </div>')
  expect(header ~= nil and header:find('toggleCollapsed()', 1, true) ~= nil,
    'the header carries the collapse toggle')
  expect(bar ~= nil and bar:find('toggleCollapsed()', 1, true) ~= nil,
    'the driver bar carries the collapse toggle, for a driver mid-session')
  expect(js:find('$scope.toggleCollapsed', 1, true) ~= nil,
    'toggleCollapsed is defined in the app')
end

-- THERE IS ALWAYS A WAY BACK IN.
--
-- minimalMode() is "not an admin AND a session is live", and it strips the app
-- down to the leaderboard for the length of that session. The lock button that
-- opens the admin login lives in the driver bar, which only EXISTS in minimal
-- mode -- so if the login panel is also gated on `!minimalMode()`, pressing it
-- sets a flag nothing renders. That shipped: an admin who lost their session
-- could not log back in to stop the race they were running, for as long as it
-- ran, with no other way in.
--
-- Logging in clears minimal mode on its own (isAdmin goes true), so the panel
-- only has to be REACHABLE.
do
  local login = html:match('<div class="rm%-login"[^>]*>')
  expect(login ~= nil, 'found the admin login panel')
  expect(login ~= nil and login:find('showLogin', 1, true) ~= nil,
    'the login panel is opened by showLogin')
  expect(login ~= nil and login:find('minimalMode', 1, true) == nil,
    'the login panel is NOT hidden by minimal mode: the button that opens it is '
      .. 'in the driver bar, which only exists in that mode')
  -- CLOSED until asked for. It used to open itself, which was survivable only
  -- because it was ALSO suppressed for the whole of a live session -- two wrongs
  -- cancelling. With that suppression gone (it was the dead end above) an
  -- auto-opening prompt lands over the top of a race instead.
  expect(js:find('$scope.showLogin = false', 1, true) ~= nil,
    'the login prompt starts closed: it is something you go and get')

  -- ...and the button really is in the bar, so the two halves stay together.
  local bar = html:match('<div class="rm%-driverbar".-</div>')
  expect(bar ~= nil and bar:find('openLogin()', 1, true) ~= nil,
    'the driver bar carries the login button')
end

-- Every grid order the panel offers must be one the server accepts. A button-- Every grid order the panel offers must be one the server accepts. A button
-- for a mode its validator drops is a dead button: the panel un-highlights the
-- old mode, the server keeps it, and the next broadcast puts it back.
do
  local modes = {}
  for mode in html:gmatch("setGridMode%('([%w_]+)'%)") do modes[mode] = true end
  expect(modes.quali and modes.reverse and modes.random and modes.custom,
    'the panel offers Quali, Reverse, Random and Custom grid orders')
  local validator = readFile('server/RaceManager/main.lua')
    :match('function RM_onSetGridMode.-\n(.-)\nend')
  expect(validator ~= nil, 'found RM_onSetGridMode in the server plugin')
  for mode in pairs(modes) do
    expect(validator ~= nil and validator:find("'" .. mode .. "'", 1, true) ~= nil,
      'the panel offers the "' .. mode .. '" grid order but RM_onSetGridMode '
        .. 'never names it, so pressing it changes nothing')
  end
  -- ...and so must the CLIENT RELAY between them, which is where this went
  -- wrong. Checking the panel against the server skipped the one layer in the
  -- middle: M.setGridMode normalises anything it does not recognise back to
  -- 'quali', so Reverse -- a mode both ends knew about -- was rewritten on the
  -- way out and the panel lit Quali up instead. Every hop has to name the mode,
  -- not just the two ends.
  local relay = readFile('lua/ge/extensions/raceManager.lua')
    :match('function M%.setGridMode.-\n(.-)\nend')
  expect(relay ~= nil, 'found M.setGridMode in the client bridge')
  for mode in pairs(modes) do
    expect(relay ~= nil and relay:find("'" .. mode .. "'", 1, true) ~= nil,
      'the panel offers the "' .. mode .. '" grid order but M.setGridMode never '
        .. 'names it, so the client rewrites it before the server ever sees it')
  end
end
wired('setQualiLimits',     'applyQualiLimits',   'Qualifying limits')
wired('moveStartPosition',  'moveStartPosition',  'Move start position')
wired('removeStartPosition','removeStartPosition','Remove start position')
wired('derbySaveLayout',    'derbySaveLayout',    'Derby arena save')
wired('derbyLoadLayout',    'derbyLoadLayout',    'Derby arena load')
-- The derby arena is editable entry by entry, the same way the race grid is.
wired('derbyMoveMarker',        'derbyMoveMarker',   'Move derby boundary marker')
wired('derbyRemoveMarker',      'derbyRemoveMarker', 'Remove derby boundary marker')
wired('derbyMoveStartPosition', 'derbyMoveStart',    'Move derby start position')
wired('derbyRemoveStartPosition', 'derbyRemoveStart','Remove derby start position')
-- The rectangle arena editor: a centre, and sliders for the rest.
wired('derbySetBoundaryMode', 'derbySetBoundaryMode', 'Derby boundary mode')
wired('derbySetShapeCenter',  'derbySetShapeCenter',  'Derby rectangle centre')
wired('derbySetShape',        'derbyApplyShape',      'Derby rectangle size')
wired('derbySetShape',        'derbyApplyWallHeight', 'Derby wall height')

-- The lists themselves render the arrays the derby broadcast carries, not just
-- the counts the header shows: a panel bound to `boundaryCount` alone can say
-- "7 markers" and still offer nothing to click.
for _, field in ipairs({ 'boundary', 'startPositions' }) do
  expect(html:find('derby.' .. field .. '.length', 1, true) ~= nil,
    'the derby panel lists derby.' .. field)
  expect(js:find('$scope.derby.' .. field .. ' = toArray(data.' .. field .. ')', 1, true) ~= nil,
    'derby.' .. field .. ' is mirrored from the derby broadcast')
end

-- Every one of those edit controls is refused by the server from form-up
-- onward, so the template must not offer them then either.
for _, handler in ipairs({ 'derbyMoveMarker', 'derbyRemoveMarker', 'derbyPreviewMarker',
                           'derbyMoveStart', 'derbyRemoveStart', 'derbyPreviewStart' }) do
  local call = html:match('ng%-click="' .. handler .. '%([^"]*%)"[^>]-ng%-disabled="([^"]*)"')
  expect(call ~= nil and call:find('derbyActive()', 1, true) ~= nil,
    handler .. ' is not disabled by derbyActive(), so the panel offers an edit '
      .. 'the server will refuse while a derby is under way')
end

-- The rectangle's sliders are refused from form-up onward too: the arena cannot
-- be resized under a field already standing on its grid, and a slider that
-- moves while the server ignores it is worse than one that will not move.
for _, handler in ipairs({ 'derbyApplyShape', 'derbyApplyWallHeight' }) do
  local n = 0
  for disabled in html:gmatch('ng%-change="' .. handler .. '%(%)"%s*ng%-disabled="([^"]*)"') do
    n = n + 1
    expect(disabled:find('derbyActive()', 1, true) ~= nil,
      handler .. ' has a control that is not disabled by derbyActive()')
  end
  expect(n > 0, handler .. ' is not bound to any control')
end

-- The arena's own state has to come back off the broadcast, or the panel drifts
-- from what every other client is drawing: which editor is in use, the
-- rectangle itself, and how tall its walls are.
for _, field in ipairs({ 'gridMode', 'ghostQuali', 'startSlots',
                         'boundaryMode', 'shape', 'wallHeight' }) do
  expect(js:find('data.' .. field, 1, true) ~= nil,
    field .. ' is mirrored from the server broadcast')
end

-- ---------------------------------------------------------------------------
-- 4a2. The qualifying out lap is SHOWN, not just enforced
--
-- The rule is worth nothing to a driver who cannot tell it is in force: a lap
-- clock ticking away on a lap that is not being timed is worse than no readout
-- at all, because it is a number they will drive to. So the app has to render
-- the out lap as a state, and must never render a time in its place.
-- ---------------------------------------------------------------------------
expect(js:find('data.qualiOutLap', 1, true) ~= nil,
  'the out-lap rule is mirrored from the server broadcast')
for _, fn in ipairs({ 'onOutLap', 'outLapDone' }) do
  expect(html:find(fn .. '()', 1, true) ~= nil and js:find('$scope.' .. fn, 1, true) ~= nil,
    'the template calls ' .. fn .. '() and the controller defines it - an '
      .. 'undefined one is not an error in Angular, it is a readout that '
      .. 'silently never appears')
end
expect(html:find('showOutLap(row)', 1, true) ~= nil
  and js:find('$scope.showOutLap', 1, true) ~= nil,
  'the qualifying table shows which drivers are still on their out lap')
-- ...and only for drivers who are actually in the session. The server's flag
-- stays set on a driver who withdrew or was taken by the grace timeout - they
-- never completed one - so a row announcing an out lap beside a status of DNF
-- is what this guards against.
do
  local body = js:match('%$scope%.showOutLap = function %(row%)(.-)\n%s*};')
  expect(body ~= nil, 'found showOutLap in the controller')
  expect(body ~= nil and body:find("'qualifying'", 1, true) ~= nil
    and body:find("'gridded'", 1, true) ~= nil,
    'showOutLap does not check the driver is still in the session')
end

-- The live clock and the out-lap label share one slot. Both rendering at once
-- is the failure this prevents, and it is invisible until a qualifying session
-- is actually running in the game.
do
  local live = 0
  for cond in html:gmatch('class="rm%-laptime%-live"%s+ng%-if="([^"]*)"') do
    live = live + 1
    expect(cond:find('!onOutLap()', 1, true) ~= nil,
      'a live lap clock renders without excluding the out lap, so a driver on '
        .. 'an untimed lap is shown a running time: ' .. cond)
  end
  expect(live >= 2, 'found the lap clock in both the header and the driver bar '
    .. '(found ' .. live .. ')')

  -- ...and the out-lap slot itself must not format a lap time into the gap.
  for block in html:gmatch('class="rm%-laptime%-out"(.-)</span>') do
    expect(block:find('formatLap', 1, true) == nil,
      'the out-lap readout renders a lap time, which is exactly the number that '
        .. 'lap does not have')
  end
end

-- ---------------------------------------------------------------------------
-- 4b. Cup / series points
--
-- The cup panel is entirely server-driven: it renders standings it is sent and
-- posts the admin's edits back, and it must never compute a total of its own.
-- The wiring below is what makes that round trip real rather than intended.
-- ---------------------------------------------------------------------------
expect(bound('cupUi.name'), 'the cup name input binds cupUi.name')
expect(html:find('ng%-model="cupUi%.points%[%$index%]"') ~= nil,
  'the race points editor binds cupUi.points by index')
expect(html:find('ng%-model="cupUi%.quali%[%$index%]"') ~= nil,
  'the quali points editor binds cupUi.quali by index')
expect(html:find('ng%-model="cupUi%.bonus%[b%.key%]"') ~= nil,
  'each bonus row binds cupUi.bonus by its registry key')

wired('cupStart',              'cupStart',          'Start cup')
wired('cupReset',              'cupReset',          'End cup')
wired('cupSetEnabled',         'cupToggleEnabled',  'Pause/resume scoring')
wired('cupSetPreset',          'cupApplyPreset',    'Scoring preset')
wired('cupSetRacePoints',      'cupApplyPoints',    'Race points table')
wired('cupSetQualiPoints',     'cupApplyQuali',     'Quali points table')
wired('cupSetBonus',           'cupApplyBonus',     'Bonus value')
wired('cupSetFastestLapRule',  'cupToggleFlRule',   'Fastest lap rule')

-- Ending a cup destroys a season of points, so it must not be a single click.
expect(html:find('cupAskReset()', 1, true) ~= nil and html:find('cupCancelReset()', 1, true) ~= nil,
  'End Cup is behind a confirmation step, not a bare button')

-- ---------------------------------------------------------------------------
-- 4d2. Every irreversible control is behind a confirmation
--
-- Two controls in this app destroy something no undo can bring back: End Cup
-- deletes a season of points, and Clear Results Cache deletes every saved
-- results file -- which, once a session is over, is the only record a league
-- has that the race happened. Both sit in panels an admin opens for other
-- things, one click away from a mis-aimed press.
-- ---------------------------------------------------------------------------
for _, c in ipairs({
  { ask = 'cupAskReset',     cancel = 'cupCancelReset',     go = 'cupReset',     what = 'End Cup' },
  { ask = 'askClearResults', cancel = 'cancelClearResults', go = 'clearResults', what = 'Clear Results Cache' },
}) do
  for _, fn in ipairs({ c.ask, c.cancel, c.go }) do
    expect(html:find(fn .. '()', 1, true) ~= nil,
      c.what .. ': the template has no ' .. fn .. '() control')
    expect(js:find('$scope.' .. fn .. ' ', 1, true) ~= nil
      or js:find('$scope.' .. fn .. '=', 1, true) ~= nil,
      c.what .. ': ' .. fn .. ' is not defined on the controller')
  end
  -- The destructive call must be reachable ONLY from the confirmed branch. A
  -- second bare button calling it directly would make the confirmation
  -- decorative, which is the way this protection actually gets lost.
  local _, bare = html:gsub('ng%-click="' .. c.go .. '%(%)"', '')
  expect(bare == 1,
    c.what .. ': expected exactly one control calling ' .. c.go
      .. '() (the confirmed one), found ' .. bare)
end

-- The panel renders the ARRAYS the broadcast carries, not just summary counts:
-- a standings block bound to a total alone can say "5 drivers" and list none.
expect(html:find('cup.standings.length', 1, true) ~= nil
  and html:find('s in cup.standings', 1, true) ~= nil,
  'the cup panel lists cup.standings rather than only counting it')
-- Bonus controls are generated from the server registry, filtered by the
-- discipline each bonus declares -- so a race bonus is never offered under the
-- derby table and vice versa, and a new bonus needs no template change.
expect(html:find("b in cupBonusesFor('race')", 1, true) ~= nil,
  'race bonus controls are generated from the server registry')
expect(html:find("b in cupBonusesFor('derby')", 1, true) ~= nil,
  'derby bonus controls are generated from the same registry, filtered by kind')
expect(html:find('b in cup.bonuses', 1, true) == nil,
  'no control renders the whole bonus registry ungrouped: a race bonus under '
    .. 'the derby table would offer points the server will never award')
expect(html:find('p in cup.presets', 1, true) ~= nil,
  'the preset picker is filled from the server list')

-- ---------------------------------------------------------------------------
-- 4c. Derbies score into the same cup
--
-- A cup may be all races, all derbies or a mixture. The two score on separate
-- tables and are reported separately, with a combined summary over both.
-- ---------------------------------------------------------------------------
expect(html:find('ng%-model="cupUi%.derby%[%$index%]"') ~= nil,
  'the derby points editor binds cupUi.derby by index')
wired('cupSetDerbyPoints', 'cupApplyDerby',       'Derby points table')
wired('cupSetDerbyPoints', 'cupDisableDerby',     'Derby points off')
wired('cupSetPreset',      'cupApplyDerbyPreset', 'Derby scoring preset')

-- Three views over one set of server-sent numbers.
for _, view in ipairs({ 'combined', 'race', 'derby' }) do
  expect(html:find("cupSetView('" .. view .. "')", 1, true) ~= nil,
    'the standings offer a ' .. view .. ' view')
end
expect(html:find("orderBy:'racePos'", 1, true) ~= nil
  and html:find("orderBy:'derbyPos'", 1, true) ~= nil,
  'the per-discipline tables are ordered by the position the SERVER ranked, '
    .. 'not by one the app worked out for itself')
-- The per-discipline tabs are pointless in a cup that only ever held one kind.
expect(html:find('cupIsMixed()', 1, true) ~= nil,
  'the discipline tabs only appear once the cup has held both kinds of event')

-- Race and derby totals are reported separately AND combined.
for _, field in ipairs({ 'raceTotal', 'derbyTotal', 'raceRounds', 'derbyRounds',
                         'raceWins', 'derbyWins' }) do
  expect(html:find('s.' .. field, 1, true) ~= nil,
    'the standings report ' .. field .. ', so race and derby stay separable')
end
for _, field in ipairs({ 'derbyPoints', 'derbyPreset' }) do
  expect(js:find('data.' .. field, 1, true) ~= nil,
    'cup field ' .. field .. ' is mirrored from the RaceManagerCup broadcast')
end

-- Every field the panel shows has to come off the cup broadcast, or it drifts
-- from what the server actually has.
for _, field in ipairs({ 'cupEnabled', 'cupName', 'round', 'preset', 'racePoints',
                         'qualiPoints', 'presets', 'bonuses', 'standings',
                         'pendingQuali', 'fastestLapRequiresFinish' }) do
  expect(js:find('data.' .. field, 1, true) ~= nil,
    'cup field ' .. field .. ' is mirrored from the RaceManagerCup broadcast')
end

-- The cup is reachable from Race AND Derby, and it was not always.
--
-- It began as a race-mode tab on the reasoning that a cup is a property of a
-- race night rather than a parallel game mode. That part still holds -- it is
-- not a fourth mode -- but "it has nothing to say about a derby" was wrong: a
-- derby banks a cup round exactly like a race does, there is a derby column in
-- the scoring table and derby points in every preset. An admin running an
-- evening of derbies could see none of it without switching modes.
--
-- So the panel is gated on the TAB alone. Both mode tab bars must offer the
-- button, or the tab is selectable in a mode with no way back to it.
local cupButtons = 0
for _ in html:gmatch('selectAdminTab%(\'cup\'%)') do
  cupButtons = cupButtons + 1
end
expect(cupButtons == 2,
  'both the race and derby tab bars offer a Cup button (found ' .. cupButtons .. ')')
expect(html:find('ng-if="isAdminTab(\'cup\')"', 1, true) ~= nil,
  'the cup panel is gated on the tab alone, not on the mode')
expect(html:find("isMode('race') && isAdminTab('cup')", 1, true) == nil,
  'and the old race-mode gate is gone rather than merely bypassed')
expect(js:find('derby: { derby: true, cup: true, editor: true }', 1, true) ~= nil,
  'derby mode lists cup as a selectable tab, so selectAdminTab cannot fall back')

-- ---------------------------------------------------------------------------
-- LMS / DM
-- ---------------------------------------------------------------------------
-- The mode changes which SETTINGS are offered, not which rules apply: the
-- stopped timer is the wreck detector and runs in both. Lives is the one box
-- that belongs to DM alone.
expect(html:find("derbySetMode('lms')", 1, true) ~= nil, 'there is an LMS button')
expect(html:find("derbySetMode('dm')", 1, true) ~= nil, 'and a DM button')
expect(html:find("ng-if=\"derbyUi.mode === 'dm'\"", 1, true) ~= nil,
  'the lives setting is shown for DM only')

-- The timers are NOT mode-gated, and that is the point of the whole exercise:
-- a stopped timer hidden in LMS is a derby that cannot detect a wreck.
local demoRow = html:match('<span class="rm%-setting">%s*<label>Demolished timer.-</span>')
expect(demoRow ~= nil and not demoRow:find('ng-if', 1, true),
  'the stopped timer is offered in both modes, with no ng-if hiding it')
local oobRow = html:match('<span class="rm%-setting">%s*<label>OOB timer.-</span>')
expect(oobRow ~= nil and not oobRow:find('ng-if', 1, true),
  'and so is out-of-bounds')

expect(js:find("mode: 'lms'", 1, true) ~= nil, 'the panel starts in LMS')
expect(js:find('data.derbyMode', 1, true) ~= nil,
  'and mirrors the mode from the server, which owns it')

-- NO SET RULES BUTTON. The derby settings apply as they are changed.
--
-- It was redundant -- nothing here needs staging -- and it was reported as
-- having done something it cannot do: a 'you start from P1' notice appeared on
-- pressing it. Nothing in derbyApplyConfig can place a car, and the path was
-- never found; removing the button removes the question.
expect(html:find('>Set Rules<', 1, true) == nil, 'the Set Rules button is gone')
for _, field in ipairs({ 'oob', 'demo', 'lives' }) do
  local row = html:match('ng%-model="derbyUi%.' .. field .. '".-ng%-disabled')
  expect(row ~= nil and row:find('ng-change="derbyApplyConfig()"', 1, true) ~= nil,
    'derbyUi.' .. field .. ' applies on change instead')
  -- Debounced, or typing "10" applies 1 first -- which for a timer means the
  -- floor, and for lives means a value the admin never chose.
  expect(row ~= nil and row:find('debounce', 1, true) ~= nil,
    'and is debounced, so a half-typed number is not applied')
end

-- The derby reset allowance is gone with it: resets are blocked outright for
-- the length of a derby, so a box setting how many you get would be a lie.
expect(html:find('derbyUi.resets', 1, true) == nil,
  'the derby Max resets box is gone, because there is no allowance any more')

-- ---------------------------------------------------------------------------
-- LAP AND SECTOR DELTAS
-- ---------------------------------------------------------------------------
-- GREEN IS FASTER. This is the one detail worth a test of its own: a delta is
-- read at speed, mid-corner, and a driver who has to work out which way round
-- it goes is not reading it at all. Faster means a SMALLER time, so green is
-- the negative number -- the inversion that makes it easy to write backwards.
expect(js:find("return d < 0 ? 'rm-delta-faster' : 'rm-delta-slower';", 1, true) ~= nil,
  'a negative delta (a quicker time) is the FASTER class, not the slower one')
expect(html:find('.rm-delta-faster { color: #7ee2a8; }', 1, true) ~= nil,
  'and the faster class is green')
expect(html:find('.rm-delta-slower { color: #f28b82; }', 1, true) ~= nil,
  'while the slower class is red')

-- Zero is neither. An exact tie to the thousandth is not an improvement, and
-- green would overstate it.
expect(js:find('d === 0', 1, true) ~= nil, 'a dead-level delta is left uncoloured')

-- The two readouts use DIFFERENT baselines on purpose: at the line the question
-- is "am I still improving" (against the last lap), mid-lap it is "where am I
-- losing it" (against the best for that sector).
expect(js:find('timing.prevLap', 1, true) == nil,
  'the lap baseline is held in the extension, not mirrored into the UI')
expect(html:find('Against your previous lap', 1, true) ~= nil,
  'the lap delta says it is against the previous lap')
expect(html:find('against your best for this sector', 1, true) ~= nil,
  'and the sector delta says it is against your best')

-- Both readouts can be on screen together: the final sector of a lap closes on
-- the same crossing that ends the lap.
expect(html:find('ng-if="sectorHolding()"', 1, true) ~= nil,
  'the sector readout has its own hold, independent of the lap one')
expect(js:find('cup: true', 1, true) ~= nil,
  'the cup tab is registered in MODE_TABS for race mode')

-- ---------------------------------------------------------------------------
-- 4d. Manual adjustments and the DNF rule
--
-- An admin has to be able to correct a cup by hand, and the ledger has to stay
-- visible: a total nobody can take apart is a total nobody can check.
-- ---------------------------------------------------------------------------
expect(bound('cupUi.adjustDelta') and bound('cupUi.adjustReason'),
  'the adjustment editor binds its inputs through cupUi')
wired('cupAdjust',       'cupApplyAdjust',  'Manual adjustment')
wired('cupAdjust',       'cupQuickAdjust',  'Quick adjustment')
wired('cupRemoveAdjust', 'cupRemoveAdjust', 'Remove an adjustment')

-- The ledger is rendered, not just its net total: an admin removing the wrong
-- adjustment because the panel only showed a number is the failure this avoids.
expect(html:find('a in s.adjustments', 1, true) ~= nil,
  'the adjustment ledger is listed per driver')
expect(html:find('a.reason', 1, true) ~= nil and html:find('a.by', 1, true) ~= nil,
  'each adjustment shows what it was for and who made it')
expect(js:find('$scope.cup.standings = toArray(data.standings)', 1, true) ~= nil,
  'standings (and the ledger they carry) come from the server')

-- A DNF is not always a nil score, so which of the three rules applies is a
-- setting rather than an assumption.
wired('cupSetDnfScoring', 'cupSetDnfScoring', 'DNF scoring rule')
for _, mode in ipairs({ 'none', 'classified', 'held' }) do
  expect(html:find("cupSetDnfScoring('" .. mode .. "')", 1, true) ~= nil,
    'the DNF rule offers "' .. mode .. '"')
end
expect(js:find('data.dnfScoring', 1, true) ~= nil,
  'the DNF rule is mirrored from the cup broadcast')

-- ---------------------------------------------------------------------------
-- 4f. Driver identity is an ADMIN decision
--
-- BeamMP issues a fresh random guest name on every join, so nothing can work
-- out who has come back. The panel therefore has to offer an explicit
-- assignment, and it must never treat player id 0 as "nobody" -- ids are
-- zero-based, and a truthiness test on one reads the first player on the server
-- as unassigned, which would offer their driver (and their points) to somebody
-- else as free to take.
-- ---------------------------------------------------------------------------
expect(html:find('cupUi.bindTo[c.pid]', 1, true) ~= nil,
  'the assignment picker stores its choice in cupUi.bindTo by player id')
wired('cupBindDriver',   'cupApplyBind',      'Assign a connection to a driver')
wired('cupBindDriver',   'cupUnbind',         'Unassign a connection')
wired('cupForgetDriver', 'cupForgetDriver',   'Delete a saved driver')

expect(html:find('c in cup.connected', 1, true) ~= nil,
  'the panel lists who is connected right now')
expect(html:find('e in cup.roster', 1, true) ~= nil,
  'and the saved drivers they can be assigned to')
for _, field in ipairs({ 'roster', 'connected' }) do
  expect(js:find('data.' .. field, 1, true) ~= nil,
    'cup field ' .. field .. ' is mirrored from the RaceManagerCup broadcast')
end

-- The zero-based id trap, in both files.
expect(js:find('e.boundPid == null', 1, true) ~= nil,
  'the free-entry filter tests boundPid against null, not truthiness - player '
    .. 'id 0 is a real driver')
expect(html:find('e.boundPid', 1, true) == nil
  or (html:find('e.boundPid != null', 1, true) ~= nil
      and html:find('e.boundPid == null', 1, true) ~= nil),
  'the template compares boundPid against null too, so the first player on the '
    .. 'server is not rendered as unassigned')
expect(html:match('ng%-if="e%.boundPid"') == nil,
  'no bare truthiness test on boundPid survives in the template')

-- ---------------------------------------------------------------------------
-- 4h. Loading a preset actually refills the boxes
--
-- The scoring editors are re-seeded from the server, and the rule for when has
-- to be "the server's value changed", not "the buffer differs from the server".
-- Those look the same and are not: pressing Load replaces the table ON THE
-- SERVER, which the second rule reads as an edit in progress -- so the boxes
-- kept the old preset, and pressing Apply then posted those stale numbers back
-- and turned the table into a hand-edited "Custom" one. Loading a preset
-- appeared to do nothing, then appeared to corrupt itself.
--
-- The fix is to remember what the server last said (cupSeen) and compare
-- against that. This checks the seeding does not go back to asking the dirty
-- helpers, which is the shape of the bug.
-- ---------------------------------------------------------------------------
do
  expect(js:find('function cupSeedEditors', 1, true) ~= nil,
    'found the cup seeding function')
  expect(js:find('cupSeen', 1, true) ~= nil,
    'cup editors are re-seeded by comparing against the last value the SERVER '
      .. 'sent, so a preset load reaches the boxes')
  -- The exact gate that caused it. Seeding "unless the buffer differs from the
  -- server" treats a preset load as an edit in progress and skips it.
  for _, gate in ipairs({ '!$scope.cupPointsDirty()', '!$scope.cupDerbyDirty()',
                          '!$scope.cupQualiDirty()', '!$scope.cupBonusDirty()' }) do
    expect(js:find(gate, 1, true) == nil,
      'the seeding gates on "' .. gate .. '": a preset load changes the server '
        .. 'value, which that reads as an edit in progress, so the boxes keep '
        .. 'showing the old preset')
  end
  -- Asking for a preset must take the server's answer even when the table it
  -- replaces happens to be identical.
  expect(js:find('cupExpectReseed', 1, true) ~= nil,
    'loading a preset marks that table for re-seeding, so Load resets the boxes '
      .. 'even when the server value does not change')
end

-- ---------------------------------------------------------------------------
-- 4g. No native <select> anywhere in the app
--
-- BeamNG's UI is Chromium Embedded Framework, where a <select> popup is a
-- separate OS window that never renders over the game surface: the box shows
-- its value and clicking it does nothing whatsoever. There is no error and no
-- console output -- and it works perfectly in a desktop browser, so neither a
-- harness nor a code review catches it. Three of these reached a live server
-- before anybody could open the panel in the game.
--
-- Every picker in this app is therefore a custom DOM menu (see
-- .rm-layout-dropdown). This is the only cheap way to keep it that way.
-- ---------------------------------------------------------------------------
do
  -- Strip comments first -- both kinds. The markup and the stylesheet both
  -- explain WHY there are no selects, and those mentions are prose, not
  -- elements. (The CSS block is a /* */ comment, which is how this check first
  -- reported itself as failing against its own explanation.)
  local stripped = html:gsub('<!%-%-.-%-%->', ''):gsub('/%*.-%*/', '')
  local offender = stripped:match('<select')
  expect(offender == nil,
    'a native <select> element is present. Its popup is an OS window that CEF '
      .. 'never draws over the game, so the control renders and then does '
      .. 'nothing. Use the custom .rm-layout-dropdown menu instead.')
  expect(stripped:find('<option', 1, true) == nil,
    'a native <option> element is present, which means a <select> came back')
end

-- ---------------------------------------------------------------------------
-- 4e. The driver payload carries every field the app reads off a driver row
--
-- The state broadcast sends a TRIMMED projection of each player record rather
-- than the whole thing: a record holds audit counters and comparator scratch
-- that no client renders, and shipping them cost about a fifth of the busiest
-- message the plugin sends, three times a second, to every driver.
--
-- The hazard that creates is a quiet one. A field left off the list does not
-- error anywhere; it simply arrives as undefined, and a column goes blank.
-- This checks the template against the list so that cannot happen unnoticed.
-- ---------------------------------------------------------------------------
local server = readFile('server/RaceManager/main.lua')
local wireBlock = server:match('local DRIVER_WIRE_FIELDS = {(.-)\n}')
expect(wireBlock ~= nil, 'found DRIVER_WIRE_FIELDS in the server plugin')

local onWire = {}
for name in (wireBlock or ''):gmatch("'([%w_]+)'") do onWire[name] = true end
expect(next(onWire) ~= nil, 'the driver wire-field list is not empty')

-- Every `row.<field>` the template reads, where `row` is the driver row the
-- leaderboard repeats over.
local rowFields = {}
for field in html:gmatch('row%.([%w_]+)') do rowFields[field] = true end
expect(next(rowFields) ~= nil, 'found driver row field reads in the template')
for field in pairs(rowFields) do
  expect(onWire[field],
    'the leaderboard reads row.' .. field .. ' but the server does not send it - '
      .. 'add it to DRIVER_WIRE_FIELDS or that column renders blank with no error')
end

-- And the ones the controller reads off a driver row it was handed.
for _, field in ipairs({ 'alias', 'currentLap', 'finishTime', 'id', 'jokerLap',
                         'jokerTaken', 'name', 'outReason', 'position', 'resets',
                         'status', 'qualiBest', 'outLap' }) do
  expect(onWire[field],
    'the controller reads ' .. field .. ' off a driver row, so it must be on the wire')
end

-- The converse: fields that exist only for this plugin's own bookkeeping must
-- NOT be shipped. Each of these is read solely inside the server.
for _, field in ipairs({ 'pitStops', 'holdCorrections',
                         'holdCorrectedAt', 'distNext' }) do
  expect(not onWire[field],
    field .. ' is server-side bookkeeping and should not be broadcast to every '
      .. 'client three times a second')
end

-- ---------------------------------------------------------------------------
-- 4. Race and Derby are separated by mode, not just by tab
-- ---------------------------------------------------------------------------
-- The race session controls and the track layout picker sit ABOVE the tab bar,
-- deliberately -- they are what an admin reaches for under time pressure. That
-- put them over the Derby tab as well, offering a Load Layout button for a race
-- nobody was setting up. They are race controls, so they belong to race mode.
for _, row in ipairs({ 'rm%-controls"', 'rm%-controls rm%-controls%-layout"' }) do
  local cond = html:match('<div class="' .. row .. '%s+ng%-if="([^"]*)"')
  expect(cond ~= nil and cond:find("isMode('race')", 1, true) ~= nil,
    'the ' .. row:gsub('%%', '') .. ' row is not scoped to race mode')
end

-- Both modes have an Editor sub-tab, so a panel keyed on the tab name alone
-- would render both editors at once.
for _, panel in ipairs({ 'rm%-editor', 'rm%-derby rm%-derby%-editor' }) do
  local cond = html:match('<div class="' .. panel .. '" ng%-if="([^"]*)"')
  expect(cond ~= nil and cond:find('isMode(', 1, true) ~= nil,
    'the ' .. panel:gsub('%%', '') .. ' panel does not name its mode')
end

-- Each editor is a render gate in Lua. Both have to be pushed, or closing one
-- panel leaves its authoring furniture drawn in the world for every driver.
for _, cmd in ipairs({ 'setEditorOpen', 'setDerbyEditorOpen' }) do
  expect(js:find('raceManager.' .. cmd, 1, true) ~= nil,
    cmd .. ' is never pushed to Lua')
  expect(js:find("raceManager." .. cmd .. "(false)", 1, true) ~= nil,
    cmd .. ' is not cleared when the app is torn down')
end

-- The leaderboard at the bottom of the app is OUTSIDE the admin panel body, so
-- it renders on every tab. Which board it shows has to follow the mode for an
-- admin: the derby never touches race state, so a race table rendered under the
-- derby panel is the LAST race's field, not anything live. That is exactly what
-- it used to do -- the rule was `!isAdmin` alone, written for the driver HUD
-- before the panel had modes.
local board = js:match('%$scope%.derbyBoardOnly = function %(%)(.-)\n%s*};')
expect(board ~= nil, 'derbyBoardOnly is missing')
expect(board ~= nil and board:find('isMode(', 1, true) ~= nil,
  "derbyBoardOnly does not consult the mode, so an admin's leaderboard does not "
    .. 'follow the panel they are working in')

-- Both of these gate driver-facing chrome on the derby, and a derby is live from
-- FORM-UP, not from GO -- a driver held on the derby grid through the countdown
-- must already be seeing the derby board, not the previous race's.
for _, fn in ipairs({ 'derbyBoardOnly', 'sessionLive' }) do
  local body = js:match('%$scope%.' .. fn .. ' = function %(%)(.-)\n%s*};')
  expect(body ~= nil, fn .. ' is missing')
  expect(body ~= nil and body:find("derby.phase === 'running'", 1, true) == nil,
    fn .. " keys on derby.phase === 'running', which misses form-up and the "
      .. 'countdown; use derbyActive()')
end

-- The derby field is never on screen twice. It used to be repeated inside the
-- Derby panel as well as on the board below it, which put the standings up twice
-- on one tab and nowhere at all on the Derby Editor tab.
--
-- COUNTING COPIES IS NOT THE RULE, though it was while there was only ever one.
-- The broadcast board has a derby table of its own, and it has to: `drivers` is
-- the racing field and holds the LAST RACE while an arena is running. What
-- matters is that the two can never render together, so the test is on their
-- conditions rather than on the total.
do
  local boardAt = html:find('<div class="rm%-broadcast%-board"')
  local boardEnd = html:find('<!%-%- =+ Derby standings')
  expect(boardAt ~= nil and boardEnd ~= nil and boardAt < boardEnd,
    'located the broadcast board ahead of the leaderboards')
  local inBoard, outside = 0, 0
  for at in html:gmatch('()ng%-repeat="p in derby%.players') do
    if boardAt and boardEnd and at > boardAt and at < boardEnd then
      inBoard = inBoard + 1
    else
      outside = outside + 1
    end
  end
  expect(inBoard == 1, 'the broadcast board has one derby table (found '
    .. inBoard .. ')')
  expect(outside == 1, 'and the leaderboard has the only other one (found '
    .. outside .. ')')
  -- ...and they are exact complements, so no tab can show both.
  expect(html:find('ng-if="derbyBoardOnly() && !broadcastMode()"', 1, true) ~= nil,
    'the leaderboard derby board stands down for the broadcast board')
  expect(html:find("ng-if=\"broadcastView('race') && derbyActive()\"", 1, true) ~= nil,
    'and the broadcast one only renders while an arena is actually running')
end

-- ---------------------------------------------------------------------------
-- 5. Editor tabs: Main Route / Joker Route / Start Grid
--
-- The editor panel shows whichever list editorTarget names, so a tab that is
-- not carried through - to the client Lua on the way out, or back from its
-- route broadcast - leaves the button looking pressed while the panel stays on
-- the main route. That is exactly how the Start Grid tab broke: both ends
-- collapsed anything that was not 'joker' back to 'main'.
-- ---------------------------------------------------------------------------
wired('setEditorTarget', 'setEditorTarget', 'Editor tabs')

local tabs = {}
for target in html:gmatch("setEditorTarget%('([%w_]+)'%)") do tabs[target] = true end
expect(tabs.main and tabs.joker and tabs.start,
  'the template offers a Main Route, a Joker Route and a Start Grid tab')

local accepted = js:match('EDITOR_TARGETS%s*=%s*{(.-)}') or ''
for target in pairs(tabs) do
  expect(accepted:find(target .. ':', 1, true) ~= nil,
    'the "' .. target .. '" tab is not in the controller\'s EDITOR_TARGETS, so '
      .. 'pressing it falls back to the main route')
end

-- Every editorTarget assignment fed by a tab press or by the client's route
-- broadcast has to normalise through editorTargetOf; a hand-written ternary is
-- what dropped the third target on the floor.
for assign in js:gmatch('%$scope%.editorTarget%s*=%s*([^\n]+)') do
  if assign:find('data.editorTarget', 1, true) or assign:find('target', 1, true) then
    expect(assign:find('editorTargetOf', 1, true) ~= nil,
      'editorTarget is assigned from `' .. assign .. '` without editorTargetOf, '
        .. 'so a target it does not name collapses back to the main route')
  end
end

-- The command sent to the client Lua must carry the tab that was pressed.
local setTarget = js:match('%$scope%.setEditorTarget%s*=%s*function%s*%(target%)%s*{(.-)};')
expect(setTarget ~= nil, 'found the setEditorTarget handler in app.js')
if setTarget then
  expect(setTarget:find("'joker'", 1, true) == nil and setTarget:find("'main'", 1, true) == nil,
    'setEditorTarget rewrites the pressed tab into a hard-coded target before '
      .. 'sending it to raceManager.setEditorTarget')
end

-- ===========================================================================
-- Every editor target must have a case in editorWaypoints()
-- ===========================================================================
-- A missing case does not fail loudly. editorWaypoints() falls through to the
-- main route, so the tab's own count still reads correctly off its real list
-- while the list underneath shows the CHECKPOINTS -- which is how the pit tab
-- came to show four stalls when one had been placed.
local wpFn = js:match('editorWaypoints%s*=%s*function%s*%(%)(.-)end') or ''
for target in accepted:gmatch('([%w_]+)%s*:%s*true') do
  if target ~= 'main' then
    expect(wpFn:find("'" .. target .. "'", 1, true) ~= nil,
      'editorWaypoints() has no case for the "' .. target .. '" target, so that ' ..
      'tab silently lists the main route instead of its own markers')
  end
end

-- The adjust controls the starting grid has, on placed gates too.
for _, fn in ipairs({ 'previewCheckpoint', 'moveCheckpoint' }) do
  expect(html:find(fn .. '%(') ~= nil, 'the gate list offers ' .. fn)
  expect(js:find('%$scope%.' .. fn .. '%s*=') ~= nil,
    fn .. ' is bound on the controller scope')
end

-- ===========================================================================
-- Running a saved race must not require the editor
-- ===========================================================================
-- The layout picker used to live inside the editor panel, which meant loading a
-- track was only reachable by opening the editor -- and opening the editor is
-- what swaps the race checkpoint visuals for the authoring ones. An admin
-- looked for their gate poles during a race and found none, because choosing
-- the track had left them in the editor.
--
-- So: the Load control lives in the session controls, next to Generate Grid and
-- Start Countdown, and the editor keeps only the authoring half.
local editorStart = html:find('================= Checkpoint editor', 1, true)
local loadAt = html:find('ng%-click="loadLayout%(%)"')
expect(loadAt ~= nil, 'the template has a Load Layout control')
expect(editorStart ~= nil, 'the template has a checkpoint editor section')
expect(loadAt and editorStart and loadAt < editorStart,
  'Load Layout sits ABOVE the editor section, so running a saved race never ' ..
  'requires opening the editor')

-- Saving stays in the editor: that IS authoring.
local saveAt = html:find('ng%-click="saveLayout%(%)"')
expect(saveAt and editorStart and saveAt > editorStart,
  'Save Current Layout stays inside the editor, where authoring belongs')

-- ---------------------------------------------------------------------------
-- Layout management: save / overwrite / delete, and no second private copy
-- ---------------------------------------------------------------------------
-- The editor used to carry its own Save and Load beside the layout ones, for a
-- local scratch file nobody else could see. Loading it rebuilt the route while
-- emptying the joker route and the grid -- so a Load there followed by a Save
-- here overwrote a finished server layout with a partial one, and the two pairs
-- of identically-named buttons were the trap that made it easy.
for _, fn in ipairs({ 'editorSave', 'editorLoad' }) do
  expect(html:find('ng%-click="' .. fn .. '%(%)"') == nil,
    fn .. ' is still a button: the local scratch route file is gone, and a '
      .. 'second Save/Load pair meaning something else is what caused the loss')
  expect(js:find('$scope.' .. fn .. ' =', 1, true) == nil,
    fn .. ' still has a handler in app.js')
end

-- Overwrite and Delete act on the SELECTED layout, so neither may require a
-- typed name -- the whole point is putting a loaded track back without retyping.
for _, c in ipairs({ { fn = 'overwriteLayout' }, { fn = 'deleteLayout' } }) do
  expect(html:find('ng%-click="' .. c.fn .. '%(%)"') ~= nil,
    'the template has a ' .. c.fn .. ' control')
  expect(js:find('$scope.' .. c.fn .. ' = function', 1, true) ~= nil,
    c.fn .. ' has a handler in app.js')
  local disabled = html:match('ng%-click="' .. c.fn .. '%(%)"[^>]-ng%-disabled="([^"]*)"')
  expect(disabled ~= nil, c.fn .. ' has a ng-disabled guard')
  expect(disabled and disabled:find('layoutUi%.selected') ~= nil,
    c.fn .. ' is disabled until a layout is selected')
  expect(disabled and disabled:find('layoutUi%.name') == nil,
    c.fn .. ' must NOT require a typed name -- it works on the selection')
end

-- Both destructive actions go through the in-app confirmation. A browser
-- confirm() cannot be drawn over the game, so it is a panel, and the panel has
-- to exist with both a go-ahead and a way out.
expect(html:find('ng%-if="layoutUi%.confirm"') ~= nil,
  'the template has a confirmation panel for destructive layout actions')
expect(html:find('ng%-click="confirmLayoutAction%(%)"') ~= nil
  and html:find('ng%-click="cancelLayoutAction%(%)"') ~= nil,
  'the confirmation offers both a go-ahead and a cancel')
expect(js:find('window.confirm', 1, true) == nil and js:find('%f[%w]confirm%(') == nil,
  'no native confirm() -- CEF cannot draw one over the game')
for _, fn in ipairs({ 'overwriteLayout', 'deleteLayout' }) do
  local body = js:match('%$scope%.' .. fn .. ' = function %(%)(.-)\n      };')
  expect(body ~= nil, fn .. ' body found in app.js')
  expect(body and body:find('askLayout', 1, true) ~= nil,
    fn .. ' asks before acting rather than firing straight at the server')
end

-- The server can refuse a save that would empty part of a stored layout. That
-- reply has to reach the admin, or the save just silently does nothing.
expect(js:find("RaceManagerSaveHeld", 1, true) ~= nil,
  'the UI listens for the held-save reply')
expect(js:find('sendSave(data.name, true)', 1, true) ~= nil,
  'and can re-send the save with the confirmation the server is waiting for')

-- Delete is a BUTTON, not a keybind. Guessing a key for a destructive action on
-- an engine that cannot be driven from a test is how the node grabber block
-- shipped listening for action names nothing answered to, silently.
expect(html:find('ng%-click="nudgeDelete%(%)"') ~= nil,
  'the nudge panel has a Delete button')
expect(js:find('$scope.nudgeDelete = function', 1, true) ~= nil,
  'nudgeDelete has a handler in app.js')
local delGuard = html:match('ng%-click="nudgeDelete%(%)"[^>]-ng%-disabled="([^"]*)"')
expect(delGuard and delGuard:find('nudgeSel') ~= nil,
  'and it is disabled until something is picked')

-- The derby wall has a depth as well as a height, and both ride one command:
-- they are how the arena is DRAWN and neither touches the flat out-of-bounds
-- test, so there is no reason for them to travel separately.
expect(html:find('rectUi.wallDepth', 1, true) ~= nil,
  'the derby editor has a wall depth control')
expect(js:find('rectUi.wallDepth', 1, true) ~= nil,
  'and the controller reads it')
expect(js:find('$scope.derby.wallDepth = data.wallDepth', 1, true) ~= nil,
  'the server owns it: the panel follows what it broadcasts, like wall height')

-- ---------------------------------------------------------------------------
-- Start lights, and the flag that is not a phase
-- ---------------------------------------------------------------------------
-- Three lamps going amber one at a time on 3-2-1, then all three green together
-- on GO. The mapping is asserted here because it is the whole feature: a lamp
-- lighting on the wrong count is a start nobody can read.
local lamps = {}
for cls in html:gmatch('<span class="rm%-lamp" ng%-class="([^"]*)"') do
  lamps[#lamps + 1] = cls
end
expect(#lamps == 3, 'three lamps in the gantry (found ' .. #lamps .. ')')
for i, cls in ipairs(lamps) do
  -- Plain find, not a pattern: `?` is a quantifier in Lua patterns and this
  -- string is full of them.
  expect(cls:find("countdown === 0 ? 'rm-lamp-green'", 1, true) ~= nil,
    'lamp ' .. i .. ' goes GREEN on GO, with the others: a start is all three '
      .. 'at once, not a wave')
end
-- Lamp 1 lights at 3, lamp 2 at 2, lamp 3 at 1, so they accumulate.
expect(lamps[1] and lamps[1]:find('countdown <= 3', 1, true) ~= nil,
  'the first lamp lights at three')
expect(lamps[2] and lamps[2]:find('countdown <= 2', 1, true) ~= nil,
  'the second at two')
expect(lamps[3] and lamps[3]:find('countdown <= 1', 1, true) ~= nil,
  'the third at one, so they accumulate rather than chase')

-- The number stays. It is the part that reads at a glance on a narrow panel,
-- and the thing people count along with out loud.
expect(html:find('rm%-count%-num') ~= nil, 'the count is still shown as a number too')

-- THE FLAG IS A FIELD, NOT A PHASE. Fifty-odd `phase ==` tests across the two
-- Lua halves would each need an answer for a 'caution' phase, and most would be
-- wrong by default. The UI has to read it the same way.
expect(js:find('$scope.flag = (data.flag', 1, true) ~= nil,
  'the panel reads the flag off the state broadcast')
expect(html:find("ng%-click=\"setFlag%('yellow'%)\"") ~= nil
  and html:find("ng%-click=\"setFlag%('green'%)\"") ~= nil,
  'an admin can call a caution and go back to green')
expect(js:find('$scope.setFlag = function', 1, true) ~= nil,
  'setFlag has a handler in app.js')

-- ALL THREE FLAGS ARE ALWAYS PRESENT while a session runs, and the one that is
-- out is MARKED rather than removed. A single toggle hid whichever flag was not
-- next, so the sequence a marshal actually runs (red to clean up, yellow to pack
-- them up, green to go) meant guessing which button would appear.
for _, colour in ipairs({ 'red', 'yellow', 'green' }) do
  expect(html:find("ng%-click=\"setFlag%('" .. colour .. "'%)\"") ~= nil,
    'the ' .. colour .. ' flag has its own button')
end
local flagset = html:match('<span class="rm%-flagset"[^>]-ng%-if="([^"]*)"')
expect(flagset ~= nil, 'the flag buttons are grouped')
expect(flagset and flagset:find('racing', 1, true) ~= nil,
  'and the group is only shown during a session')
expect(html:find("'rm%-flag%-on': flag === 'red'") ~= nil,
  'the flag currently out is marked, not hidden')

-- RED ON THE GRID, AMBER UNDER CAUTION, carried by the flag itself.
--
-- This used to assert a pair of separate header LAMP classes, and it went on
-- passing long after the lamps were replaced -- first by the drawn flag, then by
-- the glyph -- because the CSS for them was never deleted. A test that checks a
-- rule exists rather than that anything WEARS it will hold dead code in place
-- indefinitely, and here it held a rule carrying a permanent animation.
--
-- The flag is the one thing that says this now, so the colours are what to pin.
for _, colour in ipairs({ 'red', 'yellow', 'white', 'green' }) do
  expect(html:find('%.rm%-flag%-' .. colour .. '%s*{') ~= nil,
    'the ' .. colour .. ' flag has a colour rule')
end
expect(js:find("$scope.phase === 'grid'", 1, true) ~= nil,
  'and the flag is shown on the grid, where red means held')
local greenLamp = html:find('rm%-flaglamp%-green')
expect(greenLamp == nil,
  'and no green one: an always-lit lamp is one nobody reads')

-- The flag is shown to DRIVERS, not just admins. Minimal mode is the whole HUD
-- for a non-admin, and a caution nobody in the field can see may as well not
-- have been called.
local _, flagsInHtml = html:gsub('rm%-flag rm%-flag%-{{ driverFlag }}', '')
expect(flagsInHtml == 2,
  'the flag appears twice: the admin header and the driver bar (found '
    .. flagsInHtml .. ')')
local barStart = html:find('<div class="rm%-driverbar"')
local flagInBar = html:find('rm%-flag rm%-flag%-{{ driverFlag }}', barStart or 1)
expect(barStart and flagInBar and flagInBar > barStart,
  'one of them is inside the driver bar, which is a non-admin\'s entire HUD')

-- White is a fact about ONE driver's lap, so the client resolves it and the
-- panel only renders it. The UI has no idea which lap anybody is on.
expect(js:find('$scope.driverFlag = data.driverFlag', 1, true) ~= nil,
  'the panel takes the shown flag from the client rather than deriving it')

-- ...AND READS IT ON THE STATE BROADCAST, not only on the route push. It was
-- read in the RaceManagerRoute handler alone, which fires on editor changes and
-- checkpoint crossings, so the flag changed when the driver went through a gate
-- and at no other time. The client had been sending it on both channels; only
-- one end was listening.
local updateHandler = js:match("%$scope%.%$on%('RaceManagerUpdate'.-\n      }%);")
expect(updateHandler ~= nil, 'found the state-broadcast handler')
expect(updateHandler and updateHandler:find('$scope.driverFlag = data.driverFlag', 1, true) ~= nil,
  'and it reads driverFlag, so the flag follows a caution called while nobody '
    .. 'happens to be crossing a checkpoint')
expect(js:find("=== 'white'", 1, true) ~= nil,
  'and knows about the white last-lap flag')

-- GO SURVIVES THE NEXT STATE BROADCAST.
--
-- Reported live: GO! showed on a derby and never on a race. On GO the phase is
-- already 'racing', and a race broadcasts state three times a second, so the
-- line that clears the overlay outside a countdown wiped GO within a third of a
-- second. A derby sends no such broadcast, so it kept it. The counts still clear
-- that way, which is what tidies up an aborted countdown.
local clearLine = js:match("if %(%$scope%.phase !== 'countdown'[^\n]*\n[^\n]*")
expect(clearLine ~= nil, 'the overlay-clearing guard is still there')
expect(clearLine and clearLine:find('countdown !== 0', 1, true) ~= nil,
  'and it spares the GO frame, which owns its own lifetime on a timer')

-- ---------------------------------------------------------------------------
-- A REPEAT INSIDE A REPEAT MUST NOT ADDRESS THE OUTER ROW BY $index
-- ---------------------------------------------------------------------------
-- ng-repeat shadows $index at every level, so a button inside an inner repeat
-- that calls something with $index is naming its OWN position in the inner
-- list, not the row it is sitting in. It reads perfectly and silently targets
-- the wrong thing.
--
-- That shipped: the marker symbol buttons are a repeat over seven symbols
-- inside a repeat over the placed markers, so every button addressed the marker
-- numbered after the arrow it drew. Pressing them looked like doing nothing,
-- because the marker that changed was elsewhere in the list.
--
-- THIS CHECK IS DELIBERATELY NARROW. A general "nested repeat using $index"
-- rule cannot be written against text: real nesting needs the DOM, an
-- indent-based guess flags separate subtrees as nested (it reported the derby
-- boundary and start lists, both of which are single-level and correct), and
-- the branch-gate buttons repeat over their own list where $index is exactly
-- right. A lint with false positives gets switched off, so this pins the one
-- place the mistake was actually made.
do
  local markerBtns = 0
  for tag in html:gmatch('<button[^>]-markerKinds[^>]->') do
    markerBtns = markerBtns + 1
    local click = tag:match('ng%-click="([^"]*)"') or ''
    -- Only the buttons that NAME A ROW. The picker above the list sets the
    -- symbol for the next marker placed and passes no index at all, which is
    -- correct and must not be dragged into this.
    local args = click:match('setMarkerKind%(([^)]*)%)') or ''
    if args:find(',', 1, true) then
      expect(args:find('%$index') == nil,
        'a marker symbol button addresses its row with $index, which inside that '
          .. 'inner repeat is the SYMBOL position, not the marker')
      expect(args:find('mIndex', 1, true) ~= nil,
        'a marker symbol button addresses its row through the index captured by '
          .. 'ng-init on the outer repeat')
    end
  end
  expect(markerBtns > 0, 'found the marker symbol buttons (got ' .. markerBtns .. ')')
  -- ...and the capture it depends on is still there.
  expect(html:find('ng%-init="mIndex = %$index"') ~= nil,
    'the gate row captures its index as mIndex for the symbol buttons to use')
end

-- ---------------------------------------------------------------------------
-- Every full-window overlay is confined to the panel in minimal mode
-- ---------------------------------------------------------------------------
-- These are `position: absolute; inset: 0` against the root, and the root is the
-- whole HUD app window, so inset:0 can never mean "the panel". The countdown was
-- confined on its own and the derby's OUT OF BOUNDS warning was not, so a
-- non-admin driving a derby got a red flash across their entire screen.
--
-- This asserts the LIST is complete rather than that one entry exists: patching
-- them one at a time is exactly what let the second one through.
-- GROUPED SELECTORS COUNT TOO, and reading only the line with the brace on it
-- is how one goes missing. `.rm-flash` and `.rm-derby-warning` share a rule now:
--
--     .rm-flash,
--     .rm-derby-warning {
--       position: absolute;
--       inset: 0;
--
-- A pattern anchored on "  .name {" sees the second of those and never the
-- first, so the shared primitive would sit outside this guard while the count
-- below stayed reassuringly unchanged. The whole selector list is walked back
-- from the declaration instead.
local overlays = {}
do
  local lines = {}
  for line in (html .. NL):gmatch('([^' .. NL .. ']*)' .. NL) do lines[#lines + 1] = line end
  for i = 2, #lines - 1 do
    if lines[i]:match('^    position: absolute;$')
       and lines[i + 1]:match('^    inset: 0;$') then
      -- The line directly above the declarations carries the brace, and every
      -- line above THAT which ends in a comma is another selector in the same
      -- group. Walking stops at the first line that is not one.
      local j = i - 1
      local sel = lines[j]:match('^  %.([%w%-]+)%s*{%s*$')
      if sel then
        overlays[#overlays + 1] = sel
        j = j - 1
        while j >= 1 do
          local grouped = lines[j]:match('^  %.([%w%-]+),%s*$')
          if not grouped then break end
          overlays[#overlays + 1] = grouped
          j = j - 1
        end
      end
    end
  end
end
expect(#overlays >= 3, 'found the full-window overlays, grouped selectors '
  .. 'included (got ' .. #overlays .. ': ' .. table.concat(overlays, ', ') .. ')')

for _, cls in ipairs(overlays) do
  -- Escaped: `-` is a quantifier in a Lua pattern, so a bare class name here
  -- silently matches nothing and the guard passes by never looking.
  local safe = cls:gsub('%-', '%%-')
  -- BOUNDED, or a longer class name satisfies the guard for a shorter one.
  -- `.rm-minimal .rm-flash-title` contains `.rm-minimal .rm-flash`, so an
  -- unbounded find reported the flash overlay as confined on the strength of a
  -- font-size rule for its caption, while the overlay itself was not in the
  -- list at all. The class has to be followed by something that cannot continue
  -- it: a comma, a brace, or whitespace.
  expect(html:find('%.rm%-minimal %.' .. safe .. '[^%w%-]') ~= nil,
    'the ' .. cls .. ' overlay is confined to the panel in minimal mode. Any '
      .. 'new overlay that covers the window belongs in that selector list too')
end

-- And the confinement needs a measured HEIGHT, not just a width: width alone
-- leaves a narrow column of overlay down the whole screen.
expect(html:find('var(--rm-lb-height', 1, true) ~= nil,
  'the confinement uses a measured panel height')
expect(js:find('--rm-lb-height', 1, true) ~= nil,
  'and the controller measures one')

-- ---------------------------------------------------------------------------
-- Both panels read in the SAME ORDER
-- ---------------------------------------------------------------------------
-- The admin header and the driver bar carry the same facts, and they used to
-- carry them in different orders with different subsets: switching between admin
-- and driver moved every number, and the flag was never twice in the same place.
--
-- The order is: phase, checkpoint, distance, race clock, lap, line, joker,
-- resets, flag. This compares the two RUNS against each other rather than
-- against a copy of the list, so adding a field to one panel and not the other
-- fails here rather than in somebody's peripheral vision mid-race.
local function fieldOrder(chunk)
  local seen = {}
  local marks = {
    { 'phase',  'rm%-phase' },
    { 'cp',     'CP <?b?>?{?{? ?nextWp' },
    { 'dist',   'formatDistance%(progress%.dist%)' },
    { 'clock',  'formatRaceTime%(raceTime%)' },
    { 'lap',    'class="rm%-laptime"' },
    { 'line',   'LINE <b>' },
    { 'joker',  'JOKER <b' },
    { 'resets', 'RESETS <b' },
    { 'flag',   'rm%-flag rm%-flag%-' },
  }
  local found = {}
  for _, m in ipairs(marks) do
    local at = chunk:find(m[2])
    if at then found[#found + 1] = { name = m[1], at = at } end
  end
  table.sort(found, function (a, b) return a.at < b.at end)
  for _, f in ipairs(found) do seen[#seen + 1] = f.name end
  return table.concat(seen, ',')
end

local headerChunk = html:match('<div class="rm%-header".-<!%-%- =+ Admin login')
local barChunk    = html:match('<div class="rm%-driverbar".-<!%-%- =+ Derby standings')
expect(headerChunk ~= nil, 'found the admin header')
expect(barChunk ~= nil, 'found the driver bar')

local headerOrder = fieldOrder(headerChunk or '')
local barOrder    = fieldOrder(barChunk or '')
expect(headerOrder == barOrder,
  'the two panels list their status fields in the same order.\n    admin: '
    .. headerOrder .. '\n    driver: ' .. barOrder)
-- THE FLAG ENDS THE FIRST ROW, which is not the same claim as "ends the run"
-- and replaces it. The wide, wordy readouts -- JOKER PENDING, RESETS n/m, the
-- out-lap notice -- moved below the break, so they now come AFTER the flag in
-- document order while appearing under it on screen. What still has to hold is
-- that the flag is the last thing on row one: it sits between the push that
-- shoves it to the right-hand end and the break that starts row two, with no
-- other status field in that span.
for _, panel in ipairs({ { 'admin header', headerChunk }, { 'driver bar', barChunk } }) do
  local row1 = (panel[2] or ''):match('rm%-bar%-corner(.-)rm%-bar%-break')
  expect(row1 ~= nil,
    panel[1] .. ' has no corner group, so its first row has no defined end')
  expect(row1 ~= nil and row1:find('rm%-flag rm%-flag%-') ~= nil,
    panel[1] .. ': the flag is not in the corner group at the end of row one')
  for _, field in ipairs({ 'JOKER <b', 'RESETS <b', 'rm%-waiting' }) do
    expect(row1 ~= nil and row1:find(field) == nil,
      panel[1] .. ': ' .. field:gsub('%%', '') .. ' is back on the first row. '
        .. 'It comes and goes mid-session and it is wide, which is exactly what '
        .. 'was moving the corner controls while somebody reached for one')
  end
end

-- SPECTATING IS A THING YOU DO, not a way to close a dialog.
--
-- The login panel's button said "Spectate" and only ever dismissed the box, so
-- racers pressed it expecting to watch a race. It is a close button now, and
-- sitting out lives in the entry row where entry decisions belong.
expect(html:find('ng%-click="spectate%(%)"[^>]-rm%-btn%-mini') ~= nil
    or html:find('rm%-btn%-mini" ng%-click="spectate%(%)"') ~= nil,
  'the login panel\'s dismiss is a small close button')
expect(html:find('Spectate »', 1, true) == nil,
  'and no longer promises a mode it never delivered')

-- ABSOLUTE, NOT A TOGGLE. `setSpectating(!spectating)` derives the action from
-- what the panel believes, so one stale broadcast leaves the driver holding a
-- button for the state they are already in: pressing it does nothing and there
-- is no way back. Two buttons that each send a fixed value are reachable
-- whatever the panel thinks, which is the property that makes the trap
-- unreachable rather than merely rare.
expect(html:find('ng%-click="setSpectating%(!spectating%)"') == nil,
  'nothing toggles spectating off its own belief about the current state')
expect(html:find('ng%-click="setSpectating%(false%)"') ~= nil,
  'there is always a button that puts you IN the field')
expect(html:find('ng%-click="setSpectating%(true%)"') ~= nil,
  'and always one that takes you out')
-- Both panels, because a driver in minimal mode has only the bar.
local racing, sitting = 0, 0
for _ in html:gmatch('setSpectating%(false%)') do racing = racing + 1 end
for _ in html:gmatch('setSpectating%(true%)') do sitting = sitting + 1 end
expect(racing == 2 and sitting == 2,
  'both the Race Entry row and the driver bar carry the pair')
expect(js:find('$scope.setSpectating = function', 1, true) ~= nil,
  'with a handler in app.js')
expect(js:find('data.youSpectating', 1, true) ~= nil,
  'and the panel follows the server, which owns whether you are in the field')

-- THE FLAG IS A GLYPH, AND IT MUST STILL TAKE ITS COLOUR FROM THE STATE.
--
-- A bare ⚑ renders as an EMOJI, carrying its own colour and ignoring CSS
-- `color`, so the flag stayed one shade while a yellow was out. The chat line
-- and the notice were correct the whole time, which is what made it look like a
-- state bug rather than a font one. See the variation-selector checks below for
-- how the text form is asked for.
expect(html:find('rm%-flag rm%-flag%-{{ driverFlag }}"[^>]->[^<]*⚑[^9]') == nil,
  'the flag glyph is never left bare: an emoji cannot be recoloured by the state')

-- A driver has to be able to reach their own participation controls, and the
-- entry row is hidden for a non-admin for exactly as long as a session is live.
-- Retire lived only there, so the people it is for could never press it.
local barChunk2 = html:match('<div class="rm%-driverbar".-<!%-%- =+ Derby standings')
expect(barChunk2 ~= nil, 'found the driver bar')
expect(barChunk2 and barChunk2:find('retireUi.confirm', 1, true) ~= nil,
  'the driver bar carries Retire, because it is a non-admin\'s whole HUD while a '
    .. 'session is live and the entry row is not shown then')
expect(barChunk2 and barChunk2:find('setSpectating', 1, true) ~= nil,
  'and Spectate, for between sessions')

-- ---------------------------------------------------------------------------
-- Nothing writes a BARE name from an ng-click
-- ---------------------------------------------------------------------------
-- ng-if and ng-repeat make a child scope, so `confirmRetire = true` written from
-- inside one lands on the CHILD and shadows the parent. The sibling that reads it
-- never sees the change, and the button does nothing at all -- which is exactly
-- what Retire did, in both panels, until it was bound through an object.
--
-- This file already warns about it for ng-model. An ng-click that ASSIGNS is the
-- same trap with a different attribute, so it is checked the same way: any
-- assignment has to go through a dot.
local bareWrites = {}
for expr in html:gmatch('ng%-click="([^"]*)"') do
  for target in expr:gmatch('([%w_%.]+)%s*=[^=]') do
    if not target:find('%.') then
      bareWrites[#bareWrites + 1] = target .. '  (in: ' .. expr:sub(1, 45) .. ')'
    end
  end
end
expect(#bareWrites == 0,
  'every ng-click assignment writes through an object, so a child scope cannot '
    .. 'shadow it: ' .. (bareWrites[1] or 'none'))

-- ---------------------------------------------------------------------------
-- Angular expressions must actually PARSE
-- ---------------------------------------------------------------------------
-- A stray apostrophe inside a single-quoted string ("the game's own controls")
-- is a $parse syntax error, and Angular reports it by failing to compile the
-- element -- which took the entire Race Entry row off the panel for admins and
-- drivers alike. Nothing else broke, nothing was logged where anybody would see
-- it, and every text-matching check in this file still passed, because the
-- string was all present and correct. It just could not be parsed.
--
-- Counting quotes is enough to catch it: a well-formed expression closes every
-- string it opens, so an ODD count is a broken one.
local exprBad = {}
for expr in html:gmatch('{{(.-)}}') do
  local n = select(2, expr:gsub("'", ''))
  if n % 2 == 1 then exprBad[#exprBad + 1] = expr:sub(1, 60) end
end
expect(#exprBad == 0,
  'every {{ }} expression closes its strings (odd-quoted: '
    .. (exprBad[1] or 'none') .. ')')

-- The same trap in an ng-* attribute, which is an expression too.
local attrBad = {}
for attr, val in html:gmatch('(ng%-[%w-]+)="([^"]*)"') do
  local n = select(2, val:gsub("'", ''))
  if n % 2 == 1 then attrBad[#attrBad + 1] = attr .. '="' .. val:sub(1, 50) end
end
expect(#attrBad == 0,
  'and so does every ng-* attribute (odd-quoted: ' .. (attrBad[1] or 'none') .. ')')

-- ---------------------------------------------------------------------------
-- Nudge mode: the button, and who owns whether it is on
-- ---------------------------------------------------------------------------
expect(html:find('ng%-click="toggleNudge%(%)"') ~= nil,
  'the editor has a Nudge toggle')
expect(js:find('$scope.toggleNudge = function', 1, true) ~= nil,
  'toggleNudge has a handler in app.js')
expect(js:find('raceManager.setNudgeMode(', 1, true) ~= nil,
  'and it reaches the client entry point')

-- The CLIENT decides whether the mode is on: it ends it by itself when a session
-- starts or the editor closes. A button tracking only what it last asked for
-- would sit there lit with the mouse already handed back.
expect(js:find('$scope.nudgeOn = data.nudgeOn === true', 1, true) ~= nil,
  'the button follows the state the client broadcasts, not the last request')
expect(html:find("ng%-class=\"{'rm%-btn%-nudge%-on': nudgeOn}\"") ~= nil,
  'and the button shows it, because this mode takes the mouse off the camera')

-- Exactly one layout picker, or two dropdowns would share one open-state flag
-- and both spring open together.
local _, pickers = html:gsub('ng%-click="toggleLayoutDropdown%(%)"', '')
expect(pickers == 1, 'exactly one layout dropdown in the template (found ' .. pickers .. ')')

-- ---------------------------------------------------------------------------
-- The broadcast board
-- ---------------------------------------------------------------------------
-- A board that hides every other panel in the app has exactly one way to go
-- wrong, and it is unrecoverable: hide the control that leaves it. Everything
-- below is about that, plus the wiring that a stale file would break silently.
do
  local client = readFile('lua/ge/extensions/raceManager.lua')

  -- IT IS A DIRECT CHILD OF .rm-root. The sweep that folds the app away is
  -- `.rm-broadcast > *`, a CHILD combinator, so a board nested inside anything
  -- else would be hidden by its own rule with nothing left on screen.
  local depth, found = 0, false
  for line in html:gmatch('[^\n]+') do
    local indent = #(line:match('^(%s*)') or '')
    if line:find('rm%-broadcast%-board') and line:find('<div') then
      found = true
      depth = indent
    end
  end
  expect(found, 'the broadcast board exists in the template')
  expect(depth == 2, 'and it is a direct child of .rm-root (indent ' .. depth
    .. '), or the .rm-broadcast sweep hides the board along with everything else')

  -- The sweep itself, and what survives it: only the board.
  local sweep = html:match('%.rm%-broadcast%s*>%s*%*([^{]*){')
  expect(sweep ~= nil, 'found the .rm-broadcast sweep')
  expect(sweep ~= nil and sweep:find(':not(.rm-broadcast-board)', 1, true) ~= nil,
    'the sweep keeps the board, or turning broadcast mode on empties the app')

  -- ...and the OTHER sweep must keep it too. Collapsing hides everything but a
  -- keep-list, and in broadcast mode the board is the only chrome there is: two
  -- sweeps each hiding what the other kept leaves nothing on screen and no way
  -- back but the game's app editor.
  local collapse = html:match('%.rm%-collapsed%s*>%s*%*([^{]*){')
  expect(collapse ~= nil and collapse:find(':not(.rm-broadcast-board)', 1, true) ~= nil,
    'collapsing must not hide the broadcast board: it carries the only control '
      .. 'that leaves the mode')

  -- THE WAY OUT IS ON THE BOARD. Not on the header or the driver bar, both of
  -- which the sweep above has just removed from the screen.
  local board = html:match('(<div class="rm%-broadcast%-board".-)<!%-%- =+ Derby standings')
  expect(board ~= nil, 'isolated the board markup')
  expect(board ~= nil and board:find('ng-click="toggleBroadcast()"', 1, true) ~= nil,
    'the board carries its own exit control')

  -- The mode is never shown to somebody who is IN the field. A driver cannot
  -- broadcast from a car they are racing, and the board replaces the HUD that
  -- tells them what their car is doing.
  expect(js:find('$scope.broadcast.on && $scope.spectatorView()', 1, true) ~= nil,
    'broadcastMode() requires the entry decision as well as the preference')
  expect(js:find('$scope.spectating === true || $scope.carTaken === true', 1, true) ~= nil,
    'spectatorView() reads BOTH spectator states: the entry decision and a car '
      .. 'taken away are different variables on purpose, and a finisher is as '
      .. 'much a spectator as somebody who sat the session out')
  for _, place in ipairs({ 'rm%-header', 'rm%-driverbar' }) do
    local bar = html:match('<div class="' .. place .. '"(.-)</div>%s*\n%s*\n')
    local _ = bar
  end
  local toggles = 0
  for _ in html:gmatch('ng%-click="toggleBroadcast%(%)"') do toggles = toggles + 1 end
  expect(toggles == 3,
    'the toggle sits in the header, on the driver bar and on the board itself '
      .. '(found ' .. toggles .. '): exactly one of the first two renders at a '
      .. 'time, so a mode reachable from only one of them is unreachable half '
      .. 'the time')

  -- The boards it replaces are ng-if'd off rather than left to the sweep. CSS
  -- hides an ng-repeat; it does not stop it digesting the whole field three
  -- times a second on a machine that is also encoding a stream.
  local wraps = 0
  for attrs in html:gmatch('<div class="rm%-table%-wrap"([^>]*)>') do
    wraps = wraps + 1
    expect(attrs:find('!broadcastMode()', 1, true) ~= nil,
      'a leaderboard renders under the broadcast board: ' .. attrs)
  end
  expect(wraps == 3, 'checked all three leaderboards (found ' .. wraps .. ')')
  expect(html:find('class="rm-admin-body" ng-if="isAdmin && !broadcastMode()"', 1, true) ~= nil,
    'the admin panels come out of the DOM too: an admin is often the broadcaster')

  -- The editor draws into the WORLD, and Lua only ever hears about the panel.
  -- An admin broadcasting from the Editor tab would stream gate rectangles and
  -- start-slot outlines over the race.
  local gate = js:match('function pushEditorOpen%(%)(.-)\n      }')
  expect(gate ~= nil, 'found pushEditorOpen')
  expect(gate ~= nil and gate:find('broadcastMode()', 1, true) ~= nil,
    'pushEditorOpen treats broadcast mode as closed, or the editor keeps drawing '
      .. 'its authoring furniture into a stream')
  expect(js:match('%$scope%.toggleBroadcast = function.-pushEditorOpen%(%)') ~= nil,
    'and the toggle re-pushes it, so the drawing stops as the panel goes')

  -- CLICK A NAME, GET A CAMERA: the one thing this board does that no other
  -- panel does. Three layers have to agree, and a stale one of them is silent.
  expect(html:find('ng-click="watchDriver(row)"', 1, true) ~= nil,
    'a driver row is clickable')
  expect(js:find("raceManager.spectateDriver(' + pid + ')", 1, true) ~= nil,
    'and the handler calls raceManager.spectateDriver')
  expect(client:find('function M.spectateDriver(pid)', 1, true) ~= nil,
    'which the client bridge defines')
  -- The id crosses a bngApi.engineLua STRING boundary, so it is coerced to a
  -- number on the way out rather than trusted because it came from our own row.
  expect(js:match('%$scope%.watchDriver = function.-Number%(row%.id%)') ~= nil,
    'the pid is coerced to a number before it is pasted into a Lua string')

  -- The board marks the row the camera actually reached, which is reported back
  -- rather than assumed: a click that could not resolve a car must not leave a
  -- board claiming a camera it never got.
  expect(client:find("guihooks.trigger('RaceManagerWatch'", 1, true) ~= nil,
    'the client bridge reports which car the camera landed on')
  expect(js:find("$scope.$on('RaceManagerWatch'", 1, true) ~= nil,
    'and the app listens for it, or the marker would never move')

  -- A DERBY IS NOT A RACE, and `drivers` proves it: the racing state machine's
  -- field is untouched by a derby, so what it holds while an arena is running is
  -- the LAST RACE. The admin's board fell into exactly this once and showed a
  -- finished race's results under the derby panel.
  expect(board ~= nil and board:find("broadcastView('race') && !derbyActive()", 1, true) ~= nil,
    'the race table stands down for a derby, or the board shows the previous '
      .. 'race while an arena is running')
  expect(board ~= nil and board:find("broadcastView('race') && derbyActive()", 1, true) ~= nil,
    'and a derby gets a table of its own')
  expect(board ~= nil and board:find('ng-click="watchDriver(p)"', 1, true) ~= nil,
    'a derby row is clickable too: the wreck is most of the show')

  -- THE BOARD DOES NOT OUTLIVE THE SPELL THAT SHOWED IT.
  --
  -- Being out of the field is two different things wearing one name: pressing
  -- Spectate is a decision that lasts, while taking the chequered flag makes you
  -- a spectator for the few seconds between the finish and the results. The
  -- preference is remembered across a teardown (it has to be -- BeamNG rebuilds
  -- this directive whenever the HUD layer goes, and the pause menu does that),
  -- and with both states feeding broadcastMode() that memory meant crossing the
  -- line threw an admin into a stream graphic and back out again mid race night.
  -- Reported from a live session.
  -- Anchored on the tail of the watch expression rather than the whole of it:
  -- the prefix is a function literal and easy to get subtly wrong in a pattern.
  local spell = js:match('spectatorView%(%); },(.-)' .. NL .. '        }%);')
  expect(spell ~= nil,
    'nothing watches the spectator spell, so the board outlives it and a driver '
      .. 'who merely finished is thrown into it for the results hold')
  expect(spell ~= nil and spell:find("savePref('broadcast', false)", 1, true) ~= nil,
    'the end of a spell must CLEAR the stored preference, not just hide the '
      .. 'board: otherwise the next finish brings it straight back')
  expect(spell ~= nil and spell:find('pushEditorOpen()', 1, true) ~= nil,
    'broadcastMode() changes here without anybody pressing anything, and the '
      .. "editor's world drawing is gated on it in Lua -- which only hears about "
      .. 'it when something says so')

  -- Points view. It renders standings and computes nothing, the same split the
  -- admin cup panel keeps: two places deciding who is leading is two places
  -- that can disagree.
  expect(board ~= nil and board:find('setBroadcastView(\'points\')', 1, true) ~= nil,
    'the board offers a points view')
  expect(board ~= nil and board:find('ng-if="cup.enabled"', 1, true) ~= nil,
    'and only when a cup is actually running: a toggle to an empty standings '
      .. 'table is a control that looks broken')
  expect(js:match('%$scope%.setBroadcastView = function.-pullCupState%(%)') ~= nil,
    'switching to points pulls the standings: the cup is pushed only when it '
      .. 'changes, so a board opened mid-evening would otherwise render empty')
  expect(board ~= nil and board:find('s.total', 1, true) ~= nil,
    'the points column is the server total, not a sum worked out here')
end

-- ---------------------------------------------------------------------------
-- Race entry is ONE switch
-- ---------------------------------------------------------------------------
-- There used to be three ways to answer "am I in this race": an admin-set entry
-- mode, a per-driver Join Race, and spectating. They could disagree, and the one
-- that broke was a driver who sat out and then had no way back in. Spectating is
-- the only mechanism now, so nothing here may come back.
for _, gone in ipairs({ 'entryMode', 'joinRace', 'leaveRace', 'canJoin',
                        'toggleEntryMode', 'setEntryMode' }) do
  expect(html:find(gone, 1, true) == nil,
    'the template no longer mentions ' .. gone)
  expect(js:find(gone, 1, true) == nil,
    'the panel script no longer mentions ' .. gone)
end

-- A spectator must always be able to see the way back. The button stays put
-- during a session and disables instead of vanishing: one that disappears reads
-- as broken, which is exactly how the trap was reported.
local entryRow = html:match('<div class="rm%-entry".-</div>')
expect(entryRow ~= nil, 'the Race Entry row is still there')
expect(entryRow and entryRow:find('setSpectating(false)', 1, true) ~= nil,
  'and it offers a way back into the field')
expect(entryRow and entryRow:find('ng%-disabled="sessionUnderWay%(%)"') ~= nil,
  'entry controls disable mid-session rather than disappearing')


-- ---------------------------------------------------------------------------
-- The entry decision and the camera state are two different facts
-- ---------------------------------------------------------------------------
-- They shared one $scope.spectating once. The route push carries "your car has
-- been taken away" (a finisher, a driver serving a penalty) and it overwrote
-- "I am sitting this one out" several times a second, so Rejoin looked broken
-- and the entry row lied to anybody who had just finished.
--
-- `spectating` is the ENTRY decision and may only ever be written from the
-- server's own youSpectating. `carTaken` is the camera.
--
-- `[^=]` on the end, or a COMPARISON counts as a write: `$scope.spectating ===`
-- begins with exactly the characters this is looking for, so the first predicate
-- that reads the flag made the count say three.
local writes = 0
for _ in js:gmatch('%$scope%.spectating%s*=[^=]') do writes = writes + 1 end
expect(writes == 2, 'only the initialiser and one server-owned write set $scope.spectating')
expect(js:find('$scope.spectating = data.youSpectating', 1, true) ~= nil,
  'and that write is youSpectating, the entry decision')
expect(js:find('$scope.carTaken', 1, true) ~= nil,
  'the forced-spectator camera state has its own name')
expect(js:find('$scope.spectating = !!(data', 1, true) == nil,
  'the RaceManagerSpectator event never writes the entry decision')
expect(html:find('class="rm-spectator-bar" ng-if="carTaken"', 1, true) ~= nil,
  'the spectator bar follows the camera, not the entry decision')


-- ---------------------------------------------------------------------------
-- The flag is a glyph, and it does not paint over anything else
-- ---------------------------------------------------------------------------
-- U+2691 arrives as an EMOJI unless the text form is asked for, and an emoji
-- carries its own colour: the flag stayed one shade whatever the session was
-- doing. The workaround was to draw a flag out of ::before and ::after, which
-- then painted over the checkered flag in the results table, because that
-- borrowed the same class. VS15 is the actual fix.
expect(html:find('&#x2691;&#xFE0E;', 1, true) ~= nil,
  'the flag glyph asks for its text form with a variation selector')
expect(html:find('%.rm%-flag::before') == nil and html:find('%.rm%-flag::after') == nil,
  'and nothing is drawn on top of it')
expect(html:find('class="rm%-finished%-flag"') ~= nil,
  'the results table checkered flag has its own class')
expect(html:find('class="rm%-flag">🏁') == nil,
  'so the flag styling can never paint over it')
-- Both panels show the same glyph.
local flagUses = 0
for _ in html:gmatch('rm%-flag rm%-flag%-{{ driverFlag }}') do flagUses = flagUses + 1 end
expect(flagUses == 2, 'the driver flag appears in both the admin header and the driver bar')


-- ---------------------------------------------------------------------------
-- Every infinite animation is gated, and every one of them is actually worn
-- ---------------------------------------------------------------------------
-- An element animating forever keeps the compositor repainting the UI layer for
-- as long as it exists, which is the one thing in this template that can cost
-- real frame time. All of them are inside an ng-if so they exist only while the
-- thing they describe is happening: the derby badge while a derby runs, the
-- out-of-bounds warning while a driver is outside the arena.
--
-- The rule this pins is narrower and mechanical: an infinite animation must
-- belong to a class the MARKUP actually uses. A rule nobody wears is dead
-- weight that still reads as a permanent animation to anyone auditing this
-- file, which is exactly what the old flag-lamp CSS was after the start lights
-- were built out of different classes.
-- Class names contain hyphens, which are Lua pattern metacharacters, so the
-- membership test is built out of plain finds rather than a pattern per class.
local worn = {}
for attr in html:gmatch('class="([^"]*)"') do
  for cls in attr:gmatch('[^%s]+') do worn[cls] = true end
end
for attr in html:gmatch("'(rm%-[%w%-]+)'%s*:") do worn[attr] = true end   -- ng-class keys
for attr in html:gmatch("'(rm%-[%w%-]+)'") do worn[attr] = true end       -- ng-class values
-- CLASSES BUILT AT RUNTIME. ng-class="'rm-flash-' + notice.colour" wears a
-- class whose name exists nowhere in this file, so a purely literal search
-- reports it as dead weight and fails on a rule that is very much in use. Any
-- prefix the markup concatenates onto marks everything sharing it as worn --
-- which is as precise as a static check can be about a name assembled at
-- runtime, and still catches a whole prefix nobody references.
local prefixes = {}
for pre in html:gmatch("'(rm%-[%w%-]-%-)'%s*%+") do prefixes[#prefixes + 1] = pre end
local function isWorn(cls)
  if worn[cls] then return true end
  for _, pre in ipairs(prefixes) do
    if cls:sub(1, #pre) == pre then return true end
  end
  return false
end
local animated = 0
for cls in html:gmatch('%.(rm%-[%w%-]+)%s*{[^}]-animation:[^}]-infinite') do
  animated = animated + 1
  expect(isWorn(cls),
    'the infinitely animated class ' .. cls .. ' is worn by an element')
end
-- A loop over nothing passes silently, which for a guard is the same as not
-- having one. Three forever-animations exist by design: the derby-live badge,
-- the out-of-bounds warning, and the checkered flash -- whose squares SWAP
-- rather than fading, because the shared fade takes black and white to grey.
expect(animated == 3, 'every infinite animation was found and checked, got '
  .. animated)

-- ---------------------------------------------------------------------------
-- Time behind: the gap columns, and the column counts they change
-- ---------------------------------------------------------------------------
-- Adding a column to a table means adding it in two places -- the header and the
-- body row -- and updating a third, the colspan on the empty-state row. Miss the
-- colspan and the "no drivers yet" message stops spanning the table, which is
-- invisible until a board renders empty in front of a room.
do
  local client = readFile('lua/ge/extensions/raceManager.lua')
  local server = readFile('server/RaceManager/main.lua')
  local _ = client

  -- Header count vs the empty row's colspan, per table. The tables are isolated
  -- by the marker comment that introduces each, so a fourth one added later has
  -- to be listed here rather than quietly skipped.
  -- Anchored on each table's WRAPPER rather than on its first header. A header
  -- class is shared between tables and a title attribute is not the start of the
  -- tag, so an anchor inside one silently drops a column from the count -- which
  -- is how the first version of this check reported a table one short.
  local tables = {
    { name = 'quali',     from = 'ng%-if="isQualiView%(%) && !derbyBoardOnly' },
    { name = 'race',      from = 'ng%-if="!isQualiView%(%) && !derbyBoardOnly' },
    { name = 'broadcast', from = '<div class="rm%-broadcast%-board"' },
    { name = 'board derby',  from = "broadcastView%('race'%) && derbyActive%(%)" },
    { name = 'board points', from = [[<div ng%-if="broadcastView%('points'%)"]] },
  }
  for _, t in ipairs(tables) do
    local at = html:find(t.from)
    expect(at ~= nil, 'located the ' .. t.name .. ' table')
    if at then
      local body = html:sub(at, (html:find('</table>', at, true) or #html))
      local ths = 0
      for _ in body:gmatch('<th[%s>]') do ths = ths + 1 end
      local span = tonumber(body:match('colspan="(%d+)"%s+class="rm%-empty"'))
      expect(ths > 0, t.name .. ' table has headers')
      expect(span ~= nil, t.name .. ' table has an empty-state row')
      expect(span == ths,
        t.name .. ' table has ' .. tostring(ths) .. ' columns but its empty row '
          .. 'spans ' .. tostring(span) .. ': the "nothing here yet" message '
          .. 'stops covering the table the moment a column is added')
    end
  end

  -- A GAP ON EVERY BOARD, which is what was asked for. Three tables, three
  -- cells, and the qualifying one comes from a different place on purpose.
  expect(html:find('gapLabel(row)', 1, true) ~= nil,
    'the race table shows a gap to the leader')
  expect(html:find('qualiGapLabel(row, $index)', 1, true) ~= nil,
    'the qualifying table shows a gap too')
  expect(html:find('intervalLabel(row)', 1, true) ~= nil,
    'and the broadcast board adds the interval to the car ahead')

  -- QUALIFYING'S GAP IS NOT THE RACE'S, and the split is the whole point. A
  -- qualifying session is scored on the best LAP -- two drivers who set
  -- identical times ten minutes apart are level -- so a delta off the session
  -- clock would rank them by when they went out.
  local qgap = js:match('%$scope%.qualiGapLabel = function %(row, index%)(.-)\n      };')
  expect(qgap ~= nil, 'found qualiGapLabel')
  expect(qgap ~= nil and qgap:find('qualiBest', 1, true) ~= nil,
    'the qualifying gap is worked out from the best laps')
  expect(qgap ~= nil and qgap:find('row.gap', 1, true) == nil,
    'and never from the clock delta, which qualifying has no meaning for')
  expect(server:find("local quali  = race.sessionKind == 'quali'", 1, true) ~= nil,
    'the server declines to compute one for a qualifying session at all')

  -- LAPPED IS NOT A NUMBER OF SECONDS. It is the one reading here that would
  -- actively mislead: a split delta across a lap boundary is a real figure and
  -- says nothing about a race those two cars are not having.
  local gapFn = js:match('%$scope%.gapLabel = function %(row%)(.-)\n      };')
  expect(gapFn ~= nil, 'found gapLabel')
  expect(gapFn ~= nil and gapFn:find('lapsDown(row)', 1, true) ~= nil,
    'the gap reads as laps once a driver is lapped')
  local intFn = js:match('%$scope%.intervalLabel = function %(row%)(.-)\n      };')
  expect(intFn ~= nil and intFn:find('currentLap', 1, true) ~= nil,
    'and so does the interval, against the car directly ahead rather than the '
      .. 'leader: a lapped driver is usually running right behind somebody on '
      .. 'the lead lap, which is where a raw delta looks most like a real gap')

  -- The panel formats and never computes. Both numbers arrive ready.
  for _, field in ipairs({ 'gap', 'intv' }) do
    expect(server:find("'" .. field .. "'", 1, true) ~= nil,
      'the server puts ' .. field .. ' on the wire')
  end
  expect(js:find('row.gap - ', 1, true) == nil and js:find('- leader.gap', 1, true) == nil,
    'the panel does no arithmetic on the race gap: the server measured it off '
      .. 'the one clock both drivers are scored on, and a second opinion here '
      .. 'is a second answer')
end

-- ---------------------------------------------------------------------------
-- The status bars are two rows, and the flag ends the first one
-- ---------------------------------------------------------------------------
-- All three bars wrap. What they did not do was wrap in the SAME PLACE twice
-- running: every readout on the run changes width as it changes value -- a lap
-- clock crossing 0:09.9 to 0:10.0, a fastest-lap holder called `guest5961302`
-- replacing one called `Ana` -- so the controls after them moved while you were
-- reaching for one, and how many ended up on the second row depended on the
-- width of a number.
--
-- The break is placed after the FLAG in all three, which is not a new rule: the
-- flag was already written as the end of the status run and this file already
-- pins that ("the flag ends the run in both"). Information above, anything you
-- press below.
do
  local bars = {
    { name = 'admin header', chunk = headerChunk },
    { name = 'driver bar',   chunk = barChunk },
  }
  for _, b in ipairs(bars) do
    expect(b.chunk ~= nil, 'isolated the ' .. b.name)
    if b.chunk then
      local after = b.chunk:match('rm%-flag rm%-flag%-{{ driverFlag }}(.*)$')
      expect(after ~= nil, b.name .. ' still shows the driver flag')
      expect(after ~= nil and after:find('rm-bar-break', 1, true) ~= nil,
        b.name .. ' has no row break after its flag, so its controls wrap '
          .. 'wherever the numbers above them happen to end')
      -- The only things pressed on the first row are the two corner controls,
      -- and they must be AFTER the push -- otherwise they sit in the middle of
      -- the status run, which is where they were being shoved about.
      local run = b.chunk:match('^(.-)rm%-bar%-corner')
      expect(run ~= nil and run:find('<button', 1, true) == nil,
        b.name .. ' has a button in its status run: the only controls on the '
          .. 'first row are the corner pair, and they live inside the corner group')
      local corner = b.chunk:match('rm%-bar%-corner(.-)rm%-bar%-break')
      local buttons = 0
      for _ in (corner or ''):gmatch('<button') do buttons = buttons + 1 end
      expect(buttons == 2,
        b.name .. ' should carry exactly the size reset and the collapse in its '
          .. 'corner (found ' .. buttons .. ')')
      -- OUT OF FLOW, and that is the point rather than a detail. A flex push
      -- distributes space only AFTER the browser has decided where lines break,
      -- so a bar that is marginally too wide wraps its last button onto row two
      -- and only then inflates the push on row one -- a stranded control and a
      -- lake of space after the lap clock, from one cause, exactly when a race
      -- is running and the bar is fullest.
      expect(html:find('.rm-bar-corner {', 1, true) ~= nil,
        'the corner group has no rule of its own')
      local rule = html:match(NL .. '  %.rm%-bar%-corner {(.-)}')
      expect(rule ~= nil and rule:find('position: absolute', 1, true) ~= nil,
        b.name .. ': the corner group is back in the flex flow, where wrapping '
          .. 'can strand it on the second row')
    end
  end

  -- The broadcast bar keeps the same rule with its own flag, which is a session
  -- flag rather than a driver one.
  local bc = html:match('<div class="rm%-bc%-bar">(.-)</div>')
  expect(bc ~= nil, 'isolated the broadcast bar')
  if bc then
    local after = bc:match('rm%-flag rm%-flag%-{{ flag }}(.*)$')
    expect(after ~= nil and after:find('rm-bar-break', 1, true) ~= nil,
      'the broadcast bar breaks after its flag too')
    -- The fastest-lap holder is a name of any length, so it must sit BEFORE the
    -- flag: leaving it after would put a variable-width field last and hand the
    -- jitter straight back.
    local flagAt, flAt = bc:find('rm%-flag rm%-flag%-{{ flag }}'), bc:find('rm%-bc%-fastest')
    expect(flAt ~= nil and flagAt ~= nil and flAt < flagAt,
      'the fastest lap sits before the flag, so the widest, most variable field '
        .. 'is not the one deciding where the row ends')
  end

  -- COLLAPSING STANDS THE BREAK DOWN. Collapsing exists to leave one line
  -- carrying the phase, the clock and the way back; a forced second row there
  -- defeats the control that got them there.
  -- COLLAPSED CHANGES NOTHING ABOUT THE BAR. This used to assert the opposite --
  -- that the break and the push both stood down while folded -- on the reasoning
  -- that collapsing exists to leave one line. It does not produce one line: the
  -- header keeps its badges and its admin controls either way, so all that
  -- happened was the run stopped breaking and the corner pair fell back into the
  -- middle of it. That is the exact wandering the pair exists to stop, and it was
  -- reported from a live session.
  expect(html:find('.rm-collapsed .rm-bar-corner', 1, true) == nil
    and html:find('.rm-collapsed .rm-bar-break', 1, true) == nil,
    'collapsing must not stand the row break or the pinned corner down: the '
      .. 'corner group belongs in the corner in every state, folded or not')
  -- ...and the pair stays a PAIR in every state. Hiding the size reset while
  -- folded left the corner holding two buttons expanded and one collapsed, so
  -- the collapse toggle shifted sideways at the moment it was pressed.
  for _, fn in ipairs({ 'resetHudSize', 'resetLeaderboardSize', 'resetBroadcastSize' }) do
    local tag = html:match('<button[^>]-' .. fn .. '%(%)[^>]->')
    expect(tag ~= nil, 'found the ' .. fn .. ' button')
    expect(tag ~= nil and tag:find('hudCollapsed', 1, true) == nil,
      fn .. ' is hidden while collapsed, so its corner holds two buttons when '
        .. 'expanded and one when folded, and the collapse toggle moves sideways '
        .. 'as you press it')
  end
  -- Each bar is its own positioning context. Without that the corner pins itself
  -- to .rm-root and the driver bar's lands up beside the header's.
  for _, sel in ipairs({ 'rm%-header', 'rm%-driverbar', 'rm%-bc%-bar' }) do
    local rule = html:match(NL .. '  %.' .. sel .. ' {(.-)}')
    expect(rule ~= nil and rule:find('position: relative', 1, true) ~= nil,
      '.' .. sel:gsub('%%', '') .. ' is not a positioning context, so its pinned '
        .. 'corner anchors to the app root instead of to the bar')
  end
  -- No auto margins left anywhere in the bars: each one right-aligns whatever
  -- follows it, which is how both the button row and the admin row ended up as
  -- right aligned strips nobody asked for.
  for _, sel in ipairs({ 'rm%-btn%-tab', 'rm%-admin%-tag' }) do
    local rule = html:match(NL .. '  %.' .. sel .. ' {(.-)}')
    -- Comments stripped first. Both of these rules now carry a note explaining
    -- why the auto margin is gone, and the note contains the words -- so a
    -- search over the raw rule finds the explanation and reports the bug it is
    -- explaining the absence of.
    rule = rule and rule:gsub('/%*.-%*/', '')
    expect(rule ~= nil and rule:find('margin%-left: auto') == nil,
      '.' .. sel:gsub('%%', '') .. ' carries margin-left: auto again, which drags '
        .. 'everything after it to the right-hand edge of its row')
  end

  -- ...and the break only means anything on a bar that wraps.
  for _, sel in ipairs({ 'rm%-header', 'rm%-driverbar', 'rm%-bc%-bar' }) do
    local rule = html:match(NL .. '  %.' .. sel .. ' {(.-)}')
    expect(rule ~= nil and rule:find('flex-wrap: wrap', 1, true) ~= nil,
      '.' .. sel:gsub('%%', '') .. ' does not wrap, so the row break above it is '
        .. 'an invisible no-op that silently puts the controls back on the info row')
  end
end

-- ---------------------------------------------------------------------------
-- One slider fades everything with a background
-- ---------------------------------------------------------------------------
-- The panel fill was the only thing driven by it for a while, so the header's
-- orange band and its rule kept their own fixed alpha: fade the HUD all the way
-- out and a solid orange stripe stayed painted across the middle of the view.
-- Anything with a background of its own is driven from the one watcher, or
-- "opacity" means "opacity, except that bit".
do
  local watcher = js:match("%$scope%.%$watch%('lbUi%.opacity'.-\n      }%);")
  expect(watcher ~= nil, 'found the opacity watcher')
  for _, prop in ipairs({ '--rm-panel-bg', '--rm-accent-bg', '--rm-accent-line' }) do
    expect(watcher ~= nil and watcher:find(prop, 1, true) ~= nil,
      'the opacity slider does not drive ' .. prop)
  end
  -- The header is what those two exist for.
  local head = html:match(NL .. '  %.rm%-header {(.-)}')
  expect(head ~= nil and head:find('var(--rm-accent-bg', 1, true) ~= nil,
    'the header tint is hardcoded again, so it survives a fade to nothing')
  expect(head ~= nil and head:find('var(--rm-accent-line', 1, true) ~= nil,
    'and so does its bottom rule')
  -- The driver bar mixed its own fill at 0.8x the slider, so it sat visibly
  -- lighter than the board directly beneath it at every setting but zero.
  expect(html:find('lbUi.opacity * 0.8', 1, true) == nil,
    'the driver bar no longer mixes its own opacity: one slider, one value')
  local dbar = html:match(NL .. '  %.rm%-driverbar {(.-)}')
  expect(dbar ~= nil and dbar:find('var(--rm-panel-bg', 1, true) ~= nil,
    'it takes the same fill every other surface here does')
end

if fails == 0 then
  print('ui_bindings_test: ' .. checks .. ' checks, 0 failures ('
    .. #models .. ' ng-model bindings)')
else
  print('ui_bindings_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
