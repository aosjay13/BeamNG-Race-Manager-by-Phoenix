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
-- broke — the server console logged a change, the panel kept showing the
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
expect(bound('derbyUi.name'),      'Derby arena name input binds derbyUi.name')
expect(bound('lbUi.opacity'),      'Leaderboard opacity slider binds lbUi.opacity')

-- A checkpoint is a flat width x height rectangle: the depth control and every
-- reference to it are gone from both ends.
expect(not html:find('settingsUi.depth', 1, true), 'the gate depth input is gone from the template')
expect(not js:find('setCheckpointDepth', 1, true), 'the depth command is gone from the controller')
expect(not html:find('cpEdit.depth', 1, true), 'the per-gate depth override is gone')

-- UI -> server: the Set handlers read the value the inputs actually write.
expect(js:find('$scope.settingsUi.laps', 1, true) ~= nil,
  'applyTotalLaps reads settingsUi.laps')
expect(js:find('$scope.settingsUi.resets', 1, true) ~= nil,
  'applyMaxResets reads settingsUi.resets')

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

for _, field in ipairs({ 'entryMode', 'gridMode', 'ghostQuali', 'startSlots' }) do
  expect(js:find('data.' .. field, 1, true) ~= nil,
    field .. ' is mirrored from the server broadcast')
end

-- ---------------------------------------------------------------------------
-- 5. Editor tabs: Main Route / Joker Route / Start Grid
--
-- The editor panel shows whichever list editorTarget names, so a tab that is
-- not carried through — to the client Lua on the way out, or back from its
-- route broadcast — leaves the button looking pressed while the panel stays on
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
