-- Headless test for the client-side vehicle-reset rules in
-- lua/ge/extensions/raceManager.lua (Module 1).
--
-- Why this exists: BeamNG reports a teleport as a vehicle reset, and the mod
-- teleports the car itself — a blocked reset puts it back where it was, and a
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
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = self.hx, y = self.hy, z = 0 } end
function veh:getVelocity() return { x = self.vx, y = self.vy, z = self.vz } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation(x, y, z, qx, qy, qz, qw)
  self.x, self.y, self.z = x, y, z
  teleports[#teleports + 1] = { x = x, y = y, z = z, qx = qx, qy = qy, qz = qz, qw = qw }
end
function veh:queueLuaCommand(cmd) frozen = cmd end

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
-- recognised as our own for TUNE-sized window afterwards, and burning that
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
local function countNotices()
  local n = 0
  for _, h in ipairs(hooks) do
    if h.event == 'RaceManagerNotice' and h.payload.kind == 'reset' then n = n + 1 end
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
-- π/2 + π = 3π/2 (half-angle 3π/4) — without the half-turn the car stood
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
-- Over the allowance, the reset INPUTS themselves go dead — and come back
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
-- Demo derby reset allowance (isolated from the race ruleset)
-- ===========================================================================
serverState({ phase = 'waiting', maxResets = -1, resetMode = 'inplace',
  totalLaps = 3, drivers = {} })
derbyState({ derbyPhase = 'running', oobLimit = 5, demoLimit = 10, maxResets = 1,
  derbyTime = 0, boundary = {}, startPositions = {},
  players = { { id = 1, status = 'alive' } } })

veh.x, veh.y, veh.z = 500, 0, 0
frames(0.6)                                  -- rolling snapshot: (500, 0, 0)
clearLog()
driverPressedReset(5, 5, 0)
resetHook()
check(countSent('RM_DerbyVehicleReset') == 1, 'a derby reset inside the allowance is reported')
check(#teleports == 0, 'and not undone')

frames(1.2)                                  -- new snapshot + notice throttle expiry
clearLog()
driverPressedReset(80, 80, 0)
resetHook()
check(#teleports == 1 and teleports[1].x == 5 and teleports[1].y == 5,
  'an over-allowance derby reset is put back on the last good position')
check(countSent('RM_DerbyResetDenied') == 1, 'the blocked derby attempt is reported')
check(countSent('RM_DerbyVehicleReset') == 0, 'and spends no derby allowance')
frames(0.2)
check(inputsBlocked == true, 'derby: reset inputs go dead once the derby allowance is spent')

derbyState({ derbyPhase = 'finished', oobLimit = 5, demoLimit = 10, maxResets = 1,
  derbyTime = 20, boundary = {}, startPositions = {}, players = {} })
frames(0.2)
check(inputsBlocked == false, 'derby over: the reset inputs come back')

-- ===========================================================================
-- BeamNG v0.39 compatibility
-- ===========================================================================
-- The GE-side accessor is used wherever the extension needs the player's car;
-- the be:* round trip is only there for builds that lack it.
check(engineAccessorCalls == 0,
  'the player vehicle is read through getPlayerVehicle(0), not be:getPlayerVehicle')

-- v0.39 reworked the teleport detector ("reduce false positives/negatives in
-- extreme cases (such as ... really fast vehicles)"), so the echo of a teleport
-- the mod performed can land a frame or two after the teleport itself — by which
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
local report = nil
for _, e in ipairs(sent) do
  if e.event == 'RM_VehicleConfig' then report = e.payload end
end
check(report ~= nil, 'the vehicle configuration is reported to the server')
check(report.label == 'etk800 — Cup Spec',
  'the setup is labelled with its real name, not the .pc filename stem')
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
-- mod has to lift them itself — otherwise a driver who disconnects mid-race is
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
  check(inputsBlocked == false, hook .. ': setup — a spectator does not need blocked inputs')
  handlers['RM_ReleaseSpectate']({ source = 'race' })
  frames(0.2)
  check(inputsBlocked == true, hook .. ': setup — the reset keys are dead with no allowance')

  clearLog()
  RM[hook]()
  local st = lastRouteState()
  check(st ~= nil and #st.waypoints == 0, hook .. ' clears the placed track')
  check(st ~= nil and st.spectating == false, hook .. ' lifts any spectator lock')
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

if fails == 0 then
  print('reset_test: ' .. checks .. ' checks, 0 failures')
else
  print('reset_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
