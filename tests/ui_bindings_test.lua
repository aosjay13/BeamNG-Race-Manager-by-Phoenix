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

wired('joinRace',           'joinRace',           'Join Race')
wired('setEntryMode',       'toggleEntryMode',    'Entry mode')
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
for _, field in ipairs({ 'entryMode', 'gridMode', 'ghostQuali', 'startSlots',
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

-- The cup is a race-mode tab. It has nothing to say about a derby, and putting
-- it anywhere else would repeat the mistake the mode split fixed.
expect(html:match('ng%-click="selectAdminTab%(\'cup\'%)"') ~= nil,
  'there is a Cup tab button')
expect(html:find("isMode('race') && isAdminTab('cup')", 1, true) ~= nil,
  'the cup panel is scoped to race mode')
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

-- One copy of the derby standings, not two. The bottom board is the derby board
-- in derby mode, so repeating the table inside the Derby panel put the field on
-- screen twice on one tab and nowhere at all on the Derby Editor tab.
local _, boards = html:gsub('ng%-repeat="p in derby%.players', '')
expect(boards == 1,
  'expected exactly one derby standings table in the app, found ' .. boards)

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

-- The caution button is only live while something is actually running.
local cautionGuard = html:match("ng%-click=\"setFlag%('yellow'%)\"[^>]-ng%-disabled=\"([^\"]*)\"")
expect(cautionGuard ~= nil, 'the caution button has a guard')
expect(cautionGuard and cautionGuard:find('racing', 1, true) ~= nil,
  'and it is only live during a session')

-- The header lamp is RED on the grid and AMBER under caution, and shows nothing
-- at all when the race is simply green: a lamp that is always lit is a lamp
-- nobody reads.
expect(html:find('rm%-flaglamp%-red') ~= nil and html:find('rm%-flaglamp%-amber') ~= nil,
  'the header carries a red grid lamp and an amber caution lamp')
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

if fails == 0 then
  print('ui_bindings_test: ' .. checks .. ' checks, 0 failures ('
    .. #models .. ' ng-model bindings)')
else
  print('ui_bindings_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
