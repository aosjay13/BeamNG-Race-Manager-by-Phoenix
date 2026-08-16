-- Headless test for grid HOLD enforcement, across both halves of the mod:
--   * client (lua/ge/extensions/raceManager.lua) - the freeze, the drift watch
--     and the paths that used to lose the hold silently
--   * server (server/RaceManager/main.lua)       - position validation, the
--     correction and the audit line
--
-- Why this exists: the hold used to be a single fire-and-forget freeze issued at
-- grid placement, with nothing verifying it and nothing re-asserting it. The
-- placement teleport is reported back by BeamNG as a vehicle reset, and a reset
-- reloads the vehicle's Lua VM and takes the freeze with it. The re-apply only
-- ran when that report was recognised as our own echo - inside a 0.6 s window
-- so three ordinary things left the car free for the whole countdown:
--
--   * the report arriving later than the window (a loaded client on a full grid)
--   * the driver pressing reset on the grid
--   * the driver reloading or respawning their vehicle on the grid
--
-- and because nothing re-asserted the freeze, any one of them was permanent. The
-- driver simply drove away before the lights. Every case below is one of those.
--
-- Run from the repo root: lua5.3 tests/hold_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ===========================================================================
-- Part 1 - the client
-- ===========================================================================
local sent, hooks, handlers = {}, {}, {}
local frozen = nil            -- last setFreeze value that reached the vehicle
local VEH_ID = 7
local SLOT_X, SLOT_Y = 50, 50

local veh = { id = VEH_ID, x = 0, y = 0, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
veh.vx, veh.vy, veh.vz = 0, 0, 0
function veh:getVelocity() return { x = self.vx, y = self.vy, z = self.vz } end
function veh:getJBeamFilename() return 'etk800' end
-- Teleports are counted, not just applied. A teleport is what BeamNG reports
-- back as a vehicle reset, and that report is what the placement loop was built
-- from - so "did this move the car" and "did this provoke a reset" are the same
-- question, and several cases below turn on the answer being no.
teleports = 0
function veh:setPositionRotation(x, y, z)
  self.x, self.y, self.z = x, y, z
  teleports = teleports + 1
end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end
function veh:getSpawnWorldOOBB() return nil end

getPlayerVehicle = function () return veh end
be = { getPlayerVehicle = function () return veh end, enterVehicle = function () end }
getAllVehicles = function () return { veh } end
getObjectByID = function (id) return id == VEH_ID and veh or nil end
MPVehicleGE = {
  isOwn = function (id) return id == VEH_ID end,
  getVehicles = function () return { { ownerID = 1, gameVehicleID = VEH_ID } } end,
}

-- BeamNG's freeze bridge, and the thing that undoes it. A vehicle reset reloads
-- the vehicle's Lua VM, so whatever freeze was on it is gone.
core_vehicleBridge = {
  executeAction = function (_, action, value)
    if action == 'setFreeze' then frozen = value end
  end,
}
local function engineResetsVehicle() frozen = false end

core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
core_vehicles = { removeCurrent = function () end }
beamng_version = '0.39.4.0'
vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }
MPGameNetwork = {}
MPConfig = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

-- The extension `require`s its modules (raceManager/derby, and more to come),
-- so the headless harness has to be able to find them the way the game can.
-- One line, and it is what makes a split file testable at all.
package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function frames(seconds, step)
  step = step or 0.05
  for _ = 1, math.floor(seconds / step + 0.5) do RM.onUpdate(step) end
end
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end
local function countSent(event)
  local n = 0
  for _, e in ipairs(sent) do if e.event == event then n = n + 1 end end
  return n
end
local function onSlot()
  return math.abs(veh.x - SLOT_X) < 0.01 and math.abs(veh.y - SLOT_Y) < 0.01
end

-- A track with one start position, at (50, 50).
RM.setEditorTarget('start')
veh.x, veh.y, veh.z = SLOT_X, SLOT_Y, 0
RM.editorAdd()
RM.setEditorTarget('main')

-- Put this client on the grid and settle the placement, which is the state every
-- case below starts from: on the slot, frozen, countdown not yet finished.
-- Place the car and let the placement reset land, but stop there: the car is on
-- its slot and still settling onto its suspension.
local function gridUpRaw()
  sent, hooks = {}, {}
  serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
  serverState({ phase = 'grid', maxResets = -1, totalLaps = 3, drivers = {} })
  handlers['RM_GridAssign']({ slot = 1, order = 1, count = 11 })
  frames(0.3, 0.02)
  engineResetsVehicle()          -- the placement teleport reports as a reset...
  RM.onVehicleResetted(VEH_ID)   -- ...and the echo puts the freeze back
end

-- The same, then run on until the car has settled. This is the state a grid is
-- actually in for almost all of a countdown, and what every case below the
-- settling ones starts from.
local function gridUp()
  gridUpRaw()
  veh.vx, veh.vy, veh.vz = 0, 0, 0
  frames(2.0)
  sent, hooks = {}, {}
end

gridUp()
check(frozen == true, 'placement puts the car on its slot and freezes it')
check(onSlot(), 'and the car is standing on the slot')

-- ===========================================================================
-- Settling is not creeping
-- ===========================================================================
-- A car dropped onto a start position falls onto its suspension: it MOVES, and
-- it ends up below the height it was placed at. Enforcing against that is what
-- turned this guard into a loop in the first live test -- it teleported the car
-- back up to the drop height, the teleport was reported as a vehicle reset, and
-- the car hovered there being reset every frame, spamming the console.
--
-- Three things stop that, and each is checked here: a placed car is left alone
-- until it comes to rest; where it comes to rest is what drift is measured from;
-- and movement alone is answered by re-pinning the car where it stands rather
-- than by teleporting it anywhere.

-- 1. Freezing a car mid-drop would pin it in the air, so nothing at all touches
--    it while it is still falling.
gridUpRaw()
local freezeCalls = 0
core_vehicleBridge.executeAction = function (_, action, value)
  if action == 'setFreeze' then frozen = value; freezeCalls = freezeCalls + 1 end
end
teleports, freezeCalls = 0, 0
veh.vz = -4.0                           -- falling fast onto the suspension
frames(0.5)
check(teleports == 0, 'a falling car is not teleported while it settles')
check(freezeCalls == 0, 'and is not re-frozen mid-air, which would pin it hovering')

-- 2. It lands well below the height it was dropped at. That is not creeping.
veh.z = veh.z - 1.50
veh.vz = 0
frames(4.0)
teleports, freezeCalls = 0, 0
frames(5.0)
check(teleports == 0,
  'a car resting far below the slot height is never dragged back up')
check(freezeCalls == 0, 'and is not re-frozen for standing still')

-- 3. Movement ON the slot is answered by re-pinning, never by a teleport. The
--    teleport is what BeamNG reports back as a vehicle reset, and the reset is
--    what the loop was made of.
teleports, freezeCalls = 0, 0
veh.vy = 3.0                            -- freeze lost, car starting to roll
frames(0.2)
check(freezeCalls > 0, 'a car moving on its slot is re-pinned')
check(teleports == 0, 'and is NOT teleported, so no vehicle reset is provoked')
veh.vy = 0

-- 4. Sinking further after it has settled is still not creeping. Measured in
--    three dimensions this would read as a metre of movement and drag the car
--    back up; measured across the ground, which is the only direction a car can
--    steal a start in, it reads as nothing.
gridUp()
teleports = 0
veh.z = veh.z - 1.20
frames(1.0)
check(teleports == 0, 'sinking a metre on its suspension is not creeping')
check(veh.x == SLOT_X and veh.y == SLOT_Y, 'and the car is left where it stands')

-- 5. The settle grace is not a window in which the hold is off: a car that
--    drives away before it has settled is still caught.
gridUpRaw()
teleports = 0
veh.y = veh.y + 3.0                     -- driving off, mid-settle
frames(0.2)
check(teleports > 0, 'a car leaving before it settles is put back')
check(onSlot(), 'and lands back on its slot')

-- 6. Actually leaving the slot horizontally is still caught, and that one does
--    put the car back.
gridUp()
teleports = 0
veh.y = veh.y + 2.0
frames(0.2)
check(teleports > 0, 'a car that has crept off its slot is put back')
check(onSlot(), 'and lands back on the slot')

-- ===========================================================================
-- A car that is behaving is left completely alone
-- ===========================================================================
-- This matters as much as the corrections do. Re-applying the freeze re-pins the
-- car and resets the drivetrain, so revs bleed away and a pre-selected gear will
-- not stick - and revving against the hold is the whole point of a standing
-- start. So the guard has to be driven by observed movement, never by a timer.
local freezeCallsBefore = 0
core_vehicleBridge.executeAction = function (_, action, value)
  if action == 'setFreeze' then frozen = value; freezeCallsBefore = freezeCallsBefore + 1 end
end
frames(5.0)
check(freezeCallsBefore == 0,
  'a stationary held car is never re-frozen: revs and gear selection survive')
check(frozen == true, 'and it is still held')

-- ===========================================================================
-- The three ways the hold used to be lost silently
-- ===========================================================================

-- (1) A driver presses reset on the grid. The reset reloads the vehicle VM and
-- takes the freeze with it; nothing used to put it back.
gridUp()
veh.x, veh.y = SLOT_X + 3, SLOT_Y + 3   -- a real reset moves the car
engineResetsVehicle()
RM.onVehicleResetted(VEH_ID)
check(frozen == true, 'a driver reset on the grid leaves the car HELD')
check(onSlot(), 'and puts it back on its assigned slot')

-- (2) The driver reloads or respawns their vehicle on the grid. The new car
-- arrives with no freeze on it at all.
gridUp()
engineResetsVehicle()
veh.x, veh.y = SLOT_X + 5, SLOT_Y
RM.onVehicleSpawned(VEH_ID)
check(frozen == true, 'a vehicle respawned on the grid comes back HELD')
check(onSlot(), 'and back on its assigned slot')

-- (3) The freeze is lost some other way - the placement report arriving after
-- the 0.6 s echo window is the real-world case, and on a loaded client with a
-- full grid that is not exotic. The guard does not need to know WHY: it watches
-- for the symptom, which is a car that has moved off its slot.
gridUp()
frozen = false                          -- freeze silently gone
veh.x = SLOT_X + 1.0                    -- and the car starts to creep
frames(0.2)
check(frozen == true, 'a car creeping off its slot is re-frozen')
check(onSlot(), 'and pulled back onto the slot')

-- A car that has lost its freeze but has not gone anywhere yet is caught by its
-- VELOCITY, before it has covered the drift tolerance. A frozen car has none, so
-- any movement at all means the freeze is already gone - and at launch speeds a
-- third of a metre of grace is half a car length of stolen start.
gridUp()
frozen = false
veh.vy = 3.0                            -- rolling, but still on the slot
frames(0.05)
check(frozen == true, 'a held car that is MOVING is re-frozen before it drifts')
check(onSlot(), 'and has not left its slot to do it')
veh.vy = 0

-- Creep smaller than the tolerance is ignored, so a car settling on its
-- suspension is not fought with.
gridUp()
freezeCallsBefore = 0
veh.x = SLOT_X + 0.1
frames(0.5)
check(freezeCallsBefore == 0, 'settling inside the tolerance is left alone')

-- ===========================================================================
-- The server is told where the car is, and can pull it back
-- ===========================================================================
gridUp()
sent = {}
frames(1.0)
check(countSent('RM_HoldPos') >= 3, 'a held car reports its position to the server')
check(countSent('RM_HoldPos') <= 6,
  'and does so on a cadence, not once a frame - a full grid must not flood')

-- The server's correction is obeyed even when the local guard has not fired,
-- and it carries the slot coordinates so a client with a stale layout still
-- lands in the right place.
gridUp()
veh.x, veh.y = 900, 900                 -- somehow well off the grid
handlers['RM_HoldCorrect']({ x = SLOT_X, y = SLOT_Y, z = 0, hx = 0, hy = 1,
  reason = 'test' })
check(frozen == true, 'a server correction re-freezes the car')
check(onSlot(), 'and puts it back on the slot the server named')

-- ===========================================================================
-- Release
-- ===========================================================================
gridUp()
handlers['RM_Countdown']({ count = 0 })
check(frozen == false, 'countdown zero releases the car')

-- ...and the drift watch lets go with it. A car that is racing must never be
-- dragged back onto a grid slot it legitimately left at the lights.
veh.x, veh.y = SLOT_X + 200, SLOT_Y
serverState({ phase = 'racing', maxResets = -1, totalLaps = 3, drivers = {} })
sent = {}
frames(1.0)
check(veh.x == SLOT_X + 200, 'a released car is not pulled back to its grid slot')
check(countSent('RM_HoldPos') == 0, 'and stops reporting hold positions')

-- A reset once racing is an ordinary reset again, not a hold restore.
sent = {}
veh.x = SLOT_X + 300
RM.onVehicleResetted(VEH_ID)
check(veh.x == SLOT_X + 300, 'a reset while racing does not teleport to the grid')

print(string.format('hold_test (client): %d checks, %d failures', checks, fails))

-- ===========================================================================
-- Part 2 - the server
-- ===========================================================================
-- Fresh globals: the server plugin is Lua 5.3 with the MP.* API and knows
-- nothing about the client stubs above.
for _, name in ipairs({ 'getPlayerVehicle', 'be', 'getAllVehicles', 'getObjectByID',
    'MPVehicleGE', 'core_vehicleBridge', 'core_input_actionFilter',
    'core_vehicle_partmgmt', 'core_vehicles', 'guihooks', 'MPGameNetwork',
    'MPConfig', 'TriggerServerEvent', 'AddEventHandler', 'jsonEncode',
    'jsonDecode', 'vec3', 'quat', 'log' }) do
  _G[name] = nil
end

local connected = { [1] = 'Alice', [2] = 'Bob' }
local corrections = {}   -- ordered RM_HoldCorrect payloads, with their target
local lastState = nil

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function () end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    if event == 'RM_Update' then lastState = payload end
    if event == 'RM_HoldCorrect' then
      corrections[#corrections + 1] = { pid = target, payload = payload }
    end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/gridmap_v2/info.json' end,
}
Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    if type(s) ~= 'string' then return s end
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

dofile('server/RaceManager/main.lua')
onInit()
RM_onLogin(1, '{"password":"phoenix"}')
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onJoinRace(1, '{"join":true}')
RM_onJoinRace(2, '{"join":true}')

-- The grid geometry. Two slots, 10 m apart down the track.
RM_onStartPositionCount(1, '{"count":2,"positions":['
  .. '{"x":0,"y":0,"z":0,"hx":0,"hy":1},'
  .. '{"x":0,"y":-10,"z":0,"hx":0,"hy":1}]}')
check(lastState.startSlots == 2, 'the server learns the grid has two slots')

RM_onGenerateGrid(1)
check(lastState.phase == 'grid', 'a grid is formed')

-- A car sitting on its slot is not touched.
corrections = {}
RM_onHoldPos(1, '{"x":0,"y":0,"z":0}')
check(#corrections == 0, 'a car on its slot draws no correction')

-- Inside the tolerance: still fine.
RM_onHoldPos(1, '{"x":0.3,"y":0,"z":0}')
check(#corrections == 0, 'movement inside the 0.5m tolerance is tolerated')

-- Creeping forward beyond it is corrected, and the correction names the slot.
RM_onHoldPos(1, '{"x":0,"y":2.5,"z":0}')
check(#corrections == 1, 'a car 2.5m off its slot is corrected')
check(corrections[1].pid == 1, 'the correction goes to the offending driver')
local p = corrections[1].payload
check(p.x == 0 and p.y == 0, 'and carries the coordinates of that driver\'s slot')

-- Each driver is judged against their OWN slot, not the pole slot.
corrections = {}
RM_onHoldPos(2, '{"x":0,"y":-10,"z":0}')
check(#corrections == 0, 'the driver on slot 2 is judged against slot 2')
RM_onHoldPos(2, '{"x":0,"y":0,"z":0}')
check(#corrections == 1, 'and is corrected for standing on slot 1 instead')
check(corrections[1].payload.y == -10, 'back to slot 2, not slot 1')

-- Corrections are rate-limited per driver: a car being shoved by someone else
-- must not generate one per report for as long as the shoving lasts.
corrections = {}
for _ = 1, 10 do RM_onHoldPos(1, '{"x":0,"y":5,"z":0}') end
check(#corrections <= 1, 'repeat reports inside the cooldown draw one correction')

-- Nothing is policed once the race is running: a car 200 m from its grid slot
-- is a car that has driven away, which is the entire idea.
RM_onStartCountdown(1)
for _ = 1, 4 do RM_CountdownTick() end
check(lastState.phase == 'racing', 'the countdown released the field')
corrections = {}
RM_onHoldPos(1, '{"x":0,"y":200,"z":0}')
check(#corrections == 0, 'a racing car is never corrected onto a grid slot')

-- A grid whose coordinates the server was never told is left to the clients
-- rather than policed against a grid it does not have.
RM_onEndRace(1)
RM_onResetLeaderboard(1)
for id in pairs(connected) do RM_onPlayerJoin(id) end
RM_onJoinRace(1, '{"join":true}')
-- A count-only report from an older client, for a grid that is no longer the
-- one whose coordinates the server holds. What it has is stale: slot 1 is not
-- where it thinks it is any more.
RM_onStartPositionCount(1, '{"count":3}')   -- count only, and it disagrees
RM_onGenerateGrid(1)
corrections = {}
RM_onHoldPos(1, '{"x":0,"y":999,"z":0}')
check(#corrections == 0,
  'a grid whose coordinates no longer match the slot count is not policed')

print(string.format('hold_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
