-- Headless test for ROUTE BUFFER OWNERSHIP in
-- lua/ge/extensions/raceManager.lua.
--
-- Why this exists: route/jokerRoute/pitRoute/startPositions are the track this
-- client races AND the working copy the editor appends to. Nothing separated
-- them, so an incoming RM_ApplyLayout overwrote whatever an admin had
-- half-built.
--
-- That is the two-admin bug. The controller back button was blamed for it and
-- had nothing to do with it: the app asks the server for state on every mount,
-- the server answers with whichever layout is globally loaded, and the reply
-- landed as an unconditional overwrite. A rejoin, a HUD apps toggle or a UI
-- scale change reproduced it just as well.
--
-- The claim under test is the whole guard: a layout is refused ONLY when the
-- editor is open, the buffer has drifted from what the server last handed over,
-- and no session is running. Every other path stays exactly as it was, which is
-- what keeps a driver, a late joiner and a deliberate Load unaffected.
--
-- Run from the repo root: lua5.3 tests/editor_buffer_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local sent     = {}   -- ordered { event, payload } sent to the server
local hooks    = {}   -- ordered { event, payload } pushed to the UI
local handlers = {}   -- server -> client handlers the extension registered

local veh = { id = 7, x = 0, y = 0, z = 0, hx = 0, hy = 1 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = self.hx, y = self.hy, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation() end
function veh:queueLuaCommand() end

be               = { getPlayerVehicle = function () return veh end }
getPlayerVehicle = function (_) return veh end
getAllVehicles   = function () return { veh } end
beamng_version   = '0.39.0.0'

vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt   = { getConfig = function ()
  return { parts = {}, vars = {}, configName = 'Stock' }
end }

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

-- ---------------------------------------------------------------------------
-- Harness helpers
-- ---------------------------------------------------------------------------
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end

-- A layout as the server broadcasts it. Gate coordinates are spaced far enough
-- apart that two layouts can never fingerprint the same by accident.
local function layout(name, x0)
  return {
    name = name, width = 20, height = 8, depth = 2,
    checkpoints = {
      { x = x0,       y = 0,  z = 0, hx = 0, hy = 1 },
      { x = x0 + 50,  y = 60, z = 0, hx = 1, hy = 0 },
      { x = x0 + 100, y = 0,  z = 0, hx = 0, hy = -1 },
    },
  }
end

-- WHAT THE SERVER ACTUALLY SENDS when an admin presses Load.
--
-- RM_onLoadLayout purges every client first and broadcasts the gates second, so
-- a test that fires only the apply is testing half the sequence -- and it is the
-- half that leaves the buffer intact. Guarding the apply alone still lost the
-- work, to the purge.
local function loadOnServer(l)
  handlers['RM_ClearTrack']({ reason = 'loading layout "' .. l.name .. '"' })
  handlers['RM_ApplyLayout'](l)
end

-- The apply on its own, for the paths that genuinely send one: a targeted reply
-- to RM_RequestState, and the push a joining client gets.
local function applyLayout(l) handlers['RM_ApplyLayout'](l) end

-- The editor's view of the buffer, read back off the last RaceManagerRoute push
-- rather than out of the extension: that hook IS what the panel draws, so a
-- test reading it is testing what an admin actually sees.
local function currentRoute()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerRoute' then return hooks[i].payload.waypoints end
  end
  return nil
end

local function routeStartsAt()
  local r = currentRoute()
  return (r and r[1]) and r[1].x or nil
end

-- ---------------------------------------------------------------------------
-- A driver never holds the buffer
-- ---------------------------------------------------------------------------
-- The editor has never been opened on this client, which is every non-admin and
-- every admin who has not gone looking for the editor tab. Layouts must apply
-- unconditionally, exactly as they did before the guard existed.
serverState({ phase = 'waiting', drivers = {} })
applyLayout(layout('Alpha', 100))
check(routeStartsAt() == 100, 'first layout applies to a fresh client')

applyLayout(layout('Bravo', 700))
check(routeStartsAt() == 700, 'a second layout replaces the first when no editor is open')

-- The guard must not engage for a driver even once a layout HAS been applied,
-- which is the state every client on the server is in mid-session.
applyLayout(layout('Charlie', 1300))
check(routeStartsAt() == 1300, 'a driver never refuses a layout')

-- ---------------------------------------------------------------------------
-- An open but untouched editor still takes layouts
-- ---------------------------------------------------------------------------
-- Opening the editor is not the same as having work in it. An admin sitting on
-- the editor tab with the layout the server gave them must still receive a load
-- somebody else performs, or the guard would strand every admin who left the
-- tab open.
RM.setEditorOpen(true)
applyLayout(layout('Delta', 1900))
check(routeStartsAt() == 1900, 'an open, clean editor still accepts a layout')

-- ---------------------------------------------------------------------------
-- THE BUG: a dirty editor buffer is not overwritten
-- ---------------------------------------------------------------------------
-- The admin places a gate of their own. The buffer has now drifted from what
-- the server handed over, and this is the state that used to be destroyed.
RM.setFinishLine(4242, 17, 3, 0, 1)
check(routeStartsAt() == 4242, 'the admin\'s own edit is in the buffer')

applyLayout(layout('Echo', 2500))
check(routeStartsAt() == 4242, 'a layout loaded by another admin does NOT overwrite unsaved work')

-- Repeating it changes nothing: this is the RM_RequestState reply arriving on
-- every app mount, which is the path that actually fired in the session where
-- this was found.
applyLayout(layout('Echo', 2500))
applyLayout(layout('Echo', 2500))
check(routeStartsAt() == 4242, 'a repeated apply still leaves the editor buffer alone')

-- The panel is told, rather than the load failing silently. A refusal nobody can
-- see reads as the Load button being broken.
-- Matched on the REFUSAL wording, not just on the layout name: a successful
-- apply also pushes an editor message naming the layout, so a looser search
-- here passes whether the guard ran or not and proves nothing.
local told = false
for _, h in ipairs(hooks) do
  local msg = h.event == 'RaceManagerEditorMsg' and tostring(h.payload.msg) or ''
  if msg:find('Echo', 1, true) and msg:find('unsaved', 1, true) then told = true end
end
check(told, 'the editor is told which layout was refused, and why')

-- ---------------------------------------------------------------------------
-- Pressing Load is the admin saying yes
-- ---------------------------------------------------------------------------
-- The guard exists to stop somebody else's layout landing on unsaved work. It
-- must never stop the admin taking one deliberately.
RM.loadLayout('Echo')
check(sent[#sent].event == 'RM_LoadLayout', 'Load asks the server for the layout')
applyLayout(layout('Echo', 2500))
check(routeStartsAt() == 2500, 'a deliberate Load overwrites the admin\'s own buffer')

-- ...and the buffer is clean again afterwards, so the next foreign load applies
-- normally rather than being refused against a stale fingerprint.
applyLayout(layout('Foxtrot', 3100))
check(routeStartsAt() == 3100, 'the buffer is re-stamped after a deliberate Load')

-- ---------------------------------------------------------------------------
-- A running session outranks unsaved work
-- ---------------------------------------------------------------------------
-- An admin who leaves the editor open with edits in it while a grid forms must
-- still get the raced track. The alternative is one car running a layout nobody
-- else on the server is on, which is worse than losing an unsaved edit.
RM.setFinishLine(9999, 5, 0, 0, 1)
check(routeStartsAt() == 9999, 'the editor is dirty again')

for _, running in ipairs({ 'grid', 'countdown', 'racing', 'qualifying' }) do
  RM.setFinishLine(9999, 5, 0, 0, 1)
  serverState({ phase = running, drivers = {} })
  applyLayout(layout('Race Track', 5000))
  check(routeStartsAt() == 5000, 'phase ' .. running .. ': the raced layout wins over unsaved work')
end

-- Back to waiting, and the guard comes back with it.
serverState({ phase = 'waiting', drivers = {} })
RM.setFinishLine(8888, 5, 0, 0, 1)
applyLayout(layout('Golf', 6000))
check(routeStartsAt() == 8888, 'the guard is back once the session is over')

-- ---------------------------------------------------------------------------
-- The real broadcast sequence: purge, then gates
-- ---------------------------------------------------------------------------
-- Everything above fires RM_ApplyLayout on its own, which is what a targeted
-- state reply looks like. A LOAD is two broadcasts, and the purge is the one
-- that destroys work.
serverState({ phase = 'waiting', drivers = {} })
RM.setEditorOpen(true)
RM.loadLayout('Baseline')
applyLayout(layout('Baseline', 200))
check(routeStartsAt() == 200, 'baseline layout applied, editor clean')

-- A clean editor must ride the whole sequence through and end up on the new
-- track. This is the case that a naive apply-only guard breaks: the purge wipes
-- the buffer, the wipe reads as an edit, and the gates that follow are refused.
loadOnServer(layout('India', 2200))
check(routeStartsAt() == 2200, 'a clean open editor survives purge-then-apply and takes the layout')

-- ...and a dirty one keeps its work through BOTH broadcasts.
RM.setFinishLine(7777, 1, 0, 0, 1)
loadOnServer(layout('Juliet', 2800))
check(routeStartsAt() == 7777, 'a dirty editor survives the purge, not just the apply')

-- The empty-editor failure specifically: the buffer must not be left holding
-- nothing. This is the assertion that fails if only onApplyLayout is guarded.
local r = currentRoute()
check(r ~= nil and #r > 0, 'a refused load never leaves the editor empty')

-- ---------------------------------------------------------------------------
-- Closing the editor hands the buffer back
-- ---------------------------------------------------------------------------
-- A closed panel cannot be holding work in progress, so an admin who closes the
-- editor rejoins the unconditional path rather than silently refusing layouts
-- for the rest of the session.
RM.setEditorOpen(false)
applyLayout(layout('Hotel', 6600))
check(routeStartsAt() == 6600, 'closing the editor releases the buffer')

-- ---------------------------------------------------------------------------
-- The editor is closed while a session is running
-- ---------------------------------------------------------------------------
-- Until this guard existed, nothing in Lua stopped a gate moving under a car at
-- speed: the only thing in the way was an ng-disabled attribute in the panel,
-- and those tested for 'countdown' and 'racing' and missed QUALIFYING in all
-- fourteen places. The whole editor was live for every qualifying session.
RM.setEditorOpen(true)
serverState({ phase = 'waiting', drivers = {} })
RM.loadLayout('Guard Base')
applyLayout(layout('Guard Base', 400))
check(routeStartsAt() == 400, 'baseline for the mode guard')

for _, running in ipairs({ 'grid', 'countdown', 'racing', 'qualifying' }) do
  serverState({ phase = running, drivers = {} })
  local before = routeStartsAt()

  RM.setFinishLine(1234, 0, 0, 0, 1)
  check(routeStartsAt() == before, running .. ': setFinishLine is refused')

  veh.x, veh.y, veh.z = 500, 500, 0
  RM.editorAdd()
  local r = currentRoute()
  check(r and #r == 3, running .. ': editorAdd cannot place a gate')

  RM.editorClear()
  r = currentRoute()
  check(r and #r == 3, running .. ': editorClear cannot wipe the track')

  RM.removeCheckpoint(1)
  r = currentRoute()
  check(r and #r == 3, running .. ': removeCheckpoint is refused')
end

-- ...and every one of them works again the moment the session is over. A guard
-- that latched on would be a worse bug than the one it fixed.
serverState({ phase = 'waiting', drivers = {} })
RM.setFinishLine(1234, 0, 0, 0, 1)
check(routeStartsAt() == 1234, 'the editor works again once the session ends')
veh.x, veh.y, veh.z = 600, 600, 0
RM.editorAdd()
check(#currentRoute() == 2, 'and gates can be placed again')

-- The refusal is visible. A control that silently does nothing reads as broken.
local warned = false
for _, h in ipairs(hooks) do
  local msg = h.event == 'RaceManagerEditorMsg' and tostring(h.payload.msg) or ''
  if msg:find('session is running', 1, true) then warned = true end
end
check(warned, 'a refused editor action says why')

print(string.format('editor_buffer_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
