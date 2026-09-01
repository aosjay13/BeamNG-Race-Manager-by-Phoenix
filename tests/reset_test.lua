-- Headless test for the client-side vehicle-reset rules in
-- lua/ge/extensions/raceManager.lua (Module 1).
--
-- Why this exists: BeamNG reports a teleport as a vehicle reset, and the mod
-- teleports the car itself - a blocked reset puts it back where it was, and a
-- grid assignment stands it on its slot. Those teleports come straight back
-- through onVehicleResetted. Treated as a driver pressing reset, the blocked
-- case looped forever (restore -> hook -> restore ...), which pinned the car in
-- place and flooded the UI with notices until the game locked up, and the grid
-- case silently spent an allowance nobody used.
--
-- The extension is a GE module, so the BeamNG/BeamMP globals it calls are
-- stubbed here and the file is dofile'd like any other Lua module.
-- Run from the repo root: lua5.3 tests/reset_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs
-- ---------------------------------------------------------------------------
local sent      = {}   -- ordered { event, payload } sent to the server
local hooks     = {}   -- ordered { event, payload } pushed to the UI
local teleports = {}   -- every setPositionRotation the mod performed
local handlers  = {}   -- server -> client handlers the extension registered
local frozen    = nil  -- last controller.setFreeze the mod queued

local veh = {
  id = 7,
  x = 0, y = 0, z = 0,
  hx = 0, hy = 1,
  vx = 0, vy = 0, vz = 0,
}
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
-- A REAL ROTATION, because a constant one hides the bug this stub exists to
-- catch: the undo used to read the heading AFTER the recovery had moved the car,
-- so a driver was put back in the right place facing whichever way the spawn
-- point pointed. With `w` fixed at 1 forever, reading it at the wrong moment
-- gives the same answer as reading it at the right one.
veh.rz, veh.rw = 0, 1
function veh:getRotation() return { x = 0, y = 0, z = self.rz, w = self.rw } end
function veh:getDirectionVector() return { x = self.hx, y = self.hy, z = 0 } end
function veh:getVelocity() return { x = self.vx, y = self.vy, z = self.vz } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z, qx, qy, qz, qw)
  self.x, self.y, self.z = x, y, z
  teleports[#teleports + 1] = { x = x, y = y, z = z, qx = qx, qy = qy, qz = qz, qw = qw }
end
-- EVERY queued command, not just the last one. `frozen` kept only the most
-- recent, which was fine while the freeze was the only thing queued -- the
-- trailer re-couple is queued in the same breath and would have overwritten it.
local queued = {}
function veh:queueLuaCommand(cmd) frozen = cmd; queued[#queued + 1] = cmd end

-- Where BeamNG's own reset dropped the car before the mod hears about it.
local function driverPressedReset(x, y, z)
  veh.x, veh.y, veh.z = x, y, z
end

-- Two ways to reach the player's car. getPlayerVehicle(0) is the GE-side
-- accessor BeamNG's performance guide tells modders to use; be:getPlayerVehicle
-- is the old C++ round trip, kept in the extension only as a fallback for builds
-- without the former. Both are stubbed and counted, so the test can prove the
-- extension takes the fast path when it is available.
local engineAccessorCalls = 0
be     = { getPlayerVehicle = function ()
  engineAccessorCalls = engineAccessorCalls + 1
  return veh
end }
getPlayerVehicle = function (_) return veh end

-- A rival's car, for the ghost-qualifying fade. getAllVehicles() is the GE-side
-- vehicle list the extension walks; be:getObject/be:getObjectCount is the older
-- scene-object walk it falls back to (and is deliberately left unstubbed here,
-- so reaching for it would be an error rather than a silent no-op).
local remote = { id = 42, alpha = nil }
function remote:getID() return self.id end
function remote:setMeshAlpha(a) self.alpha = a end
getAllVehicles = function () return { veh, remote } end
-- BeamNG's input action filter: how the mod switches the reset keys off once
-- the allowance is spent. The stub records the current blocked state.
local inputsBlocked = false
-- GROUP-AWARE, because the mod now arms two of them and they mean different
-- things: 'raceManagerResets' kills the reset/recover keys when a driver's
-- allowance is spent, and 'raceManagerSpectate' kills the DRIVING keys for
-- somebody who is out of the session. `inputsBlocked` below tracks the reset
-- group, which is what every assertion in this file is about; a stub that
-- ignored the name let the spectate block masquerade as a reset block.
local blockedGroups = {}
core_input_actionFilter = {
  setGroup  = function (name, actions) blockedGroups[name] = blockedGroups[name] or false end,
  addAction = function (_, name, blocked)
    blockedGroups[name] = blocked
    if name == 'raceManagerResets' then inputsBlocked = blocked end
  end,
}
-- The saved setup the player is driving. From BeamNG v0.39 the name the player
-- typed lives on the config itself and the .pc filename is only a sanitised
-- derivative of it, so the two deliberately disagree here.
core_vehicle_partmgmt = {
  getConfig = function ()
    return {
      parts = { body = 'etk800_body' },
      vars  = { camber = -1.5 },
      configName = 'Cup Spec',
      partConfigFilename = '/vehicles/etk800/cup_spec_2026_v3.pc',
    }
  end,
}
beamng_version = '0.39.0.0'

vec3   = function (x, y, z) return { x = x, y = y, z = z } end
quat   = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log    = function () end
guihooks = { trigger = function (e, p) hooks[#hooks + 1] = { event = e, payload = p } end }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function (e, p) sent[#sent + 1] = { event = e, payload = p } end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
-- LuaJIT (BeamNG) still has math.atan2; 5.3 folded it into math.atan.
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

-- The extension `require`s its modules (raceManager/derby, and more to come),
-- so the headless harness has to be able to find them the way the game can.
-- One line, and it is what makes a split file testable at all.
package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

-- ---------------------------------------------------------------------------
-- Harness helpers
-- ---------------------------------------------------------------------------
-- Every broadcast from the current server plugin carries the protocol stamp;
-- the client drops anything without it (see the stale-copy test below).
local function serverState(t) t.rmProtocol = 2; handlers['RM_Update'](t) end
local function derbyState(t) t.rmProtocol = 2; handlers['RM_DerbyUpdate'](t) end
local function resetHook() RM.onVehicleResetted(veh.id) end
local function frames(seconds, step)
  step = step or 0.1
  for _ = 1, math.floor(seconds / step + 0.5) do RM.onUpdate(step) end
end

-- A grid slot no longer teleports the car on the tick it arrives: the placement
-- is QUEUED so a whole field can be ghosted and staggered rather than landing on
-- one another. Pumping a few very short frames here runs this client's turn in
-- that queue, and the steps are deliberately tiny -- the placement teleport is
-- recognized as our own for TUNE-sized window afterwards, and burning that
-- window in the harness would make the echo look like a driver reset.
local function gridAssign(slot, order, count)
  handlers['RM_GridAssign']({ slot = slot, order = order, count = count })
  frames(0.05, 0.01)
end
local function countSent(event)
  local n = 0
  for _, e in ipairs(sent) do if e.event == event then n = n + 1 end end
  return n
end
-- REFUSALS, which is what most of this file counts. A refused reset speaks on
-- its own channel now: spending your last one and being told there are none
-- left are different events, and the second is the one that changes what the
-- driver can do about the wall they are in.
local function countNotices()
  local n = 0
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerNotice' and h.payload.kind == 'resetsout' then n = n + 1 end
  end
  return n
end
local function lastRouteState()
  for i = #hooks, 1, -1 do
    if hooks[i].event == 'RaceManagerRoute' then return hooks[i].payload end
  end
end
local function clearLog() sent, hooks, teleports = {}, {}, {} end

-- ===========================================================================
-- TWO RESETS IN A ROW, on an unlimited-reset server
-- ===========================================================================
-- The reported failure: press one reset key, drive on, press the other, and land
-- where you reset the first time. The two keys were not disagreeing -- they were
-- both measuring against the same stale sample. The refresh that prevents it
-- existed but sat inside the ALLOWANCE check, so a server running unlimited
-- resets (the default) never ran it.
--
-- And the first fix for that cleared the reference instead of re-seeding it,
-- which left a hole: the next reset had nothing to undo itself with, so BeamNG's
-- teleport simply stood -- a recovery key putting a driver on their start
-- position in the middle of a lap.
do
  -- A route has to exist, because the reference the undo measures against is the
  -- crossing test's own per-frame sample -- and the crossing test does not run on
  -- a track with no gates. That is a real dependency, not a test detail: with no
  -- layout loaded there is nothing to undo a recovery teleport with.
  RM.setFinishLine(0, 500, 0, 0, 1)
  serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
  serverState({ phase = 'racing',  maxResets = -1, totalLaps = 3, drivers = {} })

  veh.x, veh.y, veh.z = 100, 0, 0
  frames(0.6)
  teleports = {}

  -- A recovery-style teleport: the car ends up a long way from where it was.
  veh.x, veh.y, veh.z = 900, 900, 0
  resetHook()
  check(#teleports == 1, 'the teleport is undone on an unlimited-reset server too')
  local back = teleports[#teleports]
  check(back and math.abs(back.x - 100) < 1 and math.abs(back.y - 0) < 1,
    'and puts the car back where it was, not where the game sent it')

  -- Drive on, then do it again. THIS is the one that used to land on the first
  -- reset's position: the reference has to have moved with the car.
  veh.x, veh.y, veh.z = 300, 0, 0
  frames(0.6)
  teleports = {}
  veh.x, veh.y, veh.z = 900, 900, 0
  resetHook()
  check(#teleports == 1, 'a second reset is undone as well')
  local back2 = teleports[#teleports]
  check(back2 and math.abs(back2.x - 300) < 1,
    'and lands where the car was THIS time, not where it reset before')
end

-- ===========================================================================
-- A reset inside the allowance is counted and left alone
-- ===========================================================================
serverState({ phase = 'waiting', maxResets = 1, totalLaps = 3, drivers = {} })
serverState({ phase = 'racing',  maxResets = 1, totalLaps = 3, drivers = {} })

veh.x, veh.y, veh.z = 100, 0, 0
frames(0.6)                                  -- rolling snapshot: (100, 0, 0)
clearLog()

-- An in-place recovery leaves the car where it stood, so this lands next to the
-- snapshot. Dropping it across the map here would BE a teleport, and the undo is
-- right to reverse one -- that is the whole point of the rule.
driverPressedReset(101, 1, 0)
resetHook()
check(countSent('RM_VehicleReset') == 1, 'a reset inside the allowance is reported to the server')
check(#teleports == 0, 'a legal reset is not undone')
check(lastRouteState().resetsUsed == 1, 'the allowance is spent')

-- ===========================================================================
-- The blocked reset: applied once, and its own restore is not heard back as a
-- fresh reset (the loop that froze the game)
-- ===========================================================================
veh.x, veh.y, veh.z = 200, 0, 0
frames(0.6)                                  -- new snapshot: (200, 0, 0)
clearLog()

driverPressedReset(5, 5, 0)
resetHook()
check(#teleports == 1, 'an over-allowance reset puts the car back')
check(teleports[1].x == 200 and teleports[1].y == 0,
  'the car is put back on its last good position')
check(countSent('RM_ResetDenied') == 1, 'the blocked attempt is reported once')
check(countSent('RM_VehicleReset') == 0, 'a blocked reset spends no allowance')
check(countNotices() == 1, 'the driver is told once')
check(lastRouteState() == nil, 'a blocked reset pushes no route state: nothing in it changed')

-- BeamNG now reports the restore itself as a vehicle reset. Repeatedly, the
-- way it would arrive frame after frame.
for _ = 1, 5 do resetHook() end
check(#teleports == 1, 'the restore is not heard back as a reset (no teleport loop)')
check(countSent('RM_ResetDenied') == 1, 'the echo is not reported to the server')
check(countNotices() == 1, 'the echo raises no second notice')

-- A genuine second attempt still gets blocked: the car moved somewhere the mod
-- did not put it.
driverPressedReset(-40, 12, 0)
resetHook()
check(#teleports == 2, 'a real second attempt is blocked too')
check(teleports[2].x == 200, 'and lands back on the same good position')
check(countNotices() == 1, 'repeat attempts inside the throttle window stay quiet')
check(countSent('RM_ResetDenied') == 1, 'and are not re-reported to the server')

-- Once the throttle window passes, the driver is told again.
frames(1.2)
driverPressedReset(-60, 20, 0)
resetHook()
check(countNotices() == 2, 'a later attempt reports again')
check(countSent('RM_ResetDenied') == 2, 'and reaches the server again')

-- ===========================================================================
-- Being placed on the starting grid is not a reset
-- ===========================================================================
serverState({ phase = 'waiting', maxResets = 1, totalLaps = 3, drivers = {} })

-- Place one start position at (300, 10, 0) facing +X.
RM.setEditorTarget('start')
veh.x, veh.y, veh.z = 300, 10, 0
veh.hx, veh.hy = 1, 0
RM.editorAdd()

serverState({ phase = 'countdown', maxResets = 1, totalLaps = 3, drivers = {} })
clearLog()
veh.x, veh.y, veh.z = 0, 0, 0               -- somewhere else when the grid forms
gridAssign(1)
check(#teleports == 1 and teleports[1].x == 300, 'the car is stood on its grid slot')
-- BeamNG vehicles face -Y at identity, so a +X heading is a yaw of
-- π/2 + π = 3π/2 (half-angle 3π/4) - without the half-turn the car stood
-- exactly 180° backwards on its slot.
check(math.abs(teleports[1].qz - math.sin(3 * math.pi / 4)) < 1e-6
  and math.abs(teleports[1].qw - math.cos(3 * math.pi / 4)) < 1e-6,
  'facing down the track (heading half-turned for the -Y vehicle forward)')
check(frozen == 'controller.setFreeze(1)', 'and held for the countdown')

-- The placement comes back through the same hook.
resetHook(); resetHook()
check(countSent('RM_VehicleReset') == 0, 'a grid placement never spends an allowance')
check(countSent('RM_ResetDenied') == 0, 'and is never reported as a blocked attempt')
check(#teleports == 1, 'and is not answered with another teleport')

-- A driver who resets off the grid is put back on their slot, facing the right
-- way: the slot is the good position, heading included.
frames(1.2)
serverState({ phase = 'countdown', maxResets = 0, totalLaps = 3, drivers = {} })
clearLog()
driverPressedReset(0, 0, 0)
resetHook()
check(#teleports == 1 and teleports[1].x == 300 and teleports[1].y == 10,
  'a reset on the grid is undone back to the slot')
check(math.abs(teleports[1].qz - math.sin(3 * math.pi / 4)) < 1e-6
  and math.abs(teleports[1].qw - math.cos(3 * math.pi / 4)) < 1e-6,
  'the restored car keeps the slot heading instead of snapping to identity')

-- ===========================================================================
-- Over the allowance, the reset INPUTS themselves go dead - and come back
-- the moment the session stops enforcing the rule
-- ===========================================================================
-- Still in the countdown with maxResets = 0 from the section above: the very
-- first frame should switch the reset actions off.
frames(0.2)
check(inputsBlocked == true, 'reset inputs are blocked once the allowance is spent')
serverState({ phase = 'waiting', maxResets = 0, totalLaps = 3, drivers = {} })
frames(0.2)
check(inputsBlocked == false, 'reset inputs are released when the session ends')

-- ===========================================================================
-- Broadcasts without the protocol stamp (an outdated server plugin copy
-- installed alongside) are dropped instead of flickering the UI
-- ===========================================================================
frames(1.2)
clearLog()
handlers['RM_Update']({ phase = 'racing', maxResets = 5, totalLaps = 9, drivers = {} })
local sawUpdate, sawStaleNotice = false, false
for _, h in ipairs(hooks) do
  if h.event == 'RaceManagerUpdate' then sawUpdate = true end
  if h.event == 'RaceManagerNotice' and h.payload.kind == 'server' then sawStaleNotice = true end
end
check(not sawUpdate, 'an unstamped broadcast never reaches the UI')
check(sawStaleNotice, 'the outdated-server-copy problem is reported to the driver')
clearLog()
handlers['RM_Update']({ rmProtocol = 2, phase = 'waiting', maxResets = 0, totalLaps = 3, drivers = {} })
sawUpdate = false
for _, h in ipairs(hooks) do
  if h.event == 'RaceManagerUpdate' then sawUpdate = true end
end
check(sawUpdate, 'a stamped broadcast still goes through')

-- ===========================================================================
-- "Last Checkpoint" reset mode: a legal reset respawns at the last gate
-- crossed instead of repairing in place
-- ===========================================================================
serverState({ phase = 'waiting', maxResets = -1, resetMode = 'checkpoint',
  totalLaps = 3, drivers = {} })
RM.setFinishLine(0, 50, 0, 0, 1)   -- one gate at (0, 50, 0), heading +Y
serverState({ phase = 'racing', maxResets = -1, resetMode = 'checkpoint',
  totalLaps = 3, drivers = {} })

-- Before any gate is crossed the mode has nothing to respawn at: in place.
veh.x, veh.y, veh.z = 0, 0, 0
frames(1.2)
clearLog()
driverPressedReset(1, 1, 0)
resetHook()
check(#teleports == 0, 'checkpoint mode before the first gate stays in place')

-- Drive through the gate, then reset somewhere else.
veh.x, veh.y, veh.z = 0, 45, 0
RM.onUpdate(0.1)                   -- prime prevPos behind the gate plane
veh.x, veh.y, veh.z = 0, 55, 0
RM.onUpdate(0.1)                   -- crossing: gate 1 is now the last checkpoint
frames(1.0)
clearLog()
driverPressedReset(30, 30, 0)
resetHook()
check(#teleports == 1 and teleports[1].x == 0 and teleports[1].y == 50,
  'a legal reset respawns the car at the last checkpoint crossed')
check(math.abs(teleports[1].qz - 1) < 1e-6 and math.abs(teleports[1].qw) < 1e-6,
  'facing the gate heading (+Y = a half-turn from the -Y vehicle forward)')
check(countSent('RM_VehicleReset') == 0,
  'unlimited resets: the relocation spends no allowance')
-- The relocation echoes back through the reset hook like every mod teleport.
resetHook()
check(#teleports == 1, 'the checkpoint respawn is not heard back as a fresh reset')

-- ===========================================================================
-- No resets at all in a derby (isolated from the race ruleset)
-- ===========================================================================
-- This was an ALLOWANCE, defaulting to unlimited -- which is to say defaulting
-- to off. A reset REPAIRS the car: in a demolition derby that undoes the entire
-- object of the exercise, and while it is available the stopped timer can
-- hardly ever decide anything, because a driver about to be counted out just
-- resets instead.
--
-- So there is no allowance to spend and no number to get wrong. The keys are
-- dead for the length of a running derby and come back when it ends.
serverState({ phase = 'waiting', maxResets = -1, resetMode = 'inplace',
  totalLaps = 3, drivers = {} })
derbyState({ derbyPhase = 'running', oobLimit = 5, demoLimit = 10, maxResets = -1,
  derbyTime = 0, boundary = {}, startPositions = {},
  players = { { id = 1, status = 'alive' } } })

veh.x, veh.y, veh.z = 500, 0, 0
frames(0.6)                                  -- rolling snapshot: (500, 0, 0)
clearLog()
driverPressedReset(5, 5, 0)
resetHook()
-- maxResets = -1 is the case that used to mean "unlimited", and is the one that
-- has to be dead now: it is the default, so it is what a derby actually runs on.
check(countSent('RM_DerbyVehicleReset') == 0,
  'the very first reset of a derby is refused, on the setting that used to '
    .. 'mean unlimited')
check(#teleports == 1 and teleports[1].x == 500,
  'and the car is put back where it was rather than left where it reset to')
check(countSent('RM_DerbyResetDenied') == 1, 'the blocked attempt is reported')
frames(0.2)
check(inputsBlocked == true, 'derby: the reset inputs are dead for the whole derby')

derbyState({ derbyPhase = 'finished', oobLimit = 5, demoLimit = 10, maxResets = -1,
  derbyTime = 20, boundary = {}, startPositions = {}, players = {} })
frames(0.2)
check(inputsBlocked == false, 'derby over: the reset inputs come back')

-- A RACE IS UNTOUCHED BY ANY OF THIS. The derby ruleset is meant to be
-- isolated, and "no resets" leaking into the circuit side would take the
-- allowance away from every driver on a race night.
serverState({ phase = 'racing', maxResets = 2, resetMode = 'inplace',
  totalLaps = 3, drivers = { { id = 1, laps = 0 } } })
frames(0.2)
check(inputsBlocked == false,
  'a race with resets left keeps its keys after the derby blocked them')

-- ===========================================================================
-- BeamNG v0.39 compatibility
-- ===========================================================================
-- The GE-side accessor is used wherever the extension needs the player's car;
-- the be:* round trip is only there for builds that lack it.
check(engineAccessorCalls == 0,
  'the player vehicle is read through getPlayerVehicle(0), not be:getPlayerVehicle')

-- v0.39 reworked the teleport detector ("reduce false positives/negatives in
-- extreme cases (such as ... really fast vehicles)"), so the echo of a teleport
-- the mod performed can land a frame or two after the teleport itself - by which
-- time a fast car is no longer sitting on the spot we put it. Judged against a
-- fixed radius that echo reads as a driver reset, and the driver gets dragged
-- back (or charged) for a reset they never pressed. The tolerance therefore
-- grows with the distance the car could actually have covered.
serverState({ phase = 'waiting', maxResets = 0, resetMode = 'inplace',
  totalLaps = 3, drivers = {} })
serverState({ phase = 'racing',  maxResets = 0, resetMode = 'inplace',
  totalLaps = 3, drivers = {} })
veh.x, veh.y, veh.z = 1000, 0, 0
veh.vx, veh.vy, veh.vz = 50, 0, 0            -- 180 km/h down +X
frames(1.2)                                  -- snapshot + notice throttle expiry
clearLog()

driverPressedReset(0, 0, 0)
resetHook()
check(#teleports == 1 and teleports[1].x == 1000, 'the over-allowance reset is undone')

-- Two frames later the delayed echo arrives, and the car has travelled 10 m.
frames(0.2)
veh.x = 1010
resetHook()
check(#teleports == 1,
  'a delayed teleport echo from a fast car is not miscounted as a driver reset')
check(countSent('RM_VehicleReset') == 0, 'and never spends an allowance')

-- The same delay and the same 10 m, but the car is stationary: it cannot have
-- got there on its own, so this is a real attempt and is blocked.
frames(1.2)
veh.x, veh.y, veh.z = 2000, 0, 0
veh.vx, veh.vy, veh.vz = 0, 0, 0
frames(0.6)                                  -- snapshot: (2000, 0, 0)
clearLog()
driverPressedReset(0, 0, 0)
resetHook()
check(#teleports == 1, 'a stationary car is restored')
frames(0.2)
veh.x = 2010                                 -- 10 m away with no speed to explain it
resetHook()
check(#teleports == 2, 'and a real follow-up attempt is still blocked')
veh.vx, veh.vy, veh.vz = 0, 0, 0

-- The vehicle/setup report the Garage List is built from: the setup is named
-- after the config, not after the .pc filename (v0.39 broke that equivalence),
-- and it carries the game build so the server can explain a Garage List that
-- stopped matching after a game update renamed vehicle parts.
clearLog()
RM.onVehicleSpawned(veh.id)

-- NOT ON THE SPAWN FRAME. BeamNG has not finished loading the vehicle's parts
-- when the object appears, so getConfig() answers with nothing and the
-- signature comes out as 'model=X|parts=' - which matches no Garage List entry
-- and got the car deleted as soon as the deletion started working. The spawn
-- arms the poll; the poll asks once the answer is knowable.
local function configReport()
  local found = nil
  for _, e in ipairs(sent) do
    if e.event == 'RM_VehicleConfig' then found = e.payload end
  end
  return found
end
check(configReport() == nil, 'nothing is declared on the frame the vehicle appears')
frames(1.2)
local report = configReport()
check(report ~= nil, 'the vehicle configuration is reported once the poll comes round')
check(report.partsSig == 'model=etk800|parts=body=etk800_body',
  'the parts half is sent separately, so tuning can be left free')
check(report.sig == report.partsSig .. '|vars=camber=-1.5000',
  'and the full signature is still the parts half plus the tuning')
check(report.label == 'etk800 - Cup Spec',
  'the setup is labeled with its real name, not the .pc filename stem')
check(report.game == '0.39.0.0', 'and the report carries the BeamNG build')

-- Ghost qualifying walks the spawned cars through getAllVehicles() and fades
-- everyone but the local driver.
serverState({ phase = 'qualifying', maxResets = -1, ghostQuali = true,
  totalLaps = 3, drivers = {} })
frames(0.2)
check(remote.alpha ~= nil and remote.alpha < 1, 'rivals are faded for ghost qualifying')
serverState({ phase = 'waiting', maxResets = -1, ghostQuali = true,
  totalLaps = 3, drivers = {} })
frames(0.2)
check(remote.alpha == 1, 'and solid again once qualifying ends')

-- ===========================================================================
-- BeamMP session lifecycle
-- ===========================================================================
-- Every regulation the server owns is APPLIED on this client and lifted by a
-- broadcast. Leaving the server means that broadcast is never coming, so the
-- mod has to lift them itself - otherwise a driver who disconnects mid-race is
-- dropped into singleplayer with a dead reset key, a frozen car and a camera
-- that reasserts freecam every second.
for _, hook in ipairs({ 'onBeamMPServerLeave', 'onServerLeave' }) do
  -- v4.22.0 renamed BeamMP's hooks with an onBeamMP* prefix; both names must
  -- work, because only one of them exists on any given BeamMP build.
  check(type(RM[hook]) == 'function', hook .. ' is handled')

  RM.setFinishLine(0, 50, 0, 0, 1)
  serverState({ phase = 'waiting',  maxResets = 0, totalLaps = 3, drivers = {} })
  serverState({ phase = 'countdown', maxResets = 0, totalLaps = 3, drivers = {} })
  handlers['RM_ForceSpectate']({ reason = 'You finished', source = 'race' })
  frames(0.2)
  check(inputsBlocked == false, hook .. ': setup - a spectator does not need blocked inputs')
  handlers['RM_ReleaseSpectate']({ source = 'race' })
  frames(0.2)
  check(inputsBlocked == true, hook .. ': setup - the reset keys are dead with no allowance')

  clearLog()
  RM[hook]()
  local st = lastRouteState()
  check(st ~= nil and #st.waypoints == 0, hook .. ' clears the placed track')
  check(st ~= nil and st.carTaken == false, hook .. ' lifts any spectator lock')
  check(st ~= nil and st.maxResets == -1, hook .. ' drops the reset allowance')
  frames(0.2)
  check(inputsBlocked == false, hook .. ' gives the reset keys back')
end

-- Joining: the extension can load before BeamMP's network extension is ready,
-- which left the mod deaf for the whole session. The join hook binds again and
-- asks the server for the current state a beat later, once its socket is up.
for _, hook in ipairs({ 'onBeamMPPostJoin', 'runPostJoin' }) do
  check(type(RM[hook]) == 'function', hook .. ' is handled')
  clearLog()
  RM[hook]()
  check(countSent('RM_RequestState') == 0, hook .. ' does not talk before the socket is up')
  frames(1.2)
  check(countSent('RM_RequestState') == 1, hook .. ' then asks the server for the live state')
  check(countSent('RM_RequestLayouts') == 1, hook .. ' and for the track layouts')
end

-- ===========================================================================
-- Being refused a reset is the event, not spending the last one
-- ===========================================================================
-- The first version of this announced it when the allowance hit zero, and the
-- test session said that was the wrong moment: spending your last reset still
-- GAVE you a reset, so nothing about the car had changed. The thing worth
-- interrupting a driver for is reaching for one and not getting it, which is
-- when they are sat in a wall deciding what to do.
--
-- And every refusal, not just the first: a driver who has forgotten and presses
-- reset three corners later needs the same answer. Silence there reads as the
-- key having broken.
--
-- PRIVATE by construction, which is what the brief asked for: pushNotice is a
-- guihook into one client's panel and never reaches the server, so there is no
-- lobby announcement to suppress. The only thing that leaves this client on
-- this path is the RM_ResetDenied that records the attempt.
local function noticesOfKind(kind)
  local out = {}
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerNotice' and h.payload.kind == kind then
      out[#out + 1] = h.payload
    end
  end
  return out
end
-- The running tally ("Reset 1/2 used: 1 left"), which is a different channel
-- from the refusal. Not every kind='reset' notice: a reset also explains what it
-- did to the car ("Recovered in place"), and that is not a tally.
local function tallyNotices()
  local out = {}
  for _, n in ipairs(noticesOfKind('reset')) do
    if tostring(n.msg):find('used:', 1, true) then out[#out + 1] = n end
  end
  return out
end

serverState({ phase = 'waiting', maxResets = 2, totalLaps = 3, drivers = {} })
serverState({ phase = 'racing',  maxResets = 2, totalLaps = 3, drivers = {} })
veh.x, veh.y, veh.z = 300, 0, 0
frames(0.6)
clearLog()

-- One of two: the ordinary tally.
driverPressedReset(301, 1, 0)
resetHook()
check(#noticesOfKind('resetsout') == 0, 'spending a reset that is not the last says nothing special')
check(#tallyNotices() == 1, 'it is the ordinary running tally')

-- TWO OF TWO. Still a reset they were entitled to, so still just the tally --
-- this is the moment the old version announced, and the one the test session
-- said was wrong.
veh.x, veh.y, veh.z = 400, 0, 0
frames(0.6)
clearLog()
driverPressedReset(401, 1, 0)
resetHook()
check(#noticesOfKind('resetsout') == 0,
  'spending the LAST reset is still just a reset: they got what they asked for')
check(#tallyNotices() == 1, 'and it is reported as the tally reaching zero')
check(countSent('RM_VehicleReset') == 1, 'and it is spent and reported like any other')

-- THE NEXT ONE IS REFUSED, and that is the event.
veh.x, veh.y, veh.z = 500, 0, 0
frames(0.6)
clearLog()
driverPressedReset(5, 5, 0)
resetHook()
local out = noticesOfKind('resetsout')
check(#out == 1, 'being refused a reset is announced')
check(out[1] and out[1].msg == "Uh oh! You're out of resets", 'in the words the brief asked for')
check(out[1] and out[1].sub and out[1].sub:find('All 2', 1, true) ~= nil,
  'and says how many they had')
check(countSent('RM_ResetDenied') == 1, 'and the attempt is recorded on the server')
check(#tallyNotices() == 0, 'a refused attempt spends nothing, so there is no tally line')

-- AND AGAIN, three corners later. The throttle below is about a HELD key, not
-- about repeat attempts, so a genuinely separate press says it again.
frames(1.5)
veh.x, veh.y, veh.z = 600, 0, 0
frames(0.6)
clearLog()
driverPressedReset(6, 6, 0)
resetHook()
check(#noticesOfKind('resetsout') == 1, 'and again on the next attempt, not only the first')

-- ...but a HELD key is one attempt, not forty. This is the flood guard, and the
-- reason it is a throttle rather than a once-only latch.
clearLog()
for _ = 1, 20 do driverPressedReset(7, 7, 0); resetHook() end
check(#noticesOfKind('resetsout') == 0,
  'a held reset key inside the throttle window does not repeat it')

-- A session with no resets AT ALL is a different sentence: those drivers never
-- had one to run out of.
serverState({ phase = 'waiting', maxResets = 0, totalLaps = 3, drivers = {} })
serverState({ phase = 'racing',  maxResets = 0, totalLaps = 3, drivers = {} })
veh.x, veh.y, veh.z = 700, 0, 0
frames(1.5)
clearLog()
driverPressedReset(701, 1, 0)
resetHook()
local none = noticesOfKind('resetsout')
check(#none == 1 and none[1].msg == 'No resets in this session',
  'a session with no resets says so, rather than that you have run out of them')


-- ===========================================================================
-- A coupled trailer goes back on after the mod moves the car
-- ===========================================================================
-- BeamNG treats a trailer as a second vehicle that belongs to the same driver,
-- so a grid placement brings it along -- and drops it DETACHED. Every trailer
-- race so far has started with the driver re-coupling by hand before the
-- countdown.
--
-- beamstate.attachCouplers() is exactly that manual re-couple: it is the onDown
-- of BeamNG's own couplersLock action.
local function queuedHas(what)
  for _, c in ipairs(queued) do
    if tostring(c):find(what, 1, true) then return true end
  end
  return false
end

-- A SLOT TO BE PLACED ON. Without one, RM_GridAssign has nowhere to put the car,
-- no teleport happens, and every assertion below passes or fails for want of a
-- start position rather than for anything to do with trailers.
serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
RM.setEditorTarget('start')
veh.x, veh.y, veh.z = 300, 10, 0
veh.hx, veh.hy = 1, 0
RM.editorAdd()
RM.setEditorTarget('main')

-- Nothing coupled: the mod must not reach out and grab whatever is parked
-- alongside. On a packed grid that is a worse bug than the one being fixed.
core_vehicles = { attachedCouplers = {} }
serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
veh.x, veh.y, veh.z = 0, 0, 0
frames(0.6)
queued = {}
gridAssign(1, 1, 1)
resetHook()
check(not queuedHas('attachCouplers'),
  'a car with no trailer does not couple to whatever is beside it on the grid')

-- With a trailer attached, the coupling is put back.
core_vehicles = { attachedCouplers = { { veh.id, 99, 12, 34 } } }
serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
veh.x, veh.y, veh.z = 0, 0, 0
frames(0.6)
queued = {}
gridAssign(1, 1, 1)
resetHook()

-- NOT WHILE THE CAR IS STILL GHOSTED, which is the whole bug.
--
-- A field placement ghosts the car so the grid can land through itself, and a
-- ghosted vehicle has no collisions for a coupler to find. The first version of
-- this fired in the vehicle-reset echo -- during the placement, mid-ghost -- so
-- attachCouplers did nothing whatsoever and the trailer still arrived loose.
check(not queuedHas('attachCouplers'),
  'nothing is coupled while the placement ghost is still on: there are no '
    .. 'collisions for the coupler to find')

-- ...and once the field has settled and collisions are back, it goes on.
frames(3.5)
check(queuedHas('attachCouplers'), 'a coupled trailer is re-attached once the ghost lifts')
check(frozen ~= nil, 'and the grid hold still went on alongside it')

-- The pair can name our vehicle on EITHER side: which end of the coupling a
-- vehicle is on says nothing about whose trailer it is.
core_vehicles = { attachedCouplers = { { 99, veh.id, 34, 12 } } }
serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
veh.x, veh.y, veh.z = 0, 0, 0
frames(0.6)
queued = {}
gridAssign(1, 1, 1)
resetHook()
frames(3.5)
check(queuedHas('attachCouplers'), 'and found when our id is the second of the pair')

-- A DRIVER's own reset is not our teleport, so nothing is re-coupled: BeamNG
-- keeps the trailer through one of those on its own, which is why this was only
-- ever a problem on the grid.
core_vehicles = { attachedCouplers = { { veh.id, 99, 12, 34 } } }
serverState({ phase = 'racing', maxResets = 5, totalLaps = 3, drivers = {} })
veh.x, veh.y, veh.z = 500, 0, 0
frames(0.6)
queued = {}
driverPressedReset(501, 1, 0)
resetHook()
frames(3.5)
check(not queuedHas('attachCouplers'),
  'a driver reset is left alone: the game keeps the trailer through those itself')

-- The extension being absent costs the trailer, not the teleport.
core_vehicles = nil
serverState({ phase = 'waiting', maxResets = -1, totalLaps = 3, drivers = {} })
veh.x, veh.y, veh.z = 0, 0, 0
frames(0.6)
queued = {}
local okPlace = pcall(function () gridAssign(1, 1, 1); resetHook(); frames(3.5) end)
check(okPlace, 'a build without core_vehicles still places the car on the grid')

-- ===========================================================================
-- THE HOME KEY, and the order that made it invisible
-- ===========================================================================
-- Home is bound to loadHome, and the game's own action definition is:
--
--   obj:queueGameEngineLua('extensions.hook("trackVehReset")') recovery.loadHome()
--
-- ...while recovery.loadHome() is:
--
--   obj:requestReset(RESET_PHYSICS)      -- the reset fires HERE
--   setRecoveryPoint(M.homePoint, ...)   -- the teleport happens AFTER it
--
-- So onVehicleResetted arrives while the car is still sitting at the crash site.
-- The undo there measured no movement, stood down, and the teleport landed a
-- frame later with nothing watching -- which is exactly how a driver pressing
-- the key they press every other day ended up at the far end of the map, still
-- classified and still being timed.
--
-- The sequence below is that order, faithfully. A test that teleported first and
-- reset second would pass against the old code.
-- A CLEAN SESSION FIRST. This file is long and earlier sections leave a driver
-- spectating, held, or out of resets; every one of those is a reason the watch
-- deliberately stands down, so inheriting one would make these checks pass or
-- fail on what ran before them.
handlers['RM_ReleaseSpectate']({ source = 'race' })
serverState({ phase = 'racing', maxResets = -1, totalLaps = 5, drivers = {} })
frames(0.2)
veh.x, veh.y, veh.z = 100, 200, 0
frames(0.3)                       -- the mod samples where the car is

teleports = {}
RM.trackVehReset()                -- the hook the action fires...
resetHook()                       -- ...and the reset, with the car UNMOVED
veh.x, veh.y, veh.z = 1500, -900, 0   -- ...and only now the teleport lands
frames(0.3)
check(math.abs(veh.x - 100) < 1 and math.abs(veh.y - 200) < 1,
  'a recovery that teleports AFTER its reset is undone: the driver is put back '
    .. 'where they were (got ' .. veh.x .. ', ' .. veh.y .. ')')

-- ...and the repair is kept. Undoing the teleport must not undo the recovery:
-- the driver asked for a reset and gets one, in place, which is the whole point.
check(#teleports > 0, 'the mod moved the car back itself')

-- A RECOVERY THAT DID NOT MOVE THE CAR is left alone. The in-place reset key
-- lands here on every press, and snapping a car that never moved would be a
-- teleport where there was none.
-- Nudged rather than jumped: the car is left where the undo above put it and
-- moved a couple of metres, which is what an in-place recovery looks like. A
-- test that teleported it across the map first would be asking the mod to
-- ignore a teleport, which is the opposite of the rule being checked -- and
-- would trip the older undo in onVehicleResetted besides.
veh.x, veh.y = veh.x + 2, veh.y + 1
frames(0.3)
teleports = {}
local atX, atY = veh.x, veh.y
RM.trackVehReset()
resetHook()
frames(0.3)
check(#teleports == 0, 'an in-place recovery is not interfered with')
check(math.abs(veh.x - atX) < 1 and math.abs(veh.y - atY) < 1,
  'and the car stays where it recovered')

-- THE WATCH IS ONLY EVER ARMED BY A RESET. This is the guard that sank the first
-- attempt at this fix: a version that watched every frame could not tell a
-- teleport from a fast car, and would drag a LEADING driver backwards for going
-- quickly. Moving a long way with no reset behind it must be left alone.
veh.x, veh.y, veh.z = 500, 500, 0
frames(0.3)
teleports = {}
veh.x, veh.y, veh.z = 2500, 2500, 0    -- a huge jump, no reset requested
frames(0.5)
check(#teleports == 0,
  'a car that moves a long way without a reset behind it is NOT touched')

-- OUT OF THE SESSION, a driver may recover wherever they like: they are not
-- being scored for where it ends up.
serverState({ phase = 'racing', maxResets = -1, totalLaps = 5, drivers = {},
  spectatorLock = true })
handlers['RM_ForceSpectate']({ reason = 'test' })
veh.x, veh.y, veh.z = 600, 600, 0
frames(0.3)
teleports = {}
RM.trackVehReset()
veh.x, veh.y, veh.z = 3000, 3000, 0
frames(0.5)
check(#teleports == 0, 'a driver out of the session recovers freely')

-- ===========================================================================
-- ...AND FACING THE WAY THEY WERE
-- ===========================================================================
-- Reported from a live server: the undo put the driver back on the track at
-- ninety degrees to it. The position was captured when the key was pressed and
-- the HEADING was read at undo time -- which is the heading of wherever the
-- recovery had just dumped the car.
handlers['RM_ReleaseSpectate']({ source = 'race' })
serverState({ phase = 'racing', maxResets = -1, totalLaps = 5, drivers = {} })
frames(0.2)
veh.x, veh.y, veh.z = 700, 700, 0
veh.rz, veh.rw = 0.3827, 0.9239        -- 45 degrees: the driver's own heading
frames(0.3)

teleports = {}
RM.trackVehReset()
resetHook()
veh.rz, veh.rw = 0.9239, 0.3827        -- the spawn faces somewhere else entirely
veh.x, veh.y, veh.z = 4000, 4000, 0
frames(0.3)
check(#teleports >= 1, 'the teleport is undone')
local back = teleports[#teleports]
check(back and math.abs(back.qz - 0.3827) < 0.001
  and math.abs(back.qw - 0.9239) < 0.001,
  'and the driver is put back on THEIR heading, not the spawn point\'s (got z='
    .. tostring(back and back.qz) .. ')')

-- ===========================================================================
-- A TELEPORT THAT LANDS LATE
-- ===========================================================================
-- Also from the live server: it worked twice and put the driver at their spawn
-- the third time. loadHome calls obj:requestReset first, which reloads the
-- vehicle's Lua VM, and only then teleports -- so on a loaded server the move
-- can land most of a second after the key, and the window used to have closed.
veh.x, veh.y, veh.z = 800, 800, 0
veh.rz, veh.rw = 0, 1
frames(0.3)
teleports = {}
RM.trackVehReset()
resetHook()
frames(1.5)                             -- a long, slow vehicle reload
veh.x, veh.y, veh.z = 5000, 5000, 0     -- ...and only NOW does the teleport land
frames(0.3)
check(#teleports >= 1,
  'a teleport that lands a second and a half after the key is still caught')
check(math.abs(veh.x - 800) < 1 and math.abs(veh.y - 800) < 1,
  'and the driver goes back where they were (got ' .. veh.x .. ', ' .. veh.y .. ')')

-- ...WITHOUT DRAGGING BACK A DRIVER WHO SIMPLY DROVE OFF. The window is three
-- seconds now, and a car pulling away from a reset covers well over the old
-- twenty-five metre threshold inside it. Only a JUMP counts, so continuous
-- movement -- however far it adds up to -- is left alone.
veh.x, veh.y, veh.z = 900, 900, 0
frames(0.3)
RM.trackVehReset()
resetHook()
frames(0.1)
-- WHERE THE CAR ACTUALLY IS once the reset has settled, which is not necessarily
-- where it was put: the older undo in onVehicleResetted fires here too, because
-- prevPos goes stale in a harness with no route loaded. What is being checked is
-- that the WATCH leaves a driver alone from here on, so the reference is here.
teleports = {}
local droveFrom = veh.y
veh.vy = 30                             -- driving away at about 110 km/h
for _ = 1, 25 do                        -- 2.5s of it, a couple of metres a frame
  veh.y = veh.y + 3
  RM.onUpdate(0.1)
end
veh.vy = 0
check(#teleports == 0,
  'a driver who accelerates away from their reset is NOT dragged back, however '
    .. 'far they get')
check(math.abs(veh.y - (droveFrom + 75)) < 1,
  'and keeps every metre of it (drove ' .. (veh.y - droveFrom) .. ' m of 75)')

if fails == 0 then
  print('reset_test: ' .. checks .. ' checks, 0 failures')
else
  print('reset_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
